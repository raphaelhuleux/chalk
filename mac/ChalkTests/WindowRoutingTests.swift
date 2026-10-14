import XCTest
import ChalkKit
@testable import Chalk

/// The app-target half of the multi-window routing contracts: the strip push
/// payload (built from `TabItem`) and the two-window save that identity
/// routing exists to fix. The pure predicates moved to ChalkKit's
/// `WindowRoutingTests` when `WindowRouting` did.
final class WindowRoutingTests: XCTestCase {
    // MARK: - Push payload (single source of truth = the scene's tabs model)

    func testStripPayloadCarriesPreviewAndActiveForEveryTab() throws {
        // R1 rendered a stale set with the preview tab missing and the wrong
        // chip active. Every push is the full snapshot: preview and active are
        // explicit per tab in every payload, so no update can drop them.
        let items = [
            TabItem(id: UUID(), name: "conflict-test.md", isDirty: true,
                    isActive: false, isPreview: false, folder: "test-docs"),
            TabItem(id: UUID(), name: "Welcome.md", isDirty: false,
                    isActive: true, isPreview: true),
        ]
        let payload = WindowRouting.stripPayload(items)
        XCTAssertEqual(payload.count, 2)
        for (item, dict) in zip(items, payload) {
            XCTAssertEqual(dict["id"] as? String, item.id.uuidString)
            XCTAssertEqual(dict["name"] as? String, item.name)
            XCTAssertEqual(dict["dirty"] as? Bool, item.isDirty)
            XCTAssertEqual(dict["active"] as? Bool, item.isActive,
                           "active must be explicit in every push, never inferred")
            XCTAssertEqual(dict["preview"] as? Bool, item.isPreview,
                           "the preview (dimmed) flag must survive every push")
        }
        let welcome = try XCTUnwrap(payload.last)
        XCTAssertEqual(welcome["preview"] as? Bool, true)
        XCTAssertEqual(welcome["active"] as? Bool, true)
        // Folder prefix (option 2a): carried when present, KEY OMITTED when
        // absent — StripTab decodes a missing key as nil, and an empty string
        // would render as a bare "/" prefix.
        let first = try XCTUnwrap(payload.first)
        XCTAssertEqual(first["folder"] as? String, "test-docs")
        XCTAssertNil(welcome["folder"],
                     "a draft/root tab must omit the folder key entirely")
    }

    // MARK: - Save path end to end (two windows, same document)

    private func tempFile(contents: String) throws -> URL {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("chalk-routing-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("doc.md")
        try Data(contents.utf8).write(to: url)
        return url
    }

    /// Open `url` in a fresh controller/surface pair, wired like a real tab
    /// (FakeEditorSurface pattern, mirrors CrossWindowSyncTests). The spy is
    /// retained by `spies` so dirty callbacks stay wired for the whole test.
    private var spies: [DirtySpy] = []

    private func makeOpenController(for url: URL) -> (DocumentController, FakeEditorSurface) {
        let surface = FakeEditorSurface()
        let controller = DocumentController(surface: surface)
        let spy = DirtySpy()
        controller.delegate = spy
        spies.append(spy)
        surface.signalReady()
        let opened = expectation(description: "open \(url.lastPathComponent)")
        spy.onDirtyChange = { _ in opened.fulfill() }
        controller.open(url: url)
        wait(for: [opened], timeout: 5)
        spy.onDirtyChange = nil
        return (controller, surface)
    }

    /// Reproduces the live defect shape, then proves the fix: the same file is
    /// open in window A (clean) and window B (dirty). Dispatching save to the
    /// controller picked by a STALE UIKit key flag is a silent no-op — save
    /// reports success, disk keeps the old text, B stays dirty (exactly what
    /// three Cmd+S presses did live). Dispatching to the controller picked by
    /// the identity binding flushes B's text.
    func testSaveRoutedByIdentityFlushesTheDirtyWindow() throws {
        let url = try tempFile(contents: "# One\n")
        let (a, _) = makeOpenController(for: url)
        let (b, surfaceB) = makeOpenController(for: url)
        b.editor(surfaceB, didEdit: "# One\nfrom window B\n")
        XCTAssertTrue(b.isDirty)
        let windows = [a, b] // index 0 = window A, 1 = window B

        // The defect: stale key flag names A; B is the AppKit key window but
        // unbound (pre-fix there was no binding at all).
        let staleIndex = try XCTUnwrap(WindowRouting.shellTargetIndex(
            boundToActiveWindow: [false, false], uikitKey: [true, false]))
        XCTAssertEqual(staleIndex, 0)
        let silentNoOp = expectation(description: "misrouted save completes")
        windows[staleIndex].save { ok in
            XCTAssertTrue(ok, "the misrouted save even reports success — fully silent")
            silentNoOp.fulfill()
        }
        wait(for: [silentNoOp], timeout: 5)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "# One\n",
                       "disk must show why the user's edits never landed")
        XCTAssertTrue(b.isDirty, "the real window's buffer stays dirty, dot and all")

        // The fix: B's scene is bound to the AppKit key window's number, so
        // identity routing picks B regardless of the stale UIKit flag.
        let boundIndex = try XCTUnwrap(WindowRouting.shellTargetIndex(
            boundToActiveWindow: [false, true], uikitKey: [true, false]))
        XCTAssertEqual(boundIndex, 1)
        let saved = expectation(description: "identity-routed save flushes")
        windows[boundIndex].save { ok in
            XCTAssertTrue(ok)
            saved.fulfill()
        }
        wait(for: [saved], timeout: 5)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "# One\nfrom window B\n")
        XCTAssertFalse(b.isDirty)
    }}
