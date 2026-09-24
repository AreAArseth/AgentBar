import Foundation

/// How a staged update gets into place, and the part of it that outlives the process
/// performing it.
///
/// Once the bundle has been replaced, the app has to die for the new one to start —
/// so the last steps run in a detached shell. Keeping the script and the file moves
/// here, away from the `Process` and `NSApp` that drive them, is what lets both be
/// tested: the same code runs against throwaway bundles and a fake launcher in
/// `UpdateInstallationTests`.
enum UpdateInstallation {
    enum Method: String, Equatable {
        /// Rename the old bundle aside and the new one into its place. Needs write
        /// access to the folder the bundle sits in — for /Applications, an admin.
        case bundle
        /// Replace what is inside the bundle, keeping the bundle folder itself. What a
        /// standard account can do with an app it installed and owns.
        case contents
        /// Neither is possible from this account; the running app stays as it is.
        case needsAdministrator
    }

    /// Decided by trying rather than asking: `access()` and the kernel can disagree
    /// (ACLs, App Management), so the parent is probed by making and removing a folder.
    static func method(for bundle: URL, uid: uid_t = getuid()) -> Method {
        if parentIsWritable(bundle) { return .bundle }
        if isReplaceableInPlace(bundle, uid: uid) { return .contents }
        return .needsAdministrator
    }

    static func parentIsWritable(_ bundle: URL) -> Bool {
        let fm = FileManager.default
        let probe = bundle.deletingLastPathComponent()
            .appendingPathComponent(".agentbar-update-probe-\(UUID().uuidString)")
        guard (try? fm.createDirectory(at: probe, withIntermediateDirectories: false)) != nil
        else { return false }
        try? fm.removeItem(at: probe)
        return true
    }

    /// Every item in the bundle is `uid`'s and every folder in it is writable, so
    /// the contents can be swapped out — and, if that fails halfway, swapped back.
    /// A single foreign file is enough to refuse: it could be neither removed nor
    /// restored, and a half-replaced bundle is worse than an old one.
    static func isReplaceableInPlace(_ bundle: URL, uid: uid_t = getuid()) -> Bool {
        let fm = FileManager.default
        func ok(_ path: String) -> Bool {
            guard let attrs = try? fm.attributesOfItem(atPath: path),
                  (attrs[.ownerAccountID] as? NSNumber)?.uint32Value == uid else { return false }
            if attrs[.type] as? FileAttributeType == .typeDirectory {
                return fm.isWritableFile(atPath: path)
            }
            return true
        }
        guard ok(bundle.path), let walk = fm.enumerator(atPath: bundle.path) else { return false }
        for case let relative as String in walk {
            if !ok(bundle.appendingPathComponent(relative).path) { return false }
        }
        return true
    }

    /// `.bundle`: move `current` to `backup`, `staged` into `current`'s place. On
    /// failure the old bundle is moved back and the error rethrown — the app never
    /// ends up missing.
    static func swapBundle(current: URL, staged: URL, backup: URL) throws {
        let fm = FileManager.default
        try fm.moveItem(at: current, to: backup)
        do {
            do { try fm.moveItem(at: staged, to: current) }
            catch { try fm.copyItem(at: staged, to: current) }   // cross-volume temp
        } catch {
            try? fm.moveItem(at: backup, to: current)
            throw error
        }
    }

    /// `.contents`: copy `current` to `backup`, then replace what is inside `current`
    /// with what is inside `staged`. Nothing is touched until the backup exists; on a
    /// failure after that the old contents are put back from it, the backup is
    /// dropped, and the error rethrown. Only if putting them back fails too is the
    /// backup kept, so there is still a whole copy of the old app to recover from.
    static func replaceContents(current: URL, staged: URL, backup: URL) throws {
        let fm = FileManager.default
        try fm.copyItem(at: current, to: backup)
        do {
            try replaceChildren(of: current, withChildrenOf: staged)
        } catch {
            do {
                try replaceChildren(of: current, withChildrenOf: backup)
                try? fm.removeItem(at: backup)
            } catch let restore {
                NSLog("AgentBar update: restoring \(current.path) failed (\(restore)); the old app is at \(backup.path)")
            }
            throw error
        }
    }

    private static func replaceChildren(of target: URL, withChildrenOf source: URL) throws {
        let fm = FileManager.default
        for child in try fm.contentsOfDirectory(at: target, includingPropertiesForKeys: nil) {
            try fm.removeItem(at: child)
        }
        for child in try fm.contentsOfDirectory(at: source, includingPropertiesForKeys: nil) {
            try fm.copyItem(at: child, to: target.appendingPathComponent(child.lastPathComponent))
        }
    }

    /// Open the freshly installed bundle, and put the old one back if it will not open.
    ///
    /// Arguments, all passed as arguments and never interpolated — this script runs
    /// `rm -rf`, and an app path is not something to hand to the shell's parser:
    /// `$1` the installed bundle, `$2` the staging dir, `$3` the backup of the old
    /// bundle, `$4` the launcher (`/usr/bin/open`, or a stand-in under test), `$5` the
    /// `Method` the bundle went in by (absent means `bundle`).
    ///
    /// The backup is deleted only after the new bundle has actually opened. If it
    /// refuses to, the old one is put back and launched instead, and the staging dir
    /// is left behind so a failed update can still be looked at. After a `contents`
    /// install the bundle folder stays where it is and only its insides go back: its
    /// parent is not writable, so removing the folder fails after emptying it, and the
    /// `mv` that follows would put the backup inside the empty bundle, not in its place.
    static let relaunchScript = #"""
    sleep 0.6
    if "$4" -n "$1"; then
      /bin/rm -rf "$2" "$3"
      exit 0
    fi
    if [ "$5" = contents ]; then
      /usr/bin/find "$1" -mindepth 1 -maxdepth 1 -exec /bin/rm -rf {} + || exit 1
      /usr/bin/ditto "$3" "$1" || exit 1
      /bin/rm -rf "$3"
    else
      /bin/rm -rf "$1"
      /bin/mv "$3" "$1" || exit 1
    fi
    "$4" -n "$1" || exit 1
    /bin/rm -rf "$2"
    """#
}
