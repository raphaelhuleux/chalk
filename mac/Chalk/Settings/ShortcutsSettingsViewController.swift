import AppKit
import ChalkKit

/// Callbacks name their row by identity, never by index: the table may have
/// reloaded by the time a callback fires (see `ShortcutRowIdentity`).
protocol ShortcutRowViewDelegate: AnyObject {
    func rowView(_ row: ShortcutRowView, didEdit identity: ShortcutRowIdentity, trigger: String, replacement: String)
    func rowView(_ row: ShortcutRowView, identity: ShortcutRowIdentity, didChange options: SnippetOptions)
    func rowView(_ row: ShortcutRowView, identity: ShortcutRowIdentity, didSetEnabled isEnabled: Bool)
    /// Reset (a fork) or Delete (a user shortcut): the row button and the context menu share it.
    func rowView(_ row: ShortcutRowView, requestsRemovalOf identity: ShortcutRowIdentity)
    /// The replacement grew or shrank; the table needs to re-measure.
    func rowViewDidChangeHeight(_ row: ShortcutRowView)
}

/// Column geometry shared by the rows and the column header so the labels sit over their columns.
enum ShortcutColumnLayout {
    /// The enable checkbox ahead of the first column; unlabelled in the header.
    static var checkboxWidth: CGFloat { 20 }
    static var gap: CGFloat { 10 }
    static var inset: CGFloat { 16 }
    /// Fractions of the row's content width.
    static let triggerWidthMultiplier: CGFloat = 0.20
    static let replacementWidthMultiplier: CGFloat = 0.48
}

/// The table, with the row context menu (Reset / Delete) on the right-click.
final class ShortcutsTableView: NSTableView {
    var onMenuForRow: ((Int) -> NSMenu?)?

    override func menu(for event: NSEvent) -> NSMenu? {
        onMenuForRow?(row(at: convert(event.locationInWindow, from: nil)))
    }
}

/// The LaTeX Shortcuts pane: one table of shortcuts, edited in place.
/// Built-in rows fork into user snippets on first edit, with Reset on the
/// row. Mutations fire `onSnippetsChange` (coalesced).
final class ShortcutsSettingsViewController: NSViewController {
    var onSnippetsChange: (() -> Void)?

    private let library: SnippetLibrary
    private let searchField = NSSearchField()
    private let scrollView = NSScrollView()
    private let tableView = ShortcutsTableView()

    private var yours: [ShortcutRow] = []
    private var builtin: [ShortcutRow] = []
    private var query = "" { didSet { reload() } }

    /// What the table shows, in order.
    enum TableRow: Equatable {
        case header(title: String, showsColumns: Bool)
        case shortcut(ShortcutRowIdentity)
        case addRow
        case footer
    }
    private var tableRows: [TableRow] = []

    /// The rail row being shown. Only `.yours` offers the add row; the others slice the built-ins.
    var selectedCategory: ShortcutCategory = .yours {
        didSet {
            guard selectedCategory != oldValue else { return }
            if isViewLoaded {
                // A rail click does not end the focused field, and after
                // `reload()` swaps the slice its blur can no longer find its
                // row, dropping the edit. Commit it first, while the old arrays
                // are current; the save only schedules a reload.
                if isAnyRowBeingEdited() { view.window?.makeFirstResponder(nil) }
                reload()
                if tableView.numberOfRows > 0 { tableView.scrollRowToVisible(0) }
            }
        }
    }

    /// Hidden while searching so row indices map cleanly onto the filtered arrays.
    private var showsAddRow: Bool { !isFiltering && selectedCategory == .yours }

    /// Set when the table needs resyncing but a row may be first responder. Cleared by `reload()`.
    private var pendingReload = false

    /// The snippet the add row created before a deferred reload caught up
    /// (the row is still `.addRow`). Without it the next blur would create a
    /// second snippet or trip the duplicate check. Cleared by `reload()`.
    private var pendingAddRowId: String?

    /// Coalesces the recompose-and-push behind `onSnippetsChange`, since the
    /// options menu invites rapid toggles. The store write and `invalidate()`
    /// stay synchronous.
    private var pendingPush: DispatchWorkItem?
    private static let pushCoalesceInterval: TimeInterval = 0.25

    private var isFiltering: Bool { !query.isEmpty }

