import AppKit
import ChalkKit

/// One row of a settings card: a title, an optional detail beside it, and a
/// control (or a disclosure chevron) at the trailing edge. Rows that open a
/// screen act on click.
final class SettingsRowView: FlippedView {
    let titleLabel = NSTextField(labelWithString: "")
    let detailLabel = NSTextField(labelWithString: "")
    private(set) var control: NSView?
    private let disclosure = NSImageView()
    var onClick: (() -> Void)?

    static let height: CGFloat = 44
    static let inset: CGFloat = 16

    init(title: String, detail: String? = nil, control: NSView? = nil, opensAScreen: Bool = false) {
        super.init(frame: .zero)
        self.control = control
        titleLabel.stringValue = title
        titleLabel.font = .systemFont(ofSize: ChalkMetrics.sidebarRowFontSize)
        titleLabel.textColor = .chalkTextBody
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.maximumNumberOfLines = 1
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        detailLabel.stringValue = detail ?? ""
        detailLabel.font = .systemFont(ofSize: ChalkMetrics.sidebarRowFontSize)
        detailLabel.textColor = .chalkTextMuted
        detailLabel.lineBreakMode = .byTruncatingTail
        detailLabel.maximumNumberOfLines = 1
        detailLabel.translatesAutoresizingMaskIntoConstraints = false
        detailLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        disclosure.image = NSImage(systemSymbolName: "chevron.right", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 11, weight: .semibold))
        disclosure.contentTintColor = .chalkTextFaint
        disclosure.imageScaling = .scaleNone
        disclosure.isHidden = !opensAScreen
        disclosure.translatesAutoresizingMaskIntoConstraints = false
        addSubview(titleLabel)
        addSubview(detailLabel)
        addSubview(disclosure)

        var constraints = [
            heightAnchor.constraint(equalToConstant: Self.height),
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.inset),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            disclosure.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Self.inset),
            disclosure.centerYAnchor.constraint(equalTo: centerYAnchor),
        ]
        // The trailing slot: the control, else the chevron, else the edge.
        let trailingEdge: NSLayoutXAxisAnchor
        if let control {
            control.translatesAutoresizingMaskIntoConstraints = false
            addSubview(control)
            constraints += [
                control.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Self.inset),
                control.centerYAnchor.constraint(equalTo: centerYAnchor),
            ]
            trailingEdge = control.leadingAnchor
        } else if opensAScreen {
            trailingEdge = disclosure.leadingAnchor
        } else {
            trailingEdge = trailingAnchor
        }
        constraints += [
            detailLabel.leadingAnchor.constraint(greaterThanOrEqualTo: titleLabel.trailingAnchor, constant: 8),
            detailLabel.trailingAnchor.constraint(equalTo: trailingEdge, constant: control == nil ? -Self.inset : -12),
            detailLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
        ]
        NSLayoutConstraint.activate(constraints)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func mouseDown(with event: NSEvent) {
        guard let onClick else { super.mouseDown(with: event); return }
        onClick()
    }

    /// Readout rows rewrite the detail in place.
    func setDetail(_ text: String) { detailLabel.stringValue = text }
}

/// A titled card of rows, the inset-grouped look: a caption above a rounded
/// card with hairlines between the rows.
final class SettingsCardView: ThemedView {
    let caption = NSTextField(labelWithString: "")
    let card = FlippedView()
    private let stack = NSStackView()

    init(title: String, rows: [SettingsRowView]) {
        super.init(frame: .zero)
        caption.stringValue = title.uppercased()
        caption.font = .systemFont(ofSize: 11, weight: .semibold)
        caption.textColor = .chalkTextMuted
        caption.translatesAutoresizingMaskIntoConstraints = false
        card.wantsLayer = true
        card.layer?.cornerRadius = 10
        card.layer?.cornerCurve = .continuous
        card.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .vertical
        stack.spacing = 0
        stack.alignment = .leading
        stack.translatesAutoresizingMaskIntoConstraints = false
        for (index, row) in rows.enumerated() {
            if index > 0 {
                let rule = FlippedView()
                rule.wantsLayer = true
                rule.translatesAutoresizingMaskIntoConstraints = false
                rule.heightAnchor.constraint(equalToConstant: 1).isActive = true
                stack.addArrangedSubview(rule)
                rule.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -Self.ruleInset * 2).isActive = true
            }
            row.translatesAutoresizingMaskIntoConstraints = false
            stack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        card.addSubview(stack)
        addSubview(caption)
        addSubview(card)
        NSLayoutConstraint.activate([
            caption.topAnchor.constraint(equalTo: topAnchor),
            caption.leadingAnchor.constraint(equalTo: leadingAnchor, constant: SettingsRowView.inset),
            card.topAnchor.constraint(equalTo: caption.bottomAnchor, constant: 8),
            card.leadingAnchor.constraint(equalTo: leadingAnchor),
            card.trailingAnchor.constraint(equalTo: trailingAnchor),
            card.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.topAnchor.constraint(equalTo: card.topAnchor),
            stack.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: card.bottomAnchor),
        ])
        refreshColors()
    }

    private static let ruleInset: CGFloat = 16

    override func refreshColors() {
        paint(card, background: .chalkCardBackground)
        for rule in stack.arrangedSubviews where !(rule is SettingsRowView) {
            paint(rule, background: .chalkCardSeparator)
        }
    }
}

