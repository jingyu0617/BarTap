import AppKit
import BarTapCore

/// Owns our status items. Hiding works purely by resizing separator items: a separator that is
/// wider than any screen pushes every icon to its left out of the drawable area. No events are
/// synthesized and no other app's item is ever touched.
///
/// Layout, left to right:
///   [always-hidden icons] ‖ [hidden icons] │ (toggle) [shown icons] [Control Center] [Clock]
final class StatusBarController: NSObject {
    enum Click { case toggle, toggleAll, menu }

    static let collapsedLength: CGFloat = 10_000
    /// Collapsed dividers are always wider than this, so window geometry can tell them apart
    /// from real icons (see `separatorWidthThreshold`).
    static let minimumCollapsedLength: CGFloat = 1600
    static let dividerLength: CGFloat = 8
    /// Open divider without the drawn line. Not 0: a zero-length item may report no frame.
    static let gapLength: CGFloat = 1

    private enum Name {
        static let toggle = "tb_toggle"
        static let hidden = "tb_hidden"
        static let always = "tb_always"
        static let clean = "tb_clean"
        static let cleanExit = "tb_clean_exit"
    }

    private(set) var toggleItem: NSStatusItem?
    private(set) var hiddenItem: NSStatusItem?
    private(set) var alwaysItem: NSStatusItem?
    private var cleanSeparator: NSStatusItem?
    private var cleanExit: NSStatusItem?

    var onClick: ((Click) -> Void)?
    var onCleanExitClick: (() -> Void)?
    var menuProvider: (() -> NSMenu)?

    private let settings: Settings
    private(set) var appliedLevel: RevealLevel?
    private var showDividers = true

    // MARK: macOS 27 (one window for the whole menu bar; see SingleWindowBar)

    /// macOS 27 and later. `defaults write io.github.chenfangfc.BarTap singleWindowBar -bool …` overrides it.
    static let singleWindowBar: Bool = {
        if let forced = UserDefaults.standard.object(forKey: "singleWindowBar") as? Bool { return forced }
        return ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 27
    }()
    /// Right edge (global x) of the front app's menus on a display, if known.
    var menuMaxXProvider: ((NSScreen) -> CGFloat?)?
    /// The BarTap button's window width while it only shows its icon.
    private var toggleNaturalWidth: CGFloat = 36
    /// macOS's padding around an item (window width − length).
    private var itemPadding: CGFloat = 10
    private var lastBetween: CGFloat = 0
    private var lastMenuEdge: CGFloat?
    /// Blank width currently added on the left of the BarTap button.
    private(set) var toggleExtra: CGFloat = 0
    private var baseToggleImage: NSImage?
    private var wideToggleImage: (base: NSImage, extra: CGFloat, image: NSImage)?
    private var refitWork: DispatchWorkItem?
    /// The last sizing, for the debug dump.
    private(set) var lastFit = ""

    init(settings: Settings) {
        self.settings = settings
    }

    // MARK: Creation

    static func preferredPositionKey(_ name: String) -> String { "NSStatusItem Preferred Position \(name)" }

    static func hasStoredPositions(_ defaults: UserDefaults) -> Bool {
        defaults.object(forKey: preferredPositionKey(Name.toggle)) != nil
    }

    static func seed(_ seeds: Placement.Seeds, in defaults: UserDefaults) {
        defaults.set(seeds.toggle, forKey: preferredPositionKey(Name.toggle))
        defaults.set(seeds.hidden, forKey: preferredPositionKey(Name.hidden))
    }

    /// Exact keys for all three items (Settings › Layout places each divider in a chosen gap).
    static func storeKeys(toggle: Double, hidden: Double, always: Double?, in defaults: UserDefaults) {
        defaults.set(toggle, forKey: preferredPositionKey(Name.toggle))
        defaults.set(hidden, forKey: preferredPositionKey(Name.hidden))
        if let always { defaults.set(always, forKey: preferredPositionKey(Name.always)) }
    }

    static func clearStoredPositions(_ defaults: UserDefaults) {
        for n in [Name.toggle, Name.hidden, Name.always] { defaults.removeObject(forKey: preferredPositionKey(n)) }
    }

