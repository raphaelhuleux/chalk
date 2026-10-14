import UIKit
import ChalkKit
import os

/// Focus-grab breadcrumbs. See docs/issues/2026-08-17-fullscreen-drops-when-outline-opens.md.
private let outlineFocusLog = Logger(subsystem: "com.huleux.chalk", category: "outline")

/// The ⌘P outline palette: headings, numbered callouts and figures, fuzzy-filterable, jump on
/// select. Mirrors QuickOpenViewController; selection and indent rules live in
/// `OutlinePalettePolicy`. Reports its natural height so the host's card hugs the list.
final class OutlinePaletteViewController: UIViewController {
    /// Jump to a 1-based line. Fired through `onClose`, so the overlay is gone before the editor
    /// takes focus back.
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

    private let searchField = UITextField()
    private let tableView = UITableView(frame: .zero, style: .plain)
    private let itemCountLabel = UILabel()
    private let emptyLabel = UILabel()

    private static let inputRowHeight: CGFloat = ChalkMetrics.s(48)
    private static let footerHeight: CGFloat = ChalkMetrics.s(33)
    private static let rowHeight: CGFloat = ChalkMetrics.outlineRowHeight
    private static let resultsPadding: CGFloat = ChalkMetrics.s(8)
    private static let maxVisibleRows = 10

    private var selectedIndex = 0

    init() {
        super.init(nibName: nil, bundle: nil)
    }

    /// Feed a snapshot fetched at open. With no query the cursor's section is preselected, so the
    /// palette opens where you are.
    func setSnapshot(_ snapshot: OutlineSnapshot) {
        items = snapshot.items
        cursorLine = snapshot.cursorLine
        indents = OutlinePalettePolicy.indentLevels(for: items)
        applyQuery(searchField.text ?? "")
    }

