import Cocoa

/// The furniture the Settings window is built from: a sidebar, grouped cards, and
/// rows that put a label on the left and its control on the right.
///
/// It exists because the old window was one long scroll of checkboxes and
/// paragraphs. That shape has two faults and they compound: everything is visible
/// at once, so nothing is findable; and every explanation is a wall of text under
/// its switch, so the window grows until Diagnostics is somewhere off the bottom
/// of the screen. Seven sections down a page is a document. Seven sections in a
/// sidebar is a window.
///
/// Nothing here knows what a setting *is* — it lays out rows and returns views.
/// `SettingsWindow` owns every control, every default and every side effect, the
/// way it always has.
enum SettingsChrome {
    /// One scale, used everywhere. Spacing invented per view is what makes a
    /// window look assembled rather than designed: the first cut had 9, 10, 12,
    /// 14, 16 and 20 in it, all of them a judgement call made once and forgotten.
    enum Space {
        static let hair: CGFloat = 4
        static let tight: CGFloat = 8
        static let step: CGFloat = 12
        static let gap: CGFloat = 16
        static let page: CGFloat = 24
    }

    static let sidebarWidth: CGFloat = 196
    static let contentWidth: CGFloat = 520
    static let cardRadius: CGFloat = 10
    static let rowInset: CGFloat = Space.gap
    /// Two lines of label and a control, with the same air above and below.
    static let rowHeight: CGFloat = 52
    /// A floor, not the size: `SettingsWindow` measures the tallest page and uses
    /// that, so no page opens with a field of empty grey under it.
    static let minWindowHeight: CGFloat = 320
    static let maxWindowHeight: CGFloat = 640

    // MARK: - Cards

    /// A group of rows on one rounded panel, hairlines between them. The panel is
    /// what turns "nine controls" into "three groups of three", which is the only
    /// reason anyone can find anything in a settings window.
    static func card(_ rows: [NSView]) -> NSView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false
        for (i, row) in rows.enumerated() {
            if i > 0 { stack.addArrangedSubview(hairline()) }
            stack.addArrangedSubview(row)
        }

        let panel = NSView()
        panel.wantsLayer = true
        panel.layer?.cornerRadius = cardRadius
        // A filled group rather than an outlined box, and a fill that is defined
        // against the label colour so it holds up in both appearances instead of
        // being a light-mode guess.
        panel.layer?.backgroundColor = NSColor.quaternaryLabelColor
            .withAlphaComponent(0.07).cgColor
        panel.translatesAutoresizingMaskIntoConstraints = false
        panel.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: panel.topAnchor),
            stack.bottomAnchor.constraint(equalTo: panel.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: panel.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: panel.trailingAnchor),
        ])
        for row in stack.arrangedSubviews {
            row.widthAnchor.constraint(equalTo: panel.widthAnchor).isActive = true
        }
        return panel
    }

    /// A label, an optional line of explanation under it, and a control on the
    /// right. The explanation is one sentence: anything longer belongs in the
    /// README, and the old window proved that nobody reads four lines of it under
    /// a checkbox anyway.
    static func row(_ title: String, _ subtitle: String? = nil,
                    control: NSView? = nil, accessory: NSView? = nil) -> NSView {
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 13.5, weight: .regular)
        label.lineBreakMode = .byTruncatingTail

        let text = NSStackView(views: [label])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 3
        if let subtitle, !subtitle.isEmpty {
            text.addArrangedSubview(caption(subtitle))
        }
        text.setContentHuggingPriority(.defaultLow, for: .horizontal)

        var views: [NSView] = [text]
        if let accessory { views.append(accessory) }
        if let control {
            // An explicit spacer, not hugging priorities: two rows built from the
            // same code came out with one control its own size and the next one
            // stretched across the row, because a stack hands leftover space to
            // whichever view lets it. A spacer takes the leftover instead.
            let spacer = NSView()
            spacer.setContentHuggingPriority(.init(1), for: .horizontal)
            spacer.setContentCompressionResistancePriority(.init(1), for: .horizontal)
            views.append(spacer)
            control.setContentHuggingPriority(.required, for: .horizontal)
            control.setContentCompressionResistancePriority(.required, for: .horizontal)
            views.append(control)
        }
        let row = NSStackView(views: views)
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = Space.step
        row.edgeInsets = NSEdgeInsets(top: Space.step, left: rowInset,
                                      bottom: Space.step, right: rowInset)
        row.translatesAutoresizingMaskIntoConstraints = false
        row.heightAnchor.constraint(greaterThanOrEqualToConstant: rowHeight).isActive = true
        return row
    }

    /// A row that is all text: a status sentence, or a note. It wraps, and it
    /// states the width it wraps at — a label that doesn't is how the old window
    /// came to be nineteen hundred points wide.
    static func noteRow(_ label: NSTextField) -> NSView {
        label.preferredMaxLayoutWidth = contentWidth - Space.page * 2 - rowInset * 2
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let row = NSStackView(views: [label])
        row.orientation = .horizontal
        row.alignment = .top
        row.edgeInsets = NSEdgeInsets(top: Space.step, left: rowInset,
                                      bottom: Space.step, right: rowInset)
        row.translatesAutoresizingMaskIntoConstraints = false
        label.widthAnchor.constraint(equalTo: row.widthAnchor,
                                     constant: -rowInset * 2).isActive = true
        return row
    }

    /// A row holding whatever it is given, at the row's own margins — buttons, a
    /// slider, the diagnostics table.
    static func customRow(_ view: NSView, height: CGFloat? = nil) -> NSView {
        let row = NSStackView(views: [view])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.edgeInsets = NSEdgeInsets(top: Space.step, left: rowInset,
                                      bottom: Space.step, right: rowInset)
        row.translatesAutoresizingMaskIntoConstraints = false
        // Whatever it holds spans the row, so a slider or a button strip lines up
        // with the labels above it instead of floating at its own natural width.
        view.widthAnchor.constraint(equalTo: row.widthAnchor,
                                    constant: -rowInset * 2).isActive = true
        if let height {
            row.heightAnchor.constraint(greaterThanOrEqualToConstant: height).isActive = true
        }
        return row
    }

    // MARK: - Pieces

    static func toggle(target: AnyObject, action: Selector) -> NSSwitch {
        let s = NSSwitch()
        s.target = target
        s.action = action
        s.controlSize = .small
        return s
    }

    static func header(_ text: String) -> NSTextField {
        let l = NSTextField(wrappingLabelWithString: text)
        l.preferredMaxLayoutWidth = contentWidth - Space.page * 2
        l.font = .systemFont(ofSize: 11)
        l.textColor = .secondaryLabelColor
        return l
    }

    static func title(_ text: String) -> NSTextField {
        let l = NSTextField(labelWithString: text)
        l.font = .systemFont(ofSize: 19, weight: .semibold)
        return l
    }

    static func caption(_ text: String) -> NSTextField {
        let l = NSTextField(wrappingLabelWithString: text)
        l.font = .systemFont(ofSize: 11.5)
        l.textColor = .secondaryLabelColor
        l.preferredMaxLayoutWidth = contentWidth - Space.page * 2 - rowInset * 2 - 60
        l.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return l
    }

    static func smallButton(_ title: String, target: AnyObject, action: Selector) -> NSButton {
        let b = NSButton(title: title, target: target, action: action)
        b.bezelStyle = .rounded
        b.controlSize = .small
        b.font = .systemFont(ofSize: 11)
        return b
    }

    /// Inset from the left, the way a grouped list's separators are. One that
    /// runs the full width cuts the card in two and the rows stop reading as one
    /// group.
    private static func hairline() -> NSView {
        let line = NSView()
        line.wantsLayer = true
        line.layer?.backgroundColor = NSColor.separatorColor.withAlphaComponent(0.45).cgColor
        line.translatesAutoresizingMaskIntoConstraints = false

        let holder = NSView()
        holder.translatesAutoresizingMaskIntoConstraints = false
        holder.addSubview(line)
        NSLayoutConstraint.activate([
            holder.heightAnchor.constraint(equalToConstant: 1),
            line.topAnchor.constraint(equalTo: holder.topAnchor),
            line.bottomAnchor.constraint(equalTo: holder.bottomAnchor),
            line.leadingAnchor.constraint(equalTo: holder.leadingAnchor, constant: rowInset),
            line.trailingAnchor.constraint(equalTo: holder.trailingAnchor),
        ])
        return holder
    }
}

