import UIKit
import ChalkKit

/// The LaTeX Shortcuts tab: one table of shortcuts, edited in place. Built-in rows fork into user
/// snippets on first edit, with Reset on swipe. Mutations fire `onSnippetsChange` (coalesced).
final class ShortcutsSettingsViewController: UIViewController {
    var onSnippetsChange: (() -> Void)?

    private let library = SnippetLibrary.shared
    private let tableView = UITableView(frame: .zero, style: .insetGrouped)
    private let searchBar = UISearchBar()

    private var yours: [ShortcutRow] = []
    private var builtin: [ShortcutRow] = []
    private var query = "" { didSet { reload() } }

    /// The rail row being shown. Only `.yours` offers the add row; the others slice the built-ins.
    var selectedCategory: ShortcutCategory = .yours {
        didSet {
            guard selectedCategory != oldValue else { return }
            if isViewLoaded {
                // A rail tap does not resign the focused field, and after `reload()` swaps the
                // slice its blur can no longer find its row, dropping the edit. Commit it first,
                // while the old arrays are current; the save only schedules a reload.
                if isAnyRowBeingEdited() { view.endEditing(true) }
                reload()
                tableView.setContentOffset(.zero, animated: false)
            }
        }
    }

    /// Hidden while searching so row indices map cleanly onto the filtered arrays.
    private var showsAddRow: Bool { !isFiltering && selectedCategory == .yours }

    /// Row count straight from the model. Never call `tableView.numberOfRows(inSection:)` from a data
    /// source or delegate callback: it calls back into the delegate and recurses until SIGSEGV.
    private func rowCount(inSection section: Int) -> Int {
        if section == 0 { return yours.count + (showsAddRow ? 1 : 0) }
        return builtin.count
    }

    /// The rows on screen, in index-path order: tells a content edit (refresh in place) from a
    /// structural change (reload).
    private var renderedIdentities: [[ShortcutRowIdentity]] = []

    /// Set when the table needs resyncing but a row may be first responder. Cleared by `reload()`.
    private var pendingReload = false

    /// The snippet the add row created before a deferred reload caught up (the cell is still
    /// `.addRow`). Without it the next blur would create a second snippet or trip the duplicate
    /// check. Cleared by `reload()`.
    private var pendingAddRowId: String?

    /// Coalesces the recompose-and-push behind `onSnippetsChange`, since the chip menu invites rapid
    /// toggles. The store write and `invalidate()` stay synchronous.
    private var pendingPush: DispatchWorkItem?
    private static let pushCoalesceInterval: TimeInterval = 0.25

    private var isFiltering: Bool { !query.isEmpty }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .chalkChromeBackground

        searchBar.placeholder = "Search shortcuts"
        searchBar.delegate = self
        searchBar.searchBarStyle = .minimal
        searchBar.autocapitalizationType = .none
        searchBar.autocorrectionType = .no
        searchBar.tintColor = .chalkAccent
        searchBar.searchTextField.backgroundColor = .chalkCardBackground
        searchBar.searchTextField.textColor = .chalkTextBody
        searchBar.searchTextField.focusEffect = nil

        // Asymmetric insets: a minimal UISearchBar pads its field ~8pt on the left only, so 12+8 left
        // and 20 right align both edges with the grouped cards' 20pt margins.
        let headerHeight = ChalkMetrics.s(48)
        let searchHeader = UIView(frame: CGRect(x: 0, y: 0, width: 320, height: headerHeight))
        searchBar.frame = CGRect(
            x: ChalkMetrics.s(12), y: ChalkMetrics.s(10),
            width: searchHeader.bounds.width - ChalkMetrics.s(32),
            height: headerHeight - ChalkMetrics.s(12))
        searchBar.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        searchHeader.addSubview(searchBar)

