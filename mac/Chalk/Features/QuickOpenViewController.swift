import UIKit
import ChalkKit

/// The ⌘O Quick Open palette: fuzzy-filter every file across all Locations, open on select. The
/// match key is "parentFolder/fileName" so queries like "notes ideas" rank the right file.
/// Reports its natural height so the host's card hugs the results.
final class QuickOpenViewController: UIViewController {
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

    private let searchField = UITextField()
    private let tableView = UITableView(frame: .zero, style: .plain)
    private let resultCountLabel = UILabel()

    private static let inputRowHeight: CGFloat = ChalkMetrics.s(48)
    private static let footerHeight: CGFloat = ChalkMetrics.s(33)
    private static let resultRowHeight: CGFloat = ChalkMetrics.s(46)
    private static let resultsPadding: CGFloat = ChalkMetrics.s(8)

    private var selectedIndex = 0

    init() {
        super.init(nibName: nil, bundle: nil)
    }

    /// Feed the asynchronously enumerated file index. The palette presents first and fills in.
    func setFiles(_ files: [FileNode]) {
        self.indexed = files.map { ($0, Self.key($0)) }
        applyQuery(searchField.text ?? "")
    }

    private func applyQuery(_ query: String) {
        appliedQuery = query
        // A blank query yields the first 50 files in index order.
        results = FuzzyMatcher.filter(query: query, items: indexed, key: { $0.key }, limit: 50)
            .map(\.node)
        selectedIndex = 0
        if isViewLoaded {
            tableView.reloadData()
            select(0)
            resultCountLabel.text = results.count == 1 ? "1 result" : "\(results.count) results"
            reportContentHeight()
        }
    }

