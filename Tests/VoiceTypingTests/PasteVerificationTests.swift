import XCTest
@testable import VoiceTypingCore

final class PasteVerificationTests: XCTestCase {
    typealias Snap = TextInjector.FieldSnapshot

    func testPageURLIgnoresQueryAndFragmentButKeepsPath() {
        XCTAssertEqual(TargetInputManager.normalizedPageURL("https://mail.google.com/mail/u/0/?tab=rm#inbox"),
                       "https://mail.google.com/mail/u/0")
        XCTAssertEqual(TargetInputManager.normalizedPageURL("https://app.slack.com/client/T1/C123"),
                       "https://app.slack.com/client/T1/C123")
        XCTAssertNotEqual(TargetInputManager.normalizedPageURL("https://app.slack.com/client/T1/C123"),
                          TargetInputManager.normalizedPageURL("https://app.slack.com/client/T1/C999"),
                          "Farklı kanal farklı hedef sayılmalı")
        XCTAssertNil(TargetInputManager.normalizedPageURL("not a url"))
    }

    func testOutcomeVerifiedWhenValueChanges() {
        XCTAssertEqual(TextInjector.outcome(before: Snap(value: "Merhaba", count: 7),
                                            after: Snap(value: "Merhaba dünya", count: 13)), .verified)
    }

    func testOutcomeVerifiedWhenSelectionReplacedWithSameLength() {
        // Seçili 5 karakter yerine 5 karakter yapıştırıldı: sayı aynı, içerik farklı.
        XCTAssertEqual(TextInjector.outcome(before: Snap(value: "abc hello", count: 9),
                                            after: Snap(value: "abc world", count: 9)), .verified)
    }

    func testOutcomeNotInsertedWhenFieldUnchanged() {
        XCTAssertEqual(TextInjector.outcome(before: Snap(value: "aynı", count: 4),
                                            after: Snap(value: "aynı", count: 4)), .notInserted)
        XCTAssertEqual(TextInjector.outcome(before: Snap(value: nil, count: 10),
                                            after: Snap(value: nil, count: 10)), .notInserted)
    }

    func testOutcomeUnverifiableWhenFieldUnreadable() {
        XCTAssertEqual(TextInjector.outcome(before: Snap(value: nil, count: nil),
                                            after: Snap(value: "x", count: 1)), .unverifiable)
        XCTAssertEqual(TextInjector.outcome(before: Snap(value: "x", count: 1),
                                            after: Snap(value: nil, count: nil)), .unverifiable)
    }
}

final class DirectTypingRulesTests: XCTestCase {
    private func context(bundle: String, pageURL: String? = nil) -> TargetContext {
        TargetContext(pid: 1, bundleIdentifier: bundle, appName: "", runningApp: nil,
                      element: AXUIElementCreateSystemWide(), window: nil, role: "AXTextArea", pageURL: pageURL)
    }

    func testAccessibilityInsertOnlyForReadableNativeFields() {
        let readable = TextInjector.FieldSnapshot(value: "abc", count: 3)
        XCTAssertTrue(TextInjector.canInsertViaAccessibility(target: context(bundle: "com.apple.Notes"), before: readable))
        // Web alanında JS olayları tetiklenmez: kullanılmamalı
        XCTAssertFalse(TextInjector.canInsertViaAccessibility(target: context(bundle: "com.apple.Notes", pageURL: "https://x.com"), before: readable))
        XCTAssertFalse(TextInjector.canInsertViaAccessibility(target: context(bundle: "com.google.Chrome"), before: readable))
        XCTAssertFalse(TextInjector.canInsertViaAccessibility(target: context(bundle: "com.tinyspeck.slackmacgap"), before: readable))
        // Sonuç doğrulanamıyorsa kullanılmamalı
        XCTAssertFalse(TextInjector.canInsertViaAccessibility(target: context(bundle: "com.apple.Notes"),
                                                              before: .init(value: nil, count: 3)))
        XCTAssertFalse(TextInjector.canInsertViaAccessibility(target: nil, before: readable))
    }

    func testCharacterTypingSkipsNewlinesAndTabs() {
        XCTAssertTrue(TextInjector.canTypeAsCharacters("Merhaba dünya 👋 İğüşöç"))
        XCTAssertFalse(TextInjector.canTypeAsCharacters("- madde 1\n- madde 2"), "Satır sonu sohbeti erken gönderebilir")
        XCTAssertFalse(TextInjector.canTypeAsCharacters("a\tb"))
        XCTAssertFalse(TextInjector.canTypeAsCharacters(""))
    }
}
