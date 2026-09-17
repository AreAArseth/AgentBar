import Cocoa

/// The rules list in **Settings ▸ Approvals**: what you told AgentBar to answer
/// for you, and what each one has actually done.
///
/// Two things it insists on. A rule's line always carries **what it has done**, not
/// only what it says — an approving rule that has fired forty times is a different
/// object from one that has never fired, and the difference belongs on the same
/// line as the rule. And a rules file that will not parse is shown as exactly that:
/// a refusal, in red, with no rules listed under it, because none are in force.
///
/// Its own file rather than another method on `SettingsWindow`, for the reason
/// `DiagnosticsView` is: a section that builds a variable number of subviews and
/// re-lays itself out is not a checkbox.
final class RulesView: NSView {
    /// Fired when the row count changed, so the window can re-fit — both ways.
    var onResize: (() -> Void)?
    /// The person asked for a new rule. The sheet belongs to the window, not here.
    var onNew: (() -> Void)?

    /// Beyond this the window runs off the bottom of the screen — and every page
    /// is sized to the tallest one, so a long list here makes Notifications tall
    /// too. Same cap Diagnostics uses, for the same reason; the file is where a
    /// long list lives and the last row says so.
    private static let maxRows = 4
    private static let textWidth = SettingsWindow.minWidth - 58

    private let summary = NSTextField(labelWithString: "")
    private let rows = NSStackView()
    private var rules: [RulesStore.Rule] = []

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        summary.font = .systemFont(ofSize: 11)
        summary.lineBreakMode = .byTruncatingTail

        let add = NSButton(title: "New rule…", target: self, action: #selector(newRule))
        add.bezelStyle = .rounded
        add.controlSize = .small
        add.font = .systemFont(ofSize: 11)
        add.toolTip = "A rule answers a prompt the way you would have. It never widens itself."

        let reveal = NSButton(title: "Show file", target: self, action: #selector(revealFile))
        reveal.bezelStyle = .rounded
        reveal.controlSize = .small
        reveal.font = .systemFont(ofSize: 11)
        reveal.toolTip = "~/.agentbar/rules.json — plain JSON, yours to edit."

        let header = NSStackView(views: [summary, NSView(), reveal, add])
        header.orientation = .horizontal
        header.spacing = 6
        header.alignment = .centerY

        rows.orientation = .vertical
        rows.alignment = .leading
        rows.spacing = 8

        let stack = NSStackView(views: [header, rows])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            header.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
        reload()
    }

    required init?(coder: NSCoder) { nil }

    // MARK: - Contents

    func reload() {
        for v in rows.arrangedSubviews { v.removeFromSuperview() }
        switch RulesStore.load() {
        case .none:
            rules = []
            summary.stringValue = "No rules yet"
            summary.textColor = .secondaryLabelColor
            rows.addArrangedSubview(note(
                "Until you write one, every prompt comes to you. That is the default and "
                + "it stays the default.", colour: .secondaryLabelColor))
        case .invalid(let why):
            rules = []
            summary.stringValue = "No rules are in force"
            summary.textColor = .systemRed
            rows.addArrangedSubview(note(why, colour: .systemRed))
            rows.addArrangedSubview(note(
                "Nothing in the file is applied while any of it is wrong — a policy half in "
                + "force is worse than none. Fix the file, or move it aside.",
                colour: .secondaryLabelColor))
        case .rules(let list):
            rules = list
            summary.stringValue = summaryLine(list)
            summary.textColor = .secondaryLabelColor
            let ledger = DecisionLedger.cached()
            for rule in list.prefix(Self.maxRows) {
                rows.addArrangedSubview(row(rule, ledger: ledger))
            }
            if list.count > Self.maxRows {
                rows.addArrangedSubview(note(
                    "\(list.count - Self.maxRows) more in ~/.agentbar/rules.json.",
                    colour: .secondaryLabelColor))
            }
        }
        onResize?()
    }

    private func summaryLine(_ list: [RulesStore.Rule]) -> String {
        guard !list.isEmpty else { return "No rules yet" }
        let allows = list.filter(\.isAllow).count
        let denies = list.count - allows
        var parts: [String] = []
        if allows > 0 { parts.append("\(allows) say\(allows == 1 ? "s" : "") yes") }
        if denies > 0 { parts.append("\(denies) say\(denies == 1 ? "s" : "") no") }
        return "\(list.count) rule\(list.count == 1 ? "" : "s") · " + parts.joined(separator: ", ")
    }

    private func note(_ text: String, colour: NSColor) -> NSView {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: 11)
        label.textColor = colour
        label.preferredMaxLayoutWidth = Self.textWidth
        label.widthAnchor.constraint(equalToConstant: Self.textWidth).isActive = true
        return label
    }

