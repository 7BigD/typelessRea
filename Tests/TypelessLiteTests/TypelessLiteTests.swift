import XCTest
@testable import TypelessLite

final class TypelessLiteTests: XCTestCase {

    func testLocalCleanFillerRemovalAndDictionary() {
        let dictionary = [
            DictionaryEntry(term: "TypelessLite", aliases: ["type less lite", "typeless light"]),
            DictionaryEntry(term: "GitHub", aliases: ["git hub"]),
            DictionaryEntry(term: "SwiftUI", aliases: ["swift ui"])
        ]

        let raw = "嗯，那个，我们今天把 type less lite 的代码推到 git hub 上，然后用 swift ui 写界面。"
        let cleaned = TextRefiner.localClean(raw, tone: .neutral, removeFillers: true, dictionary: dictionary)

        XCTAssertFalse(cleaned.hasPrefix("嗯"))
        XCTAssertFalse(cleaned.contains("那个，"))
        XCTAssertTrue(cleaned.contains("TypelessLite"))
        XCTAssertTrue(cleaned.contains("GitHub"))
        XCTAssertTrue(cleaned.contains("SwiftUI"))
    }

    func testLocalCleanSimpleSelfCorrection() {
        let raw = "明天下午三点，不对，四点开产品评审会。"
        let cleaned = TextRefiner.localClean(raw, tone: .neutral, removeFillers: true, dictionary: [])
        XCTAssertEqual(cleaned, "四点开产品评审会。")
    }

    func testEnglishFillerCleanupAndCapitalization() {
        let raw = "um, uh, we should deploy this, you know, before Friday."
        let cleaned = TextRefiner.localClean(raw, tone: .professional, removeFillers: true, dictionary: [])
        XCTAssertTrue(cleaned.hasPrefix("We should deploy this"))
        XCTAssertFalse(cleaned.lowercased().contains("um,"))
        XCTAssertFalse(cleaned.lowercased().contains("you know"))
    }

    func testContextToneInference() {
        XCTAssertEqual(
            AppContextInfo.inferTone(bundleId: "com.apple.dt.Xcode", appName: "Xcode", webDomain: nil),
            .codeFriendly
        )
        XCTAssertEqual(
            AppContextInfo.inferTone(bundleId: "com.google.Chrome", appName: "Google Chrome", webDomain: "github.com"),
            .codeFriendly
        )
        XCTAssertEqual(
            AppContextInfo.inferTone(bundleId: "com.bytedance.feishu", appName: "Feishu", webDomain: nil),
            .professional
        )
        XCTAssertEqual(
            AppContextInfo.inferTone(bundleId: "com.tencent.xinWeChat", appName: "WeChat", webDomain: nil),
            .casual
        )
    }

    func testPromptConstructionForAllModes() {
        var settings = AppSettings()
        settings.translationTargetLanguage = "English"
        settings.enableContextToneAdaptation = true

        let ctx = AppContextInfo(
            appName: "Xcode",
            bundleId: "com.apple.dt.Xcode",
            windowTitle: "TypelessLiteApp.swift",
            selectedText: "let foo = 1",
            beforeText: "// comment",
            detectedTone: .codeFriendly
        )
        let dict = [DictionaryEntry(term: "AXUIElement", aliases: ["ax ui element"])]

        let dictPrompts = TextRefiner.buildPrompts(mode: .dictation, rawTranscript: "测试口述", context: ctx, settings: settings, dictionary: dict)
        XCTAssertTrue(dictPrompts.system.contains("AXUIElement"))
        XCTAssertTrue(dictPrompts.system.contains("Xcode"))

        let transPrompts = TextRefiner.buildPrompts(mode: .translation, rawTranscript: "你好世界", context: ctx, settings: settings, dictionary: dict)
        XCTAssertTrue(transPrompts.system.contains("English"))

        let askPrompts = TextRefiner.buildPrompts(mode: .askAnything, rawTranscript: "解释这段代码", context: ctx, settings: settings, dictionary: dict)
        XCTAssertTrue(askPrompts.user.contains("let foo = 1"))
        XCTAssertTrue(askPrompts.system.contains("\"delivery\""))
    }

    func testAskAnythingJSONAndFallbackParsing() {
        let fencedJSON = """
        ```json
        {"delivery": "card", "result": "这段代码定义了一个不可变常量 foo。"}
        ```
        """
        let parsed = TextRefiner.parseAskAnythingResponse(fencedJSON, voicePrompt: "解释一下", hasSelectedText: true)
        XCTAssertEqual(parsed.delivery, .card)
        XCTAssertEqual(parsed.text, "这段代码定义了一个不可变常量 foo。")

        let replaceJSON = #"{"delivery":"replace","result":"const foo = 1;"}"#
        let parsedReplace = TextRefiner.parseAskAnythingResponse(replaceJSON, voicePrompt: "转成 JS", hasSelectedText: true)
        XCTAssertEqual(parsedReplace.delivery, .replaceOrInsert)
        XCTAssertEqual(parsedReplace.text, "const foo = 1;")

        XCTAssertEqual(
            TextRefiner.classifyAskAnythingFallback(voicePrompt: "总结这段话的重点", hasSelectedText: true),
            .card
        )
        XCTAssertEqual(
            TextRefiner.classifyAskAnythingFallback(voicePrompt: "改写得更礼貌一些", hasSelectedText: true),
            .replaceOrInsert
        )
    }

    @MainActor
    func testLocalStorePersistence() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("typelesslite-test-\(UUID().uuidString)")
        let suiteName = "TypelessLiteTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer {
            try? FileManager.default.removeItem(at: tempDir)
            defaults.removePersistentDomain(forName: suiteName)
        }

        let store = LocalStore(baseDirectory: tempDir, userDefaults: defaults)
        store.settings.translationTargetLanguage = "日本語"
        store.addDictionaryEntry(term: "Koffi", aliases: ["coffee"], note: "Node FFI")
        store.addHistory(HistoryRecord(
            mode: .dictation,
            rawText: "嗯测试",
            refinedText: "测试",
            appName: "Notes",
            durationSeconds: 2.5
        ))

        let reloaded = LocalStore(baseDirectory: tempDir, userDefaults: defaults)
        XCTAssertEqual(reloaded.settings.translationTargetLanguage, "日本語")
        XCTAssertTrue(reloaded.dictionary.contains(where: { $0.term == "Koffi" }))
        XCTAssertEqual(reloaded.history.count, 1)
        XCTAssertEqual(reloaded.history.first?.refinedText, "测试")
    }
}
