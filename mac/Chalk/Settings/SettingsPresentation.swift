import UIKit
import ChalkKit

/// Settings layout rules, as pure functions so they are unit-testable without
/// presenting anything.
enum SettingsPresentation {

    /// The rail width for a given container width. In a narrow window the rail shrinks rather than
    /// squeezing the three-column shortcuts table.
    static func railWidth(forContainerWidth width: CGFloat) -> CGFloat {
        let full = ChalkMetrics.s(190)
        guard width > 0 else { return full }
        // At most a quarter of the container; the floor still fits "Linear algebra".
        return max(ChalkMetrics.s(120), min(full, width * 0.25))
    }
}
