import XCTest
@testable import VoiceTypingCore

final class ClipboardPasteTransactionTests: XCTestCase {
    private final class Harness {
        var clock = 0.0
        var clipboard = "önceki pano"
        var field = ""
        var generation = 0
        var ownedGeneration = -1
        var previous = ""
        var sentAt: Double?
        var consumed = false
        var delay = 0.8
        var readable = true
        var writeSucceeds = true
        var sendSucceeds = true
        var cancelled = false
        var targetChange: String?
        var onWait: (() -> Void)?
        var onSnapshot: (() -> Void)?
        var onTargetCheck: (() -> Void)?
        var onRestore: (() -> Void)?
        var snapshotPrefixLength: Int?
        var readRange: ((NSRange) -> String?)?
        var events: [String] = []

        func environment(text: String) -> ClipboardPasteTransaction.Environment {
            ClipboardPasteTransaction.Environment(
                prepare: {
                    self.events.append("prepare")
                    guard self.writeSucceeds else { return false }
                    self.previous = self.clipboard
                    self.clipboard = text
                    self.generation += 1
                    self.ownedGeneration = self.generation
                    self.sentAt = nil
                    self.consumed = false
                    return true
                },
                ownsClipboard: { self.generation == self.ownedGeneration },
                targetChangedReason: { self.onTargetCheck?(); return self.targetChange },
                snapshot: {
                    self.onSnapshot?()
                    let visible = self.snapshotPrefixLength.map { String(self.field.prefix($0)) } ?? self.field
                    return .init(value: self.readable ? visible : nil,
                                 count: self.readable ? self.field.utf16.count : nil,
                                 selection: NSRange(location: self.field.utf16.count, length: 0))
                },
                sendPaste: {
                    self.events.append("send")
                    self.sentAt = self.clock
                    return self.sendSucceeds
                },
                restore: {
                    self.events.append("restore")
                    self.clipboard = self.previous
                    self.generation += 1
                    self.onRestore?()
                },
                autoSubmit: { self.events.append("submit") },
                isCancelled: { self.cancelled },
                now: { self.clock },
                wait: { interval in
                    self.clock += interval
                    self.onWait?()
                    if let sentAt = self.sentAt, !self.consumed, self.clock - sentAt >= self.delay {
                        self.field += self.clipboard
                        self.consumed = true
                        self.events.append("consume")
                    }
                },
                readRange: { self.readRange?($0) }
            )
        }

        func run(_ text: String = "uzun dikte") -> TextInjector.InjectionOutcome {
            ClipboardPasteTransaction.run(text: text, pasteDelay: 0.02,
                                          restoreClipboard: true, autoSubmit: true,
                                          environment: environment(text: text))
        }
    }

    func testSlowEditorReadsCompleteLongUnicodeTextBeforeRestoration() {
        let h = Harness()
        let text = String(repeating: "İğüşöç 👩🏽‍💻 e\u{301}\n", count: 3000) + "SON"
        XCTAssertEqual(h.run(text), .verified)
        XCTAssertEqual(h.field, text)
        XCTAssertEqual(h.clipboard, "önceki pano")
        XCTAssertEqual(h.events, ["prepare", "send", "consume", "restore", "submit"])
    }

    func testLongPasteCanBeVerifiedAfterMoreThanThreeSeconds() {
        let h = Harness()
        h.delay = 4.5
        let text = String(repeating: "uzun konuşma 👩🏽‍💻 ", count: 300)
        XCTAssertEqual(h.run(text), .verified)
        XCTAssertEqual(h.field, text)
        XCTAssertEqual(h.events, ["prepare", "send", "consume", "restore", "submit"])
        XCTAssertGreaterThanOrEqual(h.clock, 4.5)
        XCTAssertLessThan(h.clock, 8)
    }

    func testTruncatedFieldUsesRangeToVerifyAndRestoreClipboard() {
        let h = Harness()
        h.field = String(repeating: "x", count: 3_000)
        h.snapshotPrefixLength = 20
        h.readRange = { range in (h.field as NSString).substring(with: range) }
        let text = String(repeating: "uzun metin 👩🏽‍💻\n", count: 300)
        XCTAssertEqual(h.run(text), .verified)
        XCTAssertEqual(h.field, String(repeating: "x", count: 3_000) + text)
        XCTAssertEqual(h.clipboard, "önceki pano")
        XCTAssertEqual(h.events, ["prepare", "send", "consume", "restore", "submit"])
    }

