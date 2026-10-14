import UIKit
import UniformTypeIdentifiers
import ChalkKit
import os

/// Delegate for a Location header's context menu. Held strongly by the header
/// (`SidebarHeaderCell.menu`) because `UIContextMenuInteraction` only weakly retains its delegate.
///
/// `build` is a var so a recycled header rebinds it instead of re-adding the interaction, which
/// would re-install its pointer tracking on every header that scrolls past.
private final class LocationHeaderMenu: NSObject, UIContextMenuInteractionDelegate {
    var build: () -> UIMenu?
    init(build: @escaping () -> UIMenu?) { self.build = build }
    func contextMenuInteraction(
        _ interaction: UIContextMenuInteraction,
        configurationForMenuAtLocation location: CGPoint
    ) -> UIContextMenuConfiguration? {
        UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [build] _ in build() }
    }
}

/// A Library row, built so that scrolling moves content and nothing else:
///
/// - The height is pinned to `ChalkMetrics.sidebarRowHeight`. The list layout sizes items
///   `.estimated(44)` with no API to change it, so a self-sizing row enters at 44pt and corrects on
///   screen, dragging the rows below. The cell is the only seam that can refuse to self-size.
/// - One chevron view, reused: a fresh `UIImageView` per update reads to UIKit as an accessory
///   removal plus insertion, which it animates on a visible cell.
///
/// Section headers stay self-sizing: the `needsReauthorization` header is two lines tall.
private final class SidebarRowCell: UICollectionViewListCell {
    private let chevron = UIImageView()

    /// Show the SF Symbol in the leading chevron slot, or hide the slot with nil. `accessories` is
    /// only assigned when it changes kind, so repainting a folder row touches only the image.
    func setChevron(_ symbol: String?) {
        guard let symbol else {
            if !accessories.isEmpty { accessories = [] }
            return
        }
        chevron.image = UIImage(
            systemName: symbol,
            withConfiguration: UIImage.SymbolConfiguration(
                pointSize: ChalkMetrics.s(8), weight: .semibold))
        chevron.tintColor = .chalkTextFaint
        guard accessories.isEmpty else { return }
        accessories = [.customView(configuration: .init(
            customView: chevron, placement: .leading(displayed: .always),
            reservedLayoutWidth: .custom(ChalkMetrics.s(8))))]
    }

    override func preferredLayoutAttributesFitting(
        _ layoutAttributes: UICollectionViewLayoutAttributes
    ) -> UICollectionViewLayoutAttributes {
        let attributes = super.preferredLayoutAttributesFitting(layoutAttributes)
        attributes.frame.size.height = ChalkMetrics.sidebarRowHeight
        return attributes
    }
}

/// An area header's trailing slot: the entry count at rest, the fold chevron while the area is
/// collapsed, never both. Cross-faded in a fixed frame so folding never shifts the header's text.
private final class HeaderTrailingSlot: UIView {
    private let count = UILabel()
    private let chevron = UIImageView()
    private var isCollapsed = false

