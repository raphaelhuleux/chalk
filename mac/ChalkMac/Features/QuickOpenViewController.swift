import AppKit
import ChalkKit

/// The ⌘O Quick Open palette: fuzzy-filter every file across all Locations,
/// open on select. The match key is "parentFolder/fileName" so queries like
/// "notes ideas" rank the right file. Reports its natural height so the host's
/// card hugs the results.
final class QuickOpenViewController: NSViewController {
    /// Open `url`; `inNewTab` is the ⌘↩ path. Plain ↩ browses in place like a sidebar click.
    var onOpen: ((_ url: URL, _ inNewTab: Bool) -> Void)?
    /// Fired once the overlay is hidden, on every exit path.
    var onDismiss: (() -> Void)?
    /// Ask the host to hide the overlay, then run `then`. A child view can't dismiss itself.
    var onClose: ((_ then: (() -> Void)?) -> Void)?
    /// The card's natural height for the current results. The host caps it against the window.
    var onContentHeightChanged: ((CGFloat) -> Void)?

    private var results: [FileNode] = []
    /// The query the current `results` were computed for.
    private var appliedQuery = ""
    /// Match keys built once per index, not per keystroke.
    private var indexed: [(node: FileNode, key: String)] = []
    private var pendingQuery: DispatchWorkItem?

    private let frame = PaletteFrame(
        glyph: "magnifyingglass", placeholder: "Open file\u{2026}",
        hints: "\u{2191}\u{2193} navigate    return open    \u{2318} return new tab",
        rowHeight: QuickOpenViewController.resultRowHeight)

    private static let resultRowHeight: CGFloat = ChalkMetrics.s(46)
    private static let maxVisibleRows = 8

    private var selectedIndex = 0

    init() {
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// Feed the asynchronously enumerated file index. The palette presents first and fills in.
    func setFiles(_ files: [FileNode]) {
        indexed = files.map { ($0, Self.key($0)) }
        applyQuery(currentQuery)
    }

    private var currentQuery: String { isViewLoaded ? frame.searchField.stringValue : "" }

    private func applyQuery(_ query: String) {
        appliedQuery = query
        // A blank query yields the first 50 files in index order.
        results = FuzzyMatcher.filter(query: query, items: indexed, key: { $0.key }, limit: 50)
            .map(\.node)
        selectedIndex = 0
        if isViewLoaded {
            frame.tableView.reloadData()
            select(0)
            frame.countLabel.stringValue = results.count == 1 ? "1 result" : "\(results.count) results"
            reportContentHeight()
        }
    }

    private func reportContentHeight() {
        let rows = CGFloat(min(max(results.count, 1), Self.maxVisibleRows))
        let height = PaletteFrame.inputRowHeight + 1
            + PaletteFrame.resultsPadding * 2 + rows * Self.resultRowHeight
            + PaletteFrame.footerHeight
        onContentHeightChanged?(height)
    }

    private func moveUp() { select(max(0, selectedIndex - 1)) }
    private func moveDown() { select(min(results.count - 1, selectedIndex + 1)) }
    private func cancelPalette() {
        onClose? { [weak self] in self?.onDismiss?() }
    }

    private func select(_ index: Int) {
        guard results.indices.contains(index) else {
            frame.tableView.deselectAll(nil)
            return
        }
        selectedIndex = index
        frame.tableView.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        frame.tableView.scrollRowToVisible(index)
    }

    private func openSelected(inNewTab: Bool = false) {
        guard results.indices.contains(selectedIndex) else { return }
        let url = results[selectedIndex].url
        onClose? { [weak self] in
            self?.onOpen?(url, inNewTab)
            self?.onDismiss?()
        }
    }

    /// Reset before a reused instance is re-presented. The last file index is
    /// kept so the palette never flashes empty; the async enumeration refreshes it.
    func prepareForReuse() {
        loadViewIfNeeded()
        frame.searchField.stringValue = ""
        applyQuery("")
    }

    #if DEBUG
    /// Set right before presenting, to measure command-to-visible latency. 0 = unset.
    var openCommandTime: CFTimeInterval = 0
    #endif

    override func loadView() {
        let content = PaletteContentView()
        content.onCommandReturn = { [weak self] in self?.openSelected(inNewTab: true) }
        view = content
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        frame.install(in: view) { [weak self] in self?.cancelPalette() }
        frame.searchField.delegate = self
        frame.tableView.dataSource = self
        frame.tableView.delegate = self
        frame.tableView.target = self
        frame.tableView.action = #selector(rowClicked)
    }

    /// Called by the host on each reveal; the VC is mounted once, so `viewDidAppear` doesn't fire.
    func didReveal() {
        loadViewIfNeeded()
        reportContentHeight()
        #if DEBUG
        if openCommandTime > 0 {
            NSLog("[latency] QuickOpen command->visible %.0fms",
                  (CACurrentMediaTime() - openCommandTime) * 1000)
            openCommandTime = 0
        }
        #endif
        // The editor webview holds the keyboard, and an immediate grab can
        // lose to it (its blur round-trips through the web process). Retry
        // until we win; `willHide` cancels the chain.
        revealGeneration += 1
        grabFocus(retries: 5, generation: revealGeneration)
    }

    /// Called by the host as the overlay hides. Cancels pending focus retries,
    /// which would otherwise hand the keyboard to the hidden field.
    func willHide() {
        revealGeneration += 1
    }

    /// Bumped on every reveal and on willHide; a grabFocus retry from an older generation bails.
    private var revealGeneration = 0

    private func grabFocus(retries: Int, generation: Int) {
        guard generation == revealGeneration else { return }
        #if DEBUG
        focusAttemptCountForTesting += 1
        #endif
        if let window = view.window, window.makeFirstResponder(frame.searchField) { return }
        guard retries > 0 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) { [weak self] in
            self?.grabFocus(retries: retries - 1, generation: generation)
        }
    }

