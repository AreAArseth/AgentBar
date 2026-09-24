import Foundation
import Testing
@testable import AgentBar

/// The relaunch script is the one piece of the updater that runs after the app is
/// gone, so it is also the one piece nobody ever sees fail. These drive it against
/// throwaway directories standing in for the bundles, and a fake `open` that can be
/// told to refuse — the case that used to leave the Mac with no AgentBar at all.
@Suite struct UpdateInstallationTests {
    private let root: URL
    private let fm = FileManager.default

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("agentbar-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    /// A stand-in bundle whose `version` file says which one it is.
    private func bundle(_ name: String, version: String) throws -> URL {
        let url = root.appendingPathComponent(name)
        try fm.createDirectory(at: url, withIntermediateDirectories: true)
        try version.write(to: url.appendingPathComponent("version"), atomically: true, encoding: .utf8)
        return url
    }

    private func version(_ url: URL) throws -> String {
        try String(contentsOf: url.appendingPathComponent("version"), encoding: .utf8)
    }

    private func exists(_ url: URL) -> Bool { fm.fileExists(atPath: url.path) }

    /// Run the real script with a fake launcher in place of `/usr/bin/open`.
    /// The launcher is handed `-n <bundle>`, exactly as `open` would be, so a
    /// script of `[[ ... $2 ... ]]` can decide by looking at the bundle it was given.
    private func relaunch(current: URL, staging: URL, backup: URL,
                          launcherScript: String, method: String? = nil) throws -> Int32 {
        // A space in the name is not an accident: it is how a real /Applications
        // path behaves, and the script must survive it.
        let launcher = root.appendingPathComponent("fake launcher")
        try ("#!/bin/bash\n" + launcherScript + "\n").write(to: launcher, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: launcher.path)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-c", UpdateInstallation.relaunchScript, "agentbar-relaunch",
                             current.path, staging.path, backup.path, launcher.path]
            + (method.map { [$0] } ?? [])
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }

