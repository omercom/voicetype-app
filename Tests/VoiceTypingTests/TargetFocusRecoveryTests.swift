import XCTest
import ApplicationServices
@testable import VoiceTypingCore

final class TargetFocusRecoveryTests: XCTestCase {
    private final class Harness {
        var validProcess = true
        var available = true
        var focused = false
        var appFocused = false
        var windowFocused = false
        var activationSucceeds = true
        var focusSucceeds = true
        var windowRaises = true
        var fieldActuallyFocuses = true
        var cancelled = false
        var clock: TimeInterval = 0
        var events: [String] = []
        var onActivate: (() -> Void)?
        var onRaise: (() -> Void)?
        var onFocus: (() -> Void)?

        func environment() -> TargetFocusRecovery.Environment {
            .init(
                processIsValid: { self.validProcess },
                targetIsAvailable: { self.available && self.validProcess },
                targetIsFocused: { self.focused && self.appFocused && self.windowFocused },
                applicationIsFocused: { self.appFocused },
                activateApplication: {
                    self.events.append("activate")
                    if self.activationSucceeds { self.appFocused = true }
                    self.onActivate?()
                    return self.activationSucceeds
                },
                windowIsFocused: { self.windowFocused },
                raiseWindow: {
                    self.events.append("raise")
                    if self.windowRaises { self.windowFocused = true }
                    self.onRaise?()
                },
                focusField: {
                    self.events.append("focus")
                    if self.focusSucceeds && self.fieldActuallyFocuses { self.focused = true }
                    self.onFocus?()
                    return self.focusSucceeds
                },
                isCancelled: { self.cancelled },
                now: { self.clock },
                wait: { self.clock += $0 }
            )
        }
    }

    func testAlreadyFocusedDoesNotStealFocus() {
        let h = Harness()
        h.appFocused = true; h.windowFocused = true; h.focused = true
        XCTAssertEqual(TargetFocusRecovery.run(h.environment()), .ready)
        XCTAssertEqual(h.events, [])
    }

    func testRestoresOriginalAppWindowAndFieldInOrder() {
        let h = Harness()
        XCTAssertEqual(TargetFocusRecovery.run(h.environment()), .ready)
        XCTAssertEqual(h.events, ["activate", "raise", "focus"])
    }

    func testDifferentFieldInSameWindowOnlyRefocusesField() {
        let h = Harness()
        h.appFocused = true; h.windowFocused = true
        XCTAssertEqual(TargetFocusRecovery.run(h.environment()), .ready)
        XCTAssertEqual(h.events, ["focus"])
    }

    func testExitedOrReplacedProcessIsNeverActivated() {
        let h = Harness()
        h.validProcess = false
        XCTAssertEqual(TargetFocusRecovery.run(h.environment()), .unavailable)
        XCTAssertEqual(h.events, [])
    }

    func testClosedOrChangedFieldIsNeverFocused() {
        let h = Harness()
        h.available = false
        XCTAssertEqual(TargetFocusRecovery.run(h.environment()), .unavailable)
        XCTAssertEqual(h.events, ["activate", "raise"])
    }

    func testActivationFailureDoesNotFocusAnotherApp() {
        let h = Harness()
        h.activationSucceeds = false
        XCTAssertEqual(TargetFocusRecovery.run(h.environment()), .unavailable)
        XCTAssertEqual(h.events, ["activate"])
    }

    func testWindowThatDoesNotRaiseStopsBeforeFocusing() {
        let h = Harness()
        h.windowRaises = false
        XCTAssertEqual(TargetFocusRecovery.run(h.environment()), .unavailable)
        XCTAssertEqual(h.events, ["activate", "raise"])
        XCTAssertGreaterThanOrEqual(h.clock, 0.8)
    }

