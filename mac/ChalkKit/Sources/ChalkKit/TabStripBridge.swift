import CoreGraphics
import Foundation

/// The Catalyst tab-strip bridge contract: notification names, userInfo
/// keys, row anatomy and metrics, shared by the UIKit strip
/// (`HeaderTabStrip`) and the AppKit titlebar strip (`ChalkTabStrip`, in
/// ChalkAppKitGlue, since Catalyst toolbar custom views never get touches).
///
/// This file is COMPILED INTO the glue bundle (see mac/project.yml), so it is
/// the single definition both sides read; hand-copied values drifted before
/// (docs/issues/2026-08-18-mac-tabs-vanish-when-the-library-is-open.md).
/// Keep it pure Foundation/CoreGraphics: no UIKit or AppKit types. The row's
/// colours are the theme's (`ThemePalette.tab*`, ChalkTheme.swift).
public enum TabStripBridge {
    // MARK: - Notification names

    /// UIKit → strip: the FULL snapshot of a scene's tabs (`tabs`, tagged
    /// with `windowNumber`). Never an incremental diff.
    public static let update = Notification.Name("chalk.tabstrip.update")
    /// Strip → UIKit: a click on a name, its ×, the "+" or the overflow menu
    /// (`action`, plus `id`/`index`).
    public static let action = Notification.Name("chalk.tabstrip.action")
    /// Strip → UIKit: "I have no state for my window, push it again."
    public static let needsState = Notification.Name("chalk.tabstrip.needsState")
    /// Full-height sidebar: the bound scene posts the sidebar/editor divider's
    /// X (MAC points, window coords; 0 = sidebar hidden) so the names start
    /// at the editor column and slide back to the lights when it hides.
    public static let leadingInset = Notification.Name("chalk.tabstrip.leadingInset")
    /// Glue → UIKit window pairing, posted at toolbar attach, on key
    /// transitions and on retry. Payload: `windowNumber`; `uiWindow` and/or
    /// `token` as pairing evidence; `isKeyFact` when key now; `isFullScreen`,
    /// because a window restored into full screen posts that fact before any
    /// scene has bound.
    public static let bind = Notification.Name("chalk.tabstrip.bind")
    /// Zen's toolbar toggle: Catalyst has no handle on the NSWindow's
    /// toolbar, so the glue flips `NSWindow.toolbar.isVisible`.
    public static let setVisible = Notification.Name("chalk.tabstrip.setVisible")
    /// Auto-hide's windowed-Mac lane: fade the names and band WITHOUT
    /// touching toolbar visibility (`setVisible` collapses the titlebar).
    public static let setFaded = Notification.Name("chalk.tabstrip.setFaded")
    /// The palette's wash, carried into the titlebar a UIKit scrim cannot
    /// reach (`ChromeScrim`).
    public static let setScrimmed = Notification.Name("chalk.tabstrip.setScrimmed")

    /// A click in the titlebar band over the Library panel. AppKit owns those
    /// pixels, so the band forwards the point (`x`/`y`) instead of letting it
    /// die as a window-drag grip.
    public static let titlebarBandClick = Notification.Name("chalk.titlebar.bandClick")
    /// The pointer entered or left the titlebar (`inside`): UIKit hover
    /// recognizers never fire over AppKit's pixels.
    public static let titlebarPointerInBand = Notification.Name("chalk.titlebar.pointerInBand")

    /// Glue → UIKit: a shell key equivalent the AppKit responder chain saw
    /// first (⌘P and friends).
    public static let shellKey = Notification.Name("chalk.shell.key")
    /// Middle-click close for the full-screen (UIKit) strip: Catalyst gives
    /// UIKit only two buttons, so the glue forwards the release point (`x`/`y`).
    public static let shellMiddleClick = Notification.Name("chalk.shell.middleClick")
    /// UIKit → glue: the pointer entered or left a horizontal resize grip
    /// (`inside`); UIKit has no resize cursor, so the glue sets one.
    public static let shellResizeCursor = Notification.Name("chalk.shell.resizeCursor")

    /// Full-screen fact from the glue (`on`): macOS rehosts the toolbar into
    /// an opaque system strip there, so the scene swaps in the UIKit band.
    public static let windowFullscreen = Notification.Name("chalk.window.fullscreen")
    /// UIKit → glue: the app's appearance (`style`) and colour theme
    /// (`theme`). NSColor resolves against the window's NSAppearance, which
    /// follows the system, not the app, and knows nothing of the theme.
    public static let windowAppearance = Notification.Name("chalk.window.appearance")

    /// Debug/verification lane: toggle the window's full-screen state without
    /// a synthetic keystroke.
    public static let debugToggleFullScreen = Notification.Name("chalk.debug.toggleFullScreen")

