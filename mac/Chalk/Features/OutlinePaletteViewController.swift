import AppKit
import ChalkKit

/// The ⌘P outline palette: headings, numbered callouts and figures,
/// fuzzy-filterable, jump on select. Selection and indent rules live in
/// `OutlinePalettePolicy`.
final class OutlinePaletteViewController: PaletteListViewController {
    /// Jump to a 1-based line. Fired through `onClose`, so the overlay is gone
    /// before the editor takes focus back.
    var onJump: ((Int) -> Void)?

    private var items: [OutlineItem] = []
    /// Indent steps per item of the unfiltered list; a live query flattens indentation.
    private var indents: [Int] = []
    private var cursorLine = 1
    private var results: [OutlineItem] = []

    private static let rowHeight: CGFloat = ChalkMetrics.outlineRowHeight
    private static let maxVisibleRows = 10

    init() {
        super.init(frame: PaletteFrame(
            glyph: "list.bullet.indent", placeholder: "Go to section\u{2026}",
            hints: "\u{2191}\u{2193} navigate    return jump",
            rowHeight: Self.rowHeight))
    }

    /// Feed a snapshot fetched at open. With no query the cursor's section is
    /// preselected, so the palette opens where you are.
    func setSnapshot(_ snapshot: OutlineSnapshot) {
        items = snapshot.items
        cursorLine = snapshot.cursorLine
        indents = OutlinePalettePolicy.indentLevels(for: items)
        applyQuery(currentQuery)
    }

    override var resultCount: Int { results.count }
    override var resultNoun: String { "item" }
    override var emptyMessage: String? { items.isEmpty ? "No outline in this document" : "No matches" }

    override func computeResults(for query: String) {
        if query.isEmpty {
            results = items
            selectedIndex = OutlinePalettePolicy.preselectedIndex(items: items, cursorLine: cursorLine)
        } else {
            results = OutlinePalettePolicy.filter(query: query, items: items)
            selectedIndex = 0
        }
    }

    override func bodyHeight() -> CGFloat {
        results.isEmpty
            ? ChalkMetrics.outlineEmptyHeight
            : CGFloat(min(results.count, Self.maxVisibleRows)) * Self.rowHeight
    }

    override func confirmation(of index: Int, inNewTab: Bool) -> () -> Void {
        let line = results[index].line
        return { [weak self] in self?.onJump?(line) }
    }

    /// The outline is per-document: dropped so a stale structure never flashes
    /// before the host's fetch lands.
    override func resetForReuse() {
        items = []
        indents = []
        cursorLine = 1
    }

    override func cell(for row: Int, in tableView: NSTableView) -> NSView? {
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

    #if DEBUG
    var visibleItemsForTesting: [OutlineItem] { results }
    #endif
}

/// One outline palette (⌘P) row: indent, kind glyph, optional "Theorem 3"
/// badge, title, and a "return" key badge when selected. The persistent panel
/// (⌘K) uses `OutlineTreeRowView`.
final class OutlinePaletteCellView: FlippedView, PaletteRowContent {
    static let identifier = NSUserInterfaceItemIdentifier("outline-palette-row")
    private let icon = NSImageView()
    private let badgeLabel = NSTextField(labelWithString: "")
    private let titleLabel = NSTextField(labelWithString: "")
    private let returnBadge = KeyBadgeView(text: "return", color: .chalkChromeFgSecondary, width: 42)
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
        iconLeading = icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10)
        badgeGap = titleLabel.leadingAnchor.constraint(equalTo: badgeLabel.trailingAnchor, constant: 7)
        NSLayoutConstraint.activate([
            iconLeading,
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 16),

            badgeLabel.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 9),
            badgeLabel.centerYAnchor.constraint(equalTo: centerYAnchor),

            badgeGap,
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: returnBadge.leadingAnchor, constant: -10),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),

            returnBadge.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            returnBadge.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func configure(item: OutlineItem, indent: Int, query: String) {
        iconLeading.constant = 10 + CGFloat(indent) * ChalkMetrics.outlineIndentUnit

        let symbol: String
        switch item.kind {
        case .heading: symbol = "number"
        case .callout: symbol = "function"
        case .figure: symbol = "photo"
        case .frame: symbol = "rectangle.on.rectangle"
        }
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 13, weight: .regular))

        badgeLabel.stringValue = item.badge ?? ""
        badgeLabel.isHidden = item.badge == nil
        badgeGap.constant = item.badge == nil ? 0 : 7

        let isTop = item.kind == .heading && item.level <= 1
        titleLabel.attributedStringValue = paletteHighlightedTitle(
            item.title, query: query, baseWeight: isTop ? .semibold : .regular,
            size: ChalkMetrics.outlineRowFontSize)
    }

    func setHighlighted(_ highlighted: Bool) {
        returnBadge.isHidden = !highlighted
    }
}