/// The General pane of Settings: Appearance, Editor and About sections.
/// Window-wide chrome lives in `SettingsContainerViewController`.
final class GeneralSettingsViewController: NSViewController {
    /// The About section: which build this is, how to reach a person, and what the app does with data.
    enum AboutRow {
        case version, report, privacy, acknowledgements

        var title: String {
            switch self {
            case .version: return "Version"
            case .report: return "Report a Problem"
            case .privacy: return "Privacy"
            case .acknowledgements: return "Acknowledgements"
            }
        }

        var opensAScreen: Bool {
            switch self {
            case .version: return false
            case .report, .privacy, .acknowledgements: return true
            }
        }
    }

    /// Lets AboutSectionTests drive a stamped build without the real preferences.
    var alphaSessionForTesting: AlphaSession?
    private var alpha: AlphaSession { alphaSessionForTesting ?? .shared }

    var aboutRows: [AboutRow] { [.version, .report, .privacy, .acknowledgements] }

    private func detail(for row: AboutRow) -> String? {
        switch row {
        case .version:
            let build = alpha.build
            return "\(build.appVersion) (\(build.build), \(build.commit))"
        case .report, .privacy, .acknowledgements:
            return nil
        }
    }

    /// The screen a row leads to, or nil for a row that only states a fact. Also the tests' seam.
    func destination(section: Int, row: Int) -> NSViewController? {
        guard section == 2, row < aboutRows.count else { return nil }
        switch aboutRows[row] {
        case .version: return nil
        case .report: return ReportProblemViewController(alpha: alpha)
        case .privacy: return PrivacyViewController(alpha: alpha)
        case .acknowledgements: return AcknowledgementsViewController()
        }
    }

    /// Called after any setting changes so the coordinator can apply it live.
    var onChange: (() -> Void)?

    private let scrollView = NSScrollView()
    private let document = FlippedView()
    /// The rows per section, in display order, so the tests read the real screen.
    private var sectionRows: [[SettingsRowView]] = []

    /// Slider readouts are rewritten in place on every tick.
    private weak var fontRow: SettingsRowView?
    private weak var measureRow: SettingsRowView?
    private weak var lineHeightRow: SettingsRowView?

    static let sectionTitles = ["Appearance", "Editor", "About"]

