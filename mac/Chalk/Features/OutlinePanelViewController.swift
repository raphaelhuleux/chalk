import UIKit
import ChalkKit

/// The persistent outline panel (⌘K) on the editor column's trailing edge, fed by the surface's
/// outline pushes. The selection follows the caret's section; a tap jumps and leaves the panel
/// open. A footer shows the document's prose counts. Design:
/// docs/specs/2026-09-04-outline-panel-design.md.
final class OutlinePanelViewController: UIViewController {
    /// Jump to a 1-based line.
    var onJump: ((Int) -> Void)?

    private var items: [OutlineItem] = []
    private var indents: [Int] = []
    private var cursorLine = 1
    private var selectedIndex: Int?
    private var documentName = ""

    private let header = UIView()
    private let eyebrowLabel = UILabel()
    private let nameLabel = UILabel()
    private let headerRule = UIView()
    private let tableView = UITableView(frame: .zero, style: .plain)
    private let emptyLabel = UILabel()
    private let edge = UIView()
    private let footerRule = UIView()
    private let statsLabel = UILabel()
    private var stats: DocumentStats?

    /// The header's distance from the panel's top: up in the band, level with the Mac traffic lights.
    static let headerTop: CGFloat = ChalkMetrics.s(26)
    private static let headerLeading: CGFloat = ChalkMetrics.s(22)
    private static let headerTrailing: CGFloat = ChalkMetrics.s(16)
    private static let headerGap: CGFloat = ChalkMetrics.s(4)
    private static let headerBottom: CGFloat = ChalkMetrics.s(10)
    private static let listTop: CGFloat = ChalkMetrics.s(6)
    private static let listSide: CGFloat = ChalkMetrics.s(6)
    private static let listBottom: CGFloat = ChalkMetrics.s(8)
    static let rowHeight: CGFloat = ChalkMetrics.s(32)
    private static let emptyPadding: CGFloat = ChalkMetrics.s(24)
    private static let footerPadding: CGFloat = ChalkMetrics.s(10)

    #if DEBUG
    private(set) var reloadCountForTesting = 0
    var selectedRowForTesting: Int? { tableView.indexPathForSelectedRow?.row }
    var isEmptyStateVisibleForTesting: Bool { isViewLoaded && !emptyLabel.isHidden }
    var tableViewForTesting: UITableView { tableView }
    var headerFrameForTesting: CGRect { header.frame }
    var headerDocumentNameForTesting: String { nameLabel.text ?? "" }
    /// The footer's text, or nil while it is hidden.
    var statsTextForTesting: String? { statsLabel.isHidden ? nil : statsLabel.text }
    func guideCountForTesting(row: Int) -> Int? {
        (tableView.cellForRow(at: IndexPath(row: row, section: 0)) as? OutlineTreeRowCell)?.guideCount
    }
    #endif

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .chalkChromeBackground

        edge.backgroundColor = .chalkPaletteDivider
        edge.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(edge)

        eyebrowLabel.attributedText = NSAttributedString(
            string: "OUTLINE",
            attributes: [
                .font: UIFont.systemFont(ofSize: ChalkMetrics.sidebarCountFontSize, weight: .semibold),
                .kern: ChalkMetrics.sidebarCountFontSize * 0.08,
                .foregroundColor: UIColor.chalkTextFaint,
            ])
        eyebrowLabel.translatesAutoresizingMaskIntoConstraints = false
        nameLabel.font = .systemFont(ofSize: ChalkMetrics.sectionHeaderFontSize, weight: .semibold)
        nameLabel.textColor = .chalkChromeFg
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.text = documentName
        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        header.translatesAutoresizingMaskIntoConstraints = false
        header.addSubview(eyebrowLabel)
        header.addSubview(nameLabel)
        view.addSubview(header)

        headerRule.backgroundColor = .chalkPaletteDivider
        headerRule.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(headerRule)

        tableView.dataSource = self
        tableView.delegate = self
        tableView.register(OutlineTreeRowCell.self, forCellReuseIdentifier: "row")
        tableView.rowHeight = Self.rowHeight
        tableView.separatorStyle = .none
        // The header already clears the chrome; the automatic adjustment would add the titlebar's
        // safe-area inset again and land the first row a band too low.
        tableView.contentInsetAdjustmentBehavior = .never
        tableView.backgroundColor = .clear
        tableView.contentInset = UIEdgeInsets(top: Self.listTop, left: 0, bottom: Self.listBottom, right: 0)
        tableView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(tableView)

        emptyLabel.text = "No headings"
        emptyLabel.font = .systemFont(ofSize: ChalkMetrics.outlineRowFontSize)
        emptyLabel.textColor = .chalkChromeFgTertiary
        emptyLabel.textAlignment = .center
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(emptyLabel)

