import AppKit
import ChalkKit

/// The persistent outline panel (⌘K) on the editor column's trailing edge, fed by the surface's
/// outline pushes. The selection follows the caret's section; a click jumps and leaves the panel
/// open. A footer shows the document's prose counts. Design:
/// docs/specs/2026-09-04-outline-panel-design.md.
final class OutlinePanelViewController: NSViewController {
    /// Jump to a 1-based line.
    var onJump: ((Int) -> Void)?

    private var items: [OutlineItem] = []
    private var indents: [Int] = []
    private var cursorLine = 1
    private var selectedIndex: Int?
    private var documentName = ""

    private let header = FlippedView()
    private let eyebrowLabel = NSTextField(labelWithString: "")
    private let nameLabel = NSTextField(labelWithString: "")
    private let headerRule = FlippedView()
    private let scrollView = NSScrollView()
    private let tableView = NSTableView()
    private let emptyLabel = NSTextField(labelWithString: "No headings")
    private let edge = FlippedView()
    private let footerRule = FlippedView()
    private let statsLabel = NSTextField(wrappingLabelWithString: "")
    private var stats: DocumentStats?

    /// The header's distance from the panel's top: up in the band, level with the traffic lights.
    static let headerTop: CGFloat = 26
    private static let headerLeading: CGFloat = 22
    private static let headerTrailing: CGFloat = 16
    private static let headerGap: CGFloat = 4
    private static let headerBottom: CGFloat = 10
    private static let listTop: CGFloat = 6
    private static let listSide: CGFloat = 6
    private static let listBottom: CGFloat = 8
    static let rowHeight: CGFloat = 32
    private static let emptyPadding: CGFloat = 24
    private static let footerPadding: CGFloat = 10

    #if DEBUG
    private(set) var reloadCountForTesting = 0
    var selectedRowForTesting: Int? { tableView.selectedRow >= 0 ? tableView.selectedRow : nil }
    var isEmptyStateVisibleForTesting: Bool { isViewLoaded && !emptyLabel.isHidden }
    var tableViewForTesting: NSTableView { tableView }
    var headerFrameForTesting: CGRect { header.frame }
    var headerDocumentNameForTesting: String { nameLabel.stringValue }
    /// The footer's text, or nil while it is hidden.
    var statsTextForTesting: String? { statsLabel.isHidden ? nil : statsLabel.stringValue }
    /// A row click, as `rowClicked` reads it.
    func jumpToRowForTesting(_ row: Int) {
        guard items.indices.contains(row) else { return }
        onJump?(items[row].line)
    }
    func guideCountForTesting(row: Int) -> Int? {
        (tableView.rowView(atRow: row, makeIfNecessary: false) as? OutlineTreeRowView)?.guideCount
    }
    #endif

    override func loadView() {
        let root = ChromeToneView()
        root.onAppearanceChange = { [weak self] in self?.refreshColors() }
        view = root
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        for hairline in [edge, headerRule, footerRule] {
            hairline.wantsLayer = true
            hairline.translatesAutoresizingMaskIntoConstraints = false
        }
        view.addSubview(edge)

        eyebrowLabel.attributedStringValue = NSAttributedString(
            string: "OUTLINE",
            attributes: [
                .font: NSFont.systemFont(ofSize: ChalkMetrics.sidebarCountFontSize, weight: .semibold),
                .kern: ChalkMetrics.sidebarCountFontSize * 0.08,
                .foregroundColor: NSColor.chalkTextFaint,
            ])
        eyebrowLabel.translatesAutoresizingMaskIntoConstraints = false
        nameLabel.font = .systemFont(ofSize: ChalkMetrics.sectionHeaderFontSize, weight: .semibold)
        nameLabel.textColor = .chalkChromeFg
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.maximumNumberOfLines = 1
        nameLabel.stringValue = documentName
        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        header.translatesAutoresizingMaskIntoConstraints = false
        header.addSubview(eyebrowLabel)
        header.addSubview(nameLabel)
        view.addSubview(header)
        view.addSubview(headerRule)

        let column = NSTableColumn(identifier: .init("outline"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.rowHeight = Self.rowHeight
        tableView.intercellSpacing = .zero
        tableView.selectionHighlightStyle = .none
        tableView.backgroundColor = .clear
        tableView.focusRingType = .none
        tableView.allowsEmptySelection = true
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.action = #selector(rowClicked)
        scrollView.documentView = tableView
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.contentInsets = NSEdgeInsets(top: Self.listTop, left: 0, bottom: Self.listBottom, right: 0)
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scrollView)

        emptyLabel.font = .systemFont(ofSize: ChalkMetrics.outlineRowFontSize)
        emptyLabel.textColor = .chalkChromeFgTertiary
        emptyLabel.alignment = .center
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(emptyLabel)

        view.addSubview(footerRule)
        // Monospaced digits, so the line doesn't jitter as the count changes.
        statsLabel.font = .monospacedDigitSystemFont(ofSize: ChalkMetrics.outlineBadgeFontSize, weight: .regular)
        statsLabel.textColor = .chalkChromeFgTertiary
        statsLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(statsLabel)

        let hair = 1 / max(1, view.window?.backingScaleFactor ?? 2)
        NSLayoutConstraint.activate([
            edge.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            edge.topAnchor.constraint(equalTo: view.topAnchor),
            edge.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            edge.widthAnchor.constraint(equalToConstant: hair),

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
            headerRule.heightAnchor.constraint(equalToConstant: hair),

            scrollView.topAnchor.constraint(equalTo: headerRule.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: edge.trailingAnchor, constant: Self.listSide),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -Self.listSide),
            scrollView.bottomAnchor.constraint(equalTo: footerRule.topAnchor),

            footerRule.leadingAnchor.constraint(equalTo: edge.trailingAnchor),
            footerRule.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            footerRule.heightAnchor.constraint(equalToConstant: hair),
            statsLabel.topAnchor.constraint(equalTo: footerRule.bottomAnchor, constant: Self.footerPadding),
            statsLabel.leadingAnchor.constraint(equalTo: header.leadingAnchor),
            statsLabel.trailingAnchor.constraint(equalTo: header.trailingAnchor),
            statsLabel.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -Self.footerPadding),

            emptyLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            emptyLabel.topAnchor.constraint(equalTo: headerRule.bottomAnchor, constant: Self.emptyPadding),
        ])
        refreshColors()
        render(reload: true)
    }

    private func refreshColors() {
        guard isViewLoaded else { return }
        view.effectiveAppearance.performAsCurrentDrawingAppearance {
            for hairline in [edge, headerRule, footerRule] {
                hairline.layer?.backgroundColor = NSColor.chalkPaletteDivider.cgColor
            }
        }
    }

    /// The document name under the eyebrow; empty when no document is open.
    func setDocumentName(_ name: String) {
        documentName = name
        guard isViewLoaded else { return }
        nameLabel.stringValue = name
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

    /// Built once: `statsText` runs on every outline push.
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
            tableView.layoutSubtreeIfNeeded()
            #if DEBUG
            reloadCountForTesting += 1
            #endif
        }
        emptyLabel.isHidden = !items.isEmpty
        // Nil before the editor has a document: no footer at all.
        footerRule.isHidden = stats == nil
        statsLabel.isHidden = stats == nil
        statsLabel.stringValue = stats.map(Self.statsText) ?? ""
        guard !items.isEmpty else {
            selectedIndex = nil
            tableView.deselectAll(nil)
            return
        }
        let index = OutlinePalettePolicy.preselectedIndex(items: items, cursorLine: cursorLine)
        let moved = selectedIndex != index
        selectedIndex = index
        tableView.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        // Scroll only when the row is off screen, so the reader's own scroll isn't fought.
        let visible = tableView.rows(in: tableView.visibleRect)
        if (moved || reload), !visible.contains(index) {
            tableView.scrollRowToVisible(index)
        }
    }

    @objc private func rowClicked() {
        let row = tableView.clickedRow
        guard items.indices.contains(row) else { return }
        onJump?(items[row].line)
    }
}

