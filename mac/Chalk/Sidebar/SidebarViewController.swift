import AppKit
import UniformTypeIdentifiers
import ChalkKit
import os

/// A file or folder row's backing object. A class, not the `FileNode` value:
/// `NSOutlineView` keys expansion, selection and reloads on item identity, so
/// an object kept across reloads keeps its row state. `isExpanded` is the
/// model's truth, mirrored from the outline view's expand/collapse
/// notifications and re-applied when a collapsed parent opens again.
final class LibraryRowItem {
    var node: FileNode
    /// nil: never read (a folder two levels under a collapsed one); []: read
    /// and empty. A collapsed folder's children exist so its chevron works.
    var children: [LibraryRowItem]?
    var isExpanded = false
    weak var parent: LibraryRowItem?
    weak var section: LibraryLocationItem?

    init(node: FileNode, section: LibraryLocationItem?, parent: LibraryRowItem?) {
        self.node = node
        self.section = section
        self.parent = parent
    }
}

/// A Location's header row. Always expanded in the outline view: a folded
/// Location has no children instead.
final class LibraryLocationItem {
    var location: Location
    var children: [LibraryRowItem] = []
    /// Top-level entries, for the header's count (not a recursive count).
    var count = 0

    init(location: Location) { self.location = location }
}

/// The Library: each Location is a header with an expandable file tree.
/// Folders disclose, documents open, assets preview. Locations are added
/// through the folder panel (security-scoped bookmark).
final class SidebarViewController: NSViewController {
    /// Supplies the current Locations (set by the coordinator before the view loads).
    var locationsProvider: (() -> [Location])?
    /// Clicked a document row (`.md`/`.tex`/`.qmd`).
    var onOpenFile: ((URL) -> Void)?
    /// Clicked an asset row (image/PDF). Binary, so it never reaches the
    /// editor: the shell shows a preview instead.
    var onPreviewFile: ((URL) -> Void)?
    /// "Open in New Tab": always adds a tab, unlike `onOpenFile`, which reuses
    /// the current tab when it is unmodified (browse-reuse).
    var onOpenFileInNewTab: ((URL) -> Void)?
    /// "Open in New Window": a fresh window showing this file.
    var onOpenFileInNewWindow: ((URL) -> Void)?
    /// Picked a folder to add as a Location.
    var onAddLocation: ((URL) -> Void)?
    /// Chose "Remove from Window" on a Location header.
    var onRemoveLocation: ((String) -> Void)?
    /// Re-picked the folder for a Location that lost sandbox access; the
    /// coordinator re-bookmarks it in place via `LocationStore.reauthorize`.
    var onReauthorizeLocation: ((_ id: String, _ url: URL) -> Void)?
    /// Location id awaiting a folder re-pick: routes the next panel result to
    /// `onReauthorizeLocation` instead of `onAddLocation`.
    private var pendingReauthorizationID: String?
    /// Created a file via a context menu; the coordinator opens it in a tab.
    var onOpenCreatedFile: ((URL) -> Void)?
    /// A file or folder was renamed or drag-moved on disk. The coordinator
    /// retargets any open tab at or under `from`, keeping unsaved edits.
    var onFileMoved: ((_ from: URL, _ to: URL) -> Void)?
    #if DEBUG
    /// Fires on main after any sidebar file operation finishes, success or
    /// failure. The operations run off the main thread (`CoordinatedFileMove`,
    /// `runFileWork`), so tests await this before asserting on-disk state.
    var onFileWorkFinishedForTesting: (() -> Void)?
    /// Same seam for the grandchild reads a folder expansion starts
    /// (`loadGrandchildren`). Fires on main once the reads land.
    var onExpansionWorkFinishedForTesting: (() -> Void)?
    /// Whether the last grandchild read ran on the main thread (SidebarFileWorkThreadingTests).
    static var lastExpansionReadRanOnMainThread: Bool?
    /// The last failure notice, whether or not a window was there to sheet it on.
    private(set) var lastNoticeMessageForTesting: String?
    #endif

    /// The Library's surface: a flat tone-on-tone panel, flush with the
    /// column's edges, separated from the editor by tone alone.
    private let panel = ChalkGlassView(style: .paper, cornerRadius: 0)

    /// Where the list's first area header belongs, in this view controller's
    /// coordinates: the chrome floor, where the titlebar ends. The host owns
    /// the number because only it can read its live chrome.
    ///
    /// Asked at every layout pass, never pushed: a column slide moves this
    /// view without laying it out, so a pushed value can describe a position
    /// that no longer exists.
    var treeTopProvider: (() -> CGFloat?)?

    /// Where the tree starts inside the panel: the host's datum in panel
    /// coordinates, or the fallback when there is no window (unit tests).
    ///
    /// Applied to the scroll view's frame, never its content: content that
    /// moves with the chrome is what re-anchored the Catalyst list
    /// (docs/issues/2026-08-18-sidebar-gap-after-fullscreen.md).
    func treeTopClearance() -> CGFloat {
        guard let top = treeTopProvider?(), view.window != nil else {
            return Self.treeTopPadding
        }
        return max(Self.treeTopPadding, top - panel.frame.minY)
    }

    /// Fallback clearance with no window: an unhosted column has no titlebar.
    static let treeTopPadding: CGFloat = 24
    private var treeTopConstraint: NSLayoutConstraint?

    /// Internal, not private: the rename editor and the file operations reach
    /// the rows through it.
    let outlineView = LibraryOutlineView()
    let scrollView = NSScrollView()
    /// Shown centered when the Library has no Locations at all.
    private let emptyStateLabel = NSTextField(wrappingLabelWithString: "")

    /// The list's bottom fade: rows dissolve before reaching the floating
    /// pill instead of sliding under its glass. The bottom content inset is
    /// what lets the last row clear the pill.
    private let listFade = CAGradientLayer()

    /// The model: one entry per Location, in Library order.
    private(set) var sections: [LibraryLocationItem] = []

    /// The document the editor is showing, marked with the selection pill.
    /// Pushed by the host on every tab change; nil when no file-backed tab is active.
    private var openDocumentURL: URL? {
        didSet {
            guard oldValue != openDocumentURL else { return }
            repaintRows(for: [oldValue, openDocumentURL].map { url in url.flatMap { self.node(at: $0) } })
        }
    }

    /// Location ids the user has folded shut, for this session only. A folded
    /// Location shows only its header row.
    private var collapsedLocationIDs: Set<String> = []

    /// Undo for sidebar file moves. On the responder chain when the Library
    /// has focus, while the editor's own Cmd+Z (CodeMirror history) wins when
    /// the editor has focus. `moveFile` focuses the tree after a move so Cmd+Z
    /// lands here. Internal, not private: `SidebarFileOperations` registers
    /// undo for Duplicate and Move to Trash.
    let fileUndoManager = UndoManager()
    override var undoManager: UndoManager? { fileUndoManager }

    /// The row being renamed in place; its cell shows a text field. Internal
    /// so `SidebarRenameEditor` (same type, other file) drives the lifecycle.
    var renamingNode: FileNode?

    /// The folder row under the pointer during a drag, lit as the landing
    /// zone. Mutually exclusive with `dropTargetLocationID`.
    private var dropTargetNode: FileNode? {
        didSet {
            guard oldValue != dropTargetNode else { return }
            repaintRows(for: [oldValue, dropTargetNode])
        }
    }

    /// The Location header under the pointer during a drag.
    private var dropTargetLocationID: String? {
        didSet {
            guard oldValue != dropTargetLocationID else { return }
            refreshHeaderHighlights()
        }
    }