    private func reportContentHeight() {
        let rows = CGFloat(min(max(results.count, 1), 8))
        let height = Self.inputRowHeight + 1
            + Self.resultsPadding * 2 + rows * Self.resultRowHeight
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
        let openNewTab = UIKeyCommand(input: "\r", modifierFlags: .command,
                                       action: #selector(openSelectedInNewTab))
        return [up, down, esc, openNewTab]
    }

    @objc private func moveUp() { select(max(0, selectedIndex - 1)) }
    @objc private func moveDown() { select(min(results.count - 1, selectedIndex + 1)) }
    @objc private func cancelPalette() {
        onClose? { [weak self] in self?.onDismiss?() }
    }

    private func select(_ index: Int) {
        guard results.indices.contains(index) else { return }
        selectedIndex = index
        tableView.selectRow(at: IndexPath(row: index, section: 0), animated: false,
                             scrollPosition: .none)
        tableView.scrollToRow(at: IndexPath(row: index, section: 0), at: .none, animated: false)
    }

    private func openSelected(inNewTab: Bool = false) {
        guard results.indices.contains(selectedIndex) else { return }
        let url = results[selectedIndex].url
        onClose? { [weak self] in
            self?.onOpen?(url, inNewTab)
            self?.onDismiss?()
        }
    }

    @objc private func openSelectedInNewTab() { openSelected(inNewTab: true) }

    /// Reset before a reused instance is re-presented. The last file index is kept so the palette
    /// never flashes empty; the async enumeration refreshes it.
    func prepareForReuse() {
        loadViewIfNeeded()
        searchField.text = ""
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

        let magnifier = UIImageView(image: UIImage(
            systemName: "magnifyingglass",
            withConfiguration: UIImage.SymbolConfiguration(pointSize: ChalkMetrics.s(14), weight: .regular)))
        magnifier.tintColor = .chalkChromeFgTertiary
        // Only the text field may flex, or the solver stretches the image view across the row.
        magnifier.setContentHuggingPriority(.required, for: .horizontal)
        searchField.setContentHuggingPriority(UILayoutPriority(1), for: .horizontal)
        searchField.setContentCompressionResistancePriority(.required, for: .horizontal)
        magnifier.translatesAutoresizingMaskIntoConstraints = false

        searchField.font = .systemFont(ofSize: ChalkMetrics.paletteSearchFontSize)
        searchField.textColor = .chalkChromeFg
        searchField.tintColor = .chalkAccent // caret
        searchField.attributedPlaceholder = NSAttributedString(
            string: "Open file…",
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

        inputRow.addSubview(magnifier)
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
        tableView.rowHeight = Self.resultRowHeight
        tableView.contentInset = UIEdgeInsets(
            top: Self.resultsPadding, left: 0, bottom: Self.resultsPadding, right: 0)
        tableView.register(PaletteResultCell.self, forCellReuseIdentifier: "cell")
        tableView.translatesAutoresizingMaskIntoConstraints = false

        let footer = UIView()
        footer.translatesAutoresizingMaskIntoConstraints = false
        let footerHairline = UIView()
        footerHairline.backgroundColor = .chalkPaletteDivider
        footerHairline.translatesAutoresizingMaskIntoConstraints = false
        footer.addSubview(footerHairline)

        let hints = UILabel()
        hints.font = .systemFont(ofSize: ChalkMetrics.paletteHintFontSize)
        hints.textColor = .chalkChromeFgQuaternary
        hints.text = "↑↓ navigate    return open    ⌘ return new tab"
        hints.translatesAutoresizingMaskIntoConstraints = false
        footer.addSubview(hints)

        resultCountLabel.font = .systemFont(ofSize: ChalkMetrics.paletteHintFontSize)
        resultCountLabel.textColor = .chalkChromeFgQuaternary
        resultCountLabel.textAlignment = .right
        resultCountLabel.translatesAutoresizingMaskIntoConstraints = false
        footer.addSubview(resultCountLabel)

        view.addSubview(inputRow)
        view.addSubview(divider)
        view.addSubview(tableView)
        view.addSubview(footer)
        NSLayoutConstraint.activate([
            inputRow.topAnchor.constraint(equalTo: view.topAnchor),
            inputRow.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            inputRow.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            inputRow.heightAnchor.constraint(equalToConstant: Self.inputRowHeight),

            magnifier.leadingAnchor.constraint(equalTo: inputRow.leadingAnchor, constant: ChalkMetrics.s(16)),
            magnifier.centerYAnchor.constraint(equalTo: inputRow.centerYAnchor),
            searchField.leadingAnchor.constraint(equalTo: magnifier.trailingAnchor, constant: ChalkMetrics.s(10)),
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
            resultCountLabel.leadingAnchor.constraint(
                greaterThanOrEqualTo: hints.trailingAnchor, constant: ChalkMetrics.s(14)),
            resultCountLabel.trailingAnchor.constraint(equalTo: footer.trailingAnchor, constant: -ChalkMetrics.s(16)),
            resultCountLabel.centerYAnchor.constraint(equalTo: footer.centerYAnchor),
        ])
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
        // The editor webview holds the keyboard, and an immediate becomeFirstResponder can lose to
        // it, leaking keystrokes into the document. End editing first, then retry until we win.
        revealGeneration += 1
        view.window?.endEditing(true)
        grabFocus(retries: 5, generation: revealGeneration)
    }

    /// Bumped on every reveal; a grabFocus retry from an older reveal bails.
    private var revealGeneration = 0

    /// A retry must never hand first responder to a hidden field, which would swallow the editor's
    /// keystrokes. The host's hide tells this palette nothing, so the overlay is read directly.
    private func grabFocus(retries: Int, generation: Int) {
        guard generation == revealGeneration, isOverlayShowing else { return }
        if searchField.becomeFirstResponder() { return }
        guard retries > 0 else { return }
        DispatchQueue.main.async { [weak self] in
            self?.grabFocus(retries: retries - 1, generation: generation)
        }
    }

    /// False from the moment the host starts hiding the overlay: its fade-out sets the model alpha
    /// to 0 at once, and under Reduce Motion it hides the backdrop outright.
    private var isOverlayShowing: Bool {
        guard view.window != nil else { return false }
        var current: UIView? = view
        while let candidate = current {
            if candidate.isHidden || candidate.alpha == 0 { return false }
            current = candidate.superview
        }
        return true
    }

    private static func key(_ node: FileNode) -> String {
        let parent = node.url.deletingLastPathComponent().lastPathComponent
        return "\(parent)/\(node.name)"
    }

    @objc private func textChanged() {
        // Debounce: the fuzzy filter scans every file on the main thread. Clearing applies at once.
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
    /// Force a query without the debounce. Works before or after `setFiles`, which re-runs it.
    func setQueryForAudit(_ query: String) {
        loadViewIfNeeded()
        searchField.text = query
        applyQuery(query)
    }
    #endif
}

extension QuickOpenViewController: UITextFieldDelegate {
    // Enter in the search field confirms the keyboard-highlighted row.
    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        openSelected()
        return false
    }
}

extension QuickOpenViewController: UITableViewDataSource, UITableViewDelegate {
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        results.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(
            withIdentifier: "cell", for: indexPath) as! PaletteResultCell
        let node = results[indexPath.row]
        cell.configure(name: node.name, path: Self.key(node), query: appliedQuery)
        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        let url = results[indexPath.row].url
        onClose? { [weak self] in
            self?.onOpen?(url, false)
            self?.onDismiss?()
        }
    }
}

/// One result row: doc icon, name, muted path below, and a "return" key badge when selected.
private final class PaletteResultCell: UITableViewCell {
    private let icon = UIImageView()
    private let nameLabel = UILabel()
    private let pathLabel = UILabel()
    private let returnBadge = UILabel()

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        backgroundColor = .clear
        registerForTraitChanges(UITraitCollection.chalkColorTraits) { (cell: Self, _: UITraitCollection) in
            cell.refreshBadgeEdge()
        }