    private func applyQuery(_ query: String) {
        appliedQuery = query
        if query.isEmpty {
            results = items
            selectedIndex = OutlinePalettePolicy.preselectedIndex(
                items: items, cursorLine: cursorLine)
        } else {
            results = OutlinePalettePolicy.filter(query: query, items: items)
            selectedIndex = 0
        }
        if isViewLoaded {
            tableView.reloadData()
            select(selectedIndex, scrollPosition: query.isEmpty ? .middle : .none)
            emptyLabel.text = items.isEmpty ? "No outline in this document" : "No matches"
            emptyLabel.isHidden = !results.isEmpty
            itemCountLabel.text = results.count == 1 ? "1 item" : "\(results.count) items"
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
        let height = Self.inputRowHeight + 1
            + Self.resultsPadding * 2 + body
            + Self.footerHeight
        onContentHeightChanged?(height)
    }

    override var canBecomeFirstResponder: Bool { true }

    override var keyCommands: [UIKeyCommand]? {
        let up = UIKeyCommand(input: UIKeyCommand.inputUpArrow, modifierFlags: [],
                              action: #selector(moveUp))
        let down = UIKeyCommand(input: UIKeyCommand.inputDownArrow, modifierFlags: [],
                                action: #selector(moveDown))
        // Beat the search field's own caret-move and Escape handling.
        up.wantsPriorityOverSystemBehavior = true
        down.wantsPriorityOverSystemBehavior = true
        let esc = UIKeyCommand(input: UIKeyCommand.inputEscape, modifierFlags: [],
                               action: #selector(cancelPalette))
        esc.wantsPriorityOverSystemBehavior = true
        return [up, down, esc]
    }

    @objc private func moveUp() { select(max(0, selectedIndex - 1)) }
    @objc private func moveDown() { select(min(results.count - 1, selectedIndex + 1)) }
    @objc private func cancelPalette() {
        onClose? { [weak self] in self?.onDismiss?() }
    }

    private func select(_ index: Int, scrollPosition: UITableView.ScrollPosition = .none) {
        guard results.indices.contains(index) else { return }
        selectedIndex = index
        let path = IndexPath(row: index, section: 0)
        tableView.selectRow(at: path, animated: false, scrollPosition: .none)
        tableView.scrollToRow(at: path, at: scrollPosition, animated: false)
    }

    private func jumpToSelected() {
        guard results.indices.contains(selectedIndex) else { return }
        let line = results[selectedIndex].line
        onClose? { [weak self] in
            self?.onJump?(line)
            self?.onDismiss?()
        }
    }

    /// Reset before a reused instance is re-presented. The outline is per-document, so it is
    /// dropped to keep a stale structure from flashing before the host's fetch lands.
    func prepareForReuse() {
        loadViewIfNeeded()
        searchField.text = ""
        items = []
        indents = []
        cursorLine = 1
        applyQuery("")
    }

    #if DEBUG
    /// Set right before presenting, to measure command-to-visible latency. 0 = unset.
    var openCommandTime: CFTimeInterval = 0
    #endif

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear // the glass card behind provides the fill

        let inputRow = UIView()
        inputRow.translatesAutoresizingMaskIntoConstraints = false

        let glyph = UIImageView(image: UIImage(
            systemName: "list.bullet.indent",
            withConfiguration: UIImage.SymbolConfiguration(
                pointSize: ChalkMetrics.s(14), weight: .regular)))
        glyph.tintColor = .chalkChromeFgTertiary
        // Only the text field may flex, or the solver stretches the image view across the row.
        glyph.setContentHuggingPriority(.required, for: .horizontal)
        searchField.setContentHuggingPriority(UILayoutPriority(1), for: .horizontal)
        searchField.setContentCompressionResistancePriority(.required, for: .horizontal)
        glyph.translatesAutoresizingMaskIntoConstraints = false

        searchField.font = .systemFont(ofSize: ChalkMetrics.paletteSearchFontSize)
        searchField.textColor = .chalkChromeFg
        searchField.tintColor = .chalkAccent // caret
        searchField.attributedPlaceholder = NSAttributedString(
            string: "Go to section…",
            attributes: [.foregroundColor: UIColor.chalkChromeFgQuaternary])
        searchField.autocapitalizationType = .none
        searchField.autocorrectionType = .no
        searchField.spellCheckingType = .no
        searchField.returnKeyType = .go
        // No Catalyst focus ring: the accent caret is the only focus cue.
        searchField.focusEffect = nil
        searchField.delegate = self
        searchField.addTarget(self, action: #selector(textChanged), for: .editingChanged)
        searchField.translatesAutoresizingMaskIntoConstraints = false

        // The esc badge is also a click target.
        let escBadge = UIButton(type: .system)
        var escConfig = UIButton.Configuration.plain()
        escConfig.attributedTitle = AttributedString(
            "esc", attributes: AttributeContainer([
                .font: UIFont.systemFont(ofSize: ChalkMetrics.s(10.5)),
                .foregroundColor: UIColor.chalkChromeFgQuaternary,
            ]))
        escConfig.contentInsets = NSDirectionalEdgeInsets(top: 2, leading: 6, bottom: 2, trailing: 6)
        escBadge.configuration = escConfig
        escBadge.layer.borderWidth = 0.5
        escBadge.layer.borderColor = UIColor.chalkKeyBadgeEdge
            .resolvedColor(with: traitCollection).cgColor
        // A layer colour does not follow a dynamic colour: re-resolve on appearance and theme flips.
        escBadge.registerForTraitChanges(UITraitCollection.chalkColorTraits) {
            (badge: UIButton, _: UITraitCollection) in
            badge.layer.borderColor = UIColor.chalkKeyBadgeEdge
                .resolvedColor(with: badge.traitCollection).cgColor
        }
        escBadge.layer.cornerRadius = ChalkMetrics.s(5)
        escBadge.accessibilityLabel = "Close"
        escBadge.addAction(UIAction { [weak self] _ in self?.cancelPalette() }, for: .touchUpInside)
        escBadge.translatesAutoresizingMaskIntoConstraints = false

        inputRow.addSubview(glyph)
        inputRow.addSubview(searchField)
        inputRow.addSubview(escBadge)

        let divider = UIView()
        divider.backgroundColor = .chalkPaletteDivider
        divider.translatesAutoresizingMaskIntoConstraints = false

        tableView.dataSource = self
        tableView.delegate = self
        tableView.keyboardDismissMode = .onDrag
        tableView.backgroundColor = .clear
        tableView.separatorStyle = .none
        tableView.rowHeight = Self.rowHeight
        tableView.contentInset = UIEdgeInsets(
            top: Self.resultsPadding, left: 0, bottom: Self.resultsPadding, right: 0)
        tableView.register(OutlineRowCell.self, forCellReuseIdentifier: "cell")
        tableView.translatesAutoresizingMaskIntoConstraints = false

        emptyLabel.font = .systemFont(ofSize: ChalkMetrics.outlineRowFontSize)
        emptyLabel.textColor = .chalkChromeFgQuaternary
        emptyLabel.textAlignment = .center
        emptyLabel.isHidden = true
        let emptyWrap = UIView()
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        emptyWrap.addSubview(emptyLabel)
        NSLayoutConstraint.activate([
            emptyLabel.centerXAnchor.constraint(equalTo: emptyWrap.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: emptyWrap.centerYAnchor),
        ])
        tableView.backgroundView = emptyWrap

        let footer = UIView()
        footer.translatesAutoresizingMaskIntoConstraints = false
        let footerHairline = UIView()
        footerHairline.backgroundColor = .chalkPaletteDivider
        footerHairline.translatesAutoresizingMaskIntoConstraints = false
        footer.addSubview(footerHairline)

        let hints = UILabel()
        hints.font = .systemFont(ofSize: ChalkMetrics.paletteHintFontSize)
        hints.textColor = .chalkChromeFgQuaternary
        hints.text = "↑↓ navigate    return jump"
        hints.translatesAutoresizingMaskIntoConstraints = false
        footer.addSubview(hints)

        itemCountLabel.font = .systemFont(ofSize: ChalkMetrics.paletteHintFontSize)
        itemCountLabel.textColor = .chalkChromeFgQuaternary
        itemCountLabel.textAlignment = .right
        itemCountLabel.translatesAutoresizingMaskIntoConstraints = false
        footer.addSubview(itemCountLabel)

        view.addSubview(inputRow)
        view.addSubview(divider)
        view.addSubview(tableView)
        view.addSubview(footer)
        NSLayoutConstraint.activate([
            inputRow.topAnchor.constraint(equalTo: view.topAnchor),
            inputRow.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            inputRow.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            inputRow.heightAnchor.constraint(equalToConstant: Self.inputRowHeight),

            glyph.leadingAnchor.constraint(equalTo: inputRow.leadingAnchor, constant: ChalkMetrics.s(16)),
            glyph.centerYAnchor.constraint(equalTo: inputRow.centerYAnchor),
            searchField.leadingAnchor.constraint(equalTo: glyph.trailingAnchor, constant: ChalkMetrics.s(10)),
            searchField.trailingAnchor.constraint(equalTo: escBadge.leadingAnchor, constant: -ChalkMetrics.s(10)),
            searchField.centerYAnchor.constraint(equalTo: inputRow.centerYAnchor),
            escBadge.trailingAnchor.constraint(equalTo: inputRow.trailingAnchor, constant: -ChalkMetrics.s(16)),
            escBadge.centerYAnchor.constraint(equalTo: inputRow.centerYAnchor),

            divider.topAnchor.constraint(equalTo: inputRow.bottomAnchor),
            divider.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: ChalkMetrics.s(12)),
            divider.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -ChalkMetrics.s(12)),
            divider.heightAnchor.constraint(equalToConstant: 0.5),

            tableView.topAnchor.constraint(equalTo: divider.bottomAnchor),
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: ChalkMetrics.s(8)),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -ChalkMetrics.s(8)),
            tableView.bottomAnchor.constraint(equalTo: footer.topAnchor),

            footer.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            footer.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            footer.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            footer.heightAnchor.constraint(equalToConstant: Self.footerHeight),
            footerHairline.topAnchor.constraint(equalTo: footer.topAnchor),
            footerHairline.leadingAnchor.constraint(equalTo: footer.leadingAnchor),
            footerHairline.trailingAnchor.constraint(equalTo: footer.trailingAnchor),
            footerHairline.heightAnchor.constraint(equalToConstant: 0.5),
            hints.leadingAnchor.constraint(equalTo: footer.leadingAnchor, constant: ChalkMetrics.s(16)),
            hints.centerYAnchor.constraint(equalTo: footer.centerYAnchor),
            itemCountLabel.leadingAnchor.constraint(
                greaterThanOrEqualTo: hints.trailingAnchor, constant: ChalkMetrics.s(14)),
            itemCountLabel.trailingAnchor.constraint(equalTo: footer.trailingAnchor, constant: -ChalkMetrics.s(16)),
            itemCountLabel.centerYAnchor.constraint(equalTo: footer.centerYAnchor),
        ])
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
        // The editor webview holds the keyboard, and an immediate becomeFirstResponder can lose to
        // it, leaking keystrokes into the document. End editing first, then retry until we win.
        revealGeneration += 1
        view.window?.endEditing(true)
        grabFocus(retries: 5, generation: revealGeneration)
    }

