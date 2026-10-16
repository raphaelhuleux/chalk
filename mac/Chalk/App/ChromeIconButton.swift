import AppKit

extension NSView {
    /// Replace `stored` with a fresh tracking area over `rect` (the whole
    /// view by default) that reports enter and exit while the window is key.
    /// Every hover-styled view does this in `updateTrackingAreas`.
    func chalkReplaceTrackingArea(_ stored: inout NSTrackingArea?, rect: NSRect? = nil,
                                  userInfo: [AnyHashable: Any]? = nil) {
        if let stored { removeTrackingArea(stored) }
        var options: NSTrackingArea.Options = [.mouseEnteredAndExited, .activeInKeyWindow]
        if rect == nil { options.insert(.inVisibleRect) }
        let area = NSTrackingArea(rect: rect ?? bounds, options: options, owner: self, userInfo: userInfo)
        addTrackingArea(area)
        stored = area
    }
}
import ChalkKit

/// The chrome icon button (VisualGlass .footer-btn): 30×26, radius 7, tertiary
/// tint idle → chrome foreground over a faint fill on hover/press. Every
/// button of the utility pill (FooterBarView) is one, so each chrome glyph
/// reads as the same control.
final class ChromeIconButton: NSView {
    private let imageView = NSImageView()
    private var action: (() -> Void)?
    /// The editing-mode picker's menu, opened on click instead of firing `action`.
    private var menuBuilder: (() -> NSMenu)?
    private var hovering = false
    private var pressed = false
    private var trackingArea: NSTrackingArea?
    private(set) var symbol: String

    static func make(_ symbol: String, label: String, action: @escaping () -> Void) -> ChromeIconButton {
        let button = ChromeIconButton(symbol: symbol, label: label)
        button.action = action
        return button
    }

    /// Same control, but clicking opens the menu `menu` builds instead of
    /// firing an action; built on every open so the checkmark is live.
    static func makeMenu(_ symbol: String, label: String, menu: @escaping () -> NSMenu) -> ChromeIconButton {
        let button = ChromeIconButton(symbol: symbol, label: label)
        button.menuBuilder = menu
        return button
    }

    /// The chrome glyph at the pill's symbol size.
    static func glyph(_ symbol: String) -> NSImage? {
        NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: ChalkMetrics.headerIconPointSize, weight: .regular))
    }

    private init(symbol: String, label: String) {
        self.symbol = symbol
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = ChalkMetrics.rowCornerRadius
        layer?.cornerCurve = .continuous
        imageView.image = Self.glyph(symbol)
        imageView.imageScaling = .scaleNone
        imageView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(imageView)
        setAccessibilityRole(.button)
        setAccessibilityLabel(label)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: ChalkMetrics.footerButtonSize.width),
            heightAnchor.constraint(equalToConstant: ChalkMetrics.footerButtonSize.height),
            imageView.centerXAnchor.constraint(equalTo: centerXAnchor),
            imageView.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        applyStyle()
        NotificationCenter.default.addObserver(
            self, selector: #selector(themeDidChange), name: ChalkAppearance.themeDidChange, object: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    @objc private func themeDidChange() { applyStyle() }

    /// Swap the glyph (the mode button follows the editing mode).
    func setSymbol(_ symbol: String, label: String) {
        self.symbol = symbol
        imageView.image = Self.glyph(symbol)
        setAccessibilityLabel(label)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        chalkReplaceTrackingArea(&trackingArea)
    }

    override func mouseEntered(with event: NSEvent) { hovering = true; applyStyle() }
    override func mouseExited(with event: NSEvent) { hovering = false; applyStyle() }

    override func mouseDown(with event: NSEvent) {
        if let menuBuilder {
            let menu = menuBuilder()
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: bounds.maxY + 4), in: self)
            return
        }
        pressed = true
        applyStyle()
    }

    override func mouseUp(with event: NSEvent) {
        let inside = bounds.contains(convert(event.locationInWindow, from: nil))
        pressed = false
        applyStyle()
        if inside { action?() }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyStyle()
    }

    private func applyStyle() {
        let engaged = pressed || hovering
        imageView.contentTintColor = engaged ? .chalkChromeFg : .chalkChromeFgTertiary
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = engaged ? NSColor.chalkRowHoverBackground.cgColor : nil
        }
    }
}

extension ChromeIconButton {
    /// The editing-mode picker menu: one checkmarked row per mode, built on
    /// every open so the checkmark reflects the live mode.
    static func editingModeMenu(
        current: @escaping () -> EditingMode,
        onSelect: @escaping (EditingMode) -> Void
    ) -> () -> NSMenu {
        {
            let menu = NSMenu(title: "Editing Mode")
            let active = current()
            for mode in EditingMode.allCases {
                let item = MenuActionItem(title: mode.title) { onSelect(mode) }
                item.image = NSImage(systemSymbolName: mode.symbol, accessibilityDescription: nil)
                item.state = mode == active ? .on : .off
                menu.addItem(item)
            }
            return menu
        }
    }
}

/// An `NSMenuItem` whose action is a closure: menus built from enum cases
/// should not need a selector per case.
final class MenuActionItem: NSMenuItem {
    private let handler: () -> Void

    init(title: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("init(coder:) is not used") }

    @objc private func fire() { handler() }
}