    /// `library` defaults to the user's; tests pass one over their own store.
    init(library: SnippetLibrary = .shared) {
        self.library = library
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func loadView() {
        view = ChromeToneView()
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        searchField.placeholderString = "Search shortcuts"
        searchField.delegate = self
        searchField.focusRingType = .none
        searchField.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(searchField)

        let column = NSTableColumn(identifier: .init("shortcut"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.style = .plain
        tableView.intercellSpacing = .zero
        tableView.selectionHighlightStyle = .none
        tableView.backgroundColor = .clear
        tableView.focusRingType = .none
        tableView.allowsEmptySelection = true
        tableView.usesAutomaticRowHeights = true
        tableView.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        tableView.dataSource = self
        tableView.delegate = self
        tableView.onMenuForRow = { [weak self] row in self?.contextMenu(forRow: row) }
        scrollView.documentView = tableView
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.contentInsets = NSEdgeInsets(top: 0, left: 0, bottom: 16, right: 0)
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scrollView)

        NSLayoutConstraint.activate([
            searchField.topAnchor.constraint(equalTo: view.topAnchor, constant: 12),
            searchField.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            searchField.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            scrollView.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 10),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        reload()
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        tableView.sizeLastColumnToFit()
    }

    // MARK: - Data

    private func reload() {
        pendingReload = false
        pendingAddRowId = nil
        let sections = ShortcutTableModel.rows(
            user: library.store.snippets(),
            builtins: library.builtins,
            disabledBuiltinKeys: library.store.disabledBuiltinKeys(),
            query: query,
            // Search ignores the rail category on purpose.
            category: isFiltering ? nil : selectedCategory)
        yours = sections.yours
        builtin = sections.builtin

        var rows: [TableRow] = []
        if !yours.isEmpty || showsAddRow {
            rows.append(.header(title: "Your Shortcuts", showsColumns: true))
            rows += yours.map { .shortcut($0.identity) }
            if showsAddRow { rows.append(.addRow) }
        }
        if !builtin.isEmpty {
            let title = isFiltering ? "Built-in (\(builtin.count))" : "\(selectedCategory.title) (\(builtin.count))"
            rows.append(.header(title: title, showsColumns: rows.isEmpty))
            rows += builtin.map { .shortcut($0.identity) }
        }
        if !rows.isEmpty { rows.append(.footer) }

        // Same rows in the same order: refresh in place. `reloadData()` would
        // drop the field being typed into. Structural changes take the full reload.
        if rows == tableRows, refreshVisibleRows() { return }
        tableRows = rows
        tableView.reloadData()
    }

    /// Reconfigures visible rows from the model. False when a view shows a
    /// different row than the model expects, which needs a full reload.
    private func refreshVisibleRows() -> Bool {
        for index in Range(tableView.rows(in: tableView.visibleRect)) ?? 0..<0 {
            guard index < tableRows.count,
                  let rowView = tableView.view(atColumn: 0, row: index, makeIfNecessary: false) as? ShortcutRowView
            else { continue }
            guard case .shortcut(let identity) = tableRows[index], rowView.identity == identity,
                  let row = row(for: identity) else {
                if case .addRow = tableRows[index], rowView.identity == .addRow { continue }
                return false
            }
            configure(rowView, with: row)
        }
        return true
    }

    /// Every mutation ends here. `invalidate()` is immediate so a new tab
    /// never gets the stale cache; only the push is coalesced.
    private func changed() {
        library.invalidate()
        pendingPush?.cancel()
        let push = DispatchWorkItem { [weak self] in
            self?.pendingPush = nil
            self?.onSnippetsChange?()
        }
        pendingPush = push
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.pushCoalesceInterval, execute: push)
    }

    /// Fires a coalesced push now. Leaving the screen must not outrun it.
    func flushPendingPush() {
        guard let push = pendingPush else { return }
        push.cancel()
        pendingPush = nil
        onSnippetsChange?()
    }

    override func viewWillDisappear() {
        super.viewWillDisappear()
        flushPendingPush()
    }

    /// True while some row's field holds the keyboard. Reloading mid-edit
    /// drops the field being typed into, so reloads that could race an edit
    /// go through `requestReload()`.
    private func isAnyRowBeingEdited() -> Bool {
        guard let responder = view.window?.firstResponder as? NSTextView,
              let field = responder.delegate as? NSTextField else { return false }
        return field.isDescendant(of: tableView)
    }

    /// Marks the table dirty and reloads as soon as nothing is mid-edit.
    private func requestReload() {
        pendingReload = true
        scheduleReloadFlush()
    }

    /// Retries a deferred reload on the next runloop turn, once a same-row
    /// focus handoff has landed. Every delegate callback must call this, even
    /// ones that save nothing, or the flag strands and a forked row reads as built-in.
    private func scheduleReloadFlush() {
        DispatchQueue.main.async { [weak self] in self?.flushReloadIfIdle() }
    }

    private func flushReloadIfIdle() {
        guard pendingReload, !isAnyRowBeingEdited() else { return }
        reload()
    }

    /// The row a callback's identity names; nil for the add row or a row deleted since.
    private func row(for identity: ShortcutRowIdentity) -> ShortcutRow? {
        ShortcutTableModel.row(identity, yours: yours, builtin: builtin)
    }

    /// The stored fork of a built-in. The row model can lag the store while a
    /// reload is deferred, so the store decides whether a built-in is forked.
    private func storedFork(ofBuiltinKey key: String) -> UserSnippet? {
        library.store.snippets().first { $0.overridesBuiltinKey == key }
    }

    /// The add row's created snippet not yet reloaded into a row, read from the store.
    private func pendingAddRowSnippet() -> UserSnippet? {
        guard let id = pendingAddRowId else { return nil }
        return library.store.snippets().first { $0.id == id }
    }

    /// The stored snippet a row edits, forking on first touch of a built-in.
    private func editableSnippet(for row: ShortcutRow) -> UserSnippet {
        if let existing = row.userSnippet { return existing }
        guard case .builtin(let source) = row.source else {
            preconditionFailure("editableSnippet(for:) has no stored snippet only when the row is an unforked builtin")
        }
        // Two edits can land before a reload; reuse the first one's fork.
        if let fork = storedFork(ofBuiltinKey: source.key) {
            return fork
        }
        // `ShortcutTableModel.fork` always mints an enabled snippet; keep a disabled built-in disabled.
        var fork = ShortcutTableModel.fork(source)
        fork.enabled = row.isEnabled
        return fork
    }

    private func save(_ snippet: UserSnippet) {
        library.store.upsert(snippet)
        changed()
        requestReload()
    }

    private func remove(identity: ShortcutRowIdentity) {
        guard let row = row(for: identity) else { return }
        // Both remove the stored snippet; on a fork that brings the built-in back, hence "Reset".
        let snippet: UserSnippet
        switch row.source {
        case .user(let user): snippet = user
        case .fork(_, let fork): snippet = fork
        case .builtin: return
        }
        library.store.remove(id: snippet.id)
        changed()
        requestReload()
    }

    /// Reports a rejected edit.
    private func showError(_ message: String) {
        #if DEBUG
        lastErrorForTesting = message
        #endif
        presentChalkNotice(title: nil, message: message)
    }

    private func validate(_ snippet: UserSnippet) -> String? {
        if let error = SnippetComposer.validateTrigger(snippet.trigger, isRegex: snippet.options.isRegex) { return error }
        if let error = SnippetComposer.validateReplacement(snippet.replacement) { return error }
        let duplicate = library.store.snippets().contains {
            $0.trigger == snippet.trigger && $0.id != snippet.id
        }
        return duplicate ? "You already have a shortcut with this trigger." : nil
    }

    /// The right-click menu: Reset on a fork, Delete on a user shortcut, nothing on a built-in.
    private func contextMenu(forRow index: Int) -> NSMenu? {
        guard tableRows.indices.contains(index), case .shortcut(let identity) = tableRows[index],
              let row = row(for: identity), let title = Self.removalTitle(for: row) else { return nil }
        let menu = NSMenu()
        menu.addItem(MenuActionItem(title: title) { [weak self] in self?.remove(identity: identity) })
        return menu
    }

    static func removalTitle(for row: ShortcutRow) -> String? {
        switch row.source {
        case .user: return "Delete"
        case .fork: return "Reset"
        case .builtin: return nil
        }
    }

    fileprivate func configure(_ view: ShortcutRowView, with row: ShortcutRow?) {
        guard let row else {
            view.configure(identity: .addRow, trigger: "", replacement: "", options: SnippetOptions(),
                           isEnabled: true, isModified: false, removalTitle: nil)
            return
        }
        view.configure(identity: row.identity, trigger: row.trigger, replacement: row.replacement,
                       options: row.options, isEnabled: row.isEnabled, isModified: row.isModified,
                       removalTitle: Self.removalTitle(for: row))
    }

    #if DEBUG
    private(set) var lastErrorForTesting: String?
    var tableRowsForTesting: [TableRow] { tableRows }
    var yoursForTesting: [ShortcutRow] { yours }
    var builtinForTesting: [ShortcutRow] { builtin }
    func setQueryForTesting(_ text: String) { query = text }
    /// Drive the row callbacks the way a row would.
    func editForTesting(_ identity: ShortcutRowIdentity, trigger: String, replacement: String) {
        let probe = ShortcutRowView()
        rowView(probe, didEdit: identity, trigger: trigger, replacement: replacement)
    }
    func setOptionsForTesting(_ identity: ShortcutRowIdentity, _ options: SnippetOptions) {
        rowView(ShortcutRowView(), identity: identity, didChange: options)
    }
    func setEnabledForTesting(_ identity: ShortcutRowIdentity, _ enabled: Bool) {
        rowView(ShortcutRowView(), identity: identity, didSetEnabled: enabled)
    }
    func removeForTesting(_ identity: ShortcutRowIdentity) { remove(identity: identity) }
    /// Land a deferred reload now, as the runloop would.
    func flushReloadForTesting() { flushReloadIfIdle() }
    var tableViewForTesting: NSTableView { tableView }
    #endif
}

// MARK: - Data source and delegate

extension ShortcutsSettingsViewController: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int { tableRows.count }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { false }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let rowView = ShortcutTableRowView()
        switch tableRows[row] {
        case .shortcut, .addRow: rowView.isCard = true
        case .header, .footer: break
        }
        return rowView
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row index: Int) -> NSView? {
        switch tableRows[index] {
        case .header(let title, let showsColumns):
            let header = tableView.makeView(withIdentifier: ShortcutColumnsHeaderView.identifier, owner: nil)
                as? ShortcutColumnsHeaderView ?? ShortcutColumnsHeaderView()
            header.configure(title: title, showsColumns: showsColumns)
            return header
        case .footer:
            let footer = tableView.makeView(withIdentifier: ShortcutFooterView.identifier, owner: nil)
                as? ShortcutFooterView ?? ShortcutFooterView()
            return footer
        case .shortcut, .addRow:
            let view = tableView.makeView(withIdentifier: ShortcutRowView.identifier, owner: nil)
                as? ShortcutRowView ?? ShortcutRowView()
            view.delegate = self
            if case .shortcut(let identity) = tableRows[index] {
                configure(view, with: row(for: identity))
            } else {
                configure(view, with: nil)
            }
            return view
        }
    }
}