    /// The node in flight during an in-app drag (`draggingSession(_:willBeginAt:forItems:)`).
    private var draggedNode: FileNode?

    /// The in-app drag's pasteboard type: the row's path, so a drop knows it
    /// came from this tree and not from Finder.
    static let rowPasteboardType = NSPasteboard.PasteboardType("com.huleux.chalk.library-row")

    private static let log = Logger(subsystem: "com.huleux.chalk", category: "sidebar")

    // MARK: - Row pills

    /// A row's paint: colour and geometry of the pill, nil colour for idle.
    struct RowBackground: Equatable {
        var backgroundColor: NSColor?
        var cornerRadius: CGFloat
        static let clear = RowBackground(backgroundColor: nil, cornerRadius: 0)
    }

    /// The drop-target pill, shared by folder rows and Location headers so
    /// both read as one landing zone.
    private static func dropPillBackground() -> RowBackground {
        RowBackground(backgroundColor: .chalkRowSelection, cornerRadius: ChalkMetrics.rowCornerRadius)
    }

    /// The row pill for a cell state. Priority: drop target > selected or
    /// focused > hovered > idle; colour only, one geometry.
    static func rowBackground(
        isDropTarget: Bool, isSelected: Bool, isFocused: Bool, isHoveredOrHighlighted: Bool
    ) -> RowBackground {
        if isDropTarget { return dropPillBackground() }
        if isSelected || isFocused {
            return RowBackground(backgroundColor: .chalkRowSelection, cornerRadius: ChalkMetrics.rowCornerRadius)
        }
        if isHoveredOrHighlighted {
            return RowBackground(backgroundColor: .chalkRowHoverBackground, cornerRadius: ChalkMetrics.rowCornerRadius)
        }
        return .clear
    }

    /// Sentinel leaf shown under a Location with no files. Its hidden marker
    /// name is one `FileTree` never enumerates, so it cannot collide with a
    /// real file.
    private static let emptyMarkerName = ".chalk-empty-location-placeholder"
    private static func emptyPlaceholder(for location: Location) -> FileNode {
        // Encode the Location id: two Locations on the same empty folder still need distinct items.
        let url = location.url.appendingPathComponent("\(emptyMarkerName).\(location.id)")
        return FileNode(url: url, name: "Empty", isDirectory: false)
    }
    static func isEmptyPlaceholder(_ node: FileNode) -> Bool {
        node.url.lastPathComponent.hasPrefix(emptyMarkerName)
    }

    init() {
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func loadView() {
        let root = ChromeToneView()
        root.onAppearanceChange = { [weak self] in self?.outlineView.needsDisplay = true }
        view = root
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.setAccessibilityIdentifier("LibrarySidebar")
        configureOutlineView()
        reload()
    }

    /// One line for the window diagnostics (`RootSplitViewController.stateSummary`).
    var diagnosticSummary: String {
        guard isViewLoaded else { return "sidebar=notLoaded" }
        let rows = sections.reduce(0) { $0 + Self.countItems($1.children) }
        let panelFrame = view.window == nil ? panel.frame : view.convert(panel.frame, to: nil)
        return "locations=\(sections.count) rows=\(rows)"
            + " emptyLabel=\(emptyStateLabel.isHidden ? "hidden" : "SHOWN")"
            + " panel=\(Int(panelFrame.minX)),\(Int(panelFrame.minY)) \(Int(panelFrame.width))x\(Int(panelFrame.height))"
    }

    private static func countItems(_ items: [LibraryRowItem]) -> Int {
        items.reduce(0) { $0 + 1 + countItems($1.children ?? []) }
    }

    // MARK: - Reload (capture on main, build anywhere, apply on main)

    /// Rebuild every Location's tree from disk, keeping expansion. Lazy: only
    /// the top level plus one level under each folder (so chevrons work);
    /// deeper levels load on expansion.
    ///
    /// This synchronous entry is for callers that want rows on the next line
    /// (the panel, tests); notification triggers use `scheduleReload()`, which
    /// builds off-main because `contentsOfDirectory` on an iCloud Location can
    /// block on the ubiquity daemon indefinitely.
    func reload(animated: Bool = false) {
        guard isViewLoaded else { return } // viewDidLoad calls reload() once loaded
        // A sync reload supersedes the async lane: the generation bump kills
        // any build in flight, and the cancel stops a pending scheduleReload
        // from running a duplicate up to 100ms later.
        pendingReload?.cancel()
        pendingReload = nil
        reloadGeneration += 1
        applySections(Self.buildSections(captureReloadInput()), animated: animated)
    }

    /// Coalesced, off-main reload for notification storms (library change,
    /// file move, foreground, each fanned out to every window) and for the
    /// refresh after a file operation (`delay: 0`). What matters is that the
    /// build leaves the main thread; `delay` only coalesces.
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
        let expandedByLocation: [String: Set<FileNode>]
    }

    /// A built tree, value types only, so the build can run on any queue.
    struct BuiltTree {
        var node: FileNode
        /// Same meaning as `LibraryRowItem.children`.
        var children: [BuiltTree]?
        var isExpanded: Bool
    }

    struct BuiltSection {
        let location: Location
        var trees: [BuiltTree]
        let count: Int
    }

    struct BuiltSections {
        var sections: [BuiltSection]
        let hasLocations: Bool
    }

    private func captureReloadInput() -> ReloadInput {
        let locations = locationsProvider?() ?? []
        // Remember expansion per section before the rebuild wipes it.
        var expandedByLocation: [String: Set<FileNode>] = [:]
        for section in sections {
            var expanded = Set<FileNode>()
            Self.walk(section.children) { item in
                if item.node.isDirectory, item.isExpanded { expanded.insert(item.node) }
            }
            expandedByLocation[section.location.id] = expanded
        }
        return ReloadInput(locations: locations, collapsed: collapsedLocationIDs,
                           expandedByLocation: expandedByLocation)
    }

    private static func walk(_ items: [LibraryRowItem], _ body: (LibraryRowItem) -> Void) {
        for item in items {
            body(item)
            walk(item.children ?? [], body)
        }
    }

    /// Pure: value types in, value types out. Every FileTree walk lives here.
    private static func buildSections(_ input: ReloadInput) -> BuiltSections {
        var sections: [BuiltSection] = []
        for location in input.locations {
            // Folded: header only. One top-level read still runs, for the header's count.
            if input.collapsed.contains(location.id) {
                sections.append(BuiltSection(location: location, trees: [],
                                             count: FileTree.children(of: location.url).count))
                continue
            }
            let expanded = input.expandedByLocation[location.id] ?? []
            func build(childrenOf directory: URL) -> [BuiltTree] {
                FileTree.children(of: directory).map { node in
                    guard node.isDirectory else { return BuiltTree(node: node, children: nil, isExpanded: false) }
                    if expanded.contains(node) {
                        return BuiltTree(node: node, children: build(childrenOf: node.url), isExpanded: true)
                    }
                    // One level ahead so the chevron shows; deeper levels load on expansion.
                    let ahead = FileTree.children(of: node.url).map {
                        BuiltTree(node: $0, children: nil, isExpanded: false)
                    }
                    return BuiltTree(node: node, children: ahead, isExpanded: false)
                }
            }
            var trees = build(childrenOf: location.url)
            let count = trees.count
            // A Location with no files gets an "Empty" sentinel row.
            if trees.isEmpty {
                trees = [BuiltTree(node: Self.emptyPlaceholder(for: location), children: nil, isExpanded: false)]
            }
            sections.append(BuiltSection(location: location, trees: trees, count: count))
        }
        return BuiltSections(sections: sections, hasLocations: !input.locations.isEmpty)
    }