/// One entry in the sidebar: a tinted glyph, a name, and a selection that fills
/// the column.
///
/// It fills the column because that is what a source list does — a highlight that
/// stops at the end of the word reads as a tag somebody stuck on the text, and
/// that is exactly how it was read.
final class SidebarItem: NSButton {
    let page: SettingsWindow.Page
    private var selected = false

    init(page: SettingsWindow.Page, target: AnyObject, action: Selector) {
        self.page = page
        super.init(frame: .zero)
        self.target = target
        self.action = action
        isBordered = false
        wantsLayer = true
        layer?.cornerRadius = 7
        imagePosition = .imageLeading
        imageHugsTitle = true
        alignment = .left
        image = Self.chip(symbol: page.symbol, tint: page.tint)
        imageScaling = .scaleNone
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: 30).isActive = true
        apply()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    var isSelected: Bool {
        get { selected }
        set { selected = newValue; apply() }
    }

    private func apply() {
        layer?.backgroundColor = selected
            ? NSColor.controlAccentColor.cgColor : NSColor.clear.cgColor
        attributedTitle = NSAttributedString(string: " " + page.title, attributes: [
            .font: NSFont.systemFont(ofSize: 13, weight: .regular),
            .foregroundColor: selected ? NSColor.white : NSColor.labelColor,
        ])
    }

    /// A rounded tile with the glyph knocked out of it, the way the system's own
    /// settings list marks each pane. Drawn once per item: a tinted image cannot
    /// come from a symbol configuration alone.
    private static func chip(symbol: String, tint: NSColor) -> NSImage {
        let side: CGFloat = 18
        let image = NSImage(size: NSSize(width: side, height: side))
        image.lockFocus()
        tint.setFill()
        NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: side, height: side),
                     xRadius: 4.5, yRadius: 4.5).fill()
        if let glyph = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 11, weight: .medium)) {
            let tinted = NSImage(size: glyph.size)
            tinted.lockFocus()
            NSColor.white.set()
            NSRect(origin: .zero, size: glyph.size).fill(using: .sourceOver)
            glyph.draw(at: .zero, from: NSRect(origin: .zero, size: glyph.size),
                       operation: .destinationIn, fraction: 1)
            tinted.unlockFocus()
            let box = NSRect(x: (side - glyph.size.width) / 2,
                             y: (side - glyph.size.height) / 2,
                             width: glyph.size.width, height: glyph.size.height)
            tinted.draw(in: box)
        }
        image.unlockFocus()
        return image
    }
}
