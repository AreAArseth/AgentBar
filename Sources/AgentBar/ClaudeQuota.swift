import Foundation
import Security

/// Claude Code's quota windows — the one number on this machine that cannot be
/// read off the disk.
///
/// Everything else AgentBar shows about spending comes from a file: Codex writes
/// its exact percentages into every rollout, Copilot keeps its spend in a SQLite
/// database, Claude's transcripts carry tokens. Claude's *windows* are not
/// written anywhere local — checked across every `~/.claude*` config on this
/// machine, twice — so the choice was to keep showing half an answer or to ask
/// Anthropic the same question Claude Code itself asks. This asks, and only when
/// switched on.
///
/// The rules this file exists to keep:
///
/// - **Off until asked.** `enabled` is false by default and nothing here runs
///   until it is true. It is the second network call the app can make, and the
///   README says so in the same breath as the first.
/// - **The token is borrowed, never kept.** It is read at the moment of the call,
///   never cached in memory between calls, never written anywhere, and never put
///   into a string that could reach a label, a log or a crash report.
/// - **AgentBar never refreshes it.** That is Claude Code's job; two processes
///   racing on one refresh token is how people get logged out. An expired token
///   means no reading until the CLI renews it on its own next run.
/// - **Every failure is silent.** A refused Keychain prompt, no credential, a
///   401, a 429, no network — all end the same way: no reading, nothing on
///   screen, and the local token line stays where it was.
final class ClaudeQuota {
    static let shared = ClaudeQuota()

    // MARK: - The switch

    static var enabled: Bool {
        get { UserDefaults.standard.bool(forKey: "claudeQuotaNetwork") }
        set { UserDefaults.standard.set(newValue, forKey: "claudeQuotaNetwork") }
    }

    // MARK: - What comes back

    struct Snapshot: Equatable {
        /// `UsageWindow`, not a type of this file's own: the meter draws Codex and
        /// Claude with the same code, and two structs of the same shape would
        /// drift the first time one of them learned something.
        let windows: [UsageWindow]
        /// Which login the number belongs to. A machine can carry several
        /// `~/.claude*` configs, and a percentage with no owner is a lie on all
        /// but one of them.
        let account: String?
        let at: Date
    }

    // MARK: - State

    private let lock = NSLock()
    private var snapshot: Snapshot?
    private var nextAllowed = Date.distantPast
    private var inFlight = false

    /// The documented safe floor for this endpoint is 180 s; five minutes is
    /// well clear of it and still fresh enough for a window that moves over
    /// hours.
    private static let interval: TimeInterval = 300
    /// Past this the number is old enough to be wrong, and silence beats a stale
    /// percentage — the same stance `UsageCenter` takes for Codex.
    private static let maxAge: TimeInterval = 30 * 60
    /// 429 backs off hard and recovers slowly. The endpoint has a punishing
    /// bucket for callers it does not recognise, and hammering it is how a
    /// borrowed token gets the person's own CLI throttled.
    private static let backoffSteps: [TimeInterval] = [600, 1200, 1800]
    private var backoffStep = 0

    /// The freshest reading, or nil when there isn't one worth showing.
    func latest(now: Date = Date()) -> Snapshot? {
        lock.lock(); defer { lock.unlock() }
        guard let s = snapshot, now.timeIntervalSince(s.at) < Self.maxAge else { return nil }
        return s
    }

    /// Fetch if the switch is on and enough time has passed. `changed` fires on
    /// an arbitrary queue, and only when there is something new to draw.
    func refreshIfDue(now: Date = Date(), changed: @escaping () -> Void) {
        guard Self.enabled else {
            lock.lock(); snapshot = nil; lock.unlock()
            return
        }
        lock.lock()
        guard !inFlight, now >= nextAllowed else { lock.unlock(); return }
        inFlight = true
        nextAllowed = now.addingTimeInterval(Self.interval)
        lock.unlock()

        fetch { [weak self] result in
            guard let self else { return }
            self.lock.lock()
            self.inFlight = false
            var fresh = false
            switch result {
            case .success(let snap):
                self.backoffStep = 0
                fresh = self.snapshot?.windows != snap.windows
                self.snapshot = snap
            case .rateLimited:
                let wait = Self.backoffSteps[min(self.backoffStep, Self.backoffSteps.count - 1)]
                self.backoffStep += 1
                self.nextAllowed = Date().addingTimeInterval(wait)
            case .failed:
                // Ordinary failure (offline, 401, a shape we don't recognise):
                // wait out the normal interval and try again. Whatever is on
                // screen ages out by itself through `maxAge`.
                break
            }
            self.lock.unlock()
            if fresh { changed() }
        }
    }

    private enum Outcome {
        case success(Snapshot)
        case rateLimited
        case failed
    }

    // MARK: - The call

    private func fetch(_ done: @escaping (Outcome) -> Void) {
        guard let credential = Self.credential(),
              let token = Self.accessToken(in: credential.json),
              !Self.expired(credential.json)
        else { done(.failed); return }

        var request = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
        request.httpMethod = "GET"
        request.timeoutInterval = 15
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(Self.userAgent(), forHTTPHeaderField: "User-Agent")

        // Ephemeral: no cookie jar, no disk cache, nothing about this call
        // outlives it.
        let config = URLSessionConfiguration.ephemeral
        config.waitsForConnectivity = false
        config.httpCookieStorage = nil
        config.urlCache = nil
        let session = URLSession(configuration: config)
        let account = credential.account
        session.dataTask(with: request) { data, response, _ in
            defer { session.finishTasksAndInvalidate() }
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            if code == 429 { done(.rateLimited); return }
            guard code == 200, let data,
                  let snap = Self.parse(data, account: account)
            else { done(.failed); return }
            done(.success(snap))
        }.resume()
    }