    private static func key(_ node: FileNode) -> String {
        let parent = node.url.deletingLastPathComponent().lastPathComponent
        return "\(parent)/\(node.name)"
    }

    private func textChanged() {
        // Debounce: the fuzzy filter scans every file on the main thread. Clearing applies at once.
        pendingQuery?.cancel()
        let text = frame.searchField.stringValue
        if text.isEmpty {
            applyQuery("")
            return
        }
        let work = DispatchWorkItem { [weak self] in self?.applyQuery(text) }
        pendingQuery = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08, execute: work)
    }

    @objc private func rowClicked() {
        let row = frame.tableView.clickedRow
        guard results.indices.contains(row) else { return }
        selectedIndex = row
        openSelected()
    }

    #if DEBUG
    /// Force a query without the debounce. Works before or after `setFiles`, which re-runs it.
    func setQueryForAudit(_ query: String) {
        loadViewIfNeeded()
        frame.searchField.stringValue = query
        applyQuery(query)
    }

    var visibleResultsForTesting: [FileNode] { results }
    var selectedIndexForTesting: Int { selectedIndex }
    func confirmSelectedForTesting(inNewTab: Bool = false) { openSelected(inNewTab: inNewTab) }
    func moveSelectionForTesting(down: Bool) { down ? moveDown() : moveUp() }
    func cancelForTesting() { cancelPalette() }
    var searchFieldForTesting: NSTextField { frame.searchField }
    var tableViewForTesting: NSTableView { frame.tableView }
    /// becomeFirstResponder attempts by grabFocus.
    private(set) var focusAttemptCountForTesting = 0
    #endif
}

extension QuickOpenViewController: NSTextFieldDelegate {
    func controlTextDidBeginEditing(_ notification: Notification) {
        if let editor = notification.userInfo?["NSFieldEditor"] as? NSTextView {
            PaletteFrame.dress(fieldEditor: editor)
        }
    }

    func controlTextDidChange(_ notification: Notification) {
        textChanged()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard let command = PaletteFrame.command(for: selector) else { return false }
        switch command {
        case .up: moveUp()
        case .down: moveDown()
        case .cancel: cancelPalette()
        case .confirm: openSelected()
        }
        return true
    }
}

extension QuickOpenViewController: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int { results.count }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        PaletteRowView()
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = tableView.makeView(withIdentifier: PaletteResultCellView.identifier, owner: nil)
            as? PaletteResultCellView ?? PaletteResultCellView()
        let node = results[row]
        cell.configure(name: node.name, path: Self.key(node), query: appliedQuery)
        cell.setHighlighted(row == selectedIndex)
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        let row = frame.tableView.selectedRow
        if row >= 0 { selectedIndex = row }
    }
}

/// One result row: doc icon, name, muted path below, and a "return" key badge when selected.
final class PaletteResultCellView: FlippedView, PaletteRowContent {
    static let identifier = NSUserInterfaceItemIdentifier("quick-open-result")
    private let icon = NSImageView()
    private let nameLabel = NSTextField(labelWithString: "")
    private let pathLabel = NSTextField(labelWithString: "")
    private let returnBadge = KeyBadgeView(text: "return", color: .chalkChromeFgSecondary, width: ChalkMetrics.s(42))

    override init(frame: NSRect) {
        super.init(frame: frame)
        identifier = Self.identifier
        icon.image = NSImage(systemSymbolName: "doc.text", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: ChalkMetrics.s(13), weight: .regular))
        icon.contentTintColor = .chalkChromeFgTertiary
        icon.imageScaling = .scaleNone
        icon.translatesAutoresizingMaskIntoConstraints = false

        nameLabel.font = .systemFont(ofSize: ChalkMetrics.paletteResultFontSize)
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.maximumNumberOfLines = 1
        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        pathLabel.font = .systemFont(ofSize: ChalkMetrics.paletteResultPathFontSize)
        pathLabel.textColor = .chalkChromeFgQuaternary
        // Middle-truncate: a tail ellipsis would drop the file name at the end of "parent/name".
        pathLabel.lineBreakMode = .byTruncatingMiddle
        pathLabel.maximumNumberOfLines = 1
        pathLabel.translatesAutoresizingMaskIntoConstraints = false
        returnBadge.isHidden = true
        returnBadge.translatesAutoresizingMaskIntoConstraints = false

        addSubview(icon)
        addSubview(nameLabel)
        addSubview(pathLabel)
        addSubview(returnBadge)
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: ChalkMetrics.s(10)),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: ChalkMetrics.s(16)),

            nameLabel.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: ChalkMetrics.s(11)),
            nameLabel.trailingAnchor.constraint(lessThanOrEqualTo: returnBadge.leadingAnchor, constant: -10),
            nameLabel.topAnchor.constraint(equalTo: topAnchor, constant: ChalkMetrics.s(6)),

            pathLabel.leadingAnchor.constraint(equalTo: nameLabel.leadingAnchor),
            pathLabel.trailingAnchor.constraint(lessThanOrEqualTo: returnBadge.leadingAnchor, constant: -10),
            pathLabel.topAnchor.constraint(equalTo: nameLabel.bottomAnchor, constant: 1),

            returnBadge.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -ChalkMetrics.s(10)),
            returnBadge.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func configure(name: String, path: String, query: String) {
        nameLabel.attributedStringValue = paletteHighlightedTitle(
            name, query: query, baseWeight: .regular, size: ChalkMetrics.paletteResultFontSize)
        pathLabel.stringValue = path
    }

    func setHighlighted(_ highlighted: Bool) {
        returnBadge.isHidden = !highlighted
    }
}
