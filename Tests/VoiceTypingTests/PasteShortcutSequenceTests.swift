import Carbon
import CoreGraphics
import XCTest
@testable import VoiceTypingCore

final class PasteShortcutSequenceTests: XCTestCase {
    func testSendsOneCompleteShortcutInOrder() {
        var events: [PasteShortcutSequence.Event] = []
        var waits: [TimeInterval] = []
        let result = PasteShortcutSequence.run(
            isSafe: { true }, post: { events.append($0) }, wait: { waits.append($0) }
        )

        XCTAssertTrue(result)
        XCTAssertEqual(events, [.commandDown, .pasteDown, .pasteUp, .commandUp])
        XCTAssertEqual(events.filter { $0 == .pasteDown }.count, 1)
        XCTAssertEqual(waits.count, 3)
        XCTAssertTrue(waits.allSatisfy { $0 > 0 })
    }

    func testDoesNotSendAnythingWhenInitiallyUnsafe() {
        var events: [PasteShortcutSequence.Event] = []
        let result = PasteShortcutSequence.run(
            isSafe: { false }, post: { events.append($0) }, wait: { _ in }
        )

        XCTAssertFalse(result)
        XCTAssertTrue(events.isEmpty)
    }

    func testFocusChangeBeforePasteReleasesCommandWithoutPasting() {
        var events: [PasteShortcutSequence.Event] = []
        var checks = 0
        let result = PasteShortcutSequence.run(
            isSafe: { checks += 1; return checks == 1 },
            post: { events.append($0) }, wait: { _ in }
        )

        XCTAssertFalse(result)
        XCTAssertEqual(events, [.commandDown, .commandUp])
    }

    func testCancellationAfterPasteDownStillReleasesBothKeys() {
        var events: [PasteShortcutSequence.Event] = []
        var safe = true
        let result = PasteShortcutSequence.run(
            isSafe: { safe },
            post: { event in
                events.append(event)
                if event == .pasteDown { safe = false }
            },
            wait: { _ in }
        )

        XCTAssertTrue(result)
        XCTAssertEqual(events, [.commandDown, .pasteDown, .pasteUp, .commandUp])
    }

    func testNativeEventsIncludeExplicitModifierTransitions() throws {
        let events = try XCTUnwrap(TextInjector.makePasteKeyboardEvents(vKeyCode: CGKeyCode(kVK_ANSI_V)))
        XCTAssertEqual(events.commandDown.type, .flagsChanged)
        XCTAssertEqual(events.commandUp.type, .flagsChanged)
        XCTAssertTrue(events.commandDown.flags.contains(.maskCommand))
        XCTAssertFalse(events.commandUp.flags.contains(.maskCommand))
        XCTAssertEqual(events.pasteDown.type, .keyDown)
        XCTAssertEqual(events.pasteUp.type, .keyUp)
        XCTAssertTrue(events.pasteDown.flags.contains(.maskCommand))
        XCTAssertTrue(events.pasteUp.flags.contains(.maskCommand))
        XCTAssertEqual(events.commandDown.getIntegerValueField(.keyboardEventKeycode), Int64(kVK_Command))
        XCTAssertEqual(events.pasteDown.getIntegerValueField(.keyboardEventKeycode), Int64(kVK_ANSI_V))
    }
}