    /// Every bridge name, for the uniqueness guard in ChalkKit's tests. Add a
    /// name above and it belongs here too.
    public static let allNames: [Notification.Name] = [
        update, action, needsState, leadingInset, bind,
        setVisible, setFaded, setScrimmed,
        titlebarBandClick, titlebarPointerInBand,
        shellKey, shellMiddleClick, shellResizeCursor,
        windowFullscreen, windowAppearance,
        debugToggleFullScreen,
    ]

    // MARK: - userInfo keys

    /// Every bridge message names its NSWindow; a receiver ignores messages
    /// for any other window number.
    public static let windowNumberKey = "windowNumber"
    /// The paired UIWindow object (KVC), primary pairing evidence in a `bind`.
    public static let uiWindowKey = "uiWindow"
    /// The scene's published title token, the public-API pairing fallback.
    public static let tokenKey = "token"
    /// `true` when the posting window is key at post time.
    public static let isKeyFactKey = "isKeyFact"
    /// The posting window's full-screen state, carried on every `bind`.
    public static let isFullScreenKey = "isFullScreen"

    /// The tab snapshot array in an `update`.
    public static let tabsKey = "tabs"
    /// A tab's id — and the id an `action` names.
    public static let idKey = "id"
    public static let nameKey = "name"
    public static let dirtyKey = "dirty"
    public static let activeKey = "active"
    public static let previewKey = "preview"
    /// Parent folder for the label's prefix. Omitted (not "") when absent.
    public static let folderKey = "folder"
    /// Which strip gesture fired, in an `action`.
    public static let actionKey = "action"
    /// Drop position, in a reorder `action`.
    public static let indexKey = "index"

    public static let visibleKey = "visible"
    public static let fadedKey = "faded"
    public static let scrimmedKey = "scrimmed"
    /// Sidebar/editor divider X, MAC points, window coords; 0 = hidden.
    public static let dividerXKey = "dividerX"
    /// Outline panel width, MAC points, taken off the strip's trailing edge.
    public static let outlineWidthKey = "outlineWidth"
    /// Animation duration (seconds) accompanying a fade or a slide.
    public static let durationKey = "duration"
    /// Animation curve name accompanying a slide (docs/motion.md).
    public static let curveKey = "curve"
    /// Forwarded point, MAC points, window coords, top-left origin.
    public static let xKey = "x"
    public static let yKey = "y"
    /// Boolean payload of `windowFullscreen`.
    public static let onKey = "on"
    /// Boolean payload of the pointer-crossing messages.
    public static let insideKey = "inside"
    /// Appearance name in `windowAppearance`.
    public static let styleKey = "style"
    /// `ChalkTheme` raw value in `windowAppearance`.
    public static let themeKey = "theme"

    // MARK: - Payload values
    //
    // The raw values are the wire format.

    /// Which strip gesture fired: the `actionKey` value of an `action`.
    public enum Action: String, Sendable {
        case new, select, close, move
    }

    /// A slide's curve: the `curveKey` value of a `leadingInset` (docs/motion.md).
    public enum SlideCurve: String, Sendable {
        case easeOut = "ease-out"
        case easeInOut = "ease-in-out"
    }

    /// The app's appearance: the `styleKey` value of a `windowAppearance`.
    /// `.system` hands the window's appearance back to the OS.
    public enum Appearance: String, Sendable {
        case dark, light, system
    }
}

/// Pure rules for the tab name row's anatomy, read by both strips.
public enum TabStripPolicy {
    /// What occupies a tab's trailing slot. A dirty tab shows the dot, a clean
    /// one the close ×. Never both — closing an unsaved tab goes through the
    /// dot's hover swap, ⌘W, or the context menu.
    public enum SlotContent: Equatable, Sendable {
        case dot
        case close
    }

    public static func slotContent(isDirty: Bool) -> SlotContent {
        isDirty ? .dot : .close
    }

    /// Whether the slot takes LAYOUT space inside the item.
    ///
    /// Reserved when something rests in it (active tab, unsaved dot). A clean
    /// background tab's hover × hangs in the following gap at the same offset,
    /// so revealing it never reflows the row.
    public static func slotIsReserved(isActive: Bool, isDirty: Bool) -> Bool {
        isActive || isDirty
    }

    /// Whether a tab's filename run takes the synthetic slant.
    ///
    /// Only the ACTIVE preview slants: `isPreview` is true of every
    /// uncommitted tab, but `open(url:reuseCurrentIfClean:)` only reuses the
    /// active one, so that is the only tab a sidebar click will replace.
    public static func isOblique(isActive: Bool, isPreview: Bool) -> Bool {
        isActive && isPreview
    }

    /// The immediate parent folder name for the label's dim prefix
    /// ("test-docs" for …/test-docs/least-squares.md; rendering appends "/").
    /// Nil when there is no meaningful parent (drafts have no URL at all;
    /// files at a volume root have no folder worth naming).
    public static func folderPrefix(for url: URL) -> String? {
        let parent = url.deletingLastPathComponent().lastPathComponent
        switch parent {
        case "", "/", ".", "..": return nil
        default: return parent
        }
    }

