import Cocoa
import UserNotifications

/// Native macOS notifications, with Allow and Deny on the banner itself.
///
/// This is a deliberate, narrow exception to rule 2 ("nothing that unfolds over
/// the screen on its own"), and it earns it twice over. It is **off by default and
/// stays off** until the user turns it on, like sounds — a status app must not
/// start interrupting people after an update. And the surface belongs to macOS:
/// AgentBar draws nothing of its own, it hands the system a banner and the system
/// decides where and whether to show it, under the user's own Focus rules.
///
/// What made it worth building was the display picker. Pin the island to one screen
/// and work on another and there is no longer anywhere a pending approval can
/// appear — the hole is new, and this is what fills it.
///
/// The buttons land in exactly the seam the menu, the island and the global hotkey
/// already use: `AgentActions.answer(ApprovalAction(...))`. No fourth code path.
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = Notifier()

    /// Category ids. Actions are registered once, before anything is posted —
    /// a notification whose category has no registered actions shows no buttons.
    private static let approvalCategory = "agentbar.approval"
    private static let plainCategory = "agentbar.plain"
    private static let allowAction = "agentbar.allow"
    private static let denyAction = "agentbar.deny"

    /// Set by the app delegate so a tapped banner can find its request and session.
    var requests: (() -> [ApprovalRequest])?
    var sessions: (() -> [Session])?

    /// The previous tick, for edge detection — the same shape `SoundCenter` keeps.
    private var lastStates: [String: Session.State] = [:]
    private var primed = false
    /// Identifiers currently on screen, so they can be taken back down.
    private var deliveredRequests: Set<String> = []

    // MARK: - Preferences

    /// Two switches, both off by default (`bool(forKey:)` gives false), owned here
    /// rather than as string literals because Settings and this class both read them.
    enum Prefs {
        static var approvals: Bool {
            get { UserDefaults.standard.bool(forKey: "notifyApprovals") }
            set { UserDefaults.standard.set(newValue, forKey: "notifyApprovals") }
        }
        static var done: Bool {
            get { UserDefaults.standard.bool(forKey: "notifyDone") }
            set { UserDefaults.standard.set(newValue, forKey: "notifyDone") }
        }
        static var anyEnabled: Bool { approvals || done }
    }

    // MARK: - Lifecycle

    /// Registers the delegate and the categories at launch, **without** asking for
    /// permission. Setting a delegate prompts for nothing; `requestAuthorization`
    /// does, and a system prompt during launch is how the app once hung waiting for
    /// a TCC dialog nobody had seen yet. The ask happens when the user ticks the box.
    ///
    /// The delegate is registered even with both switches off, because it is what
    /// receives button taps — and a notification can outlive the setting that
    /// created it.
    func start() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        let allow = UNNotificationAction(identifier: Self.allowAction, title: "Allow", options: [])
        let deny = UNNotificationAction(identifier: Self.denyAction, title: "Deny",
                                        options: [.destructive])
        center.setNotificationCategories([
            UNNotificationCategory(identifier: Self.approvalCategory, actions: [allow, deny],
                                   intentIdentifiers: [], options: []),
            UNNotificationCategory(identifier: Self.plainCategory, actions: [],
                                   intentIdentifiers: [], options: []),
        ])
    }

    /// Asks macOS for permission, and reports back whether it was granted so the
    /// checkbox can un-tick itself rather than claiming a setting that does nothing.
    func requestAuthorization(_ done: @escaping (Bool) -> Void) {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert]) { granted, _ in
            DispatchQueue.main.async { done(granted) }
        }
    }

    /// Whether macOS will actually deliver, which the user can change in System
    /// Settings behind our back. Settings shows it so a ticked box that does nothing
    /// is explainable.
    func authorizationStatus(_ done: @escaping (UNAuthorizationStatus) -> Void) {
        UNUserNotificationCenter.current().getNotificationSettings { s in
            DispatchQueue.main.async { done(s.authorizationStatus) }
        }
    }

    // MARK: - What deserves a notification (pure, so it can be tested)

    struct Event: Equatable {
        enum Kind: Equatable { case approval, question, finished }
        let id: String
        let kind: Kind
        let title: String
        let body: String
        let sessionId: String
    }

    /// Approvals and questions, keyed by the request's file name so the banner can
    /// be taken back down when the request goes away.
    ///
    /// Questions get no buttons: their answer is a choice from a list or free text,
    /// which a two-button banner cannot express — tapping one jumps to the session.
    static func requestEvents(previous: Set<String>, requests: [ApprovalRequest],
                              sessions: [Session], enabled: Bool) -> (post: [Event], withdraw: [String]) {
        guard enabled else { return ([], Array(previous)) }
        let live = Set(requests.map(\.fileName))
        let post = requests.filter { !previous.contains($0.fileName) }.map { r -> Event in
            // The project names the work; the agent names it when there is no project
            // yet, and the request carries its own agent id — a request can arrive
            // before the session row it belongs to.
            let project = sessions.first { $0.id == r.sessionId }?.project ?? ""
            let who = project.isEmpty ? Agent.byID(r.agentID).name : project
            return r.questions != nil
                ? Event(id: r.fileName, kind: .question, title: "\(who) is asking",
                        body: r.display, sessionId: r.sessionId)
                : Event(id: r.fileName, kind: .approval, title: "\(who) needs approval",
                        body: r.display, sessionId: r.sessionId)
        }
        return (post, previous.subtracting(live).map { $0 })
    }

    /// Sessions that just finished. Edge-detected against the previous tick, the way
    /// `SoundCenter.observe` does it, so a row sitting in `done` notifies once.
    ///
    /// `decayed` rows are skipped: a watchdog guessing that a quiet Antigravity
    /// session is over is not the agent saying it finished, and a banner claiming
    /// otherwise would be inventing an outcome.
    static func sessionEvents(previous: [String: Session.State], sessions: [Session],
                              enabled: Bool) -> [Event] {
        guard enabled else { return [] }
        return sessions.compactMap { s -> Event? in
            guard s.started, !s.decayed, s.state == .done || s.state == .error else { return nil }
            let was = previous[s.id]
            guard was != .done, was != .error else { return nil }
            let who = s.project.isEmpty ? s.agentID : s.project
            return Event(id: "done:\(s.id):\(Int(s.ts))", kind: .finished,
                         title: s.state == .error ? "\(who) failed" : "\(who) finished",
                         body: s.state == .error ? (s.label.isEmpty ? "The turn ended with an error." : s.label)
                                                 : (s.recap.isEmpty ? (s.prompt.isEmpty ? "" : s.prompt) : s.recap),
                         sessionId: s.id)
        }
    }

    // MARK: - Wiring

    func observe(_ sessions: [Session]) {
        defer { lastStates = Dictionary(sessions.map { ($0.id, $0.state) }, uniquingKeysWith: { a, _ in a }) }
        // The launch snapshot is a baseline; every finished session already on disk
        // did not just finish, and a relaunch must not fire a dozen banners.
        guard primed else { primed = true; return }
        for e in Self.sessionEvents(previous: lastStates, sessions: sessions, enabled: Prefs.done) {
            post(e)
        }
    }

    func requestsChanged(_ requests: [ApprovalRequest], sessions: [Session]) {
        let (post, withdraw) = Self.requestEvents(previous: deliveredRequests, requests: requests,
                                                  sessions: sessions, enabled: Prefs.approvals)
        // Withdraw first, and always — a delivered banner whose request has been
        // answered elsewhere, or has timed out, has two live buttons that would do
        // nothing. That is worse than never having shown it.
        if !withdraw.isEmpty {
            UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: withdraw)
            deliveredRequests.subtract(withdraw)
        }
        for e in post { self.post(e); deliveredRequests.insert(e.id) }
    }

    /// Everything on screen goes away — used when the user turns approvals off, so a
    /// banner posted a moment ago cannot outlive the setting that allowed it.
    func withdrawAll() {
        guard !deliveredRequests.isEmpty else { return }
        UNUserNotificationCenter.current()
            .removeDeliveredNotifications(withIdentifiers: Array(deliveredRequests))
        deliveredRequests.removeAll()
    }

    private func post(_ e: Event) {
        let content = UNMutableNotificationContent()
        content.title = e.title
        if !e.body.isEmpty { content.body = e.body }
        // No sound, deliberately. Audio belongs to `SoundCenter`, which is its own
        // opt-in with its own volume — two systems both deciding to make a noise
        // would double up on every approval.
        content.categoryIdentifier = e.kind == .approval ? Self.approvalCategory : Self.plainCategory
        content.userInfo = ["sessionId": e.sessionId, "requestId": e.id]
        let request = UNNotificationRequest(identifier: e.id, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    // MARK: - UNUserNotificationCenterDelegate

    /// AgentBar has no dock icon and is almost never frontmost, but when it is (the
    /// Settings window is open) the banner must still appear — otherwise turning the
    /// setting on and testing it looks broken.
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler handler: @escaping (UNNotificationPresentationOptions) -> Void) {
        handler([.banner, .list])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse,
                                withCompletionHandler handler: @escaping () -> Void) {
        defer { handler() }
        let info = response.notification.request.content.userInfo
        let requestId = info["requestId"] as? String ?? ""
        let sessionId = info["sessionId"] as? String ?? ""
        deliveredRequests.remove(requestId)

        let behavior: String?
        switch response.actionIdentifier {
        case Self.allowAction: behavior = "allow"
        case Self.denyAction: behavior = "deny"
        default: behavior = nil          // the banner itself was clicked
        }

        let live = sessions?() ?? []
        guard let behavior else {
            // Tapping the body means "take me there", for an approval and a question
            // alike — a question's answer is a list or free text, which a banner
            // cannot carry.
            if let session = live.first(where: { $0.id == sessionId }) {
                AgentActions.focus(session, requests: requests?() ?? [])
            }
            return
        }

        // Re-look-up rather than trusting the banner: request file names repeat
        // across the tools of one turn, so by the time this is tapped the name may
        // belong to a *successor* request showing a different command. Answering
        // that one would allow something the user never read.
        guard let request = (requests?() ?? []).first(where: { $0.fileName == requestId }),
              let session = live.first(where: { $0.id == request.sessionId })
        else { return }
        AgentActions.answer(ApprovalAction(request: request, behavior: behavior, session: session))
    }
}