extension OutlinePanelViewController: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int { items.count }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let rowView = (tableView.makeView(withIdentifier: OutlineTreeRowView.identifier, owner: nil)
            as? OutlineTreeRowView) ?? OutlineTreeRowView()
        rowView.identifier = OutlineTreeRowView.identifier
        rowView.configure(item: items[row], indent: indents[row])
        return rowView
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        // The row view draws everything; the cell is empty so AppKit has a view to size.
        let cell = tableView.makeView(withIdentifier: .init("cell"), owner: nil) ?? NSView()
        cell.identifier = .init("cell")
        return cell
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { true }
}

/// One outline row as a tree node: indented title, one hairline guide per ancestor level, and
/// ink that quietens with depth. Draws its own selection pill (the accent at a wash).
final class OutlineTreeRowView: NSTableRowView {
    static let identifier = NSUserInterfaceItemIdentifier("outline-row")
    private let titleLabel = NSTextField(labelWithString: "")
    private var titleLeading: NSLayoutConstraint!
    private(set) var guideCount = 0

    /// Where a level-1 title starts, and how far each deeper level steps in.
    static let titleLeading: CGFloat = 14
    static let indentUnit: CGFloat = 15
    /// The first guide's x; guide `i` sits `indentUnit` further per step.
    static let guideLeading: CGFloat = 16

    override init(frame: NSRect) {
        super.init(frame: frame)
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.maximumNumberOfLines = 1
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(titleLabel)
        titleLeading = titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.titleLeading)
        NSLayoutConstraint.activate([
            titleLeading,
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -10),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }

    func configure(item: OutlineItem, indent: Int) {
        guideCount = max(0, indent)
        titleLeading.constant = Self.titleLeading + CGFloat(indent) * Self.indentUnit
        let ink: NSColor
        let weight: NSFont.Weight
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
        titleLabel.stringValue = item.title.isEmpty ? (item.badge ?? "") : item.title
        needsDisplay = true
    }

    override func drawSelection(in dirtyRect: NSRect) {
        guard isSelected else { return }
        let pill = NSBezierPath(
            roundedRect: bounds.insetBy(dx: 0, dy: 1),
            xRadius: ChalkMetrics.paletteRowRadius, yRadius: ChalkMetrics.paletteRowRadius)
        NSColor.chalkAccentSelection.setFill()
        pill.fill()
    }

    override func drawBackground(in dirtyRect: NSRect) {
        guard guideCount > 0 else { return }
        NSColor.chalkPaletteDivider.setFill()
        let hair = 1 / max(1, window?.backingScaleFactor ?? 2)
        for i in 0..<guideCount {
            let x = Self.guideLeading + CGFloat(i) * Self.indentUnit
            NSRect(x: x, y: 0, width: hair, height: bounds.height).fill()
        }
    }
}

/// A flipped view painted in the chrome tone, re-resolved on appearance flips.
final class ChromeToneView: FlippedView {
    var onAppearanceChange: (() -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        refresh()
        NotificationCenter.default.addObserver(
            self, selector: #selector(themeDidChange), name: ChalkAppearance.themeDidChange, object: nil)
    }

    @objc private func themeDidChange() {
        refresh()
        onAppearanceChange?()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refresh()
        onAppearanceChange?()
    }

    private func refresh() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = NSColor.chalkChromeBackground.cgColor
        }
    }
}
