import XCTest
@testable import VoiceTypingCore

final class PasteVerificationTests: XCTestCase {
    typealias Snap = TextInjector.FieldSnapshot

    func testPageURLKeepsNavigationIdentity() {
        XCTAssertEqual(TargetInputManager.normalizedPageURL("https://mail.google.com/mail/u/0/?tab=rm#inbox"),
                       "https://mail.google.com/mail/u/0?tab=rm#inbox")
        XCTAssertEqual(TargetInputManager.normalizedPageURL("https://app.slack.com/client/T1/C123"),
                       "https://app.slack.com/client/T1/C123")
        XCTAssertNotEqual(TargetInputManager.normalizedPageURL("https://app.slack.com/client/T1/C123"),
                          TargetInputManager.normalizedPageURL("https://app.slack.com/client/T1/C999"),
                          "Farklı kanal farklı hedef sayılmalı")
        XCTAssertNotEqual(TargetInputManager.normalizedPageURL("https://mail.google.com/#inbox"),
                          TargetInputManager.normalizedPageURL("https://mail.google.com/#sent"))
        XCTAssertNotEqual(TargetInputManager.normalizedPageURL("http://localhost:3000/?chat=1"),
                          TargetInputManager.normalizedPageURL("http://localhost:3001/?chat=1"))
        XCTAssertNotEqual(TargetInputManager.normalizedPageURL("http://localhost:3000/?chat=1"),
                          TargetInputManager.normalizedPageURL("http://localhost:3000/?chat=2"))
        XCTAssertNil(TargetInputManager.normalizedPageURL("not a url"))
    }

    func testOutcomeVerifiedWhenValueChanges() {
        XCTAssertEqual(TextInjector.outcome(before: Snap(value: "Merhaba", count: 7),
                                            after: Snap(value: "Merhaba dünya", count: 13), insertedText: " dünya"), .verified)
    }

    func testOutcomeVerifiedWhenSelectionReplacedWithSameLength() {
        // Seçili 5 karakter yerine 5 karakter yapıştırıldı: sayı aynı, içerik farklı.
        let before = Snap(value: "abc hello", count: 9, selection: NSRange(location: 4, length: 5))
        XCTAssertEqual(TextInjector.outcome(before: before,
                                            after: Snap(value: "abc world", count: 9), insertedText: "world"), .verified)
    }

    func testOutcomeNotInsertedWhenFieldUnchanged() {
        XCTAssertEqual(TextInjector.outcome(before: Snap(value: "aynı", count: 4),
                                            after: Snap(value: "aynı", count: 4), insertedText: "yeni"), .notInserted)
        XCTAssertEqual(TextInjector.outcome(before: Snap(value: nil, count: 10),
                                            after: Snap(value: nil, count: 10), insertedText: "yeni"), .unverifiable)
    }

    func testOutcomeUnverifiableWhenFieldUnreadable() {
        XCTAssertEqual(TextInjector.outcome(before: Snap(value: nil, count: nil),
                                            after: Snap(value: "x", count: 1), insertedText: "x"), .unverifiable)
        XCTAssertEqual(TextInjector.outcome(before: Snap(value: "x", count: 1),
                                            after: Snap(value: nil, count: nil), insertedText: "x"), .unverifiable)
    }

    func testUnrelatedEditAndCharacterCountCannotProveDelivery() {
        XCTAssertEqual(TextInjector.outcome(before: Snap(value: "metin eski", count: nil),
                                            after: Snap(value: "metin yeni", count: nil), insertedText: "metin"), .unverifiable)
        XCTAssertEqual(TextInjector.outcome(before: Snap(value: nil, count: 0),
                                            after: Snap(value: nil, count: 5), insertedText: "metin"), .unverifiable)
    }

    func testEmojiSelectionUsesUTF16Range() {
        let old = "Önce 👩🏽‍💻 sonra"
        let range = (old as NSString).range(of: "👩🏽‍💻")
        XCTAssertEqual(TextInjector.outcome(before: Snap(value: old, count: nil, selection: range),
                                            after: Snap(value: "Önce İğüşöç sonra", count: nil), insertedText: "İğüşöç"), .verified)
    }

    func testSelectionFreeInsertionWithSharedPrefixAndSuffix() {
        for (old, new, text) in [("abX", "abcabX", "abc"), ("Xab", "Xabcab", "cab"),
                                 ("ön sonra", "ön 👋 sonra", "👋 "), ("aynı", "aynıaynı", "aynı")] {
            XCTAssertEqual(TextInjector.outcome(before: Snap(value: old, count: nil),
                                                after: Snap(value: new, count: nil), insertedText: text), .verified)
        }
    }

    func testRangeOnlyEditorCanProveUnicodeInsertion() {
        let old = "Önce 👩🏽‍💻"
        let inserted = " Merhaba"
        let new = old + inserted
        let oldCount = old.utf16.count
        let newCount = new.utf16.count
        let beforeValue = TextInjector.completeSnapshotValue(nil, count: oldCount) { range in
            XCTAssertEqual(range, NSRange(location: 0, length: oldCount))
            return old
        }
        let afterValue = TextInjector.completeSnapshotValue(nil, count: newCount) { range in
            XCTAssertEqual(range, NSRange(location: 0, length: newCount))
            return new
        }
        let before = Snap(value: beforeValue, count: oldCount)
        let after = Snap(value: afterValue, count: newCount)
        XCTAssertEqual(TextInjector.outcome(before: before, after: after, insertedText: inserted), .verified)
        XCTAssertEqual(TextInjector.outcome(before: before, after: after, insertedText: " başka"), .unverifiable)
    }

