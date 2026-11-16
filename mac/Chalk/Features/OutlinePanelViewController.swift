import AppKit
import ChalkKit

/// The persistent outline panel (⌘K) on the editor column's trailing edge, fed by the surface's
/// outline pushes. The selection follows the caret's section; a click jumps and leaves the panel
/// open. A heading with nested items folds from its chevron; folds are kept per document for the
/// session. A footer shows the document's prose counts. Design:
/// docs/specs/2026-09-04-outline-panel-design.md.
final class OutlinePanelViewController: NSViewController {
    /// Jump to a 1-based line.
    var onJump: ((Int) -> Void)?

    private var items: [OutlineItem] = []
    private var indents: [Int] = []
    private var foldable: [Bool] = []
    private var foldKeys: [String] = []
    /// Item index per table row: `items` minus what folded headings hide.
    private var visible: [Int] = []
    private var cursorLine = 1
    /// The caret's item; its row is a folded ancestor's while it is hidden.
    private var selectedIndex: Int?
    private var documentName = ""
    private var documentKey = ""
    private var foldedByDocument: [String: Set<String>] = [:]
    /// Any row folds: every title then steps past a chevron column.
    private var hasGutter = false

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
        guard visible.indices.contains(row) else { return }
        onJump?(items[visible[row]].line)
    }
    /// A chevron click on `row`.
    func toggleFoldForTesting(row: Int, recursive: Bool = false) {
        guard visible.indices.contains(row) else { return }
        toggleFold(item: visible[row], recursive: recursive)
    }
    var rowCountForTesting: Int { tableView.numberOfRows }
    func isFoldableForTesting(row: Int) -> Bool? {
        (tableView.rowView(atRow: row, makeIfNecessary: false) as? OutlineTreeRowView)?.isFoldable
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
        // Layer-backed, so the container's slide moves the panel as one unit:
        // without a layer its frame snapped to its final place while its
        // layer-backed children slid in, a dark block one frame ahead.
        view.wantsLayer = true
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
        let menu = NSMenu()
        menu.addItem(MenuActionItem(title: "Collapse All") { [weak self] in self?.setAllFolded(true) })
        menu.addItem(MenuActionItem(title: "Expand All") { [weak self] in self?.setAllFolded(false) })
        tableView.menu = menu
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
        for hairline in [edge, headerRule, footerRule] {
            hairline.chalkSetLayerBackground(.chalkPaletteDivider, under: view.effectiveAppearance)
        }
    }

    /// The document name under the eyebrow; empty when no document is open.
    /// `key` identifies the document for its folds (default: the name).
    func setDocumentName(_ name: String, key: String? = nil) {
        documentName = name
        let newKey = key ?? name
        let keyChanged = newKey != documentKey
        documentKey = newKey
        if keyChanged { visible = OutlineFolding.visibleIndices(indents: indents, folded: foldedIndices) }
        guard isViewLoaded else { return }
        nameLabel.stringValue = name
        if keyChanged { render(reload: true) }
    }

    // MARK: Folding

    private var foldedKeys: Set<String> {
        get { foldedByDocument[documentKey] ?? [] }
        set { foldedByDocument[documentKey] = newValue.isEmpty ? nil : newValue }
    }

    private var foldedIndices: Set<Int> {
        let keys = foldedKeys
        guard !keys.isEmpty else { return [] }
        return Set(items.indices.filter { foldable[$0] && keys.contains(foldKeys[$0]) })
    }

    /// Fold or unfold one heading; `recursive` (⌥-click) applies the same state to every
    /// foldable item under it, as Finder does.
    private func toggleFold(item index: Int, recursive: Bool) {
        guard foldable.indices.contains(index), foldable[index] else { return }
        let fold = !foldedKeys.contains(foldKeys[index])
        let targets = recursive
            ? OutlineFolding.subtree(of: index, indents: indents).filter { foldable[$0] }
            : [index]
        var keys = foldedKeys
        for target in targets {
            if fold { keys.insert(foldKeys[target]) } else { keys.remove(foldKeys[target]) }
        }
        foldedKeys = keys
        applyFolds()
    }

    private func setAllFolded(_ fold: Bool) {
        foldedKeys = fold ? Set(items.indices.filter { foldable[$0] }.map { foldKeys[$0] }) : []
        applyFolds()
    }

    /// Recompute the visible rows and slide the difference in or out. A single toggle only ever
    /// removes or only inserts; anything mixed reloads.
    private func applyFolds() {
        let old = visible
        visible = OutlineFolding.visibleIndices(indents: indents, folded: foldedIndices)
        guard isViewLoaded else { return }
        let oldSet = Set(old), newSet = Set(visible)
        let removed = IndexSet(old.indices.filter { !newSet.contains(old[$0]) })
        let inserted = IndexSet(visible.indices.filter { !oldSet.contains(visible[$0]) })
        if removed.isEmpty || inserted.isEmpty {
            let animation: NSTableView.AnimationOptions = view.chalkMotionAllowed ? [.effectFade, .slideUp] : []
            tableView.beginUpdates()
            if !removed.isEmpty { tableView.removeRows(at: removed, withAnimation: animation) }
            if !inserted.isEmpty { tableView.insertRows(at: inserted, withAnimation: animation) }
            tableView.endUpdates()
            let folded = foldedIndices
            tableView.enumerateAvailableRowViews { rowView, row in
                guard let rowView = rowView as? OutlineTreeRowView, self.visible.indices.contains(row) else { return }
                rowView.setFolded(folded.contains(self.visible[row]))
            }
            render(reload: false)
        } else {
            render(reload: true)
        }
    }

    /// Feed a snapshot. The list reloads only when the items changed, so typing inside a section
    /// never flickers the rows.
    func setSnapshot(_ snapshot: OutlineSnapshot) {
        let itemsChanged = snapshot.items != items
        items = snapshot.items
        cursorLine = snapshot.cursorLine
        stats = snapshot.stats
        if itemsChanged {
            indents = OutlinePalettePolicy.indentLevels(for: items)
            foldable = OutlineFolding.foldable(indents: indents)
            hasGutter = foldable.contains(true)
            foldKeys = OutlineFolding.keys(for: items)
            visible = OutlineFolding.visibleIndices(indents: indents, folded: foldedIndices)
        }
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
        guard let row = OutlineFolding.row(for: index, visible: visible) else {
            tableView.deselectAll(nil)
            return
        }
        tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        // Scroll only when the row is off screen, so the reader's own scroll isn't fought.
        let shown = tableView.rows(in: tableView.visibleRect)
        if (moved || reload), !shown.contains(row) {
            tableView.scrollRowToVisible(row)
        }
    }

    @objc private func rowClicked() {
        let row = tableView.clickedRow
        guard visible.indices.contains(row) else { return }
        onJump?(items[visible[row]].line)
    }
}

