import XCTest
import ChalkKit
@testable import Chalk

/// The view-mode DEFAULT: cycle order, wire values, preference fallback, and
/// the one config payload that carries every shell-owned editor-core field.
@MainActor
final class ViewModeTests: XCTestCase {
    func testCycleOrderAndTitles() {
        XCTAssertEqual(ViewMode.preview.next, .mixed)
        XCTAssertEqual(ViewMode.mixed.next, .source)
        XCTAssertEqual(ViewMode.source.next, .preview)
        XCTAssertEqual(ViewMode.allCases.map(\.title), ["Preview", "Mixed", "Source"])
        XCTAssertEqual(ViewMode.allCases.map(\.rawValue), ["preview", "mixed", "source"])
    }

    func testPreferenceFallsBackToPreviewOnUnknownRawValue() {
        let previous = UserDefaults.standard.string(forKey: "chalk.viewMode")
        defer {
            if let previous {
                UserDefaults.standard.set(previous, forKey: "chalk.viewMode")
            } else {
                UserDefaults.standard.removeObject(forKey: "chalk.viewMode")
            }
        }
        UserDefaults.standard.set("bogus", forKey: "chalk.viewMode")
        XCTAssertEqual(Preferences.viewMode, .preview)
        Preferences.viewMode = .mixed
        XCTAssertEqual(Preferences.viewMode, .mixed)
    }

    /// editor-core sanitizes the whole message: a field left out of the
    /// payload falls back to its default. So the payload must carry EVERY
    /// shell-owned field every time, or a view-mode push would reset the
    /// editing mode, a theme change the view mode, and so on.
    func testEditorConfigPayloadCarriesEveryShellField() {
        let previousMode = Preferences.editingMode
        let previousView = Preferences.viewMode
        let previousTheme = Preferences.colorTheme
        defer {
            Preferences.editingMode = previousMode
            Preferences.viewMode = previousView
            Preferences.colorTheme = previousTheme
        }
        Preferences.editingMode = .typewriter
        Preferences.viewMode = .mixed
        Preferences.colorTheme = .latex
        XCTAssertEqual(
            Preferences.editorConfigPayload(),
            .object(["editingMode": .string("typewriter"), "viewMode": .string("mixed"),
                     "markdownStyle": .string("typeset")])
        )
        Preferences.colorTheme = .ink
        XCTAssertEqual(
            Preferences.editorConfigPayload(),
            .object(["editingMode": .string("typewriter"), "viewMode": .string("mixed"),
                     "markdownStyle": .string("source")])
        )
    }

    /// `editingMode` is a per-WINDOW value, not the stored global preference —
    /// a caller broadcasting to one window (or seeding a fresh container) must
    /// be able to name that window's own mode regardless of what's persisted,
    /// or a settings change would reconfigure a zen window's editors to
    /// whichever window's mode was stored last while its chrome stayed in zen.
    func testEditorConfigPayloadTakesAnExplicitEditingModeOverTheStoredPreference() {
        let previousMode = Preferences.editingMode
        defer { Preferences.editingMode = previousMode }
        Preferences.editingMode = .normal
        XCTAssertEqual(
            Preferences.editorConfigPayload(editingMode: .zen),
            .object(["editingMode": .string("zen"), "viewMode": .string(Preferences.viewMode.rawValue),
                     "markdownStyle": .string(Preferences.colorTheme.markdownStyle)])
        )
    }

    /// A window's `setEditingMode` must push ITS OWN mode to every one of its
    /// own open tabs — not the global `Preferences.editingMode`, which could
    /// belong to a DIFFERENT window that changed its mode more recently. Before
    /// the fix, `EditorContainerViewController.applyEditorConfig()` read the
    /// global preference directly, so a second window's `setEditingMode` call
    /// would silently reconfigure THIS window's tabs too the next time
    /// something re-applied settings (e.g. the Settings scene's broadcast).
    @MainActor
    func testSetEditingModePushesThisWindowsOwnModeToEveryOpenTab() {
        let previousMode = Preferences.editingMode
        defer { Preferences.editingMode = previousMode }

        let root = RootSplitViewController(initialContent: .openEmpty)
        root.loadViewIfNeeded()
        root.editor.newFile()
        root.editor.newFile()
        XCTAssertEqual(root.editor.tabCountForTesting, 2)

        // A DIFFERENT window set the global preference to something else —
        // this window's own push must win regardless.
        Preferences.editingMode = .focus

        root.setEditingMode(.zen)

        for index in 0..<root.editor.tabCountForTesting {
            let config = root.editor.tabSurfaceForTesting(at: index)?.editorConfigForTesting
            XCTAssertEqual(
                config,
                .object(["editingMode": .string("zen"), "viewMode": .string(Preferences.viewMode.rawValue),
                         "markdownStyle": .string(Preferences.colorTheme.markdownStyle)]),
                "tab \(index) did not get this window's own editing mode"
            )
        }
    }
}