    /// Called by the host as the overlay hides. Cancels pending grabFocus retries, which would
    /// otherwise hand first responder to the hidden field and swallow the editor's keystrokes.
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
        let won = searchField.becomeFirstResponder()
        outlineFocusLog.info("grabFocus: won=\(won, privacy: .public) retriesLeft=\(retries, privacy: .public)")
        if won { return }
        guard retries > 0 else { return }
        // Spaced retries: the webview's blur round-trips through the web process, so its release
        // can land several runloop turns later.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) { [weak self] in
            self?.grabFocus(retries: retries - 1, generation: generation)
        }
    }

    @objc private func textChanged() {
        // Debounce burst typing; clearing the field applies immediately.
        pendingQuery?.cancel()
        let text = searchField.text ?? ""
        if text.isEmpty {
            applyQuery("")
            return
        }
        let work = DispatchWorkItem { [weak self] in self?.applyQuery(text) }
        pendingQuery = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08, execute: work)
    }

    #if DEBUG
    /// Force a query without the debounce.
    func setQueryForAudit(_ query: String) {
        loadViewIfNeeded()
        searchField.text = query
        applyQuery(query)
    }

    var visibleItemsForTesting: [OutlineItem] { results }
    var selectedIndexForTesting: Int { selectedIndex }
    var isEmptyStateVisibleForTesting: Bool { !emptyLabel.isHidden }
    func confirmSelectedForTesting() { jumpToSelected() }
    /// becomeFirstResponder attempts by grabFocus.
    private(set) var focusAttemptCountForTesting = 0
    #endif
}

extension OutlinePaletteViewController: UITextFieldDelegate {
    // Enter in the search field confirms the keyboard-highlighted row.
    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        jumpToSelected()
        return false
    }
}

extension OutlinePaletteViewController: UITableViewDataSource, UITableViewDelegate {
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        results.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(
            withIdentifier: "cell", for: indexPath) as! OutlineRowCell
        let item = results[indexPath.row]
        // A live query flattens indentation: the hit list is ranked, not hierarchical. With no
        // query `results` is `items`, so the row is also the index into `indents`.
        let indent = appliedQuery.isEmpty && indents.indices.contains(indexPath.row)
            ? indents[indexPath.row] : 0
        cell.configure(item: item, indent: indent, query: appliedQuery)
        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        selectedIndex = indexPath.row
        jumpToSelected()
    }
}