    /// One rule: a switch, what it does, and what it has done.
    private func row(_ rule: RulesStore.Rule, ledger: [DecisionLedger.Record]) -> NSView {
        let box = NSButton(checkboxWithTitle: "", target: self, action: #selector(toggleRule(_:)))
        box.state = rule.enabled ? .on : .off
        box.identifier = NSUserInterfaceItemIdentifier(rule.id)
        box.toolTip = rule.enabled ? "Switch this rule off without deleting it"
                                   : "Switched off — it answers nothing"

        // A switched-off rule is drawn as switched off — greyed through, not merely
        // an unticked box somebody has to find. It is still listed, because the
        // point of the switch is that it does not delete anything.
        let verb = NSTextField(labelWithString: rule.isAllow ? "Allow" : "Deny")
        verb.font = .systemFont(ofSize: 11.5, weight: .semibold)
        verb.textColor = rule.enabled ? (rule.isAllow ? .systemGreen : .systemRed)
                                      : .tertiaryLabelColor

        let what = NSTextField(labelWithString: Self.readable(rule.shape))
        what.font = .monospacedSystemFont(ofSize: 11.5, weight: .regular)
        what.textColor = rule.enabled ? .labelColor : .tertiaryLabelColor
        what.lineBreakMode = .byTruncatingTail

        let wherE = NSTextField(labelWithString: rule.cwd.isEmpty
                                ? "everywhere"
                                : "in " + (rule.cwd as NSString).lastPathComponent)
        wherE.font = .systemFont(ofSize: 11.5)
        wherE.textColor = rule.enabled ? .secondaryLabelColor : .tertiaryLabelColor
        wherE.toolTip = rule.cwd.isEmpty ? "Any directory — only a denial may say this" : rule.cwd

        let remove = NSButton(title: "Remove", target: self, action: #selector(removeRule(_:)))
        remove.bezelStyle = .inline
        remove.controlSize = .small
        remove.font = .systemFont(ofSize: 10.5)
        remove.identifier = NSUserInterfaceItemIdentifier(rule.id)

        let top = NSStackView(views: [box, verb, what, wherE, NSView(), remove])
        top.orientation = .horizontal
        top.spacing = 6
        top.alignment = .firstBaseline

        // What it has actually done, from the ledger — never from a counter in the
        // rules file. The intent lives in one place and the record in another, and
        // this line is the only place they meet.
        let fired = DecisionLedger.firings(rule: rule.id, in: ledger)
        var trail = rule.enabled ? DecisionLedger.firingLine(fired)
                                 : "Switched off" + (fired.isEmpty ? "" : " · " + DecisionLedger.firingLine(fired))
        if !rule.note.isEmpty { trail += " · " + rule.note }
        let detail = NSTextField(labelWithString: trail)
        detail.font = .systemFont(ofSize: 10.5)
        detail.textColor = fired.isEmpty ? .tertiaryLabelColor : .secondaryLabelColor
        detail.lineBreakMode = .byTruncatingTail

        let stack = NSStackView(views: [top, detail])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 2
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.widthAnchor.constraint(equalToConstant: Self.textWidth).isActive = true
        top.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        return stack
    }

    /// `bash:git push` reads as `git push`; `edit:Sources/*.swift` keeps its prefix
    /// because "edit" is the half that says what happens.
    static func readable(_ shape: String) -> String {
        guard let colon = shape.firstIndex(of: ":") else { return shape }
        let kind = String(shape[shape.startIndex..<colon])
        let rest = String(shape[shape.index(after: colon)...])
        return kind == "bash" ? rest : "\(kind) \(rest)"
    }

    // MARK: - Actions

    @objc private func newRule() { onNew?() }

    @objc private func revealFile() {
        let url = RulesStore.fileURL
        if !FileManager.default.fileExists(atPath: url.path) {
            RulesStore.save(rules, to: url)
        }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    @objc private func toggleRule(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue,
              let i = rules.firstIndex(where: { $0.id == id }) else { return }
        rules[i].enabled = sender.state == .on
        RulesStore.save(rules)
        reload()
    }

    @objc private func removeRule(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue,
              let rule = rules.first(where: { $0.id == id }) else { return }
        // Removing a rule is not destructive in the way deleting work is, but it is
        // silent otherwise: the prompts simply start coming back, and a week later
        // nobody remembers why. One confirmation, naming the rule.
        let alert = NSAlert()
        alert.messageText = "Remove this rule?"
        alert.informativeText = "\(rule.isAllow ? "Allow" : "Deny") \(Self.readable(rule.shape))"
            + (rule.cwd.isEmpty ? "" : " in " + (rule.cwd as NSString).lastPathComponent)
            + ".\n\nThe prompts it was answering will come back to you. What it already "
            + "did stays in the approval history."
        alert.addButton(withTitle: "Remove")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        rules.removeAll { $0.id == id }
        RulesStore.save(rules)
        reload()
    }
}