extension OutlinePanelViewController: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int { visible.count }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let rowView = (tableView.makeView(withIdentifier: OutlineTreeRowView.identifier, owner: nil)
            as? OutlineTreeRowView) ?? OutlineTreeRowView()
        rowView.identifier = OutlineTreeRowView.identifier
        let index = visible[row]
        rowView.configure(item: items[index], indent: indents[index],
                          hasGutter: hasGutter, isFoldable: foldable[index],
                          isFolded: foldedIndices.contains(index))
        rowView.onToggleFold = { [weak self] recursive in self?.toggleFold(item: index, recursive: recursive) }
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

/// One outline row as a tree node: a fold chevron where items nest under it, indented title, one
/// hairline guide per ancestor level hanging from the parent's chevron, and ink that quietens with
/// depth. Draws its own hover wash and selection pill (the accent at a wash).
final class OutlineTreeRowView: NSTableRowView {
    static let identifier = NSUserInterfaceItemIdentifier("outline-row")
    private let titleLabel = NSTextField(labelWithString: "")
    private let disclosure = OutlineDisclosureView()
    private var titleLeading: NSLayoutConstraint!
    private var disclosureCenter: NSLayoutConstraint!
    private(set) var guideCount = 0
    private(set) var isFoldable = false
    private var hasGutter = false
    private var item: OutlineItem?
    private var titleFont: NSFont = .systemFont(ofSize: ChalkMetrics.outlineRowFontSize)
    private var restInk: NSColor = .chalkChromeFg
    private var hovering = false
    private var trackingArea: NSTrackingArea?
    /// Chevron click; true when ⌥ was held.
    var onToggleFold: ((Bool) -> Void)?

