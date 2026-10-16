import XCTest
import ChalkKit
@testable import Chalk

/// The PDF panel shares the outline's trailing slot: ⌥⌘P and ⌘K each toggle
/// their own content, switching it in place when the slot already shows the
/// other one, and only the outline content keeps the surface pushing outlines.
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

    private func makeRoot(_ content: WindowContent = .openWelcome) -> RootSplitViewController {
        let window = NSWindow.hostedForTesting(frame: CGRect(x: 0, y: 0, width: 1400, height: 820))
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

    func testEachToggleSwitchesTheOtherContentInPlace() {
        let root = makeRoot()
        root.cmdToggleOutlinePanel()
        XCTAssertEqual(root.trailingPanelStateForTesting, .shown)
        root.cmdTogglePDFPanel()
        XCTAssertEqual(root.trailingPanelStateForTesting, .pdf, "⌥⌘P over the outline swaps, it does not close")
        outlastAdmitWindow()
        root.cmdToggleOutlinePanel()
        XCTAssertEqual(root.trailingPanelStateForTesting, .shown, "⌘K over the PDF swaps back")
    }

    func testTheSlotTakesEachContentsOwnWidth() {
        let root = makeRoot()
        root.cmdToggleOutlinePanel()
        let outlineWidth = root.editorForTesting.outlinePanelWidthForTesting
        root.cmdTogglePDFPanel()
        XCTAssertEqual(root.editorForTesting.outlinePanelWidthForTesting, Preferences.pdfPanelWidth)
        XCTAssertNotEqual(root.editorForTesting.outlinePanelWidthForTesting, outlineWidth)
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

        // With the window's outline on, a tab without a PDF shows the outline.
        editor.open(url: b)
        root.cmdToggleOutlinePanel()
        XCTAssertEqual(root.trailingPanelStateForTesting, .shown)
        editor.open(url: a)
        XCTAssertEqual(root.trailingPanelStateForTesting, .pdf)
        outlastAdmitWindow()
        root.cmdTogglePDFPanel()
        XCTAssertEqual(root.trailingPanelStateForTesting, .shown, "taking the PDF down uncovers the outline")
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