    init() {
        super.init(frame: .zero)
        count.font = .systemFont(ofSize: ChalkMetrics.sidebarCountFontSize)
        count.textColor = .chalkTextFaint
        count.textAlignment = .right
        count.translatesAutoresizingMaskIntoConstraints = false
        chevron.image = UIImage(
            systemName: "chevron.right",
            withConfiguration: UIImage.SymbolConfiguration(
                pointSize: ChalkMetrics.s(9), weight: .semibold))
        chevron.tintColor = .chalkTextFaint
        chevron.alpha = 0
        chevron.translatesAutoresizingMaskIntoConstraints = false
        addSubview(count)
        addSubview(chevron)
        NSLayoutConstraint.activate([
            count.trailingAnchor.constraint(equalTo: trailingAnchor),
            count.centerYAnchor.constraint(equalTo: centerYAnchor),
            chevron.trailingAnchor.constraint(equalTo: trailingAnchor),
            chevron.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// A zero count shows nothing at all: an empty area already says so with
    /// its "Empty" row, and "0" reads as a defect.
    func apply(count value: Int, collapsed: Bool) {
        count.text = value > 0 ? "\(value)" : ""
        let changed = collapsed != isCollapsed
        isCollapsed = collapsed
        let show = { [self] in
            chevron.alpha = collapsed ? 1 : 0
            count.alpha = collapsed ? 0 : 1
        }
        guard changed, window != nil, !UIAccessibility.isReduceMotionEnabled else {
            show()
            invalidateIntrinsicContentSize()
            return
        }
        UIView.animate(withDuration: ChalkMetrics.motionFast,
                       delay: 0, options: [.beginFromCurrentState], animations: show)
        invalidateIntrinsicContentSize()
    }

    override var intrinsicContentSize: CGSize {
        let width = max(count.intrinsicContentSize.width,
                        chevron.intrinsicContentSize.width)
        return CGSize(width: width, height: UIView.noIntrinsicMetric)
    }

    #if DEBUG
    var stateForTesting: (count: String, showsChevron: Bool) {
        (count.alpha > 0.5 ? (count.text ?? "") : "", chevron.alpha > 0.5)
    }
    #endif
}

/// A Location header. Self-sizing (the `needsReauthorization` state adds a second line), and it
/// reuses its trailing slot for the same reason `SidebarRowCell` reuses its chevron.
private final class SidebarHeaderCell: UICollectionViewListCell {
    private let slot = HeaderTrailingSlot()

    /// The Location this header shows, restamped on every dequeue: a tap, or
    /// a click the titlebar band forwards, folds this one.
    var locationID: String?
    /// The context menu's delegate, installed once per header and rebound on
    /// reuse (see `LocationHeaderMenu`).
    var menu: LocationHeaderMenu?

    func setTrailingSlot(count: Int, collapsed: Bool) {
        slot.apply(count: count, collapsed: collapsed)
        guard accessories.isEmpty else { return }
        accessories = [.customView(configuration: .init(
            customView: slot, placement: .trailing(displayed: .always)))]
    }

    #if DEBUG
    var slotStateForTesting: (count: String, showsChevron: Bool) { slot.stateForTesting }
    #endif
}

/// The Library: each Location is a section with an expandable file tree. Folders disclose, documents
/// open, assets preview. Locations are added through the folder picker (security-scoped bookmark).
final class SidebarViewController: UIViewController {
    /// Supplies the current Locations (set by the coordinator before the view loads).
    var locationsProvider: (() -> [Location])?
    /// Tapped a document row (`.md`/`.tex`/`.qmd`).
    var onOpenFile: ((URL) -> Void)?
    /// Tapped an asset row (image/PDF). Binary, so it never reaches the
    /// editor: the shell shows a Quick Look preview instead.
    var onPreviewFile: ((URL) -> Void)?
    /// "Open in New Tab": always adds a tab, unlike `onOpenFile`, which reuses
    /// the current tab when it is unmodified (browse-reuse).
    var onOpenFileInNewTab: ((URL) -> Void)?
    /// "Open in New Window": activates a fresh scene showing this file.
    var onOpenFileInNewWindow: ((URL) -> Void)?
    /// Picked a folder to add as a Location.
    var onAddLocation: ((URL) -> Void)?
    /// Chose "Remove from Window" on a Location header.
    var onRemoveLocation: ((String) -> Void)?
    /// Re-picked the folder for a Location that lost sandbox access; the coordinator re-bookmarks it
    /// in place via `LocationStore.reauthorize`.
    var onReauthorizeLocation: ((_ id: String, _ url: URL) -> Void)?
    /// Location id awaiting a folder re-pick: routes the next document-picker
    /// result to `onReauthorizeLocation` instead of `onAddLocation`.
    private var pendingReauthorizationID: String?
    /// Created a file via a context menu; the coordinator opens it in a tab.
    var onOpenCreatedFile: ((URL) -> Void)?
    /// A file or folder was renamed or drag-moved on disk. The coordinator retargets any open tab
    /// at or under `from`, keeping unsaved edits.
    var onFileMoved: ((_ from: URL, _ to: URL) -> Void)?
    #if DEBUG
    /// Fires on main after any sidebar file operation finishes, success or failure. The operations
    /// run off the main thread (`CoordinatedFileMove`, `runFileWork`), so tests await this before
    /// asserting on-disk state.
    var onFileWorkFinishedForTesting: (() -> Void)?
    /// Same seam for the grandchild reads a folder expansion starts (`loadGrandchildren`). Fires on
    /// main once the reads land, whether or not they changed anything.
    var onExpansionWorkFinishedForTesting: (() -> Void)?
    /// Whether the last grandchild read ran on the main thread (SidebarFileWorkThreadingTests).
    static var lastExpansionReadRanOnMainThread: Bool?
    #endif
    /// The Library's surface: a flat tone-on-tone panel, flush with the window's leading, top and
    /// bottom edges, separated from the editor by tone alone.
    private let panel = ChalkGlassView(style: .paper, cornerRadius: 0)
    /// Where the list's first area header belongs, in this view controller's coordinates: the
    /// chrome floor, where the titlebar ends. The host owns the number because only it can read its
    /// live chrome.
    ///
    /// Asked at every layout pass, never pushed: a column slide moves this view without laying it
    /// out, so a pushed value can describe a position that no longer exists.
    var treeTopProvider: (() -> CGFloat?)?

    /// Where the tree starts inside the panel: the host's datum in panel coordinates, or the
    /// fallback when there is no window (unit tests).
    ///
    /// Applied to the collection view's frame, never its scroll content: content that moves with the
    /// chrome makes UICollectionView re-anchor the scroll offset. See
    /// docs/issues/2026-08-18-sidebar-gap-after-fullscreen.md.
    func treeTopClearance() -> CGFloat {
        guard let top = treeTopProvider?(), view.window != nil else {
            return Self.treeTopPadding
        }
        // Both terms are in this view's own space, so neither goes stale when
        // an ancestor moves the column without laying this controller out.
        return max(Self.treeTopPadding, top - panel.frame.minY)
    }

    /// Fallback clearance with no window: the titlebar is a safe-area inset an unhosted root does
    /// not have.
    static let treeTopPadding = ChalkMetrics.s(24)
    private var treeTopConstraint: NSLayoutConstraint?
    /// Internal, not private: the inline rename editor reaches the cell it is
    /// shaking through it.
    var collectionView: UICollectionView!
    /// Internal, not private: shared with `SidebarRenameEditor` (same type,
    /// other file), which resolves rows to index paths.
    var dataSource: UICollectionViewDiffableDataSource<Location, FileNode>!
    /// Shown centered when the Library has no Locations at all.
    private let emptyStateLabel = UILabel()

    /// The list's bottom fade: rows dissolve before reaching the floating pill instead of sliding
    /// under its glass. The bottom content inset is what lets the last row clear the pill.
    private let listFade = CAGradientLayer()

    /// The document the editor is showing, marked with the selection pill. Pushed by the host on
    /// every tab change; nil when no file-backed tab is active.
    private var openDocumentURL: URL? {
        didSet {
            guard oldValue != openDocumentURL else { return }
            repaintRows(for: [oldValue, openDocumentURL].map { url in
                url.flatMap { self.node(at: $0) }
            })
        }
    }

    /// Top-level entry count per Location id, captured by the section build so
    /// an area header can show it without a disk walk per dequeue.
    private var locationCounts: [String: Int] = [:]

    /// Location ids the user has folded shut, for this session only. A folded Location shows only its
    /// header row.
    private var collapsedLocationIDs: Set<String> = []

    /// Undo for sidebar file moves. Lives here so it is on the responder chain when the Library has
    /// focus, while the editor's own Cmd+Z (CodeMirror history) wins when the editor has focus.
    /// `moveFile` becomes first responder after a move so Cmd+Z lands here.
    /// Internal, not private: `SidebarFileOperations` registers undo for Duplicate and Move to Trash.
    let fileUndoManager = UndoManager()
    override var undoManager: UndoManager? { fileUndoManager }
    override var canBecomeFirstResponder: Bool { true }

    /// Crash-safe row repaint. `reconfigureItems` raises NSInternalInconsistencyException when it
    /// lands during a diffable apply or a layout transition (a column slide), so this
    /// pokes the visible cells' `configurationUpdateHandler` instead. `cellForItem` is a pure query:
    /// misses skip silently, and off-screen rows repaint on dequeue.
    /// Internal, not private: the inline rename editor repaints the row it enters and leaves.
    func repaintRows(for nodes: [FileNode?]) {
        guard isViewLoaded, dataSource != nil else { return }
        for node in nodes.compactMap({ $0 }) {
            if let indexPath = dataSource.indexPath(for: node),
               let cell = collectionView.cellForItem(at: indexPath) {
                cell.setNeedsUpdateConfiguration()
            }
        }
    }

    /// The folder row under the pointer during a drag, lit as the landing zone. Mutually exclusive
    /// with `dropTargetLocationID`.
    private var dropTargetNode: FileNode? {
        didSet {
            guard oldValue != dropTargetNode else { return }
            // Same crash-safe repaint: a drop-target update can land mid-apply.
            repaintRows(for: [oldValue, dropTargetNode])
        }
    }

    /// The row being renamed in place; it renders a text field instead of a label.
    /// Internal so `SidebarRenameEditor` (same type, other file) drives the lifecycle.
    var renamingNode: FileNode?

    /// The Location header under the pointer during a drag. Headers have no reconfigure API, so the
    /// highlight is set directly on the visible header view.
    private var dropTargetLocationID: String? {
        didSet {
            guard oldValue != dropTargetLocationID else { return }
            refreshHeaderHighlights()
        }
    }

    /// The drop-target pill, shared by folder rows and Location headers so both read as one landing
    /// zone.
    private static func dropPillBackground() -> UIBackgroundConfiguration {
        var background = UIBackgroundConfiguration.clear()
        background.backgroundColor = .chalkRowSelection
        background.cornerRadius = ChalkMetrics.rowCornerRadius
        background.backgroundInsets = NSDirectionalEdgeInsets(top: 0.5, leading: 0, bottom: 0.5, trailing: 0)
        return background
    }

    /// The row pill for a cell state. Priority: drop target > selected or focused > pressed > idle; color only, one geometry. Keyboard focus gets the full
    /// selection pill so arrowing moves the same highlight a click leaves (the system halo is
    /// suppressed in the painter).
    static func rowBackground(
        isDropTarget: Bool, isSelected: Bool, isFocused: Bool, isHoveredOrHighlighted: Bool
    ) -> UIBackgroundConfiguration {
        if isDropTarget { return dropPillBackground() }
        var background = UIBackgroundConfiguration.clear()
        if isSelected || isFocused {
            background.backgroundColor = .chalkRowSelection
        } else if isHoveredOrHighlighted {
            background.backgroundColor = .chalkRowHoverBackground
        } else {
            return background
        }
        background.cornerRadius = ChalkMetrics.rowCornerRadius
        background.backgroundInsets = NSDirectionalEdgeInsets(
            top: 0.5, leading: 0, bottom: 0.5, trailing: 0)
        return background
    }

    /// Re-apply every visible area header's trailing slot. A fold changes only the section's items,
    /// and the collection view does not re-dequeue a header for that.
    private func refreshHeaderSlots() {
        let kind = UICollectionView.elementKindSectionHeader
        for indexPath in collectionView.indexPathsForVisibleSupplementaryElements(ofKind: kind) {
            guard let location = dataSource.sectionIdentifier(for: indexPath.section),
                  let view = collectionView.supplementaryView(
                    forElementKind: kind, at: indexPath) as? SidebarHeaderCell else { continue }
            view.setTrailingSlot(count: locationCounts[location.id] ?? 0,
                                 collapsed: collapsedLocationIDs.contains(location.id))
        }
    }

    /// Repaint the visible Location headers so only the `dropTargetLocationID` one shows the drop
    /// pill, with a short fade. The header registration reads the same state, so a header
    /// re-dequeued mid-drag stays correct.
    private func refreshHeaderHighlights() {
        let kind = UICollectionView.elementKindSectionHeader
        UIView.animate(withDuration: ChalkMetrics.motionFast) {
            for indexPath in self.collectionView.indexPathsForVisibleSupplementaryElements(ofKind: kind) {
                guard let location = self.dataSource.sectionIdentifier(for: indexPath.section),
                      let view = self.collectionView.supplementaryView(
                        forElementKind: kind, at: indexPath) as? UICollectionViewListCell else { continue }
                let isTarget = self.dropTargetLocationID == location.id
                view.backgroundConfiguration = isTarget ? Self.dropPillBackground() : .clear()
            }
        }
    }

    /// Sentinel leaf shown under a Location with no files. Its hidden marker name is one `FileTree`
    /// never enumerates, so it cannot collide with a real file.
    private static let emptyMarkerName = ".chalk-empty-location-placeholder"
    private static func emptyPlaceholder(for location: Location) -> FileNode {
        // Encode the Location id: two Locations on the same empty folder still need distinct items
        // (a diffable data source requires uniqueness across all sections).
        let url = location.url.appendingPathComponent("\(emptyMarkerName).\(location.id)")
        return FileNode(url: url, name: "Empty", isDirectory: false)
    }
    static func isEmptyPlaceholder(_ node: FileNode) -> Bool {
        node.url.lastPathComponent.hasPrefix(emptyMarkerName)
    }

    init() {
        super.init(nibName: nil, bundle: nil)
        // No title or toolbar buttons: Quick Open is Cmd+P, Settings Cmd+,, Add Folder the File menu.
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.accessibilityIdentifier = "LibrarySidebar"
        navigationController?.setNavigationBarHidden(true, animated: false)
        configureCollectionView()
        configureDataSource()
        reload()
    }

    /// One line for the scene diagnostics (`RootSplitViewController.stateSummary`), to tell an empty
    /// Library apart from a ghost window without a debugger.
    var diagnosticSummary: String {
        guard isViewLoaded else { return "sidebar=notLoaded" }
        let snapshot = dataSource.snapshot()
        // Window coordinates when possible: a panel pushed out of its column is the known
        // "the Library reads as empty" shape.
        let panel = view.window == nil
            ? panel.frame : view.convert(panel.frame, to: nil)
        return "locations=\(snapshot.sectionIdentifiers.count) rows=\(snapshot.numberOfItems)"
            + " emptyLabel=\(emptyStateLabel.isHidden ? "hidden" : "SHOWN")"
            + " panel=\(Int(panel.minX)),\(Int(panel.minY)) \(Int(panel.width))x\(Int(panel.height))"
    }

    /// Rebuild every Location's tree from disk, keeping expansion. Lazy: only the top level plus one
    /// level under each folder (so chevrons work); deeper levels load on expansion.
    ///
    /// Capture (main), build (pure, any queue), apply (main). This synchronous entry is for callers
    /// that want rows on the next line (the picker, tests); notification triggers use
    /// `scheduleReload()`, which builds off-main because `contentsOfDirectory` on an iCloud Location
    /// can block on the ubiquity daemon indefinitely.
    func reload(animated: Bool = false) {
        guard isViewLoaded else { return } // viewDidLoad calls reload() once loaded
        // A sync reload supersedes the async lane: the generation bump kills any build in flight, and
        // the cancel stops a pending scheduleReload from running a duplicate up to 100ms later.
        pendingReload?.cancel()
        pendingReload = nil
        reloadGeneration += 1
        applySections(Self.buildSections(captureReloadInput()), animated: animated)
    }

    /// Coalesced, off-main reload for notification storms (library change, file move, foreground,
    /// each fanned out to every window) and for the refresh after a file operation (`delay: 0`).
    /// What matters is that the build leaves the main thread; `delay` only coalesces.
    func scheduleReload(animated: Bool = false, delay: TimeInterval = 0.1) {
        guard isViewLoaded else { return }
        pendingReload?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.reloadGeneration += 1
            let generation = self.reloadGeneration
            let input = self.captureReloadInput()
            self.reloadBuildQueue.async { [weak self] in
                let built = Self.buildSections(input)
                DispatchQueue.main.async {
                    guard let self, self.reloadGeneration == generation else { return }
                    self.applySections(built, animated: animated)
                }
            }
        }
        pendingReload = item
        if delay > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
        } else {
            // Same runloop turn: capture now (so the input matches the state
            // the user just changed), build off-main, apply when it lands.
            item.perform()
        }
    }

    private var pendingReload: DispatchWorkItem?
    /// Bumped by every reload (sync or scheduled); an async apply whose
    /// generation is stale bails, so an older tree can never overwrite a newer.
    private var reloadGeneration = 0
    private let reloadBuildQueue = DispatchQueue(label: "com.huleux.chalk.sidebar-reload",
                                                 qos: .userInitiated)

    private struct ReloadInput {
        let locations: [Location]
        let collapsed: Set<String>
        let expandedByLocation: [Location: Set<FileNode>]
    }

    private struct BuiltSections {
        let sections: NSDiffableDataSourceSnapshot<Location, FileNode>
        let trees: [(Location, NSDiffableDataSourceSectionSnapshot<FileNode>)]
        let hasLocations: Bool
        /// Top-level entries per Location id, for the area headers' counts.
        let counts: [String: Int]
    }

    private func captureReloadInput() -> ReloadInput {
        let locations = locationsProvider?() ?? []
        // Remember expansion per section before the rebuild wipes it.
        var expandedByLocation: [Location: Set<FileNode>] = [:]
        for location in dataSource.snapshot().sectionIdentifiers {
            let current = dataSource.snapshot(for: location)
            expandedByLocation[location] = Set(current.items.filter {
                $0.isDirectory && current.isExpanded($0)
            })
        }
        return ReloadInput(locations: locations,
                           collapsed: collapsedLocationIDs,
                           expandedByLocation: expandedByLocation)
    }

    /// Pure: value types in, value types out. Every FileTree walk lives here.
    private static func buildSections(_ input: ReloadInput) -> BuiltSections {
        var sections = NSDiffableDataSourceSnapshot<Location, FileNode>()
        sections.appendSections(input.locations)
        var trees: [(Location, NSDiffableDataSourceSectionSnapshot<FileNode>)] = []
        var counts: [String: Int] = [:]
        for location in input.locations {
            // Folded: header only (empty section snapshot). One top-level read still runs, for the
            // header's count.
            if input.collapsed.contains(location.id) {
                counts[location.id] = FileTree.children(of: location.url).count
                trees.append((location, NSDiffableDataSourceSectionSnapshot<FileNode>()))
                continue
            }
            var tree = NSDiffableDataSourceSectionSnapshot<FileNode>()
            let expanded = input.expandedByLocation[location] ?? []
            func append(_ parent: FileNode?, childrenOf directory: URL) {
                let nodes = FileTree.children(of: directory)
                tree.append(nodes, to: parent)
                for node in nodes where node.isDirectory {
                    if expanded.contains(node) {
                        append(node, childrenOf: node.url)
                        tree.expand([node])
                    } else {
                        // One level ahead so the chevron shows; deeper levels
                        // load in willExpandItem.
                        tree.append(FileTree.children(of: node.url), to: node)
                    }
                }
            }
            append(nil, childrenOf: location.url)
            counts[location.id] = tree.rootItems.count
            // A Location with no files gets an "Empty" sentinel row.
            if tree.items.isEmpty {
                tree.append([Self.emptyPlaceholder(for: location)])
            }
            trees.append((location, tree))
        }
        return BuiltSections(sections: sections, trees: trees,
                             hasLocations: !input.locations.isEmpty, counts: counts)
    }

    /// True when the top-level (section identity) snapshot has to be applied at
    /// all: the Locations were added, removed, or reordered. Pure, so the
    /// "don't blank the tree on an ordinary reload" rule is unit-testable.
    static func sectionsNeedApply(
        _ built: NSDiffableDataSourceSnapshot<Location, FileNode>,
        _ current: NSDiffableDataSourceSnapshot<Location, FileNode>,
    ) -> Bool {
        built.sectionIdentifiers != current.sectionIdentifiers
    }

    private func applySections(_ built: BuiltSections, animated: Bool) {
        emptyStateLabel.isHidden = built.hasLocations
        locationCounts = built.counts
        // Deferred a turn so both run after the applies below settle the section list: headers may
        // not be re-dequeued for a count change (see `refreshHeaderSlots`), and the leading-padding
        // trim can only measure once a first header exists.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.refreshHeaderSlots()
            self.view.setNeedsLayout()
        }
        // A scheduled build used expansion state captured at fire time, and the user may have folded
        // or unfolded since (`toggleFolderExpansion` and `loadChildren` apply directly without
        // bumping reloadGeneration, on purpose). Overlay the current state onto the built trees so a
        // stale build never reverts an interaction. A no-op for the synchronous reload().
        var currentTrees: [Location: NSDiffableDataSourceSectionSnapshot<FileNode>] = [:]
        for location in dataSource.snapshot().sectionIdentifiers {
            currentTrees[location] = dataSource.snapshot(for: location)
        }
        // `built.sections` carries sections and no items. Applying it empties the tree for one turn,
        // which with `animated: true` is a visible blank Library, so apply it only when Locations
        // were added, removed or reordered.
        if Self.sectionsNeedApply(built.sections, dataSource.snapshot()) {
            // Never animated: its only visible effect is the empty tree before the per-section applies.
            dataSource.apply(built.sections, animatingDifferences: false)
        }
        for (location, tree) in built.trees {
            var tree = tree
            if let current = currentTrees[location] {
                Self.mergeExpansion(from: current, into: &tree)
            }
            dataSource.apply(tree, to: location, animatingDifferences: animated)
        }
    }

