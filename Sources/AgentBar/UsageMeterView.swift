import Cocoa

/// What each provider has left, as a short stack of meters in the menu.
///
/// The question this answers is one question — *how much have I spent and how
/// much is left* — so the row is the whole design and there is nothing else on
/// it: who, which window, a bar, and what remains. No history, no forecast, no
/// per-model breakdown; those are different questions and they belong to whoever
/// wants to ask them.
///
/// It lives in the **menu** and not on the island. The island's one dim usage line
/// already says the same thing in a sentence, and the island's height is exactly
/// what got pushed back on the last time something new wanted to live down there.
/// The menu is the surface you open when you want the detail.
///
/// Drawn rather than composed, like `TodayStripView`: a stack of labels and
/// progress views rebuilt whenever a menu opens costs more than the whole rest of
/// the menu, and buys nothing a `draw(_:)` can't do.
final class UsageMeterView: NSView {
    /// One line of the block. A window row carries a meter; a plain row is a
    /// provider that publishes no ceiling and gets a number instead — which is
    /// the honest shape, not a lesser one.
    struct Row {
        let provider: String     // "" on a provider's second window: said once
        let window: String       // "5h" / "weekly" / "" for a plain row
        let used: Double?        // nil = no meter
        let trailing: String
    }

    private static let rowHeight: CGFloat = 17
    private static let vPad: CGFloat = 3
    private static let meterWidth: CGFloat = 70
    private static let meterHeight: CGFloat = 4
    private static let windowWidth: CGFloat = 46
    /// Lines the block up with the menu's own text, like `ApprovalContextView`.
    private static let leading: CGFloat = 22
    private static let trailingPad: CGFloat = 14

    private static let label = NSFont.systemFont(ofSize: 11, weight: .medium)
    private static let small = NSFont.systemFont(ofSize: 11)
    private static let digits = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)

    private let rows: [Row]
    private let providerColumn: CGFloat
    /// A column exists when some row uses it, and then it is held open for every
    /// row — so each sentence begins in the same place and a missing meter reads
    /// as missing rather than as a shorter line. A block with no meters at all
    /// (only Copilot, say) keeps neither column and sits flush.
    private let windowColumn: CGFloat
    private let meterColumn: CGFloat

    /// Flattens the readings into rows. A provider's name is said once, on its
    /// first window, so two windows read as one thing with two parts rather than
    /// as two providers with similar names.
    static func rows(for readings: [UsageCenter.Reading]) -> [Row] {
        var out: [Row] = []
        for r in readings {
            if r.windows.isEmpty {
                out.append(Row(provider: r.provider, window: "", used: nil, trailing: r.text))
                continue
            }
            for (i, w) in r.windows.enumerated() {
                // A window past its reset gets no meter. Nobody has written a
                // number since it rolled over: a full bar would be the last
                // window's news, and an empty one a zero nobody measured.
                out.append(Row(provider: i == 0 ? r.provider : "",
                               window: w.name,
                               used: w.expired() ? nil : w.usedPercent,
                               trailing: UsageCenter.short(w)))
            }
            if let note = r.note {
                out.append(Row(provider: "", window: "", used: nil, trailing: note))
            }
        }
        return out
    }

    init?(readings: [UsageCenter.Reading]) {
        let rows = Self.rows(for: readings)
        guard !rows.isEmpty else { return nil }
        self.rows = rows
        // The label column is as wide as the widest name and no wider — a fixed
        // one would leave a gap on a machine running only Codex.
        self.providerColumn = rows.map {
            $0.provider.isEmpty ? 0
                : ($0.provider as NSString).size(withAttributes: [.font: Self.label]).width
        }.max().map { $0 + 10 } ?? 0
        self.windowColumn = rows.contains { !$0.window.isEmpty } ? Self.windowWidth : 0
        self.meterColumn = rows.contains { $0.used != nil } ? Self.meterWidth + 10 : 0
        super.init(frame: NSRect(x: 0, y: 0, width: 320,
                                 height: CGFloat(rows.count) * Self.rowHeight + Self.vPad * 2))
        autoresizingMask = [.width]
        toolTip = readings.compactMap { r in
            r.detail.map { "\(r.provider)\n\($0)" }
        }.joined(separator: "\n\n")
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    /// Rows are laid out top-down, in the order they are read. Without this they
    /// come out bottom-up: the first provider at the foot of the block, its
    /// weekly window above its 5-hour one. (Found by rendering the thing, which
    /// is the whole reason `renderForVerification` exists.)
    override var isFlipped: Bool { true }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        var y = Self.vPad
        for row in rows {
            draw(row, atTop: y)
            y += Self.rowHeight
        }
    }

    private func draw(_ row: Row, atTop y: CGFloat) {
        // Text sits on the row's baseline; the meter centres on the same line, so
        // the bar reads as part of the sentence and not as a separate object.
        let textY = y + 2
        var x = Self.leading

        if !row.provider.isEmpty {
            (row.provider as NSString).draw(
                at: NSPoint(x: x, y: textY),
                withAttributes: [.font: Self.label, .foregroundColor: NSColor.secondaryLabelColor])
        }
        x += providerColumn

        if !row.window.isEmpty {
            (row.window as NSString).draw(
                at: NSPoint(x: x, y: textY),
                withAttributes: [.font: Self.small, .foregroundColor: NSColor.tertiaryLabelColor])
        }
        x += windowColumn

        if let used = row.used {
            drawMeter(in: NSRect(x: x, y: y + (Self.rowHeight - Self.meterHeight) / 2,
                                 width: Self.meterWidth, height: Self.meterHeight),
                      used: used)
        }
        x += meterColumn

        let width = max(0, bounds.width - x - Self.trailingPad)
        (row.trailing as NSString).draw(
            in: NSRect(x: x, y: textY, width: width, height: Self.rowHeight),
            withAttributes: [.font: Self.digits,
                             // The number is the answer; it gets the readable
                             // grey, and the window's name beside it the quiet one.
                             .foregroundColor: NSColor.secondaryLabelColor,
                             .paragraphStyle: Self.truncating])
    }

    /// Colour only where it means something. A meter that is orange at every
    /// value has told you nothing; one that turns amber at four fifths and red at
    /// nineteen twentieths is saying the only thing a colour can usefully say
    /// here.
    private func drawMeter(in rect: NSRect, used: Double) {
        let radius = rect.height / 2
        NSColor.labelColor.withAlphaComponent(0.12).setFill()
        NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()

        let fraction = min(max(used, 0), 100) / 100
        guard fraction > 0 else { return }
        // Never thinner than the cap it is drawn with: 1 % has to look like a
        // sliver rather than like nothing at all.
        let width = max(rect.height, rect.width * CGFloat(fraction))
        let fill: NSColor
        switch used {
        case 95...:  fill = NSColor.systemRed
        case 80...:  fill = NSColor.systemOrange
        default:     fill = NSColor.labelColor.withAlphaComponent(0.55)
        }
        fill.setFill()
        NSBezierPath(roundedRect: NSRect(x: rect.minX, y: rect.minY,
                                         width: width, height: rect.height),
                     xRadius: radius, yRadius: radius).fill()
    }

    private static let truncating: NSParagraphStyle = {
        let p = NSMutableParagraphStyle()
        p.lineBreakMode = .byTruncatingTail
        return p
    }()
}

