import AppKit
import ChalkKit

/// The Settings shell: a left rail (General, LaTeX Shortcuts categories)
/// beside a content area that swaps child controllers. Owns everything
/// window-wide so the pane controllers stay plain content.
final class SettingsContainerViewController: NSViewController {
    /// Called after a General setting changes so the coordinator can apply it live.
    var onChange: (() -> Void)?
    /// Called after any snippet edit so the coordinator can push hsnips to open editors.
    var onSnippetsChange: (() -> Void)?
    /// Done, Esc or ⌘,: the host closes the window.
    var onDismiss: (() -> Void)?

    /// The rail's rows: General, then a banner over one row per shortcut
    /// category, all backed by the one shortcuts controller showing a
    /// different slice.
    enum RailItem: Equatable {
        case general
        case banner(String)
        case category(ShortcutCategory)

        var title: String {
            switch self {
            case .general: return "General"
            case .banner(let title): return title
            case .category(let c): return c.title
            }
        }

        var icon: String? {
            switch self {
            case .general: return "gearshape"
            case .banner: return nil
            case .category(let c): return c.symbol
            }
        }

        var isSelectable: Bool {
            if case .banner = self { return false }
            return true
        }
    }

    /// Built once: categories come from the bundled file, which cannot change
    /// while the window is up.
    private lazy var railItems: [RailItem] =
        [.general, .banner("LaTeX Shortcuts")]
        + ShortcutCategory.all(for: SnippetLibrary.shared.builtins).map(RailItem.category)

    private let railView = NSTableView()
    private let railScroll = NSScrollView()
    private let divider = FlippedView()
    private let contentContainer = FlippedView()
    private var currentChild: NSViewController?

    /// Retuned in `viewDidLayout` so the rail narrows on a compact window.
    private var railWidthConstraint: NSLayoutConstraint!

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

    override func loadView() {
        view = ChromeToneView()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Settings"

        let column = NSTableColumn(identifier: .init("rail"))
        column.resizingMask = .autoresizingMask
        railView.addTableColumn(column)
        railView.headerView = nil
        railView.style = .plain
        railView.intercellSpacing = .zero
        railView.selectionHighlightStyle = .none
        railView.backgroundColor = .clear
        railView.focusRingType = .none
        railView.allowsEmptySelection = false
        railView.refusesFirstResponder = true
        railView.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        railView.dataSource = self
        railView.delegate = self
        railScroll.documentView = railView
        railScroll.drawsBackground = false
        railScroll.hasVerticalScroller = true
        railScroll.autohidesScrollers = true
        railScroll.automaticallyAdjustsContentInsets = false
        railScroll.contentInsets = NSEdgeInsets(top: 14, left: 0, bottom: 0, right: 0)

        divider.wantsLayer = true
        divider.layer?.backgroundColor = NSColor.chalkBorderHard.cgColor

        for sub in [railScroll, divider, contentContainer] {
            sub.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(sub)
        }
        railWidthConstraint = railScroll.widthAnchor.constraint(equalToConstant: 190)
        NSLayoutConstraint.activate([
            railScroll.topAnchor.constraint(equalTo: view.topAnchor),
            railScroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            railScroll.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            railWidthConstraint,

            divider.topAnchor.constraint(equalTo: view.topAnchor),
            divider.leadingAnchor.constraint(equalTo: railScroll.trailingAnchor),
            divider.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            divider.widthAnchor.constraint(equalToConstant: 1),

            contentContainer.topAnchor.constraint(equalTo: view.topAnchor),
            contentContainer.leadingAnchor.constraint(equalTo: divider.trailingAnchor),
            contentContainer.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            contentContainer.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])

        railView.reloadData()
        railView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        show(.general)
    }

    /// Esc, from anywhere in the window.
    override func cancelOperation(_ sender: Any?) { done() }

    /// Every close path funnels here so each fires `onDismiss`.
    @objc func done() {
        onDismiss?()
    }

    /// ⌘, while the window is key. The menu resolves against the first
    /// responder, which is in this window and cuts the editor's root out of
    /// the chain, so the same selector means close.
    @objc func cmdSettings(_ sender: Any?) { done() }

    /// A coalesced snippet push must not outrun the window closing.
    func flushPendingWork() {
        shortcutsVC.flushPendingPush()
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        let wanted = SettingsPresentation.railWidth(forContainerWidth: view.bounds.width)
        if abs(railWidthConstraint.constant - wanted) > 0.5 {
            railWidthConstraint.constant = wanted
        }
        railView.sizeLastColumnToFit()
    }

