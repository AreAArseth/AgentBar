import Foundation
import Testing
@testable import AgentBar

/// Rows the cloud poller writes run somewhere this Mac cannot reach — a vendor's
/// cloud, or one of the user's own machines mirrored over ssh — and the two are
/// told apart by the adapter that wrote them, never by reading a label or a url.
/// A mirror is never called "Cloud", and none of its turns, ends or lost
/// connections are this Mac's events. Hosts here are synthetic (`host-a`).
@Suite struct OffMachineTests {
    private func row(_ fields: [String: Any], id: String = "ssh-host-a-s1") throws -> Session {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("agentbar-offmachine-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var o: [String: Any] = ["agent": "claude", "state": "thinking", "label": "", "project": "host-a: api",
                                "cwd": "", "pid": 1, "started": true, "ts": Date().timeIntervalSince1970]
        for (k, v) in fields { o[k] = v }
        let url = dir.appendingPathComponent("\(id).json")
        try JSONSerialization.data(withJSONObject: o).write(to: url)
        return try #require(Session(fileURL: url))
    }

    private func mirror(_ extra: [String: Any] = [:]) throws -> Session {
        try row(["entrypoint": "cloud", "source": "ssh", "host": "host-a", "url": "ssh://host-a"].merging(extra) { $1 })
    }

    private func vendor(_ source: String) throws -> Session {
        try row(["entrypoint": "cloud", "source": source, "url": "https://remote-host.example/run"],
                id: "cloud-\(source)-r1")
    }

    @Test func aMirrorIsNamedForItsMachineAndNeverCloud() throws {
        #expect(try mirror().placeName == "host-a")
        #expect(try mirror().isMirror)
    }

    @Test func aMirrorWithNoNameIsRemote() throws {
        #expect(try mirror(["host": ""]).placeName == "Remote")
        #expect(try row(["entrypoint": "cloud", "source": "ssh"]).placeName == "Remote")
    }

    /// A name arrives in a file anybody may write; one that is not a short line
    /// is dropped, and the row says "Remote" rather than carry it.
    @Test func aHostNameThatIsNotOneShortLineIsDropped() throws {
        #expect(try mirror(["host": "host-a\nsecond line"]).placeName == "Remote")
        #expect(try mirror(["host": String(repeating: "h", count: 25)]).placeName == "Remote")
    }

    @Test(arguments: ["devin", "cursor", "codex"])
    func aVendorsCloudIsStillCloud(source: String) throws {
        let s = try vendor(source)
        #expect(s.placeName == "Cloud")
        #expect(!s.isMirror)
        #expect(s.isOffMachine)
    }

    /// Structural, not textual: a vendor row that happens to carry a host, or a
    /// project that looks like one, is still the vendor's.
    @Test func theAdapterDecidesNotTheWords() throws {
        let s = try row(["entrypoint": "cloud", "source": "devin", "host": "host-a", "url": "ssh://host-a"])
        #expect(s.placeName == "Cloud")
        #expect(try row(["source": "ssh", "host": "host-a"]).placeName == nil, "a local row is never off-machine")
    }

    @Test func localRowsHaveNoPlace() throws {
        let s = try row([:], id: "local-1")
        #expect(s.placeName == nil)
        #expect(!s.isOffMachine)
    }

    /// Everything that records, sounds or announces is handed this list.
    @Test func onlyAMirrorIsLeftOutOfWhatThisMacRecords() throws {
        let local = try row([:], id: "local-1")
        let all = [local, try mirror(), try vendor("devin")]
        #expect(Session.local(all).map(\.id) == ["local-1", "cloud-devin-r1"])
    }

    @Test func aStaleMirrorIsDimmedAndNeverFinished() throws {
        let c = SessionRowView.content(for: try mirror(["stale": true]))
        #expect(c.dot == .ended)
        #expect(c.detail == "connection lost")
        #expect(SessionRowView.content(for: try mirror()).dot == .working)
    }

    @Test func noLinkAndNoKeystrokeReachesAnOffMachineRow() throws {
        let copilotMirror = try mirror(["agent": "copilot", "state": "question"])
        #expect(!AgentActions.mayKeystroke(copilotMirror))
        let local = try row([:], id: "local-1")
        #expect(URLCommands.linkable([local, try mirror(), try vendor("cursor")]).map(\.id) == ["local-1"])
    }
}
