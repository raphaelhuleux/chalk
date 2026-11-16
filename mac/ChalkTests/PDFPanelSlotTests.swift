import XCTest
import ChalkKit
@testable import Chalk

/// The PDF and the outline share the trailing slot: ⌥⌘P and ⌘K each toggle
/// their own panel and leave the other up, PDF on the leading side, and only
/// the outline keeps the surface pushing outlines.
@MainActor
final class PDFPanelSlotTests: XCTestCase {
    private var previousMode: EditingMode!
    private var previousPDFWidth: Any?
    private var windows: [NSWindow] = []

    override func setUp() {
        super.setUp()
        previousMode = Preferences.editingMode
        Preferences.editingMode = .normal
        previousPDFWidth = UserDefaults.standard.object(forKey: Preferences.pdfPanelWidthKey)
        UserDefaults.standard.removeObject(forKey: Preferences.pdfPanelWidthKey)
    }

    override func tearDown() {
        Preferences.editingMode = previousMode
        if let previousPDFWidth {
            UserDefaults.standard.set(previousPDFWidth, forKey: Preferences.pdfPanelWidthKey)
        } else {
            UserDefaults.standard.removeObject(forKey: Preferences.pdfPanelWidthKey)
        }
        for window in windows { dismantleHostedSidebar(window) }
        windows = []
        super.tearDown()
    }

    private func makeRoot(_ content: WindowContent = .openWelcome, width: CGFloat = 1400) -> RootSplitViewController {
        let window = NSWindow.hostedForTesting(frame: CGRect(x: 0, y: 0, width: width, height: 820))
        let root = RootSplitViewController(initialContent: content)
        root.motionPolicyForTesting = .instant
        window.rootViewController = root
        window.isHidden = false
        root.loadViewIfNeeded()
        root.view.layoutSubtreeIfNeeded()
        windows.append(window)
        return root
    }