    /// Overlay the data source's live expansion state onto a freshly built tree: a folder in both
    /// keeps its current fold state. A folder expanded mid-build was walked only one level deep, so
    /// its children are copied from the live tree. Folders only the build knows keep its state.
    private static func mergeExpansion(
        from current: NSDiffableDataSourceSectionSnapshot<FileNode>,
        into tree: inout NSDiffableDataSourceSectionSnapshot<FileNode>
    ) {
        var stack = tree.items.filter(\.isDirectory)
        var visited = Set<FileNode>()
        while let node = stack.popLast() {
            guard visited.insert(node).inserted, current.contains(node) else { continue }
            if current.isExpanded(node) {
                if tree.snapshot(of: node, includingParent: false).items.isEmpty {
                    // From the live tree, not disk: this runs inside the main-thread apply, where an
                    // iCloud `contentsOfDirectory` can block. The next reload corrects anything stale.
                    let children = current.snapshot(of: node, includingParent: false).rootItems
                    tree.append(children, to: node)
                    // Newly appended subfolders can themselves be expanded in
                    // the live tree (a deep expansion during a slow build).
                    stack.append(contentsOf: children.filter(\.isDirectory))
                }
                if !tree.isExpanded(node) { tree.expand([node]) }
            } else if tree.isExpanded(node) {
                tree.collapse([node])
            }
        }
    }

    /// Lazy-load grandchildren when a folder expands, so its child folders show working chevrons.
    private func loadChildren(forExpanding node: FileNode) {
        guard let (location, tree) = sectionTree(containing: node) else { return }
        let folders = tree.snapshot(of: node, includingParent: false).rootItems
            .filter {
                $0.isDirectory
                    && tree.snapshot(of: $0, includingParent: false).items.isEmpty
            }
        guard !folders.isEmpty else { return }
        loadGrandchildren(of: folders, in: location)
    }

    /// The Location holding `node`, with its live tree. A shown row resolves through its index
    /// path; one under a collapsed folder has none, so it falls back to a scan of every section.
    private func sectionTree(
        containing node: FileNode
    ) -> (location: Location, tree: NSDiffableDataSourceSectionSnapshot<FileNode>)? {
        if let indexPath = dataSource.indexPath(for: node),
           let location = dataSource.sectionIdentifier(for: indexPath.section) {
            return (location, dataSource.snapshot(for: location))
        }
        for location in dataSource.snapshot().sectionIdentifiers {
            let tree = dataSource.snapshot(for: location)
            if tree.contains(node) { return (location, tree) }
        }
        return nil
    }

    /// One directory read per revealed subfolder, off the main thread, spliced in when it lands.
    /// The expansion never waits: `buildSections` already loaded the opened folder's children, so
    /// this only gives the revealed subfolders working chevrons. Off-main because each read on an
    /// iCloud Location can block on the ubiquity daemon.
    private func loadGrandchildren(of folders: [FileNode], in location: Location) {
        let generation = reloadGeneration
        reloadBuildQueue.async { [weak self] in
            #if DEBUG
            SidebarViewController.lastExpansionReadRanOnMainThread = Thread.isMainThread
            #endif
            let loaded = folders.map { ($0, FileTree.children(of: $0.url)) }
            DispatchQueue.main.async {
                guard let self else { return }
                #if DEBUG
                defer { self.onExpansionWorkFinishedForTesting?() }
                #endif
                guard self.reloadGeneration == generation else { return }
                var tree = self.dataSource.snapshot(for: location)
                var changed = false
                for (folder, children) in loaded where !children.isEmpty {
                    // Re-check against the live tree: a reload may have landed
                    // while the reads ran and already carried these children.
                    guard tree.contains(folder),
                          tree.snapshot(of: folder, includingParent: false).items.isEmpty
                    else { continue }
                    tree.append(children, to: folder)
                    changed = true
                }
                if changed {
                    self.dataSource.apply(tree, to: location, animatingDifferences: false)
                }
            }
        }
    }

