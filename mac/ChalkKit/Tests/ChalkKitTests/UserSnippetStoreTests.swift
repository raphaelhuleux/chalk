import XCTest
@testable import ChalkKit

final class UserSnippetStoreTests: XCTestCase {
    private var defaults: UserDefaults!
    private var store: UserSnippetStore!

    override func setUpWithError() throws {
        // Isolated defaults per test run.
        let suite = "chalk-usersnippet-tests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
        store = UserSnippetStore(defaults: defaults, key: "snips")
    }

    func testStartsEmpty() {
        XCTAssertTrue(store.snippets().isEmpty)
        XCTAssertTrue(store.disabledBuiltinKeys().isEmpty)
    }

    func testUpsertInsertsAndPersists() {
        let snippet = UserSnippet(id: "s1", trigger: ";a", replacement: "\\alpha")
        store.upsert(snippet)

        let reopened = UserSnippetStore(defaults: defaults, key: "snips")
        XCTAssertEqual(reopened.snippets(), [snippet])
    }

    func testUpsertReplacesByIdPreservingOrder() {
        store.upsert(UserSnippet(id: "s1", trigger: ";a", replacement: "\\alpha"))
        store.upsert(UserSnippet(id: "s2", trigger: ";b", replacement: "\\beta"))
        store.upsert(UserSnippet(id: "s1", trigger: ";a", replacement: "\\aleph"))

        let snippets = store.snippets()
        XCTAssertEqual(snippets.map(\.id), ["s1", "s2"])
        XCTAssertEqual(snippets[0].replacement, "\\aleph")
    }

    func testRemove() {
        store.upsert(UserSnippet(id: "s1", trigger: ";a", replacement: "\\alpha"))
        store.remove(id: "s1")
        XCTAssertTrue(store.snippets().isEmpty)
        store.remove(id: "missing") // no-op, no crash
    }

    func testDisabledBuiltinsRoundTrip() {
        store.setBuiltinDisabled(key: "te", disabled: true)
        store.setBuiltinDisabled(key: "([ ]*)sr", disabled: true)
        XCTAssertEqual(store.disabledBuiltinKeys(), ["te", "([ ]*)sr"])

        store.setBuiltinDisabled(key: "te", disabled: false)
        let reopened = UserSnippetStore(defaults: defaults, key: "snips")
        XCTAssertEqual(reopened.disabledBuiltinKeys(), ["([ ]*)sr"])
    }

    func testKeysAreNamespacedByStoreKey() {
        store.setBuiltinDisabled(key: "te", disabled: true)
        let other = UserSnippetStore(defaults: defaults, key: "other")
        XCTAssertTrue(other.disabledBuiltinKeys().isEmpty)
    }

    func testDecodesLegacyRecordsWithoutOptions() throws {
        // Records written before SnippetOptions existed: two booleans.
        let legacy = """
        [{"id":"s1","trigger":";a","replacement":"\\\\alpha",
          "autoExpand":false,"mathOnly":true,"enabled":true}]
        """
        let snippet = try JSONDecoder()
            .decode([UserSnippet].self, from: Data(legacy.utf8))[0]
        XCTAssertEqual(snippet.options.mode, .math)
        XCTAssertFalse(snippet.options.autoExpand)
        XCTAssertNil(snippet.overridesBuiltinKey)
    }

    func testLegacyMathOnlyFalseMeansAnywhereNotProse() throws {
        // The old switch meant "not restricted to math", never "text only".
        let legacy = """
        [{"id":"s1","trigger":";a","replacement":"x",
          "autoExpand":true,"mathOnly":false,"enabled":true}]
        """
        let snippet = try JSONDecoder()
            .decode([UserSnippet].self, from: Data(legacy.utf8))[0]
        XCTAssertEqual(snippet.options.mode, .any)
    }

    func testOptionsAndOverrideKeyPersist() {
        let snippet = UserSnippet(
            id: "s1",
            trigger: "([a-z])bar",
            replacement: "\\\\bar{#1}",
            options: SnippetOptions(mode: .text, wholeWord: true, isRegex: true),
            overridesBuiltinKey: "([a-gi-zA-Z])bar"
        )
        store.upsert(snippet)
        let reopened = UserSnippetStore(defaults: defaults, key: "snips")
        XCTAssertEqual(reopened.snippets(), [snippet])
    }

    // MARK: - Corruption tolerance
    //
    // The store's array decode must not be all-or-nothing: one record a
    // rollback build can't read (a future options mode, say) or one
    // sync-corrupted element must not read as "no snippets", because every
    // mutation rewrites the whole blob and would wipe the rest for good.

    private func seed(_ json: String) {
        defaults.set(Data(json.utf8), forKey: "snips")
    }

    private var goodPairJSON: String {
        """
        [{"id":"s1","trigger":";a","replacement":"\\\\alpha","enabled":true,
          "options":{"mode":"math","autoExpand":true,"wholeWord":false,
                     "lineStart":false,"isRegex":false}},
         {"garbage":true},
         {"id":"s2","trigger":";b","replacement":"\\\\beta","enabled":true,
          "options":{"mode":"math","autoExpand":true,"wholeWord":false,
                     "lineStart":false,"isRegex":false}}]
        """
    }

