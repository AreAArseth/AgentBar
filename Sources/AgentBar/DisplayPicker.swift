import Cocoa

/// The "which display" row in the welcome window: one drawn thumbnail per
/// connected screen, plus a *Follow the pointer* tile, laid out the way System
/// Settings ▸ Displays does it — because that is the picture people already
/// recognise as "my desk", and a list of display names is not.
///
/// It builds itself from `NSScreen.screens` and rebuilds on screen changes, so
/// plugging a monitor in while the window is open does the obvious thing.
final class DisplayPicker: NSView {
    /// Called after the user picks; the window uses it to refresh its caption.
    var onPick: (() -> Void)?

    /// Rows of tiles, stacked. More than one only when they don't fit on a line.
    private let rows = NSStackView()
    private static let tileHeight: CGFloat = 62
    private static let spacing: CGFloat = 10
    /// Wide enough for a short display name on one line. Names are kept short on
    /// purpose rather than wrapped: a two-line label inside a stack fights
    /// AppKit's intrinsic width and loses, and System Settings labels them
    /// briefly too. The full name is in the tooltip.
    ///
    /// Fixed, never scaled down. Tiles that shrink to fit a crowded desk get
    /// illegible exactly where the picker matters most, so the row wraps instead.
    static let tileWidth: CGFloat = 104

    /// How much room the row has; the welcome window sets it to its content width.
    var availableWidth: CGFloat = 480 {
        didSet { if availableWidth != oldValue { rebuild() } }
    }

    /// How many tiles fit on one line at full size — the rest wrap to the next.
    /// At the welcome window's 480pt that is four, so a three-display desk (plus
    /// the *Follow pointer* tile) still sits on a single line.
    static func tilesPerRow(available: CGFloat) -> Int {
        max(1, Int((available + spacing) / (tileWidth + spacing)))
    }

    /// Width a line of `tiles` occupies — what the fit is judged on in the tests.
    static func lineWidth(tiles: Int) -> CGFloat {
        let n = CGFloat(max(1, tiles))
        return tileWidth * n + spacing * (n - 1)
    }

