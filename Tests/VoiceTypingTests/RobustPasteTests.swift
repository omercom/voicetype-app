import AppKit
import CoreGraphics
import XCTest
@testable import VoiceTypingCore

final class RobustPasteTests: XCTestCase {
    func testMakePasteKeyboardEventsTagsSyntheticUserData() throws {
        let pair = try XCTUnwrap(TextInjector.makePasteKeyboardEvents(vKeyCode: 0x09))
        for event in [pair.commandDown, pair.pasteDown, pair.pasteUp, pair.commandUp] {
            XCTAssertEqual(event.getIntegerValueField(.eventSourceUserData), TextInjector.syntheticEventUserData)
        }
    }

    func testWaitForClearModifiersImmediateAndTimeoutBehavior() {
        var polls = 0
        let immediate = TextInjector.waitForClearModifiers(
            maxWait: 0.2,
            pollInterval: 0.01,
            areModifiersClear: { true },
            canContinue: { true },
            now: { TimeInterval(polls) * 0.01 },
            wait: { _ in polls += 1 }
        )
        XCTAssertTrue(immediate)
        XCTAssertEqual(polls, 0)

        var clock = 0.0
        let delayedClear = TextInjector.waitForClearModifiers(
            maxWait: 0.2,
            pollInterval: 0.05,
            areModifiersClear: { clock >= 0.1 },
            canContinue: { true },
            now: { clock },
            wait: { clock += $0 }
        )
        XCTAssertTrue(delayedClear)
        XCTAssertGreaterThanOrEqual(clock, 0.1)

        var stuckClock = 0.0
        let timedOut = TextInjector.waitForClearModifiers(
            maxWait: 0.15,
            pollInterval: 0.05,
            areModifiersClear: { false },
            canContinue: { true },
            now: { stuckClock },
            wait: { stuckClock += $0 }
        )
        XCTAssertFalse(timedOut)
    }

    func testSkippablePromiseAndTransientPasteboardTypes() {
        XCTAssertTrue(TextInjector.isSkippablePromiseOrTransientType(NSPasteboard.PasteboardType("com.apple.pasteboard.promised-file-url")))
        XCTAssertTrue(TextInjector.isSkippablePromiseOrTransientType(NSPasteboard.PasteboardType("com.apple.pasteboard.promised-suggested-file-name")))
        XCTAssertTrue(TextInjector.isSkippablePromiseOrTransientType(NSPasteboard.PasteboardType("com.apple.is-remote-clipboard")))
        XCTAssertTrue(TextInjector.isSkippablePromiseOrTransientType(NSPasteboard.PasteboardType("org.nspasteboard.TransientType")))
        XCTAssertTrue(TextInjector.isSkippablePromiseOrTransientType(NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")))

        XCTAssertFalse(TextInjector.isSkippablePromiseOrTransientType(.string))
        XCTAssertFalse(TextInjector.isSkippablePromiseOrTransientType(.rtf))
        XCTAssertFalse(TextInjector.isSkippablePromiseOrTransientType(.html))
        XCTAssertFalse(TextInjector.isSkippablePromiseOrTransientType(.png))
    }

    func testOutcomeAcceptsTrailingSmartSpaceTrimmedInsertion() {
        let before = TextInjector.FieldSnapshot(value: "Merhaba", count: 7, selection: NSRange(location: 7, length: 0))
        let after = TextInjector.FieldSnapshot(value: "Merhaba dünya", count: 13, selection: NSRange(location: 13, length: 0))
        let result = TextInjector.outcome(before: before, after: after, insertedText: " dünya ")
        XCTAssertEqual(result, .verified)
    }

    func testTargetEquivalenceAcceptsSameOrDescendantOrSameContainer() {
        XCTAssertTrue(TargetInputManager.isEquivalentLiveField(sameElement: true, isDescendantOrAncestor: false, isSameContainerTextInput: false))
        XCTAssertTrue(TargetInputManager.isEquivalentLiveField(sameElement: false, isDescendantOrAncestor: true, isSameContainerTextInput: false))
        XCTAssertTrue(TargetInputManager.isEquivalentLiveField(sameElement: false, isDescendantOrAncestor: false, isSameContainerTextInput: true))
        XCTAssertFalse(TargetInputManager.isEquivalentLiveField(sameElement: false, isDescendantOrAncestor: false, isSameContainerTextInput: false))
    }

    func testModifiersSafeForPasteAllowsSyntheticCommandAfterCommandDown() {
        XCTAssertTrue(TextInjector.areModifiersSafeForPaste(flags: [], commandAlreadyPosted: false))
        XCTAssertFalse(TextInjector.areModifiersSafeForPaste(flags: .maskCommand, commandAlreadyPosted: false))
        XCTAssertTrue(TextInjector.areModifiersSafeForPaste(flags: .maskCommand, commandAlreadyPosted: true))
        XCTAssertFalse(TextInjector.areModifiersSafeForPaste(flags: [.maskCommand, .maskShift], commandAlreadyPosted: true))
        XCTAssertFalse(TextInjector.areModifiersSafeForPaste(flags: .maskAlternate, commandAlreadyPosted: true))
        XCTAssertFalse(TextInjector.areModifiersSafeForPaste(flags: .maskControl, commandAlreadyPosted: true))
    }

    func testPasteShortcutSequenceSucceedsWhenHIDCommandFlagReflectsSyntheticCommandDown() {
        var hidFlags: CGEventFlags = []
        var posted: [PasteShortcutSequence.Event] = []
        var commandAlreadyPosted = false

        let result = PasteShortcutSequence.run(
            isSafe: {
                TextInjector.areModifiersSafeForPaste(flags: hidFlags, commandAlreadyPosted: commandAlreadyPosted)
            },
            post: { phase in
                posted.append(phase)
                switch phase {
                case .commandDown:
                    commandAlreadyPosted = true
                    hidFlags.insert(.maskCommand)
                case .commandUp:
                    hidFlags.remove(.maskCommand)
                case .pasteDown, .pasteUp:
                    break
                }
            },
            wait: { _ in }
        )

        XCTAssertTrue(result)
        XCTAssertEqual(posted, [.commandDown, .pasteDown, .pasteUp, .commandUp])
        XCTAssertTrue(hidFlags.isEmpty)
    }
}