    /// True when the Location list itself has to be rebuilt: the Locations
    /// were added, removed, or reordered. Pure, so the "don't blank the tree
    /// on an ordinary reload" rule is unit-testable.
    static func sectionsNeedApply(_ built: [Location], _ current: [Location]) -> Bool {
        built != current
    }

    private func applySections(_ built: BuiltSections, animated: Bool) {
        emptyStateLabel.isHidden = built.hasLocations
        // A scheduled build used expansion state captured at fire time, and
        // the user may have folded or unfolded since (`toggleFolderExpansion`
        // and `loadGrandchildren` touch the live tree directly without bumping
        // reloadGeneration, on purpose). Overlay the current state onto the
        // built trees so a stale build never reverts an interaction. A no-op
        // for the synchronous reload().
        var built = built
        let liveByID = Dictionary(sections.map { ($0.location.id, $0) }, uniquingKeysWith: { a, _ in a })
        for index in built.sections.indices {
            if let live = liveByID[built.sections[index].location.id] {
                Self.mergeExpansion(from: live.children, into: &built.sections[index].trees)
            }
        }

        if Self.sectionsNeedApply(built.sections.map(\.location), sections.map(\.location)) {
            // A Location came or went: rebuild the list (never animated, the
            // whole tree re-dequeues) and re-open every header.
            sections = built.sections.map { section in
                let item = liveByID[section.location.id] ?? LibraryLocationItem(location: section.location)
                item.location = section.location
                item.count = section.count
                reconcile(parent: .section(item), with: section.trees, rowsLive: false, animated: false)
                return item
            }
            outlineView.reloadData()
            for section in sections {
                outlineView.expandItem(section)
                syncExpansion(of: section.children)
            }
        } else {
            outlineView.beginUpdates()
            for (section, builtSection) in zip(sections, built.sections) {
                section.count = builtSection.count
                reconcile(parent: .section(section), with: builtSection.trees, rowsLive: true, animated: animated)
            }
            outlineView.endUpdates()
            for section in sections { syncExpansion(of: section.children) }
        }
        refreshHeaderSlots()
        view.needsLayout = true
    }

    /// Overlay the live expansion state onto a freshly built tree: a folder in
    /// both keeps its current fold state. A folder expanded live that the
    /// build only walked one level deep takes its children from the live
    /// tree. Folders only the build knows keep its state.
    private static func mergeExpansion(from live: [LibraryRowItem], into trees: inout [BuiltTree]) {
        var liveByNode: [FileNode: LibraryRowItem] = [:]
        walk(live) { if $0.node.isDirectory { liveByNode[$0.node] = $0 } }
        func overlay(_ trees: inout [BuiltTree]) {
            for index in trees.indices where trees[index].node.isDirectory {
                if let item = liveByNode[trees[index].node] {
                    if item.isExpanded {
                        if (trees[index].children ?? []).isEmpty, let children = item.children, !children.isEmpty {
                            // From the live tree, not disk: this runs inside the
                            // main-thread apply, where an iCloud read can block.
                            // The next reload corrects anything stale.
                            trees[index].children = children.map(snapshot)
                        }
                        trees[index].isExpanded = true
                    } else if trees[index].isExpanded {
                        trees[index].isExpanded = false
                    }
                }
                if trees[index].children != nil { overlay(&trees[index].children!) }
            }
        }
        overlay(&trees)
    }

    /// A live subtree as build output, flags included.
    private static func snapshot(_ item: LibraryRowItem) -> BuiltTree {
        BuiltTree(node: item.node, children: item.children?.map(snapshot), isExpanded: item.isExpanded)
    }

    /// A row's parent: the Location for a top-level row, else the folder.
    /// The model is written through the reference, never through an inout
    /// borrow: the table reads `children` back during its own row updates,
    /// and a live inout access there is an exclusivity violation.
    private enum LibraryParent {
        case section(LibraryLocationItem)
        case folder(LibraryRowItem)

        var children: [LibraryRowItem] {
            get {
                switch self {
                case .section(let section): return section.children
                case .folder(let folder): return folder.children ?? []
                }
            }
            nonmutating set {
                switch self {
                case .section(let section): section.children = newValue
                case .folder(let folder): folder.children = newValue
                }
            }
        }

        var section: LibraryLocationItem? {
            switch self {
            case .section(let section): return section
            case .folder(let folder): return folder.section
            }
        }

        var folder: LibraryRowItem? {
            if case .folder(let folder) = self { return folder }
            return nil
        }

        /// What the table calls the parent.
        var object: Any {
            switch self {
            case .section(let section): return section
            case .folder(let folder): return folder
            }
        }
    }

    /// Land `built` under `parent`, keeping every item that survives (its
    /// identity is what keeps the outline view's state). The model is written
    /// first, in its final shape, then the table takes the removals (old
    /// offsets) and insertions (new offsets) when `rowsLive` (the parent's
    /// rows are on screen). A folder whose rows are not live has its subtree
    /// reconciled silently and is told to forget its cached children.
    private func reconcile(parent: LibraryParent, with built: [BuiltTree],
                           rowsLive: Bool, animated: Bool) {
        guard let section = parent.section else { return }
        let live = parent.children
        let difference = built.map(\.node).difference(from: live.map(\.node))
        var removals = IndexSet()
        var insertions = IndexSet()
        for change in difference {
            switch change {
            case .remove(let offset, _, _): removals.insert(offset)
            case .insert(let offset, _, _): insertions.insert(offset)
            }
        }
        var next = live
        for offset in removals.reversed() { next.remove(at: offset) }
        for offset in insertions {
            next.insert(Self.makeItem(built[offset], section: section, parent: parent.folder), at: offset)
        }
        parent.children = next
        if rowsLive {
            let animation: NSTableView.AnimationOptions = animated ? [.effectFade, .slideUp] : []
            if !removals.isEmpty {
                outlineView.removeItems(at: removals, inParent: parent.object, withAnimation: animation)
            }
            if !insertions.isEmpty {
                outlineView.insertItems(at: insertions, inParent: parent.object, withAnimation: animation)
            }
        }

        for (offset, (item, tree)) in zip(next, built).enumerated() {
            item.node = tree.node
            guard tree.node.isDirectory, !insertions.contains(offset) else { continue }
            // Not walked by the build: keep what the live tree has.
            guard let builtChildren = tree.children else { continue }
            let known = outlineView.row(forItem: item) >= 0
            let childRowsLive = rowsLive && item.isExpanded && known
            reconcile(parent: .folder(item), with: builtChildren, rowsLive: childRowsLive, animated: animated)
            if !childRowsLive, known {
                // Known to the table but shut: forget the cached subtree so
                // the next expansion asks again.
                outlineView.reloadItem(item, reloadChildren: true)
            }
            if item.isExpanded != tree.isExpanded {
                if rowsLive, known {
                    // Through the table, which mirrors the flag back.
                    if tree.isExpanded { outlineView.expandItem(item) } else { outlineView.collapseItem(item) }
                } else {
                    item.isExpanded = tree.isExpanded
                }
            }
        }
    }

    private static func makeItem(_ tree: BuiltTree, section: LibraryLocationItem, parent: LibraryRowItem?) -> LibraryRowItem {
        let item = LibraryRowItem(node: tree.node, section: section, parent: parent)
        item.isExpanded = tree.isExpanded
        item.children = tree.children?.map { makeItem($0, section: section, parent: item) }
        return item
    }

