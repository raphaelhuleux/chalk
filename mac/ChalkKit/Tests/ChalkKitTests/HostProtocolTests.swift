import XCTest
@testable import ChalkKit

final class HostProtocolTests: XCTestCase {
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    private func roundTripHostToEditor(_ msg: HostToEditorMessage) throws {
        let data = try encoder.encode(msg)
        let back = try decoder.decode(HostToEditorMessage.self, from: data)
        XCTAssertEqual(msg, back)
    }

    private func roundTripEditorToHost(_ msg: EditorToHostMessage) throws {
        let data = try encoder.encode(msg)
        let back = try decoder.decode(EditorToHostMessage.self, from: data)
        XCTAssertEqual(msg, back)
    }

    // MARK: round-trips for all 9 messages

    func testHostToEditorRoundTrips() throws {
        try roundTripHostToEditor(.initialize(text: "x = 1", language: .tex, editorConfig: nil, epoch: nil))
        try roundTripHostToEditor(.initialize(
            text: "hi", language: .md,
            editorConfig: .object(["fontSize": .number(16), "wordWrap": .bool(true)]),
            epoch: 3
        ))
        try roundTripHostToEditor(.update(text: "new text", epoch: nil))
        try roundTripHostToEditor(.update(text: "new text", epoch: 7))
        try roundTripHostToEditor(.themeColors(ThemeColors(keyword: "#ea6a5f", tagName: "#abc", specialVariable: "#def")))
        try roundTripHostToEditor(.headingColors(HeadingColors(h1: "#111", h3: "#333", h6: "#666")))
        try roundTripHostToEditor(.editorConfig(.object(["lineNumbers": .bool(false)])))
        // The native editing-mode payload (editor-core's EditorConfig.editingMode).
        try roundTripHostToEditor(.editorConfig(.object(["editingMode": .string("focus")])))
        try roundTripHostToEditor(.editorConfig(.object([
            "editingMode": .string("normal"), "viewMode": .string("mixed"),
        ])))
        try roundTripHostToEditor(.hsnips(content: "snippet ;; $$\n"))
    }

    func testEditorToHostRoundTrips() throws {
        try roundTripEditorToHost(.ready)
        try roundTripEditorToHost(.edit(text: "buffered text", epoch: nil))
        try roundTripEditorToHost(.edit(text: "buffered text", epoch: 12))
        try roundTripEditorToHost(.openExternal(url: "https://example.com"))
    }

    // MARK: exact JSON key shapes (match host-port.ts)

    func testInitEncodesExpectedKeys() throws {
        let data = try encoder.encode(HostToEditorMessage.initialize(text: "a", language: .tex, editorConfig: nil, epoch: nil))
        let obj = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(obj["type"] as? String, "init")
        XCTAssertEqual(obj["text"] as? String, "a")
        XCTAssertEqual(obj["language"] as? String, "tex")
        XCTAssertNil(obj["editorConfig"], "absent editorConfig must be omitted, not null")
        XCTAssertNil(obj["epoch"], "absent epoch must be omitted, not null (VS Code parity)")
    }

    func testUpdateEncodesEpochWhenPresent() throws {
        let data = try encoder.encode(HostToEditorMessage.update(text: "t", epoch: 9))
        let obj = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(obj["type"] as? String, "update")
        XCTAssertEqual(obj["epoch"] as? Int, 9)
    }

    func testThemeColorsUsesCamelCaseKeysAndOmitsNil() throws {
        let data = try encoder.encode(HostToEditorMessage.themeColors(ThemeColors(tagName: "#abc", specialVariable: "#def")))
        let obj = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(obj["type"] as? String, "theme-colors")
        let colors = try XCTUnwrap(obj["colors"] as? [String: Any])
        XCTAssertEqual(colors["tagName"] as? String, "#abc")
        XCTAssertEqual(colors["specialVariable"] as? String, "#def")
        XCTAssertNil(colors["keyword"], "nil color fields must be omitted")
    }

    func testHeadingColorsUsesNumericStringKeys() throws {
        let data = try encoder.encode(HostToEditorMessage.headingColors(HeadingColors(h1: "#111", h2: "#222")))
        let obj = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let colors = try XCTUnwrap(obj["colors"] as? [String: Any])
        XCTAssertEqual(colors["1"] as? String, "#111")
        XCTAssertEqual(colors["2"] as? String, "#222")
        XCTAssertNil(colors["3"])
    }

    // MARK: decode from captured wire payloads

    func testDecodeInitFromWire() throws {
        let json = #"{"type":"init","text":"\\frac{1}{2}","language":"tex"}"#
        let msg = try decoder.decode(HostToEditorMessage.self, from: Data(json.utf8))
        XCTAssertEqual(msg, .initialize(text: #"\frac{1}{2}"#, language: .tex, editorConfig: nil, epoch: nil))
    }

    func testDecodeEditFromWire() throws {
        let json = #"{"type":"edit","text":"hello"}"#
        let msg = try decoder.decode(EditorToHostMessage.self, from: Data(json.utf8))
        XCTAssertEqual(msg, .edit(text: "hello", epoch: nil))
    }

    /// The epoch echo from an epoch-aware bundle (C-5).
    func testDecodeEditWithEpochFromWire() throws {
        let json = #"{"type":"edit","text":"hello","epoch":4}"#
        let msg = try decoder.decode(EditorToHostMessage.self, from: Data(json.utf8))
        XCTAssertEqual(msg, .edit(text: "hello", epoch: 4))
    }

    func testDecodeOpenExternalFromWire() throws {
        let json = #"{"type":"open-external","url":"https://chalk.app"}"#
        let msg = try decoder.decode(EditorToHostMessage.self, from: Data(json.utf8))
        XCTAssertEqual(msg, .openExternal(url: "https://chalk.app"))
    }

    func testUnknownTypeThrows() {
        let json = #"{"type":"bogus"}"#
        XCTAssertThrowsError(try decoder.decode(HostToEditorMessage.self, from: Data(json.utf8)))
    }
}
