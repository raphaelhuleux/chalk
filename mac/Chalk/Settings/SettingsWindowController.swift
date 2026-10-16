import AppKit
import ChalkKit

/// Settings in its own window, one per app: resizable, movable, its frame
/// remembered by the system, and pinned to the app's forced appearance (a
/// window would otherwise follow the system's). Owned by the app delegate.
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    let container = SettingsContainerViewController()

    init() {
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: ChalkMetrics.settingsDefaultSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false)
        window.title = "Settings"
        // A floor, not a ceiling: the whole point is that the user sizes it.
        // Below this the rail and the three shortcut columns start clipping.
        window.contentMinSize = ChalkMetrics.settingsMinWindowSize
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        window.contentViewController = container
        window.setContentSize(ChalkMetrics.settingsDefaultSize)
        // Centre only on first use: a saved frame wins.
        if !window.setFrameUsingName("chalk.settings") { window.center() }
        window.setFrameAutosaveName("chalk.settings")
        pinAppearance()

        // The broadcast reaches the editor windows; this window re-pins
        // itself so a new theme or appearance shows here too.
        container.onChange = { [weak self] in
            SettingsBroadcast.applyGeneralSettings()
            self?.pinAppearance()
        }
        container.onSnippetsChange = { SettingsBroadcast.applySnippetChange() }
        // Done, Esc and ⌘, all close the window.
        container.onDismiss = { [weak self] in self?.close() }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// The app's forced appearance, or the system's for Auto.
    func pinAppearance() {
        window?.appearance = Preferences.themePreference.appearance
        window?.attachedSheet?.appearance = Preferences.themePreference.appearance
    }

    /// The window closing is not a snippet edit being lost: a coalesced push
    /// still lands.
    func windowWillClose(_ notification: Notification) {
        container.flushPendingWork()
    }
}

/// Settings edits are process-wide, so they fan out to every open window: the
/// Settings window has no presenter to route through.
enum SettingsBroadcast {
    /// `roots` defaults to every live window and is evaluated at call time, so
    /// production callers stay `applyGeneralSettings()`. Tests pass their own
    /// root: one built directly is in no window, so `everyLiveRoot()` cannot
    /// see it.
    static func applyGeneralSettings(
        roots: @autoclosure () -> [RootSplitViewController] = RootSplitViewController.everyLiveRoot()
    ) {
        for root in roots() {
            root.applyThemePreference()
            root.applyEditorFontScale()
            root.applyEditorMeasure()
            root.applyEditorLineHeight()
            root.applyTextAlignment()
            root.applyHeadingColors()
            root.applyEditorConfig()
        }
    }

    static func applySnippetChange(
        roots: @autoclosure () -> [RootSplitViewController] = RootSplitViewController.everyLiveRoot()
    ) {
        SnippetLibrary.shared.invalidate()
        guard let content = SnippetLibrary.shared.composedContent() else { return }
        for root in roots() {
            root.pushHsnips(content)
        }
    }
}

/// Settings layout rules, as pure functions so they are unit-testable without
/// presenting anything.
enum SettingsPresentation {
    /// The rail width for a given container width. In a narrow window the
    /// rail shrinks rather than squeezing the three-column shortcuts table.
    static func railWidth(forContainerWidth width: CGFloat) -> CGFloat {
        let full: CGFloat = 190
        guard width > 0 else { return full }
        // At most a quarter of the container; the floor still fits "Linear algebra".
        return max(120, min(full, width * 0.25))
    }
}