    /// Where a level-1 title starts, and how far each deeper level steps in.
    static let titleLeading: CGFloat = 14
    static let indentUnit: CGFloat = 15
    /// Extra lead when any row folds, so every title sits past the chevron column.
    static let gutterWidth: CGFloat = 14
    /// The chevron's centre sits this far before its title; guide `i` hangs from level `i`'s chevron.
    static let chevronToTitle: CGFloat = 9
    /// The first guide's x without a chevron column.
    static let guideLeading: CGFloat = 16

    override init(frame: NSRect) {
        super.init(frame: frame)
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.maximumNumberOfLines = 1
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(titleLabel)
        disclosure.translatesAutoresizingMaskIntoConstraints = false
        disclosure.onToggle = { [weak self] recursive in self?.onToggleFold?(recursive) }
        addSubview(disclosure)
        titleLeading = titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.titleLeading)
        disclosureCenter = disclosure.centerXAnchor.constraint(equalTo: leadingAnchor)
        NSLayoutConstraint.activate([
            titleLeading,
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -10),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            disclosureCenter,
            disclosure.topAnchor.constraint(equalTo: topAnchor),
            disclosure.bottomAnchor.constraint(equalTo: bottomAnchor),
            disclosure.widthAnchor.constraint(equalToConstant: OutlineDisclosureView.width),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }

    override var isSelected: Bool {
        didSet { applyInk() }
    }

    func configure(item: OutlineItem, indent: Int, hasGutter: Bool, isFoldable: Bool, isFolded: Bool) {
        guideCount = max(0, indent)
        self.hasGutter = hasGutter
        self.isFoldable = isFoldable
        let lead = Self.titleLeading + (hasGutter ? Self.gutterWidth : 0) + CGFloat(indent) * Self.indentUnit
        titleLeading.constant = lead
        disclosureCenter.constant = lead - Self.chevronToTitle
        disclosure.isHidden = !isFoldable
        disclosure.isFolded = isFolded
        let weight: NSFont.Weight
        switch indent {
        case 0:
            restInk = .chalkChromeFg
            weight = .semibold
        case 1:
            restInk = .chalkChromeFgSecondary
            weight = .regular
        default:
            restInk = .chalkTextSecondary
            weight = .regular
        }
        self.item = item
        titleFont = .systemFont(ofSize: ChalkMetrics.outlineRowFontSize, weight: weight)
        applyInk()
        needsDisplay = true
    }

    func setFolded(_ folded: Bool) { disclosure.isFolded = folded }