    override func loadView() {
        view = ChromeToneView()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        scrollView.documentView = document
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scrollView)
        document.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: view.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            document.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor),
        ])
        buildSections()
    }

    private func buildSections() {
        sectionRows = [appearanceRows(), editorRows(), aboutRowViews()]
        let cards = zip(Self.sectionTitles, sectionRows).map { SettingsCardView(title: $0, rows: $1) }
        let stack = NSStackView(views: cards)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 22
        stack.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(stack)
        let margin: CGFloat = 20
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: document.topAnchor, constant: margin),
            stack.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: margin),
            stack.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -margin),
            stack.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -margin),
        ])
        for card in cards { card.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
    }

    // MARK: - Appearance

    private func appearanceRows() -> [SettingsRowView] {
        let appearance = makeSegmented(
            titles: ThemePreference.allCases.map(\.title),
            selected: Preferences.themePreference.rawValue,
            action: #selector(themeChanged))
        appearanceControl = appearance
        let theme = makeThemeMenu()
        let autoHide = makeSwitch(isOn: Preferences.autoHideChrome, action: #selector(autoHideChromeToggled))
        return [
            SettingsRowView(title: "Appearance", control: appearance),
            SettingsRowView(title: "Theme", control: theme),
            SettingsRowView(title: "Auto-hide Tabs", detail: "While scrolling", control: autoHide),
        ]
    }

    @objc private func themeChanged(_ control: NSSegmentedControl) {
        Preferences.themePreference = ThemePreference(rawValue: control.selectedSegment) ?? .auto
        onChange?()
    }

    #if DEBUG
    /// The Appearance segment as a click would set it, through the control's own action.
    func selectAppearanceForTesting(_ preference: ThemePreference) {
        loadViewIfNeeded()
        appearanceControl?.selectedSegment = preference.rawValue
        appearanceControl.map(themeChanged)
    }
    #endif
    private weak var appearanceControl: NSSegmentedControl?

    /// A pop-up rather than segments: theme names are long and the list will grow.
    private func makeThemeMenu() -> NSPopUpButton {
        let button = NSPopUpButton(frame: .zero, pullsDown: false)
        for theme in ChalkTheme.allCases {
            button.addItem(withTitle: theme.title)
            button.lastItem?.representedObject = theme.rawValue
        }
        if let index = ChalkTheme.allCases.firstIndex(of: Preferences.colorTheme) {
            button.selectItem(at: index)
        }
        button.target = self
        button.action = #selector(themeMenuChanged)
        return button
    }

    @objc private func themeMenuChanged(_ button: NSPopUpButton) {
        let cases = ChalkTheme.allCases
        guard cases.indices.contains(button.indexOfSelectedItem) else { return }
        Preferences.colorTheme = cases[button.indexOfSelectedItem]
        onChange?()
    }

    /// Also broadcast: every window's chrome must hear it.
    @objc private func autoHideChromeToggled(_ toggle: NSSwitch) {
        Preferences.autoHideChrome = toggle.state == .on
        NotificationCenter.default.post(name: Preferences.autoHideChromeDidChange, object: nil)
        onChange?()
    }

    // MARK: - Editor

    private func editorRows() -> [SettingsRowView] {
        let font = SettingsRowView(
            title: "Text Size", detail: Self.fontReadout(Preferences.editorFontScale),
            control: makeSlider(range: Preferences.editorFontScaleRange, value: Preferences.editorFontScale,
                                action: #selector(fontSlid)))
        fontRow = font
        let measure = SettingsRowView(
            title: "Text Width", detail: Self.measureReadout(Preferences.editorMeasure),
            control: makeSlider(range: Preferences.editorMeasureRange, value: Preferences.editorMeasure,
                                action: #selector(measureSlid)))
        measureRow = measure
        let lineHeight = SettingsRowView(
            title: "Line Spacing", detail: Self.lineHeightReadout(Preferences.editorLineHeight),
            control: makeSlider(range: Preferences.editorLineHeightRange, value: Preferences.editorLineHeight,
                                action: #selector(lineHeightSlid)))
        lineHeightRow = lineHeight
        let alignmentCases = EditorTextAlignment.allCases
        let alignment = SettingsRowView(
            title: "Alignment",
            control: makeSegmented(titles: alignmentCases.map(\.title),
                                   selected: alignmentCases.firstIndex(of: Preferences.textAlignment) ?? 0,
                                   action: #selector(alignmentChanged)))
        let headings = SettingsRowView(
            title: "Color Markdown Headings", detail: "A hue per level",
            control: makeSwitch(isOn: Preferences.colorHeadings, action: #selector(colorHeadingsToggled)))
        let fileCases = DefaultFileType.allCases
        let newDocuments = SettingsRowView(
            title: "New Documents",
            control: makeSegmented(titles: fileCases.map(\.title),
                                   selected: fileCases.firstIndex(of: Preferences.defaultFileType) ?? 0,
                                   action: #selector(defaultFileTypeChanged)))
        let viewCases = ViewMode.allCases
        let viewMode = SettingsRowView(
            title: "View Mode", detail: "What documents open in; \u{2318}: cycles one",
            control: makeSegmented(titles: viewCases.map(\.title),
                                   selected: viewCases.firstIndex(of: Preferences.viewMode) ?? 0,
                                   action: #selector(viewModeChanged)))
        return [font, measure, lineHeight, alignment, headings, newDocuments, viewMode]
    }

    /// `onChange` is enough: the broadcast already reaches every window's editors.
    @objc private func colorHeadingsToggled(_ toggle: NSSwitch) {
        Preferences.colorHeadings = toggle.state == .on
        onChange?()
    }

    /// Snapped to 0.05 so it stays commensurate with the 0.1 Cmd+/Cmd- zoom step. Applies live.
    @objc private func fontSlid(_ slider: NSSlider) {
        let snapped = (slider.doubleValue / 0.05).rounded() * 0.05
        Preferences.editorFontScale = snapped
        fontRow?.setDetail(Self.fontReadout(snapped))
        onChange?()
    }

    @objc private func measureSlid(_ slider: NSSlider) {
        let snapped = (slider.doubleValue / 10).rounded() * 10
        Preferences.editorMeasure = snapped
        measureRow?.setDetail(Self.measureReadout(Preferences.editorMeasure))
        onChange?()
    }

    /// Snapped to 0.05 so the readout never shows noise like 1.63. Applies live.
    @objc private func lineHeightSlid(_ slider: NSSlider) {
        let snapped = (slider.doubleValue / 0.05).rounded() * 0.05
        Preferences.editorLineHeight = snapped
        lineHeightRow?.setDetail(Self.lineHeightReadout(Preferences.editorLineHeight))
        onChange?()
    }

    @objc private func alignmentChanged(_ control: NSSegmentedControl) {
        let cases = EditorTextAlignment.allCases
        Preferences.textAlignment = cases.indices.contains(control.selectedSegment)
            ? cases[control.selectedSegment] : .left
        onChange?()
    }

    @objc private func defaultFileTypeChanged(_ control: NSSegmentedControl) {
        let cases = DefaultFileType.allCases
        Preferences.defaultFileType = cases.indices.contains(control.selectedSegment)
            ? cases[control.selectedSegment] : .md
        onChange?()
    }

    @objc private func viewModeChanged(_ control: NSSegmentedControl) {
        let cases = ViewMode.allCases
        Preferences.viewMode = cases.indices.contains(control.selectedSegment)
            ? cases[control.selectedSegment] : .preview
        onChange?()
    }

    static func fontReadout(_ scale: Double) -> String {
        "\(Int((scale * 100).rounded()))%"
    }

    static func measureReadout(_ px: Double) -> String {
        "\(Int(px.rounded())) px"
    }

    /// Shown as a multiplier, not points: the line height tracks the text size.
    static func lineHeightReadout(_ multiplier: Double) -> String {
        String(format: "%.2fx", multiplier)
    }

    // MARK: - About

    private func aboutRowViews() -> [SettingsRowView] {
        aboutRows.enumerated().map { index, row in
            let view = SettingsRowView(title: row.title, detail: detail(for: row), opensAScreen: row.opensAScreen)
            if row.opensAScreen {
                view.onClick = { [weak self] in self?.openAboutRow(index) }
            }
            return view
        }
    }

    /// The About screens are sheets on the Settings window, as they are on
    /// an editor window from the Help menu.
    private func openAboutRow(_ index: Int) {
        guard let destination = destination(section: 2, row: index),
              let window = view.window, window.attachedSheet == nil else { return }
        HelpSheet.present(destination, over: window) {}
    }

    // MARK: - Controls

    /// One accent for the selected segment.
    private func makeSegmented(titles: [String], selected: Int, action: Selector) -> NSSegmentedControl {
        let control = NSSegmentedControl(labels: titles, trackingMode: .selectOne, target: self, action: action)
        control.selectedSegment = selected
        control.selectedSegmentBezelColor = .chalkAccent
        control.font = .systemFont(ofSize: 12)
        return control
    }

    private func makeSwitch(isOn: Bool, action: Selector) -> NSSwitch {
        let toggle = NSSwitch()
        toggle.state = isOn ? .on : .off
        toggle.target = self
        toggle.action = action
        return toggle
    }

    /// An NSSlider has no intrinsic width, so it carries an explicit one.
    private func makeSlider(range: ClosedRange<Double>, value: Double, action: Selector) -> NSSlider {
        let slider = NSSlider(value: value, minValue: range.lowerBound, maxValue: range.upperBound,
                              target: self, action: action)
        slider.isContinuous = true
        slider.widthAnchor.constraint(equalToConstant: 160).isActive = true
        return slider
    }

    #if DEBUG
    /// Row titles of one section, read through the real rows.
    func rowTitlesForTesting(section: Int) -> [String] {
        loadViewIfNeeded()
        return sectionRows[section].map(\.titleLabel.stringValue)
    }

    func rowDetailForTesting(section: Int, row: Int) -> String {
        loadViewIfNeeded()
        return sectionRows[section][row].detailLabel.stringValue
    }

    func rowHasDisclosureForTesting(section: Int, row: Int) -> Bool {
        loadViewIfNeeded()
        return sectionRows[section][row].onClick != nil
    }

    /// The Editor section's row, for the layout assertions.
    func editorRowForTesting(_ row: Int) -> SettingsRowView {
        loadViewIfNeeded()
        return sectionRows[1][row]
    }
    #endif
}

/// Scrollable plain-text view of the bundled THIRD-PARTY-NOTICES.
final class AcknowledgementsViewController: NSViewController {
    override func loadView() {
        view = ChromeToneView()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Acknowledgements"
        let scroll = NSScrollView()
        let textView = NSTextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.textColor = .chalkTextMuted
        textView.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        textView.textContainerInset = NSSize(width: 16, height: 16)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        if let url = Bundle.main.url(forResource: "THIRD-PARTY-NOTICES", withExtension: nil),
           let text = try? String(contentsOf: url, encoding: .utf8) {
            textView.string = text
        } else {
            textView.string = "Third-party notices are unavailable in this build."
        }
        scroll.documentView = textView
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: view.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    #if DEBUG
    var textForTesting: String {
        loadViewIfNeeded()
        return ((view.subviews.first as? NSScrollView)?.documentView as? NSTextView)?.string ?? ""
    }
    #endif
}
