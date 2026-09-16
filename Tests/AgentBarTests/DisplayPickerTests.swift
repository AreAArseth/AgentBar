import AppKit
import Testing
@testable import AgentBar

/// The display row's fit. Rendering needs real hardware, but the arithmetic that
/// decides whether every tile lands on the row does not — and it is what broke:
/// at the fixed ideal width, four displays ran 80pt past the window edge.
@Suite struct DisplayPickerTests {
    /// The welcome window's content width for this row.
    private let available: CGFloat = 480

    @Test(arguments: 1...6)
    func everyDisplayCountFitsOnTheRow(_ displays: Int) {
        let tiles = displays + 1   // + the "Follow pointer" tile
        let width = DisplayPicker.rowWidth(tiles: tiles, available: available)
        #expect(width <= available,
                "\(displays) display(s) need \(width)pt of \(available)pt")
    }

    /// Few displays must not blow the tiles up to fill the row — they stay at the
    /// ideal size and the row simply ends early.
    @Test func smallSetupsKeepTheIdealTileWidth() {
        #expect(DisplayPicker.tileWidth(tiles: 2, available: available) == 104)
        #expect(DisplayPicker.tileWidth(tiles: 4, available: available) == 104)
    }

    /// Many displays shrink the tiles rather than overflowing.
    @Test func crowdedSetupsShrinkInstead() {
        let five = DisplayPicker.tileWidth(tiles: 5, available: available)
        #expect(five < 104)
        #expect(five > DisplayPicker.tileWidth(tiles: 7, available: available))
    }

    /// There is a floor: past it the drawing stops reading as a display, so the
    /// row is allowed to overflow rather than shrink into confetti.
    @Test func shrinkingStopsAtAReadableSize() {
        #expect(DisplayPicker.tileWidth(tiles: 40, available: available) == 56)
    }
}
