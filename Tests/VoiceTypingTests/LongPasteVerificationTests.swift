import XCTest
@testable import VoiceTypingCore

final class LongPasteVerificationTests: XCTestCase {
    typealias Snapshot = TextInjector.FieldSnapshot

    func testLineEndingNormalizationVerifiesTheWholeReplacement() {
        let before = Snapshot(value: "baş--son", count: nil, selection: NSRange(location: 3, length: 2))
        let after = Snapshot(value: "başbir\niki\nüçson", count: nil)
        XCTAssertEqual(TextInjector.outcome(before: before, after: after,
                                            insertedText: "bir\r\niki\rüç"), .verified)
    }

    func testLineEndingNormalizationAlsoWorksWithoutSelection() {
        let before = Snapshot(value: "başson", count: nil)
        let after = Snapshot(value: "başbir\niki\nüçson", count: nil)
        XCTAssertEqual(TextInjector.outcome(before: before, after: after,
                                            insertedText: "bir\r\niki\rüç"), .verified)
    }

    func testTruncatedValueWithChangedCountIsNotReportedAsUnchanged() {
        let before = Snapshot(value: "görünen", count: 2_000, selection: NSRange(location: 1_000, length: 0))
        let after = Snapshot(value: "görünen", count: 2_500, selection: NSRange(location: 1_500, length: 0))
        let text = String(repeating: "a", count: 500)
        XCTAssertEqual(TextInjector.outcome(before: before, after: after, insertedText: text), .unverifiable)
    }

    func testUnchangedVisibleValueWithMovedCaretIsNotAnInsertionFailure() {
        let before = Snapshot(value: "sabit", count: nil, selection: NSRange(location: 5, length: 0))
        let after = Snapshot(value: "sabit", count: nil, selection: NSRange(location: 10, length: 0))
        XCTAssertEqual(TextInjector.outcome(before: before, after: after, insertedText: "metin"), .unverifiable)
    }

    func testRangeReadVerifiesCompleteTextWhenWholeValueIsTruncated() {
        let text = String(repeating: "İğüşöç 👩🏽‍💻\n", count: 350)
        let start = 1_000
        let length = text.utf16.count
        let before = Snapshot(value: "kısmi", count: 2_000, selection: NSRange(location: start, length: 0))
        let after = Snapshot(value: "kısmi", count: 2_000 + length,
                             selection: NSRange(location: start + length, length: 0))
        var requested: NSRange?
        let result = TextInjector.outcome(before: before, after: after, insertedText: text) { range in
            requested = range
            return text
        }
        XCTAssertEqual(result, .verified)
        XCTAssertEqual(requested, NSRange(location: start, length: length))
    }

    func testRangeReadAllowsOnlyLineEndingDifferences() {
        let before = Snapshot(value: nil, count: 10, selection: NSRange(location: 5, length: 0))
        let after = Snapshot(value: nil, count: 13, selection: NSRange(location: 8, length: 0))
        XCTAssertEqual(TextInjector.outcome(before: before, after: after, insertedText: "a\r\nb") { range in
            XCTAssertEqual(range, NSRange(location: 5, length: 3))
            return "a\nb"
        }, .verified)
    }

    func testMatchingOldTextWithoutMovementCannotProveInsertion() {
        let before = Snapshot(value: nil, count: 100, selection: NSRange(location: 10, length: 0))
        let after = Snapshot(value: nil, count: 100, selection: NSRange(location: 10, length: 0))
        var queried = false
        let result = TextInjector.outcome(before: before, after: after, insertedText: "metin") { _ in
            queried = true
            return "metin"
        }
        XCTAssertEqual(result, .notInserted)
        XCTAssertFalse(queried)
    }

    func testMismatchedOrPartialRangeCannotProveInsertion() {
        let before = Snapshot(value: nil, count: 100, selection: NSRange(location: 10, length: 0))
        let after = Snapshot(value: nil, count: 105, selection: NSRange(location: 15, length: 0))
        XCTAssertEqual(TextInjector.outcome(before: before, after: after, insertedText: "metin") { _ in "meti" }, .unverifiable)
        XCTAssertEqual(TextInjector.outcome(before: before, after: after, insertedText: "metin") { _ in "yanlış" }, .unverifiable)
    }

    func testConflictingCountCannotBeOverriddenByMatchingRange() {
        let before = Snapshot(value: nil, count: 100, selection: NSRange(location: 10, length: 0))
        let after = Snapshot(value: nil, count: 102, selection: NSRange(location: 15, length: 0))
        var queried = false
        let result = TextInjector.outcome(before: before, after: after, insertedText: "metin") { _ in
            queried = true
            return "metin"
        }
        XCTAssertEqual(result, .unverifiable)
        XCTAssertFalse(queried)
    }

    func testCountChangeAndExactRangeCanVerifyWithoutCaretUpdate() {
        let before = Snapshot(value: nil, count: 100, selection: NSRange(location: 10, length: 0))
        let after = Snapshot(value: nil, count: 105, selection: nil)
        XCTAssertEqual(TextInjector.outcome(before: before, after: after, insertedText: "metin") { _ in "metin" }, .verified)
    }

    func testOnlyCaretAndExactRangeCanVerifyWhenCountIsUnavailable() {
        let before = Snapshot(value: nil, count: nil, selection: NSRange(location: 10, length: 0))
        let after = Snapshot(value: nil, count: nil, selection: NSRange(location: 15, length: 0))
        XCTAssertEqual(TextInjector.outcome(before: before, after: after, insertedText: "metin") { _ in "metin" }, .verified)
    }

    func testVerificationTimeoutIsBoundedAndLongerOnlyForReadableFields() {
        let longText = String(repeating: "a", count: 50_000)
        XCTAssertEqual(TextInjector.verificationTimeout(for: longText, before: Snapshot(value: "", count: 0)), 8)
        XCTAssertEqual(TextInjector.verificationTimeout(for: "kısa", before: Snapshot(value: "", count: 0)), 3)
        XCTAssertEqual(TextInjector.verificationTimeout(for: longText, before: Snapshot(value: nil, count: nil)), 3)
    }
}