// MARK: - Row editing

extension ShortcutsSettingsViewController: ShortcutRowViewDelegate {
    func rowView(_ row: ShortcutRowView, didEdit identity: ShortcutRowIdentity,
                 trigger: String, replacement: String) {
        // Flush a deferred reload on every path, including those that save nothing.
        defer { scheduleReloadFlush() }

        guard let target = self.row(for: identity) else {
            guard identity == .addRow else { return }
            // The add row already created its snippet; edit it rather than creating a second.
            if let stored = pendingAddRowSnippet() {
                var snippet = stored
                guard snippet.trigger != trigger || snippet.replacement != replacement else { return }
                snippet.trigger = trigger
                snippet.replacement = replacement
                if let error = validate(snippet) {
                    showError(error)
                    return requestReload() // revert the rejected text once editing settles
                }
                return save(snippet)
            }
            guard !trigger.isEmpty, !replacement.isEmpty else { return }
            let created = UserSnippet(trigger: trigger, replacement: replacement)
            if let error = validate(created) {
                showError(error)
                return requestReload()
            }
            pendingAddRowId = created.id
            return save(created)
        }

        var snippet = editableSnippet(for: target)
        guard snippet.trigger != trigger || snippet.replacement != replacement else { return }
        snippet.trigger = trigger
        snippet.replacement = replacement
        if let error = validate(snippet) {
            showError(error)
            return requestReload()
        }
        save(snippet)
    }

