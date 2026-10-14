import XCTest
import ChalkKit
@testable import Chalk

/// The writing-surface settings the General pane gained: text size, text
/// column width, interline spacing, wrapped-prose alignment, and the file type
/// new documents get.
///
/// `Preferences` reads `UserDefaults.standard` with no injectable suite, so
/// every test here saves and restores the raw key (the ChromeAutoHideTests
/// idiom) rather than leaving the test host's defaults rewritten.
@MainActor
final class EditorPreferencesTests: XCTestCase {
    private let measureKey = "chalk.editorMeasure"
    private let lineHeightKey = "chalk.editorLineHeight"
    private let alignmentKey = "chalk.textAlignment"
    private let fileTypeKey = "chalk.defaultFileType"

    /// Run `body` with `key` cleared, then put whatever was there back.
    private func withCleanKey(_ key: String, _ body: () -> Void) {
        let previous = UserDefaults.standard.object(forKey: key)
        defer {
            if let previous {
                UserDefaults.standard.set(previous, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
        UserDefaults.standard.removeObject(forKey: key)
        body()
    }

    // MARK: - Defaults

    /// A fresh install must reproduce exactly what chalk-theme.css bakes in:
    /// a 960px centered column, ragged right, Markdown. If these drift the
    /// shell starts overriding the stylesheet on first launch for no reason.
    func testDefaultsMatchTheStylesheet() {
        withCleanKey(measureKey) {
            XCTAssertEqual(Preferences.editorMeasure, 960,
                           "960 is the max-width baked into chalk-theme.css")
        }
        withCleanKey(lineHeightKey) {
            XCTAssertEqual(Preferences.editorLineHeight, 1.6,
                           "1.6 is the --chalk-line-height baked into chalk-theme.css")
        }
        withCleanKey(alignmentKey) {
            XCTAssertEqual(Preferences.textAlignment, .left)
        }
        withCleanKey(fileTypeKey) {
            XCTAssertEqual(Preferences.defaultFileType, .md)
        }
    }

    // MARK: - The measure

    func testMeasureClampsAtBothEnds() {
        withCleanKey(measureKey) {
            Preferences.editorMeasure = 10
            XCTAssertEqual(Preferences.editorMeasure, Preferences.editorMeasureRange.lowerBound)

            Preferences.editorMeasure = 99_999
            XCTAssertEqual(Preferences.editorMeasure, Preferences.editorMeasureRange.upperBound)
        }
    }

    func testMeasureRoundTripsAValueInRange() {
        withCleanKey(measureKey) {
            Preferences.editorMeasure = 720
            XCTAssertEqual(Preferences.editorMeasure, 720)
        }
    }

    /// A value written by some other build that falls outside today's range
    /// must be clamped on the way OUT too, not just on the way in — otherwise
    /// it collapses the column until the reader touches the slider.
    func testOutOfRangeStoredValueIsClampedOnRead() {
        withCleanKey(measureKey) {
            UserDefaults.standard.set(80.0, forKey: measureKey)
            XCTAssertEqual(Preferences.editorMeasure, Preferences.editorMeasureRange.lowerBound)
        }
    }

    // MARK: - The line height

    func testLineHeightClampsAtBothEnds() {
        withCleanKey(lineHeightKey) {
            Preferences.editorLineHeight = 0.2
            XCTAssertEqual(Preferences.editorLineHeight,
                           Preferences.editorLineHeightRange.lowerBound)

            Preferences.editorLineHeight = 9
            XCTAssertEqual(Preferences.editorLineHeight,
                           Preferences.editorLineHeightRange.upperBound)
        }
    }

    func testLineHeightRoundTripsAValueInRange() {
        withCleanKey(lineHeightKey) {
            Preferences.editorLineHeight = 2.0
            XCTAssertEqual(Preferences.editorLineHeight, 2.0, accuracy: 0.0001)
        }
    }

    /// Same out-of-range-on-read guard as the measure: a stored 0.3 from some
    /// other build would stack the lines on top of each other.
    func testOutOfRangeStoredLineHeightIsClampedOnRead() {
        withCleanKey(lineHeightKey) {
            UserDefaults.standard.set(0.3, forKey: lineHeightKey)
            XCTAssertEqual(Preferences.editorLineHeight,
                           Preferences.editorLineHeightRange.lowerBound)
        }
    }

    // MARK: - Unknown raw values

    func testUnknownAlignmentFallsBackToLeft() {
        withCleanKey(alignmentKey) {
            UserDefaults.standard.set("bogus-future-alignment", forKey: alignmentKey)
            XCTAssertEqual(Preferences.textAlignment, .left)
        }
    }

    func testUnknownFileTypeFallsBackToMarkdown() {
        withCleanKey(fileTypeKey) {
            UserDefaults.standard.set("bogus-future-type", forKey: fileTypeKey)
            XCTAssertEqual(Preferences.defaultFileType, .md)
        }
    }

    // MARK: - What the enums hand to the layers below

    /// The rawValue doubles as the file extension, so a typo here would create
    /// files named `Untitled.markdown`.
    func testFileTypeCarriesExtensionAndLanguage() {
        XCTAssertEqual(DefaultFileType.md.fileExtension, "md")
        XCTAssertEqual(DefaultFileType.tex.fileExtension, "tex")
        XCTAssertEqual(DefaultFileType.md.language, .md)
        XCTAssertEqual(DefaultFileType.tex.language, .tex)
    }

    /// These strings are interpolated straight into the CSS variable, and
    /// `start` (not `left`) is deliberate so a future RTL document follows the
    /// writing direction.
    func testAlignmentCarriesCSSValues() {
        XCTAssertEqual(EditorTextAlignment.left.cssValue, "start")
        XCTAssertEqual(EditorTextAlignment.justified.cssValue, "justify")
    }

    /// Both enums drive segmented controls built from `allCases`, so the order
    /// is what the reader sees and the selected index depends on it.
    func testSegmentedControlOrdering() {
        XCTAssertEqual(EditorTextAlignment.allCases, [.left, .justified])
        XCTAssertEqual(DefaultFileType.allCases, [.md, .tex])
    }

    // MARK: - The broadcast chain

    private func loadedRoot() -> RootSplitViewController {
        let root = RootSplitViewController()
        root.loadViewIfNeeded()
        root.view.frame = CGRect(x: 0, y: 0, width: 1180, height: 820)
        root.view.layoutIfNeeded()
        return root
    }

    /// Settings runs in its own scene (its own window on Mac) with no
    /// presenter, so a preference that `SettingsBroadcast` forgets reaches no
    /// window at all and the setting looks dead. This is the regression test
    /// for that specific omission.
    func testGeneralSettingsBroadcastCarriesMeasureAndAlignment() {
        withCleanKey(measureKey) {
            withCleanKey(alignmentKey) {
                withCleanKey(lineHeightKey) {
                    let root = loadedRoot()
                    Preferences.editorMeasure = 720
                    Preferences.textAlignment = .justified
                    Preferences.editorLineHeight = 2.0

                    SettingsBroadcast.applyGeneralSettings(roots: [root])

                    XCTAssertEqual(root.editorMeasureForTesting, 720,
                                   "the column width never reached the window's tabs")
                    XCTAssertEqual(root.editorTextAlignForTesting, "justify",
                                   "the alignment never reached the window's tabs")
                    XCTAssertEqual(root.editorLineHeightForTesting ?? 0, 2.0, accuracy: 0.0001,
                                   "the line spacing never reached the window's tabs")
                }
            }
        }
    }

    /// The per-window apply must read the CURRENT preference, not a value
    /// captured at launch.
    func testApplyReadsThePreferenceAtCallTime() {
        withCleanKey(measureKey) {
            let root = loadedRoot()
            Preferences.editorMeasure = 560
            root.applyEditorMeasure()
            XCTAssertEqual(root.editorMeasureForTesting, 560)

            Preferences.editorMeasure = 1200
            root.applyEditorMeasure()
            XCTAssertEqual(root.editorMeasureForTesting, 1200)
        }
    }
}
