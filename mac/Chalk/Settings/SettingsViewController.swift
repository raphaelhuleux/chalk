import UIKit
import ChalkKit

/// The General tab of Settings: Appearance, Editor and About sections. Sheet-wide chrome lives in
/// `SettingsContainerViewController`.
final class GeneralSettingsViewController: UIViewController {
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
    func destinationForTesting(section: Int, row: Int) -> UIViewController? {
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

    private let tableView = UITableView(frame: .zero, style: .insetGrouped)

    /// Slider readouts are rewritten in place on `.valueChanged`: reloading the table mid-drag would
    /// rebuild the cell and cancel the gesture.
    private weak var fontValueLabel: UILabel?
    private weak var measureValueLabel: UILabel?
    private weak var lineHeightValueLabel: UILabel?

    /// Rows of the Appearance section, in display order.
    private enum AppearanceRow: Int, CaseIterable {
        case appearance, theme, autoHideTabs
    }

    /// Rows of the Editor section, in display order.
    private enum EditorRow: Int, CaseIterable {
        case textSize, textWidth, lineSpacing, alignment, colorHeadings, newDocuments, viewMode
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .chalkChromeBackground

        tableView.dataSource = self
        tableView.delegate = self
        // Only About rows that open a screen act on tap; control rows opt out via selectionStyle
        // .none and the didSelect guard.
        tableView.allowsSelection = true
        tableView.backgroundColor = .chalkChromeBackground
        tableView.separatorColor = .chalkCardSeparator
        tableView.contentInset = UIEdgeInsets(
            top: ChalkMetrics.s(4), left: 0, bottom: ChalkMetrics.s(16), right: 0)
        tableView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(tableView)
        NSLayoutConstraint.activate([
            tableView.topAnchor.constraint(equalTo: view.topAnchor),
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    @objc private func themeChanged(_ control: UISegmentedControl) {
        Preferences.themePreference = ThemePreference(rawValue: control.selectedSegmentIndex) ?? .auto
        onChange?()
    }

    /// A pop-up button rather than segments: theme names are long and the list will grow.
    private func makeThemeMenu() -> UIButton {
        let actions = ChalkTheme.allCases.map { theme in
            UIAction(title: theme.title, state: theme == Preferences.colorTheme ? .on : .off) {
                [weak self] _ in
                Preferences.colorTheme = theme
                self?.onChange?()
            }
        }
        var config = UIButton.Configuration.plain()
        config.baseForegroundColor = .chalkTextBody
        config.contentInsets = .zero
        let button = UIButton(configuration: config)
        button.menu = UIMenu(children: actions)
        button.showsMenuAsPrimaryAction = true
        button.changesSelectionAsPrimaryAction = true
        button.sizeToFit()
        return button
    }

    /// Also broadcast: Settings runs in its own scene, so every window's chrome must hear it.
    @objc private func autoHideChromeToggled(_ toggle: UISwitch) {
        Preferences.autoHideChrome = toggle.isOn
        NotificationCenter.default.post(
            name: Preferences.autoHideChromeDidChange, object: nil)
        onChange?()
    }

    /// `onChange` is enough: `SettingsBroadcast.applyGeneralSettings` already reaches every window's
    /// editors, and the palette only affects editors.
    @objc private func colorHeadingsToggled(_ toggle: UISwitch) {
        Preferences.colorHeadings = toggle.isOn
        onChange?()
    }

    /// Snapped to 0.05 so it stays commensurate with the 0.1 Cmd+/Cmd- zoom step. Applies live.
    @objc private func fontSlid(_ slider: UISlider) {
        let snapped = (Double(slider.value) / 0.05).rounded() * 0.05
        Preferences.editorFontScale = snapped
        fontValueLabel?.text = Self.fontReadout(snapped)
        onChange?()
    }

    @objc private func measureSlid(_ slider: UISlider) {
        let snapped = (Double(slider.value) / 10).rounded() * 10
        Preferences.editorMeasure = snapped
        measureValueLabel?.text = Self.measureReadout(Preferences.editorMeasure)
        onChange?()
    }

    /// Snapped to 0.05 so the readout never shows noise like 1.63. Applies live.
    @objc private func lineHeightSlid(_ slider: UISlider) {
        let snapped = (Double(slider.value) / 0.05).rounded() * 0.05
        Preferences.editorLineHeight = snapped
        lineHeightValueLabel?.text = Self.lineHeightReadout(Preferences.editorLineHeight)
        onChange?()
    }

    @objc private func alignmentChanged(_ control: UISegmentedControl) {
        let cases = EditorTextAlignment.allCases
        Preferences.textAlignment = cases.indices.contains(control.selectedSegmentIndex)
            ? cases[control.selectedSegmentIndex] : .left
        onChange?()
    }

    @objc private func defaultFileTypeChanged(_ control: UISegmentedControl) {
        let cases = DefaultFileType.allCases
        Preferences.defaultFileType = cases.indices.contains(control.selectedSegmentIndex)
            ? cases[control.selectedSegmentIndex] : .md
        onChange?()
    }

    @objc private func viewModeChanged(_ control: UISegmentedControl) {
        let cases = ViewMode.allCases
        Preferences.viewMode = cases.indices.contains(control.selectedSegmentIndex)
            ? cases[control.selectedSegmentIndex] : .preview
        onChange?()
    }

    private static func fontReadout(_ scale: Double) -> String {
        "\(Int((scale * 100).rounded()))%"
    }

    private static func measureReadout(_ px: Double) -> String {
        "\(Int(px.rounded())) px"
    }

    /// Shown as a multiplier, not points: the line height tracks the text size.
    private static func lineHeightReadout(_ multiplier: Double) -> String {
        String(format: "%.2fx", multiplier)
    }

    /// Shared styling for the segmented rows: one accent, stock divider bars blanked.
    private func makeSegmented(
        titles: [String], selected: Int, action: Selector
    ) -> UISegmentedControl {
        let control = UISegmentedControl(items: titles)
        control.selectedSegmentIndex = selected
        control.selectedSegmentTintColor = .chalkAccent
        control.setTitleTextAttributes([.foregroundColor: UIColor.chalkTextBody], for: .normal)
        control.setTitleTextAttributes([.foregroundColor: UIColor.white], for: .selected)
        control.setDividerImage(
            UIImage(), forLeftSegmentState: .normal, rightSegmentState: .normal,
            barMetrics: .default)
        control.addTarget(self, action: action, for: .valueChanged)
        return control
    }

    /// A UISlider has no intrinsic width, so an accessoryView slider collapses
    /// to nothing unless it carries an explicit frame.
    private func makeSlider(
        range: ClosedRange<Double>, value: Double, action: Selector
    ) -> UISlider {
        let slider = UISlider(
            frame: CGRect(x: 0, y: 0, width: ChalkMetrics.s(160), height: ChalkMetrics.s(28)))
        slider.minimumValue = Float(range.lowerBound)
        slider.maximumValue = Float(range.upperBound)
        slider.value = Float(value)
        slider.minimumTrackTintColor = .chalkAccent
        slider.addTarget(self, action: action, for: .valueChanged)
        return slider
    }
}

extension GeneralSettingsViewController: UITableViewDataSource {
    func numberOfSections(in tableView: UITableView) -> Int { 3 }

    func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        ["Appearance", "Editor", "About"][section]
    }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        [AppearanceRow.allCases.count, EditorRow.allCases.count, aboutRows.count][section]
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .value1, reuseIdentifier: nil)
        cell.backgroundColor = .chalkCardBackground
        cell.textLabel?.font = .systemFont(ofSize: ChalkMetrics.sidebarRowFontSize)
        cell.textLabel?.textColor = .chalkTextBody
        cell.detailTextLabel?.textColor = .chalkTextMuted
        cell.selectionStyle = .none

        if indexPath.section == 2 {
            let row = aboutRows[indexPath.row]
            cell.textLabel?.text = row.title
            cell.detailTextLabel?.text = detail(for: row)
            if row.opensAScreen {
                cell.accessoryType = .disclosureIndicator
                cell.selectionStyle = .default
            }
            return cell
        }

        if indexPath.section == 0 {
            switch AppearanceRow(rawValue: indexPath.row) ?? .appearance {
            case .appearance:
                cell.textLabel?.text = "Appearance"
                cell.accessoryView = makeSegmented(
                    titles: ThemePreference.allCases.map(\.title),
                    selected: Preferences.themePreference.rawValue,
                    action: #selector(themeChanged))
            case .theme:
                cell.textLabel?.text = "Theme"
                cell.accessoryView = makeThemeMenu()
            case .autoHideTabs:
                let toggle = UISwitch()
                toggle.isOn = Preferences.autoHideChrome
                toggle.onTintColor = .chalkAccent
                toggle.addTarget(self, action: #selector(autoHideChromeToggled), for: .valueChanged)
                cell.textLabel?.text = "Auto-hide Tabs"
                cell.detailTextLabel?.text = "While scrolling"
                cell.accessoryView = toggle
            }
            return cell
        }

        switch EditorRow(rawValue: indexPath.row) ?? .textSize {
        case .textSize:
            cell.textLabel?.text = "Text Size"
            cell.detailTextLabel?.text = Self.fontReadout(Preferences.editorFontScale)
            fontValueLabel = cell.detailTextLabel
            cell.accessoryView = makeSlider(
                range: Preferences.editorFontScaleRange, value: Preferences.editorFontScale,
                action: #selector(fontSlid))

        case .textWidth:
            cell.textLabel?.text = "Text Width"
            cell.detailTextLabel?.text = Self.measureReadout(Preferences.editorMeasure)
            measureValueLabel = cell.detailTextLabel
            cell.accessoryView = makeSlider(
                range: Preferences.editorMeasureRange, value: Preferences.editorMeasure,
                action: #selector(measureSlid))

        case .lineSpacing:
            cell.textLabel?.text = "Line Spacing"
            cell.detailTextLabel?.text = Self.lineHeightReadout(Preferences.editorLineHeight)
            lineHeightValueLabel = cell.detailTextLabel
            cell.accessoryView = makeSlider(
                range: Preferences.editorLineHeightRange, value: Preferences.editorLineHeight,
                action: #selector(lineHeightSlid))

        case .alignment:
            let cases = EditorTextAlignment.allCases
            cell.textLabel?.text = "Alignment"
            cell.accessoryView = makeSegmented(
                titles: cases.map(\.title),
                selected: cases.firstIndex(of: Preferences.textAlignment) ?? 0,
                action: #selector(alignmentChanged))

        case .colorHeadings:
            let toggle = UISwitch()
            toggle.isOn = Preferences.colorHeadings
            toggle.onTintColor = .chalkAccent
            toggle.addTarget(self, action: #selector(colorHeadingsToggled),
                             for: .valueChanged)
            cell.textLabel?.text = "Color Markdown Headings"
            cell.detailTextLabel?.text = "A hue per level"
            cell.accessoryView = toggle

        case .newDocuments:
            let cases = DefaultFileType.allCases
            cell.textLabel?.text = "New Documents"
            cell.accessoryView = makeSegmented(
                titles: cases.map(\.title),
                selected: cases.firstIndex(of: Preferences.defaultFileType) ?? 0,
                action: #selector(defaultFileTypeChanged))

        case .viewMode:
            let cases = ViewMode.allCases
            cell.textLabel?.text = "View Mode"
            cell.detailTextLabel?.text = "What documents open in; ⌘: cycles one"
            cell.accessoryView = makeSegmented(
                titles: cases.map(\.title),
                selected: cases.firstIndex(of: Preferences.viewMode) ?? 0,
                action: #selector(viewModeChanged))
        }
        return cell
    }

    /// Row titles of one section, read through the real data source since cells are built inline.
    func rowTitlesForTesting(section: Int) -> [String] {
        loadViewIfNeeded()
        return (0..<tableView(tableView, numberOfRowsInSection: section)).map { row in
            tableView(tableView, cellForRowAt: IndexPath(row: row, section: section))
                .textLabel?.text ?? ""
        }
    }

    func rowDetailForTesting(section: Int, row: Int) -> String {
        loadViewIfNeeded()
        return tableView(tableView, cellForRowAt: IndexPath(row: row, section: section))
            .detailTextLabel?.text ?? ""
    }

    func rowHasDisclosureForTesting(section: Int, row: Int) -> Bool {
        loadViewIfNeeded()
        return tableView(tableView, cellForRowAt: IndexPath(row: row, section: section))
            .accessoryType == .disclosureIndicator
    }
}

extension GeneralSettingsViewController: UITableViewDelegate {
    func tableView(_ tableView: UITableView, willDisplayHeaderView view: UIView, forSection section: Int) {
        guard let header = view as? UITableViewHeaderFooterView else { return }
        header.textLabel?.textColor = .chalkTextMuted
        header.textLabel?.font = .systemFont(ofSize: ChalkMetrics.s(11), weight: .semibold)
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard indexPath.section == 2,
              let destination = destinationForTesting(section: 2, row: indexPath.row)
        else { return }
        navigationController?.pushViewController(destination, animated: true)
    }
}

/// Scrollable plain-text view of the bundled THIRD-PARTY-NOTICES.
final class AcknowledgementsViewController: UIViewController {
    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Acknowledgements"
        view.backgroundColor = .chalkChromeBackground

        let textView = UITextView()
        textView.isEditable = false
        textView.alwaysBounceVertical = true
        textView.backgroundColor = .chalkChromeBackground
        textView.textColor = .chalkTextMuted
        textView.font = .monospacedSystemFont(ofSize: ChalkMetrics.s(11), weight: .regular)
        textView.textContainerInset = UIEdgeInsets(
            top: ChalkMetrics.s(16), left: ChalkMetrics.s(16),
            bottom: ChalkMetrics.s(16), right: ChalkMetrics.s(16))
        if let url = Bundle.main.url(forResource: "THIRD-PARTY-NOTICES", withExtension: nil),
           let text = try? String(contentsOf: url, encoding: .utf8) {
            textView.text = text
        } else {
            textView.text = "Third-party notices are unavailable in this build."
        }
        textView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(textView)
        NSLayoutConstraint.activate([
            textView.topAnchor.constraint(equalTo: view.topAnchor),
            textView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            textView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            textView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }
}