    init() {
        super.init(frame: .zero)
        rows.orientation = .vertical
        rows.spacing = Self.spacing
        rows.alignment = .leading
        rows.translatesAutoresizingMaskIntoConstraints = false
        addSubview(rows)
        NSLayoutConstraint.activate([
            rows.leadingAnchor.constraint(equalTo: leadingAnchor),
            rows.topAnchor.constraint(equalTo: topAnchor),
            rows.bottomAnchor.constraint(equalTo: bottomAnchor),
            rows.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
        ])
        rebuild()
        NotificationCenter.default.addObserver(
            self, selector: #selector(rebuild),
            name: NSApplication.didChangeScreenParametersNotification, object: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    deinit { NotificationCenter.default.removeObserver(self) }

    /// Shown whenever the island is on, including with a single display.
    ///
    /// Hiding it below two screens was the tidier choice and the wrong one: a
    /// laptop that spends half its life docked would show the setting only while
    /// docked, so the one time you go looking for it — undocked, wondering where
    /// the island will land when you plug in — it isn't there. With one screen
    /// the row still answers "where does the island go", and `singleDisplay`
    /// lets the caption say the choice starts mattering with a second one.
    static var singleDisplay: Bool { NSScreen.screens.count < 2 }

    @objc func rebuild() {
        rows.arrangedSubviews.forEach { $0.removeFromSuperview() }
        // nil is the "Follow pointer" tile, and it leads.
        let all: [NSScreen?] = [nil] + NSScreen.screens.map { Optional($0) }
        let perRow = Self.tilesPerRow(available: availableWidth)
        for chunk in stride(from: 0, to: all.count, by: perRow) {
            let line = NSStackView()
            line.orientation = .horizontal
            line.spacing = Self.spacing
            line.alignment = .top
            for screen in all[chunk..<min(chunk + perRow, all.count)] {
                line.addArrangedSubview(tile(for: screen))
            }
            rows.addArrangedSubview(line)
        }
    }

    /// `screen == nil` is the *Follow the pointer* tile.
    private func tile(for screen: NSScreen?) -> NSView {
        let selected: Bool
        if let screen {
            selected = IslandScreen.choice == .pinned(IslandScreen.uuid(of: screen) ?? "")
        } else {
            selected = IslandScreen.choice == .followsPointer
                // A pinned display that has been unplugged reads as "following the
                // pointer" on screen, because that is what is actually happening.
                || IslandScreen.pinnedDisplayMissing
        }

        let art = DisplayTileView(screen: screen, selected: selected)
        art.translatesAutoresizingMaskIntoConstraints = false
        art.heightAnchor.constraint(equalToConstant: Self.tileHeight).isActive = true
        let width = Self.tileWidth

        let name = NSTextField(labelWithString: label(for: screen))
        name.font = .systemFont(ofSize: 10)
        name.textColor = selected ? .controlAccentColor : .secondaryLabelColor
        name.alignment = .center
        name.lineBreakMode = .byTruncatingTail
        name.translatesAutoresizingMaskIntoConstraints = false
        name.widthAnchor.constraint(equalToConstant: width).isActive = true

        let col = NSStackView(views: [art, name])
        col.orientation = .vertical
        col.spacing = 4
        col.alignment = .centerX
        col.translatesAutoresizingMaskIntoConstraints = false
        col.widthAnchor.constraint(equalToConstant: width).isActive = true

        let button = TileButton(frame: .zero)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.addSubview(col)
        button.target = self
        button.action = #selector(pick(_:))
        button.screenUUID = screen.flatMap { IslandScreen.uuid(of: $0) }
        button.toolTip = tooltip(for: screen)
        NSLayoutConstraint.activate([
            col.leadingAnchor.constraint(equalTo: button.leadingAnchor),
            col.trailingAnchor.constraint(equalTo: button.trailingAnchor),
            col.topAnchor.constraint(equalTo: button.topAnchor),
            col.bottomAnchor.constraint(equalTo: button.bottomAnchor),
        ])
        return button
    }

    /// Short enough for one line at tile width. "Built-in Retina Display" is the
    /// system's name for every Mac's own screen and says nothing the drawing does
    /// not; "Built-in" does the same job and fits.
    private func label(for screen: NSScreen?) -> String {
        guard let screen else { return "Follow pointer" }
        if IslandScreen.isBuiltIn(screen) { return "Built-in" }
        let name = screen.localizedName
        return name.isEmpty ? "Display" : name
    }

    private func tooltip(for screen: NSScreen?) -> String {
        guard let screen else {
            return "The island appears on whichever display the pointer is on."
        }
        let size = screen.frame.size
        let notch = IslandGeometry.notch(on: screen) != nil ? " · has a notch" : ""
        return "\(label(for: screen)) — \(Int(size.width))×\(Int(size.height))\(notch)"
    }

    @objc private func pick(_ sender: TileButton) {
        IslandScreen.choice = sender.screenUUID.map { .pinned($0) } ?? .followsPointer
        rebuild()
        onPick?()
    }

    /// A borderless button that is just a hit area — the tile draws itself.
    private final class TileButton: NSButton {
        var screenUUID: String?
        override init(frame: NSRect) {
            super.init(frame: frame)
            isBordered = false
            title = ""
            setButtonType(.momentaryChange)
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        override func resetCursorRects() {
            addCursorRect(bounds, cursor: .pointingHand)
        }
    }
}

/// One drawn display: a laptop for a built-in screen, a monitor on a stand for an
/// external one, and a dashed outline for *Follow the pointer*. Proportions come
/// from the real screen, so a portrait display looks like a portrait display.
private final class DisplayTileView: NSView {
    private let screen: NSScreen?
    private let selected: Bool

    init(screen: NSScreen?, selected: Bool) {
        self.screen = screen
        self.selected = selected
        super.init(frame: .zero)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        let accent = NSColor.controlAccentColor
        let line = selected ? accent : NSColor.tertiaryLabelColor
        let fill = selected ? accent.withAlphaComponent(0.16) : NSColor.quaternaryLabelColor

        guard let screen else { drawPointerTile(line: line, fill: fill); return }
        let builtIn = IslandScreen.isBuiltIn(screen)

        // Screen glass, sized from the display's own aspect ratio so the row reads
        // as the desk it represents.
        let ratio = max(0.4, min(2.4, screen.frame.width / max(screen.frame.height, 1)))
        let maxW = bounds.width - 6
        let maxH = bounds.height - (builtIn ? 10 : 14)
        var w = maxH * ratio, h = maxH
        if w > maxW { w = maxW; h = w / ratio }
        let glass = NSRect(x: (bounds.width - w) / 2,
                           y: bounds.height - h - 1,
                           width: w, height: h).integral

        let body = NSBezierPath(roundedRect: glass, xRadius: 4, yRadius: 4)
        fill.setFill(); body.fill()
        line.setStroke(); body.lineWidth = selected ? 2 : 1; body.stroke()

        // The notch, drawn only where there is one — it is how you tell the
        // built-in Mac apart from an external panel at a glance, and it is also
        // where the island actually sits.
        if IslandGeometry.notch(on: screen) != nil {
            let nw = max(10, glass.width * 0.22), nh: CGFloat = 3
            let notch = NSRect(x: glass.midX - nw / 2, y: glass.maxY - nh,
                               width: nw, height: nh)
            line.setFill()
            NSBezierPath(roundedRect: notch, xRadius: 1.5, yRadius: 1.5).fill()
        }

        line.setFill()
        if builtIn {
            // Laptop: a wider base under the glass, the way the Displays pane draws it.
            let base = NSRect(x: glass.minX - 5, y: glass.minY - 3,
                              width: glass.width + 10, height: 3)
            NSBezierPath(roundedRect: base, xRadius: 1.5, yRadius: 1.5).fill()
        } else {
            // Monitor: a neck and a foot.
            let neck = NSRect(x: glass.midX - 3, y: glass.minY - 5, width: 6, height: 5)
            NSBezierPath(rect: neck).fill()
            let foot = NSRect(x: glass.midX - 13, y: glass.minY - 8, width: 26, height: 3)
            NSBezierPath(roundedRect: foot, xRadius: 1.5, yRadius: 1.5).fill()
        }
    }

    /// Follow the pointer: a dashed screen with an arrow in it. Dashed because
    /// nothing is pinned — the island has no fixed home in this mode.
    private func drawPointerTile(line: NSColor, fill: NSColor) {
        let w = min(bounds.width - 10, (bounds.height - 12) * 1.5)
        let h = w / 1.5
        let glass = NSRect(x: (bounds.width - w) / 2, y: bounds.height - h - 4,
                           width: w, height: h).integral
        let body = NSBezierPath(roundedRect: glass, xRadius: 4, yRadius: 4)
        fill.setFill(); body.fill()
        body.lineWidth = selected ? 2 : 1
        body.setLineDash([3, 2], count: 2, phase: 0)
        line.setStroke(); body.stroke()

        // A pointer arrow, drawn rather than shipped as an asset.
        let a = NSBezierPath()
        let o = NSPoint(x: glass.midX - 3, y: glass.midY + 6)
        a.move(to: o)
        a.line(to: NSPoint(x: o.x, y: o.y - 13))
        a.line(to: NSPoint(x: o.x + 3.6, y: o.y - 9.4))
        a.line(to: NSPoint(x: o.x + 6.2, y: o.y - 14.4))
        a.line(to: NSPoint(x: o.x + 8.4, y: o.y - 13.4))
        a.line(to: NSPoint(x: o.x + 5.8, y: o.y - 8.4))
        a.line(to: NSPoint(x: o.x + 10.4, y: o.y - 8.2))
        a.close()
        line.setFill(); a.fill()
    }
}
