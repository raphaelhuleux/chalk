import AppKit
import ChalkKit
import os

/// The palette card's content view. ⌘↩ is a key equivalent, which AppKit
/// offers to the view tree before the menu and never to the field editor's
/// command path, so it is caught here.
final class PaletteContentView: FlippedView {
    var onCommandReturn: (() -> Void)?

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
        if modifiers == .command, event.charactersIgnoringModifiers == "\r", let onCommandReturn {
            onCommandReturn()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

/// A key badge ("esc", "return"): small text in a hairline ring.
final class KeyBadgeView: ThemedView {
    private let label = NSTextField(labelWithString: "")
    var onClick: (() -> Void)?

    init(text: String, color: NSColor, width: CGFloat? = nil) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.borderWidth = 0.5
        layer?.cornerRadius = 5
        label.stringValue = text
        label.font = .systemFont(ofSize: 10.5)
        label.textColor = color
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        var constraints = [
            label.centerXAnchor.constraint(equalTo: centerXAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            heightAnchor.constraint(equalToConstant: 20),
        ]
        if let width {
            constraints.append(widthAnchor.constraint(equalToConstant: width))
        } else {
            constraints.append(widthAnchor.constraint(equalTo: label.widthAnchor, constant: 12))
        }
        NSLayoutConstraint.activate(constraints)
        refreshColors()
    }

    override func refreshColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.borderColor = NSColor.chalkKeyBadgeEdge.cgColor
        }
    }

    override func mouseDown(with event: NSEvent) {
        guard let onClick else { super.mouseDown(with: event); return }
        onClick()
    }
}

/// A palette row's content knows whether its row is the keyboard's.
protocol PaletteRowContent: AnyObject {
    func setHighlighted(_ highlighted: Bool)
}

/// A palette result row: the accent wash pill while selected, nothing otherwise.
final class PaletteRowView: NSTableRowView {
    override var isFlipped: Bool { true }

    override var isSelected: Bool {
        didSet { (subviews.first as? PaletteRowContent)?.setHighlighted(isSelected) }
    }

    override func drawBackground(in dirtyRect: NSRect) {}

    override func drawSelection(in dirtyRect: NSRect) {
        guard isSelected else { return }
        // The table is already inset from the card, so the pill spans the row minus a hair.
        fillChalkPill(.chalkAccentSelection, insetY: 1, radius: ChalkMetrics.paletteRowRadius)
    }

    override func drawSeparator(in dirtyRect: NSRect) {}
}

/// The shared frame of both palettes: an input row (glyph, field, esc badge),
/// a hairline, the results table, and a footer with the key hints and a
/// count. The owner wires the field's and table's delegates to itself.
final class PaletteFrame {
    static let inputRowHeight: CGFloat = 48
    static let footerHeight: CGFloat = 33
    static let resultsPadding: CGFloat = 8

    let searchField = NSTextField()
    let tableView = NSTableView()
    let scrollView = NSScrollView()
    let countLabel = NSTextField(labelWithString: "")
    /// Centered over the results, for a palette with nothing to list.
    let emptyLabel = NSTextField(labelWithString: "")
    private let escBadge: KeyBadgeView
    private let glyphName: String
    private let placeholder: String
    private let hints: String
    private let rowHeight: CGFloat

    init(glyph: String, placeholder: String, hints: String, rowHeight: CGFloat) {
        glyphName = glyph
        self.placeholder = placeholder
        self.hints = hints
        self.rowHeight = rowHeight
        escBadge = KeyBadgeView(text: "esc", color: .chalkChromeFgQuaternary)
    }

    /// Build the frame into `view`. `onEscape` is the badge's click.
    func install(in view: NSView, onEscape: @escaping () -> Void) {
        let inputRow = FlippedView()
        inputRow.translatesAutoresizingMaskIntoConstraints = false

        let glyph = NSImageView()
        glyph.image = NSImage(systemSymbolName: glyphName, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 14, weight: .regular))
        glyph.contentTintColor = .chalkChromeFgTertiary
        glyph.imageScaling = .scaleNone
        glyph.setContentHuggingPriority(.required, for: .horizontal)
        glyph.translatesAutoresizingMaskIntoConstraints = false