    @Test func successfulLaunchCleansBackupAndStaging() throws {
        let current = try bundle("AgentBar.app", version: "new")
        let backup = try bundle("backup.app", version: "old")
        let staging = try bundle("staging", version: "staged")

        #expect(try relaunch(current: current, staging: staging, backup: backup,
                             launcherScript: "exit 0") == 0)

        #expect(try version(current) == "new")
        #expect(!exists(backup))
        #expect(!exists(staging))
    }

    /// The regression this suite exists for: when the new bundle will not open,
    /// the old one goes back and gets launched instead of being deleted.
    @Test func failedLaunchRestoresOldBundleAndRelaunchesIt() throws {
        // The path is hostile on purpose — a quote and a command substitution that
        // would run if any of these paths reached the shell's parser unquoted.
        let current = try bundle("AgentBar ' $(touch injected).app", version: "new")
        let backup = try bundle("backup.app", version: "old")
        let staging = try bundle("staging", version: "staged")

        // Opens only the old bundle; the new one is rejected.
        let result = try relaunch(current: current, staging: staging, backup: backup,
                                  launcherScript: #"[[ "$(/bin/cat "$2/version")" == old ]]"#)

        #expect(result == 0)
        #expect(try version(current) == "old")
        #expect(!exists(staging))
        #expect(!exists(root.appendingPathComponent("injected")))
    }

    /// Nothing opens. The old bundle is still what sits in /Applications, and the
    /// staging dir survives so the failed download can be looked at.
    @Test func bothLaunchesFailKeepRestoredOldBundle() throws {
        let current = try bundle("AgentBar.app", version: "new")
        let backup = try bundle("backup.app", version: "old")
        let staging = try bundle("staging", version: "staged")

        #expect(try relaunch(current: current, staging: staging, backup: backup,
                             launcherScript: "exit 1") != 0)

        #expect(try version(current) == "old")
        #expect(exists(staging))
    }

    // MARK: - How the bundle goes in

    /// A folder standing in for /Applications, with a space in its name like the
    /// relaunch tests' launcher, holding a stand-in AgentBar.app.
    private func installed(version: String) throws -> (folder: URL, app: URL) {
        let folder = root.appendingPathComponent("Apps Folder")
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        return (folder, try app(at: folder.appendingPathComponent("AgentBar.app"), version: version))
    }

    /// `version` at the top, and again one level down, so a replace that only
    /// handled the first level would show.
    private func app(at url: URL, version: String) throws -> URL {
        let macOS = url.appendingPathComponent("Contents/MacOS")
        try fm.createDirectory(at: macOS, withIntermediateDirectories: true)
        try version.write(to: url.appendingPathComponent("version"), atomically: true, encoding: .utf8)
        try version.write(to: macOS.appendingPathComponent("AgentBar"), atomically: true, encoding: .utf8)
        return url
    }

    private func nestedVersion(_ url: URL) throws -> String {
        try String(contentsOf: url.appendingPathComponent("Contents/MacOS/AgentBar"), encoding: .utf8)
    }

    /// A standard account in front of /Applications: the folder is there to read, and
    /// nothing can be created in it or renamed out of it. Undone afterwards so the
    /// temp dir can still be cleaned up.
    private func readOnly<T>(_ url: URL, _ body: () throws -> T) throws -> T {
        try fm.setAttributes([.posixPermissions: 0o555], ofItemAtPath: url.path)
        defer { try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path) }
        return try body()
    }

    /// Permissions mean nothing to root, so the read-only simulations would pass for
    /// the wrong reason there.
    private static let notRoot = getuid() != 0

    @Test func writableParentSwapsTheBundle() throws {
        let (_, app) = try installed(version: "old")
        #expect(UpdateInstallation.method(for: app) == .bundle)
    }

    @Test(.enabled(if: notRoot))
    func readOnlyParentWithOwnedBundleReplacesContents() throws {
        let (folder, app) = try installed(version: "old")
        let method = try readOnly(folder) { UpdateInstallation.method(for: app) }
        #expect(method == .contents)
        // The probe cleans up after itself, and it was refused anyway.
        #expect(try fm.contentsOfDirectory(atPath: folder.path) == ["AgentBar.app"])
    }

    /// Someone else's bundle behind a folder this account cannot write — the admin
    /// installed it. Nothing can be done from here, so nothing is tried. The owner
    /// cannot be changed without root, so the check is asked about another uid.
    @Test(.enabled(if: notRoot))
    func readOnlyParentWithForeignBundleNeedsAnAdministrator() throws {
        let (folder, app) = try installed(version: "old")
        let method = try readOnly(folder) { UpdateInstallation.method(for: app, uid: getuid() + 1) }
        #expect(method == .needsAdministrator)
    }

    /// Owned, but with a folder inside it that could not be emptied — or refilled on
    /// the way back. A half-replaced bundle is worse than an old one.
    @Test(.enabled(if: notRoot))
    func readOnlyFolderInsideTheBundleNeedsAnAdministrator() throws {
        let (folder, app) = try installed(version: "old")
        let macOS = app.appendingPathComponent("Contents/MacOS")
        let method = try readOnly(macOS) { try readOnly(folder) { UpdateInstallation.method(for: app) } }
        #expect(method == .needsAdministrator)
    }

    @Test func swapBundleMovesTheOldOneAsideAndTheNewOneIn() throws {
        let (_, app) = try installed(version: "old")
        let staged = try self.app(at: root.appendingPathComponent("staging/AgentBar.app"), version: "new")
        let backup = root.appendingPathComponent("backup.app")

        try UpdateInstallation.swapBundle(current: app, staged: staged, backup: backup)

        #expect(try version(app) == "new")
        #expect(try nestedVersion(app) == "new")
        #expect(try version(backup) == "old")
        #expect(!exists(staged))
    }

    @Test func swapBundleThatCannotFinishPutsTheOldOneBack() throws {
        let (_, app) = try installed(version: "old")
        let missing = root.appendingPathComponent("staging/AgentBar.app")
        let backup = root.appendingPathComponent("backup.app")

        #expect(throws: (any Error).self) {
            try UpdateInstallation.swapBundle(current: app, staged: missing, backup: backup)
        }
        #expect(try version(app) == "old")
        #expect(!exists(backup))
    }

    /// The standard-account path end to end: the folder stays, its insides are the
    /// new build's (a file only the old one had is gone), and a whole copy of the old
    /// app waits in the backup for the relaunch script.
    @Test(.enabled(if: notRoot))
    func replaceContentsInstallsIntoAReadOnlyParent() throws {
        let (folder, app) = try installed(version: "old")
        try "stale".write(to: app.appendingPathComponent("Contents/only-in-old"), atomically: true, encoding: .utf8)
        let staged = try self.app(at: root.appendingPathComponent("staging/AgentBar.app"), version: "new")
        let backup = root.appendingPathComponent("backup.app")

        try readOnly(folder) {
            try UpdateInstallation.replaceContents(current: app, staged: staged, backup: backup)
        }

        #expect(try version(app) == "new")
        #expect(try nestedVersion(app) == "new")
        #expect(!exists(app.appendingPathComponent("Contents/only-in-old")))
        #expect(try version(backup) == "old")
        #expect(exists(backup.appendingPathComponent("Contents/only-in-old")))
    }

    /// The new build cannot be copied in partway through — one of its files is
    /// unreadable. The old contents go back, and the backup is not left lying around.
    @Test(.enabled(if: notRoot))
    func replaceContentsThatFailsHalfwayRestoresTheOldContents() throws {
        let (folder, app) = try installed(version: "old")
        let staged = try self.app(at: root.appendingPathComponent("staging/AgentBar.app"), version: "new")
        let unreadable = staged.appendingPathComponent("Contents/MacOS/AgentBar")
        let backup = root.appendingPathComponent("backup.app")

        try fm.setAttributes([.posixPermissions: 0o000], ofItemAtPath: unreadable.path)
        defer { try? fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: unreadable.path) }
        #expect(throws: (any Error).self) {
            try readOnly(folder) {
                try UpdateInstallation.replaceContents(current: app, staged: staged, backup: backup)
            }
        }

        #expect(try version(app) == "old")
        #expect(try nestedVersion(app) == "old")
        #expect(!exists(backup))
    }

    // MARK: - Relaunching after a contents replace

    @Test(.enabled(if: notRoot))
    func contentsLaunchSuccessCleansBackupAndStaging() throws {
        let (folder, app) = try installed(version: "new")
        let backup = try bundle("backup.app", version: "old")
        let staging = try bundle("staging", version: "staged")

        let result = try readOnly(folder) {
            try relaunch(current: app, staging: staging, backup: backup,
                         launcherScript: "exit 0", method: "contents")
        }

        #expect(result == 0)
        #expect(try version(app) == "new")
        #expect(!exists(backup))
        #expect(!exists(staging))
    }

    /// Why the script needs a contents mode at all: in a folder this account cannot
    /// write, the bundle-mode restore empties AgentBar.app, fails to remove the folder,
    /// and then moves the backup *into* it — a bundle holding a bundle, launching nothing.
    @Test(.enabled(if: notRoot))
    func contentsFailedLaunchRestoresOldContentsInPlaceAndRelaunches() throws {
        let (folder, app) = try installed(version: "new")
        let backup = try self.app(at: root.appendingPathComponent("backup ' $(touch injected).app"), version: "old")
        let staging = try bundle("staging", version: "staged")

        let result = try readOnly(folder) {
            try relaunch(current: app, staging: staging, backup: backup,
                         launcherScript: #"[[ "$(/bin/cat "$2/version")" == old ]]"#, method: "contents")
        }

        #expect(result == 0)
        #expect(try version(app) == "old")
        #expect(try nestedVersion(app) == "old")
        #expect(!exists(backup))
        #expect(!exists(staging))
        #expect(!exists(root.appendingPathComponent("injected")))
    }

    @Test(.enabled(if: notRoot))
    func contentsBothLaunchesFailKeepRestoredOldContents() throws {
        let (folder, app) = try installed(version: "new")
        let backup = try self.app(at: root.appendingPathComponent("backup.app"), version: "old")
        let staging = try bundle("staging", version: "staged")

        let result = try readOnly(folder) {
            try relaunch(current: app, staging: staging, backup: backup,
                         launcherScript: "exit 1", method: "contents")
        }

        #expect(result != 0)
        #expect(try version(app) == "old")
        #expect(try nestedVersion(app) == "old")
        #expect(exists(staging))
    }
}