    func testRangeFallbackDoesNotTrustPartialOrUnboundedValues() {
        var calls = 0
        let read: (NSRange) -> String? = { _ in calls += 1; return "kısa" }
        XCTAssertEqual(TextInjector.completeSnapshotValue(nil, count: 0, readRange: read), "")
        XCTAssertEqual(TextInjector.completeSnapshotValue("tam", count: 3, readRange: read), "tam")
        XCTAssertNil(TextInjector.completeSnapshotValue(nil, count: 10_001, readRange: read))
        XCTAssertNil(TextInjector.completeSnapshotValue(nil, count: -1, readRange: read))
        XCTAssertEqual(calls, 0)
        XCTAssertNil(TextInjector.completeSnapshotValue(nil, count: 10, readRange: read))
        XCTAssertEqual(TextInjector.completeSnapshotValue("parça", count: 10, readRange: read), "parça")
        XCTAssertEqual(calls, 2)
    }

    func testWrongSelectionAndPartialTextDoNotVerify() {
        let before = Snap(value: "ön son", count: nil, selection: NSRange(location: 3, length: 0))
        for new in ["ön sondikte", "ön dikson", "ön başka son"] {
            XCTAssertEqual(TextInjector.outcome(before: before, after: Snap(value: new, count: nil),
                                                insertedText: "dikte"), .unverifiable)
        }
    }
}

final class DirectTypingRulesTests: XCTestCase {
    func testCharacterTypingSkipsNewlinesAndTabs() {
        XCTAssertTrue(TextInjector.canTypeAsCharacters("Merhaba dünya 👋 İğüşöç"))
        XCTAssertFalse(TextInjector.canTypeAsCharacters("- madde 1\n- madde 2"), "Satır sonu sohbeti erken gönderebilir")
        XCTAssertFalse(TextInjector.canTypeAsCharacters("a\tb"))
        XCTAssertFalse(TextInjector.canTypeAsCharacters(""))
        XCTAssertFalse(TextInjector.canTypeAsCharacters(String(repeating: "a", count: 4001)))
    }

    func testCharacterTypingSkipsEveryLineBreakFormat() {
        for separator in ["\n", "\r", "\r\n", "\u{000B}", "\u{000C}", "\u{0085}", "\u{2028}", "\u{2029}"] {
            XCTAssertFalse(TextInjector.canTypeAsCharacters("ilk\(separator)son"),
                           "Satır sonları doğrudan tuş olaylarına dönüşmemeli: \(separator.debugDescription)")
        }
    }

    func testCharacterChunksPreserveUnicodeWithoutSplittingCharacters() {
        let text = String(repeating: "İğüşöç 👩🏽‍💻 e\u{301} ", count: 100)
        var chunks: [String] = []
        XCTAssertTrue(TextInjector.sendCharacterChunks(text, isCancelled: { false }) { units in
            let chunk = String(decoding: units, as: UTF16.self)
            XCTAssertEqual(Array(chunk.utf16), units)
            XCTAssertLessThanOrEqual(units.count, 20)
            chunks.append(chunk)
            return true
        })
        XCTAssertEqual(chunks.joined(), text)
        XCTAssertEqual(chunks.flatMap { Array($0) }, Array(text))
    }

    func testCharacterTypingStopsAfterCancellationWithoutRetry() {
        var cancelled = false
        var sentCount = 0
        XCTAssertFalse(TextInjector.sendCharacterChunks(String(repeating: "a", count: 200), isCancelled: { cancelled }) { _ in
            sentCount += 1
            cancelled = true
            return true
        })
        XCTAssertEqual(sentCount, 1)
    }

    func testCharacterTypingReportsSendFailureWithoutRetry() {
        var sentCount = 0
        XCTAssertFalse(TextInjector.sendCharacterChunks(String(repeating: "a", count: 200), isCancelled: { false }) { _ in
            sentCount += 1
            return false
        })
        XCTAssertEqual(sentCount, 1)
    }
}

final class DictationDeliveryGateTests: XCTestCase {
    func testDuplicateCompletionCannotStartSecondDelivery() {
        var gate = DictationDeliveryGate()
        gate.begin(1)
        XCTAssertTrue(gate.beginDelivery(1))
        XCTAssertFalse(gate.beginDelivery(1))
        XCTAssertFalse(gate.acceptsResult(1))
        XCTAssertTrue(gate.isDelivering(1))
    }

    func testCancelledTranslationCannotDeliver() {
        var gate = DictationDeliveryGate()
        gate.begin(1)
        XCTAssertTrue(gate.beginDelivery(1))
        gate.finish()
        XCTAssertFalse(gate.isDelivering(1))
        XCTAssertFalse(gate.acceptsResult(1))
    }

    func testOldResultCannotModifyNewRecording() {
        var gate = DictationDeliveryGate()
        gate.begin(1)
        gate.begin(2)
        XCTAssertFalse(gate.acceptsResult(1))
        XCTAssertFalse(gate.isDelivering(1))
        XCTAssertTrue(gate.beginDelivery(2))
    }
}