        searchField.font = .systemFont(ofSize: ChalkMetrics.paletteSearchFontSize)
        searchField.textColor = .chalkChromeFg
        searchField.isBordered = false
        searchField.isBezeled = false
        searchField.drawsBackground = false
        searchField.focusRingType = .none // the accent caret is the only focus cue
        searchField.placeholderAttributedString = NSAttributedString(
            string: placeholder,
            attributes: [.foregroundColor: NSColor.chalkChromeFgQuaternary,
                         .font: NSFont.systemFont(ofSize: ChalkMetrics.paletteSearchFontSize)])
        searchField.cell?.usesSingleLineMode = true
        searchField.cell?.wraps = false
        searchField.cell?.isScrollable = true
        searchField.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)
        searchField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        searchField.translatesAutoresizingMaskIntoConstraints = false

        escBadge.onClick = onEscape
        escBadge.setAccessibilityLabel("Close")
        escBadge.translatesAutoresizingMaskIntoConstraints = false

        inputRow.addSubview(glyph)
        inputRow.addSubview(searchField)
        inputRow.addSubview(escBadge)

        let divider = Self.hairline()

        let column = NSTableColumn(identifier: .init("result"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.style = .plain
        tableView.rowHeight = rowHeight
        tableView.intercellSpacing = .zero
        tableView.selectionHighlightStyle = .none
        tableView.backgroundColor = .clear
        tableView.focusRingType = .none
        tableView.allowsEmptySelection = true
        tableView.allowsMultipleSelection = false
        // The field keeps the keyboard; a click on a row must not take it.
        tableView.refusesFirstResponder = true
        tableView.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        scrollView.documentView = tableView
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.contentInsets = NSEdgeInsets(top: Self.resultsPadding, left: 0, bottom: Self.resultsPadding, right: 0)
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        emptyLabel.font = .systemFont(ofSize: ChalkMetrics.outlineRowFontSize)
        emptyLabel.textColor = .chalkChromeFgQuaternary
        emptyLabel.alignment = .center
        emptyLabel.isHidden = true
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false

        let footer = FlippedView()
        footer.translatesAutoresizingMaskIntoConstraints = false
        let footerHairline = Self.hairline()
        footer.addSubview(footerHairline)

        let hintsLabel = NSTextField(labelWithString: hints)
        hintsLabel.font = .systemFont(ofSize: ChalkMetrics.paletteHintFontSize)
        hintsLabel.textColor = .chalkChromeFgQuaternary
        hintsLabel.translatesAutoresizingMaskIntoConstraints = false
        footer.addSubview(hintsLabel)

        countLabel.font = .systemFont(ofSize: ChalkMetrics.paletteHintFontSize)
        countLabel.textColor = .chalkChromeFgQuaternary
        countLabel.alignment = .right
        countLabel.translatesAutoresizingMaskIntoConstraints = false
        footer.addSubview(countLabel)

        view.addSubview(inputRow)
        view.addSubview(divider)
        view.addSubview(scrollView)
        view.addSubview(emptyLabel)
        view.addSubview(footer)
        NSLayoutConstraint.activate([
            inputRow.topAnchor.constraint(equalTo: view.topAnchor),
            inputRow.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            inputRow.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            inputRow.heightAnchor.constraint(equalToConstant: Self.inputRowHeight),

            glyph.leadingAnchor.constraint(equalTo: inputRow.leadingAnchor, constant: 16),
            glyph.centerYAnchor.constraint(equalTo: inputRow.centerYAnchor),
            searchField.leadingAnchor.constraint(equalTo: glyph.trailingAnchor, constant: 10),
            searchField.trailingAnchor.constraint(equalTo: escBadge.leadingAnchor, constant: -10),
            searchField.centerYAnchor.constraint(equalTo: inputRow.centerYAnchor),
            escBadge.trailingAnchor.constraint(equalTo: inputRow.trailingAnchor, constant: -16),
            escBadge.centerYAnchor.constraint(equalTo: inputRow.centerYAnchor),

            divider.topAnchor.constraint(equalTo: inputRow.bottomAnchor),
            divider.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            divider.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
            divider.heightAnchor.constraint(equalToConstant: 0.5),

            scrollView.topAnchor.constraint(equalTo: divider.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 8),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -8),
            scrollView.bottomAnchor.constraint(equalTo: footer.topAnchor),
            emptyLabel.centerXAnchor.constraint(equalTo: scrollView.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor),

            footer.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            footer.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            footer.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            footer.heightAnchor.constraint(equalToConstant: Self.footerHeight),
            footerHairline.topAnchor.constraint(equalTo: footer.topAnchor),
            footerHairline.leadingAnchor.constraint(equalTo: footer.leadingAnchor),
            footerHairline.trailingAnchor.constraint(equalTo: footer.trailingAnchor),
            footerHairline.heightAnchor.constraint(equalToConstant: 0.5),
            hintsLabel.leadingAnchor.constraint(equalTo: footer.leadingAnchor, constant: 16),
            hintsLabel.centerYAnchor.constraint(equalTo: footer.centerYAnchor),
            countLabel.leadingAnchor.constraint(
                greaterThanOrEqualTo: hintsLabel.trailingAnchor, constant: 14),
            countLabel.trailingAnchor.constraint(equalTo: footer.trailingAnchor, constant: -16),
            countLabel.centerYAnchor.constraint(equalTo: footer.centerYAnchor),
        ])
    }

    private static func hairline() -> NSView {
        let line = FlippedView()
        line.wantsLayer = true
        line.translatesAutoresizingMaskIntoConstraints = false
        line.layer?.backgroundColor = NSColor.chalkPaletteDivider.cgColor
        return line
    }

    /// The field editor for the search field, dressed: no smart substitutions
    /// in a filename or heading query, and the accent caret.
    static func dress(fieldEditor: NSTextView) {
        fieldEditor.isAutomaticQuoteSubstitutionEnabled = false
        fieldEditor.isAutomaticDashSubstitutionEnabled = false
        fieldEditor.isAutomaticTextReplacementEnabled = false
        fieldEditor.isAutomaticSpellingCorrectionEnabled = false
        fieldEditor.isContinuousSpellCheckingEnabled = false
        fieldEditor.insertionPointColor = .chalkAccent
    }

    /// The palettes' shared command set in the field: Up/Down move the row,
    /// Escape cancels, Return confirms. nil for anything else.
    enum FieldCommand { case up, down, cancel, confirm }

    static func command(for selector: Selector) -> FieldCommand? {
        switch selector {
        case #selector(NSResponder.moveUp(_:)): return .up
        case #selector(NSResponder.moveDown(_:)): return .down
        case #selector(NSResponder.cancelOperation(_:)): return .cancel
        case #selector(NSResponder.insertNewline(_:)): return .confirm
        default: return nil
        }
    }
}