// MARK: - Offline verification

extension UsageMeterView {
    /// Renders the block to a PNG without opening a menu, so the one drawn surface
    /// this release adds can actually be looked at. The precedent is
    /// `SoundCenter.renderAllForVerification`: a surface nobody can see while
    /// building it ships with whatever it happens to look like — 1.18.0's island
    /// strip had one bar eating 97 % of the width, and only a screenshot found it.
    ///
    /// The set is fixed rather than live: it is a specification of every case the
    /// view has to handle at once — a calm window, one near its limit, one past it,
    /// a rolled-over window with no meter, a credit balance, and a provider with no
    /// ceiling at all.
    static func renderForVerification(to url: URL) -> Bool {
        let now = Date()
        let readings: [UsageCenter.Reading] = [
            UsageCenter.Reading(
                provider: "Codex", text: "", detail: "account: someone",
                windows: [UsageWindow(name: "5h", usedPercent: 97,
                                      resetsAt: now.addingTimeInterval(1_800)),
                          UsageWindow(name: "weekly", usedPercent: 27,
                                      resetsAt: now.addingTimeInterval(4 * 86_400))],
                note: "12.50 credits left"),
            UsageCenter.Reading(
                provider: "Claude", text: "",
                windows: [UsageWindow(name: "5h", usedPercent: 84,
                                      resetsAt: now.addingTimeInterval(7_200)),
                          UsageWindow(name: "weekly", usedPercent: 3,
                                      resetsAt: now.addingTimeInterval(-60))]),
            UsageCenter.Reading(provider: "Copilot", text: "2.4 AIU today"),
        ]
        guard let view = UsageMeterView(readings: readings) else { return false }
        view.frame = NSRect(x: 0, y: 0, width: 340, height: view.frame.height)
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return false }
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]) else { return false }
        return (try? data.write(to: url)) != nil
    }
}