    /// Expand or collapse a folder when its row is clicked. Loads children first so revealed
    /// subfolders get working chevrons, like the disclosure path.
    private func toggleFolderExpansion(_ node: FileNode) {
        guard let (location, current) = sectionTree(containing: node) else { return }
        var tree = current
        if tree.isExpanded(node) {
            tree.collapse([node])
        } else {
            loadChildren(forExpanding: node)
            tree = dataSource.snapshot(for: location)
            tree.expand([node])
        }
        dataSource.apply(tree, to: location, animatingDifferences: true)
        // Repaint the row so its chevron rotates. Not `reconfigureItems`: it raises while the
        // apply above is uncommitted (e.g. a freshly restored window that never laid out).
        if let indexPath = dataSource.indexPath(for: node),
           let cell = collectionView.cellForItem(at: indexPath) {
            cell.setNeedsUpdateConfiguration()
        }
    }

    /// Whether `node` is expanded in whichever section holds it; read by the chevron painter.
    private func isExpanded(_ node: FileNode) -> Bool {
        sectionTree(containing: node)?.tree.isExpanded(node) ?? false
    }

    // MARK: - Keyboard navigation

    /// The tree's keys beyond the focus system (which owns Up/Down and Space): F2 renames, Right
    /// unfolds a folder, Left folds it. `wantsPriorityOverSystemBehavior` because Left/Right are
    /// otherwise consumed as lateral focus moves. Return is not claimed; see `treeKeyCommands`.
    override var keyCommands: [UIKeyCommand]? {
        // Vend nothing unless a Library row has focus: on Catalyst this VC stays on the responder
        // chain while the caret is in the editor, and priority arrow bindings beat the web view, so
        // they ate Left/Right in the document. `keyCommands` is queried per event.
        guard focusedNode() != nil else { return nil }
        return Self.treeKeyCommands
    }