        footerRule.backgroundColor = .chalkPaletteDivider
        footerRule.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(footerRule)
        // Monospaced digits, so the line doesn't jitter as the count changes.
        statsLabel.font = .monospacedDigitSystemFont(ofSize: ChalkMetrics.outlineBadgeFontSize, weight: .regular)
        statsLabel.textColor = .chalkChromeFgTertiary
        statsLabel.numberOfLines = 0
        statsLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(statsLabel)

        // One device pixel; the scale is only final once the view is in a window.
        let hair = 1 / max(1, traitCollection.displayScale)
        let edgeWidth = edge.widthAnchor.constraint(equalToConstant: hair)
        let ruleHeight = headerRule.heightAnchor.constraint(equalToConstant: hair)
        let footerRuleHeight = footerRule.heightAnchor.constraint(equalToConstant: hair)
        registerForTraitChanges([UITraitDisplayScale.self]) { (panel: Self, _: UITraitCollection) in
            let hair = 1 / max(1, panel.traitCollection.displayScale)
            edgeWidth.constant = hair
            ruleHeight.constant = hair
            footerRuleHeight.constant = hair
        }
        NSLayoutConstraint.activate([
            edge.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            edge.topAnchor.constraint(equalTo: view.topAnchor),
            edge.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            edgeWidth,

            header.topAnchor.constraint(equalTo: view.topAnchor, constant: Self.headerTop),
            header.leadingAnchor.constraint(equalTo: edge.trailingAnchor, constant: Self.headerLeading),
            header.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -Self.headerTrailing),
            eyebrowLabel.topAnchor.constraint(equalTo: header.topAnchor),
            eyebrowLabel.leadingAnchor.constraint(equalTo: header.leadingAnchor),
            eyebrowLabel.trailingAnchor.constraint(lessThanOrEqualTo: header.trailingAnchor),
            nameLabel.topAnchor.constraint(equalTo: eyebrowLabel.bottomAnchor, constant: Self.headerGap),
            nameLabel.leadingAnchor.constraint(equalTo: header.leadingAnchor),
            nameLabel.trailingAnchor.constraint(equalTo: header.trailingAnchor),
            nameLabel.bottomAnchor.constraint(equalTo: header.bottomAnchor),

            headerRule.topAnchor.constraint(equalTo: header.bottomAnchor, constant: Self.headerBottom),
            headerRule.leadingAnchor.constraint(equalTo: edge.trailingAnchor),
            headerRule.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            ruleHeight,

            tableView.topAnchor.constraint(equalTo: headerRule.bottomAnchor),
            tableView.leadingAnchor.constraint(equalTo: edge.trailingAnchor, constant: Self.listSide),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -Self.listSide),
            tableView.bottomAnchor.constraint(equalTo: footerRule.topAnchor),

            footerRule.leadingAnchor.constraint(equalTo: edge.trailingAnchor),
            footerRule.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            footerRuleHeight,
            statsLabel.topAnchor.constraint(equalTo: footerRule.bottomAnchor, constant: Self.footerPadding),
            statsLabel.leadingAnchor.constraint(equalTo: header.leadingAnchor),
            statsLabel.trailingAnchor.constraint(equalTo: header.trailingAnchor),
            statsLabel.bottomAnchor.constraint(
                equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -Self.footerPadding),

            emptyLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            emptyLabel.topAnchor.constraint(equalTo: headerRule.bottomAnchor, constant: Self.emptyPadding),
        ])
        render(reload: true)
    }

    /// The document name under the eyebrow; empty when no document is open.
    func setDocumentName(_ name: String) {
        documentName = name
        guard isViewLoaded else { return }
        nameLabel.text = name
    }

    /// Feed a snapshot. The list reloads only when the items changed, so typing inside a section
    /// never flickers the rows.
    func setSnapshot(_ snapshot: OutlineSnapshot) {
        let itemsChanged = snapshot.items != items
        items = snapshot.items
        cursorLine = snapshot.cursorLine
        stats = snapshot.stats
        if itemsChanged { indents = OutlinePalettePolicy.indentLevels(for: items) }
        guard isViewLoaded else { return }
        render(reload: itemsChanged)
    }

    /// Built once: `statsText` runs on every outline push. The autoupdating locale keeps the digit
    /// grouping following a region change.
    private static let statsFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.locale = .autoupdatingCurrent
        return formatter
    }()

    /// "1,234 words" (or "12 of 1,234 words" while selecting) over "6,789 characters".
    static func statsText(_ stats: DocumentStats) -> String {
        let number = { (n: Int) in statsFormatter.string(from: NSNumber(value: n)) ?? String(n) }
        let unit = stats.words == 1 ? "word" : "words"
        let words = stats.selectionWords.map { "\(number($0)) of \(number(stats.words)) \(unit)" }
            ?? "\(number(stats.words)) \(unit)"
        let characters = "\(number(stats.characters)) character\(stats.characters == 1 ? "" : "s")"
        return "\(words)\n\(characters)"
    }

    private func render(reload: Bool) {
        if reload {
            tableView.reloadData()
            tableView.layoutIfNeeded()
            #if DEBUG
            reloadCountForTesting += 1
            #endif
        }
        emptyLabel.isHidden = !items.isEmpty
        // Nil before the editor has a document: no footer at all.
        footerRule.isHidden = stats == nil
        statsLabel.isHidden = stats == nil
        statsLabel.text = stats.map(Self.statsText)
        guard !items.isEmpty else {
            selectedIndex = nil
            return
        }
        let index = OutlinePalettePolicy.preselectedIndex(items: items, cursorLine: cursorLine)
        let path = IndexPath(row: index, section: 0)
        let moved = selectedIndex != index
        selectedIndex = index
        // Scroll only when the row is off screen, so the reader's own scroll isn't fought.
        let visible = tableView.indexPathsForVisibleRows ?? []
        let position: UITableView.ScrollPosition =
            (moved || reload) && !visible.contains(path) ? .middle : .none
        tableView.selectRow(at: path, animated: false, scrollPosition: position)
    }
}