    /// Which tabs actually need that prefix: the ones whose filename is open
    /// more than once.
    ///
    /// Computed over the whole open set. Returns one flag per input, in order.
    public static func needsFolderPrefix(names: [String]) -> [Bool] {
        var counts: [String: Int] = [:]
        for name in names { counts[name, default: 0] += 1 }
        return names.map { (counts[$0] ?? 0) > 1 }
    }

    /// A tab's row in the overflow menu: the full "folder/name" label, so two
    /// tabs sharing a filename stay distinguishable there too.
    public static func menuTitle(name: String, folder: String?) -> String {
        (folder.map { "\($0)/" } ?? "") + name
    }

    /// Whether the underline slides to the active name rather than being
    /// placed: only a change of active tab, from an underline already on
    /// screen, moves (docs/motion.md "Tab switch"). Each host adds its own
    /// Reduce Motion gate.
    public static func underlineSlides<ID: Equatable>(
        wasHidden: Bool, previousID: ID?, newID: ID
    ) -> Bool {
        !wasHidden && previousID != nil && previousID != newID
    }

    /// One drag-reorder step: the slot the dragged item at `index` moves to
    /// when its probe sits at `probeX`, or nil to stay. It passes a
    /// neighbour once the probe crosses that neighbour's midpoint
    /// (`midXs[i]`, the arranged items' laid-out midpoints, `index`
    /// included); the left neighbour is checked first. Callers loop until
    /// nil so a fast drag can cross several items in one event.
    public static func reorderStep(index: Int, probeX: CGFloat, midXs: [CGFloat]) -> Int? {
        if index > 0, probeX < midXs[index - 1] { return index - 1 }
        if index < midXs.count - 1, probeX > midXs[index + 1] { return index + 1 }
        return nil
    }
}

/// Chrome animation clocks both toolkits run on (docs/motion.md, Tokens), so
/// the AppKit strip and the UIKit chrome cannot drift apart.
public enum ChromeMotion {
    /// Tab close, cover fades, the tab-switch cross-fade and the underline
    /// slide (`ChalkMetrics.motionFast` on the UIKit side).
    public static let fast: TimeInterval = 0.15
    /// The auto-hide slide and fade, and the glue's default for an untagged
    /// `setFaded` post.
    public static let autoHide: TimeInterval = 0.22
}

/// The tab row's spacing and size tokens, in MAC points (spec px at 1×).
///
/// The AppKit strip uses these raw (the titlebar escapes the 0.77× Catalyst
/// scale); the UIKit strip wraps each in `ChalkMetrics.s()` to land the same
/// physical size.
public enum TabStripMetrics {
    /// The name row's own height.
    public static let stripHeight: CGFloat = 46
    /// Between name items.
    public static let gap: CGFloat = 12
    /// Inside each item, both sides.
    public static let labelPadding: CGFloat = 8
    /// Label → trailing slot.
    public static let innerGap: CGFloat = 8
    /// Label truncation cap.
    public static let maxTabWidth: CGFloat = 290
    /// The active name's accent underline.
    public static let underlineHeight: CGFloat = 2
    /// …and its distance below the label.
    public static let underlineGap: CGFloat = 7
    /// Unsaved dot.
    public static let dotSize: CGFloat = 5
    /// The trailing slot that holds the dot or the close ×.
    public static let slotWidth: CGFloat = 14
    /// The trailing "+" button's box…
    public static let newTabSize = CGSize(width: 28, height: 34)
    /// …and the ink inside it (NewTabGlyphSizeTests measures the ink).
    public static let newTabGlyph: CGFloat = 10
    /// The overflow chevron's symbol point size.
    public static let overflowGlyph: CGFloat = 10
    /// The close ×'s symbol point size, inside the trailing slot.
    public static let closeGlyph: CGFloat = 7.5
    /// Mono name size (spec value).
    public static let fontSize: CGFloat = 12
    /// Divider → first item edge; with the item's 8pt padding the first label
    /// lands 22pt past the divider.
    public static let dividerGap: CGFloat = 14

    /// tan(12°): the preview tab's synthetic slant (no italic face is
    /// bundled). Not a length: never pass this through `s()`.
    public static let obliqueSlant: CGFloat = 0.2126

    // Placement inside the NSToolbar (see layoutInTitlebar). The UIKit band
    // reuses the first two for its trailing padding and its full-screen
    // leading edge (`ChalkMetrics.headerPadding`, `tabStripLeading`).

    /// Gap kept clear at the titlebar's trailing edge.
    public static let trailingMargin: CGFloat = 14
    /// Gap between the traffic lights and the first name.
    public static let trafficLightGap: CGFloat = 16
    /// Leading edge used only before the window's buttons can be measured.
    /// AppKit only.
    public static let fallbackLeading: CGFloat = 91
}