    /// Built once: `keyCommands` is queried on every key event app-wide.
    ///
    /// Return / keypad-Enter are deliberately not bound: on Catalyst a priority Return binding can
    /// eat the editor's Return, and the `focusedNode()` guard is not enough because UIKit focus is
    /// not first responder (a Library row can report focus while the caret types in the webview).
    /// Activation stays on the focus system's Space. Do not re-add Return.
    private static let treeKeyCommands: [UIKeyCommand] = {
        let commands = [
            // F2 renames the focused row (VS Code / Explorer convention).
            UIKeyCommand(input: UIKeyCommand.f2, modifierFlags: [], action: #selector(renameFocusedRow)),
            UIKeyCommand(input: UIKeyCommand.inputRightArrow, modifierFlags: [],
                         action: #selector(unfoldFocusedRow)),
            UIKeyCommand(input: UIKeyCommand.inputLeftArrow, modifierFlags: [],
                         action: #selector(foldFocusedRow)),
        ]
        for command in commands { command.wantsPriorityOverSystemBehavior = true }
        return commands
    }()

    /// The row the focus system currently highlights, resolved cell → index
    /// path → node. Nil when focus is elsewhere (header, another pane).
    private func focusedNode() -> FileNode? {
        guard let cell = UIFocusSystem.focusSystem(for: self)?.focusedItem as? UICollectionViewCell,
              let indexPath = collectionView.indexPath(for: cell)
        else { return nil }
        return dataSource.itemIdentifier(for: indexPath)
    }

    @objc private func renameFocusedRow() {
        if let node = focusedNode() { beginRename(node) }
    }

    @objc private func unfoldFocusedRow() {
        if let node = focusedNode() { handleFoldKey(node, expanding: true) }
    }

    @objc private func foldFocusedRow() {
        if let node = focusedNode() { handleFoldKey(node, expanding: false) }
    }

    /// The activation path shared by row clicks and the focus system's Space: the sentinel is inert,
    /// folders toggle, files select their row (so the pill marks it even from the keyboard) and open.
    func activate(_ node: FileNode) {
        guard !Self.isEmptyPlaceholder(node) else { return }
        // Any other row ends an in-flight rename first, discarding it, so two rows never both carry
        // the selection pill. Nothing in the sidebar resigns the field (on Mac it self-commits when it
        // loses AppKit focus). A tap inside the live field (same row) leaves the editor open.
        if let renaming = renamingNode, renaming != node {
            cancelRename()
        }
        if node.isDirectory {
            toggleFolderExpansion(node)
        } else {
            if let indexPath = dataSource.indexPath(for: node) {
                collectionView.selectItem(at: indexPath, animated: false, scrollPosition: [])
            }
            if FileTree.kind(of: node.url) == .asset {
                onPreviewFile?(node.url)
            } else {
                onOpenFile?(node.url)
            }
        }
    }

    /// Right unfolds a focused folder, Left folds it; files and the sentinel ignore both.
    private func handleFoldKey(_ node: FileNode, expanding: Bool) {
        guard node.isDirectory, !Self.isEmptyPlaceholder(node),
              isExpanded(node) != expanding else { return }
        toggleFolderExpansion(node)
    }

    private func configureCollectionView() {
        var config = UICollectionLayoutListConfiguration(appearance: .sidebarPlain)
        config.headerMode = .supplementary
        config.backgroundColor = .clear
        config.showsSeparators = false // the design has calm, separator-free rows
        let layout = UICollectionViewCompositionalLayout.list(using: config)
        collectionView = SafeAreaFreeCollectionView(
            frame: view.bounds, collectionViewLayout: layout)
        collectionView.backgroundColor = .clear
        // Rows are rigid (`SidebarRowCell` pins its height), so nothing may re-measure a laid-out
        // cell: a content change on a visible row would invalidate layout mid-scroll.
        collectionView.selfSizingInvalidation = .disabled
        collectionView.delegate = self
        // Arrow keys walk the rows through the focus system (on by default on Catalyst).
        // Selection must not follow focus: selecting opens a file or toggles a folder.
        collectionView.allowsFocus = true
        collectionView.selectionFollowsFocus = false
        collectionView.remembersLastFocusedIndexPath = true
        // In-app drag-move of rows onto folders and Location headers.
        collectionView.dragDelegate = self
        collectionView.dropDelegate = self
        collectionView.dragInteractionEnabled = true

        // The panel is flat and flush, so the column behind it carries the same tone: anything the
        // panel cannot reach (a slide in flight) still reads as sidebar.
        view.backgroundColor = .chalkChromeBackground
        panel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(panel)

        collectionView.translatesAutoresizingMaskIntoConstraints = false
        collectionView.contentInsetAdjustmentBehavior = .never // the tree clears the chrome itself
        panel.contentView.addSubview(collectionView)

        // Flush on every edge.
        let panelTop = panel.topAnchor.constraint(equalTo: view.topAnchor)
        // Safe-area leading, not view leading: the Catalyst split view gives the primary column a
        // ~100pt offscreen leading overhang, reported through the safe area.
        let panelLeading = panel.leadingAnchor.constraint(
            equalTo: view.safeAreaLayoutGuide.leadingAnchor)
        let panelBottom = panel.bottomAnchor.constraint(equalTo: view.bottomAnchor)

        // The list's padding above the first header is measured away by `trimLeadingListPadding()`.
        // The pill floats over the panel's bottom-leading corner, so the list must scroll clear of it.
        collectionView.contentInset.bottom =
            ChalkMetrics.footerPillHeight + ChalkMetrics.footerPillMargin * 2
        collectionView.verticalScrollIndicatorInsets.bottom = collectionView.contentInset.bottom
        listFade.colors = [UIColor.white.cgColor, UIColor.white.cgColor, UIColor.clear.cgColor]
        listFade.startPoint = CGPoint(x: 0.5, y: 0)
        listFade.endPoint = CGPoint(x: 0.5, y: 1)
        collectionView.layer.mask = listFade

        let treeTop = collectionView.topAnchor.constraint(
            equalTo: panel.contentView.topAnchor, constant: Self.treeTopPadding)
        treeTopConstraint = treeTop
        NSLayoutConstraint.activate([
            panelLeading,
            panel.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            panelTop,
            panelBottom,

            treeTop,
            collectionView.bottomAnchor.constraint(equalTo: panel.contentView.bottomAnchor),
            // The selection pill's inset from the panel edge; row content adds
            // its own 8, which puts a row's icon level with the area headers.
            collectionView.leadingAnchor.constraint(
                equalTo: panel.contentView.leadingAnchor, constant: ChalkMetrics.sidebarListInset),
            collectionView.trailingAnchor.constraint(
                equalTo: panel.contentView.trailingAnchor, constant: -ChalkMetrics.sidebarListInset),
        ])

        emptyStateLabel.numberOfLines = 0
        emptyStateLabel.textAlignment = .center
        emptyStateLabel.font = .systemFont(ofSize: ChalkMetrics.sidebarRowFontSize)
        emptyStateLabel.textColor = .chalkTextMuted
        emptyStateLabel.text = "No folders in this window\n\u{21E7}\u{2318}O adds one"
        emptyStateLabel.isHidden = true
        emptyStateLabel.translatesAutoresizingMaskIntoConstraints = false
        panel.contentView.addSubview(emptyStateLabel)
        NSLayoutConstraint.activate([
            emptyStateLabel.centerXAnchor.constraint(equalTo: panel.contentView.centerXAnchor),
            emptyStateLabel.centerYAnchor.constraint(equalTo: panel.contentView.centerYAnchor),
            emptyStateLabel.leadingAnchor.constraint(
                greaterThanOrEqualTo: panel.contentView.leadingAnchor, constant: 16),
            emptyStateLabel.trailingAnchor.constraint(
                lessThanOrEqualTo: panel.contentView.trailingAnchor, constant: -16),
        ])
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        updateTreeTopClearance()
        trimLeadingListPadding()
        updateListFade()
    }

    /// Keep the bottom fade over the pill's clearance. Layer geometry only, never a constraint write,
    /// so this cannot re-enter layout.
    private func updateListFade() {
        guard let collectionView, collectionView.bounds.height > 0 else { return }
        let height = collectionView.bounds.height
        // Long enough to read as a dissolve, short enough to keep the list dense.
        let fade = min(ChalkMetrics.footerPillHeight, height / 4)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        listFade.frame = collectionView.bounds
        listFade.locations = [0, NSNumber(value: Double((height - fade) / height)), 1]
        CATransaction.commit()
    }

    /// Swallow the list layout's padding above the first area header, so the list starts exactly at
    /// the tree's top. Measured, since it varies by platform and OS. The header's attribute frame is
    /// in content coordinates, so writing the inset cannot feed back into the measurement.
    ///
    /// Measured only at rest: on macOS 27 the first header is pinned, and a pinned header reports
    /// where it is pinned, so a scrolled list measured its offset as padding and was later snapped
    /// back to the top. See docs/issues/2026-09-17-macos-27-breaks-the-mac-chrome.md.
    private func trimLeadingListPadding() {
        guard let collectionView, collectionView.numberOfSections > 0,
              abs(collectionView.contentOffset.y + collectionView.contentInset.top) < 0.5,
              let header = collectionView.collectionViewLayout
                  .layoutAttributesForSupplementaryView(
                      ofKind: UICollectionView.elementKindSectionHeader,
                      at: IndexPath(item: 0, section: 0))
        else { return }
        let wanted = -header.frame.minY
        guard abs(collectionView.contentInset.top - wanted) > 0.5 else { return }
        collectionView.contentInset.top = wanted
        // UIScrollView keeps contentOffset when the inset changes; a list at the top must stay there.
        collectionView.contentOffset.y = -wanted
    }

    /// Re-apply `treeTopClearance()`. Half-point tolerance: a fractional value UIKit rounds away
    /// would re-enter layout forever.
    private func updateTreeTopClearance() {
        guard let treeTop = treeTopConstraint else { return }
        let wanted = treeTopClearance()
        if abs(treeTop.constant - wanted) > 0.5 {
            treeTop.constant = wanted
        }
    }


    private func configureDataSource() {
        let cell = UICollectionView.CellRegistration<SidebarRowCell, FileNode> { [weak self] cell, _, node in
            // Configure now, not only from the update handler, which runs on a later layout pass:
            // otherwise the cell measures at the 44pt estimate and resizes on screen
            // (SidebarRowMetricsTests pins this).
            self?.applyRowConfiguration(to: cell, node: node, state: cell.configurationState)
            // The handler covers state changes (selection, focus, hover, drop target, rename).
            // `repaintRows(for:)` and `toggleFolderExpansion` drive it through
            // `setNeedsUpdateConfiguration()`, the crash-safe stand-in for `reconfigureItems`.
            cell.configurationUpdateHandler = { [weak self] cell, state in
                guard let cell = cell as? SidebarRowCell else { return }
                self?.applyRowConfiguration(to: cell, node: node, state: state)
            }
        }

        dataSource = UICollectionViewDiffableDataSource<Location, FileNode>(
            collectionView: collectionView
        ) { collectionView, indexPath, node in
            collectionView.dequeueConfiguredReusableCell(using: cell, for: indexPath, item: node)
        }

        let header = UICollectionView.SupplementaryRegistration<SidebarHeaderCell>(
            elementKind: UICollectionView.elementKindSectionHeader
        ) { [weak self] view, _, indexPath in
            guard let self,
                  // Never index sectionIdentifiers raw: a header dequeued during an in-flight apply
                  // can carry a stale section index.
                  let location = self.dataSource.sectionIdentifier(for: indexPath.section)
            else { return }
            self.applyHeaderConfiguration(
                to: view, location: location, isFirst: indexPath.section == 0)
        }
        dataSource.supplementaryViewProvider = { collectionView, _, indexPath in
            collectionView.dequeueConfiguredReusableSupplementary(using: header, for: indexPath)
        }

        dataSource.sectionSnapshotHandlers.willExpandItem = { [weak self] node in
            self?.loadChildren(forExpanding: node)
        }
    }

    /// Paint one row. Runs from the cell registration (so the first measurement is the real row) and
    /// from `configurationUpdateHandler` on every state change; idempotent.
    ///
    /// Runs without animation: UIKit implicitly animates accessory and configuration writes on a
    /// visible cell, and a recycled cell flipping between file and folder reads as rows sliding.
    private func applyRowConfiguration(
        to cell: SidebarRowCell, node: FileNode, state: UICellConfigurationState
    ) {
        UIView.performWithoutAnimation {
            // The pill is the only focus treatment; the system halo would double-draw around it.
            cell.focusEffect = nil
            // The "Empty" sentinel: faint, icon-less, never a selection pill.
            if Self.isEmptyPlaceholder(node) {
                var content = cell.defaultContentConfiguration()
                content.text = node.name
                content.textProperties.font = .systemFont(ofSize: ChalkMetrics.sidebarRowFontSize)
                content.textProperties.color = .chalkTextFaint
                Self.compactRowMargins(&content, isFile: true)
                cell.contentConfiguration = content
                cell.backgroundConfiguration = .clear()
                cell.setChevron(nil)
                return
            }
            // Inline rename: a text field with the selected pill, even when the row is not the
            // collection view's selection (context menu / F2). `activate(_:)` ends a rename before
            // another row is selected, so the pill never doubles up.
            if renamingNode == node {
                cell.contentConfiguration = SidebarRenameConfiguration(
                    node: node,
                    symbol: Self.symbol(for: node),
                    onCommit: { [weak self] name in self?.commitRename(name) },
                    onCancel: { [weak self] in self?.cancelRename() })
                cell.backgroundConfiguration = Self.rowBackground(
                    isDropTarget: false, isSelected: true,
                    isFocused: false, isHoveredOrHighlighted: false)
                cell.setChevron(nil)
                return
            }
            var content = cell.defaultContentConfiguration()
            content.text = node.name
            // Single line, tail truncation (the default numberOfLines is 0, unlimited).
            content.textProperties.numberOfLines = 1
            content.textProperties.lineBreakMode = .byTruncatingTail
            // Rows take the editor text ramp (body -> primary). Selection, focus and the open
            // document share the pill and brighten to primary. The weight swap is safe for scrolling
            // only because the row height is pinned.
            let isOpen = openDocumentURL == node.url
            let prominent = state.isSelected || state.isFocused || isOpen
            content.textProperties.font = .systemFont(
                ofSize: ChalkMetrics.sidebarRowFontSize, weight: prominent ? .medium : .regular)
            content.textProperties.color = prominent
                ? .chalkTextPrimary : .chalkTextBody
            content.image = UIImage(
                systemName: Self.symbol(for: node), withConfiguration: Self.rowIconConfiguration)
            content.imageProperties.tintColor = .chalkTextMuted
            content.imageToTextPadding = Self.rowIconTextPadding
            Self.compactRowMargins(&content, isFile: !node.isDirectory)
            cell.contentConfiguration = content

            cell.backgroundConfiguration = Self.rowBackground(
                isDropTarget: dropTargetNode == node,
                isSelected: state.isSelected || isOpen,
                isFocused: state.isFocused,
                isHoveredOrHighlighted: state.isHighlighted)

            // Folders carry a leading chevron, right when collapsed and down when expanded, repainted
            // here after a toggle. `setChevron` swaps the image in place (see `SidebarRowCell`).
            cell.setChevron(node.isDirectory
                ? (isExpanded(node) ? "chevron.down" : "chevron.right")
                : nil)
        }
    }

    /// Paint one Location header, without animation for the same reason as rows.
    private func applyHeaderConfiguration(
        to view: SidebarHeaderCell, location: Location, isFirst: Bool
    ) {
        UIView.performWithoutAnimation {
            var content = view.defaultContentConfiguration()
            content.text = location.name
            content.textProperties.numberOfLines = 1
            content.textProperties.lineBreakMode = .byTruncatingTail
            content.textProperties.font = .systemFont(
                ofSize: ChalkMetrics.sectionHeaderFontSize, weight: .semibold)
            content.textProperties.color = .chalkTextPrimary
            if location.needsReauthorization {
                // Sandbox lost this folder (moved, deleted, or a pre-sandbox bookmark): dim it and
                // name the re-grant gesture.
                content.textProperties.color = .chalkTextMuted
                content.secondaryText = "No access — right-click to grant"
                content.secondaryTextProperties.font = .systemFont(
                    ofSize: ChalkMetrics.sidebarCountFontSize)
                content.secondaryTextProperties.color = .chalkTextMuted
            }
            // The first area sits against the chrome floor, which already
            // separates it; the 22pt block of air belongs BETWEEN areas.
            content.directionalLayoutMargins = NSDirectionalEdgeInsets(
                top: isFirst ? ChalkMetrics.s(8) : ChalkMetrics.sidebarSectionTopMargin,
                leading: ChalkMetrics.s(8),
                bottom: ChalkMetrics.sidebarSectionBottomMargin,
                trailing: ChalkMetrics.s(8))
            view.contentConfiguration = content

            // Drop-target highlight for dragging a file out to this Location's
            // top level (read here so a header re-dequeued mid-drag stays lit).
            view.backgroundConfiguration = self.dropTargetLocationID == location.id
                ? Self.dropPillBackground() : .clear()

            // The count, or the fold chevron while the area is shut; a tap on the header toggles it.
            let collapsed = self.collapsedLocationIDs.contains(location.id)
            view.setTrailingSlot(count: self.locationCounts[location.id] ?? 0,
                                 collapsed: collapsed)
            installHeaderFold(on: view, for: location)
            installHeaderMenu(on: view, for: location)
        }
    }

    /// Mark the document the editor is showing; nil when no file-backed tab is active.
    func setOpenDocument(_ url: URL?) {
        openDocumentURL = url
    }

    /// The node for a URL, if the tree lists it. Guarded on `dataSource`, not just `isViewLoaded`:
    /// the host pushes the open document (`handleTabsChanged`) on the restore path, and `dataSource`
    /// is nil until `viewDidLoad` builds it.
    private func node(at url: URL) -> FileNode? {
        guard isViewLoaded, dataSource != nil else { return nil }
        return dataSource.snapshot().itemIdentifiers.first { $0.url == url }
    }

    private static func symbol(for node: FileNode) -> String {
        // Thin monochrome outline glyphs.
        if node.isDirectory { return "folder" }
        switch node.url.pathExtension.lowercased() {
        case "tex": return "function"
        case "pdf": return "doc.richtext"
        case "png", "jpg", "jpeg": return "photo"
        default: return "doc.text"
        }
    }

    private static func compactRowMargins(
        _ content: inout UIListContentConfiguration, isFile: Bool
    ) {
        content.directionalLayoutMargins = rowMargins(isFile: isFile)
    }

    // Row geometry, shared with the inline rename row (`SidebarRenameContentView`), which must
    // match it exactly or the swap to a text field visibly moves the row.

    /// Row insets: 5pt above and below, 8pt sides. Files indent to 23pt so their icons line up past
    /// the folder rows' chevron slot.
    static func rowMargins(isFile: Bool) -> NSDirectionalEdgeInsets {
        NSDirectionalEdgeInsets(
            top: ChalkMetrics.s(5), leading: ChalkMetrics.s(isFile ? 23 : 8),
            bottom: ChalkMetrics.s(5), trailing: ChalkMetrics.s(8))
    }
    static let rowIconConfiguration = UIImage.SymbolConfiguration(
        pointSize: ChalkMetrics.sidebarRowFontSize - 1.5, weight: .regular)
    static let rowIconTextPadding = ChalkMetrics.s(7)

    // MARK: - Create

    /// A non-colliding URL in `dir`: `Untitled.md`, then `Untitled 2.md`, ... Static so the probe runs
    /// on the file-work queue: each `fileExists` inside an iCloud Location crosses the sync layer.
    private static func uniqueURL(in dir: URL, base: String, ext: String?) -> URL {
        let name = FileNaming.uniqueName(base: base, ext: ext) { candidate in
            FileManager.default.fileExists(atPath: dir.appendingPathComponent(candidate).path)
        }
        return dir.appendingPathComponent(name)
    }

    /// Create `Untitled.md` (or `.tex`, per `defaultFileType`) in `directory`, open it in a tab and
    /// refresh the tree. The directory's security scope is held by `LocationStore` for the session.
    private func createFile(in directory: URL) {
        let ext = Preferences.defaultFileType.fileExtension
        runFileWork { () throws -> URL in
            let url = Self.uniqueURL(in: directory, base: "Untitled", ext: ext)
            try Data("".utf8).write(to: url)
            return url
        } then: { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let error):
                self.showFileOpFailure("Couldn\u{2019}t create the file: \(error.localizedDescription)")
            case .success(let url):
                self.onOpenCreatedFile?(url)
                self.reloadEveryLibrary(animated: false)
            }
        }
    }

    /// Create `Untitled Folder` inside `directory` and refresh the tree.
    private func createFolder(in directory: URL) {
        runFileWork { () throws -> URL in
            let url = Self.uniqueURL(in: directory, base: "Untitled Folder", ext: nil)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
            return url
        } then: { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let error):
                self.showFileOpFailure("Couldn\u{2019}t create the folder: \(error.localizedDescription)")
            case .success:
                self.reloadEveryLibrary(animated: false)
            }
        }
    }

    /// New File / New Folder actions, shared by the folder-row and Location-header menus.
    /// Internal, not private: `SidebarFileOperations` builds the row menu.
    func createActions(in directory: URL) -> [UIMenuElement] {
        [
            UIAction(title: "New File", image: UIImage(systemName: "doc.badge.plus")) { [weak self] _ in
                self?.createFile(in: directory)
            },
            UIAction(title: "New Folder", image: UIImage(systemName: "folder.badge.plus")) { [weak self] _ in
                self?.createFolder(in: directory)
            },
        ]
    }

    // MARK: - Location header context menu

    /// Attach or rebind a Location header's context menu: New File / New Folder (Grant Access when
    /// the Location lost access) plus "Remove from Window".
    private func installHeaderMenu(on view: SidebarHeaderCell, for location: Location) {
        let build: () -> UIMenu? = { [weak self] in
            guard let self else { return nil }
            // A no-access Location can't host New File/Folder; its only useful
            // actions are re-granting the folder or removing the row.
            var children: [UIMenuElement] = location.needsReauthorization
                ? [UIAction(
                    title: "Grant Access…",
                    image: UIImage(systemName: "folder.badge.person.crop")
                  ) { [weak self] _ in self?.presentReauthorizePicker(for: location.id) }]
                : self.createActions(in: location.url)
            children.append(UIMenu(title: "", options: .displayInline, children: [
                UIAction(
                    title: "Remove from Window",
                    image: UIImage(systemName: "trash"),
                    attributes: .destructive
                ) { [weak self] _ in self?.onRemoveLocation?(location.id) },
            ]))
            return UIMenu(children: children)
        }
        // Rebind an already-installed header rather than churning its
        // interaction (see LocationHeaderMenu).
        if let existing = view.menu {
            existing.build = build
            return
        }
        let delegate = LocationHeaderMenu(build: build)
        // Retain the delegate for the life of the view (the interaction holds it weakly).
        view.menu = delegate
        view.addInteraction(UIContextMenuInteraction(delegate: delegate))
    }

    // MARK: - Location fold/unfold

    /// Make a Location header fold on tap. The header is reused, so the recognizer is attached once
    /// and `locationID` is restamped on every dequeue; the recognizer does not retain its target.
    private func installHeaderFold(on view: SidebarHeaderCell, for location: Location) {
        view.locationID = location.id
        let hasTap = view.gestureRecognizers?.contains { $0 is UITapGestureRecognizer } ?? false
        if !hasTap {
            view.addGestureRecognizer(
                UITapGestureRecognizer(target: self, action: #selector(headerTapped(_:))))
        }
    }

    @objc private func headerTapped(_ recognizer: UITapGestureRecognizer) {
        guard let view = recognizer.view else { return }
        toggleFold(onHeader: view)
    }

    /// Fold/unfold the Location a header stands for. Shared with the titlebar band's forwarded
    /// clicks, which arrive as a point, not a gesture.
    private func toggleFold(onHeader view: UIView) {
        guard let id = (view as? SidebarHeaderCell)?.locationID else { return }
        if collapsedLocationIDs.contains(id) {
            collapsedLocationIDs.remove(id)
        } else {
            collapsedLocationIDs.insert(id)
        }
        // Unfolding rebuilds the Location's first level, so build off-main. Zero delay: the fold
        // state is captured in this runloop turn.
        scheduleReload(delay: 0)
    }

    /// A click in the titlebar band over this panel. The Library's top rows sit under the titlebar,
    /// where AppKit gets the mouse (`ChalkTitlebarBandView`); the band forwards the point, in window
    /// coordinates, and this replays it as a click: a row activates, a header folds.
    func replayTitlebarBandClick(atWindowPoint point: CGPoint) {
        guard let window = view.window, !collectionView.isHidden else { return }
        let local = collectionView.convert(point, from: window)
        guard collectionView.bounds.contains(local) else { return }
        if let indexPath = collectionView.indexPathForItem(at: local),
           let node = dataSource.itemIdentifier(for: indexPath) {
            activate(node)
            return
        }
        // Headers are supplementary views: they own no index path to hit-test,
        // so match the visible ones by frame.
        for header in collectionView.visibleSupplementaryViews(
            ofKind: UICollectionView.elementKindSectionHeader)
        where header.frame.contains(local) {
            toggleFold(onHeader: header)
            return
        }
    }

    // MARK: - Move (rename + drag-move, with undo)

    /// The single mutation point for rename and drag-move: coordinated move, open-tab update
    /// (`onFileMoved`), tree refresh and undo registration, so the two callers can't drift.
    ///
    /// Two phases. The collision verdict is a synchronous `fileExists` probe, returned as the result
    /// (a collision rejects; an undo whose slot is re-occupied no-ops). The move runs off-main
    /// (`CoordinatedFileMove`) and reports through `completion`, which fires only when the pre-flight
    /// passed, so a caller is never told twice. Becoming first responder afterwards points Cmd+Z at
    /// `fileUndoManager`.
    @discardableResult
    /// Internal, not private: `commitRename` funnels through it too.
    func moveFile(from source: URL, to destination: URL, actionName: String,
                  animated: Bool = false,
                  completion: ((Bool) -> Void)? = nil) -> Bool {
        // Collision guard, except a case-only rename: on case-insensitive APFS (Catalyst's default)
        // `fileExists` matches the source itself, so "notes.md" -> "Notes.md" would always be rejected.
        guard !FileManager.default.fileExists(atPath: destination.path)
                || Self.isCaseOnlyRename(from: source, to: destination) else { return false }
        CoordinatedFileMove.perform(from: source, to: destination) { [weak self] error in
            guard let self else { return }
            if let error {
                Logger(subsystem: "com.huleux.chalk", category: "sidebar")
                    .error("move failed: \(error.localizedDescription, privacy: .private)")
                completion?(false)
                self.notifyFileWorkFinished()
                return
            }
            self.onFileMoved?(source, destination)
            // Built off-main: a synchronous tree walk here is another ubiquity-daemon wait.
            self.scheduleReload(animated: animated, delay: 0)
            // NSUndoManager is not thread-safe and this is the main queue,
            // where the completion lands by contract.
            self.fileUndoManager.registerUndo(withTarget: self) { target in
                target.moveFile(from: destination, to: source,
                                actionName: actionName, animated: animated)
            }
            self.fileUndoManager.setActionName(actionName)
            self.becomeFirstResponder()
            completion?(true)
            self.notifyFileWorkFinished()
        }
        return true
    }

    /// True when `destination` differs from `source` only by letter case in the same directory: the
    /// one existing-destination case `moveFile` allows. Pure, so it is unit-testable.
    static func isCaseOnlyRename(from source: URL, to destination: URL) -> Bool {
        let sameDir = source.deletingLastPathComponent().standardizedFileURL
            == destination.deletingLastPathComponent().standardizedFileURL
        return sameDir
            && source.lastPathComponent.lowercased() == destination.lastPathComponent.lowercased()
            && source.lastPathComponent != destination.lastPathComponent
    }

    /// The alert every failed sidebar file operation shows, so a failure is never silent.
    /// Internal, not private: shared with `SidebarFileOperations`.
    func showFileOpFailure(_ message: String) {
        presentChalkNotice(title: nil, message: message)
    }

    // MARK: - Drag-move

    /// The FileNode currently being dragged (in-app drags stash it as the drag
    /// item's `localObject`).
    private func draggedNode(_ session: UIDropSession) -> FileNode? {
        session.localDragSession?.items.first?.localObject as? FileNode
    }

    /// A resolved drag-drop landing zone: a folder row XOR a Location's top
    /// level. `url` is the directory the dragged file moves into; `.folder`
    /// also carries the row's node so the highlight can light that row.
    private enum DropTarget {
        case folder(FileNode)
        case locationRoot(Location)
        var url: URL {
            switch self {
            case .folder(let node): return node.url
            case .locationRoot(let location): return location.url
            }
        }
    }

    /// Resolve the drop target. Header hit-testing wins (so a header drop isn't read as its section's
    /// first item); otherwise `SidebarDropPolicy` maps the row under the pointer: a folder row is that
    /// folder, a file row its parent, blank space the Location root. File rows resolving to their
    /// parent is what lets a file be dragged back out of a folder.
    private func dropTarget(_ session: UIDropSession, _ destination: IndexPath?) -> DropTarget? {
        dropTarget(at: session.location(in: collectionView), destination: destination)
    }

    /// Point-based body, so the resolution is reachable from tests (a
    /// `UIDropSession` cannot be constructed).
    private func dropTarget(at point: CGPoint, destination: IndexPath?) -> DropTarget? {
        let sections = dataSource.snapshot().sectionIdentifiers
        if let section = headerSection(at: point), section < sections.count {
            return .locationRoot(sections[section])
        }
        guard let section = destination?.section ?? sectionIndex(at: point),
              section < sections.count else { return nil }
        let location = sections[section]
        let row = destination.flatMap { dataSource.itemIdentifier(for: $0) }.map { node in
            node.isDirectory && !Self.isEmptyPlaceholder(node)
                ? SidebarDropPolicy.Row.folder(node.url)
                : SidebarDropPolicy.Row.file(node.url)
        }
        switch SidebarDropPolicy.destination(row: row, locationRoot: location.url) {
        case .locationRoot:
            return .locationRoot(location)
        case .folder(let url):
            // The highlight needs the row, so a folder that isn't in the tree
            // (a collapsed ancestor can't be) has no target to light up.
            guard let node = folderNode(at: url, in: location) else { return nil }
            return .folder(node)
        }
    }

    /// The section whose header the pointer is inside, if any.
    private func headerSection(at point: CGPoint) -> Int? {
        (0..<dataSource.snapshot().sectionIdentifiers.count).first {
            headerFrame(inSection: $0)?.contains(point) == true
        }
    }

    /// The section the pointer is in when no row is under it (blank space below
    /// a Location's rows): the last section whose header starts at or above the
    /// pointer. Sections stack vertically, so that is the enclosing one.
    private func sectionIndex(at point: CGPoint) -> Int? {
        var match: Int?
        var matchY = -CGFloat.greatestFiniteMagnitude
        for section in 0..<dataSource.snapshot().sectionIdentifiers.count {
            guard let frame = headerFrame(inSection: section),
                  frame.minY <= point.y, frame.minY > matchY else { continue }
            matchY = frame.minY
            match = section
        }
        return match
    }

    /// A section header's frame in the collection view's coordinate space. Asks
    /// the layout rather than the visible-view list so a header scrolled out of
    /// view still places its section.
    private func headerFrame(inSection section: Int) -> CGRect? {
        let kind = UICollectionView.elementKindSectionHeader
        let indexPath = IndexPath(item: 0, section: section)
        if let attributes = collectionView.collectionViewLayout
            .layoutAttributesForSupplementaryView(ofKind: kind, at: indexPath) {
            return attributes.frame
        }
        return collectionView.supplementaryView(forElementKind: kind, at: indexPath)?.frame
    }

    /// The folder row for `url` inside `location`'s tree, matched by normalized
    /// path (a directory URL has two legal spellings).
    private func folderNode(at url: URL, in location: Location) -> FileNode? {
        let path = url.standardizedFileURL.path
        return dataSource.snapshot(for: location).items.first {
            $0.isDirectory && $0.url.standardizedFileURL.path == path
        }
    }

    /// Light up `target`, clearing the other kind (a drop highlights a folder
    /// row XOR a Location header, never both at once).
    private func setDropTarget(_ target: DropTarget) {
        switch target {
        case .folder(let node):
            dropTargetLocationID = nil
            dropTargetNode = node
        case .locationRoot(let location):
            dropTargetNode = nil
            dropTargetLocationID = location.id
        }
    }

    /// Drop any drop highlight (drag left a valid target, ended, or dropped).
    private func clearDropTarget() {
        dropTargetNode = nil
        dropTargetLocationID = nil
    }

    /// Whether `node` may move into `directory`; the no-op and cycle guards are `FileMove.canMove`.
    private func canMove(_ node: FileNode, into directory: URL) -> Bool {
        FileMove.canMove(source: node.url, isDirectory: node.isDirectory, into: directory)
    }

    /// Present the folder picker to add a Location (invoked from the File menu).
    func presentAddLocationPicker() {
        // System styling on purpose: the document picker is an OS-owned sheet and cannot be themed.
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.folder])
        picker.delegate = self
        picker.allowsMultipleSelection = false
        present(picker, animated: true)
    }

    /// Present the folder picker to re-grant a Location that lost access; the
    /// pick heals the existing record instead of adding a new one.
    func presentReauthorizePicker(for id: String) {
        pendingReauthorizationID = id
        presentAddLocationPicker()
    }
}