        tableView.dataSource = self
        tableView.delegate = self
        tableView.register(ShortcutRowCell.self,
                           forCellReuseIdentifier: ShortcutRowCell.reuseIdentifier)
        tableView.register(
            ShortcutColumnsHeaderView.self,
            forHeaderFooterViewReuseIdentifier: ShortcutColumnsHeaderView.reuseIdentifier)
        // Section 0's header has two lines and section 1's one, so headers self-size.
        tableView.sectionHeaderHeight = UITableView.automaticDimension
        tableView.estimatedSectionHeaderHeight = ChalkMetrics.s(34)
        tableView.backgroundColor = .chalkChromeBackground
        tableView.separatorColor = .chalkCardSeparator
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = ChalkMetrics.s(38)
        tableView.contentInset = UIEdgeInsets(
            top: 0, left: 0, bottom: ChalkMetrics.s(16), right: 0)
        tableView.tableHeaderView = searchHeader
        tableView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(tableView)
        NSLayoutConstraint.activate([
            tableView.topAnchor.constraint(equalTo: view.topAnchor),
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        reload()
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
            category: isFiltering ? nil : selectedCategory
        )
        yours = sections.yours
        builtin = sections.builtin

        // Same rows in the same order: refresh cells in place. `reloadData()` may rebind the cell an
        // open chip menu is anchored to. Structural changes take the full reload.
        let identities = displayedIdentities()
        if identities == renderedIdentities, refreshVisibleCells() {
            // Re-measure row heights without handing cells back out.
            UIView.performWithoutAnimation { tableView.performBatchUpdates(nil) }
            return
        }
        renderedIdentities = identities
        tableView.reloadData()
    }

    private func displayedIdentities() -> [[ShortcutRowIdentity]] {
        var own = yours.map(\.identity)
        if showsAddRow { own.append(.addRow) }
        return [own, builtin.map(\.identity)]
    }

    /// Reconfigures visible cells from the model. False when a cell shows a different row than the
    /// model expects, which needs a full reload.
    private func refreshVisibleCells() -> Bool {
        for indexPath in tableView.indexPathsForVisibleRows ?? [] {
            guard let cell = tableView.cellForRow(at: indexPath) as? ShortcutRowCell
            else { continue }
            guard cell.identity == identity(at: indexPath) else { return false }
            configure(cell, at: indexPath)
        }
        return true
    }

    /// Every mutation ends here. `invalidate()` is immediate so a new tab never gets the stale cache;
    /// only the push is coalesced.
    private func changed() {
        library.invalidate()
        pendingPush?.cancel()
        let push = DispatchWorkItem { [weak self] in
            self?.pendingPush = nil
            self?.onSnippetsChange?()
        }
        pendingPush = push
        DispatchQueue.main.asyncAfter(
            deadline: .now() + Self.pushCoalesceInterval, execute: push)
    }

    /// Fires a coalesced push now. Leaving the screen must not outrun it.
    private func flushPendingPush() {
        guard let push = pendingPush else { return }
        push.cancel()
        pendingPush = nil
        onSnippetsChange?()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        flushPendingPush()
    }

    deinit {
        // The work item holds a weak self and dies with us, but the editors still need the push.
        guard pendingPush != nil else { return }
        pendingPush?.cancel()
        onSnippetsChange?()
    }

    /// True while some row's field is first responder. Reloading mid-edit can detach the cell being
    /// typed into, so reloads that could race an edit go through `requestReload()`.
    private func isAnyRowBeingEdited() -> Bool {
        tableView.visibleCells.contains { ($0 as? ShortcutRowCell)?.isEditingAnyField == true }
    }

    /// Marks the table dirty and reloads as soon as nothing is mid-edit.
    private func requestReload() {
        pendingReload = true
        scheduleReloadFlush()
    }

    /// Retries a deferred reload on the next runloop turn, once a same-row focus handoff has landed.
    /// If something is still being edited the flag stays set, so every delegate callback must call
    /// this, even ones that save nothing, or the flag strands and a forked row reads as built-in.
    private func scheduleReloadFlush() {
        DispatchQueue.main.async { [weak self] in
            self?.flushReloadIfIdle()
        }
    }

    private func flushReloadIfIdle() {
        guard pendingReload, !isAnyRowBeingEdited() else { return }
        reload()
    }

    private func row(at indexPath: IndexPath) -> ShortcutRow? {
        if indexPath.section == 0 {
            return indexPath.row < yours.count ? yours[indexPath.row] : nil // nil = add row
        }
        guard indexPath.row < builtin.count else { return nil }
        return builtin[indexPath.row]
    }

