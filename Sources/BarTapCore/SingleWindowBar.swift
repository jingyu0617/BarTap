import CoreGraphics
import Foundation

/// macOS 27 draws the whole menu bar as one window (hosted by MenuBarAgent) instead of one small
/// window per status item, and it throws away any status item wider than half the display. The
/// 10,000 pt divider that hides icons on macOS 13–26 is therefore discarded there and hides nothing.
///
/// What still works: icons that don't fit between the app's menus and the rest of the bar are not
/// drawn (macOS tucks them behind its own overflow button). So on macOS 27 BarTap fills exactly
/// the room left of its divider, with widths that each stay under the half-display limit: the
/// divider first, and on a wide display the BarTap button too (it grows a blank part on its left).
/// No room is left for the icons left of the divider, so they are hidden; nothing is discarded.
public enum SingleWindowBar {
    /// What BarTap reads off its own items (global x, growing rightwards) before sizing them.
    public struct Measure: Equatable {
        public var screenMinX: CGFloat
        public var screenWidth: CGFloat
        /// Narrowest display's width: the half-display limit is taken from it.
        public var narrowestWidth: CGFloat
        /// Right edge of the BarTap button. It stays put while the button and the divider grow leftwards.
        public var toggleMaxX: CGFloat
        /// The button's window width when it only shows its icon.
        public var toggleNaturalWidth: CGFloat
        /// Whatever sits between the divider and the button (normally nothing).
        public var between: CGFloat
        /// macOS's padding around an item: window width = length + padding.
        public var padding: CGFloat
        /// The divider's length while icons are shown.
        public var openLength: CGFloat
        /// Right edge of the front app's menus on that display; nil when unknown.
        public var menuMaxX: CGFloat?

        public init(screenMinX: CGFloat, screenWidth: CGFloat, narrowestWidth: CGFloat, toggleMaxX: CGFloat,
                    toggleNaturalWidth: CGFloat, between: CGFloat, padding: CGFloat, openLength: CGFloat, menuMaxX: CGFloat?) {
            self.screenMinX = screenMinX
            self.screenWidth = screenWidth
            self.narrowestWidth = narrowestWidth
            self.toggleMaxX = toggleMaxX
            self.toggleNaturalWidth = toggleNaturalWidth
            self.between = between
            self.padding = padding
            self.openLength = openLength
            self.menuMaxX = menuMaxX
        }
    }

    public struct Fit: Equatable {
        /// The divider's length.
        public var dividerLength: CGFloat
        /// Blank width added on the left of the BarTap button (0 = just its icon).
        public var toggleExtra: CGFloat
        /// The room that had to be filled.
        public var wanted: CGFloat

        public init(dividerLength: CGFloat, toggleExtra: CGFloat, wanted: CGFloat) {
            self.dividerLength = dividerLength
            self.toggleExtra = toggleExtra
            self.wanted = wanted
        }

        public var total: CGFloat { dividerLength + toggleExtra }
    }

    /// Room deliberately left unfilled, so a menu a few points longer doesn't push BarTap's own
    /// items out. Narrower than any icon, so nothing fits in it.
    public static let margin: CGFloat = 8
    /// Without the menus' right edge, assume they take this share of the display: icons may stay
    /// visible, but BarTap's own items can never be pushed out.
    public static let unknownMenuShare: CGFloat = 0.3

    /// The longest length an item may have and still be kept by macOS 27 (its window, padding
    /// included, must stay under half the narrowest display).
    public static func maxLength(narrowestWidth: CGFloat, padding: CGFloat) -> CGFloat {
        max(0, (narrowestWidth / 2).rounded(.down) - padding - 12)
    }

    /// Lengths that hide everything left of the divider, or nil when the measurements can't be
    /// right (the button outside its display: macOS hasn't laid the bar out yet).
    /// - Parameter forcedWanted: a fixed room to fill instead of the measured one (a hidden setting).
    public static func fit(_ m: Measure, forcedWanted: CGFloat? = nil) -> Fit? {
        guard m.screenWidth > 0, m.toggleNaturalWidth > 0, m.padding >= 0,
              m.toggleMaxX > m.screenMinX + m.toggleNaturalWidth, m.toggleMaxX <= m.screenMinX + m.screenWidth + 1 else { return nil }
        let menuEdge: CGFloat
        if let x = m.menuMaxX, x >= m.screenMinX, x < m.toggleMaxX {
            menuEdge = x
        } else {
            menuEdge = m.screenMinX + m.screenWidth * unknownMenuShare
        }
        // Where the divider's left edge is while icons are shown.
        let dividerLeft = m.toggleMaxX - m.toggleNaturalWidth - max(0, m.between) - (m.openLength + m.padding)
        let wanted = max(0, (forcedWanted ?? (dividerLeft - menuEdge - margin)).rounded(.down))
        let longest = maxLength(narrowestWidth: m.narrowestWidth, padding: m.padding)
        let dividerExtra = min(wanted, max(0, longest - m.openLength))
        let toggleLength = max(0, m.toggleNaturalWidth - m.padding)
        let toggleExtra = min(wanted - dividerExtra, max(0, longest - toggleLength))
        return Fit(dividerLength: m.openLength + dividerExtra, toggleExtra: max(0, toggleExtra), wanted: wanted)
    }

    /// Whether to resize from `current` to `next`. Shrinking is always applied (a longer menu
    /// would otherwise push BarTap's items out); growing only when it is worth laying the bar out
    /// again.
    public static func shouldResize(from current: CGFloat, to next: CGFloat, hysteresis: CGFloat = 10) -> Bool {
        if next < current - 0.5 { return true }
        return next - current >= hysteresis
    }
}
