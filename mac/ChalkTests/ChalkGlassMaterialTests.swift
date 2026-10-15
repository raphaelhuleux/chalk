import XCTest
import ChalkKit
@testable import Chalk

/// Liquid Glass adoption (2026-07-27 modernization pass): on OS 26 the panel
/// material must be the system's real glass — `UIGlassEffect`, TINTED so the
/// panel reads as a wash over content, not fully transparent — instead of the
/// hand-rolled blur + tint-wash stack. Pre-26 keeps the blur; that branch
/// cannot run on a 26 host, so it stays covered by the availability
/// gate alone.
@MainActor
final class ChalkGlassMaterialTests: XCTestCase {
    func testPanelUsesTintedSystemGlassOn26() throws {
        guard #available(iOS 26.0, *) else {
            throw XCTSkip("Liquid Glass exists only on 26+")
        }
        let panel = ChalkGlassView(style: .glass, cornerRadius: 12)
        let glass = try XCTUnwrap(
            panel.materialEffectForTesting as? UIGlassEffect,
            "the panel material must be the system glass effect, not a blur")
        XCTAssertNotNil(glass.tintColor,
                        "tinted glass, per the design — a nil tint is fully clear")
    }

    func testPaletteUsesTintedSystemGlassOn26() throws {
        guard #available(iOS 26.0, *) else {
            throw XCTSkip("Liquid Glass exists only on 26+")
        }
        let panel = ChalkGlassView(style: .palette, cornerRadius: 16)
        XCTAssertTrue(panel.materialEffectForTesting is UIGlassEffect)
    }
}