    private func identity(at indexPath: IndexPath) -> ShortcutRowIdentity {
        row(at: indexPath)?.identity ?? .addRow
    }

    /// The row a callback's identity names; nil for the add row or a row deleted since.
    private func row(for identity: ShortcutRowIdentity) -> ShortcutRow? {
        ShortcutTableModel.row(identity, yours: yours, builtin: builtin)
    }

    /// The stored fork of a built-in. The row model can lag the store while a reload is deferred, so
    /// the store decides whether a built-in is forked.
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

    /// Reports a rejected edit. Pass `cell` when raised from its chip menu: an alert presented while
    /// the menu is up silently does nothing.
    private func showError(_ message: String, from cell: ShortcutRowCell? = nil) {
        cell?.dismissOptionsMenu()
        let alert = UIAlertController.chalkNotice(title: nil, message: message)
        guard let blocker = presentationBlocker() else {
            DispatchQueue.main.async { [weak self] in self?.present(alert, animated: true) }
            return
        }
        blocker.dismiss(animated: true) { [weak self] in
            self?.present(alert, animated: true)
        }
    }

    /// Whatever is presented from this controller's parent chain, where UIKit refuses a second
    /// presentation. Walks parents, since Settings itself being presented is not in the way.
    private func presentationBlocker() -> UIViewController? {
        var node: UIViewController? = self
        while let current = node {
            if let presented = current.presentedViewController { return presented }
            node = current.parent
        }
        return nil
    }
}

// MARK: - Data source

extension ShortcutsSettingsViewController: UITableViewDataSource {
    func numberOfSections(in tableView: UITableView) -> Int { 2 }

    /// Section titles, shown by `ShortcutColumnsHeaderView` in both sections.
    fileprivate func headerTitle(for section: Int) -> String {
        if section == 0 { return "Your Shortcuts" }
        return isFiltering
            ? "Built-in (\(builtin.count))"
            : "\(selectedCategory.title) (\(builtin.count))"
    }

    func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        guard section == (rowCount(inSection: 0) > 0 ? 0 : 1) else { return nil }
        return "Type in the last row to add a shortcut. Editing a built-in makes it "
            + "yours; swipe to reset. Use $1, $2 for placeholders, $0 for the final "
            + "cursor position, and #1, #2 for regex captures."
    }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        rowCount(inSection: section)
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(
            withIdentifier: ShortcutRowCell.reuseIdentifier, for: indexPath) as! ShortcutRowCell
        cell.delegate = self
        configure(cell, at: indexPath)
        return cell
    }

    fileprivate func configure(_ cell: ShortcutRowCell, at indexPath: IndexPath) {
        guard let row = row(at: indexPath) else {
            cell.configure(
                identity: .addRow, trigger: "", replacement: "",
                options: SnippetOptions(), isEnabled: true, isModified: false)
            return
        }
        cell.configure(
            identity: row.identity,
            trigger: row.trigger,
            replacement: row.replacement,
            options: row.options,
            isEnabled: row.isEnabled,
            isModified: row.isModified
        )
    }
}

// MARK: - Delegate

extension ShortcutsSettingsViewController: UITableViewDelegate {
    func tableView(_ tableView: UITableView, heightForHeaderInSection section: Int) -> CGFloat {
        // An empty section must not leave a floating title behind.
        rowCount(inSection: section) == 0
            ? .leastNormalMagnitude
            : UITableView.automaticDimension
    }

    func tableView(_ tableView: UITableView, viewForHeaderInSection section: Int) -> UIView? {
        guard rowCount(inSection: section) > 0 else { return nil }
        let header = tableView.dequeueReusableHeaderFooterView(
            withIdentifier: ShortcutColumnsHeaderView.reuseIdentifier)
            as? ShortcutColumnsHeaderView
        header?.configure(title: headerTitle(for: section), showsColumns: section == 0)
        return header
    }

    func tableView(_ tableView: UITableView, willDisplayFooterView view: UIView, forSection section: Int) {
        guard let footer = view as? UITableViewHeaderFooterView else { return }
        footer.textLabel?.textColor = .chalkTextFaint
        footer.textLabel?.font = .systemFont(ofSize: ChalkMetrics.s(11))
    }

