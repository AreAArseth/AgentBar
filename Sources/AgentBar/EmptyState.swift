import Foundation

/// What an empty session list says. Text only: the menu and the island each draw
/// it their own way (CLAUDE.md rule 2), and this is the one place the words live.
///
/// Two different empties. Nothing running after a day of work is ordinary and
/// needs one line. Nothing running on a fresh install is the moment a new user
/// decides whether AgentBar works at all — and the usual reason for it is that
/// every session they have open started before the hooks existed, which nothing
/// on screen would otherwise tell them.
enum EmptyState {
    static func title(firstRun: Bool) -> String {
        firstRun ? "Waiting for your first session" : "No active sessions"
    }

    static func hint(firstRun: Bool) -> String? {
        firstRun ? "Start a new one in any agent you have — sessions already open began before AgentBar was watching." : nil
    }

    /// No session has ever ended on this Mac: `history.jsonl` is written as
    /// sessions finish, so an absent or empty file means none has.
    static var firstRun: Bool {
        let size = (try? FileManager.default.attributesOfItem(atPath: HistoryStore.fileURL.path)[.size]) as? NSNumber
        return (size?.intValue ?? 0) == 0
    }
}
