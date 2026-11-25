import Foundation
import CoreGraphics
import BarTapCore

/// macOS 27 sizing. The wide case is a real measurement: a 5K display at 2560 pt, BarTap button
/// 36 pt at x 2251, divider 18 pt at x 2153 (macOS 27.0.1).
func runSingleWindowBarTests() {
    func measure(width: CGFloat = 2560, toggleMaxX: CGFloat = 2287, between: CGFloat = 80, menu: CGFloat? = 500,
                 narrowest: CGFloat? = nil, minX: CGFloat = 0) -> SingleWindowBar.Measure {
        SingleWindowBar.Measure(screenMinX: minX, screenWidth: width, narrowestWidth: narrowest ?? width, toggleMaxX: toggleMaxX,
                                toggleNaturalWidth: 36, between: between, padding: 10, openLength: 8, menuMaxX: menu)
    }

    test("macOS 27: a wide display needs the divider and the button") {
        let fit = SingleWindowBar.fit(measure())!
        // Divider's left edge while open: 2287 − 36 − 80 − 18 = 2153; room: 2153 − 500 − 8.
        expect(fit.wanted == 1645, "\(fit.wanted)")
        expect(fit.dividerLength == 1258, "\(fit.dividerLength)")
        expect(fit.toggleExtra == 395, "\(fit.toggleExtra)")
        // Each window (length + padding) stays under half the display.
        expect(fit.dividerLength + 10 < 1280)
        expect(26 + fit.toggleExtra + 10 < 1280)
        // Together they fill the room, and no more: BarTap's own items still fit.
        expect(fit.dividerLength - 8 + fit.toggleExtra == fit.wanted)
    }

    test("macOS 27: a narrow bar needs the divider only") {
        let fit = SingleWindowBar.fit(measure(width: 1470, toggleMaxX: 1100, between: 0, menu: 420))!
        // 1100 − 36 − 18 = 1046; 1046 − 420 − 8 = 618; the limit is 735 − 22 = 713.
        expect(fit.wanted == 618 && fit.dividerLength == 626 && fit.toggleExtra == 0, "\(fit)")
    }

    test("macOS 27: no room left of the divider leaves it as it is") {
        let fit = SingleWindowBar.fit(measure(width: 1470, toggleMaxX: 760, between: 0, menu: 720))!
        expect(fit.wanted == 0 && fit.dividerLength == 8 && fit.toggleExtra == 0, "\(fit)")
    }

    test("macOS 27: unknown menus are assumed wide, never narrow") {
        let known = SingleWindowBar.fit(measure(menu: 500))!
        let unknown = SingleWindowBar.fit(measure(menu: nil))!
        expect(unknown.wanted == 2153 - 768 - 8, "\(unknown.wanted)")
        expect(unknown.total < known.total)
        // A menu edge right of the button can't be right: treated as unknown.
        expect(SingleWindowBar.fit(measure(menu: 2400))! == unknown)
    }

    test("macOS 27: the narrowest display sets the limit") {
        let fit = SingleWindowBar.fit(measure(narrowest: 1470))!
        // 735 − 10 − 12 = 713 per item: both at the limit, the rest stays visible.
        expect(fit.dividerLength == 713, "\(fit.dividerLength)")
        expect(fit.toggleExtra == 713 - 26, "\(fit.toggleExtra)")
        expect(SingleWindowBar.maxLength(narrowestWidth: 1470, padding: 10) == 713)
    }

    test("macOS 27: a display left of the main one") {
        let fit = SingleWindowBar.fit(measure(width: 1440, toggleMaxX: -200, between: 0, menu: -1000, minX: -1440))!
        // −200 − 36 − 18 = −254; −254 − (−1000) − 8 = 738; limit 720 − 22 = 698, the button takes the other 48.
        expect(fit.wanted == 738 && fit.dividerLength == 698 && fit.toggleExtra == 48, "\(fit)")
    }

    test("macOS 27: frames that can't be right give no fit") {
        expect(SingleWindowBar.fit(measure(toggleMaxX: 0)) == nil, "not laid out yet")
        expect(SingleWindowBar.fit(measure(toggleMaxX: 4000)) == nil, "beyond the display")
        expect(SingleWindowBar.fit(measure(width: 0)) == nil)
    }

    test("macOS 27: a fixed room overrides the measured one") {
        let fit = SingleWindowBar.fit(measure(), forcedWanted: 300)!
        expect(fit.wanted == 300 && fit.dividerLength == 308 && fit.toggleExtra == 0, "\(fit)")
    }

    test("macOS 27: resize when shrinking, or when growing is worth it") {
        expect(SingleWindowBar.shouldResize(from: 1000, to: 990))
        expect(SingleWindowBar.shouldResize(from: 1000, to: 999))
        expect(!SingleWindowBar.shouldResize(from: 1000, to: 1000))
        expect(!SingleWindowBar.shouldResize(from: 1000, to: 1006))
        expect(SingleWindowBar.shouldResize(from: 1000, to: 1010))
    }
}