    func testTruncatedRangeKeepsClipboardAndDoesNotSubmit() {
        let h = Harness()
        h.field = String(repeating: "x", count: 3_000)
        h.snapshotPrefixLength = 20
        h.readRange = { _ in "yalnızca bir parça" }
        let text = String(repeating: "uzun metin 👩🏽‍💻\n", count: 300)
        XCTAssertEqual(h.run(text), .unverifiable)
        XCTAssertEqual(h.clipboard, text)
        XCTAssertEqual(h.events, ["prepare", "send", "consume"])
        let before = TextInjector.FieldSnapshot(value: "x", count: 3_000, selection: NSRange(location: 3_000, length: 0))
        XCTAssertGreaterThanOrEqual(h.clock, TextInjector.verificationTimeout(for: text, before: before))
        XCTAssertLessThan(h.clock, 8.1)
    }

    func testUnreadableEditorKeepsClipboardWithoutAutoSubmit() {
        let h = Harness()
        h.readable = false
        XCTAssertEqual(h.run(), .unverifiable)
        XCTAssertEqual(h.clipboard, "uzun dikte")
        XCTAssertEqual(h.field, "uzun dikte")
        XCTAssertGreaterThanOrEqual(h.clock, 3)
        XCTAssertEqual(h.events, ["prepare", "send", "consume"])
    }

    func testTimeoutKeepsTextAndNeverRetriesOrSubmits() {
        let h = Harness()
        h.delay = 10
        XCTAssertEqual(h.run(), .notInserted)
        XCTAssertEqual(h.clipboard, "uzun dikte")
        XCTAssertEqual(h.events, ["prepare", "send"])
    }

    func testChangedClipboardBeforeSendDoesNotPasteUnrelatedText() {
        let h = Harness()
        h.onWait = { h.clipboard = "yeni kopyalama"; h.generation += 1 }
        XCTAssertEqual(h.run(), .failed(reason: "Pano başka bir işlem tarafından değiştirildi"))
        XCTAssertEqual(h.events, ["prepare"])
    }

    func testNewCopyOfIdenticalTextIsNotOverwritten() {
        let h = Harness()
        h.onWait = { if h.sentAt != nil { h.generation += 1 } }
        XCTAssertEqual(h.run(), .verified)
        XCTAssertEqual(h.clipboard, "uzun dikte")
        XCTAssertFalse(h.events.contains("restore"))
    }

    func testTargetChangeDuringPasteDelayPreventsKeystroke() {
        let h = Harness()
        h.onWait = { h.targetChange = "Sekme değişti" }
        XCTAssertEqual(h.run(), .targetChanged(reason: "Sekme değişti"))
        XCTAssertEqual(h.events, ["prepare"])
    }

    func testClipboardChangedDuringTargetCheckIsNotReportedAsRecoveryText() {
        let h = Harness()
        h.onTargetCheck = {
            h.targetChange = "Yazı alanı değişti"
            h.clipboard = "kullanıcının yeni panosu"
            h.generation += 1
        }
        XCTAssertEqual(h.run(), .failed(reason: "Pano başka bir işlem tarafından değiştirildi"))
        XCTAssertEqual(h.clipboard, "kullanıcının yeni panosu")
        XCTAssertEqual(h.events, ["prepare"])
    }

    func testTargetChangeDuringSnapshotPreventsKeystroke() {
        let h = Harness()
        h.onSnapshot = { h.targetChange = "Yazı alanı değişti" }
        XCTAssertEqual(h.run(), .targetChanged(reason: "Yazı alanı değişti"))
        XCTAssertEqual(h.clipboard, "uzun dikte")
        XCTAssertEqual(h.events, ["prepare"])
    }

    func testClipboardChangeDuringSnapshotPreventsKeystroke() {
        let h = Harness()
        h.onSnapshot = { h.clipboard = "yeni pano"; h.generation += 1 }
        XCTAssertEqual(h.run(), .failed(reason: "Pano başka bir işlem tarafından değiştirildi"))
        XCTAssertEqual(h.clipboard, "yeni pano")
        XCTAssertEqual(h.events, ["prepare"])
    }

    func testPasteboardFailureDoesNotSendOrRestore() {
        let h = Harness()
        h.writeSucceeds = false
        XCTAssertEqual(h.run(), .failed(reason: "Metin panoya yazılamadı"))
        XCTAssertEqual(h.events, ["prepare"])
    }