extension OutlinePanelViewController: UITableViewDataSource, UITableViewDelegate {
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        items.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "row", for: indexPath) as! OutlineTreeRowCell
        cell.configure(item: items[indexPath.row], indent: indents[indexPath.row])
        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        onJump?(items[indexPath.row].line)
    }
}

/// One outline row as a tree node: indented title, one hairline guide per ancestor level, and
/// ink that quietens with depth.
final class OutlineTreeRowCell: UITableViewCell {
    private let titleLabel = UILabel()
    private var titleLeading: NSLayoutConstraint!
    private(set) var guideCount = 0

    /// Where a level-1 title starts, and how far each deeper level steps in.
    static let titleLeading: CGFloat = ChalkMetrics.s(14)
    static let indentUnit: CGFloat = ChalkMetrics.s(15)
    /// The first guide's x; guide `i` sits `indentUnit` further per step.
    static let guideLeading: CGFloat = ChalkMetrics.s(16)

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        backgroundColor = .clear
        contentView.backgroundColor = .clear
        isOpaque = false
        // The guides are drawn in the divider colour at a one-pixel width.
        registerForTraitChanges(UITraitCollection.chalkColorTraits + [UITraitDisplayScale.self]) {
            (cell: Self, _: UITraitCollection) in
            cell.setNeedsDisplay()
        }

        let selected = UIView()
        selected.backgroundColor = .chalkAccentSelection
        selected.layer.cornerRadius = ChalkMetrics.paletteRowRadius
        selected.layer.cornerCurve = .continuous
        selectedBackgroundView = selected

        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(titleLabel)
        titleLeading = titleLabel.leadingAnchor.constraint(
            equalTo: contentView.leadingAnchor, constant: Self.titleLeading)
        NSLayoutConstraint.activate([
            titleLeading,
            titleLabel.trailingAnchor.constraint(
                lessThanOrEqualTo: contentView.trailingAnchor, constant: -ChalkMetrics.s(10)),
            titleLabel.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func configure(item: OutlineItem, indent: Int) {
        guideCount = max(0, indent)
        titleLeading.constant = Self.titleLeading + CGFloat(indent) * Self.indentUnit
        let ink: UIColor
        let weight: UIFont.Weight
        switch indent {
        case 0:
            ink = .chalkChromeFg
            weight = .semibold
        case 1:
            ink = .chalkChromeFgSecondary
            weight = .regular
        default:
            ink = .chalkTextSecondary
            weight = .regular
        }
        titleLabel.font = .systemFont(ofSize: ChalkMetrics.outlineRowFontSize, weight: weight)
        titleLabel.textColor = ink
        // A badge-only callout row (no title) shows its badge.
        titleLabel.text = item.title.isEmpty ? (item.badge ?? "") : item.title
        setNeedsDisplay()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        selectedBackgroundView?.frame = bounds.insetBy(dx: 0, dy: 1)
    }

    override func draw(_ rect: CGRect) {
        super.draw(rect)
        guard guideCount > 0, let context = UIGraphicsGetCurrentContext() else { return }
        context.setFillColor(UIColor.chalkPaletteDivider.resolvedColor(with: traitCollection).cgColor)
        let hair = 1 / max(1, traitCollection.displayScale)
        for i in 0..<guideCount {
            let x = Self.guideLeading + CGFloat(i) * Self.indentUnit
            context.fill(CGRect(x: x, y: 0, width: hair, height: bounds.height))
        }
    }
}
