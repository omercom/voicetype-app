import AppKit
import XCTest
@testable import VoiceTypingCore

final class ClipboardProtectionTests: XCTestCase {
    func testCompleteSnapshotPreservesEveryItemAndFormat() throws {
        let custom = NSPasteboard.PasteboardType("org.voicetyping.test-format")
        let first = NSPasteboardItem()
        XCTAssertTrue(first.setString("Merhaba", forType: .string))
        XCTAssertTrue(first.setData(Data([0, 1, 2, 3]), forType: custom))
        let second = NSPasteboardItem()
        XCTAssertTrue(second.setString("İkinci", forType: .string))

        let snapshot = try XCTUnwrap(TextInjector.copyCompleteClipboardItems([first, second]))
        XCTAssertEqual(snapshot.count, 2)
        XCTAssertEqual(snapshot[0].string(forType: .string), "Merhaba")
        XCTAssertEqual(snapshot[0].data(forType: custom), Data([0, 1, 2, 3]))
        XCTAssertEqual(snapshot[1].string(forType: .string), "İkinci")
    }

    func testIncompleteSnapshotIsRejectedInsteadOfDiscardingFormat() {
        let unavailable = NSPasteboard.PasteboardType("org.voicetyping.unavailable")
        let item = NSPasteboardItem()
        XCTAssertTrue(item.setString("Original", forType: .string))
        XCTAssertTrue(item.setData(Data([7]), forType: unavailable))

        let snapshot = TextInjector.copyCompleteClipboardItems([item]) { item, type in
            type == unavailable ? nil : item.data(forType: type)
        }
        XCTAssertNil(snapshot)
        XCTAssertEqual(item.string(forType: .string), "Original")
        XCTAssertEqual(item.data(forType: unavailable), Data([7]))
    }

    func testEmptyNamedPasteboardIsAValidSnapshot() {
        let pasteboard = NSPasteboard(name: .init("org.voicetyping.test.\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        let snapshot = TextInjector().captureCompleteClipboardSnapshot(from: pasteboard)
        XCTAssertNotNil(snapshot)
        XCTAssertEqual(snapshot?.count, 0)
    }

    func testPreparationFailureReportsReasonWithoutSendingPaste() {
        var sent = false
        let environment = ClipboardPasteTransaction.Environment(
            prepare: { false },
            preparationFailureReason: { "Pano yedeklenemedi" },
            ownsClipboard: { true },
            targetChangedReason: { nil },
            snapshot: { .init(value: nil, count: nil, selection: nil) },
            sendPaste: { sent = true; return true },
            restore: {}, autoSubmit: {}
        )
        let outcome = ClipboardPasteTransaction.run(text: "test", pasteDelay: 0,
                                                    restoreClipboard: true, autoSubmit: false, environment: environment)
        XCTAssertEqual(outcome, .failed(reason: "Pano yedeklenemedi"))
        XCTAssertFalse(sent)
    }

    func testCancellationBeforeSendRestoresOwnedClipboard() {
        var cancelled = false
        var rollbacks = 0
        var sent = false
        let environment = ClipboardPasteTransaction.Environment(
            prepare: { true }, ownsClipboard: { true }, targetChangedReason: { nil },
            snapshot: { .init(value: nil, count: nil, selection: nil) },
            sendPaste: { sent = true; return true }, restore: {}, autoSubmit: {},
            rollbackBeforeSending: { rollbacks += 1 },
            isCancelled: { cancelled }, wait: { _ in cancelled = true }
        )
        let outcome = ClipboardPasteTransaction.run(text: "test", pasteDelay: 1,
                                                    restoreClipboard: true, autoSubmit: false, environment: environment)
        XCTAssertEqual(outcome, .cancelled)
        XCTAssertEqual(rollbacks, 1)
        XCTAssertFalse(sent)
    }

    func testCancellationDoesNotOverwriteNewClipboardContent() {
        var cancelled = false
        var rollbacks = 0
        let environment = ClipboardPasteTransaction.Environment(
            prepare: { true }, ownsClipboard: { false }, targetChangedReason: { nil },
            snapshot: { .init(value: nil, count: nil, selection: nil) },
            sendPaste: { true }, restore: {}, autoSubmit: {},
            rollbackBeforeSending: { rollbacks += 1 },
            isCancelled: { cancelled }, wait: { _ in cancelled = true }
        )
        let outcome = ClipboardPasteTransaction.run(text: "test", pasteDelay: 1,
                                                    restoreClipboard: true, autoSubmit: false, environment: environment)
        XCTAssertEqual(outcome, .cancelled)
        XCTAssertEqual(rollbacks, 0)
    }

    func testCancellationAfterSendDoesNotRestoreClipboardEarly() {
        var cancelled = false
        var rollbacks = 0
        let environment = ClipboardPasteTransaction.Environment(
            prepare: { true }, ownsClipboard: { true }, targetChangedReason: { nil },
            snapshot: { .init(value: nil, count: nil, selection: nil) },
            sendPaste: { cancelled = true; return true }, restore: {}, autoSubmit: {},
            rollbackBeforeSending: { rollbacks += 1 }, isCancelled: { cancelled }, wait: { _ in }
        )
        let outcome = ClipboardPasteTransaction.run(text: "test", pasteDelay: 0,
                                                    restoreClipboard: true, autoSubmit: false, environment: environment)
        XCTAssertEqual(outcome, .cancelled)
        XCTAssertEqual(rollbacks, 0)
    }

    func testCancellationInterruptsLongPasteDelay() {
        var elapsed = 0.0
        var sent = false
        let environment = ClipboardPasteTransaction.Environment(
            prepare: { true }, ownsClipboard: { true }, targetChangedReason: { nil },
            snapshot: { .init(value: nil, count: nil, selection: nil) },
            sendPaste: { sent = true; return true },
            restore: {}, autoSubmit: {},
            isCancelled: { elapsed >= 0.05 },
            wait: { elapsed += $0 }
        )
        let outcome = ClipboardPasteTransaction.run(text: "test", pasteDelay: 2,
                                                    restoreClipboard: false, autoSubmit: false, environment: environment)
        XCTAssertEqual(outcome, .cancelled)
        XCTAssertEqual(elapsed, 0.05, accuracy: 0.0001)
        XCTAssertFalse(sent)
    }
}
