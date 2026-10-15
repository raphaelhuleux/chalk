import UIKit
import ChalkKit

extension ThemePreference {
    /// The window's interface style override for this preference.
    var interfaceStyle: UIUserInterfaceStyle {
        switch self {
        case .auto: return .unspecified
        case .light: return .light
        case .dark: return .dark
        }
    }
}

/// The column widths, in this shell's points. Catalyst runs the iPad idiom at 77%, so the stored
/// values are 1/0.77 of a Mac point; the AppKit shell converts once on migration.
extension Preferences {
    private static let sidebarWidthKey = "chalk.sidebarWidth"
    private static let outlinePanelWidthKey = "chalk.outlinePanelWidth"

    /// Bounds for the resizable Library column. The Catalyst min window (880x560) still clears a
    /// 560pt sidebar plus a ~320pt editor column.
    static let sidebarWidthRange: ClosedRange<CGFloat> = 220...560

    /// Last-used Library column width. Clamped on read and write so a stale value can never wedge
    /// the column.
    static var sidebarWidth: CGFloat {
        get { CGFloat(storedDouble(sidebarWidthKey, default: Double(ChalkMetrics.sidebarWidth),
                                   in: widthRange)) }
        set { setStoredDouble(Double(newValue), sidebarWidthKey, in: widthRange) }
    }

    /// Last-used outline panel width (⌘K), persisted like `sidebarWidth` and
    /// clamped into the same range.
    static var outlinePanelWidth: CGFloat {
        get { CGFloat(storedDouble(outlinePanelWidthKey, default: Double(ChalkMetrics.sidebarWidth),
                                   in: widthRange)) }
        set { setStoredDouble(Double(newValue), outlinePanelWidthKey, in: widthRange) }
    }

    private static var widthRange: ClosedRange<Double> {
        Double(sidebarWidthRange.lowerBound)...Double(sidebarWidthRange.upperBound)
    }
}

extension UIViewController {
    /// Pins this controller to the app's light/dark preference and colour theme. Needed wherever a
    /// controller may land in its own UIWindow (Catalyst form sheets, alerts) and would drift to
    /// the system style and the default theme.
    func applyChalkAppearance() {
        overrideUserInterfaceStyle = Preferences.themePreference.interfaceStyle
        traitOverrides.chalkTheme = Preferences.colorTheme
    }

    /// Present above whatever is already presented: UIKit silently drops a presentation on a
    /// controller that is presenting something else (a sheet, another alert).
    func presentOnTop(_ controller: UIViewController) {
        var host: UIViewController = self
        while let presented = host.presentedViewController, !presented.isBeingDismissed {
            host = presented
        }
        host.present(controller, animated: true)
    }

    /// A one-button notice in the app's appearance, presented on top.
    func presentChalkNotice(title: String?, message: String?) {
        presentOnTop(UIAlertController.chalkNotice(title: title, message: message))
    }
}

extension UIAlertController {
    /// An OK-only alert pinned to the app's appearance: on Catalyst an alert is its own window and
    /// would otherwise follow the system's.
    static func chalkNotice(title: String?, message: String?) -> UIAlertController {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.applyChalkAppearance()
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        return alert
    }
}
