import XCTest
import ApplicationServices
@testable import VoiceTypingCore

final class TargetIdentityTests: XCTestCase {
    private func check(pid: pid_t? = 42, element: Bool = true, window: Bool? = true,
                       expectedURL: String? = "https://example.com/a",
                       currentURL: String? = "https://example.com/a") -> TargetInputManager.TargetCheck {
        TargetInputManager.assessTarget(expectedPID: 42, focusedPID: pid, sameElement: element,
                                        sameWindow: window, expectedPageURL: expectedURL,
                                        currentPageURL: currentURL)
    }

    func testSameTargetIsAccepted() {
        XCTAssertEqual(check(), .same)
        XCTAssertEqual(check(window: nil, expectedURL: nil, currentURL: nil), .same)
    }

    func testMissingFocusOrDifferentProcessIsRejected() {
        XCTAssertEqual(check(pid: nil), .changed(reason: "Odak doğrulanamadı"))
        XCTAssertEqual(check(pid: 43), .changed(reason: "Başka uygulama odakta"))
    }

    func testDifferentFieldOrWindowInSameAppIsRejected() {
        XCTAssertEqual(check(element: false), .changed(reason: "Yazı alanı değişti"))
        XCTAssertEqual(check(window: false), .changed(reason: "Pencere değişti"))
    }

    func testReusedElementStillRequiresOriginalPage() {
        XCTAssertEqual(check(currentURL: "https://example.com/b"),
                       .changed(reason: "Sekme doğrulanamadı veya değişti"))
        XCTAssertEqual(check(currentURL: nil), .changed(reason: "Sekme doğrulanamadı veya değişti"))
    }

    func testMissingShortcutKeyDoesNotResolveToAnUnrelatedKey() {
        XCTAssertTrue(Thread.isMainThread)
        XCTAssertNil(TextInjector.resolvedKeyCodeForCharacter("😀"))
        XCTAssertEqual(TextInjector.keyCodeForCharacter("😀", fallback: 123), 123)
    }

    func testIdenticalSelectionReplacementIsNotClaimedAsVerified() {
        let before = TextInjector.FieldSnapshot(value: "aynı metin", count: nil,
                                                selection: NSRange(location: 0, length: 4))
        let after = TextInjector.FieldSnapshot(value: "aynı metin", count: nil)
        XCTAssertEqual(TextInjector.outcome(before: before, after: after, insertedText: "aynı"), .unverifiable)
    }
}

final class SelectedTextTransactionTests: XCTestCase {
    private final class Harness {
        var field = "önce eski sonra"
        var selection = NSRange(location: 5, length: 4)
        var supported = true
        var targetChange: String?
        var cancelled = false
        var writeSucceeds = true
        var applyWrite = true
        var clock = 0.0
        var writes = 0
        var submits = 0
        var clipboardPreparations = 0
        var clipboardSends = 0
        var snapshotPrefixLength: Int?
        var readRange: ((NSRange) -> String?)?
        var onSnapshot: (() -> Void)?
        var onWrite: (() -> Void)?

        func environment() -> SelectedTextTransaction.Environment {
            .init(
                supportsSelectedText: { self.supported },
                targetChangedReason: { self.targetChange },
                snapshot: {
                    self.onSnapshot?()
                    let visible = self.snapshotPrefixLength.map { String(self.field.prefix($0)) } ?? self.field
                    return .init(value: visible, count: self.field.utf16.count, selection: self.selection)
                },
                writeSelectedText: { text in
                    self.writes += 1
                    if self.applyWrite {
                        let start = self.selection.location
                        self.field = (self.field as NSString).replacingCharacters(in: self.selection, with: text)
                        self.selection = NSRange(location: start + text.utf16.count, length: 0)
                    }
                    self.onWrite?()
                    return self.writeSucceeds
                },
                autoSubmit: { self.submits += 1 },
                isCancelled: { self.cancelled },
                now: { self.clock },
                wait: { self.clock += $0 },
                readRange: { self.readRange?($0) }
            )
        }

        func run(_ text: String = "yeni", autoSubmit: Bool = true) -> SelectedTextTransaction.Attempt {
            SelectedTextTransaction.run(text: text, autoSubmit: autoSubmit, environment: environment())
        }

        func clipboardEnvironment(text: String) -> ClipboardPasteTransaction.Environment {
            .init(
                prepare: { self.clipboardPreparations += 1; return true },
                ownsClipboard: { true },
                targetChangedReason: { self.targetChange },
                snapshot: { .init(value: self.field, count: nil, selection: self.selection) },
                sendPaste: {
                    self.clipboardSends += 1
                    self.field = (self.field as NSString).replacingCharacters(in: self.selection, with: text)
                    return true
                },
                restore: {}, autoSubmit: {}, isCancelled: { self.cancelled },
                now: { self.clock }, wait: { self.clock += $0 }
            )
        }

        func injector() -> TextInjector {
            TextInjector(clipboardEnvironment: { self.clipboardEnvironment(text: $0) },
                         targetCheck: { _ in .same },
                         selectedTextEnvironment: { _ in self.environment() })
        }

        func target() -> TargetContext {
            let pid = ProcessInfo.processInfo.processIdentifier
            return TargetContext(pid: pid, bundleIdentifier: "test", appName: "test", runningApp: nil,
                                 element: AXUIElementCreateApplication(pid), window: nil, role: "AXTextField")
        }
    }