extension SidebarViewController: UICollectionViewDelegate {
    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        guard let node = dataSource.itemIdentifier(for: indexPath) else { return }
        if Self.isEmptyPlaceholder(node) || node.isDirectory {
            // Neither the sentinel nor a folder keeps the selection pill.
            collectionView.deselectItem(at: indexPath, animated: false)
        }
        // Straight to activate(): clicking a row only ever opens or discloses
        // it. Rename is a menu action (right-click) or F2.
        activate(node)
    }

    /// The "Empty" sentinel is presentation, not a row: keyboard focus must
    /// arrow straight past it.
    func collectionView(_ collectionView: UICollectionView, canFocusItemAt indexPath: IndexPath) -> Bool {
        guard let node = dataSource.itemIdentifier(for: indexPath) else { return false }
        return !Self.isEmptyPlaceholder(node)
    }

    /// The row context menu (`rowMenu(for:)`). The "Empty" sentinel gets none; Location headers have
    /// their own (`installHeaderMenu`).
    func collectionView(
        _ collectionView: UICollectionView,
        contextMenuConfigurationForItemsAt indexPaths: [IndexPath],
        point: CGPoint
    ) -> UIContextMenuConfiguration? {
        guard indexPaths.count == 1, let indexPath = indexPaths.first,
              let node = dataSource.itemIdentifier(for: indexPath),
              !Self.isEmptyPlaceholder(node)
        else { return nil }

        return UIContextMenuConfiguration(actionProvider: { [weak self] _ in
            self?.rowMenu(for: node)
        })
    }
}