    private func show(_ item: RailItem) {
        let next: NSViewController
        switch item {
        case .general:
            next = generalVC
        case .category(let category):
            // Set before the swap so the first layout already has the right rows.
            shortcutsVC.selectedCategory = category
            next = shortcutsVC
        case .banner:
            return
        }
        guard next !== currentChild else { return }

        if let current = currentChild {
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
        currentChild = next
    }
}

extension SettingsContainerViewController: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int { railItems.count }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        if case .banner = railItems[row] { return 30 }
        return ChalkMetrics.settingsRailRowHeight
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        railItems[row].isSelectable
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        SettingsRailRowView()
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = tableView.makeView(withIdentifier: SettingsRailCellView.identifier, owner: nil)
            as? SettingsRailCellView ?? SettingsRailCellView()
        cell.configure(item: railItems[row], active: tableView.selectedRow == row)
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        let row = railView.selectedRow
        guard railItems.indices.contains(row) else { return }
        show(railItems[row])
        // The weight and tint follow the selection; repaint what is on screen.
        for visible in 0..<railView.numberOfRows {
            (railView.view(atColumn: 0, row: visible, makeIfNecessary: false) as? SettingsRailCellView)?
                .configure(item: railItems[visible], active: visible == row)
        }
    }
}

/// A rail row: the accent wash pill while selected, matching the sidebar.
final class SettingsRailRowView: NSTableRowView {
    override var isFlipped: Bool { true }
    override func drawBackground(in dirtyRect: NSRect) {}
    override func drawSeparator(in dirtyRect: NSRect) {}

    override func drawSelection(in dirtyRect: NSRect) {
        guard isSelected else { return }
        fillChalkPill(NSColor.chalkAccent.withAlphaComponent(0.15), insetX: 10, insetY: 2,
                      radius: ChalkMetrics.rowCornerRadius)
    }
}

/// A rail row's content: glyph and title, or the banner's small caps title.
final class SettingsRailCellView: FlippedView {
    static let identifier = NSUserInterfaceItemIdentifier("settings-rail")
    let icon = NSImageView()
    let label = NSTextField(labelWithString: "")
    private var labelLeading: NSLayoutConstraint!

    override init(frame: NSRect) {
        super.init(frame: frame)
        identifier = Self.identifier
        icon.imageScaling = .scaleNone
        icon.translatesAutoresizingMaskIntoConstraints = false
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(icon)
        addSubview(label)
        labelLeading = label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 20)
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 20),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 18),
            labelLeading,
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -8),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func configure(item: SettingsContainerViewController.RailItem, active: Bool) {
        label.stringValue = item.title
        if case .banner = item {
            icon.isHidden = true
            labelLeading.constant = 20
            label.font = .systemFont(ofSize: 11, weight: .semibold)
            label.textColor = .chalkTextFaint
            return
        }
        let indented: Bool
        if case .category = item { indented = true } else { indented = false }
        icon.isHidden = false
        icon.image = item.icon.flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: nil) }?
            .withSymbolConfiguration(.init(pointSize: 13, weight: .medium))
        icon.contentTintColor = active ? .chalkAccent : .chalkTextMuted
        labelLeading.constant = (indented ? 30 : 20) + 18 + 8
        label.font = .systemFont(ofSize: ChalkMetrics.sidebarRowFontSize, weight: active ? .medium : .regular)
        label.textColor = active ? .chalkTextPrimary : .chalkTextBody
    }
}

// MARK: - Testing hooks

#if DEBUG
extension SettingsContainerViewController {
    var railViewForTesting: NSTableView { railView }

    /// What the rail claims to offer: General alone, then the categories under the banner.
    var railTitlesForTesting: [[String]] {
        let categories = railItems.compactMap { item -> String? in
            if case .category = item { return item.title }
            return nil
        }
        return [["General"], categories]
    }

    /// The rail's rows as laid out, banner included.
    var railRowTitlesForTesting: [String] { railItems.map(\.title) }

    /// What a rail row actually renders.
    func railCellTextForTesting(section: Int, row: Int) -> String? {
        let title = railTitlesForTesting[section][row]
        guard let index = railItems.firstIndex(where: { $0.title == title && $0.isSelectable }) else { return nil }
        return (railView.view(atColumn: 0, row: index, makeIfNecessary: true) as? SettingsRailCellView)?.label.stringValue
    }

    func selectRailForTesting(section: Int, row: Int) {
        let title = railTitlesForTesting[section][row]
        guard let index = railItems.firstIndex(where: { $0.title == title && $0.isSelectable }) else { return }
        railView.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
    }

    var currentPaneForTesting: NSViewController? { currentChild }
    var generalForTesting: GeneralSettingsViewController { generalVC }
    var shortcutsForTesting: ShortcutsSettingsViewController { shortcutsVC }
}
#endif
