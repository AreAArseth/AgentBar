import Cocoa

/// The Diagnostics section of the Settings window: what `Diagnostics` found, and
/// the button that copies all of it for a bug report.
///
/// It shows **only what needs attention**. Twenty-five green rows is a wall to
/// read through for the one line that matters, and a status app that fills a
/// window with reassurance is doing the opposite of staying out of the way. When
/// everything passes it says so in one line; the copied report always carries
/// every check, because that is the thing someone else has to read.
///
/// Its own file rather than another method on `SettingsWindow` for the same reason
/// `DisplayPicker` is: a section that builds a variable number of subviews and
/// re-lays itself out is not a checkbox.
final class DiagnosticsView: NSView {
    /// Fired when the row count changed, so the window can re-fit. Both ways —
    /// growing *and* shrinking; a section that only re-fits when it gets bigger
    /// leaves a hole under it when it gets smaller.
    var onResize: (() -> Void)?

    /// More than this and the window runs off the bottom of the screen. The rest are
    /// in the report, which is where a long list belongs anyway.
    private static let maxRows = 4
    /// Matches the Settings window's content width less its insets and the row's own
    /// bullet gutter, so a fix wraps once rather than becoming a paragraph.
    private static let textWidth = SettingsWindow.minWidth - 58

    private let rows = NSStackView()
    private let summary = NSTextField(labelWithString: "")
    private let copyButton = NSButton(title: "Copy report", target: nil, action: nil)
    private var checks: [Diagnostics.Check] = []
    private var running = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        summary.font = .systemFont(ofSize: 11)
        summary.lineBreakMode = .byTruncatingTail

        copyButton.target = self
        copyButton.action = #selector(copyReport)
        copyButton.bezelStyle = .rounded
        copyButton.controlSize = .small
        copyButton.font = .systemFont(ofSize: 11)
        copyButton.toolTip = "Copy every check, passing ones included — this is what to paste into an issue."

        let recheck = NSButton(title: "Re-check", target: self, action: #selector(refresh))
        recheck.bezelStyle = .rounded
        recheck.controlSize = .small
        recheck.font = .systemFont(ofSize: 11)

        let header = NSStackView(views: [summary, NSView(), recheck, copyButton])
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
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Re-runs the checks. Off the main thread: the node probe shells out to the
    /// login shell on a version-manager setup, which is hundreds of milliseconds,
    /// and a Settings window that hangs while opening is its own bug report.
    @objc func refresh() {
        guard !running else { return }
        running = true
        summary.stringValue = "Checking…"
        summary.textColor = .secondaryLabelColor
        copyButton.isEnabled = false
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let found = Diagnostics.run()
            DispatchQueue.main.async {
                guard let self else { return }
                self.running = false
                self.copyButton.isEnabled = true
                self.apply(found)
            }
        }
    }

    private func apply(_ found: [Diagnostics.Check]) {
        checks = found
        rows.arrangedSubviews.forEach { $0.removeFromSuperview() }

        let failed = found.filter { $0.status == .fail }
        let warned = found.filter { $0.status == .warn }
        let attention = failed + warned

        if attention.isEmpty {
            summary.stringValue = "\(found.count) checks, nothing wrong."
            summary.textColor = .secondaryLabelColor
        } else {
            var parts: [String] = []
            if !failed.isEmpty { parts.append("\(failed.count) broken") }
            if !warned.isEmpty { parts.append("\(warned.count) worth a look") }
            summary.stringValue = parts.joined(separator: " · ")
            summary.textColor = failed.isEmpty ? .secondaryLabelColor : .systemRed
        }

        for check in attention.prefix(Self.maxRows) { rows.addArrangedSubview(row(check)) }
        if attention.count > Self.maxRows {
            let more = NSTextField(labelWithString:
                "…and \(attention.count - Self.maxRows) more — they are all in the copied report.")
            more.font = .systemFont(ofSize: 11)
            more.textColor = .tertiaryLabelColor
            rows.addArrangedSubview(more)
        }
        onResize?()
    }

    private func row(_ check: Diagnostics.Check) -> NSView {
        let dot = NSTextField(labelWithString: check.status == .fail ? "✕" : "!")
        dot.font = .systemFont(ofSize: 11, weight: .bold)
        dot.textColor = check.status == .fail ? .systemRed : .systemOrange
        dot.widthAnchor.constraint(equalToConstant: 12).isActive = true

        let title = NSTextField(labelWithString: check.title)
        title.font = .systemFont(ofSize: 11, weight: .medium)

        var lines = [title]
        // The detail says what is wrong; the fix says what to do. Both, or the row
        // is just a nicer way of saying "something is broken".
        for (text, color) in [(check.detail, NSColor.secondaryLabelColor),
                              (check.fix.map { "→ \($0)" }, NSColor.tertiaryLabelColor)] {
            guard let text else { continue }
            let label = NSTextField(wrappingLabelWithString: text)
            label.font = .systemFont(ofSize: 10)
            label.textColor = color
            label.preferredMaxLayoutWidth = Self.textWidth
            lines.append(label)
        }

        let text = NSStackView(views: lines)
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 2

        let row = NSStackView(views: [dot, text])
        row.orientation = .horizontal
        row.alignment = .firstBaseline
        row.spacing = 6
        return row
    }

    @objc private func copyReport() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(Diagnostics.report(checks), forType: .string)
        let was = copyButton.title
        copyButton.title = "Copied"
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak copyButton] in
            copyButton?.title = was
        }
    }
}