    func rowView(_ row: ShortcutRowView, identity: ShortcutRowIdentity, didChange options: SnippetOptions) {
        defer { scheduleReloadFlush() }
        guard let target = self.row(for: identity) else { return }
        var snippet = editableSnippet(for: target)
        snippet.options = options
        if let error = validate(snippet) {
            showError(error)
            return requestReload()
        }
        save(snippet)
    }

    func rowView(_ row: ShortcutRowView, identity: ShortcutRowIdentity, didSetEnabled isEnabled: Bool) {
        defer { scheduleReloadFlush() }
        guard let target = self.row(for: identity) else { return }
        // An unforked built-in uses the store's disable set, everything else
        // its `enabled` flag. Ask the store, not the row, which can still say
        // `.builtin` while a reload is pending.
        if case .builtin(let source) = target.source, storedFork(ofBuiltinKey: source.key) == nil {
            library.store.setBuiltinDisabled(key: source.key, disabled: !isEnabled)
            changed()
            return requestReload()
        }
        var snippet = editableSnippet(for: target)
        snippet.enabled = isEnabled
        save(snippet)
    }

    func rowView(_ row: ShortcutRowView, requestsRemovalOf identity: ShortcutRowIdentity) {
        remove(identity: identity)
    }

    func rowViewDidChangeHeight(_ row: ShortcutRowView) {
        let index = tableView.row(for: row)
        guard index >= 0 else { return }
        // Re-measure without reloading: reloading would drop the field being typed into.
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0
            tableView.noteHeightOfRows(withIndexesChanged: IndexSet(integer: index))
        }
    }
}

