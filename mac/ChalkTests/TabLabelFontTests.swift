import CoreText
import ChalkKit
import XCTest
@testable import Chalk

/// The tab label's font must survive the synthetic-oblique construction.
///
/// A preview tab is shown by SLANT, and no IBM Plex Mono italic face is
/// bundled, so the upright face is sheared through a font-descriptor matrix.
/// On 2026-08-18 the AppKit twin of this code came back at `slant × size`
/// (2.55pt for a 12pt font): every preview tab's label rendered as an
/// invisible smear, its chip shrank to a blank stub, and the Mac tab row read
/// as empty from the Library divider to the active tab
/// (docs/issues/2026-08-18-mac-tabs-vanish-when-the-library-is-open.md).
///
/// Nothing caught it, because a font matrix produces no error — just a wrong
/// number that only shows up on screen. These assertions are the cheap check
/// that was missing: the slanted font is still the size we asked for, and it
/// still measures text.
@MainActor
final class TabLabelFontTests: XCTestCase {
    private let size = ChalkMetrics.tabFontSize

    func testTheObliqueFontKeepsTheSizeItWasAskedFor() {
        let oblique = NSFont.chalkMono(size: size, weight: .regular, oblique: true)

        XCTAssertEqual(oblique.pointSize, size, accuracy: 0.01,
                       "the slant matrix swallowed the point size — labels render invisibly small")
    }

    func testTheObliqueFontKeepsTheSizeAtEveryWeightTheStripUses() {
        for weight in [NSFont.Weight.regular, .medium] {
            let oblique = NSFont.chalkMono(size: size, weight: weight, oblique: true)
            XCTAssertEqual(oblique.pointSize, size, accuracy: 0.01,
                           "weight \(weight.rawValue): slanted font lost its size")
        }
    }

    func testASlantedLabelStillMeasuresTheSameWidthAsAnUprightOne() {
        // The shear must not change advances: the strip measures chips from
        // this width, so a font that measures near zero produces a chip with
        // no room for its own label — the 2026-08-18 failure, stated as
        // geometry rather than as a point size.
        let upright = NSFont.chalkMono(size: size, weight: .regular)
        let oblique = NSFont.chalkMono(size: size, weight: .regular, oblique: true)
        let sample = "0_introduction.tex"

        let uprightWidth = (sample as NSString)
            .size(withAttributes: [.font: upright]).width
        let obliqueWidth = (sample as NSString)
            .size(withAttributes: [.font: oblique]).width

        XCTAssertGreaterThan(uprightWidth, 40, "the upright face itself must measure")
        XCTAssertEqual(obliqueWidth, uprightWidth, accuracy: 1.0,
                       "slanting changed the advances; chip widths would drift with preview state")
    }

    /// Not the reported bug, but found while measuring it and worth pinning:
    /// `NSFont(name: "IBMPlexMono", …)` is nil — the bundled regular face's
    /// PostScript name is `IBMPlexMono-Regular`. Whatever the lookup resolves
    /// to, the result has to be MONOSPACED, or the two-run labels and the
    /// chip-width arithmetic are computed against a proportional face.
    /// The bundled face, found: `ATSApplicationFontsPath` in the Info.plist
    /// registers the fonts beside the editor bundle, and a wrong path falls
    /// back silently to the system mono.
    func testTheStripFontIsTheBundledPlexMono() {
        for weight in [NSFont.Weight.regular, .medium, .semibold] {
            XCTAssertEqual(NSFont.chalkMono(size: size, weight: weight).familyName, "IBM Plex Mono",
                           "weight \(weight.rawValue) fell back to the system mono")
        }
    }

    func testTheStripFontIsMonospacedWhateverTheLookupResolvesTo() {
        let font = NSFont.chalkMono(size: size, weight: .regular)
        let narrow = ("iiiiiiiiii" as NSString).size(withAttributes: [.font: font]).width
        let wide = ("mmmmmmmmmm" as NSString).size(withAttributes: [.font: font]).width

        XCTAssertEqual(narrow, wide, accuracy: 0.5,
                       "the tab font is not monospaced: 'i' and 'm' advance differently")
    }

    // MARK: - The oblique face is really slanted (no italic file is bundled)

    /// Read through CoreText, NOT `NSFont.fontDescriptor.matrix`: NSFont
    /// rebuilds its descriptor from name+size and reports an identity matrix
    /// even when the glyphs are genuinely sheared. CTFontGetMatrix is the only
    /// accessor that sees the transform.
    func testObliqueMonoIsShearedAtTheSameSizeAsUpright() {
        let upright = NSFont.chalkMono(size: 13, weight: .medium)
        let slanted = NSFont.chalkMono(size: 13, weight: .medium, oblique: true)
        XCTAssertEqual(slanted.pointSize, upright.pointSize, accuracy: 0.01,
                       "size 0 must keep the descriptor's size — passing it alongside a matrix double-applies the scale")
        XCTAssertEqual(CTFontGetMatrix(slanted as CTFont).c, ChalkMetrics.obliqueSlant,
                       accuracy: 0.001, "no slant means no preview cue at all")
        XCTAssertEqual(CTFontGetMatrix(upright as CTFont).c, 0, accuracy: 0.001)
        XCTAssertEqual(slanted.familyName, upright.familyName,
                       "the slant must stay inside IBM Plex Mono — no family swap mid-row")
    }
}