extension SidebarViewController: UICollectionViewDragDelegate {
    /// Drag file and folder rows (not headers, not the sentinel). The FileNode
    /// rides along as `localObject` for the in-app move; the URL provider makes
    /// it a well-formed drag item.
    func collectionView(
        _ collectionView: UICollectionView,
        itemsForBeginning session: UIDragSession,
        at indexPath: IndexPath
    ) -> [UIDragItem] {
        guard let node = dataSource.itemIdentifier(for: indexPath),
              !Self.isEmptyPlaceholder(node) else { return [] }
        let item = UIDragItem(itemProvider: NSItemProvider(object: node.url as NSURL))
        item.localObject = node
        return [item]
    }
}

extension SidebarViewController: UICollectionViewDropDelegate {
    /// In-app moves only; external drops are not accepted.
    func collectionView(_ collectionView: UICollectionView, canHandle session: UIDropSession) -> Bool {
        session.localDragSession != nil
    }

    func collectionView(
        _ collectionView: UICollectionView,
        dropSessionDidUpdate session: UIDropSession,
        withDestinationIndexPath destinationIndexPath: IndexPath?
    ) -> UICollectionViewDropProposal {
        guard let node = draggedNode(session),
              let target = dropTarget(session, destinationIndexPath),
              canMove(node, into: target.url) else {
            clearDropTarget()
            return UICollectionViewDropProposal(operation: .forbidden)
        }
        setDropTarget(target)
        return UICollectionViewDropProposal(operation: .move, intent: .insertIntoDestinationIndexPath)
    }