// MARK: - Search

extension ShortcutsSettingsViewController: NSSearchFieldDelegate {
    func controlTextDidChange(_ notification: Notification) {
        guard (notification.object as? NSSearchField) === searchField else { return }
        query = searchField.stringValue.trimmingCharacters(in: .whitespaces)
    }
}

// MARK: - Views

/// Shortcut rows sit on the card tone; headers and the footer on the pane's.
final class ShortcutTableRowView: NSTableRowView {
    var isCard = false
    override var isFlipped: Bool { true }
    override func drawSelection(in dirtyRect: NSRect) {}
    override func drawSeparator(in dirtyRect: NSRect) {}
    override func drawBackground(in dirtyRect: NSRect) {
        guard isCard else { return }
        NSColor.chalkCardBackground.setFill()
        bounds.insetBy(dx: ChalkColumnInset.cardInset, dy: 0).fill()
        NSColor.chalkCardSeparator.setFill()
        NSRect(x: ChalkColumnInset.cardInset + ShortcutColumnLayout.inset, y: bounds.maxY - 1,
               width: bounds.width - 2 * (ChalkColumnInset.cardInset + ShortcutColumnLayout.inset), height: 1).fill()
    }
}

/// The cards' inset from the pane's edges.
enum ChalkColumnInset {
    static var cardInset: CGFloat { 20 }
}

/// One row of the shortcuts table: enable checkbox, trigger, replacement,
/// options pull-down, and Reset or Delete where the row is the user's. The
/// replacement is a wrapping field whose height drives the row.
final class ShortcutRowView: FlippedView, NSTextFieldDelegate {
    static let identifier = NSUserInterfaceItemIdentifier("shortcut-row")

    weak var delegate: ShortcutRowViewDelegate?

    /// The row this view currently renders, read back by the table instead of trusting indexes.
    private(set) var identity: ShortcutRowIdentity = .addRow

    private let enableButton = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let triggerField = NSTextField()
    private let modifiedLabel = NSTextField(labelWithString: "MODIFIED")
    private let replacementField = NSTextField()
    private let optionsButton = NSPopUpButton(frame: .zero, pullsDown: true)
    private let removalButton = NSButton(title: "", target: nil, action: nil)
    private var options = SnippetOptions()
    private var isEnabled = true
    /// Set while the row is being re-pointed at another shortcut, whose
    /// end-editing callbacks must not report the outgoing row's text as an edit.
    private var isBeingRecycled = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        identifier = Self.identifier
        let mono = NSFont.monospacedSystemFont(ofSize: 12.5, weight: .regular)