    /// Creation order matters when no positions are stored: each new item lands at the far left,
    /// so toggle → hidden → always yields `‖ │ (toggle)` with nothing hidden yet.
    func createItems(alwaysHidden: Bool) {
        guard toggleItem == nil else { return }
        let toggle = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        toggle.autosaveName = Name.toggle
        toggle.behavior = []
        configureButton(toggle, identifier: "bartap.toggle", label: L("BarTap: show or hide menu bar icons"))
        toggleItem = toggle

        let hidden = NSStatusBar.system.statusItem(withLength: Self.dividerLength)
        hidden.autosaveName = Name.hidden
        hidden.behavior = []
        configureButton(hidden, identifier: "bartap.hidden", label: L("BarTap divider: icons to the left are hidden"))
        hiddenItem = hidden

        if alwaysHidden { createAlwaysItem() }
        appliedLevel = nil
    }

    private func createAlwaysItem() {
        guard alwaysItem == nil else { return }
        // Start open: the reveal controller collapses it only after validating the order.
        let item = NSStatusBar.system.statusItem(withLength: Self.dividerLength)
        item.autosaveName = Name.always
        item.behavior = []
        configureButton(item, identifier: "bartap.always", label: L("BarTap divider: icons to the left are always hidden"))
        alwaysItem = item
    }

    func setAlwaysHiddenEnabled(_ on: Bool) {
        if on {
            createAlwaysItem()
        } else if let item = alwaysItem {
            NSStatusBar.system.removeStatusItem(item)
            alwaysItem = nil
        }
        appliedLevel = nil
    }

    func removeAllItems() {
        for item in [toggleItem, hiddenItem, alwaysItem, cleanSeparator, cleanExit].compactMap({ $0 }) {
            NSStatusBar.system.removeStatusItem(item)
        }
        toggleItem = nil
        hiddenItem = nil
        alwaysItem = nil
        cleanSeparator = nil
        cleanExit = nil
        appliedLevel = nil
        toggleExtra = 0
        wideToggleImage = nil
        refitWork?.cancel()
        refitWork = nil
    }

    private func configureButton(_ item: NSStatusItem, identifier: String, label: String) {
        guard let button = item.button else { return }
        button.target = self
        button.action = #selector(buttonClicked(_:))
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        button.setAccessibilityIdentifier(identifier)
        button.setAccessibilityLabel(label)
        button.imagePosition = .imageOnly
    }

    // MARK: State

    /// Collapsed dividers use a fixed, very large length (macOS clamps it to ~5,000 pt).
    /// Shorter "just wide enough" lengths save ~10 MB of backing store but were measured to
    /// trigger a macOS 26 layout state where one display draws the divider and hides every other
    /// icon (clock included); the long length never did. (Measured 2026-11: the memory is AppKit's
    /// snapshot of the item for each other display, NSStatusItemReplicantView, ~3.4 MB per copy
    /// at this length; neither hiding the button nor freezing its contents avoids it.)
    func collapsedLength() -> CGFloat { Self.collapsedLength }

    func apply(level: RevealLevel, showDividers: Bool) {
        self.showDividers = showDividers
        guard let hidden = hiddenItem else { return }
        let open = showDividers ? Self.dividerLength : Self.gapLength
        if Self.singleWindowBar {
            applySingleWindow(level: level, open: open, followUp: true)
            hidden.button?.image = (showDividers && level >= .revealed) ? Icons.divider(double: false) : nil
            alwaysItem?.button?.image = (showDividers && level >= .revealedAll) ? Icons.divider(double: true) : nil
            appliedLevel = level
            return
        }
        // Measure before changing anything: once collapsed, the divider's own right edge stays put,
        // so a measurement taken in any state is valid.
        let closed = collapsedLength()
        let hiddenLength = level >= .revealed ? open : closed
        // The always-hidden divider only has to be wide while the hidden section is shown. When
        // everything is collapsed it sits behind the hidden divider anyway, so it stays narrow and
        // does not hold a second full-width backing surface.
        let alwaysLength = level == .revealed ? closed : open
        // Change the outer separator while it is still covered by the inner one, so the
        // always-hidden icons never flash on screen.
        if level == .collapsed {
            setLength(hidden, hiddenLength)
            if let a = alwaysItem { setLength(a, alwaysLength) }
        } else {
            if let a = alwaysItem { setLength(a, alwaysLength) }
            setLength(hidden, hiddenLength)
        }
        hidden.button?.image = (showDividers && level >= .revealed) ? Icons.divider(double: false) : nil
        alwaysItem?.button?.image = (showDividers && level >= .revealedAll) ? Icons.divider(double: true) : nil
        appliedLevel = level
    }

