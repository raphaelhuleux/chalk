import XCTest
import ChalkKit
@testable import Chalk

/// What the tab row draws, across the row's own states: no tabs, one, several, more than fit;
/// the shown tab first, in the middle, last; clean and unsaved. Checked on the laid-out row and
/// the glyphs' measured ink, because the row's defects have been visual ones a frame check
/// passed: a × nearer the next name than its own, a "+" too small to find
/// (docs/issues/2026-11-16-tab-row-regressions.md).
@MainActor
final class TabRowGeometryTests: XCTestCase {
    private var window: NSWindow!
    private var strip: HeaderTabStrip!

    override func setUp() {
        super.setUp()
        window = NSWindow.hostedForTesting(frame: CGRect(x: 0, y: 0, width: 900, height: 60))
        strip = HeaderTabStrip(frame: CGRect(x: 0, y: 0, width: 900, height: ChalkMetrics.tabStripHeight))
        window.addSubview(strip)
        window.isHidden = false
    }

    override func tearDown() {
        strip.removeFromSuperview()
        window.isHidden = true
        window = nil
        strip = nil
        super.tearDown()
    }

    private var closeInk: CGSize {
        HeaderTabStrip.closeGlyphImageForTesting?.inkSizeForTesting ?? .zero
    }

    private var spacing: TabCloseSpacing {
        TabCloseSpacing(labelPadding: ChalkMetrics.tabLabelPadding, innerGap: ChalkMetrics.tabInnerGap,
                        slotWidth: ChalkMetrics.tabSlotWidth, tabGap: ChalkMetrics.tabGap,
                        glyphInkWidth: closeInk.width)
    }

    /// The row's own cells. Names vary in length so a rule cannot pass on one lucky width.
    private struct Cell {
        let name: String
        let items: [TabItem]
    }

    private static let names = ["notes.md", "a.tex", "Untitled 2", "least-squares.md", "b", "chapter-03-results.tex"]

    private var cells: [Cell] {
        var cells: [Cell] = [Cell(name: "empty", items: [])]
        for count in [1, 3, 6] {
            for shown in Set([0, count / 2, count - 1]).sorted() {
                for dirty in [false, true] {
                    let items = (0..<count).map { i in
                        TabItem(id: UUID(), name: Self.names[i], isDirty: dirty && i % 2 == 1,
                                isActive: i == shown, isPreview: false)
                    }
                    cells.append(Cell(name: "\(count) tabs, shown \(shown), dirty \(dirty)", items: items))
                }
            }
        }
        return cells
    }

