import XCTest
@testable import ChalkKit

final class DocumentBufferTests: XCTestCase {
    func testStartsCleanWithInitialText() {
        let b = DocumentBuffer(initial: "hello")
        XCTAssertFalse(b.isDirty)
        XCTAssertEqual(b.currentText, "hello")
        XCTAssertNil(b.textToFlush())
    }

    func testEditMarksDirtyAndBuffers() {
        let b = DocumentBuffer(initial: "hello")
        b.recordEdit("hello world")
        XCTAssertTrue(b.isDirty)
        XCTAssertEqual(b.currentText, "hello world")
        XCTAssertEqual(b.textToFlush(), "hello world")
        XCTAssertEqual(b.savedText, "hello", "edit must not touch saved baseline")
    }

    func testEditBackToSavedIsNotDirty() {
        let b = DocumentBuffer(initial: "hello")
        b.recordEdit("hello!")
        b.recordEdit("hello")
        XCTAssertFalse(b.isDirty, "reverting to saved text clears dirtiness")
        XCTAssertNil(b.textToFlush())
    }

    func testConfirmFlushClearsPending() {
        let b = DocumentBuffer(initial: "a")
        b.recordEdit("b")
        let toWrite = b.textToFlush()!
        b.confirmFlush(toWrite)
        XCTAssertFalse(b.isDirty)
        XCTAssertEqual(b.savedText, "b")
        XCTAssertNil(b.pendingText)
    }

    func testEditDuringFlushStaysPending() {
        let b = DocumentBuffer(initial: "a")
        b.recordEdit("b")
        let toWrite = b.textToFlush()! // "b" is being written
        b.recordEdit("c")             // user types again mid-write
        b.confirmFlush(toWrite)        // "b" landed
        XCTAssertTrue(b.isDirty, "the newer edit 'c' must remain pending")
        XCTAssertEqual(b.currentText, "c")
        XCTAssertEqual(b.savedText, "b")
    }

    func testAdoptExternalResetsBaseline() {
        let b = DocumentBuffer(initial: "a")
        b.recordEdit("local")
        b.adoptExternal("fromDisk")
        XCTAssertFalse(b.isDirty)
        XCTAssertEqual(b.currentText, "fromDisk")
        XCTAssertNil(b.pendingText)
    }

    func testConfirmFlushWithNewerPendingEqualToWrittenTextIsClean() {
        // Degenerate but legal: the mid-write edit restored exactly the text
        // being written. After the flush lands nothing differs from disk.
        let b = DocumentBuffer(initial: "a")
        b.recordEdit("b")
        let toWrite = b.textToFlush()!
        b.recordEdit("c")
        b.recordEdit("b") // back to what the in-flight write will produce
        b.confirmFlush(toWrite)
        XCTAssertFalse(b.isDirty)
    }

    /// Keystroke-path cost: one `recordEdit` + the dirty reads DocumentController
    /// does per edit, on a ~200KB document. Guards the stored-flag design —
    /// `isDirty` reads must not re-compare the full strings.
    func testKeystrokePathCostOnLargeDocument() {
        let base = String(repeating: "line of prose text for the buffer\n", count: 6000) // ~200KB
        let b = DocumentBuffer(initial: base)
        measure {
            var text = base
            for i in 0..<50 {
                text += String(i % 10)
                b.recordEdit(text)
                _ = b.isDirty
                _ = b.isDirty // DocumentController reads it twice per edit
            }
            b.adoptExternal(base)
        }
    }

    func testLanguageFromExtension() {
        XCTAssertEqual(EditorLanguage(fileExtension: "tex"), .tex)
        XCTAssertEqual(EditorLanguage(fileExtension: "TEX"), .tex)
        XCTAssertEqual(EditorLanguage(fileExtension: "md"), .md)
        XCTAssertEqual(EditorLanguage.tex.fileExtension, "tex")
        XCTAssertEqual(EditorLanguage.md.fileExtension, "md")
        XCTAssertEqual(EditorLanguage(fileExtension: "markdown"), .md)
        XCTAssertEqual(EditorLanguage(fileExtension: "qmd"), .md)
        XCTAssertEqual(EditorLanguage(fileExtension: ""), .md)
    }
}
