import ChalkKit
import UIKit

/// Hosts Settings in its own window. A Catalyst `.formSheet` is modal and
/// cannot be resized or moved; as a scene it is an ordinary window, so resize,
/// move, minimise and frame memory come from the system. This delegate only
/// sets the floor size and the title.
final class SettingsSceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?

    func scene(
        _ scene: UIScene,
        willConnectTo session: UISceneSession,
        options connectionOptions: UIScene.ConnectionOptions
    ) {
        guard let windowScene = scene as? UIWindowScene else { return }

        // The zero-width marker keeps the glue's tab strip off this window;
        // the visible part still reads "Settings".
        windowScene.title = WindowRouting.noChromeTitle("Settings")
        // A floor, not a ceiling: the whole point is that the user sizes it.
        // Below this the rail and the three shortcut columns start clipping.
        windowScene.sizeRestrictions?.minimumSize = ChalkMetrics.settingsMinWindowSize
        windowScene.sizeRestrictions?.maximumSize = CGSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude)

        let settings = SettingsContainerViewController()
        settings.isWindowed = true
        // The broadcast reaches the editor windows only; this window re-pins
        // itself so a new theme or appearance shows here too.
        settings.onChange = { [weak settings] in
            SettingsBroadcast.applyGeneralSettings()
            settings?.navigationController?.applyChalkAppearance()
            settings?.applyChalkAppearance()
        }
        settings.onSnippetsChange = { SettingsBroadcast.applySnippetChange() }
        // In a window there is no presenter to hand focus back to, and closing
        // means closing the window.
        settings.onDismiss = { [weak self] in self?.closeWindow() }

        let nav = UINavigationController(rootViewController: settings)
        let window = UIWindow(windowScene: windowScene)
        window.rootViewController = nav
        window.makeKeyAndVisible()
        self.window = window
        // Pin to the app's forced appearance: a scene in its own window would
        // otherwise follow the system's, as form sheets do.
        nav.applyChalkAppearance()
        settings.applyChalkAppearance()

        windowScene.titlebar?.titleVisibility = .visible
    }

    /// Settings deliberately does not persist: returning nil keeps a Settings
    /// window from reappearing on relaunch as a ghost scene.
    func stateRestorationActivity(for scene: UIScene) -> NSUserActivity? { nil }

    private func closeWindow() {
        guard let session = window?.windowScene?.session else { return }
        UIApplication.shared.requestSceneSessionDestruction(session, options: nil)
    }
}

/// Settings edits are process-wide, so they fan out to every open window: the
/// Settings scene has no presenter to route through.
enum SettingsBroadcast {
    /// `roots` defaults to every live window and is evaluated at call time, so
    /// production callers stay `applyGeneralSettings()`. Tests pass their own
    /// root: one built directly is attached to no scene, so `everyLiveRoot()`
    /// cannot see it.
    static func applyGeneralSettings(
        roots: @autoclosure () -> [RootSplitViewController] =
            RootSplitViewController.everyLiveRoot()
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

    static func applySnippetChange() {
        SnippetLibrary.shared.invalidate()
        guard let content = SnippetLibrary.shared.composedContent() else { return }
        for root in RootSplitViewController.everyLiveRoot() {
            root.pushHsnips(content)
        }
    }
}