    /// Make the table agree with the model's expansion flags under a parent
    /// whose rows just became live (a reload, or a parent opening).
    private func syncExpansion(of items: [LibraryRowItem]) {
        for item in items where item.node.isDirectory {
            guard outlineView.row(forItem: item) >= 0 else { continue }
            if item.isExpanded, !outlineView.isItemExpanded(item) {
                outlineView.expandItem(item)
            } else if !item.isExpanded, outlineView.isItemExpanded(item) {
                outlineView.collapseItem(item)
            }
            if item.isExpanded { syncExpansion(of: item.children ?? []) }
        }
    }

    // MARK: - Expansion

    /// Lazy-load grandchildren when a folder expands, so its child folders
    /// show working chevrons.
    private func loadChildren(forExpanding item: LibraryRowItem) {
        guard let section = item.section else { return }
        let folders = (item.children ?? []).filter { $0.node.isDirectory && ($0.children ?? []).isEmpty }
        guard !folders.isEmpty else { return }
        loadGrandchildren(of: folders.map(\.node), in: section)
    }

    /// One directory read per revealed subfolder, off the main thread, spliced
    /// in when it lands. The expansion never waits: the build already loaded
    /// the opened folder's children, so this only gives the revealed
    /// subfolders working chevrons. Off-main because each read on an iCloud
    /// Location can block on the ubiquity daemon.
    private func loadGrandchildren(of folders: [FileNode], in section: LibraryLocationItem) {
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
                for (folder, children) in loaded where !children.isEmpty {
                    // Re-check against the live tree: a reload may have landed
                    // while the reads ran and already carried these children.
                    guard let item = self.item(for: folder, in: section),
                          (item.children ?? []).isEmpty else { continue }
                    item.children = children.map { LibraryRowItem(node: $0, section: section, parent: item) }
                    if self.outlineView.row(forItem: item) >= 0 {
                        self.outlineView.reloadItem(item, reloadChildren: true)
                    }
                }
            }
        }
    }

    /// Expand or collapse a folder when its row is clicked. The table's
    /// will-expand hook loads the revealed subfolders' children.
    private func toggleFolderExpansion(_ node: FileNode) {
        guard let item = item(for: node) else { return }
        if item.isExpanded {
            outlineView.collapseItem(item)
        } else {
            outlineView.expandItem(item)
        }
        repaintRows(for: [node])
    }

    /// Whether `node` is expanded in whichever section holds it.
    private func isExpanded(_ node: FileNode) -> Bool {
        item(for: node)?.isExpanded ?? false
    }

    /// The live item for `node`, wherever it sits (a row under a collapsed
    /// folder has no row but is still in the model).
    func item(for node: FileNode) -> LibraryRowItem? {
        for section in sections {
            if let hit = item(for: node, in: section) { return hit }
        }
        return nil
    }

    private func item(for node: FileNode, in section: LibraryLocationItem) -> LibraryRowItem? {
        var found: LibraryRowItem?
        Self.walk(section.children) { if found == nil, $0.node == node { found = $0 } }
        return found
    }

    /// The node for a URL, if the tree lists it.
    private func node(at url: URL) -> FileNode? {
        guard isViewLoaded else { return nil }
        var found: FileNode?
        for section in sections {
            Self.walk(section.children) { if found == nil, $0.node.url == url { found = $0.node } }
        }
        return found
    }

    // MARK: - Activation and keys

    /// The activation path shared by row clicks and the keyboard's Space: the
    /// sentinel is inert, folders toggle, files select their row (so the pill
    /// marks it even from the keyboard) and open.
    func activate(_ node: FileNode) {
        guard !Self.isEmptyPlaceholder(node) else { return }
        // Any other row ends an in-flight rename first, discarding it, so two
        // rows never both carry the selection pill. A click inside the live
        // field (same row) leaves the editor open.
        if let renaming = renamingNode, renaming != node {
            cancelRename()
        }
        if node.isDirectory {
            toggleFolderExpansion(node)
            // Neither the sentinel nor a folder keeps the selection pill.
            outlineView.deselectAll(nil)
        } else {
            if let item = item(for: node) {
                let row = outlineView.row(forItem: item)
                if row >= 0 { outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false) }
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

    /// The row the keyboard is on: the selection.
    private func selectedNode() -> FileNode? {
        let row = outlineView.selectedRow
        guard row >= 0 else { return nil }
        return (outlineView.item(atRow: row) as? LibraryRowItem)?.node
    }

    private func handleKeyClaim(_ claim: LibraryOutlineView.KeyClaim) -> Bool {
        guard let node = selectedNode() else { return false }
        switch claim {
        case .rename: beginRename(node)
        case .activate: activate(node)
        case .fold: handleFoldKey(node, expanding: false)
        case .unfold: handleFoldKey(node, expanding: true)
        }
        return true
    }

    @objc private func rowClicked(_ sender: Any?) {
        handleClick(row: outlineView.clickedRow)
    }

    /// A click on a row: a Location header folds, a file or folder row activates.
    private func handleClick(row: Int) {
        guard row >= 0 else { return }
        switch outlineView.item(atRow: row) {
        case let section as LibraryLocationItem:
            toggleFold(locationID: section.location.id)
        case let item as LibraryRowItem:
            activate(item.node)
        default:
            break
        }
    }

    private func configure(_ header: LibraryHeaderCellView, for section: LibraryLocationItem) {
        header.configure(location: section.location, isFirst: section === sections.first,
                         count: section.count,
                         collapsed: collapsedLocationIDs.contains(section.location.id))
    }

    // MARK: - The panel and the list

    private func configureOutlineView() {
        // The panel is flat and flush, so the column behind it carries the
        // same tone: anything the panel cannot reach (a slide in flight)
        // still reads as sidebar.
        panel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(panel)

        let column = NSTableColumn(identifier: .init("library"))
        column.resizingMask = .autoresizingMask
        outlineView.addTableColumn(column)
        outlineView.outlineTableColumn = column
        outlineView.headerView = nil
        outlineView.style = .plain
        outlineView.rowHeight = ChalkMetrics.sidebarRowHeight
        outlineView.intercellSpacing = .zero
        outlineView.indentationPerLevel = 0 // the cell indents itself
        outlineView.indentationMarkerFollowsCell = false
        outlineView.selectionHighlightStyle = .none
        outlineView.backgroundColor = .clear
        outlineView.focusRingType = .none
        outlineView.allowsEmptySelection = true
        outlineView.allowsMultipleSelection = false
        outlineView.usesAlternatingRowBackgroundColors = false
        outlineView.floatsGroupRows = false
        outlineView.autoresizesOutlineColumn = false
        outlineView.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        outlineView.dataSource = self
        outlineView.delegate = self
        outlineView.target = self
        outlineView.action = #selector(rowClicked(_:))
        outlineView.onKeyClaim = { [weak self] claim in self?.handleKeyClaim(claim) ?? false }
        outlineView.onMenuForRow = { [weak self] row in self?.menu(forRow: row) }
        outlineView.onDraggingExited = { [weak self] in self?.clearDropTarget() }
        // In-app drag-move of rows onto folders and Location headers.
        outlineView.registerForDraggedTypes([Self.rowPasteboardType])
        outlineView.setDraggingSourceOperationMask(.move, forLocal: true)
        outlineView.setDraggingSourceOperationMask([], forLocal: false)
        outlineView.draggingDestinationFeedbackStyle = .none

        scrollView.documentView = outlineView
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        // The tree clears the chrome through its frame, never its content.
        scrollView.automaticallyAdjustsContentInsets = false
        // The pill floats over the panel's bottom-leading corner, so the list
        // must scroll clear of it.
        scrollView.contentInsets = NSEdgeInsets(
            top: 0, left: 0, bottom: ChalkMetrics.footerPillHeight + ChalkMetrics.footerPillMargin * 2, right: 0)
        scrollView.scrollerInsets = NSEdgeInsets(top: 0, left: 0, bottom: scrollView.contentInsets.bottom, right: 0)
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.wantsLayer = true
        listFade.colors = [NSColor.white.cgColor, NSColor.white.cgColor, NSColor.clear.cgColor]
        listFade.startPoint = CGPoint(x: 0.5, y: 0)
        listFade.endPoint = CGPoint(x: 0.5, y: 1)
        scrollView.layer?.mask = listFade
        panel.contentView.addSubview(scrollView)

        let treeTop = scrollView.topAnchor.constraint(
            equalTo: panel.contentView.topAnchor, constant: Self.treeTopPadding)
        treeTopConstraint = treeTop
        NSLayoutConstraint.activate([
            // Flush on every edge.
            panel.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            panel.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            panel.topAnchor.constraint(equalTo: view.topAnchor),
            panel.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            treeTop,
            scrollView.bottomAnchor.constraint(equalTo: panel.contentView.bottomAnchor),
            // The selection pill's inset from the panel edge; row content adds
            // its own 8, which puts a row's icon level with the area headers.
            scrollView.leadingAnchor.constraint(
                equalTo: panel.contentView.leadingAnchor, constant: ChalkMetrics.sidebarListInset),
            scrollView.trailingAnchor.constraint(
                equalTo: panel.contentView.trailingAnchor, constant: -ChalkMetrics.sidebarListInset),
        ])

        emptyStateLabel.alignment = .center
        emptyStateLabel.font = .systemFont(ofSize: ChalkMetrics.sidebarRowFontSize)
        emptyStateLabel.textColor = .chalkTextMuted
        emptyStateLabel.stringValue = "No folders in this window\n\u{21E7}\u{2318}O adds one"
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

    override func viewDidLayout() {
        super.viewDidLayout()
        updateTreeTopClearance()
        updateListFade()
        outlineView.sizeLastColumnToFit()
    }

    /// Keep the bottom fade over the pill's clearance. Layer geometry only,
    /// never a constraint write, so this cannot re-enter layout.
    private func updateListFade() {
        let height = scrollView.bounds.height
        guard height > 0 else { return }
        // Long enough to read as a dissolve, short enough to keep the list dense.
        let fade = min(ChalkMetrics.footerPillHeight, height / 4)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        listFade.frame = scrollView.bounds
        listFade.locations = [0, NSNumber(value: Double((height - fade) / height)), 1]
        CATransaction.commit()
    }

    /// Re-apply `treeTopClearance()`. Half-point tolerance: a fractional value
    /// AppKit rounds away would re-enter layout forever.
    private func updateTreeTopClearance() {
        guard let treeTop = treeTopConstraint else { return }
        let wanted = treeTopClearance()
        if abs(treeTop.constant - wanted) > 0.5 {
            treeTop.constant = wanted
        }
    }

    // MARK: - Painting rows

    /// Repaint the rows for `nodes` in place: the live cell and row views are
    /// reconfigured, never re-dequeued, so a row mid-rename keeps its field
    /// and a repaint can land during a drag or an animated apply.
    func repaintRows(for nodes: [FileNode?]) {
        guard isViewLoaded else { return }
        for node in nodes.compactMap({ $0 }) {
            guard let item = item(for: node) else { continue }
            let row = outlineView.row(forItem: item)
            guard row >= 0 else { continue }
            if let cell = outlineView.view(atColumn: 0, row: row, makeIfNecessary: false) as? LibraryCellView {
                applyRowConfiguration(to: cell, item: item)
            }
            if let rowView = outlineView.rowView(atRow: row, makeIfNecessary: false) as? LibraryRowView {
                applyRowState(to: rowView, item: item)
            }
        }
    }

    /// Paint one row's cell. Runs on dequeue and on every state change; idempotent.
    private func applyRowConfiguration(to cell: LibraryCellView, item: LibraryRowItem) {
        let node = item.node
        let level = max(1, outlineView.level(forItem: item))
        if Self.isEmptyPlaceholder(node) {
            cell.endEditing(focusReturningTo: outlineView)
            cell.configure(name: node.name, symbol: nil, chevronSymbol: nil, level: level,
                           prominent: false, isPlaceholder: true)
            return
        }
        let isOpen = openDocumentURL == node.url
        let row = outlineView.row(forItem: item)
        let prominent = isOpen || (row >= 0 && outlineView.isRowSelected(row)) || renamingNode == node
        cell.configure(
            name: node.name,
            symbol: Self.symbol(for: node),
            chevronSymbol: node.isDirectory ? (item.isExpanded ? "chevron.down" : "chevron.right") : nil,
            level: level, prominent: prominent, isPlaceholder: false)
        // Inline rename: the name becomes a field with the selected pill, even
        // when the row is not the table's selection (context menu / F2).
        if renamingNode == node {
            cell.beginEditing(
                name: node.url.lastPathComponent,
                onCommit: { [weak self] name in self?.commitRename(name) ?? true },
                onCancel: { [weak self] in self?.cancelRename() })
        } else {
            cell.endEditing(focusReturningTo: outlineView)
        }
    }

    private func applyRowState(to rowView: LibraryRowView, item: LibraryRowItem) {
        rowView.isHeader = false
        rowView.isOpenDocument = openDocumentURL == item.node.url || renamingNode == item.node
        rowView.isDropTarget = dropTargetNode == item.node
    }

    private func applyHeaderState(to rowView: LibraryRowView, section: LibraryLocationItem) {
        rowView.isHeader = true
        rowView.isOpenDocument = false
        rowView.isDropTarget = dropTargetLocationID == section.location.id
    }

    /// Re-apply every visible area header's trailing slot. A fold changes
    /// only the section's rows, and the table does not re-dequeue a header for that.
    private func refreshHeaderSlots() {
        for section in sections {
            let row = outlineView.row(forItem: section)
            guard row >= 0,
                  let header = outlineView.view(atColumn: 0, row: row, makeIfNecessary: false) as? LibraryHeaderCellView
            else { continue }
            configure(header, for: section)
        }
    }

    /// Repaint the visible Location headers so only the `dropTargetLocationID`
    /// one shows the drop pill.
    private func refreshHeaderHighlights() {
        for section in sections {
            let row = outlineView.row(forItem: section)
            guard row >= 0,
                  let rowView = outlineView.rowView(atRow: row, makeIfNecessary: false) as? LibraryRowView
            else { continue }
            applyHeaderState(to: rowView, section: section)
        }
    }

    /// Mark the document the editor is showing; nil when no file-backed tab is active.
    func setOpenDocument(_ url: URL?) {
        openDocumentURL = url
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

    // MARK: - Create

    /// A non-colliding URL in `dir`: `Untitled.md`, then `Untitled 2.md`, ...
    /// Static so the probe runs on the file-work queue: each `fileExists`
    /// inside an iCloud Location crosses the sync layer.
    private static func uniqueURL(in dir: URL, base: String, ext: String?) -> URL {
        let name = FileNaming.uniqueName(base: base, ext: ext) { candidate in
            FileManager.default.fileExists(atPath: dir.appendingPathComponent(candidate).path)
        }
        return dir.appendingPathComponent(name)
    }

    /// Create `Untitled.md` (or `.tex`, per `defaultFileType`) in `directory`,
    /// open it in a tab and refresh the tree.
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

    /// New File / New Folder items, shared by the folder-row and Location-header menus.
    /// Internal, not private: `SidebarFileOperations` builds the row menu.
    func createItems(in directory: URL) -> [NSMenuItem] {
        [
            MenuActionItem(title: "New File") { [weak self] in self?.createFile(in: directory) },
            MenuActionItem(title: "New Folder") { [weak self] in self?.createFolder(in: directory) },
        ]
    }

    // MARK: - Menus

    /// The context menu for the row under the pointer: a Location's for a
    /// header, the row menu for a file or folder, none for the sentinel or blank space.
    private func menu(forRow row: Int) -> NSMenu? {
        guard row >= 0 else { return nil }
        switch outlineView.item(atRow: row) {
        case let section as LibraryLocationItem:
            return headerMenu(for: section.location)
        case let item as LibraryRowItem where !Self.isEmptyPlaceholder(item.node):
            return rowMenu(for: item.node)
        default:
            return nil
        }
    }

    /// A Location header's menu: New File / New Folder (Grant Access when the
    /// Location lost access) plus "Remove from Window".
    func headerMenu(for location: Location) -> NSMenu {
        let menu = NSMenu()
        if location.needsReauthorization {
            // A no-access Location can't host New File/Folder; its only useful
            // actions are re-granting the folder or removing the row.
            menu.addItem(MenuActionItem(title: "Grant Access\u{2026}") { [weak self] in
                self?.presentReauthorizePicker(for: location.id)
            })
        } else {
            for item in createItems(in: location.url) { menu.addItem(item) }
        }
        menu.addItem(.separator())
        menu.addItem(Self.destructive(MenuActionItem(title: "Remove from Window") { [weak self] in
            self?.onRemoveLocation?(location.id)
        }))
        return menu
    }

    /// Mark a menu item as destructive: red, like the system's own.
    static func destructive(_ item: NSMenuItem) -> NSMenuItem {
        item.attributedTitle = NSAttributedString(
            string: item.title, attributes: [.foregroundColor: NSColor.systemRed])
        item.tag = destructiveTag
        return item
    }
    static let destructiveTag = 0x6465 // "de"

    // MARK: - Location fold/unfold

    /// Fold/unfold the Location a header stands for.
    private func toggleFold(locationID id: String) {
        if collapsedLocationIDs.contains(id) {
            collapsedLocationIDs.remove(id)
        } else {
            collapsedLocationIDs.insert(id)
        }
        // Unfolding rebuilds the Location's first level, so build off-main.
        // Zero delay: the fold state is captured in this runloop turn.
        scheduleReload(delay: 0)
    }

    // MARK: - Move (rename + drag-move, with undo)

    /// The single mutation point for rename and drag-move: coordinated move,
    /// open-tab update (`onFileMoved`), tree refresh and undo registration, so
    /// the two callers can't drift.
    ///
    /// Two phases. The collision verdict is a synchronous `fileExists` probe,
    /// returned as the result (a collision rejects; an undo whose slot is
    /// re-occupied no-ops). The move runs off-main (`CoordinatedFileMove`) and
    /// reports through `completion`, which fires only when the pre-flight
    /// passed. Focusing the tree afterwards points Cmd+Z at `fileUndoManager`.
    @discardableResult
    func moveFile(from source: URL, to destination: URL, actionName: String,
                  animated: Bool = false,
                  completion: ((Bool) -> Void)? = nil) -> Bool {
        // Collision guard, except a case-only rename: on case-insensitive APFS
        // `fileExists` matches the source itself, so "notes.md" -> "Notes.md"
        // would always be rejected.
        guard !FileManager.default.fileExists(atPath: destination.path)
                || Self.isCaseOnlyRename(from: source, to: destination) else { return false }
        CoordinatedFileMove.perform(from: source, to: destination) { [weak self] error in
            guard let self else { return }
            if let error {
                Self.log.error("move failed: \(error.localizedDescription, privacy: .private)")
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
            self.focusTree()
            completion?(true)
            self.notifyFileWorkFinished()
        }
        return true
    }

    /// True when `destination` differs from `source` only by letter case in
    /// the same directory: the one existing-destination case `moveFile` allows.
    static func isCaseOnlyRename(from source: URL, to destination: URL) -> Bool {
        let sameDir = source.deletingLastPathComponent().standardizedFileURL
            == destination.deletingLastPathComponent().standardizedFileURL
        return sameDir
            && source.lastPathComponent.lowercased() == destination.lastPathComponent.lowercased()
            && source.lastPathComponent != destination.lastPathComponent
    }

    /// Point Cmd+Z at the Library's undo manager. Internal, not private:
    /// shared with `SidebarFileOperations`.
    func focusTree() {
        guard let window = view.window, outlineView.window === window else { return }
        window.makeFirstResponder(outlineView)
    }

    /// The notice every failed sidebar file operation shows, so a failure is
    /// never silent. Internal, not private: shared with `SidebarFileOperations`.
    func showFileOpFailure(_ message: String) {
        #if DEBUG
        lastNoticeMessageForTesting = message
        #endif
        presentChalkNotice(title: nil, message: message)
    }

    // MARK: - Drag-move

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

    /// Resolve the drop target for a point in the outline view. A header wins
    /// (so a header drop isn't read as its section's first row); otherwise
    /// `SidebarDropPolicy` maps the row under the pointer: a folder row is
    /// that folder, a file row its parent, blank space the Location root.
    /// File rows resolving to their parent is what lets a file be dragged
    /// back out of a folder.
    private func dropTarget(at point: CGPoint) -> DropTarget? {
        let row = outlineView.row(at: point)
        if row >= 0 {
            switch outlineView.item(atRow: row) {
            case let section as LibraryLocationItem:
                return .locationRoot(section.location)
            case let item as LibraryRowItem:
                guard let section = item.section else { return nil }
                let rowKind: SidebarDropPolicy.Row = item.node.isDirectory && !Self.isEmptyPlaceholder(item.node)
                    ? .folder(item.node.url) : .file(item.node.url)
                switch SidebarDropPolicy.destination(row: rowKind, locationRoot: section.location.url) {
                case .locationRoot:
                    return .locationRoot(section.location)
                case .folder(let url):
                    // The highlight needs the row, so a folder that isn't in
                    // the tree (a collapsed ancestor can't be) has no target.
                    guard let folder = folderItem(at: url, in: section) else { return nil }
                    return .folder(folder.node)
                }
            default:
                return nil
            }
        }
        // Blank space: the last Location whose header starts at or above the
        // pointer encloses it. Above everything is no target.
        guard point.y >= 0, let section = section(enclosing: point) else { return nil }
        return .locationRoot(section.location)
    }

    private func section(enclosing point: CGPoint) -> LibraryLocationItem? {
        var match: LibraryLocationItem?
        var matchY = -CGFloat.greatestFiniteMagnitude
        for section in sections {
            let row = outlineView.row(forItem: section)
            guard row >= 0 else { continue }
            let top = outlineView.rect(ofRow: row).minY
            if top <= point.y, top > matchY {
                matchY = top
                match = section
            }
        }
        return match
    }

    /// The folder item for `url` inside `section`'s tree, matched by
    /// normalized path (a directory URL has two legal spellings).
    private func folderItem(at url: URL, in section: LibraryLocationItem) -> LibraryRowItem? {
        let path = url.standardizedFileURL.path
        var found: LibraryRowItem?
        Self.walk(section.children) {
            if found == nil, $0.node.isDirectory, $0.node.url.standardizedFileURL.path == path { found = $0 }
        }
        return found
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

    /// The dragged node, when the drag is this tree's own.
    private func draggedNode(_ info: NSDraggingInfo) -> FileNode? {
        guard info.draggingSource as? NSOutlineView === outlineView else { return nil }
        return draggedNode
    }

    // MARK: - Folder panels

    /// Present the folder panel to add a Location (File > Add Folder to Window).
    func presentAddLocationPicker() {
        // System styling on purpose: the open panel is an OS-owned sheet.
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Add"
        let finish: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard let self else { return }
            guard response == .OK, let url = panel.url else {
                self.pendingReauthorizationID = nil
                return
            }
            if let id = self.pendingReauthorizationID {
                self.pendingReauthorizationID = nil
                self.onReauthorizeLocation?(id, url)
            } else {
                self.onAddLocation?(url)
            }
            self.reload()
        }
        if let window = view.window {
            panel.beginSheetModal(for: window, completionHandler: finish)
        } else {
            finish(panel.runModal())
        }
    }

    /// Present the folder panel to re-grant a Location that lost access; the
    /// pick heals the existing record instead of adding a new one.
    func presentReauthorizePicker(for id: String) {
        pendingReauthorizationID = id
        presentAddLocationPicker()
    }
}

// MARK: - Data source

extension SidebarViewController: NSOutlineViewDataSource {
    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        switch item {
        case nil: return sections.count
        case let section as LibraryLocationItem: return section.children.count
        case let item as LibraryRowItem: return item.children?.count ?? 0
        default: return 0
        }
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        switch item {
        case nil: return sections[index]
        case let section as LibraryLocationItem: return section.children[index]
        case let item as LibraryRowItem: return item.children![index]
        default: fatalError("unknown outline item")
        }
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        switch item {
        case is LibraryLocationItem: return true
        case let item as LibraryRowItem: return item.node.isDirectory && !Self.isEmptyPlaceholder(item.node)
        default: return false
        }
    }

    // MARK: Drag source

    /// Drag file and folder rows (not headers, not the sentinel).
    func outlineView(_ outlineView: NSOutlineView, pasteboardWriterForItem item: Any) -> NSPasteboardWriting? {
        guard let item = item as? LibraryRowItem, !Self.isEmptyPlaceholder(item.node) else { return nil }
        let pasteboardItem = NSPasteboardItem()
        pasteboardItem.setString(item.node.url.path, forType: Self.rowPasteboardType)
        pasteboardItem.setString(item.node.url.absoluteString, forType: .fileURL)
        return pasteboardItem
    }

    func outlineView(_ outlineView: NSOutlineView, draggingSession session: NSDraggingSession,
                     willBeginAt screenPoint: NSPoint, forItems draggedItems: [Any]) {
        draggedNode = (draggedItems.first as? LibraryRowItem)?.node
    }

    func outlineView(_ outlineView: NSOutlineView, draggingSession session: NSDraggingSession,
                     endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        draggedNode = nil
        clearDropTarget()
    }

    // MARK: Drop

    func outlineView(_ outlineView: NSOutlineView, validateDrop info: NSDraggingInfo,
                     proposedItem item: Any?, proposedChildIndex index: Int) -> NSDragOperation {
        let point = outlineView.convert(info.draggingLocation, from: nil)
        guard let node = draggedNode(info),
              let target = dropTarget(at: point),
              canMove(node, into: target.url) else {
            clearDropTarget()
            return []
        }
        setDropTarget(target)
        return .move
    }

    /// Move into the resolved directory through `moveFile`: a collision
    /// rejects, open tabs follow, and the reload keeps expansion.
    func outlineView(_ outlineView: NSOutlineView, acceptDrop info: NSDraggingInfo,
                     item: Any?, childIndex index: Int) -> Bool {
        clearDropTarget()
        let point = outlineView.convert(info.draggingLocation, from: nil)
        guard let node = draggedNode(info),
              let directory = dropTarget(at: point)?.url,
              canMove(node, into: directory) else { return false }
        let destination = directory.appendingPathComponent(node.url.lastPathComponent)
        // Next runloop tick: `moveFile` lands an animated apply, and doing
        // that synchronously inside the drop races the table's own drop teardown.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            // Two rejections, arriving at different times: the name collision
            // is the synchronous verdict, an I/O failure comes back through
            // the completion after the off-main move.
            let rejected = { [weak self] in
                self?.showFileOpFailure("Couldn\u{2019}t move \u{201C}\(node.url.lastPathComponent)\u{201D} there. A file with that name may already exist.")
            }
            let started = self.moveFile(
                from: node.url, to: destination, actionName: "Move", animated: true,
                completion: { moved in if !moved { rejected() } })
            if !started { rejected() }
        }
        return true
    }
}

// MARK: - Delegate

extension SidebarViewController: NSOutlineViewDelegate {
    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        switch item {
        case let section as LibraryLocationItem:
            let header = outlineView.makeView(withIdentifier: LibraryHeaderCellView.identifier, owner: nil)
                as? LibraryHeaderCellView ?? LibraryHeaderCellView()
            configure(header, for: section)
            return header
        case let item as LibraryRowItem:
            let cell = outlineView.makeView(withIdentifier: LibraryCellView.identifier, owner: nil)
                as? LibraryCellView ?? LibraryCellView()
            // Configured now, not in a later pass: the first measurement is the real row.
            applyRowConfiguration(to: cell, item: item)
            return cell
        default:
            return nil
        }
    }

    func outlineView(_ outlineView: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? {
        let rowView = LibraryRowView()
        switch item {
        case let section as LibraryLocationItem: applyHeaderState(to: rowView, section: section)
        case let item as LibraryRowItem: applyRowState(to: rowView, item: item)
        default: break
        }
        return rowView
    }

    /// Rows are the design token; headers add their margins. Nothing self-sizes.
    func outlineView(_ outlineView: NSOutlineView, heightOfRowByItem item: Any) -> CGFloat {
        if let section = item as? LibraryLocationItem {
            return LibraryHeaderCellView.height(isFirst: section === sections.first,
                                                needsReauthorization: section.location.needsReauthorization)
        }
        return ChalkMetrics.sidebarRowHeight
    }

    /// Headers fold, they are never selected; the "Empty" sentinel is
    /// presentation, not a row.
    func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool {
        guard let item = item as? LibraryRowItem else { return false }
        return !Self.isEmptyPlaceholder(item.node)
    }

    /// A Location is always open; folding it empties its rows instead.
    func outlineView(_ outlineView: NSOutlineView, shouldCollapseItem item: Any) -> Bool {
        !(item is LibraryLocationItem)
    }

    func outlineViewItemWillExpand(_ notification: Notification) {
        guard let item = notification.userInfo?["NSObject"] as? LibraryRowItem else { return }
        loadChildren(forExpanding: item)
    }

    func outlineViewItemDidExpand(_ notification: Notification) {
        guard let item = notification.userInfo?["NSObject"] as? LibraryRowItem else { return }
        item.isExpanded = true
        // Children that were expanded when this folder last closed come back open.
        syncExpansion(of: item.children ?? [])
        repaintRows(for: [item.node])
    }

    func outlineViewItemDidCollapse(_ notification: Notification) {
        guard let item = notification.userInfo?["NSObject"] as? LibraryRowItem else { return }
        item.isExpanded = false
        repaintRows(for: [item.node])
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        // The pill and the weight follow the selection; repaint what is on screen.
        let visible = outlineView.rows(in: outlineView.visibleRect)
        for row in visible.location..<(visible.location + visible.length) {
            guard let item = outlineView.item(atRow: row) as? LibraryRowItem,
                  let cell = outlineView.view(atColumn: 0, row: row, makeIfNecessary: false) as? LibraryCellView
            else { continue }
            applyRowConfiguration(to: cell, item: item)
        }
    }
}

#if DEBUG
extension SidebarViewController {
    /// Expands every directory row in every section, for the audit harness.
    /// Expanding can reveal newly-loaded grandchildren, so re-walk until a
    /// pass finds nothing left to expand (bounded to 8).
    func expandAll() {
        loadViewIfNeeded()
        for _ in 0..<8 {
            var expandedAny = false
            for section in sections {
                var collapsed: [LibraryRowItem] = []
                Self.walk(section.children) {
                    if $0.node.isDirectory, !$0.isExpanded, !($0.children ?? []).isEmpty { collapsed.append($0) }
                }
                for item in collapsed where outlineView.row(forItem: item) >= 0 {
                    outlineView.expandItem(item)
                    expandedAny = true
                }
            }
            if !expandedAny { break }
        }
    }

    /// New File / New Folder, so tests can assert the create paths' threading contract.
    func createFileForTesting(in directory: URL) { createFile(in: directory) }
    func createFolderForTesting(in directory: URL) { createFolder(in: directory) }

    /// Drive the expansion toggle exactly as a row click would.
    func toggleFolderExpansionForTesting(_ node: FileNode) {
        toggleFolderExpansion(node)
    }

    func isExpandedForTesting(_ node: FileNode) -> Bool {
        isExpanded(node)
    }

    /// Keyboard-nav hook: drive fold-key handling with an explicit node.
    func handleFoldKeyForTesting(_ node: FileNode, expanding: Bool) {
        handleFoldKey(node, expanding: expanding)
    }

    /// The claimed keys, so the keyboard-nav tests assert what the tree
    /// claims (and that Return is not among them) without real key events.
    static var treeKeyClaimsForTesting: [LibraryOutlineView.KeyClaim] { LibraryOutlineView.KeyClaim.allCases }

    /// Reload-race hook: capture and build now (the stale input) and return
    /// the deferred apply, so a test can change expansion in between like a
    /// user racing the build.
    func makeStaleReloadApplyForTesting() -> () -> Void {
        let built = Self.buildSections(captureReloadInput())
        return { [self] in applySections(built, animated: false) }
    }

    /// Whether a node is anywhere in the model (the reload-race tests assert
    /// lazily loaded children survive a stale apply).
    func containsNodeForTesting(_ node: FileNode) -> Bool {
        item(for: node) != nil
    }

    /// The rows of one Location, in display order, including rows under
    /// expanded folders, addressed as `(item, section)`.
    func rowsForTesting(inSection section: Int) -> [FileNode] {
        guard section < sections.count else { return [] }
        var rows: [FileNode] = []
        func visit(_ items: [LibraryRowItem]) {
            for item in items {
                rows.append(item.node)
                if item.isExpanded { visit(item.children ?? []) }
            }
        }
        visit(sections[section].children)
        return rows
    }

    func numberOfItemsForTesting(inSection section: Int) -> Int { rowsForTesting(inSection: section).count }

    func nodeForTesting(at indexPath: IndexPath) -> FileNode? {
        let rows = rowsForTesting(inSection: indexPath.section)
        return indexPath.item < rows.count ? rows[indexPath.item] : nil
    }

    /// The table row for a node, nil when it has none (collapsed ancestor).
    func rowForTesting(_ node: FileNode) -> Int? {
        guard let item = item(for: node) else { return nil }
        let row = outlineView.row(forItem: item)
        return row >= 0 ? row : nil
    }

    /// A cell straight out of the delegate, before any layout pass. It must
    /// already be fully configured, or the row would remeasure on screen.
    func dequeuedCellForTesting(_ node: FileNode) -> LibraryCellView? {
        guard let item = item(for: node) else { return nil }
        return outlineView(outlineView, viewFor: nil, item: item) as? LibraryCellView
    }

    /// The live cell for a row, nil off screen.
    func cellForTesting(_ node: FileNode) -> LibraryCellView? {
        guard let row = rowForTesting(node) else { return nil }
        return outlineView.view(atColumn: 0, row: row, makeIfNecessary: false) as? LibraryCellView
    }

    /// The panel's frame in the sidebar view's own coordinates.
    var panelFrameForTesting: CGRect { panel.frame }

    /// The first tree row's frame in the sidebar view's coordinates, nil with
    /// no rows.
    var firstRowFrameForTesting: CGRect? {
        guard let first = sections.first?.children.first else { return nil }
        let row = outlineView.row(forItem: first)
        guard row >= 0 else { return nil }
        return view.convert(outlineView.rect(ofRow: row), from: outlineView)
    }

    /// The first area header's frame in the sidebar view's coordinates, nil
    /// with no Locations: where the list's content starts
    /// (`libraryListStartsAtTheChromeFloor`). A scrolled list says nothing
    /// about where the list starts.
    var firstHeaderFrameForTesting: CGRect? {
        guard let first = sections.first, abs(libraryScrollOffsetForTesting) < 0.5 else { return nil }
        let row = outlineView.row(forItem: first)
        guard row >= 0 else { return nil }
        return view.convert(outlineView.rect(ofRow: row), from: outlineView)
    }

    /// The Library list's scroll offset (transition tests: a chrome round
    /// trip must hand the list back exactly where the reader left it).
    var libraryScrollOffsetForTesting: CGFloat {
        scrollView.contentView.bounds.origin.y
    }

    /// Drive the scroll position the way a reader's scroll would leave it.
    func setLibraryScrollOffsetForTesting(_ offset: CGFloat) {
        view.layoutSubtreeIfNeeded()
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: offset))
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    /// Drag-move drop resolution without a drag: the directory a drop at
    /// `point` (outline view coordinates) would land in, nil when the
    /// position is not a target.
    func dropDestinationForTesting(at point: CGPoint) -> URL? {
        dropTarget(at: point)?.url
    }

    /// The outline view, so drop tests can turn rows into points.
    var outlineViewForTesting: LibraryOutlineView { outlineView }

    /// The URL behind a row, for locating rows by name in tests.
    func itemURLForTesting(at indexPath: IndexPath) -> URL? {
        nodeForTesting(at: indexPath)?.url
    }

    /// Fold a location from its header, exactly as a header click does.
    func toggleFoldForTesting(locationID id: String) { toggleFold(locationID: id) }

    /// Click a row or header at a point in the outline view, as `rowClicked` would.
    func clickForTesting(at point: CGPoint) {
        handleClick(row: outlineView.row(at: point))
    }

    /// Location fold state.
    func isLocationCollapsedForTesting(_ id: String) -> Bool {
        collapsedLocationIDs.contains(id)
    }

    /// The header row's frame for a section, in the outline view's coordinates.
    func headerRectForTesting(section: Int) -> CGRect? {
        guard section < sections.count else { return nil }
        let row = outlineView.row(forItem: sections[section])
        return row >= 0 ? outlineView.rect(ofRow: row) : nil
    }

    /// What an area header's trailing slot shows, read from the live header view.
    func headerSlotForTesting(section: Int) -> (count: String, showsChevron: Bool)? {
        guard section < sections.count else { return nil }
        outlineView.layoutSubtreeIfNeeded()
        let row = outlineView.row(forItem: sections[section])
        guard row >= 0,
              let header = outlineView.view(atColumn: 0, row: row, makeIfNecessary: true) as? LibraryHeaderCellView
        else { return nil }
        return header.slot.stateForTesting
    }

    /// Whether the Library paints its row pill for a node: the mark shared by
    /// selection, keyboard focus and the open document.
    func rowIsMarkedForTesting(_ node: FileNode) -> Bool {
        guard let row = rowForTesting(node),
              let rowView = outlineView.rowView(atRow: row, makeIfNecessary: true) as? LibraryRowView
        else { return false }
        return rowView.currentBackground.backgroundColor == .chalkRowSelection
    }

    /// The row's chevron view, for the accessory-stability test.
    func chevronViewForTesting(_ node: FileNode) -> NSView? {
        cellForTesting(node)?.chevron
    }
}
#endif
