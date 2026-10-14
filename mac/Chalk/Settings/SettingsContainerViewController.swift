import UIKit
import ChalkKit

/// The Settings shell: a left rail (General, LaTeX Shortcuts categories) beside a content area that
/// swaps child controllers. Owns everything sheet-wide so the tab controllers stay plain content.
final class SettingsContainerViewController: UIViewController {
    /// Called after a General setting changes so the coordinator can apply it live.
    var onChange: (() -> Void)?
    /// Called after any snippet edit so the coordinator can push hsnips to open editors.
    var onSnippetsChange: (() -> Void)?
    /// Fired once dismissal completes, so the host can return keyboard focus to the editor.
    var onDismiss: (() -> Void)?

    #if DEBUG
    /// Set right before presenting, to log command-to-visible latency. 0 = unset.
    var openCommandTime: CFTimeInterval = 0
    #endif

    /// True when hosted in its own window rather than as a sheet. The window's title bar and
    /// close button replace the nav bar and Done button.
    var isWindowed = false

    /// Section 0 is General; section 1 has one row per shortcut category, all backed by the one
    /// shortcuts controller showing a different slice.
    private enum RailItem {
        case general
        case category(ShortcutCategory)

        var title: String {
            switch self {
            case .general: return "General"
            case .category(let c): return c.title
            }
        }

        var icon: String {
            switch self {
            case .general: return "gearshape"
            case .category(let c): return c.symbol
            }
        }
    }

    /// Built once: categories come from the bundled file, which cannot change while the sheet is up.
    private lazy var railSections: [[RailItem]] = [
        [.general],
        ShortcutCategory.all(for: SnippetLibrary.shared.builtins).map(RailItem.category),
    ]

    private let railView = UITableView(frame: .zero, style: .plain)
    private let contentContainer = UIView()
    private var currentChild: UIViewController?

    /// Retuned in `viewDidLayoutSubviews` so the rail narrows on a compact container. See
    /// `SettingsPresentation.railWidth`.
    private lazy var railWidthConstraint: NSLayoutConstraint =
        railView.widthAnchor.constraint(equalToConstant: ChalkMetrics.s(190))

    private lazy var generalVC: GeneralSettingsViewController = {
        let vc = GeneralSettingsViewController()
        vc.onChange = { [weak self] in self?.onChange?() }
        return vc
    }()

    private lazy var shortcutsVC: ShortcutsSettingsViewController = {
        let vc = ShortcutsSettingsViewController()
        vc.onSnippetsChange = { [weak self] in self?.onSnippetsChange?() }
        return vc
    }()

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Settings"
        view.backgroundColor = .chalkChromeBackground
        // Scaled like every Mac token: Catalyst draws the iPad idiom at 77%, and the contents go
        // through `s()`, so a raw size would squeeze them.
        preferredContentSize = ChalkMetrics.settingsDefaultSize

        if isWindowed {
            navigationController?.setNavigationBarHidden(true, animated: false)
        } else {
            let done = UIBarButtonItem(
                barButtonSystemItem: .done, target: self, action: #selector(done))
            done.tintColor = .chalkAccent // single-accent rule, not system blue
            navigationItem.rightBarButtonItem = done
        }

        // Opaque nav bar in both scroll states so it honors the app's forced appearance.
        let barAppearance = UINavigationBarAppearance()
        barAppearance.configureWithOpaqueBackground()
        barAppearance.backgroundColor = .chalkChromeBackground
        barAppearance.shadowColor = .chalkBorderHard
        barAppearance.titleTextAttributes = [.foregroundColor: UIColor.chalkTextPrimary]
        navigationItem.standardAppearance = barAppearance
        navigationItem.scrollEdgeAppearance = barAppearance

        railView.dataSource = self
        railView.delegate = self
        railView.backgroundColor = .chalkChromeBackground
        railView.separatorStyle = .none
        railView.alwaysBounceVertical = false
        // Derived from the row font; a flat height clipped the labels.
        railView.rowHeight = ChalkMetrics.settingsRailRowHeight
        railView.contentInset = UIEdgeInsets(top: ChalkMetrics.s(14), left: 0, bottom: 0, right: 0)

        let divider = UIView()
        divider.backgroundColor = .chalkBorderHard

        contentContainer.backgroundColor = .chalkChromeBackground

        for sub in [railView, divider, contentContainer] {
            sub.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(sub)
        }
        NSLayoutConstraint.activate([
            railView.topAnchor.constraint(equalTo: view.topAnchor),
            railView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            railView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            railWidthConstraint,

            divider.topAnchor.constraint(equalTo: view.topAnchor),
            divider.leadingAnchor.constraint(equalTo: railView.trailingAnchor),
            divider.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            divider.widthAnchor.constraint(equalToConstant: 1),

            contentContainer.topAnchor.constraint(equalTo: view.topAnchor),
            contentContainer.leadingAnchor.constraint(equalTo: divider.trailingAnchor),
            contentContainer.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            contentContainer.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])

        railView.selectRow(at: IndexPath(row: 0, section: 0), animated: false, scrollPosition: .none)
        show(.general)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        // Claim first responder so Escape has a responder chain to dispatch through.
        becomeFirstResponder()
        #if DEBUG
        if openCommandTime > 0 {
            NSLog("[latency] Settings command->visible %.0fms",
                  (CACurrentMediaTime() - openCommandTime) * 1000)
            openCommandTime = 0
        }
        #endif
    }

    override var canBecomeFirstResponder: Bool { true }