    /// `claude-code/<version>` is what the endpoint routes on; callers without it
    /// land in a bucket that 429s almost immediately. We keep that prefix and add
    /// our own name after it rather than pretending to be the CLI outright — if a
    /// stricter match ever rejects the suffix, the feature goes quiet and backs
    /// off, which is the failure mode everything else here has too.
    static func userAgent(appVersion: String? = nil) -> String {
        let app = appVersion
            ?? (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String)
            ?? "0"
        return "claude-code/\(installedCLIVersion() ?? "2.1.0") AgentBar/\(app)"
    }

    /// The Claude Code build actually installed here, so the header isn't
    /// claiming a version that doesn't exist. Two cheap places carry it; a
    /// constant is the last resort.
    static func installedCLIVersion(home: URL? = nil) -> String? {
        let fm = FileManager.default
        let base = home ?? fm.homeDirectoryForCurrentUser
        let versions = base.appendingPathComponent(".local/share/claude/versions")
        if let names = try? fm.contentsOfDirectory(atPath: versions.path) {
            let real = names.filter { $0.first?.isNumber == true }
                .sorted { $0.compare($1, options: .numeric) == .orderedAscending }
            if let newest = real.last { return newest }
        }
        for root in WeightReader.claudeConfigDirs(home: base) {
            let marker = root.appendingPathComponent(".last-update-result.json")
            guard let data = try? Data(contentsOf: marker),
                  let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }
            if let v = o["version_to"] as? String { return v }
            if let v = o["version_from"] as? String { return v }
        }
        return nil
    }

    // MARK: - Parsing (pure)

    /// The endpoint answers with one object per window. `utilization` is a
    /// **percentage**, not a fraction — readers that assume otherwise render 1 %
    /// as 100 % or 55 % as half a percent, and both mistakes have been filed
    /// against other clients of this endpoint. Take it as given, clamp it, and
    /// never scale it.
    static func parse(_ data: Data, account: String? = nil, at: Date = Date()) -> Snapshot? {
        guard let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        var windows: [UsageWindow] = []
        if let w = window(o["five_hour"], name: "5h") { windows.append(w) }
        if let w = window(o["seven_day"], name: "weekly") { windows.append(w) }
        guard !windows.isEmpty else { return nil }
        return Snapshot(windows: windows, account: account, at: at)
    }

    private static func window(_ any: Any?, name: String) -> UsageWindow? {
        // A window that isn't running comes back as null, and that is an answer:
        // no window, no meter. It must not become a confident zero.
        guard let o = any as? [String: Any],
              let raw = (o["utilization"] as? NSNumber)?.doubleValue,
              raw.isFinite
        else { return nil }
        return UsageWindow(name: name,
                           usedPercent: min(max(raw, 0), 100),
                           resetsAt: (o["resets_at"] as? String).flatMap(parseISO))
    }

    private static let isoFrac: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let isoPlain = ISO8601DateFormatter()

    static func parseISO(_ s: String) -> Date? {
        isoFrac.date(from: s) ?? isoPlain.date(from: s)
    }

    // MARK: - The credential

    /// Claude Code keeps its OAuth credential in the login Keychain under one
    /// service name; some installs keep a file instead. Either way the shape is
    /// the same JSON, and either way macOS is the one that decides whether this
    /// app may read it — the first attempt raises the system's own "allow
    /// AgentBar to use this keychain item" dialog, and a refusal is final until
    /// the person changes their mind.
    static let service = "Claude Code-credentials"

    static func credential() -> (json: [String: Any], account: String?)? {
        if let fromKeychain = keychainCredential() { return fromKeychain }
        let fm = FileManager.default
        for root in WeightReader.claudeConfigDirs(home: fm.homeDirectoryForCurrentUser) {
            let file = root.appendingPathComponent(".credentials.json")
            guard let data = try? Data(contentsOf: file),
                  let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }
            return (o, root.lastPathComponent)
        }
        return nil
    }

    private static func keychainCredential() -> (json: [String: Any], account: String?)? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnData as String: true,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let found = item as? [String: Any],
              let data = found[kSecValueData as String] as? Data,
              let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return (o, found[kSecAttrAccount as String] as? String)
    }

    /// The credential's exact shape has changed before and will again, so this
    /// looks for the field by name at any depth rather than hard-coding a path
    /// through it.
    static func accessToken(in json: [String: Any]) -> String? {
        for (key, value) in json {
            if key == "accessToken" || key == "access_token",
               let s = value as? String, !s.isEmpty { return s }
            if let nested = value as? [String: Any], let found = accessToken(in: nested) {
                return found
            }
        }
        return nil
    }

    /// Expiry is milliseconds since the epoch where it appears at all. An expired
    /// token is not an error worth surfacing: the CLI renews it the next time it
    /// runs, and asking with it would only spend a 401.
    static func expired(_ json: [String: Any], now: Date = Date()) -> Bool {
        guard let ms = expiryMillis(in: json) else { return false }
        return Date(timeIntervalSince1970: ms / 1000) <= now
    }

    private static func expiryMillis(in json: [String: Any]) -> Double? {
        for (key, value) in json {
            if key == "expiresAt" || key == "expires_at",
               let n = (value as? NSNumber)?.doubleValue { return n }
            if let nested = value as? [String: Any], let found = expiryMillis(in: nested) {
                return found
            }
        }
        return nil
    }
}
