import AppKit
import Testing
@testable import AgentBar

/// The island's display choice. These run in the test bundle's own defaults
/// domain, so they never touch the installed app's setting; each test restores
/// the key it wrote anyway, because a leaked pin would silently steer the ones
/// after it.
@Suite(.serialized) struct IslandScreenTests {
    private static let key = "islandScreen"

    private func withCleanDefaults(_ body: () throws -> Void) rethrows {
        let saved = UserDefaults.standard.string(forKey: Self.key)
        UserDefaults.standard.removeObject(forKey: Self.key)
        defer {
            if let saved { UserDefaults.standard.set(saved, forKey: Self.key) }
            else { UserDefaults.standard.removeObject(forKey: Self.key) }
        }
        try body()
    }

    @Test func defaultsToFollowingThePointer() throws {
        try withCleanDefaults {
            #expect(IslandScreen.choice == .followsPointer)
            #expect(!IslandScreen.pinnedDisplayMissing)
        }
    }

    @Test func pinRoundTripsThroughDefaults() throws {
        try withCleanDefaults {
            IslandScreen.choice = .pinned("ABC-123")
            #expect(IslandScreen.choice == .pinned("ABC-123"))
            IslandScreen.choice = .followsPointer
            #expect(IslandScreen.choice == .followsPointer)
            // Clearing means clearing: a leftover value would re-pin on next launch.
            #expect(UserDefaults.standard.string(forKey: Self.key) == nil)
        }
    }

    /// The case that must never lose the island: a display that is pinned but not
    /// plugged in. The preference is kept — it takes effect again on replug — but
    /// resolution falls back to the pointer rather than to nothing.
    @Test func pinnedDisplayThatIsGoneFallsBackToThePointer() throws {
        try withCleanDefaults {
            IslandScreen.choice = .pinned("not-a-connected-display")
            #expect(IslandScreen.pinnedDisplayMissing)
            #expect(IslandScreen.resolved != nil)
            #expect(IslandScreen.resolved === IslandScreen.underPointer)
            #expect(IslandScreen.choice == .pinned("not-a-connected-display"))
        }
    }

    /// A pin only resolves when a connected display actually carries that UUID.
    @Test func pinnedDisplayThatIsPresentWins() throws {
        try withCleanDefaults {
            guard let screen = NSScreen.screens.first,
                  let uuid = IslandScreen.uuid(of: screen)
            else { return }   // headless CI: nothing to assert against
            IslandScreen.choice = .pinned(uuid)
            #expect(!IslandScreen.pinnedDisplayMissing)
            #expect(IslandScreen.resolved === screen)
        }
    }

    /// Legacy/garbage values must degrade to the default rather than pinning to a
    /// display that cannot exist — "pointer" is what older builds wrote.
    @Test(arguments: ["", "pointer"])
    func nonPinValuesReadAsFollowingThePointer(_ raw: String) throws {
        try withCleanDefaults {
            UserDefaults.standard.set(raw, forKey: Self.key)
            #expect(IslandScreen.choice == .followsPointer)
        }
    }
}