    override var keyCommands: [UIKeyCommand]? {
        let esc = UIKeyCommand(input: UIKeyCommand.inputEscape, modifierFlags: [], action: #selector(done))
        // Win over any system handling of Escape, as Quick Open does.
        esc.wantsPriorityOverSystemBehavior = true
        return [esc]
    }

    /// Every close path funnels here so each fires `onDismiss`.
    @objc func done() {
        guard !isWindowed else {
            onDismiss?()
            return
        }
        dismiss(animated: false) { [weak self] in self?.onDismiss?() }
    }

    /// Cmd+, while the sheet is up. The menu resolves against the first responder, which is this
    /// sheet and cuts RootSplitViewController out of the chain, so the same selector means close.
    @objc func cmdSettings() { done() }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let wanted = SettingsPresentation.railWidth(forContainerWidth: view.bounds.width)
        if abs(railWidthConstraint.constant - wanted) > 0.5 {
            railWidthConstraint.constant = wanted
        }
    }

    private func show(_ item: RailItem) {
        let next: UIViewController
        switch item {
        case .general:
            next = generalVC
        case .category(let category):
            // Set before the swap so the first layout already has the right rows.
            shortcutsVC.selectedCategory = category
            next = shortcutsVC
        }
        guard next !== currentChild else { return }

        if let current = currentChild {
            current.willMove(toParent: nil)
            current.view.removeFromSuperview()
            current.removeFromParent()
        }
        addChild(next)
        next.view.translatesAutoresizingMaskIntoConstraints = false
        contentContainer.addSubview(next.view)
        NSLayoutConstraint.activate([
            next.view.topAnchor.constraint(equalTo: contentContainer.topAnchor),
            next.view.leadingAnchor.constraint(equalTo: contentContainer.leadingAnchor),
            next.view.trailingAnchor.constraint(equalTo: contentContainer.trailingAnchor),
            next.view.bottomAnchor.constraint(equalTo: contentContainer.bottomAnchor),
        ])
        next.didMove(toParent: self)
        currentChild = next
    }
}

extension SettingsContainerViewController: UITableViewDataSource, UITableViewDelegate {
    func numberOfSections(in tableView: UITableView) -> Int { railSections.count }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        railSections[section].count
    }

    func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        section == 1 ? "LaTeX Shortcuts" : nil
    }

    func tableView(_ tableView: UITableView, willDisplayHeaderView view: UIView, forSection section: Int) {
        guard let header = view as? UITableViewHeaderFooterView else { return }
        header.textLabel?.textColor = .chalkTextFaint
        header.textLabel?.font = .systemFont(ofSize: ChalkMetrics.s(11), weight: .semibold)
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let item = railSections[indexPath.section][indexPath.row]
        let indented = indexPath.section == 1
        let cell = UITableViewCell(style: .default, reuseIdentifier: nil)

        // Selected row: inset rounded pill with an accent wash, matching the sidebar.
        cell.configurationUpdateHandler = { cell, state in
            let active = state.isSelected || state.isHighlighted

            var config = cell.defaultContentConfiguration()
            config.text = item.title
            config.textProperties.font = .systemFont(
                ofSize: ChalkMetrics.sidebarRowFontSize,
                weight: active ? .medium : .regular)
            config.textProperties.color = active ? .chalkTextPrimary : .chalkTextBody
            config.image = UIImage(systemName: item.icon)
            config.imageProperties.tintColor = active ? .chalkAccent : .chalkTextMuted
            config.imageProperties.preferredSymbolConfiguration =
                UIImage.SymbolConfiguration(pointSize: ChalkMetrics.s(13), weight: .medium)
            // Set all four margins: the default vertical margins (~15pt each) leave a ~32pt row's
            // label about 2pt tall, drawn as a clipped sliver. Same as
            // SidebarViewController.compactRowMargins.
            config.directionalLayoutMargins = NSDirectionalEdgeInsets(
                top: ChalkMetrics.s(5),
                leading: ChalkMetrics.s(indented ? 30 : 20),
                bottom: ChalkMetrics.s(5),
                trailing: ChalkMetrics.s(8))
            cell.contentConfiguration = config

            var bg = UIBackgroundConfiguration.clear()
            if active {
                bg.backgroundColor = UIColor.chalkAccent.withAlphaComponent(0.15)
                bg.cornerRadius = ChalkMetrics.rowCornerRadius
                bg.backgroundInsets = NSDirectionalEdgeInsets(
                    top: ChalkMetrics.s(2), leading: ChalkMetrics.s(10),
                    bottom: ChalkMetrics.s(2), trailing: ChalkMetrics.s(10))
            }
            cell.backgroundConfiguration = bg
        }
        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        show(railSections[indexPath.section][indexPath.row])
    }
}

// MARK: - Testing hooks

extension SettingsContainerViewController {
    var railViewForTesting: UITableView { railView }

    /// What the rail claims to offer, section by section.
    var railTitlesForTesting: [[String]] {
        railSections.map { $0.map(\.title) }
    }

    /// What a rail row actually renders: the text is set in `configurationUpdateHandler`, so a row
    /// can have a title and still paint blank.
    func railCellTextForTesting(section: Int, row: Int) -> String? {
        let path = IndexPath(row: row, section: section)
        let cell = tableView(railView, cellForRowAt: path)
        cell.configurationUpdateHandler?(cell, cell.configurationState)
        return (cell.contentConfiguration as? UIListContentConfiguration)?.text
    }
}