        for field in [triggerField, replacementField] {
            field.font = mono
            field.textColor = .chalkTextBody
            field.isBordered = false
            field.isBezeled = false
            field.drawsBackground = false
            field.focusRingType = .none
            field.delegate = self
            field.translatesAutoresizingMaskIntoConstraints = false
        }
        triggerField.placeholderString = "trigger"
        triggerField.cell?.usesSingleLineMode = true
        triggerField.cell?.isScrollable = true
        replacementField.placeholderString = "replacement"
        replacementField.cell?.usesSingleLineMode = false
        replacementField.cell?.wraps = true
        replacementField.cell?.isScrollable = false
        replacementField.lineBreakMode = .byWordWrapping
        replacementField.maximumNumberOfLines = 0
        replacementField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        // Marks an edited built-in, which is why it offers Reset.
        modifiedLabel.font = .systemFont(ofSize: 8.5, weight: .semibold)
        modifiedLabel.textColor = .chalkTextFaint
        modifiedLabel.isHidden = true
        modifiedLabel.translatesAutoresizingMaskIntoConstraints = false

        optionsButton.isBordered = false
        optionsButton.font = .systemFont(ofSize: 11, weight: .medium)
        optionsButton.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        optionsButton.translatesAutoresizingMaskIntoConstraints = false
        (optionsButton.cell as? NSPopUpButtonCell)?.arrowPosition = .noArrow

        removalButton.isBordered = false
        removalButton.font = .systemFont(ofSize: 11, weight: .medium)
        removalButton.contentTintColor = .chalkTextMuted
        removalButton.target = self
        removalButton.action = #selector(removalTapped)
        removalButton.isHidden = true
        removalButton.translatesAutoresizingMaskIntoConstraints = false

        enableButton.target = self
        enableButton.action = #selector(enableToggled)
        enableButton.translatesAutoresizingMaskIntoConstraints = false

        for sub in [enableButton, triggerField, modifiedLabel, replacementField, optionsButton, removalButton] {
            addSubview(sub)
        }

        let inset = ChalkColumnInset.cardInset + ShortcutColumnLayout.inset
        let gap = ShortcutColumnLayout.gap
        let top: CGFloat = 8
        NSLayoutConstraint.activate([
            enableButton.leadingAnchor.constraint(equalTo: leadingAnchor, constant: inset),
            enableButton.topAnchor.constraint(equalTo: topAnchor, constant: top),
            enableButton.widthAnchor.constraint(equalToConstant: ShortcutColumnLayout.checkboxWidth),

            triggerField.leadingAnchor.constraint(equalTo: enableButton.trailingAnchor, constant: gap),
            triggerField.topAnchor.constraint(equalTo: topAnchor, constant: top),
            triggerField.widthAnchor.constraint(equalTo: widthAnchor, multiplier: ShortcutColumnLayout.triggerWidthMultiplier,
                                                constant: -inset * 2 * ShortcutColumnLayout.triggerWidthMultiplier),
            modifiedLabel.leadingAnchor.constraint(equalTo: triggerField.leadingAnchor),
            modifiedLabel.topAnchor.constraint(equalTo: triggerField.bottomAnchor, constant: 1),

            replacementField.leadingAnchor.constraint(equalTo: triggerField.trailingAnchor, constant: gap),
            replacementField.topAnchor.constraint(equalTo: topAnchor, constant: top),
            replacementField.widthAnchor.constraint(equalTo: widthAnchor, multiplier: ShortcutColumnLayout.replacementWidthMultiplier,
                                                    constant: -inset * 2 * ShortcutColumnLayout.replacementWidthMultiplier),

            optionsButton.leadingAnchor.constraint(equalTo: replacementField.trailingAnchor, constant: gap),
            optionsButton.topAnchor.constraint(equalTo: topAnchor, constant: top - 2),
            optionsButton.trailingAnchor.constraint(lessThanOrEqualTo: removalButton.leadingAnchor, constant: -gap),
            removalButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -inset),
            removalButton.topAnchor.constraint(equalTo: topAnchor, constant: top - 2),

            // The row is as tall as its tallest column, and none of them clips.
            bottomAnchor.constraint(greaterThanOrEqualTo: modifiedLabel.bottomAnchor, constant: top),
            bottomAnchor.constraint(greaterThanOrEqualTo: replacementField.bottomAnchor, constant: top),
            bottomAnchor.constraint(greaterThanOrEqualTo: optionsButton.bottomAnchor, constant: top),
            heightAnchor.constraint(greaterThanOrEqualToConstant: 36),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func layout() {
        super.layout()
        // The wrapping field measures against its laid-out width.
        replacementField.preferredMaxLayoutWidth = replacementField.frame.width
    }

    /// True while a field holds the keyboard.
    var isEditingAnyField: Bool {
        triggerField.currentEditor() != nil || replacementField.currentEditor() != nil
    }

    func configure(identity: ShortcutRowIdentity, trigger: String, replacement: String,
                   options: SnippetOptions, isEnabled: Bool, isModified: Bool, removalTitle: String?) {
        isBeingRecycled = true
        if self.identity != identity, isEditingAnyField { window?.makeFirstResponder(nil) }
        isBeingRecycled = false
        self.identity = identity
        if triggerField.currentEditor() == nil { triggerField.stringValue = trigger }
        if replacementField.currentEditor() == nil { replacementField.stringValue = replacement }
        self.options = options
        showOptions(options)
        // The trailing add row has nothing to configure or switch off yet.
        let isPlaceholder = identity == .addRow
        optionsButton.isHidden = isPlaceholder
        enableButton.isHidden = isPlaceholder
        modifiedLabel.isHidden = !isModified
        removalButton.isHidden = removalTitle == nil
        removalButton.title = removalTitle ?? ""
        setEnabled(isEnabled)
    }

    private func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
        enableButton.state = enabled ? .on : .off
        let color: NSColor = enabled ? .chalkTextBody : .chalkTextMuted
        triggerField.textColor = color
        replacementField.textColor = color
    }

