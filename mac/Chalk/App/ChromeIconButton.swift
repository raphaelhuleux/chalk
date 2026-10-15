import UIKit
import ChalkKit

/// The chrome icon button (VisualGlass .footer-btn): 30×26, radius 7, tertiary
/// tint idle → chrome foreground over a faint fill on hover/press. Every
/// button of the utility pill (FooterBarView) is one, so each chrome glyph
/// reads as the same control.
enum ChromeIconButton {
    static func make(_ symbol: String, label: String, action: @escaping () -> Void) -> UIButton {
        let button = styled(symbol, label: label)
        button.addAction(UIAction { _ in action() }, for: .touchUpInside)
        return button
    }

    /// Same control, but clicking opens `menu` instead of firing an action —
    /// used by the editing-mode picker in the pill.
    static func makeMenu(_ symbol: String, label: String, menu: UIMenu) -> UIButton {
        let button = styled(symbol, label: label)
        button.menu = menu
        button.showsMenuAsPrimaryAction = true
        return button
    }

    /// The chrome glyph at the pill's symbol size, for a button built here and
    /// for a later swap of its image (`FooterBarView.setEditingMode`).
    static func glyph(_ symbol: String) -> UIImage? {
        UIImage(
            systemName: symbol,
            withConfiguration: UIImage.SymbolConfiguration(
                pointSize: ChalkMetrics.headerIconPointSize, weight: .regular))
    }

    private static func styled(_ symbol: String, label: String) -> UIButton {
        let button = UIButton(type: .system)
        var cfg = UIButton.Configuration.plain()
        cfg.image = glyph(symbol)
        cfg.contentInsets = .zero
        button.configuration = cfg
        button.accessibilityLabel = label
        button.layer.cornerRadius = ChalkMetrics.rowCornerRadius
        button.layer.cornerCurve = .continuous
        button.isPointerInteractionEnabled = false // the hover fill below replaces the system lift
        button.configurationUpdateHandler = { btn in
            let engaged = btn.isHighlighted || btn.isHovered
            btn.tintColor = engaged ? .chalkChromeFg : .chalkChromeFgTertiary
            btn.backgroundColor = engaged ? .chalkRowHoverBackground : .clear
        }
        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(equalToConstant: ChalkMetrics.footerButtonSize.width),
            button.heightAnchor.constraint(equalToConstant: ChalkMetrics.footerButtonSize.height),
        ])
        return button
    }
}

extension ChromeIconButton {
    /// The editing-mode picker menu: one checkmarked row per mode, rebuilt on
    /// every open (deferred + uncached) so the checkmark reflects the live
    /// preference.
    static func editingModeMenu(
        current: @escaping () -> EditingMode,
        onSelect: @escaping (EditingMode) -> Void
    ) -> UIMenu {
        UIMenu(title: "Editing Mode", options: .singleSelection, children: [
            UIDeferredMenuElement.uncached { completion in
                let active = current()
                completion(EditingMode.allCases.map { mode in
                    UIAction(
                        title: mode.title,
                        image: UIImage(systemName: mode.symbol),
                        state: mode == active ? .on : .off
                    ) { _ in onSelect(mode) }
                })
            },
        ])
    }
}
