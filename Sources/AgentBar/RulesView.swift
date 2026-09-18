import Cocoa

/// The rules list in **Settings ▸ Rules**: what you told AgentBar to answer for
/// you, whether it is answering yet, and what it has actually done.
///
/// Three things it insists on. A rule's line always carries **what it has done**,
/// not only what it says — a rule that has fired forty times is a different object
/// from one that has never fired, and the difference belongs on the same line. The
/// **mode** is a control on that line rather than a checkbox somewhere else,
/// because "watching" is a state somebody has to be able to see at a glance and get
/// out of. And a rules file that will not parse is shown as exactly that: a
/// refusal, in red, with no rules listed under it, because none are in force.
///
/// Its own file rather than another method on `SettingsWindow`, for the reason
/// `DiagnosticsView` is: a section that builds a variable number of subviews and
/// re-lays itself out is not a checkbox.
final class RulesView: NSView {
    /// Fired when the row count changed, so the window can re-fit — both ways.
    var onResize: (() -> Void)?
    /// The person asked for a new rule, or to change one. The sheet belongs to the
    /// window, not here.
    var onNew: (() -> Void)?
    var onEdit: ((RulesStore.Rule) -> Void)?

    /// Beyond this the window runs off the bottom of the screen — and every page is
    /// sized to the tallest one. Same cap `DiagnosticsView` uses; the file is where
    /// a long list lives, and the last row says so.
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
        rows.spacing = 10

        let stack = NSStackView(views: [header, rows])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
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
        let counts = RulesStore.Rule.Mode.allCases.compactMap { mode -> String? in
            let n = list.filter { $0.mode == mode }.count
            return n > 0 ? "\(n) \(mode.title.lowercased())" : nil
        }
        return "\(list.count) rule\(list.count == 1 ? "" : "s") · " + counts.joined(separator: ", ")
    }

    private func note(_ text: String, colour: NSColor) -> NSView {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: 11)
        label.textColor = colour
        label.preferredMaxLayoutWidth = Self.textWidth
        label.widthAnchor.constraint(equalToConstant: Self.textWidth).isActive = true
        return label
    }

    /// One rule: what it does, whether it is doing it, and what it has done.
    private func row(_ rule: RulesStore.Rule, ledger: [DecisionLedger.Record]) -> NSView {
        let live = rule.mode != .off
        let verb = NSTextField(labelWithString: rule.isAllow ? "Allow" : "Deny")
        verb.font = .systemFont(ofSize: 11.5, weight: .semibold)
        verb.textColor = live ? (rule.isAllow ? .systemGreen : .systemRed) : .tertiaryLabelColor

        let what = NSTextField(labelWithString: Self.readable(rule.shape))
        what.font = .monospacedSystemFont(ofSize: 11.5, weight: .regular)
        what.textColor = live ? .labelColor : .tertiaryLabelColor
        what.lineBreakMode = .byTruncatingTail

        let wherever = NSTextField(labelWithString: rule.cwd.isEmpty
                                   ? "everywhere"
                                   : "in " + (rule.cwd as NSString).lastPathComponent)
        wherever.font = .systemFont(ofSize: 11.5)
        wherever.textColor = live ? .secondaryLabelColor : .tertiaryLabelColor
        wherever.toolTip = rule.cwd.isEmpty ? "Any directory — only a denial may say this" : rule.cwd

        // The mode sits on the rule's own line, because "watching" is a state
        // somebody has to be able to see without opening anything.
        let mode = NSPopUpButton()
        mode.controlSize = .small
        mode.font = .systemFont(ofSize: 11)
        mode.identifier = NSUserInterfaceItemIdentifier(rule.id)
        mode.target = self
        mode.action = #selector(changeMode(_:))
        for m in RulesStore.Rule.Mode.allCases {
            mode.addItem(withTitle: m.title)
            mode.lastItem?.representedObject = m.rawValue
            mode.lastItem?.toolTip = m.explanation
        }
        mode.selectItem(at: RulesStore.Rule.Mode.allCases.firstIndex(of: rule.mode) ?? 0)
        mode.toolTip = rule.mode.explanation

        let top = NSStackView(views: [verb, what, wherever, NSView(), mode])
        top.orientation = .horizontal
        top.spacing = 6
        top.alignment = .centerY

        // What it has done — or, while it is watching, what it would have done.
        // Read from the ledger, never from a counter inside the rules file: intent
        // lives in one place and the record in another, and this line is the only
        // place the two meet.
        let watching = rule.mode == .watch
        let counts = watching ? DecisionLedger.wouldHave(rule: rule.id, in: ledger)
                              : DecisionLedger.firings(rule: rule.id, in: ledger)
        var trail = DecisionLedger.firingLine(counts, wouldHave: watching)
        if !rule.note.isEmpty { trail += " · " + rule.note }
        let detail = NSTextField(labelWithString: trail)
        detail.font = .systemFont(ofSize: 10.5)
        detail.textColor = counts.isEmpty ? .tertiaryLabelColor : .secondaryLabelColor
        detail.lineBreakMode = .byTruncatingTail

        let edit = inline("Edit", #selector(editRule(_:)), rule.id)
        let remove = inline("Remove", #selector(removeRule(_:)), rule.id)
        let bottom = NSStackView(views: [detail, NSView(), edit, remove])
        bottom.orientation = .horizontal
        bottom.spacing = 8
        bottom.alignment = .centerY

        let stack = NSStackView(views: [top, bottom])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 2
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.widthAnchor.constraint(equalToConstant: Self.textWidth).isActive = true
        top.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        bottom.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        return stack
    }

    private func inline(_ title: String, _ action: Selector, _ id: String) -> NSButton {
        let b = NSButton(title: title, target: self, action: action)
        b.bezelStyle = .inline
        b.controlSize = .small
        b.font = .systemFont(ofSize: 10.5)
        b.identifier = NSUserInterfaceItemIdentifier(id)
        return b
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

    @objc private func editRule(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue,
              let rule = rules.first(where: { $0.id == id }) else { return }
        onEdit?(rule)
    }

    @objc private func revealFile() {
        let url = RulesStore.fileURL
        if !FileManager.default.fileExists(atPath: url.path) {
            RulesStore.save(rules, to: url)
        }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    @objc private func changeMode(_ sender: NSPopUpButton) {
        guard let id = sender.identifier?.rawValue,
              let i = rules.firstIndex(where: { $0.id == id }),
              let raw = sender.selectedItem?.representedObject as? String,
              let mode = RulesStore.Rule.Mode(rawValue: raw) else { return }
        rules[i].mode = mode
        RulesStore.save(rules)
        reload()
    }

    @objc private func removeRule(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue,
              let rule = rules.first(where: { $0.id == id }) else { return }
        // Removing a rule is not destructive the way deleting work is, but it is
        // silent otherwise: the prompts simply start coming back, and a week later
        // nobody remembers why. One confirmation, naming the rule — and it says
        // that switching it off is the other option.
        let alert = NSAlert()
        alert.messageText = "Remove this rule?"
        alert.informativeText = "\(rule.isAllow ? "Allow" : "Deny") \(Self.readable(rule.shape))"
            + (rule.cwd.isEmpty ? "" : " in " + (rule.cwd as NSString).lastPathComponent)
            + ".\n\nThe prompts it was answering will come back to you. What it already "
            + "did stays in the approval history. If you only want it to stop for now, "
            + "set it to Off instead."
        alert.addButton(withTitle: "Remove")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        rules.removeAll { $0.id == id }
        RulesStore.save(rules)
        reload()
    }
}
