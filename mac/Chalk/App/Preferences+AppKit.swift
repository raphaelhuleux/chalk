import AppKit
import ChalkKit

extension ThemePreference {
    /// The window appearance this preference forces; nil hands the window back to the system.
    var appearance: NSAppearance? {
        switch self {
        case .auto: return nil
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        }
    }
}

/// The column widths, in Mac points, under this shell's own keys. The Catalyst shell stores its
/// widths in iPad-idiom points (1/0.77 of a Mac point) under the original keys; a first read with
/// no AppKit value converts the Catalyst one, so an upgrade keeps the column where it was.
extension Preferences {
    /// Internal so the test hosts snapshot and restore the real keys.
    static let sidebarWidthKey = "chalk.sidebarWidth.appkit"
    static let outlinePanelWidthKey = "chalk.outlinePanelWidth.appkit"
    private static let catalystSidebarWidthKey = "chalk.sidebarWidth"
    private static let catalystOutlinePanelWidthKey = "chalk.outlinePanelWidth"
    /// The Catalyst shell's idiom scale, for the one-time conversion.
    private static let catalystDisplayScale = 1 / 0.77

    /// Bounds for the resizable Library column and the outline panel.
    static let sidebarWidthRange = ChalkMetrics.sidebarWidthRange

    /// Last-used Library column width. Clamped on read and write so a stale value can never wedge
    /// the column.
    static var sidebarWidth: CGFloat {
        get { migratedWidth(sidebarWidthKey, from: catalystSidebarWidthKey) }
        set { setStoredDouble(Double(newValue), sidebarWidthKey, in: widthRange) }
    }

    /// Last-used outline panel width (⌘K), persisted like `sidebarWidth` and clamped into the
    /// same range.
    static var outlinePanelWidth: CGFloat {
        get { migratedWidth(outlinePanelWidthKey, from: catalystOutlinePanelWidthKey) }
        set { setStoredDouble(Double(newValue), outlinePanelWidthKey, in: widthRange) }
    }

    private static var widthRange: ClosedRange<Double> {
        Double(sidebarWidthRange.lowerBound)...Double(sidebarWidthRange.upperBound)
    }

    private static func migratedWidth(_ key: String, from catalystKey: String) -> CGFloat {
        if UserDefaults.standard.object(forKey: key) == nil,
           UserDefaults.standard.object(forKey: catalystKey) != nil {
            let catalyst = UserDefaults.standard.double(forKey: catalystKey)
            if catalyst > 0 { setStoredDouble(catalyst / catalystDisplayScale, key, in: widthRange) }
        }
        return CGFloat(storedDouble(key, default: Double(ChalkMetrics.sidebarWidth), in: widthRange))
    }
}