    private func outlastAdmitWindow() {
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.35))
    }

    func testPDFToggleOpensAndClosesTheSlot() {
        let root = makeRoot()
        root.cmdTogglePDFPanel()
        XCTAssertEqual(root.trailingPanelStateForTesting, .pdf)
        root.cmdTogglePDFPanel()
        XCTAssertEqual(root.trailingPanelStateForTesting, .hidden)
    }

    func testEachToggleLeavesTheOtherPanelUp() {
        let root = makeRoot()
        root.cmdToggleOutlinePanel()
        XCTAssertEqual(root.trailingPanelStateForTesting, .shown)
        root.cmdTogglePDFPanel()
        XCTAssertEqual(root.trailingPanelStateForTesting, .both)
        outlastAdmitWindow()
        root.cmdToggleOutlinePanel()
        XCTAssertEqual(root.trailingPanelStateForTesting, .pdf, "⌘K takes only the outline down")
        outlastAdmitWindow()
        root.cmdToggleOutlinePanel()
        XCTAssertEqual(root.trailingPanelStateForTesting, .both, "⌘K over the PDF keeps the PDF")
        root.cmdTogglePDFPanel()
        XCTAssertEqual(root.trailingPanelStateForTesting, .shown, "⌥⌘P takes only the PDF down")
    }

    func testBothPanelsTileThePDFThenTheOutlineToTheWindowEdge() throws {
        let root = makeRoot()
        let editor = root.editorForTesting
        root.cmdTogglePDFPanel()
        XCTAssertTrue(editor.isInnerResizeGripHiddenForTesting, "one panel has no inner border")
        root.cmdToggleOutlinePanel()
        root.view.layoutSubtreeIfNeeded()
        let slot = try XCTUnwrap(editor.outlinePanelFrame)
        let pdf = editor.panelFrameForTesting(.pdf), outline = editor.panelFrameForTesting(.outline)
        XCTAssertEqual(pdf.minX, slot.minX, accuracy: 0.5)
        XCTAssertEqual(pdf.maxX, outline.minX, accuracy: 0.5)
        XCTAssertEqual(outline.maxX, editor.view.bounds.width, accuracy: 0.5)
        XCTAssertEqual(pdf.width, Preferences.pdfPanelWidth, accuracy: 0.5)
        XCTAssertEqual(outline.width, Preferences.outlinePanelWidth, accuracy: 0.5)
        XCTAssertFalse(editor.pdfPanel.view.isHidden)
        XCTAssertFalse(editor.outlinePanel.view.isHidden)
        XCTAssertFalse(editor.isInnerResizeGripHiddenForTesting)
    }

    /// A panel taken down leaves the other one at its full frame.
    func testClosingOnePanelGivesTheSlotBackToTheOther() throws {
        let root = makeRoot()
        let editor = root.editorForTesting
        root.cmdTogglePDFPanel()
        root.cmdToggleOutlinePanel()
        outlastAdmitWindow()
        root.cmdToggleOutlinePanel()
        root.view.layoutSubtreeIfNeeded()
        var slot = try XCTUnwrap(editor.outlinePanelFrame)
        XCTAssertEqual(slot.width, Preferences.pdfPanelWidth, accuracy: 0.5)
        XCTAssertEqual(editor.panelFrameForTesting(.pdf).minX, slot.minX, accuracy: 0.5)
        XCTAssertEqual(editor.panelFrameForTesting(.pdf).maxX, slot.maxX, accuracy: 0.5)
        XCTAssertTrue(editor.outlinePanel.view.isHidden)

        outlastAdmitWindow()
        root.cmdToggleOutlinePanel()
        root.cmdTogglePDFPanel()
        root.view.layoutSubtreeIfNeeded()
        slot = try XCTUnwrap(editor.outlinePanelFrame)
        XCTAssertEqual(slot.width, Preferences.outlinePanelWidth, accuracy: 0.5)
        XCTAssertEqual(editor.panelFrameForTesting(.outline).minX, slot.minX, accuracy: 0.5)
        XCTAssertEqual(editor.panelFrameForTesting(.outline).maxX, slot.maxX, accuracy: 0.5)
        XCTAssertTrue(editor.pdfPanel.view.isHidden)
    }

    /// One ⌘K beside a PDF must not throw the text under the slot: the PDF gives way down to its
    /// minimum first, and keeps its preferred width for a wider window.
    func testThePDFGivesWayToKeepTheEditorPushed() throws {
        let root = makeRoot(width: 1100)
        let window = try XCTUnwrap(root.view.window)
        let editor = root.editorForTesting
        root.cmdTogglePDFPanel()
        root.cmdToggleOutlinePanel()
        root.view.layoutSubtreeIfNeeded()
        XCTAssertFalse(editor.outlinePanelIsOverlay)
        XCTAssertEqual(editor.outlinePanelWidthForTesting,
                       editor.view.bounds.width - ChalkMetrics.outlinePanelPushMinimumEditorWidth, accuracy: 0.5)
        XCTAssertEqual(editor.panelFrameForTesting(.outline).width, Preferences.outlinePanelWidth, accuracy: 0.5)
        XCTAssertLessThan(editor.panelFrameForTesting(.pdf).width, Preferences.pdfPanelWidth)

        window.setFrame(CGRect(x: 0, y: 0, width: 1800, height: 820), display: false)
        root.view.layoutSubtreeIfNeeded()
        XCTAssertEqual(editor.panelFrameForTesting(.pdf).width, Preferences.pdfPanelWidth, accuracy: 0.5)
    }

    func testZenRefusesThePDFAndClosesIt() {
        let root = makeRoot()
        root.cmdTogglePDFPanel()
        root.setEditingMode(.zen)
        XCTAssertEqual(root.trailingPanelStateForTesting, .hidden)
        root.cmdTogglePDFPanel()
        XCTAssertEqual(root.trailingPanelStateForTesting, .hidden)
    }

    /// The PDF is per tab; the outline is the window's.
    func testEachTabKeepsItsOwnPDF() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("chalk-slot-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let a = dir.appendingPathComponent("a.tex"), b = dir.appendingPathComponent("b.md")
        try "\\documentclass{article}\n".write(to: a, atomically: true, encoding: .utf8)
        try "# b\n".write(to: b, atomically: true, encoding: .utf8)
        let root = makeRoot(.openEmpty)
        let editor = root.editorForTesting
        editor.open(url: a)
        root.cmdTogglePDFPanel()
        XCTAssertEqual(root.trailingPanelStateForTesting, .pdf)
        editor.open(url: b)
        XCTAssertEqual(root.trailingPanelStateForTesting, .hidden, "b never asked for its PDF")
        editor.open(url: a)
        XCTAssertEqual(root.trailingPanelStateForTesting, .pdf, "a kept its PDF")

        // With the window's outline on, every tab shows it, beside its own PDF if it has one.
        editor.open(url: b)
        root.cmdToggleOutlinePanel()
        XCTAssertEqual(root.trailingPanelStateForTesting, .shown)
        editor.open(url: a)
        XCTAssertEqual(root.trailingPanelStateForTesting, .both)
        outlastAdmitWindow()
        root.cmdTogglePDFPanel()
        XCTAssertEqual(root.trailingPanelStateForTesting, .shown, "taking the PDF down leaves the outline")
    }

    /// A PDF width remembered from a wider window fits this column past the band's chips, and the
    /// window keeps its size (docs/issues/2026-10-28-wide-pdf-slot-loops-layout.md). A wider
    /// window gives the remembered width back.
    func testAPDFWiderThanTheColumnFitsItAndTheWindowKeepsItsSize() throws {
        Preferences.pdfPanelWidth = 983
        let root = makeRoot(width: 1100)
        let window = try XCTUnwrap(root.view.window)
        root.setSidebarVisible(true)
        root.view.layoutSubtreeIfNeeded()
        let editor = root.editorForTesting
        let column = editor.view.bounds.width
        XCTAssertLessThan(column, 983, "the case needs a column narrower than the PDF")

        root.cmdTogglePDFPanel()
        outlastAdmitWindow()
        root.view.layoutSubtreeIfNeeded()
        XCTAssertEqual(window.frame.width, 1100, "the band grew the window")
        let panel = try XCTUnwrap(editor.outlinePanelFrame)
        XCTAssertGreaterThan(panel.minX, 0, "the slot overhangs the Library")
        XCTAssertEqual(panel.maxX, column, accuracy: 0.5)
        XCTAssertEqual(Preferences.pdfPanelWidth, 983, "fitting is not a resize")

        window.setFrame(CGRect(x: 0, y: 0, width: 1800, height: 820), display: false)
        root.view.layoutSubtreeIfNeeded()
        XCTAssertEqual(editor.outlinePanelWidthForTesting, 983, accuracy: 0.5)
    }

    /// The same wide slot over three tab groups: the groups share what the slot leaves, the window
    /// keeps its size, and every row stays inside the band (the 10-28 loop came back through the
    /// rows once there were several).
    func testAWidePDFOverThreeGroupsKeepsTheWindowAndTheRows() throws {
        Preferences.pdfPanelWidth = 983
        let root = makeRoot(width: 1100)
        let window = try XCTUnwrap(root.view.window)
        root.setSidebarVisible(true)
        let editor = root.editorForTesting
        while editor.tabCountForTesting < 3 { editor.newFile() }
        root.setGroupsForTesting(.multiple)
        root.view.layoutSubtreeIfNeeded()
        XCTAssertEqual(editor.groupCount, 3)

        root.cmdTogglePDFPanel()
        outlastAdmitWindow()
        root.view.layoutSubtreeIfNeeded()
        XCTAssertEqual(window.frame.width, 1100, "the band grew the window")
        let panel = try XCTUnwrap(editor.outlinePanelFrame)
        XCTAssertEqual(panel.maxX, editor.view.bounds.width, accuracy: 0.5)
        let panes = editor.paneFramesForTesting
        XCTAssertEqual(panes.count, 3)
        XCTAssertEqual(panes.last?.maxX ?? 0, editor.contentViewFrameForTesting.width, accuracy: 0.5,
                       "the groups tile the content")
        let bar = try XCTUnwrap(root.headerBarForTesting as? HeaderBarView)
        for strip in root.tabStripsForTesting where strip.superview != nil {
            let frame = bar.convert(strip.frame, from: strip.superview)
            XCTAssertGreaterThanOrEqual(frame.minX, bar.bounds.minX - 0.5)
            XCTAssertLessThanOrEqual(frame.maxX, bar.bounds.maxX + 0.5)
        }
    }

    /// A wide PDF fitted to the column still leaves the strip room for a tab name, not only "+".
    func testAFittedPDFLeavesTheTabNamesReadable() throws {
        Preferences.pdfPanelWidth = 686
        let root = makeRoot(width: 843)
        root.cmdTogglePDFPanel()
        outlastAdmitWindow()
        root.view.layoutSubtreeIfNeeded()
        let bar = try XCTUnwrap(root.headerBarForTesting as? HeaderBarView)
        let editor = root.editorForTesting
        let panel = try XCTUnwrap(editor.outlinePanelFrame)
        let slotStart = bar.convert(panel, from: editor.view).minX
        XCTAssertGreaterThanOrEqual(slotStart, bar.tabStrip.frame.minX + HeaderTabStrip.readableWidth)
    }

    func testAPDFSlotDoesNotRestoreAsTheOutline() {
        let root = makeRoot()
        root.cmdTogglePDFPanel()
        XCTAssertFalse(root.captureSession().isOutlineVisible)
    }

    func testCompileNeedsACompilableFileAndShowInPDFATeXOne() {
        let compile = NSMenuItem(title: "Compile", action: #selector(RootSplitViewController.cmdCompile(_:)), keyEquivalent: "r")
        let sync = NSMenuItem(title: "Show in PDF", action: #selector(RootSplitViewController.cmdShowInPDF(_:)), keyEquivalent: "j")
        let empty = makeRoot(.openEmpty)
        XCTAssertFalse(empty.validateMenuItem(compile))
        XCTAssertFalse(empty.validateMenuItem(sync))
        let welcome = makeRoot() // Welcome.md: Markdown compiles, but has no SyncTeX
        XCTAssertTrue(welcome.validateMenuItem(compile))
        XCTAssertFalse(welcome.validateMenuItem(sync))
    }
}