    func testFocusSuccessMustBeVerified() {
        let h = Harness()
        h.fieldActuallyFocuses = false
        XCTAssertEqual(TargetFocusRecovery.run(h.environment()), .unavailable)
        XCTAssertEqual(h.events, ["activate", "raise", "focus"])
        XCTAssertGreaterThanOrEqual(h.clock, 0.8)
    }

    func testCancellationDuringActivationDoesNotRaiseOrFocus() {
        let h = Harness()
        h.onActivate = { h.cancelled = true }
        XCTAssertEqual(TargetFocusRecovery.run(h.environment()), .cancelled)
        XCTAssertEqual(h.events, ["activate"])
    }

    func testCancellationDuringWindowRaiseDoesNotFocus() {
        let h = Harness()
        h.onRaise = { h.cancelled = true }
        XCTAssertEqual(TargetFocusRecovery.run(h.environment()), .cancelled)
        XCTAssertEqual(h.events, ["activate", "raise"])
    }

    func testTargetThatDisappearsDuringRaiseIsNotFocused() {
        let h = Harness()
        h.onRaise = { h.available = false }
        XCTAssertEqual(TargetFocusRecovery.run(h.environment()), .unavailable)
        XCTAssertEqual(h.events, ["activate", "raise"])
    }

    func testSwitchingAppDuringRaiseStopsBeforeFocus() {
        let h = Harness()
        h.onRaise = { h.appFocused = false }
        XCTAssertEqual(TargetFocusRecovery.run(h.environment()), .unavailable)
        XCTAssertEqual(h.events, ["activate", "raise"])
    }
}

final class TargetRecoveryDeliveryTests: XCTestCase {
    private final class Harness {
        var targetFocused = false
        var restoreSucceeds = true
        var restorePolicy = true
        var restores = 0
        var sends = 0
        var fallbackText: String?
        var field = ""
        var clock: TimeInterval = 0
        var onRestore: (() -> Void)?

        func target() -> TargetContext {
            let pid = ProcessInfo.processInfo.processIdentifier
            return TargetContext(pid: pid, bundleIdentifier: "test", appName: "test", runningApp: nil,
                                 element: AXUIElementCreateApplication(pid), window: nil, role: "AXTextField")
        }

        func clipboardEnvironment(_ text: String) -> ClipboardPasteTransaction.Environment {
            .init(
                prepare: { true }, ownsClipboard: { true },
                targetChangedReason: { self.targetFocused ? nil : "Yazı alanı değişti" },
                snapshot: { .init(value: self.field, count: self.field.utf16.count,
                                  selection: NSRange(location: self.field.utf16.count, length: 0)) },
                sendPaste: { self.sends += 1; self.field += text; return true },
                restore: {}, autoSubmit: {},
                now: { self.clock }, wait: { self.clock += $0 }
            )
        }

        func injector() -> TextInjector {
            TextInjector(
                clipboardEnvironment: { self.clipboardEnvironment($0) },
                targetCheck: { _ in self.targetFocused ? .same : .changed(reason: "Yazı alanı değişti") },
                restoreTarget: { _ in
                    self.restores += 1
                    if self.restoreSucceeds { self.targetFocused = true }
                    self.onRestore?()
                    return self.restoreSucceeds
                },
                fallbackClipboard: { self.fallbackText = $0; return true },
                configProvider: {
                    var config = AppConfig.defaultConfig
                    config.restore_target_focus = self.restorePolicy
                    return config
                }
            )
        }
    }

    func testOriginalTargetIsRestoredThenTextIsPastedOnce() {
        let h = Harness(); let injector = h.injector()
        let done = expectation(description: "delivered")
        XCTAssertTrue(injector.paste(text: "Merhaba", targetContext: h.target(), restoreOriginalTarget: true) { outcome in
            XCTAssertEqual(outcome, .verified); done.fulfill()
        })
        wait(for: [done], timeout: 2)
        XCTAssertEqual(h.restores, 1)
        XCTAssertEqual(h.sends, 1)
        XCTAssertEqual(h.field, "Merhaba")
        XCTAssertNil(h.fallbackText)
    }

