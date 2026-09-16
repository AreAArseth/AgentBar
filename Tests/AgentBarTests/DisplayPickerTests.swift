import AppKit
import Testing
@testable import AgentBar

/// The display row's fit. Rendering needs real hardware, but the geometry that
/// decides whether every tile lands on screen does not — and it is what broke:
/// at a fixed tile width and a single line, four displays ran 80pt past the
/// window edge and the last tile was simply cut off.
@Suite struct DisplayPickerTests {
    /// The welcome window's content width for this row.
    private let available: CGFloat = 480

    /// Tiles keep their size at every display count. Shrinking them to fit was
    /// the first fix and the wrong one: they get illegible exactly on the
    /// crowded desks the picker exists for. The row wraps instead.
    @Test func tilesNeverShrink() {
        #expect(DisplayPicker.tileWidth == 104)
    }

    @Test func fourTilesFitOnOneLineAtTheWindowWidth() {
        #expect(DisplayPicker.tilesPerRow(available: available) == 4)
        #expect(DisplayPicker.lineWidth(tiles: 4) <= available)
        // Five would not, which is the wrap that has to happen.
        #expect(DisplayPicker.lineWidth(tiles: 5) > available)
    }

    /// Every display count lands on screen once wrapping is accounted for: no
    /// line is wider than the window, whatever the desk looks like.
    @Test(arguments: 1...8)
    func everyDisplayCountWrapsWithinTheWindow(_ displays: Int) {
        let tiles = displays + 1            // + the "Follow pointer" tile
        let perRow = DisplayPicker.tilesPerRow(available: available)
        for start in stride(from: 0, to: tiles, by: perRow) {
            let onThisLine = min(perRow, tiles - start)
            #expect(DisplayPicker.lineWidth(tiles: onThisLine) <= available,
                    "\(displays) display(s): a line of \(onThisLine) tiles overflows")
        }
    }

    /// A three-display desk — the case this was built for — still sits on one
    /// line, so the common setup looks exactly as it did.
    @Test func threeDisplaysStayOnASingleLine() {
        #expect(3 + 1 <= DisplayPicker.tilesPerRow(available: available))
    }

    /// A window too narrow for even one tile must still lay out a line rather
    /// than dividing by zero or producing an empty row.
    @Test func absurdlyNarrowWindowsStillGetOneTilePerLine() {
        #expect(DisplayPicker.tilesPerRow(available: 10) == 1)
    }
}