        let selected = UIView()
        selected.backgroundColor = .chalkAccentSelection
        selected.layer.cornerRadius = ChalkMetrics.paletteRowRadius
        selected.layer.cornerCurve = .continuous
        selectedBackgroundView = selected

        icon.image = UIImage(
            systemName: "doc.text",
            withConfiguration: UIImage.SymbolConfiguration(pointSize: ChalkMetrics.s(13), weight: .regular))
        icon.tintColor = .chalkChromeFgTertiary
        icon.translatesAutoresizingMaskIntoConstraints = false

        nameLabel.font = .systemFont(ofSize: ChalkMetrics.paletteResultFontSize)
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        pathLabel.font = .systemFont(ofSize: ChalkMetrics.paletteResultPathFontSize)
        pathLabel.textColor = .chalkChromeFgQuaternary
        // Middle-truncate: a tail ellipsis would drop the file name at the end of "parent/name".
        pathLabel.lineBreakMode = .byTruncatingMiddle
        pathLabel.translatesAutoresizingMaskIntoConstraints = false

        returnBadge.text = "return"
        returnBadge.font = .systemFont(ofSize: ChalkMetrics.s(10.5))
        returnBadge.textColor = .chalkChromeFgSecondary
        returnBadge.textAlignment = .center
        returnBadge.layer.borderWidth = 0.5
        returnBadge.layer.cornerRadius = ChalkMetrics.s(5)
        returnBadge.isHidden = true
        returnBadge.translatesAutoresizingMaskIntoConstraints = false

        contentView.addSubview(icon)
        contentView.addSubview(nameLabel)
        contentView.addSubview(pathLabel)
        contentView.addSubview(returnBadge)
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: ChalkMetrics.s(10)),
            icon.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: ChalkMetrics.s(16)),

            nameLabel.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: ChalkMetrics.s(11)),
            nameLabel.trailingAnchor.constraint(
                lessThanOrEqualTo: returnBadge.leadingAnchor, constant: -10),
            nameLabel.topAnchor.constraint(equalTo: contentView.topAnchor, constant: ChalkMetrics.s(6)),

            pathLabel.leadingAnchor.constraint(equalTo: nameLabel.leadingAnchor),
            pathLabel.trailingAnchor.constraint(
                lessThanOrEqualTo: returnBadge.leadingAnchor, constant: -10),
            pathLabel.topAnchor.constraint(equalTo: nameLabel.bottomAnchor, constant: 1),

            returnBadge.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -ChalkMetrics.s(10)),
            returnBadge.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            returnBadge.widthAnchor.constraint(equalToConstant: ChalkMetrics.s(42)),
            returnBadge.heightAnchor.constraint(equalToConstant: ChalkMetrics.s(20)),
        ])
        refreshBadgeEdge()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func configure(name: String, path: String, query: String) {
        // Accent highlight on a filename prefix match.
        let attributed = NSMutableAttributedString(
            string: name, attributes: [.foregroundColor: UIColor.chalkChromeFg])
        if !query.isEmpty, name.lowercased().hasPrefix(query.lowercased()),
           let range = name.range(of: name.prefix(query.count)) {
            attributed.addAttributes([
                .foregroundColor: UIColor.chalkAccent,
                .font: UIFont.systemFont(
                    ofSize: ChalkMetrics.paletteResultFontSize, weight: .semibold),
            ], range: NSRange(range, in: name))
        }
        nameLabel.attributedText = attributed
        pathLabel.text = path
    }

    override func setSelected(_ selected: Bool, animated: Bool) {
        super.setSelected(selected, animated: animated)
        returnBadge.isHidden = !selected
    }

    private func refreshBadgeEdge() {
        returnBadge.layer.borderColor = UIColor.chalkKeyBadgeEdge
            .resolvedColor(with: traitCollection).cgColor
    }

    // The table is already inset from the card, so the pill spans the row minus a hair.
    override func layoutSubviews() {
        super.layoutSubviews()
        selectedBackgroundView?.frame = bounds.insetBy(dx: 0, dy: 1)
    }
}