    private func setLength(_ item: NSStatusItem, _ length: CGFloat) {
        if abs(item.length - length) > 0.5 { item.length = length }
    }

    // MARK: macOS 27 sizing

    /// Sizes the dividers (and, on a wide display, the BarTap button) so that the icons left of a
    /// closed divider have no room left: each width stays under macOS 27's half-display limit.
    private func applySingleWindow(level: RevealLevel, open: CGFloat, followUp: Bool) {
        guard let hidden = hiddenItem else { return }
        rememberNaturalSizes()
        switch level {
        case .collapsed:
            let fit = hiddenFit(open: open)
            let current = hidden.length + toggleExtra
            // Already closed: don't lay the bar out again for a few points.
            let closed = hidden.length > open + 1 || toggleExtra > 0
            if !closed || SingleWindowBar.shouldResize(from: current, to: fit.total) {
                // Widen the divider before the button, so nothing hidden shows in between.
                setLength(hidden, fit.dividerLength)
                setToggleExtra(fit.toggleExtra)
            }
            if let a = alwaysItem { setLength(a, open) }
        case .revealed:
            setToggleExtra(0)
            if let a = alwaysItem { setLength(a, alwaysLength(open: open)) }
            setLength(hidden, open)
        case .revealedAll:
            setToggleExtra(0)
            if let a = alwaysItem { setLength(a, open) }
            setLength(hidden, open)
        }
        // The frames read above can be a layout behind (macOS lays the bar out after this
        // returns): measure once more when it has settled.
        refitWork?.cancel()
        refitWork = nil
        if followUp, level < .revealedAll {
            let work = DispatchWorkItem { [weak self] in self?.refit() }
            refitWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: work)
        }
    }

    /// Measures again and resizes if the room changed (another app's menus, a display change).
    func refit() {
        guard Self.singleWindowBar, let level = appliedLevel, level < .revealedAll, !isCleanModeOn else { return }
        applySingleWindow(level: level, open: showDividers ? Self.dividerLength : Self.gapLength, followUp: false)
    }

    private func rememberNaturalSizes() {
        if toggleExtra == 0, let w = toggleItem?.button?.window?.frame.width, w > 8, w < 160 { toggleNaturalWidth = w }
        if let h = hiddenItem, h.length > 0, h.length <= 20, let w = h.button?.window?.frame.width, w >= h.length, w - h.length <= 40 {
            itemPadding = w - h.length
        }
    }

    private func narrowestScreenWidth() -> CGFloat {
        NSScreen.screens.map(\.frame.width).min() ?? 1440
    }

    private func menuEdge(on screen: NSScreen) -> CGFloat? {
        let d = UserDefaults.standard
        // Hidden setting: the menus' right edge, in points from the display's left edge.
        if let forced = d.object(forKey: "mb27.menuEdge") as? Double { return screen.frame.minX + CGFloat(forced) }
        if let x = menuMaxXProvider?(screen) { lastMenuEdge = x; return x }
        // No answer this time (Accessibility timed out): the last one beats a guess.
        if let x = lastMenuEdge, x >= screen.frame.minX, x <= screen.frame.maxX { return x }
        return nil
    }

    private func hiddenFit(open: CGFloat) -> SingleWindowBar.Fit {
        let narrowest = narrowestScreenWidth()
        let longest = SingleWindowBar.maxLength(narrowestWidth: narrowest, padding: itemPadding)
        // Can't measure: fill a modest part with the divider alone. Icons may stay visible, but
        // the BarTap button can't be pushed out.
        let fallback = SingleWindowBar.Fit(dividerLength: max(open, min(longest, narrowest * 0.25)), toggleExtra: 0, wanted: -1)
        guard let screen = referenceScreen(), let t = toggleItem?.button?.window?.frame, t.width > 0,
              let h = hiddenItem?.button?.window?.frame, h.width > 0 else {
            lastFit = "no frames: divider \(Int(fallback.dividerLength))"
            return fallback
        }
        let between = t.minX - h.maxX
        if between >= -1, between < 600 { lastBetween = max(0, between) }
        let forced = (UserDefaults.standard.object(forKey: "mb27.extra") as? Double).map { CGFloat($0) }
        let measure = SingleWindowBar.Measure(
            screenMinX: screen.frame.minX, screenWidth: screen.frame.width, narrowestWidth: narrowest,
            toggleMaxX: t.maxX, toggleNaturalWidth: toggleNaturalWidth, between: lastBetween, padding: itemPadding,
            openLength: open, menuMaxX: menuEdge(on: screen))
        guard var fit = SingleWindowBar.fit(measure, forcedWanted: forced) else {
            lastFit = "implausible frames (toggle maxX \(Int(t.maxX))): divider \(Int(fallback.dividerLength))"
            return fallback
        }
        // Hidden setting: never widen the BarTap button (no gap beside it; on a display wider than
        // twice the limit some hidden icons then stay in the bar).
        if UserDefaults.standard.bool(forKey: "mb27.dividerOnly") { fit.toggleExtra = 0 }
        lastFit = "screen \(Int(screen.frame.minX))+\(Int(screen.frame.width)) toggleMaxX \(Int(t.maxX)) natural \(Int(toggleNaturalWidth))"
            + " between \(Int(lastBetween)) padding \(Int(itemPadding)) menuEdge \(measure.menuMaxX.map { "\(Int($0))" } ?? "?")"
            + " wanted \(Int(fit.wanted)) → divider \(Int(fit.dividerLength)) + button \(Int(fit.toggleExtra))"
        return fit
    }

    /// The always-hidden divider while the hidden section is shown: it fills the room on its left,
    /// as far as one item may (the BarTap button can't help here, it sits further right).
    private func alwaysLength(open: CGFloat) -> CGFloat {
        let longest = SingleWindowBar.maxLength(narrowestWidth: narrowestScreenWidth(), padding: itemPadding)
        guard let screen = referenceScreen(), let a = alwaysItem?.button?.window?.frame, a.width > 0,
              a.maxX > screen.frame.minX, a.maxX <= screen.frame.maxX + 1 else { return max(open, min(longest, narrowestScreenWidth() * 0.25)) }
        let edge = menuEdge(on: screen) ?? screen.frame.minX + screen.frame.width * SingleWindowBar.unknownMenuShare
        let wanted = a.maxX - itemPadding - edge - SingleWindowBar.margin
        return max(open, min(longest, wanted.rounded(.down)))
    }

    private func setToggleExtra(_ extra: CGFloat) {
        guard let toggle = toggleItem else { return }
        let e = max(0, extra.rounded())
        guard abs(e - toggleExtra) > 0.5 else { return }
        toggleExtra = e
        toggle.length = e > 0 ? max(1, toggleNaturalWidth - itemPadding) + e : NSStatusItem.variableLength
        refreshToggleImage()
    }

    /// The button's icon; while the button is wide, the icon at its right end and nothing left of it.
    private func refreshToggleImage() {
        guard let button = toggleItem?.button, let base = baseToggleImage else { return }
        var image = base
        if toggleExtra > 0 {
            if let w = wideToggleImage, w.base === base, w.extra == toggleExtra {
                image = w.image
            } else {
                let size = NSSize(width: base.size.width + toggleExtra, height: base.size.height)
                let wide = NSImage(size: size, flipped: false) { rect in
                    base.draw(in: NSRect(x: rect.maxX - base.size.width, y: rect.minY, width: base.size.width, height: base.size.height))
                    return true
                }
                wide.isTemplate = base.isTemplate
                wideToggleImage = (base, toggleExtra, wide)
                image = wide
            }
        } else {
            wideToggleImage = nil
        }
        if button.image !== image { button.image = image }
    }

    /// Left edge (global x) of BarTap's divider on a display: status icons start there (macOS 27
    /// has no per-icon windows to ask).
    func statusAreaMinX(onScreenWithFrame frame: CGRect) -> CGFloat? {
        guard Self.singleWindowBar, let h = hiddenItem?.button?.window?.frame, h.width > 0,
              h.maxX > frame.minX, h.maxX <= frame.maxX + 1 else { return nil }
        return max(frame.minX, toggleExtra > 0 || h.width > 60 ? h.maxX : h.minX)
    }

    var singleWindowInfo: [String: Any] {
        ["on": Self.singleWindowBar, "fit": lastFit, "toggleExtra": Double(toggleExtra), "toggleNatural": Double(toggleNaturalWidth),
         "padding": Double(itemPadding), "hiddenLength": Double(hiddenItem?.length ?? -1),
         "toggleLength": Double(toggleItem?.length ?? -1),
         "rawToggle": toggleItem?.button?.window.map { NSStringFromRect($0.frame) } ?? "",
         "rawHidden": hiddenItem?.button?.window.map { NSStringFromRect($0.frame) } ?? "",
         "screens": NSScreen.screens.map { NSStringFromRect($0.frame) }]
    }

    /// Re-sends the collapsed length with a 1 pt nudge so macOS lays the bar out again
    /// (used once when a display ended up drawing a collapsed divider).
    func nudgeCollapsed() {
        for item in [hiddenItem, alwaysItem].compactMap({ $0 }) where item.length >= Self.minimumCollapsedLength {
            item.length = item.length == Self.collapsedLength ? Self.collapsedLength - 1 : Self.collapsedLength
        }
    }

    func updateToggleIcon(expanded: Bool, badge: Icons.Badge?, tooltip: String) {
        guard let button = toggleItem?.button else { return }
        let image = Icons.toggle(style: settings.iconStyle, expanded: expanded, badge: badge)
        baseToggleImage = image
        if Self.singleWindowBar { refreshToggleImage() } else if button.image !== image { button.image = image }
        if button.toolTip != tooltip { button.toolTip = tooltip }
    }

    /// The display hosting our status-item proxy windows. AppKit picks one per process and it is
    /// often *not* the main display, so all geometry is expressed relative to it.
    private func referenceScreen() -> NSScreen? {
        guard let f = toggleItem?.button?.window?.frame, f.width > 0 else { return nil }
        let p = NSPoint(x: f.maxX - 0.5, y: f.maxY - 0.5)
        if let s = NSScreen.screens.first(where: { NSPointInRect(p, $0.frame) }) { return s }
        // macOS 27 keeps our items' proxy windows outside the display vertically (the bar itself is
        // MenuBarAgent's window); their x still follows the layout, so go by x alone.
        guard Self.singleWindowBar else { return nil }
        return NSScreen.screens.first { p.x >= $0.frame.minX && p.x <= $0.frame.maxX }
    }

    /// Our items' positions as distance-from-the-right-edge, encoded as rects whose x axis is
    /// `-(distance from the bar's right edge)`. That distance is identical on every display (the
    /// same icons are laid out right-aligned on each bar), so it can be compared with any display's
    /// window list. On macOS 26 the real windows live in Control Center; AppKit keeps these proxies
    /// in sync with the actual layout.
    func ownFrames() -> OwnItemFrames {
        guard let screen = referenceScreen() else {
            return OwnItemFrames(toggle: .zero, hidden: .zero, alwaysHidden: alwaysItem == nil ? nil : .zero)
        }
        func normalized(_ item: NSStatusItem?) -> CGRect {
            guard let f = item?.button?.window?.frame, f.width > 0 else { return .zero }
            let rightDistance = screen.frame.maxX - f.maxX
            return CGRect(x: -rightDistance - f.width, y: 0, width: f.width, height: f.height)
        }
        return OwnItemFrames(toggle: normalized(toggleItem), hidden: normalized(hiddenItem),
                             alwaysHidden: alwaysItem.map { normalized($0) })
    }

    /// Stored order keys of our items, or nil while any of them has none yet.
    func ownKeys() -> OwnItemKeys? {
        let d = UserDefaults.standard
        func key(_ name: String) -> Double? { d.object(forKey: Self.preferredPositionKey(name)) as? Double }
        guard let toggle = key(Name.toggle), let hidden = key(Name.hidden) else { return nil }
        if alwaysItem != nil {
            guard let always = key(Name.always) else { return nil }
            return OwnItemKeys(toggle: toggle, hidden: hidden, alwaysHidden: always)
        }
        return OwnItemKeys(toggle: toggle, hidden: hidden, alwaysHidden: nil)
    }

    // MARK: Clean mode

    var isCleanModeOn: Bool { cleanSeparator != nil }

    /// Pushes *every* third-party icon (ours included) off the bar, leaving only the system's pinned
    /// Control Center and clock. An optional exit button sits right of the separator.
    func setCleanMode(_ on: Bool, showExit: Bool) {
        if on == isCleanModeOn { return }
        let d = UserDefaults.standard
        if on {
            d.set(0.0, forKey: Self.preferredPositionKey(Name.cleanExit))
            d.set(0.5, forKey: Self.preferredPositionKey(Name.clean))
            if showExit {
                let exit = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
                exit.autosaveName = Name.cleanExit
                exit.behavior = []
                if let b = exit.button {
                    b.image = Icons.symbol("eye.slash")
                    b.target = self
                    b.action = #selector(cleanExitClicked)
                    b.toolTip = L("Clean menu bar is on. Click to restore your icons.")
                    b.setAccessibilityLabel(L("Restore menu bar icons"))
                }
                cleanExit = exit
            }
            // Created narrow so macOS honours the seeded slot, then widened once it is placed.
            let sep = NSStatusBar.system.statusItem(withLength: Self.dividerLength)
            sep.autosaveName = Name.clean
            sep.behavior = []
            cleanSeparator = sep
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self, weak sep] in
                guard let self, let sep, self.cleanSeparator === sep else { return }
                // macOS 27 discards an item wider than half the display: stay just under it (icons
                // beyond that width stay in the bar).
                self.setLength(sep, Self.singleWindowBar
                    ? SingleWindowBar.maxLength(narrowestWidth: self.narrowestScreenWidth(), padding: self.itemPadding)
                    : Self.collapsedLength)
            }
        } else {
            if let s = cleanSeparator { NSStatusBar.system.removeStatusItem(s) }
            if let e = cleanExit { NSStatusBar.system.removeStatusItem(e) }
            cleanSeparator = nil
            cleanExit = nil
        }
    }

    // MARK: Clicks

    @objc private func buttonClicked(_ sender: NSStatusBarButton) {
        guard let event = NSApp.currentEvent else { return }
        if event.type == .rightMouseUp || event.modifierFlags.contains(.control) {
            let item = [toggleItem, hiddenItem, alwaysItem].compactMap { $0 }.first { $0.button === sender } ?? toggleItem
            if let item { showMenu(from: item) }
            return
        }
        if sender === alwaysItem?.button || event.modifierFlags.contains(.option) {
            onClick?(.toggleAll)
        } else {
            onClick?(.toggle)
        }
    }

    @objc private func cleanExitClicked() { onCleanExitClick?() }

    func showMenu(from item: NSStatusItem? = nil) {
        guard let menu = menuProvider?(), let item = item ?? toggleItem else { return }
        if Self.singleWindowBar, popUpBelowPointer(menu) { return }
        // Attaching the menu for a single click is the standard way to get native placement.
        item.menu = menu
        item.button?.performClick(nil)
        item.menu = nil
    }

    /// macOS 27: our buttons only stand in for what MenuBarAgent draws (their windows sit off the
    /// display), so a menu attached to them doesn't reliably open. Open it right under the pointer
    /// instead, when the pointer is in a menu bar (a click on our item); false otherwise.
    private func popUpBelowPointer(_ menu: NSMenu) -> Bool {
        let p = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { NSPointInRect(p, $0.frame) }) else { return false }
        let bar = max(screen.frame.maxY - screen.visibleFrame.maxY, NSStatusBar.system.thickness)
        guard bar < 80, p.y >= screen.frame.maxY - bar - 2 else { return false }
        // Returns once the menu closes, whether or not something was chosen.
        menu.popUp(positioning: nil, at: NSPoint(x: p.x - 10, y: screen.frame.maxY - bar - 2), in: nil)
        return true
    }
}
