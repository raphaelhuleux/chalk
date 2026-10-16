import AppKit
import ChalkKit

/// The ⌘O Quick Open palette: fuzzy-filter every file across all Locations,
/// open on select. The match key is "parentFolder/fileName" so queries like
/// "notes ideas" rank the right file.
final class QuickOpenViewController: PaletteListViewController {
    /// Open `url`; `inNewTab` is the ⌘↩ path. Plain ↩ browses in place like a sidebar click.
    var onOpen: ((_ url: URL, _ inNewTab: Bool) -> Void)?

    private var results: [FileNode] = []
    /// Match keys built once per index, not per keystroke.
    private var indexed: [(node: FileNode, key: String)] = []

    private static let resultRowHeight: CGFloat = 46
    private static let maxVisibleRows = 8

    init() {
        super.init(frame: PaletteFrame(
            glyph: "magnifyingglass", placeholder: "Open file\u{2026}",
            hints: "\u{2191}\u{2193} navigate    return open    \u{2318} return new tab",
            rowHeight: Self.resultRowHeight))
    }

    /// Feed the asynchronously enumerated file index. The palette presents first and fills in;
    /// `prepareForReuse` keeps the last index so it never flashes empty.
    func setFiles(_ files: [FileNode]) {
        indexed = files.map { ($0, Self.key($0)) }
        applyQuery(currentQuery)
    }

    override var resultCount: Int { results.count }

    override func computeResults(for query: String) {
        // A blank query yields the first 50 files in index order.
        results = FuzzyMatcher.filter(query: query, items: indexed, key: { $0.key }, limit: 50)
            .map(\.node)
        selectedIndex = 0
    }

    override func bodyHeight() -> CGFloat {
        CGFloat(min(max(results.count, 1), Self.maxVisibleRows)) * Self.resultRowHeight
    }

    override func confirmation(of index: Int, inNewTab: Bool) -> () -> Void {
        let url = results[index].url
        return { [weak self] in self?.onOpen?(url, inNewTab) }
    }

    override func cell(for row: Int, in tableView: NSTableView) -> NSView? {
        let cell = tableView.makeView(withIdentifier: PaletteResultCellView.identifier, owner: nil)
            as? PaletteResultCellView ?? PaletteResultCellView()
        let node = results[row]
        cell.configure(name: node.name, path: Self.key(node), query: appliedQuery)
        cell.setHighlighted(row == selectedIndex)
        return cell
    }

    private static func key(_ node: FileNode) -> String {
        let parent = node.url.deletingLastPathComponent().lastPathComponent
        return "\(parent)/\(node.name)"
    }

    #if DEBUG
    var visibleResultsForTesting: [FileNode] { results }
    #endif
}

/// One result row: doc icon, name, muted path below, and a "return" key badge when selected.
final class PaletteResultCellView: FlippedView, PaletteRowContent {
    static let identifier = NSUserInterfaceItemIdentifier("quick-open-result")
    private let icon = NSImageView()
    private let nameLabel = NSTextField(labelWithString: "")
    private let pathLabel = NSTextField(labelWithString: "")
    private let returnBadge = KeyBadgeView(text: "return", color: .chalkChromeFgSecondary, width: 42)

    override init(frame: NSRect) {
        super.init(frame: frame)
        identifier = Self.identifier
        icon.image = NSImage(systemSymbolName: "doc.text", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 13, weight: .regular))
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
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 16),

            nameLabel.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 11),
            nameLabel.trailingAnchor.constraint(lessThanOrEqualTo: returnBadge.leadingAnchor, constant: -10),
            nameLabel.topAnchor.constraint(equalTo: topAnchor, constant: 6),

            pathLabel.leadingAnchor.constraint(equalTo: nameLabel.leadingAnchor),
            pathLabel.trailingAnchor.constraint(lessThanOrEqualTo: returnBadge.leadingAnchor, constant: -10),
            pathLabel.topAnchor.constraint(equalTo: nameLabel.bottomAnchor, constant: 1),

            returnBadge.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
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
