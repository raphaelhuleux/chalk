import AppKit
import ChalkKit
import os

/// Focus-grab breadcrumbs. See docs/issues/2026-08-17-fullscreen-drops-when-outline-opens.md.
private let outlineFocusLog = Logger(subsystem: "com.huleux.chalk", category: "outline")

/// The ⌘P outline palette: headings, numbered callouts and figures,
/// fuzzy-filterable, jump on select. Mirrors QuickOpenViewController;
/// selection and indent rules live in `OutlinePalettePolicy`. Reports its
/// natural height so the host's card hugs the list.
final class OutlinePaletteViewController: NSViewController {
    /// Jump to a 1-based line. Fired through `onClose`, so the overlay is gone
    /// before the editor takes focus back.
    var onJump: ((Int) -> Void)?
    /// Fired once the overlay is hidden, on every exit path.
    var onDismiss: (() -> Void)?
    /// Ask the host to hide the overlay, then run `then`. A child view can't dismiss itself.
    var onClose: ((_ then: (() -> Void)?) -> Void)?
    /// The card's natural height for the current rows.
    var onContentHeightChanged: ((CGFloat) -> Void)?

    private var items: [OutlineItem] = []
    /// Indent steps per item of the unfiltered list; a live query flattens indentation.
    private var indents: [Int] = []
    private var cursorLine = 1
    private var results: [OutlineItem] = []
    /// The query the current `results` were computed for.
    private var appliedQuery = ""
    private var pendingQuery: DispatchWorkItem?

    private let frame = PaletteFrame(
        glyph: "list.bullet.indent", placeholder: "Go to section\u{2026}",
        hints: "\u{2191}\u{2193} navigate    return jump",
        rowHeight: ChalkMetrics.outlineRowHeight)

    private static let rowHeight: CGFloat = ChalkMetrics.outlineRowHeight
    private static let maxVisibleRows = 10

    private var selectedIndex = 0

    init() {
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// Feed a snapshot fetched at open. With no query the cursor's section is
    /// preselected, so the palette opens where you are.
    func setSnapshot(_ snapshot: OutlineSnapshot) {
        items = snapshot.items
        cursorLine = snapshot.cursorLine
        indents = OutlinePalettePolicy.indentLevels(for: items)
        applyQuery(isViewLoaded ? frame.searchField.stringValue : "")
    }

    private func applyQuery(_ query: String) {
        appliedQuery = query
        if query.isEmpty {
            results = items
            selectedIndex = OutlinePalettePolicy.preselectedIndex(items: items, cursorLine: cursorLine)
        } else {
            results = OutlinePalettePolicy.filter(query: query, items: items)
            selectedIndex = 0
        }
        if isViewLoaded {
            frame.tableView.reloadData()
            select(selectedIndex)
            frame.emptyLabel.stringValue = items.isEmpty ? "No outline in this document" : "No matches"
            frame.emptyLabel.isHidden = !results.isEmpty
            frame.countLabel.stringValue = results.count == 1 ? "1 item" : "\(results.count) items"
            reportContentHeight()
        }
    }

    private func reportContentHeight() {
        let body: CGFloat
        if results.isEmpty {
            body = ChalkMetrics.outlineEmptyHeight
        } else {
            body = CGFloat(min(results.count, Self.maxVisibleRows)) * Self.rowHeight
        }
        let height = PaletteFrame.inputRowHeight + 1
            + PaletteFrame.resultsPadding * 2 + body
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

    private func jumpToSelected() {
        guard results.indices.contains(selectedIndex) else { return }
        let line = results[selectedIndex].line
        onClose? { [weak self] in
            self?.onJump?(line)
            self?.onDismiss?()
        }
    }

    /// Reset before a reused instance is re-presented. The outline is
    /// per-document, so it is dropped to keep a stale structure from flashing
    /// before the host's fetch lands.
    func prepareForReuse() {
        loadViewIfNeeded()
        frame.searchField.stringValue = ""
        items = []
        indents = []
        cursorLine = 1
        applyQuery("")
    }

    #if DEBUG
    /// Set right before presenting, to measure command-to-visible latency. 0 = unset.
    var openCommandTime: CFTimeInterval = 0
    #endif

    override func loadView() {
        view = PaletteContentView()
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
            NSLog("[latency] Outline command->visible %.0fms",
                  (CACurrentMediaTime() - openCommandTime) * 1000)
            openCommandTime = 0
        }
        #endif
        // The editor webview holds the keyboard, and an immediate grab can
        // lose to it. Retry until we win; `willHide` cancels the chain.
        revealGeneration += 1
        grabFocus(retries: 5, generation: revealGeneration)
    }

    /// Called by the host as the overlay hides. Cancels pending grabFocus
    /// retries, which would otherwise hand the keyboard to the hidden field
    /// and swallow the editor's keystrokes.
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
        let won = view.window?.makeFirstResponder(frame.searchField) ?? false
        outlineFocusLog.info("grabFocus: won=\(won, privacy: .public) retriesLeft=\(retries, privacy: .public)")
        if won { return }
        guard retries > 0 else { return }
        // Spaced retries: the webview's blur round-trips through the web
        // process, so its release can land several runloop turns later.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) { [weak self] in
            self?.grabFocus(retries: retries - 1, generation: generation)
        }
    }

    private func textChanged() {
        // Debounce burst typing; clearing the field applies immediately.
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
        jumpToSelected()
    }

    #if DEBUG
    /// Force a query without the debounce.
    func setQueryForAudit(_ query: String) {
        loadViewIfNeeded()
        frame.searchField.stringValue = query
        applyQuery(query)
    }

    var visibleItemsForTesting: [OutlineItem] { results }
    var selectedIndexForTesting: Int { selectedIndex }
    var isEmptyStateVisibleForTesting: Bool { !frame.emptyLabel.isHidden }
    func confirmSelectedForTesting() { jumpToSelected() }
    func cancelForTesting() { cancelPalette() }
    var searchFieldForTesting: NSTextField { frame.searchField }
    /// becomeFirstResponder attempts by grabFocus.
    private(set) var focusAttemptCountForTesting = 0
    #endif
}