    func testStrictPolicyKeepsExistingWarningAndDoesNotRestore() {
        let h = Harness(); let injector = h.injector()
        let done = expectation(description: "manual paste")
        XCTAssertTrue(injector.paste(text: "Merhaba", targetContext: h.target(), restoreOriginalTarget: false) { outcome in
            XCTAssertEqual(outcome, .targetChanged(reason: "Yazı alanı değişti")); done.fulfill()
        })
        wait(for: [done], timeout: 2)
        XCTAssertEqual(h.restores, 0)
        XCTAssertEqual(h.sends, 0)
        XCTAssertEqual(h.fallbackText, "Merhaba")
    }

    func testInjectUsesRestorePolicyFromConfiguration() {
        let h = Harness(); h.restorePolicy = true
        let injector = h.injector(); let done = expectation(description: "configured recovery")
        XCTAssertTrue(injector.inject(text: "Merhaba", targetContext: h.target()) { outcome in
            XCTAssertEqual(outcome, .verified); done.fulfill()
        })
        wait(for: [done], timeout: 2)
        XCTAssertEqual(h.restores, 1)
        XCTAssertEqual(h.sends, 1)
        XCTAssertNil(h.fallbackText)
    }

    func testInjectUsesWarningPolicyFromConfiguration() {
        let h = Harness(); h.restorePolicy = false
        let injector = h.injector(); let done = expectation(description: "configured warning")
        XCTAssertTrue(injector.inject(text: "Merhaba", targetContext: h.target()) { outcome in
            XCTAssertEqual(outcome, .targetChanged(reason: "Yazı alanı değişti")); done.fulfill()
        })
        wait(for: [done], timeout: 2)
        XCTAssertEqual(h.restores, 0)
        XCTAssertEqual(h.sends, 0)
        XCTAssertEqual(h.fallbackText, "Merhaba")
    }

    func testFailureToRestoreKeepsTextWithoutPasting() {
        let h = Harness(); h.restoreSucceeds = false
        let injector = h.injector(); let done = expectation(description: "recovery failed")
        XCTAssertTrue(injector.paste(text: "Merhaba", targetContext: h.target(), restoreOriginalTarget: true) { outcome in
            XCTAssertEqual(outcome, .targetChanged(reason: "Yazı alanı değişti")); done.fulfill()
        })
        wait(for: [done], timeout: 2)
        XCTAssertEqual(h.restores, 1)
        XCTAssertEqual(h.sends, 0)
        XCTAssertEqual(h.fallbackText, "Merhaba")
    }

    func testRestoreSuccessMustStillPassFinalTargetCheck() {
        let h = Harness()
        h.onRestore = { h.targetFocused = false }
        let injector = h.injector(); let done = expectation(description: "focus changed again")
        XCTAssertTrue(injector.paste(text: "Merhaba", targetContext: h.target(), restoreOriginalTarget: true) { outcome in
            XCTAssertEqual(outcome, .targetChanged(reason: "Yazı alanı değişti")); done.fulfill()
        })
        wait(for: [done], timeout: 2)
        XCTAssertEqual(h.sends, 0)
        XCTAssertEqual(h.fallbackText, "Merhaba")
    }

    func testCancellationWhileRestoringDoesNotPasteOrOverwriteClipboard() {
        let h = Harness(); let injector = h.injector()
        h.onRestore = { injector.cancelPendingInjections() }
        let done = expectation(description: "cancelled")
        XCTAssertTrue(injector.paste(text: "Merhaba", targetContext: h.target(), restoreOriginalTarget: true) { outcome in
            XCTAssertEqual(outcome, .cancelled); done.fulfill()
        })
        wait(for: [done], timeout: 2)
        XCTAssertEqual(h.sends, 0)
        XCTAssertNil(h.fallbackText)
    }
}
