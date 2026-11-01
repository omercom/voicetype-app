import XCTest
@testable import VoiceTypingCore

final class AutomationCommandsTests: XCTestCase {
    private let own = "com.antigravity.VoiceTyping"
    private let editor = "com.example.editor"

    func testAllowsOnlyTheExpectedFrontmostApplication() {
        XCTAssertEqual(AutomationStartDecision.resolve(expected: editor, frontmost: editor, ownBundle: own, busy: false), .ready)
        XCTAssertEqual(AutomationStartDecision.resolve(expected: editor, frontmost: "com.example.other", ownBundle: own, busy: false), .targetChanged)
        XCTAssertEqual(AutomationStartDecision.resolve(expected: editor, frontmost: nil, ownBundle: own, busy: false), .targetChanged)
    }

    func testRejectsMissingOrUnsafeTargets() {
        XCTAssertEqual(AutomationStartDecision.resolve(expected: nil, frontmost: editor, ownBundle: own, busy: false), .missingTarget)
        XCTAssertEqual(AutomationStartDecision.resolve(expected: "  ", frontmost: editor, ownBundle: own, busy: false), .missingTarget)
        for bundle in [own, "com.raycast.macos", "com.apple.dock", "com.apple.controlcenter", "com.apple.notificationcenterui"] {
            XCTAssertEqual(AutomationStartDecision.resolve(expected: bundle, frontmost: bundle, ownBundle: own, busy: false), .unsupportedTarget)
        }
    }

    func testDoesNotStartAnotherDictationWhileBusy() {
        XCTAssertEqual(AutomationStartDecision.resolve(expected: editor, frontmost: editor, ownBundle: own, busy: true), .busy)
    }

    func testTargetMustStillMatchAtTheMomentItIsCaptured() {
        let validate = AutomationStartDecision.acceptsCapture
        XCTAssertTrue(validate(editor, editor, 10, editor, 10))
        XCTAssertFalse(validate(editor, "com.example.other", 10, editor, 10))
        XCTAssertFalse(validate(editor, editor, 10, "com.example.other", 10))
        XCTAssertFalse(validate(editor, editor, 11, editor, 10))
        XCTAssertFalse(validate(editor, editor, 10, nil, nil))
        XCTAssertTrue(validate(nil, nil, nil, nil, nil))
    }

    func testScriptClassesAreAvailableToCocoaScripting() {
        XCTAssertNotNil(NSClassFromString("VoiceTypeStartDictationCommand"))
        XCTAssertNotNil(NSClassFromString("VoiceTypeStopDictationCommand"))
        XCTAssertNotNil(NSClassFromString("VoiceTypeOpenSettingsCommand"))
        XCTAssertNotNil(NSClassFromString("VoiceTypeAutomationStatusCommand"))
    }
}