    /// The pull-down's title is the chips; its items toggle the options.
    private func showOptions(_ options: SnippetOptions) {
        let labels = options.chipLabels
        let isEmpty = labels.isEmpty
        let color: NSColor = isEmpty ? .chalkTextFaint : .chalkTextMuted
        let menu = NSMenu()
        let titleItem = NSMenuItem()
        titleItem.attributedTitle = NSAttributedString(
            string: isEmpty ? "no options" : labels.joined(separator: " \u{00B7} "),
            attributes: [.font: NSFont.systemFont(ofSize: 11, weight: .medium),
                         .foregroundColor: color])
        menu.addItem(titleItem)
        let target = identity
        func toggle(_ title: String, _ isOn: Bool, _ apply: @escaping (inout SnippetOptions) -> Void) {
            let item = MenuActionItem(title: title) { [weak self] in
                guard let self else { return }
                var updated = self.options
                apply(&updated)
                self.reportOptions(updated, for: target)
            }
            item.state = isOn ? .on : .off
            menu.addItem(item)
        }
        toggle("Math only", options.mode == .math) { $0.mode = $0.mode == .math ? .any : .math }
        toggle("Text only", options.mode == .text) { $0.mode = $0.mode == .text ? .any : .text }
        menu.addItem(.separator())
        toggle("Auto-expand", options.autoExpand) { $0.autoExpand.toggle() }
        // No Whole word toggle on a regex trigger, where the engine ignores it.
        if options.wholeWordApplies {
            toggle("Whole word", options.wholeWord) { $0.wholeWord.toggle() }
        }
        toggle("Line start", options.lineStart) { $0.lineStart.toggle() }
        toggle("Regex trigger", options.isRegex) { $0.isRegex.toggle() }
        optionsButton.menu = menu
    }

    private func reportOptions(_ updated: SnippetOptions, for target: ShortcutRowIdentity) {
        // Repaint only if this view still shows the menu's row; the write goes by identity either way.
        if identity == target {
            options = updated
            showOptions(updated)
        }
        delegate?.rowView(self, identity: target, didChange: updated)
    }

    @objc private func enableToggled() {
        setEnabled(enableButton.state == .on)
        delegate?.rowView(self, identity: identity, didSetEnabled: isEnabled)
    }

    @objc private func removalTapped() {
        delegate?.rowView(self, requestsRemovalOf: identity)
    }

    private func reportEdit() {
        guard !isBeingRecycled else { return }
        delegate?.rowView(self, didEdit: identity, trigger: triggerField.stringValue,
                          replacement: replacementField.stringValue)
    }

    func controlTextDidBeginEditing(_ notification: Notification) {
        if let editor = notification.userInfo?["NSFieldEditor"] as? NSTextView {
            PaletteFrame.dress(fieldEditor: editor)
        }
    }