    /// A callout, figure or slide with a title leads with its badge in faint ink ("Theorem 2 ·
    /// Main result"); a badge-only row shows the badge as its title.
    private static func title(for item: OutlineItem, font: NSFont, ink: NSColor) -> NSAttributedString {
        let result = NSMutableAttributedString()
        if let badge = item.badge, !item.title.isEmpty {
            result.append(NSAttributedString(string: badge + "  ", attributes: [
                .font: NSFont.systemFont(ofSize: ChalkMetrics.outlineBadgeFontSize, weight: .medium),
                .foregroundColor: NSColor.chalkChromeFgTertiary,
            ]))
        }
        let text = item.title.isEmpty ? (item.badge ?? "") : item.title
        result.append(NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: ink]))
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        result.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: result.length))
        return result
    }

    /// The selected row's title reads at full ink whatever its depth; a badge keeps its faint ink.
    private func applyInk() {
        guard let item else { return }
        titleLabel.attributedStringValue = Self.title(
            for: item, font: titleFont, ink: isSelected ? .chalkChromeFg : restInk)
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        hovering = false
        onToggleFold = nil
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        chalkReplaceTrackingArea(&trackingArea)
    }

    override func mouseEntered(with event: NSEvent) {
        hovering = true
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        hovering = false
        needsDisplay = true
    }

    override func drawSelection(in dirtyRect: NSRect) {
        guard isSelected else { return }
        fillChalkPill(.chalkAccentSelection, insetY: 1, radius: ChalkMetrics.paletteRowRadius)
    }

    override func drawBackground(in dirtyRect: NSRect) {
        if hovering, !isSelected {
            fillChalkPill(.chalkRowHoverBackground, insetY: 1, radius: ChalkMetrics.paletteRowRadius)
        }
        guard guideCount > 0 else { return }
        NSColor.chalkPaletteDivider.setFill()
        let hair = 1 / max(1, window?.backingScaleFactor ?? 2)
        let first = hasGutter
            ? Self.titleLeading + Self.gutterWidth - Self.chevronToTitle
            : Self.guideLeading
        for i in 0..<guideCount {
            let x = first + CGFloat(i) * Self.indentUnit
            NSRect(x: x, y: 0, width: hair, height: bounds.height).fill()
        }
    }
}

/// The fold chevron: right when folded, down when open, the Library's glyph and size. Takes the
/// click itself so a fold never also jumps.
final class OutlineDisclosureView: NSView {
    static let width: CGFloat = 18
    private static let configuration = NSImage.SymbolConfiguration(pointSize: 8, weight: .semibold)
    private static let open = NSImage(systemSymbolName: "chevron.down", accessibilityDescription: "Collapse")?
        .withSymbolConfiguration(configuration)
    private static let closed = NSImage(systemSymbolName: "chevron.right", accessibilityDescription: "Expand")?
        .withSymbolConfiguration(configuration)

    private let glyph = NSImageView()
    private var hovering = false
    private var trackingArea: NSTrackingArea?
    var onToggle: ((Bool) -> Void)?

    var isFolded = false {
        didSet {
            glyph.image = isFolded ? Self.closed : Self.open
            setAccessibilityLabel(isFolded ? "Expand" : "Collapse")
        }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        glyph.imageScaling = .scaleNone
        glyph.image = Self.open
        glyph.contentTintColor = .chalkTextFaint
        glyph.translatesAutoresizingMaskIntoConstraints = false
        addSubview(glyph)
        NSLayoutConstraint.activate([
            glyph.centerXAnchor.constraint(equalTo: centerXAnchor),
            glyph.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        setAccessibilityRole(.disclosureTriangle)
        setAccessibilityLabel("Collapse")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        chalkReplaceTrackingArea(&trackingArea)
    }

    override func mouseEntered(with event: NSEvent) { setHovering(true) }
    override func mouseExited(with event: NSEvent) { setHovering(false) }

    private func setHovering(_ on: Bool) {
        hovering = on
        glyph.contentTintColor = on ? .chalkChromeFg : .chalkTextFaint
    }

    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {
        guard bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        onToggle?(event.modifierFlags.contains(.option))
    }

    override func accessibilityPerformPress() -> Bool {
        onToggle?(false)
        return true
    }
}

/// A flipped view painted in the chrome tone, re-resolved on appearance flips.
final class ChromeToneView: ThemedView {
    var onAppearanceChange: (() -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        refreshColors()
    }

    override func refreshColors() {
        chalkSetLayerBackground(.chalkChromeBackground)
        onAppearanceChange?()
    }
}