    func testInjectorUsesSelectedTextWithoutClipboard() {
        let h = Harness()
        let done = expectation(description: "selected text delivered")
        XCTAssertTrue(h.injector().paste(text: "yeni", targetContext: h.target(), typeDirectly: true) { outcome in
            XCTAssertEqual(outcome, .verified)
            done.fulfill()
        })
        wait(for: [done], timeout: 2)
        XCTAssertEqual(h.field, "önce yeni sonra")
        XCTAssertEqual(h.writes, 1)
        XCTAssertEqual(h.clipboardPreparations, 0)
    }

    func testSelectedTextAttemptIsReportedBeforeVerificationResult() {
        let h = Harness()
        h.applyWrite = false
        let done = expectation(description: "selected text not inserted")
        var callbacks: [String] = []
        XCTAssertTrue(h.injector().paste(text: "yeni", targetContext: h.target(), typeDirectly: true,
                                         observer: .init(onAttempted: {
            XCTAssertTrue(Thread.isMainThread)
            callbacks.append("attempted")
        })) { outcome in
            XCTAssertTrue(Thread.isMainThread)
            XCTAssertEqual(outcome, .notInserted)
            callbacks.append("completed")
            done.fulfill()
        })
        wait(for: [done], timeout: 2)
        XCTAssertEqual(callbacks, ["attempted", "completed"])
        XCTAssertEqual(h.writes, 1)
        XCTAssertEqual(h.clipboardPreparations, 0)
    }

    func testInjectorFallsBackOnlyWhenSelectedTextIsUnsupported() {
        let h = Harness()
        h.supported = false
        let done = expectation(description: "clipboard fallback delivered")
        XCTAssertTrue(h.injector().paste(text: "yeni", targetContext: h.target(), typeDirectly: true) { outcome in
            XCTAssertEqual(outcome, .verified)
            done.fulfill()
        })
        wait(for: [done], timeout: 2)
        XCTAssertEqual(h.writes, 0)
        XCTAssertEqual(h.clipboardPreparations, 1)
        XCTAssertEqual(h.clipboardSends, 1)
    }

    func testInjectorDoesNotFallBackAfterAnUncertainWrite() {
        let h = Harness()
        h.writeSucceeds = false
        let done = expectation(description: "uncertain write reported")
        XCTAssertTrue(h.injector().paste(text: "yeni", targetContext: h.target(), typeDirectly: true) { outcome in
            XCTAssertEqual(outcome, .failed(reason: "Metin aktarımı doğrulanamadı; hedefi kontrol edin"))
            done.fulfill()
        })
        wait(for: [done], timeout: 2)
        XCTAssertEqual(h.writes, 1)
        XCTAssertEqual(h.clipboardPreparations, 0)
        XCTAssertEqual(h.clipboardSends, 0)
    }

    func testReplacesOnlySelectionWithUnicodeAndNewlines() {
        let h = Harness()
        let text = "İğüşöç 👩🏽‍💻\nikinci satır"
        XCTAssertEqual(h.run(text), .finished(.verified))
        XCTAssertEqual(h.field, "önce \(text) sonra")
        XCTAssertEqual(h.writes, 1)
        XCTAssertEqual(h.submits, 1)
    }

    func testSelectedTextUsesRangeWhenTheFieldValueIsTruncated() {
        let h = Harness()
        h.field = String(repeating: "x", count: 3_000) + "eski" + String(repeating: "y", count: 3_000)
        h.selection = NSRange(location: 3_000, length: 4)
        h.snapshotPrefixLength = 20
        h.readRange = { range in (h.field as NSString).substring(with: range) }
        XCTAssertEqual(h.run(), .finished(.verified))
        XCTAssertEqual(h.writes, 1)
        XCTAssertEqual(h.submits, 1)
    }

    func testUnsupportedIsTheOnlySafeFallback() {
        let h = Harness()
        h.supported = false
        XCTAssertEqual(h.run(), .unsupported)
        XCTAssertEqual(h.writes, 0)
        XCTAssertEqual(h.submits, 0)
    }

    func testChangedFocusDuringSnapshotPreventsWrite() {
        let h = Harness()
        h.onSnapshot = { h.targetChange = "Yazı alanı değişti" }
        XCTAssertEqual(h.run(), .finished(.targetChanged(reason: "Yazı alanı değişti")))
        XCTAssertEqual(h.writes, 0)
        XCTAssertEqual(h.submits, 0)
    }

    func testFailedWriteIsNotRetriedEvenIfItChangedTheField() {
        let h = Harness()
        h.writeSucceeds = false
        XCTAssertEqual(h.run(), .finished(.failed(reason: "Metin aktarımı doğrulanamadı; hedefi kontrol edin")))
        XCTAssertEqual(h.field, "önce yeni sonra")
        XCTAssertEqual(h.writes, 1)
        XCTAssertEqual(h.submits, 0)
    }

    func testUnchangedFieldIsNotSubmittedOrRetried() {
        let h = Harness()
        h.applyWrite = false
        XCTAssertEqual(h.run(), .finished(.notInserted))
        XCTAssertEqual(h.writes, 1)
        XCTAssertEqual(h.submits, 0)
        XCTAssertGreaterThanOrEqual(h.clock, 3)
    }

    func testFocusChangeAfterWriteStopsAutoSubmit() {
        let h = Harness()
        h.onWrite = { h.targetChange = "Yazı alanı değişti" }
        XCTAssertEqual(h.run(), .finished(.verified))
        XCTAssertEqual(h.writes, 1)
        XCTAssertEqual(h.submits, 0)
    }

    func testCancellationDuringSnapshotPreventsWrite() {
        let h = Harness()
        h.onSnapshot = { h.cancelled = true }
        XCTAssertEqual(h.run(), .finished(.cancelled))
        XCTAssertEqual(h.writes, 0)
    }
}