    func tableView(
        _ tableView: UITableView,
        trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath
    ) -> UISwipeActionsConfiguration? {
        guard let row = row(at: indexPath) else { return nil }
        // Both remove the stored snippet; on a fork that brings the built-in back, hence "Reset".
        let snippet: UserSnippet
        let title: String
        switch row.source {
        case .user(let user):
            snippet = user
            title = "Delete"
        case .fork(_, let fork):
            snippet = fork
            title = "Reset"
        case .builtin:
            return nil
        }
        let remove = UIContextualAction(style: .destructive, title: title) {
            [weak self] _, _, completion in
            guard let self else { return completion(false) }
            self.library.store.remove(id: snippet.id)
            self.changed()
            self.requestReload()
            completion(true)
        }
        return UISwipeActionsConfiguration(actions: [remove])
    }
}

// MARK: - Row editing

extension ShortcutsSettingsViewController: ShortcutRowCellDelegate {
    func rowCell(
        _ cell: ShortcutRowCell,
        didEdit identity: ShortcutRowIdentity,
        trigger: String,
        replacement: String
    ) {
        // Flush a deferred reload on every path, including those that save nothing.
        defer { scheduleReloadFlush() }

        guard let target = row(for: identity) else {
            guard identity == .addRow else { return }
            // The add row already created its snippet; edit it rather than creating a second.
            if let stored = pendingAddRowSnippet() {
                var snippet = stored
                guard snippet.trigger != trigger || snippet.replacement != replacement
                else { return }
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
                return requestReload() // revert the rejected text once editing settles
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
            return requestReload() // revert the rejected text once editing settles
        }
        save(snippet)
    }

    func rowCell(
        _ cell: ShortcutRowCell,
        identity: ShortcutRowIdentity,
        didChange options: SnippetOptions
    ) {
        defer { scheduleReloadFlush() }
        guard let target = row(for: identity) else { return }
        var snippet = editableSnippet(for: target)
        snippet.options = options
        if let error = validate(snippet) {
            showError(error, from: cell)
            return requestReload() // revert the rejected options once editing settles
        }
        save(snippet)
    }

    func rowCell(
        _ cell: ShortcutRowCell,
        identity: ShortcutRowIdentity,
        didSetEnabled isEnabled: Bool
    ) {
        defer { scheduleReloadFlush() }
        guard let target = row(for: identity) else { return }
        // An unforked built-in uses the store's disable set, everything else its `enabled` flag. Ask
        // the store, not the row, which can still say `.builtin` while a reload is pending.
        if case .builtin(let source) = target.source,
           storedFork(ofBuiltinKey: source.key) == nil {
            library.store.setBuiltinDisabled(key: source.key, disabled: !isEnabled)
            changed()
            return requestReload()
        }
        var snippet = editableSnippet(for: target)
        snippet.enabled = isEnabled
        save(snippet)
    }

    func rowCellDidChangeHeight(_ cell: ShortcutRowCell) {
        // Re-measure without reloading: reloading would drop first responder.
        UIView.performWithoutAnimation {
            tableView.performBatchUpdates(nil)
        }
    }

    private func validate(_ snippet: UserSnippet) -> String? {
        if let error = SnippetComposer.validateTrigger(
            snippet.trigger, isRegex: snippet.options.isRegex) { return error }
        if let error = SnippetComposer.validateReplacement(snippet.replacement) { return error }
        let duplicate = library.store.snippets().contains {
            $0.trigger == snippet.trigger && $0.id != snippet.id
        }
        return duplicate ? "You already have a shortcut with this trigger." : nil
    }
}

// MARK: - Search

extension ShortcutsSettingsViewController: UISearchBarDelegate {
    func searchBar(_ searchBar: UISearchBar, textDidChange searchText: String) {
        query = searchText.trimmingCharacters(in: .whitespaces)
    }

    func searchBarSearchButtonClicked(_ searchBar: UISearchBar) {
        searchBar.resignFirstResponder()
    }
}