    func testSnippetsSurviveOneUndecodableRecord() {
        seed(goodPairJSON)
        XCTAssertEqual(store.snippets().map(\.id), ["s1", "s2"])
    }

    func testWriteAfterUndecodableRecordKeepsAllRecords() throws {
        seed(goodPairJSON)
        store.upsert(UserSnippet(id: "s3", trigger: ";g", replacement: "\\gamma"))

        let reopened = UserSnippetStore(defaults: defaults, key: "snips")
        XCTAssertEqual(reopened.snippets().map(\.id), ["s1", "s2", "s3"])

        // The unreadable record rides along verbatim instead of being
        // dropped: the build (or repaired sync store) that understands it
        // can still read it later.
        let data = try XCTUnwrap(defaults.data(forKey: "snips"))
        let array = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [[String: Any]])
        XCTAssertEqual(array.count, 4)
        XCTAssertTrue(array.contains { $0["garbage"] as? Bool == true })
    }

    func testRemovePreservesUnreadableRecords() throws {
        seed(goodPairJSON)
        store.remove(id: "s1")

        XCTAssertEqual(store.snippets().map(\.id), ["s2"])
        let data = try XCTUnwrap(defaults.data(forKey: "snips"))
        let array = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [[String: Any]])
        XCTAssertEqual(array.count, 2)
        XCTAssertTrue(array.contains { $0["garbage"] as? Bool == true })
    }

    func testUnknownOptionsModeDegradesInsteadOfDroppingTheRecord() {
        // A future build's mode raw value. The record must survive — degraded
        // to the default mode — rather than vanish and get wiped on the next
        // write.
        seed("""
        [{"id":"s1","trigger":";a","replacement":"x","enabled":true,
          "options":{"mode":"chemistry","autoExpand":false,"wholeWord":true,
                     "lineStart":false,"isRegex":false}}]
        """)
        let snippets = store.snippets()
        XCTAssertEqual(snippets.map(\.id), ["s1"])
        XCTAssertEqual(snippets.first?.options.mode, .math)
        // The flags it could read are kept, not reset.
        XCTAssertEqual(snippets.first?.options.autoExpand, false)
        XCTAssertEqual(snippets.first?.options.wholeWord, true)
    }

    func testOptionsWithMissingKeysDecodesToDefaults() throws {
        // A shape with fewer keys than this build writes (older or newer
        // schema) fills in the initializer defaults instead of throwing.
        let options = try JSONDecoder().decode(
            SnippetOptions.self, from: Data(#"{"mode":"text"}"#.utf8))
        XCTAssertEqual(options.mode, .text)
        XCTAssertTrue(options.autoExpand)
        XCTAssertFalse(options.wholeWord)
        XCTAssertFalse(options.lineStart)
        XCTAssertFalse(options.isRegex)
    }

    func testWhollyUnreadableBlobIsNeverOverwritten() {
        // Not JSON at all: nothing can be salvaged element-wise, so reads
        // fall back to empty but writes must refuse to clobber the blob —
        // a later build or repaired sync may still recover it.
        let blob = Data("not json".utf8)
        defaults.set(blob, forKey: "snips")
        XCTAssertTrue(store.snippets().isEmpty)

        store.upsert(UserSnippet(id: "s1", trigger: ";a", replacement: "x"))
        store.remove(id: "s1")
        XCTAssertEqual(defaults.data(forKey: "snips"), blob)
    }

    func testEncodedRecordAlsoCarriesTheLegacyKeys() throws {
        // A build that predates `SnippetOptions` has a synthesized decoder
        // requiring `autoExpand` and `mathOnly`; without them it throws and
        // `snippets()` swallows that into `[]`, wiping the user's shortcuts
        // on a rollback. So the encoder writes all three shapes.
        let snippet = UserSnippet(
            id: "s1", trigger: ";a", replacement: "\\alpha",
            options: SnippetOptions(mode: .text, autoExpand: false, wholeWord: true))
        let data = try JSONEncoder().encode(snippet)
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertNotNil(json["options"])
        XCTAssertEqual(json["autoExpand"] as? Bool, false)
        XCTAssertEqual(json["mathOnly"] as? Bool, false)

        // `.math` is the only mode the old boolean could express.
        let mathy = UserSnippet(
            id: "s2", trigger: ";b", replacement: "\\beta",
            options: SnippetOptions(mode: .math, autoExpand: true))
        let mathJSON = try XCTUnwrap(
            JSONSerialization.jsonObject(with: try JSONEncoder().encode(mathy))
                as? [String: Any])
        XCTAssertEqual(mathJSON["autoExpand"] as? Bool, true)
        XCTAssertEqual(mathJSON["mathOnly"] as? Bool, true)

        // And the new decoder still prefers `options` over them.
        XCTAssertEqual(try JSONDecoder().decode(UserSnippet.self, from: data), snippet)
    }
}