    func controlTextDidChange(_ notification: Notification) {
        if (notification.object as? NSTextField) === replacementField {
            delegate?.rowViewDidChangeHeight(self)
        }
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        reportEdit()
    }

    #if DEBUG
    var triggerFieldForTesting: NSTextField { triggerField }
    var replacementFieldForTesting: NSTextField { replacementField }
    var optionsTitleForTesting: String { optionsButton.menu?.items.first?.title ?? "" }
    var removalTitleForTesting: String? { removalButton.isHidden ? nil : removalButton.title }
    var isEnabledForTesting: Bool { isEnabled }
    #endif
}

/// A section header with the section title and, on the first section only,
/// the column labels, lined up with `ShortcutRowView`'s columns.
final class ShortcutColumnsHeaderView: FlippedView {
    static let identifier = NSUserInterfaceItemIdentifier("shortcut-header")
    private let titleLabel = NSTextField(labelWithString: "")
    private let columns = FlippedView()

    override init(frame: NSRect) {
        super.init(frame: frame)
        identifier = Self.identifier
        titleLabel.font = .systemFont(ofSize: 11, weight: .semibold)
        titleLabel.textColor = .chalkTextMuted
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        columns.translatesAutoresizingMaskIntoConstraints = false
        addSubview(titleLabel)
        addSubview(columns)

        let trigger = Self.columnLabel("Shortcut")
        let replacement = Self.columnLabel("Replacement")
        let options = Self.columnLabel("Options")
        for label in [trigger, replacement, options] {
            label.translatesAutoresizingMaskIntoConstraints = false
            columns.addSubview(label)
            NSLayoutConstraint.activate([
                label.topAnchor.constraint(equalTo: columns.topAnchor),
                label.bottomAnchor.constraint(equalTo: columns.bottomAnchor),
            ])
        }
        let gap = ShortcutColumnLayout.gap
        let inset = ChalkColumnInset.cardInset + ShortcutColumnLayout.inset
        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 14),
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: inset),
            columns.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 5),
            columns.leadingAnchor.constraint(equalTo: leadingAnchor, constant: inset),
            columns.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -inset),
            bottomAnchor.constraint(equalTo: columns.bottomAnchor, constant: 6),
            trigger.leadingAnchor.constraint(equalTo: columns.leadingAnchor,
                                             constant: ShortcutColumnLayout.checkboxWidth + gap),
            trigger.widthAnchor.constraint(equalTo: columns.widthAnchor,
                                           multiplier: ShortcutColumnLayout.triggerWidthMultiplier),
            replacement.leadingAnchor.constraint(equalTo: trigger.trailingAnchor, constant: gap),
            replacement.widthAnchor.constraint(equalTo: columns.widthAnchor,
                                               multiplier: ShortcutColumnLayout.replacementWidthMultiplier),
            options.leadingAnchor.constraint(equalTo: replacement.trailingAnchor, constant: gap),
            options.trailingAnchor.constraint(lessThanOrEqualTo: columns.trailingAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func configure(title: String, showsColumns: Bool) {
        titleLabel.stringValue = title
        columns.isHidden = !showsColumns
        for label in columns.subviews { label.isHidden = !showsColumns }
    }

    private static func columnLabel(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 10, weight: .semibold)
        label.textColor = .chalkTextMuted
        return label
    }
}

/// The table's footnote: how to add, fork and reset, and the placeholder syntax.
final class ShortcutFooterView: FlippedView {
    static let identifier = NSUserInterfaceItemIdentifier("shortcut-footer")

    override init(frame: NSRect) {
        super.init(frame: frame)
        identifier = Self.identifier
        let label = NSTextField(wrappingLabelWithString:
            "Type in the last row to add a shortcut. Editing a built-in makes it "
            + "yours; Reset brings the built-in back. Use $1, $2 for placeholders, $0 for the final "
            + "cursor position, and #1, #2 for regex captures.")
        label.font = .systemFont(ofSize: 11)
        label.textColor = .chalkTextFaint
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        let inset = ChalkColumnInset.cardInset + ShortcutColumnLayout.inset
        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: inset),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -inset),
            bottomAnchor.constraint(equalTo: label.bottomAnchor, constant: 10),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
}
