import Cocoa

/// The sheet that writes one rule.
///
/// Its real job is not collecting three fields — it is **showing what the rule will
/// not do** before the person commits to it. A rule is matched by the ledger's
/// `shape`, which carries no arguments, so "allow `git push`" is a sentence whose
/// edges are not obvious. The block at the bottom of this sheet is those edges, in
/// the rule's own terms, and it changes as the rule does.
///
/// Summoned by a click and gone when it is answered — the same test the launcher
/// and the banners pass.
final class RuleSheet: NSObject {
    struct Prefill {
        var decision = "allow"
        var shape = ""
        var cwd = ""
        /// What the request said, so the sheet can show the person the exact line
        /// they were looking at rather than only its shape.
        var display = ""
    }

    private let sheet = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 340),
                                 styleMask: [.titled], backing: .buffered, defer: false)
    private let kind = NSSegmentedControl(labels: ["Allow", "Deny"], trackingMode: .selectOne,
                                          target: nil, action: nil)
    private let shape = NSComboBox()
    private let place = NSPopUpButton()
    private let note = NSTextField()
    private let consequence = NSTextField(wrappingLabelWithString: "")
    private var directories: [String] = []
    private var done: ((RulesStore.Rule?) -> Void)?
    /// Retained for the life of the sheet; released when it closes.
    private static var open: RuleSheet?

    static func present(on parent: NSWindow, prefill: Prefill = Prefill(),
                        done: @escaping (RulesStore.Rule?) -> Void) {
        let s = RuleSheet(prefill: prefill, done: done)
        open = s
        parent.beginSheet(s.sheet) { _ in open = nil }
    }

    private init(prefill: Prefill, done: @escaping (RulesStore.Rule?) -> Void) {
        self.done = done
        super.init()

        let title = NSTextField(labelWithString: "A rule answers for you")
        title.font = .systemFont(ofSize: 15, weight: .semibold)

        let blurb = NSTextField(wrappingLabelWithString:
            prefill.display.isEmpty
            ? "AgentBar answers nothing by itself. It answers what you write down here, "
              + "and every time it does, the approval history says so."
            : "From “\(prefill.display)”. AgentBar will answer prompts of this shape the "
              + "way you say here, and the approval history will name this rule each time.")
        blurb.font = .systemFont(ofSize: 11.5)
        blurb.textColor = .secondaryLabelColor
        blurb.preferredMaxLayoutWidth = 420

        kind.target = self
        kind.action = #selector(changed)
        kind.selectedSegment = prefill.decision == "deny" ? 1 : 0

        shape.isEditable = true
        shape.completes = true
        shape.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        shape.delegate = self
        shape.addItems(withObjectValues: Self.knownShapes())
        shape.stringValue = prefill.shape
        shape.placeholderString = "git status"

        directories = Self.knownDirectories(including: prefill.cwd)
        place.target = self
        place.action = #selector(changed)
        rebuildPlaces(selecting: prefill.cwd)

        note.placeholderString = "Why (optional)"
        note.font = .systemFont(ofSize: 12)

        consequence.font = .systemFont(ofSize: 11)
        consequence.textColor = .secondaryLabelColor
        consequence.preferredMaxLayoutWidth = 420

        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancel))
        cancel.bezelStyle = .rounded
        cancel.keyEquivalent = "\u{1b}"
        let add = NSButton(title: "Add rule", target: self, action: #selector(commit))
        add.bezelStyle = .rounded
        add.keyEquivalent = "\r"

        let buttons = NSStackView(views: [NSView(), cancel, add])
        buttons.orientation = .horizontal
        buttons.spacing = 10

        let form = NSStackView(views: [
            title, blurb,
            labelled("Answer", kind), labelled("When", shape), labelled("In", place),
            labelled("Note", note),
            separator(), consequence, buttons,
        ])
        form.orientation = .vertical
        form.alignment = .leading
        form.spacing = 10
        form.translatesAutoresizingMaskIntoConstraints = false
        form.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)

        let content = NSView()
        content.addSubview(form)
        NSLayoutConstraint.activate([
            form.topAnchor.constraint(equalTo: content.topAnchor),
            form.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            form.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            form.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            blurb.widthAnchor.constraint(equalToConstant: 420),
            consequence.widthAnchor.constraint(equalToConstant: 420),
            buttons.widthAnchor.constraint(equalToConstant: 420),
        ])
        sheet.contentView = content
        sheet.contentMinSize = NSSize(width: 460, height: 300)
        refresh()
    }

    private func labelled(_ text: String, _ control: NSView) -> NSView {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 12)
        label.textColor = .secondaryLabelColor
        label.alignment = .right
        label.widthAnchor.constraint(equalToConstant: 56).isActive = true
        let row = NSStackView(views: [label, control])
        row.orientation = .horizontal
        row.alignment = .firstBaseline
        row.spacing = 10
        control.widthAnchor.constraint(equalToConstant: 354).isActive = true
        return row
    }

    private func separator() -> NSView {
        let line = NSBox()
        line.boxType = .separator
        line.widthAnchor.constraint(equalToConstant: 420).isActive = true
        return line
    }

    // MARK: - The two lists it offers

    /// Shapes this person has actually decided about, newest first. A rule for
    /// something you have never been asked is a rule for a prompt that may never
    /// come; the free-text field is still there for when it is.
    static func knownShapes(in records: [DecisionLedger.Record] = DecisionLedger.cached()) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for r in records.reversed() where !r.shape.isEmpty && seen.insert(r.shape).inserted {
            out.append(r.shape)
        }
        return out
    }

    /// Directories AgentBar has seen work happen in. The ledger first, then the
    /// session history, because a directory you decided something in is a better
    /// guess than one you merely worked in.
    static func knownDirectories(including first: String = "",
                                 decisions: [DecisionLedger.Record] = DecisionLedger.cached(),
                                 history: [HistoryStore.Record] = HistoryStore.cached()) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for cwd in [first] + decisions.reversed().map(\.cwd) + history.reversed().map(\.cwd)
        where !cwd.isEmpty && seen.insert(cwd).inserted {
            out.append(cwd)
        }
        return out
    }

    private func rebuildPlaces(selecting cwd: String) {
        place.removeAllItems()
        for dir in directories {
            place.addItem(withTitle: (dir as NSString).lastPathComponent)
            place.lastItem?.toolTip = dir
            place.lastItem?.representedObject = dir
        }
        if isDeny {
            place.addItem(withTitle: "Any directory")
            place.lastItem?.representedObject = ""
        }
        place.menu?.addItem(.separator())
        place.addItem(withTitle: "Choose…")
        place.lastItem?.representedObject = "choose"
        if let i = directories.firstIndex(of: cwd) { place.selectItem(at: i) }
    }

    private var isDeny: Bool { kind.selectedSegment == 1 }

    private var selectedDirectory: String {
        (place.selectedItem?.representedObject as? String) ?? ""
    }

    // MARK: - Keeping the consequence honest

    @objc private func changed() {
        if selectedDirectory == "choose" {
            chooseDirectory()
            return
        }
        // "Any directory" exists only for a denial; switching to Allow must not
        // leave it selected and quietly mean something it is not allowed to mean.
        let keep = selectedDirectory == "choose" ? "" : selectedDirectory
        rebuildPlaces(selecting: keep)
        refresh()
    }

    private func chooseDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Use this directory"
        panel.beginSheetModal(for: sheet) { [weak self] response in
            guard let self else { return }
            if response == .OK, let url = panel.url {
                if !directories.contains(url.path) { directories.insert(url.path, at: 0) }
                rebuildPlaces(selecting: url.path)
            } else {
                rebuildPlaces(selecting: directories.first ?? "")
            }
            refresh()
        }
    }

    private func refresh() {
        let what = RulesView.readable(shape.stringValue.trimmingCharacters(in: .whitespaces))
        let subject = what.isEmpty ? "this" : "`\(what)`"
        let dir = selectedDirectory
        let here = dir.isEmpty ? "anywhere" : "in " + (dir as NSString).lastPathComponent
        if isDeny {
            consequence.stringValue =
                "Refuses \(subject) \(here), every time, without asking. A refusal is never "
                + "narrowed and never needs to be — the worst it can cost you is a prompt you "
                + "have to answer somewhere else."
            consequence.textColor = .secondaryLabelColor
        } else {
            consequence.stringValue =
                "Answers \(subject) \(here) the moment it is asked.\n\n"
                + "It will never answer more than one command on a line, anything piped, "
                + "redirected or substituted, anything run through sudo, a destructive git or "
                + "rm, anything that reaches off this Mac, a path outside "
                + "\(dir.isEmpty ? "that directory" : (dir as NSString).lastPathComponent)"
                + ", or anything that configures permission itself. Those always come back to "
                + "you, and no setting turns that off."
            consequence.textColor = .labelColor
        }
    }

    // MARK: - Leaving

    @objc private func cancel() {
        done?(nil)
        finish()
    }

    @objc private func commit() {
        let text = shape.stringValue.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { complain("A rule needs something to match.",
                                            "Pick a prompt you have answered before, or type "
                                            + "one — `git status`, `npm test`.") ; return }
        // `git status` typed in the field means the shape `bash:git status`; a
        // shape that already names its kind is taken as written.
        let normalised = text.contains(":") ? text : "bash:" + DecisionLedger.verb(of: text)
        let dir = selectedDirectory == "choose" ? "" : selectedDirectory
        var rule = RulesStore.Rule(id: RulesStore.newID(), decision: isDeny ? "deny" : "allow",
                                   shape: normalised, cwd: dir,
                                   note: note.stringValue.trimmingCharacters(in: .whitespaces))
        // The same validation the file gets, before the file gets it — a rule that
        // would refuse the whole file on the next launch must not be written now.
        if let why = RulesStore.validate(rule, index: 0, seen: []) {
            complain("That rule cannot be saved.",
                     why.replacingOccurrences(of: "Rule 1 (\(rule.id)) in ~/.agentbar/rules.json",
                                              with: "This rule"))
            return
        }
        rule.created = Date().timeIntervalSince1970
        done?(rule)
        finish()
    }

    private func complain(_ message: String, _ detail: String) {
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = detail
        alert.beginSheetModal(for: sheet)
    }

    private func finish() {
        done = nil
        sheet.sheetParent?.endSheet(sheet)
    }
}

extension RuleSheet: NSComboBoxDelegate {
    func comboBoxSelectionDidChange(_ notification: Notification) {
        DispatchQueue.main.async { [weak self] in self?.refresh() }
    }

    func controlTextDidChange(_ obj: Notification) { refresh() }
}
