import AppKit
import ChalkKit

/// The utility pill (VisualGlass .utility-strip): a floating glass capsule in
/// the window's bottom-leading corner holding the chrome actions (toggle
/// Sidebar, Settings, Quick Open, Outline, editing mode).
///
/// The only home those actions have, and it stands in every state rather
/// than handing its buttons back and forth. Glass because it floats over live
/// text. New File is absent: the tab row's + covers it. The host owns only
/// its corner placement; this view is self-sizing.
final class FooterBarView: NSView {
    var onToggleSidebar: (() -> Void)?
    var onQuickOpen: (() -> Void)?
    var onOutline: (() -> Void)?
    var onSettings: (() -> Void)?
    /// Editing-mode picker: the button opens a checkmarked menu; selection
    /// routes here. `currentEditingMode` feeds the checkmark at open time.
    var onSelectEditingMode: ((EditingMode) -> Void)?
    var currentEditingMode: (() -> EditingMode)?

    private var modeButton: ChromeIconButton?

    private let glass = ChalkGlassView(
        style: .glass, cornerRadius: ChalkMetrics.utilityStripRadius, interactive: true)
    private let icons = NSStackView()

    /// Width that snugly fits the icon row + its padding; the host pins the
    /// pill to this so it always hugs the icons.
    var pillWidth: CGFloat {
        let buttons = CGFloat(icons.arrangedSubviews.count) * ChalkMetrics.footerButtonSize.width
        let gaps = CGFloat(max(0, icons.arrangedSubviews.count - 1)) * icons.spacing
        return ChalkMetrics.utilityStripPadding * 2 + buttons + gaps
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        // Reading order, left to right: toggle, settings, search, outline, mode.
        let buttons = [
            ChromeIconButton.make("sidebar.left", label: "Toggle Sidebar") { [weak self] in
                self?.onToggleSidebar?()
            },
            ChromeIconButton.make("gearshape", label: "Settings") { [weak self] in
                self?.onSettings?()
            },
            ChromeIconButton.make("magnifyingglass", label: "Quick Open") { [weak self] in
                self?.onQuickOpen?()
            },
            ChromeIconButton.make("list.bullet.indent", label: "Outline") { [weak self] in
                self?.onOutline?()
            },
            ChromeIconButton.makeMenu(
                Preferences.editingMode.symbol,
                label: "Editing Mode: \(Preferences.editingMode.title)",
                menu: ChromeIconButton.editingModeMenu(
                    current: { [weak self] in
                        self?.currentEditingMode?() ?? Preferences.editingMode
                    },
                    onSelect: { [weak self] mode in self?.onSelectEditingMode?(mode) }
                )
            ),
        ]
        modeButton = buttons[4]
        buttons.forEach { icons.addArrangedSubview($0) }
        icons.orientation = .horizontal
        icons.spacing = 4
        icons.alignment = .centerY
        icons.translatesAutoresizingMaskIntoConstraints = false

        glass.translatesAutoresizingMaskIntoConstraints = false
        addSubview(glass)
        glass.contentView.addSubview(icons)

        NSLayoutConstraint.activate([
            glass.topAnchor.constraint(equalTo: topAnchor),
            glass.leadingAnchor.constraint(equalTo: leadingAnchor),
            glass.trailingAnchor.constraint(equalTo: trailingAnchor),
            glass.bottomAnchor.constraint(equalTo: bottomAnchor),
            icons.leadingAnchor.constraint(
                equalTo: glass.contentView.leadingAnchor, constant: ChalkMetrics.utilityStripPadding),
            icons.trailingAnchor.constraint(
                equalTo: glass.contentView.trailingAnchor, constant: -ChalkMetrics.utilityStripPadding),
            icons.centerYAnchor.constraint(equalTo: glass.contentView.centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// Reflect the current mode on the mode button (icon + accessibility).
    func setEditingMode(_ mode: EditingMode) {
        modeButton?.setSymbol(mode.symbol, label: "Editing Mode: \(mode.title)")
    }
}
