import XCTest
import ApplicationServices
@testable import VoiceTypingCore

final class DictationHistoryAndModeTests: XCTestCase {

    override func setUp() {
        super.setUp()
        DictationHistoryManager.shared.clear()
    }

    override func tearDown() {
        DictationHistoryManager.shared.clear()
        super.tearDown()
    }

    // MARK: - DictationEntry ve Uygulama Etiketi

    func testDictationEntryIncludesAppNameInMenuTitle() {
        let entryWithApp = DictationEntry(
            text: "Merhaba dünya bu bir test",
            provider: "apple",
            model: "on-device",
            appName: "Xcode"
        )
        XCTAssertTrue(entryWithApp.menuTitle.contains("[Xcode]"))
        XCTAssertTrue(entryWithApp.menuTitle.contains("Merhaba dünya"))

        let entryWithoutApp = DictationEntry(
            text: "Merhaba dünya bu bir test",
            provider: "apple",
            model: "on-device",
            appName: nil
        )
        XCTAssertFalse(entryWithoutApp.menuTitle.contains("["))
        XCTAssertTrue(entryWithoutApp.menuTitle.contains("Merhaba dünya"))
    }

    func testDictationEntryCodableBackwardCompatibility() throws {
        // Eski sürüm JSON: appName alanı yok
        let legacyJSON = """
        {
            "id": "E621E1F8-C36C-495A-93FC-0C247A3E6E5F",
            "text": "Eski dikte metni",
            "timestamp": 0,
            "provider": "apple",
            "model": "on-device"
        }
        """.data(using: .utf8)!

        let decoded = try JSONDecoder().decode(DictationEntry.self, from: legacyJSON)
        XCTAssertEqual(decoded.text, "Eski dikte metni")
        XCTAssertNil(decoded.appName)

        // Yeni sürüm JSON: appName alanı var
        let modernJSON = """
        {
            "id": "E621E1F8-C36C-495A-93FC-0C247A3E6E5F",
            "text": "Yeni dikte metni",
            "timestamp": 0,
            "provider": "gemini",
            "model": "flash",
            "appName": "Slack"
        }
        """.data(using: .utf8)!

        let decodedModern = try JSONDecoder().decode(DictationEntry.self, from: modernJSON)
        XCTAssertEqual(decodedModern.appName, "Slack")
    }

    // MARK: - Markdown Dışa Aktarma (Export)

    func testExportToMarkdownDefaultTemplate() {
        let manager = DictationHistoryManager.shared
        manager.addEntry(
            text: "Bugün hava çok güzel.",
            provider: "groq",
            model: "whisper-large-v3",
            appName: "Notlar"
        )

        let markdown = manager.exportToMarkdown()
        XCTAssertTrue(markdown.contains("# VoiceType Dikte Geçmişi"))
        XCTAssertTrue(markdown.contains("Bugün hava çok güzel."))
        XCTAssertTrue(markdown.contains("Notlar"))
        XCTAssertTrue(markdown.contains("groq"))
    }

    func testExportToMarkdownCustomTemplate() {
        let manager = DictationHistoryManager.shared
        manager.addEntry(
            text: "Toplantı notları alındı.",
            provider: "gemini",
            model: "live",
            appName: "Safari"
        )

        let customTemplate = "- [{{uygulama}}] ({{saat}}): {{metin}}"
        let markdown = manager.exportToMarkdown(itemTemplate: customTemplate)
        XCTAssertTrue(markdown.contains("- [Safari] ("))
        XCTAssertTrue(markdown.contains("Toplantı notları alındı."))
    }

    func testExportToFileWritesMarkdownOnDisk() throws {
        let manager = DictationHistoryManager.shared
        manager.addEntry(
            text: "Dosyaya yazma testi metni",
            provider: "apple",
            model: "on-device",
            appName: "Terminal"
        )

        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let fileURL = try manager.exportToFile(destinationDirectory: tempDir)

        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))
        let content = try String(contentsOf: fileURL, encoding: .utf8)
        XCTAssertTrue(content.contains("Dosyaya yazma testi metni"))
        XCTAssertTrue(content.contains("Terminal"))

        try? FileManager.default.removeItem(at: tempDir)
    }

    // MARK: - Dikte Modu (Dictation Mode) ve Profil Katmanlaması

    func testTextPolisherDirectModePreservesStream() {
        var config = AppConfig.defaultConfig
        config.dictation_mode = "direct"
        config.enable_app_profiles = false

        let input = "merhaba dünya bu bir denemedir"
        let output = TextPolisher.shared.polish(text: input, config: config)
        XCTAssertEqual(output, "Merhaba dünya bu bir denemedir")
    }

    func testTextPolisherFormalModeCapitalizesAndPunctuates() {
        var config = AppConfig.defaultConfig
        config.dictation_mode = "formal"
        config.enable_app_profiles = false

        let input = "merhaba dünya bu bir denemedir"
        let output = TextPolisher.shared.polish(text: input, config: config)
        XCTAssertEqual(output, "Merhaba dünya bu bir denemedir.")
    }

    func testTextPolisherBulletModeCreatesList() {
        var config = AppConfig.defaultConfig
        config.dictation_mode = "bullet"
        config.enable_app_profiles = false

        let input = "ilk olarak projeyi derle ikinci olarak testleri çalıştır"
        let output = TextPolisher.shared.polish(text: input, config: config)
        XCTAssertTrue(output.contains("- "))
    }

    func testTextPolisherStacksModeWithAppProfile() {
        var config = AppConfig.defaultConfig
        config.dictation_mode = "formal"
        config.enable_app_profiles = true

        let dummyElement = AXUIElementCreateSystemWide()
        let terminalContext = TargetContext(
            pid: 999,
            bundleIdentifier: "com.apple.Terminal",
            appName: "Terminal",
            runningApp: nil,
            element: dummyElement,
            window: nil,
            role: "AXTextArea"
        )

        // Terminal profili komut satırı için son noktayı temizler ve küçük harfe çeker
        let input = "git status tire tire all"
        let output = TextPolisher.shared.polish(text: input, config: config, targetContext: terminalContext)

        XCTAssertFalse(output.hasSuffix("."))
        XCTAssertTrue(output.contains("git status --all"))
    }
}