    private func show(_ cell: Cell, width: CGFloat = 900) {
        strip.frame.size.width = width
        strip.update(cell.items)
        strip.needsLayout = true
        strip.layoutSubtreeIfNeeded()
        // The scroll to the shown tab is queued behind the update.
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.02))
        strip.layoutSubtreeIfNeeded()
    }

    // MARK: The close ×

    /// The shipped tokens and the shipped glyph keep the × with its own tab.
    func testTheTokensKeepTheCloseGlyphWithItsTab() {
        XCTAssertGreaterThan(closeInk.width, 0)
        XCTAssertEqual(spacing.violations, [], "tokens: \(spacing)")
    }

    /// The laid-out row agrees with the arithmetic: every tab's slot, reserved or hanging, puts
    /// the × at least twice as far from the next name as from its own, and a hanging slot ends
    /// before the next tab starts.
    func testEveryCloseGlyphSitsWithItsOwnTab() throws {
        var checked = 0
        for cell in cells where cell.items.count > 1 {
            show(cell)
            for (item, next) in zip(cell.items, cell.items.dropFirst()) {
                let label = try XCTUnwrap(strip.labelFrameForTesting(item.id), cell.name)
                let slot = try XCTUnwrap(strip.slotFrameForTesting(item.id), cell.name)
                let nextLabel = try XCTUnwrap(strip.labelFrameForTesting(next.id), cell.name)
                let nextItem = try XCTUnwrap(strip.tabFrameForTesting(next.id), cell.name)
                let inkMinX = slot.midX - closeInk.width / 2
                let inkMaxX = slot.midX + closeInk.width / 2
                let own = inkMinX - label.maxX
                let toNext = nextLabel.minX - inkMaxX
                let context = "\(cell.name), \(item.name): × \(own)pt from its name, \(toNext)pt from the next"
                XCTAssertGreaterThan(own, 0, context)
                XCTAssertGreaterThanOrEqual(toNext, TabCloseSpacing.minimumSeparationRatio * own - 0.5, context)
                XCTAssertGreaterThanOrEqual(toNext, TabCloseSpacing.minimumNextGap - 0.5, context)
                XCTAssertLessThanOrEqual(slot.maxX, nextItem.minX + 0.5,
                                         "\(cell.name), \(item.name): the slot reaches into the next tab")
                checked += 1
            }
        }
        XCTAssertGreaterThan(checked, 40, "the cells must actually lay out neighbouring tabs")
    }

    // MARK: The "+"

    /// The "+" stays inside the row and clear of the names, in every cell, the empty one included
    /// (where it is the only thing on the row). Names draw only inside their scroll view, so
    /// that clip ending a gap before the "+" is what keeps them apart, scrolled or not.
    func testTheNewTabButtonNeverTouchesANameAndStaysInTheRow() throws {
        for cell in cells {
            show(cell, width: cell.items.count == 6 ? 420 : 900)
            let plus = strip.newTabButtonFrameForTesting
            let clip = strip.namesClipFrameForTesting
            XCTAssertFalse(plus.isEmpty, cell.name)
            XCTAssertTrue(strip.bounds.insetBy(dx: -0.5, dy: -0.5).contains(plus), "\(cell.name): + at \(plus)")
            XCTAssertLessThanOrEqual(clip.maxX, plus.minX - ChalkMetrics.tabGap + 0.5,
                                     "\(cell.name): names may draw up to \(clip.maxX), + starts at \(plus.minX)")
        }
    }

    // MARK: Overflow

    /// More tabs than fit: the names scroll, the chevron shows, and the shown tab is still on
    /// screen. Once the chevron's width was left free and the names' clip came out 0pt wide.
    func testAnOverflowingRowStillShowsItsNames() throws {
        for cell in cells where cell.items.count == 6 {
            show(cell, width: 420)
            let clip = strip.namesClipFrameForTesting
            let tail = strip.bounds.width - strip.newTabButtonFrameForTesting.minX
            XCTAssertGreaterThanOrEqual(clip.width, strip.bounds.width - tail - ChalkMetrics.tabGap - 1,
                                        "\(cell.name): the names' clip is \(clip.width)pt of a \(strip.bounds.width)pt row")
            let shown = try XCTUnwrap(cell.items.first { $0.isActive })
            let label = try XCTUnwrap(strip.labelFrameForTesting(shown.id))
            XCTAssertTrue(strip.visibleNamesFrameForTesting.intersects(label),
                          "\(cell.name): the shown tab is scrolled out of sight")
        }
    }

    /// No view in the row is left to the solver's whim, in any cell.
    func testTheRowLayoutIsNeverAmbiguous() {
        for cell in cells {
            show(cell, width: cell.items.count == 6 ? 420 : 900)
            let ambiguous = strip.ambiguousViewsForTesting
            XCTAssertTrue(ambiguous.isEmpty, "\(cell.name): ambiguous \(ambiguous.map { type(of: $0) })")
        }
    }

    // MARK: Gallery

    /// Not a check: with `CHALK_TAB_GALLERY=1` in the test runner's environment
    /// (`TEST_RUNNER_CHALK_TAB_GALLERY=1 xcodebuild test ...`), writes one PNG per cell, light and
    /// dark, with the first background tab hovered, for a person to look at before calling the
    /// row clean. The path is printed (the test host is sandboxed, so it is the container's tmp).
    /// Marked deprecated only so the build's warnings-as-errors accepts `CGWindowListCreateImage`:
    /// ScreenCaptureKit needs a capture permission a test host does not have.
    @available(macOS, deprecated: 14.0)
    func testWriteGalleryWhenAsked() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["CHALK_TAB_GALLERY"] != nil,
                          "set CHALK_TAB_GALLERY to write the gallery")
        let folder = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("tab-gallery")
        try? FileManager.default.removeItem(at: folder)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        window.setContentSize(CGSize(width: 900 + ChalkMetrics.tabStripLeading, height: ChalkMetrics.tabStripHeight))
        // Clear of the traffic lights, where the band puts the row.
        strip.frame.origin.x = ChalkMetrics.tabStripLeading
        defer { strip.frame.origin.x = 0 }
        window.backgroundColor = .chalkEditorBackground
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            window.appearance = NSAppearance(named: appearance)
            for (index, cell) in cells.enumerated() {
                show(cell, width: cell.items.count == 6 ? 420 : 900)
                if let hovered = cell.items.first(where: { !$0.isActive }) { strip.setHoverForTesting(hovered.id) }
                strip.layoutSubtreeIfNeeded()
                // From the window server, not `cacheDisplay`: the names' fade is a layer mask,
                // which only the compositor applies.
                window.displayIfNeeded()
                // Past the underline's slide from the previous cell's shown tab.
                RunLoop.main.run(until: Date(timeIntervalSinceNow: ChalkMetrics.motionFast + 0.2))
                guard let image = CGWindowListCreateImage(.null, .optionIncludingWindow,
                                                          CGWindowID(window.windowNumber),
                                                          [.boundsIgnoreFraming, .bestResolution]) else { continue }
                let rep = NSBitmapImageRep(cgImage: image)
                let name = String(format: "%02d-%@-%@.png", index, appearance == .aqua ? "light" : "dark",
                                  cell.name.replacingOccurrences(of: " ", with: "_").replacingOccurrences(of: ",", with: ""))
                try rep.representation(using: .png, properties: [:])?.write(to: folder.appendingPathComponent(name))
            }
        }
        print("TAB-GALLERY>> \(folder.path)")
    }

    // MARK: One line

    /// Names, the close ×, the dot and the "+" share one centre line.
    func testEverythingOnTheRowSharesOneLine() throws {
        for cell in cells where !cell.items.isEmpty {
            show(cell)
            let line = try XCTUnwrap(strip.nameLineForTesting, cell.name)
            let plus = strip.newTabButtonFrameForTesting
            XCTAssertEqual(plus.midY, line, accuracy: 1.0, "\(cell.name): + off the name line")
            for item in cell.items {
                let slot = try XCTUnwrap(strip.slotFrameForTesting(item.id))
                XCTAssertEqual(slot.midY, line, accuracy: 1.0, "\(cell.name), \(item.name): slot off the name line")
            }
        }
    }
}