/// Accent highlight on a prefix match: the matched run in the accent, semibold.
func paletteHighlightedTitle(_ text: String, query: String, baseWeight: NSFont.Weight,
                             size: CGFloat) -> NSAttributedString {
    let attributed = NSMutableAttributedString(
        string: text,
        attributes: [.foregroundColor: NSColor.chalkChromeFg,
                     .font: NSFont.systemFont(ofSize: size, weight: baseWeight)])
    if !query.isEmpty, text.lowercased().hasPrefix(query.lowercased()),
       let range = text.range(of: text.prefix(query.count)) {
        attributed.addAttributes([
            .foregroundColor: NSColor.chalkAccent,
            .font: NSFont.systemFont(ofSize: size, weight: .semibold),
        ], range: NSRange(range, in: text))
    }
    return attributed
}

/// Focus-grab breadcrumbs. See docs/issues/2026-08-17-fullscreen-drops-when-outline-opens.md.
private let paletteFocusLog = Logger(subsystem: "com.huleux.chalk", category: "palette")

/// What the two palettes share above the `PaletteFrame`: keyboard selection,
/// the focus grab, the query debounce, the field and table plumbing, and the
/// card height report. A subclass owns its results and overrides the hooks
/// under "Subclass hooks".
class PaletteListViewController: NSViewController, NSTextFieldDelegate,
                                 NSTableViewDataSource, NSTableViewDelegate {
    /// Fired once the overlay is hidden, on every exit path.
    var onDismiss: (() -> Void)?
    /// Ask the host to hide the overlay, then run `then`. A child view can't dismiss itself.
    var onClose: ((_ then: (() -> Void)?) -> Void)?
    /// The card's natural height for the current results. The host caps it against the window.
    var onContentHeightChanged: ((CGFloat) -> Void)?

    let frame: PaletteFrame
    var selectedIndex = 0
    /// The query the current results were computed for.
    private(set) var appliedQuery = ""
    private var pendingQuery: DispatchWorkItem?
    /// Bumped on every reveal and on willHide; a grabFocus retry from an older generation bails.
    private var revealGeneration = 0

    init(frame: PaletteFrame) {
        self.frame = frame
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    // MARK: Subclass hooks

    var resultCount: Int { 0 }
    /// "result" / "item": the footer's count label.
    var resultNoun: String { "result" }
    /// Shown over an empty table; nil keeps the table bare.
    var emptyMessage: String? { nil }
    /// Recompute the results and `selectedIndex` for `query`.
    func computeResults(for query: String) {}
    /// The height of the rows (or the empty state) between the input row and the footer.
    func bodyHeight() -> CGFloat { 0 }
    /// The cell for `row`, dequeued from `tableView`.
    func cell(for row: Int, in tableView: NSTableView) -> NSView? { nil }
    /// The action for the confirmed row, run once the overlay is hidden. Captures what it
    /// needs now: the results may change before it runs.
    func confirmation(of index: Int, inNewTab: Bool) -> () -> Void { {} }
    /// Drop per-presentation content before a reused instance is re-presented.
    func resetForReuse() {}

    // MARK: Shared behaviour

    var currentQuery: String { isViewLoaded ? frame.searchField.stringValue : "" }

    func applyQuery(_ query: String) {
        appliedQuery = query
        computeResults(for: query)
        guard isViewLoaded else { return }
        frame.tableView.reloadData()
        select(selectedIndex)
        frame.countLabel.stringValue = resultCount == 1 ? "1 \(resultNoun)" : "\(resultCount) \(resultNoun)s"
        if let emptyMessage {
            frame.emptyLabel.stringValue = emptyMessage
            frame.emptyLabel.isHidden = resultCount > 0
        }
        reportContentHeight()
    }

    private func reportContentHeight() {
        onContentHeightChanged?(PaletteFrame.inputRowHeight + 1 + PaletteFrame.resultsPadding * 2
                                + bodyHeight() + PaletteFrame.footerHeight)
    }

    private func moveUp() { select(max(0, selectedIndex - 1)) }
    private func moveDown() { select(min(resultCount - 1, selectedIndex + 1)) }
    private func cancelPalette() {
        onClose? { [weak self] in self?.onDismiss?() }
    }

    private func select(_ index: Int) {
        guard (0..<resultCount).contains(index) else {
            frame.tableView.deselectAll(nil)
            return
        }
        selectedIndex = index
        frame.tableView.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        frame.tableView.scrollRowToVisible(index)
    }

    private func confirmSelected(inNewTab: Bool = false) {
        guard (0..<resultCount).contains(selectedIndex) else { return }
        let action = confirmation(of: selectedIndex, inNewTab: inNewTab)
        onClose? { [weak self] in
            action()
            self?.onDismiss?()
        }
    }

    /// Reset before a reused instance is re-presented.
    func prepareForReuse() {
        loadViewIfNeeded()
        frame.searchField.stringValue = ""
        resetForReuse()
        applyQuery("")
    }

    override func loadView() {
        let content = PaletteContentView()
        content.onCommandReturn = { [weak self] in self?.confirmSelected(inNewTab: true) }
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
        // The editor webview holds the keyboard, and an immediate grab can
        // lose to it (its blur round-trips through the web process). Retry
        // until we win; `willHide` cancels the chain.
        revealGeneration += 1
        grabFocus(retries: 5, generation: revealGeneration)
    }

    /// Called by the host as the overlay hides. Cancels pending focus retries,
    /// which would otherwise hand the keyboard to the hidden field and swallow
    /// the editor's keystrokes.
    func willHide() {
        revealGeneration += 1
    }

    private func grabFocus(retries: Int, generation: Int) {
        guard generation == revealGeneration else { return }
        #if DEBUG
        focusAttemptCountForTesting += 1
        #endif
        let won = view.window?.makeFirstResponder(frame.searchField) ?? false
        paletteFocusLog.info("grabFocus: won=\(won, privacy: .public) retriesLeft=\(retries, privacy: .public)")
        if won { return }
        guard retries > 0 else { return }
        // Spaced retries: the webview's release can land several runloop turns later.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) { [weak self] in
            self?.grabFocus(retries: retries - 1, generation: generation)
        }
    }

    private func textChanged() {
        // Debounce burst typing (the filter walks every item on the main thread); clearing
        // applies at once.
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
        guard (0..<resultCount).contains(row) else { return }
        selectedIndex = row
        confirmSelected()
    }

    // MARK: NSTextFieldDelegate

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
        case .confirm: confirmSelected()
        }
        return true
    }

    // MARK: Table

    func numberOfRows(in tableView: NSTableView) -> Int { resultCount }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        PaletteRowView()
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        cell(for: row, in: tableView)
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        let row = frame.tableView.selectedRow
        if row >= 0 { selectedIndex = row }
    }

    #if DEBUG
    /// Force a query without the debounce.
    func setQueryForAudit(_ query: String) {
        loadViewIfNeeded()
        frame.searchField.stringValue = query
        applyQuery(query)
    }

    var selectedIndexForTesting: Int { selectedIndex }
    var isEmptyStateVisibleForTesting: Bool { !frame.emptyLabel.isHidden }
    func confirmSelectedForTesting(inNewTab: Bool = false) { confirmSelected(inNewTab: inNewTab) }
    func moveSelectionForTesting(down: Bool) { down ? moveDown() : moveUp() }
    var searchFieldForTesting: NSTextField { frame.searchField }
    var tableViewForTesting: NSTableView { frame.tableView }
    /// becomeFirstResponder attempts by grabFocus.
    private(set) var focusAttemptCountForTesting = 0
    #endif
}
