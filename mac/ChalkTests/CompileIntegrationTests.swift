import XCTest
import ChalkKit
@testable import Chalk

/// ⌘R on a chapter, end to end in a hosted window: the root is found from
/// the Library, compiled with this Mac's TeX, and its PDF lands in the slot.
/// Skipped where no TeX is installed.
@MainActor
final class CompileIntegrationTests: XCTestCase {
    private var windows: [NSWindow] = []
    private var dir: URL!
    private var previousMode: EditingMode!
    private var previousEngine: LatexEngineChoice!

    override func setUpWithError() throws {
        try super.setUpWithError()
        let locator = CompileController.makeLocator()
        try XCTSkipUnless(locator.locate("pdflatex") != nil, "no TeX on this machine")
        previousMode = Preferences.editingMode
        Preferences.editingMode = .normal
        previousEngine = Preferences.latexEngine
        // Direct passes: the one engine every TeX Live install has.
        Preferences.latexEngine = .direct
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("chalk-compile-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("sections"), withIntermediateDirectories: true)
        try "\\documentclass{article}\n\\begin{document}\n\\input{sections/intro}\n\\end{document}\n"
            .write(to: dir.appendingPathComponent("main.tex"), atomically: true, encoding: .utf8)
        try "Hello from the intro.\n".write(to: dir.appendingPathComponent("sections/intro.tex"), atomically: true, encoding: .utf8)
    }

    override func tearDown() {
        if let previousMode { Preferences.editingMode = previousMode }
        if let previousEngine { Preferences.latexEngine = previousEngine }
        for window in windows { dismantleHostedSidebar(window) }
        windows = []
        if let dir { try? FileManager.default.removeItem(at: dir) }
        super.tearDown()
    }

    func testCompilingAChapterBuildsItsRootAndShowsThePDF() throws {
        let window = NSWindow.hostedForTesting(frame: CGRect(x: 0, y: 0, width: 1400, height: 820))
        let root = RootSplitViewController(initialContent: .openEmpty)
        root.motionPolicyForTesting = .instant
        window.rootViewController = root
        window.isHidden = false
        windows.append(window)
        root.loadViewIfNeeded()
        root.setLibraryLocationsForTesting([dir])
        let editor = root.editorForTesting
        editor.open(url: dir.appendingPathComponent("sections/intro.tex"))

        // The tab's document loads asynchronously; Compile saves it first.
        let ready = expectation(description: "tab ready")
        func waitForTab() {
            if editor.canCompileActive { ready.fulfill() } else { DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: waitForTab) }
        }
        waitForTab()
        wait(for: [ready], timeout: 10)

        root.cmdCompile()
        let mainTeX = dir.appendingPathComponent("main.tex").standardizedFileURL
        let done = expectation(description: "compiled")
        func poll() {
            if case .finished = editor.compiler.states[mainTeX]?.phase { done.fulfill() } else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: poll)
            }
        }
        poll()
        wait(for: [done], timeout: 60)

        let state = try XCTUnwrap(editor.compiler.states[mainTeX])
        XCTAssertEqual(state.phase, .finished(succeeded: true), state.log)
        XCTAssertEqual(root.trailingPanelStateForTesting, .pdf)
        XCTAssertEqual(editor.pdfPanel.shownPDF?.standardizedFileURL, dir.appendingPathComponent("main.pdf").standardizedFileURL)
    }
}