extension OutlinePaletteViewController: NSTextFieldDelegate {
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
        case .confirm: jumpToSelected()
        }
        return true
    }
}

extension OutlinePaletteViewController: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int { results.count }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        PaletteRowView()
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = tableView.makeView(withIdentifier: OutlinePaletteCellView.identifier, owner: nil)
            as? OutlinePaletteCellView ?? OutlinePaletteCellView()
        let item = results[row]
        // A live query flattens indentation: the hit list is ranked, not
        // hierarchical. With no query `results` is `items`, so the row is also
        // the index into `indents`.
        let indent = appliedQuery.isEmpty && indents.indices.contains(row) ? indents[row] : 0
        cell.configure(item: item, indent: indent, query: appliedQuery)
        cell.setHighlighted(row == selectedIndex)
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        let row = frame.tableView.selectedRow
        if row >= 0 { selectedIndex = row }
    }
}

/// One outline palette (⌘P) row: indent, kind glyph, optional "Theorem 3"
/// badge, title, and a "return" key badge when selected. The persistent panel
/// (⌘K) uses `OutlineTreeRowView`.
final class OutlinePaletteCellView: FlippedView, PaletteRowContent {
    static let identifier = NSUserInterfaceItemIdentifier("outline-palette-row")
    private let icon = NSImageView()
    private let badgeLabel = NSTextField(labelWithString: "")
    private let titleLabel = NSTextField(labelWithString: "")
    private let returnBadge = KeyBadgeView(text: "return", color: .chalkChromeFgSecondary, width: ChalkMetrics.s(42))
    private var iconLeading: NSLayoutConstraint!
    private var badgeGap: NSLayoutConstraint!

    override init(frame: NSRect) {
        super.init(frame: frame)
        identifier = Self.identifier
        icon.contentTintColor = .chalkChromeFgTertiary
        icon.imageScaling = .scaleNone
        icon.translatesAutoresizingMaskIntoConstraints = false

        badgeLabel.font = .systemFont(ofSize: ChalkMetrics.outlineBadgeFontSize, weight: .medium)
        badgeLabel.textColor = .chalkChromeFgSecondary
        badgeLabel.setContentHuggingPriority(.required, for: .horizontal)
        badgeLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        badgeLabel.translatesAutoresizingMaskIntoConstraints = false

        titleLabel.font = .systemFont(ofSize: ChalkMetrics.outlineRowFontSize)
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.maximumNumberOfLines = 1
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        returnBadge.isHidden = true
        returnBadge.translatesAutoresizingMaskIntoConstraints = false

        addSubview(icon)
        addSubview(badgeLabel)
        addSubview(titleLabel)
        addSubview(returnBadge)
        iconLeading = icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: ChalkMetrics.s(10))
        badgeGap = titleLabel.leadingAnchor.constraint(equalTo: badgeLabel.trailingAnchor, constant: ChalkMetrics.s(7))
        NSLayoutConstraint.activate([
            iconLeading,
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: ChalkMetrics.s(16)),

            badgeLabel.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: ChalkMetrics.s(9)),
            badgeLabel.centerYAnchor.constraint(equalTo: centerYAnchor),

            badgeGap,
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: returnBadge.leadingAnchor, constant: -10),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),

            returnBadge.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -ChalkMetrics.s(10)),
            returnBadge.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func configure(item: OutlineItem, indent: Int, query: String) {
        iconLeading.constant = ChalkMetrics.s(10) + CGFloat(indent) * ChalkMetrics.outlineIndentUnit

        let symbol: String
        switch item.kind {
        case .heading: symbol = "number"
        case .callout: symbol = "function"
        case .figure: symbol = "photo"
        case .frame: symbol = "rectangle.on.rectangle"
        }
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: ChalkMetrics.s(13), weight: .regular))

        badgeLabel.stringValue = item.badge ?? ""
        badgeLabel.isHidden = item.badge == nil
        badgeGap.constant = item.badge == nil ? 0 : ChalkMetrics.s(7)

        let isTop = item.kind == .heading && item.level <= 1
        titleLabel.attributedStringValue = paletteHighlightedTitle(
            item.title, query: query, baseWeight: isTop ? .semibold : .regular,
            size: ChalkMetrics.outlineRowFontSize)
    }

    func setHighlighted(_ highlighted: Bool) {
        returnBadge.isHidden = !highlighted
    }
}