    /// Pointer left the collection view: drop the highlight so it never lingers
    /// on a folder the drag has moved away from.
    func collectionView(_ collectionView: UICollectionView, dropSessionDidExit session: UIDropSession) {
        clearDropTarget()
    }

    /// Drag finished (dropped, or cancelled outside any target): clear the highlight.
    func collectionView(_ collectionView: UICollectionView, dropSessionDidEnd session: UIDropSession) {
        clearDropTarget()
    }

    /// Move into the resolved directory through `moveFile`: a collision rejects, open tabs follow,
    /// and the reload keeps expansion.
    func collectionView(
        _ collectionView: UICollectionView,
        performDropWith coordinator: UICollectionViewDropCoordinator
    ) {
        clearDropTarget()
        guard let node = coordinator.items.first?.dragItem.localObject as? FileNode,
              let directory = dropTarget(coordinator.session, coordinator.destinationIndexPath)?.url,
              canMove(node, into: directory) else { return }
        let destination = directory.appendingPathComponent(node.url.lastPathComponent)
        // Next runloop tick: `moveFile` applies animated diffable snapshots,
        // and doing that synchronously inside the drop coordinator races the
        // collection view's own drop teardown ("invalid update" territory).
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            // Two rejections, arriving at different times: the name collision is the synchronous
            // verdict, an I/O failure comes back through the completion after the off-main move.
            let rejected = { [weak self] in
                self?.showFileOpFailure("Couldn\u{2019}t move \u{201C}\(node.url.lastPathComponent)\u{201D} there. A file with that name may already exist.")
            }
            let started = self.moveFile(
                from: node.url, to: destination, actionName: "Move", animated: true,
                completion: { moved in if !moved { rejected() } })
            if !started { rejected() }
        }
    }
}

extension SidebarViewController: UIDocumentPickerDelegate {
    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        guard let url = urls.first else { return }
        if let id = pendingReauthorizationID {
            pendingReauthorizationID = nil
            onReauthorizeLocation?(id, url)
        } else {
            onAddLocation?(url)
        }
        reload()
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        pendingReauthorizationID = nil
    }
}

#if DEBUG
extension SidebarViewController {
    /// Expands every directory row in every section, for the audit harness.
    /// Expanding can reveal newly-loaded grandchildren, so re-walk the
    /// snapshots until a pass finds nothing left to expand (bounded to 8).
    func expandAll() {
        loadViewIfNeeded() // the sidebar starts hidden; dataSource is built in viewDidLoad
        for _ in 0..<8 {
            var expandedAny = false
            for location in dataSource.snapshot().sectionIdentifiers {
                var tree = dataSource.snapshot(for: location)
                let collapsed = tree.items.filter { $0.isDirectory && !tree.isExpanded($0) }
                guard !collapsed.isEmpty else { continue }
                for node in collapsed { loadChildren(forExpanding: node) }
                tree = dataSource.snapshot(for: location)
                tree.expand(tree.items.filter { $0.isDirectory })
                dataSource.apply(tree, to: location, animatingDifferences: false)
                expandedAny = true
            }
            if !expandedAny { break }
        }
    }

    /// New File / New Folder, so tests can assert the create paths' threading contract.
    func createFileForTesting(in directory: URL) { createFile(in: directory) }
    func createFolderForTesting(in directory: URL) { createFolder(in: directory) }

    /// Drive the expansion toggle exactly as a row click would (crash-guard tests).
    func toggleFolderExpansionForTesting(_ node: FileNode) {
        toggleFolderExpansion(node)
    }

    func isExpandedForTesting(_ node: FileNode) -> Bool {
        isExpanded(node)
    }

    /// Keyboard-nav hook (SidebarKeyboardNavTests): drive fold-key handling
    /// with an explicit node; unit tests can't move real focus.
    func handleFoldKeyForTesting(_ node: FileNode, expanding: Bool) {
        handleFoldKey(node, expanding: expanding)
    }

    /// The static command table itself, bypassing the focused-row guard: the
    /// keyboard-nav tests assert what the sidebar claims, and that Return /
    /// keypad-Enter are not, without needing real focus.
    static var treeKeyCommandsForTesting: [UIKeyCommand] { treeKeyCommands }

    /// Reload-race hook (SidebarReloadRaceTests): capture and build now (the stale input) and return
    /// the deferred apply, so a test can change expansion in between like a user racing the build.
    func makeStaleReloadApplyForTesting() -> () -> Void {
        let built = Self.buildSections(captureReloadInput())
        return { [self] in applySections(built, animated: false) }
    }

    /// Whether a node is anywhere in a section snapshot (the reload-race
    /// tests assert lazily loaded children survive a stale apply).
    func containsNodeForTesting(_ node: FileNode) -> Bool {
        sectionTree(containing: node) != nil
    }

    func nodeForTesting(at indexPath: IndexPath) -> FileNode? {
        dataSource.itemIdentifier(for: indexPath)
    }

    func indexPathForTesting(_ node: FileNode) -> IndexPath? {
        dataSource.indexPath(for: node)
    }

    /// A cell straight out of the data source, before any layout pass. It must already be fully
    /// configured, or the row would remeasure on screen.
    func dequeuedCellForTesting(at indexPath: IndexPath) -> UICollectionViewCell? {
        dataSource.collectionView(collectionView, cellForItemAt: indexPath)
    }

    /// The panel's frame in the sidebar view's own coordinates.
    var panelFrameForTesting: CGRect { panel.frame }

    /// The first tree row's frame in the sidebar view's coordinates, nil with no rows. Read from the
    /// layout's attributes so an off-screen row still reports.
    var firstRowFrameForTesting: CGRect? {
        guard let collectionView,
              collectionView.numberOfSections > 0,
              collectionView.numberOfItems(inSection: 0) > 0,
              let attributes = collectionView.collectionViewLayout
                  .layoutAttributesForItem(at: IndexPath(item: 0, section: 0))
        else { return nil }
        return collectionView.convert(attributes.frame, to: view)
    }

    /// The first area header's frame in the sidebar view's coordinates, nil with no Locations: where
    /// the list's content starts (`libraryListStartsAtTheChromeFloor`). Read from the layout's
    /// attributes so an off-screen header still reports.
    var firstHeaderFrameForTesting: CGRect? {
        guard let collectionView, collectionView.numberOfSections > 0,
              // A scrolled list says nothing about where the list starts.
              abs(collectionView.contentOffset.y + collectionView.contentInset.top) < 0.5,
              let attributes = collectionView.collectionViewLayout
                  .layoutAttributesForSupplementaryView(
                      ofKind: UICollectionView.elementKindSectionHeader,
                      at: IndexPath(item: 0, section: 0))
        else { return nil }
        return collectionView.convert(attributes.frame, to: view)
    }

    /// The Library list's scroll offset (transition tests: a chrome round
    /// trip must hand the list back exactly where the reader left it).
    var libraryScrollOffsetForTesting: CGFloat {
        collectionView?.contentOffset.y ?? 0
    }

    /// Drive the scroll position the way a reader's scroll would leave it.
    func setLibraryScrollOffsetForTesting(_ offset: CGFloat) {
        collectionView?.contentOffset.y = offset
    }

    /// Drag-move drop resolution without a `UIDropSession`: the directory
    /// a drop at `point` over row `destination` would land in, nil when the
    /// position is not a target.
    func dropDestinationForTesting(at point: CGPoint, destination: IndexPath?) -> URL? {
        dropTarget(at: point, destination: destination)?.url
    }

    /// The collection view, so drop tests can turn rows into points.
    var collectionViewForTesting: UICollectionView { collectionView }

    /// The URL behind a row, for locating rows by name in tests.
    func itemURLForTesting(at indexPath: IndexPath) -> URL? {
        dataSource.itemIdentifier(for: indexPath)?.url
    }

    /// Fold a location from its header view, exactly as a header tap does.
    func toggleFoldForTesting(onHeader view: UIView) { toggleFold(onHeader: view) }

    /// Location fold state, for the titlebar-band replay tests.
    func isLocationCollapsedForTesting(_ id: String) -> Bool {
        collapsedLocationIDs.contains(id)
    }

    /// What an area header's trailing slot shows, read from the live supplementary view.
    func headerSlotForTesting(section: Int) -> (count: String, showsChevron: Bool)? {
        let kind = UICollectionView.elementKindSectionHeader
        collectionView.layoutIfNeeded()
        guard let cell = collectionView.supplementaryView(
            forElementKind: kind, at: IndexPath(item: 0, section: section))
            as? SidebarHeaderCell else { return nil }
        return cell.slotStateForTesting
    }

    /// Whether the Library paints its row pill for a node: the mark shared by
    /// selection, keyboard focus and the open document.
    func rowIsMarkedForTesting(_ node: FileNode) -> Bool {
        guard let indexPath = dataSource.indexPath(for: node),
              let cell = collectionView.cellForItem(at: indexPath) as? UICollectionViewListCell
        else { return false }
        return cell.backgroundConfiguration?.backgroundColor == .chalkRowSelection
    }
}
#endif

/// The Library's list ignores the safe area. On Mac the column's safe-area top is the titlebar,
/// which comes and goes with full screen, and every UIKit mechanism that reads it moved the rows:
/// section insets, cell layout margins, and UICollectionView's anchor restore, which re-scrolled the
/// list by one titlebar. `contentInsetAdjustmentBehavior = .never` does not cover the anchor restore.
/// The tree's own top clearance places everything inside the panel.
/// See docs/issues/2026-08-18-sidebar-gap-after-fullscreen.md.
final class SafeAreaFreeCollectionView: UICollectionView {
    override var safeAreaInsets: UIEdgeInsets { .zero }
}