    func testKeystrokeFailureKeepsRecoveryText() {
        let h = Harness()
        h.sendSucceeds = false
        XCTAssertEqual(h.run(), .failed(reason: "Yapıştırma tuşu gönderilemedi"))
        XCTAssertEqual(h.clipboard, "uzun dikte")
        XCTAssertEqual(h.events, ["prepare", "send"])
    }

    func testCancellationDuringDelayDoesNotPaste() {
        let h = Harness()
        h.onWait = { h.cancelled = true }
        XCTAssertEqual(h.run(), .cancelled)
        XCTAssertEqual(h.events, ["prepare"])
    }

    func testRealInjectorQueueSerializesIdenticalIndependentDictations() {
        let h = Harness()
        let injector = TextInjector(clipboardEnvironment: { h.environment(text: $0) },
                                    targetCheck: { _ in .same })
        let done = expectation(description: "two deliveries")
        done.expectedFulfillmentCount = 2
        for _ in 0..<2 {
            XCTAssertTrue(injector.paste(text: "aynı metin", restoreClipboard: true) { outcome in
                XCTAssertTrue(Thread.isMainThread)
                XCTAssertEqual(outcome, .verified)
                done.fulfill()
            })
        }
        wait(for: [done], timeout: 3)
        XCTAssertEqual(h.field, "aynı metinaynı metin")
        XCTAssertEqual(h.clipboard, "önceki pano")
        XCTAssertEqual(h.events, ["prepare", "send", "consume", "restore",
                                  "prepare", "send", "consume", "restore"])
    }

    func testClipboardChangedDuringVerificationDoesNotClaimRecoveryText() {
        let h = Harness()
        h.onWait = {
            if h.sentAt != nil { h.clipboard = "başka metin"; h.generation += 1 }
        }
        XCTAssertEqual(h.run(), .failed(reason: "Aktarım doğrulanamadı; pano başka bir işlem tarafından değiştirildi"))
        XCTAssertEqual(h.clipboard, "başka metin")
        XCTAssertFalse(h.events.contains("restore"))
        XCTAssertFalse(h.events.contains("submit"))
    }

    func testTargetChangeAfterPastePreventsAutoSubmit() {
        let h = Harness()
        h.onWait = { if h.sentAt != nil { h.targetChange = "Sekme değişti" } }
        XCTAssertEqual(h.run(), .verified)
        XCTAssertFalse(h.events.contains("submit"))
    }

    func testCancellationDuringRestorationPreventsAutoSubmit() {
        let h = Harness()
        h.onRestore = { h.cancelled = true }
        XCTAssertEqual(h.run(), .verified)
        XCTAssertFalse(h.events.contains("submit"))
    }

    func testUnreadableEditorConsumesFirstTextBeforeNextQueuedPaste() {
        let h = Harness()
        h.readable = false
        let injector = TextInjector(clipboardEnvironment: { h.environment(text: $0) },
                                    targetCheck: { _ in .same })
        let done = expectation(description: "unreadable deliveries")
        done.expectedFulfillmentCount = 2
        for text in ["ilk metin", "ikinci metin"] {
            injector.paste(text: text, restoreClipboard: true, autoSubmit: true) { outcome in
                XCTAssertEqual(outcome, .unverifiable)
                done.fulfill()
            }
        }
        wait(for: [done], timeout: 3)
        XCTAssertEqual(h.field, "ilk metinikinci metin")
        XCTAssertEqual(h.clipboard, "ikinci metin")
        XCTAssertEqual(h.events, ["prepare", "send", "consume", "prepare", "send", "consume"])
    }

    func testRealInjectorCancellationStopsActiveAndQueuedDeliveries() {
        let h = Harness()
        let barrier = DispatchSemaphore(value: 0)
        let started = DispatchSemaphore(value: 0)
        h.onWait = {
            started.signal()
            XCTAssertEqual(barrier.wait(timeout: .now() + 2), .success)
        }
        let injector = TextInjector(clipboardEnvironment: { h.environment(text: $0) },
                                    targetCheck: { _ in .same })
        let done = expectation(description: "cancelled deliveries")
        done.expectedFulfillmentCount = 2
        for _ in 0..<2 {
            injector.paste(text: "iptal") { outcome in
                XCTAssertEqual(outcome, .cancelled)
                done.fulfill()
            }
        }
        XCTAssertEqual(started.wait(timeout: .now() + 2), .success)
        injector.cancelPendingInjections()
        barrier.signal()
        wait(for: [done], timeout: 3)
        XCTAssertFalse(h.events.contains("send"))
        XCTAssertFalse(h.events.contains("restore"))
    }
}
