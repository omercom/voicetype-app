import Foundation
import CoreGraphics
import XCTest
@testable import VoiceTypingCore

final class DictationShortcutStateTests: XCTestCase {
    private let command: Int64 = 54
    private let option: Int64 = 61

    private func press(_ state: inout DictationShortcutState, _ key: Int64, mode: String = "hold",
                       enabled: Bool = true, primary: Int64 = 54, time: TimeInterval = 0) -> DictationShortcutAction? {
        state.press(keyCode: key, primaryKeyCode: primary, translationEnabled: enabled,
                    triggerMode: mode, time: time)
    }

    func testRightModifierPressAndReleaseFlags() {
        let rightCommand = CGEventFlags(rawValue: CGEventFlags.maskCommand.rawValue | 0x10)
        let rightOption = CGEventFlags(rawValue: CGEventFlags.maskAlternate.rawValue | 0x40)
        XCTAssertTrue(KeyListener.isModifierPressed(keyCode: command, flags: rightCommand, currentKeyDown: false))
        XCTAssertFalse(KeyListener.isModifierPressed(keyCode: command, flags: [], currentKeyDown: true))
        XCTAssertTrue(KeyListener.isModifierPressed(keyCode: option, flags: rightOption, currentKeyDown: false))
        XCTAssertFalse(KeyListener.isModifierPressed(keyCode: option, flags: [], currentKeyDown: true))
    }

    func testModifierEventsRouteBothShortcuts() {
        var state = DictationShortcutState()
        let rightCommand = CGEventFlags(rawValue: CGEventFlags.maskCommand.rawValue | 0x10)
        let rightOption = CGEventFlags(rawValue: CGEventFlags.maskAlternate.rawValue | 0x40)
        func handle(_ key: Int64, _ flags: CGEventFlags, _ time: TimeInterval) -> DictationShortcutResult {
            state.handle(keyCode: key, event: .flagsChanged(flags), primaryKeyCode: command,
                         translationEnabled: true, triggerMode: "hold", time: time)
        }
        let commandDown = handle(command, rightCommand, 1)
        XCTAssertEqual(commandDown.action, .start(.normal))
        XCTAssertFalse(commandDown.consume)
        XCTAssertEqual(handle(command, [], 2).action, .stop(1))
        let optionDown = handle(option, rightOption, 3)
        XCTAssertEqual(optionDown.action, .start(.translation))
        XCTAssertFalse(optionDown.consume)
        XCTAssertEqual(handle(option, [], 5).action, .stop(2))
    }

    func testCommandChordCancelsAndPassesThrough() {
        var state = DictationShortcutState()
        let flags = CGEventFlags(rawValue: CGEventFlags.maskCommand.rawValue | 0x10)
        let down = state.handle(keyCode: command, event: .flagsChanged(flags), primaryKeyCode: command,
                                translationEnabled: true, triggerMode: "hold", time: 1)
        XCTAssertEqual(down.action, .start(.normal))
        let copy = state.handle(keyCode: 8, event: .keyDown(isRepeat: false), primaryKeyCode: command,
                                translationEnabled: true, triggerMode: "hold", time: 1.2)
        XCTAssertEqual(copy.action, .cancel)
        XCTAssertFalse(copy.consume)
        let release = state.handle(keyCode: command, event: .flagsChanged([]), primaryKeyCode: command,
                                   translationEnabled: true, triggerMode: "hold", time: 1.3)
        XCTAssertNil(release.action)
    }

    func testNonModifierPrimarySwallowsOnlyItsOwnEvents() {
        var state = DictationShortcutState()
        let down = state.handle(keyCode: 96, event: .keyDown(isRepeat: false), primaryKeyCode: 96,
                                translationEnabled: true, triggerMode: "hold", time: 1)
        XCTAssertEqual(down.action, .start(.normal))
        XCTAssertTrue(down.consume)
        let repeatEvent = state.handle(keyCode: 96, event: .keyDown(isRepeat: true), primaryKeyCode: 96,
                                       translationEnabled: true, triggerMode: "hold", time: 1.2)
        XCTAssertNil(repeatEvent.action)
        XCTAssertTrue(repeatEvent.consume)
        let up = state.handle(keyCode: 96, event: .keyUp, primaryKeyCode: 96,
                              translationEnabled: true, triggerMode: "hold", time: 2)
        XCTAssertEqual(up.action, .stop(1))
        XCTAssertTrue(up.consume)
    }

    func testRightCommandStartsNormalAndRightOptionStartsTranslation() {
        var state = DictationShortcutState()
        XCTAssertEqual(press(&state, command, time: 1), .start(.normal))
        XCTAssertEqual(state.release(keyCode: command, time: 3), .stop(2))
        XCTAssertEqual(press(&state, option, time: 4), .start(.translation))
        XCTAssertEqual(state.release(keyCode: option, time: 7), .stop(3))
    }

    func testTranslationShortcutIsInactiveWhenDisabled() {
        var state = DictationShortcutState()
        XCTAssertFalse(state.canHandle(keyCode: option, primaryKeyCode: command, translationEnabled: false))
        XCTAssertNil(press(&state, option, enabled: false))
        XCTAssertEqual(press(&state, command, enabled: false), .start(.normal))
    }

    func testCustomPrimaryKeyStillStartsNormalDictation() {
        var state = DictationShortcutState()
        XCTAssertEqual(press(&state, 62, primary: 62), .start(.normal))
        XCTAssertEqual(state.release(keyCode: 62, time: 1), .stop(1))
        XCTAssertEqual(press(&state, option, primary: 62, time: 2), .start(.translation))
    }

    func testSameKeyConflictPrefersExplicitTranslation() {
        var state = DictationShortcutState()
        XCTAssertEqual(press(&state, option, primary: option), .start(.translation))
        XCTAssertEqual(state.release(keyCode: option, time: 1), .stop(1))
        XCTAssertEqual(press(&state, option, enabled: false, primary: option, time: 2), .start(.normal))
    }

    func testOtherShortcutCannotStopOrChangeActiveHoldSession() {
        var state = DictationShortcutState()
        XCTAssertEqual(press(&state, command, time: 1), .start(.normal))
        XCTAssertFalse(state.canHandle(keyCode: option, primaryKeyCode: command, translationEnabled: true))
        XCTAssertNil(press(&state, option, time: 1.2))
        XCTAssertNil(state.release(keyCode: option, time: 1.4))
        XCTAssertTrue(state.isRecording)
        XCTAssertEqual(state.release(keyCode: command, time: 2), .stop(1))
        XCTAssertEqual(press(&state, option, time: 3), .start(.translation))
        XCTAssertNil(press(&state, command, time: 3.1))
        XCTAssertNil(state.release(keyCode: command, time: 3.2))
        XCTAssertEqual(state.release(keyCode: option, time: 4), .stop(1))
    }

    func testToggleSessionCanOnlyBeStoppedByItsOwnShortcut() {
        var state = DictationShortcutState()
        XCTAssertEqual(press(&state, option, mode: "toggle", time: 1), .start(.translation))
        XCTAssertNil(state.release(keyCode: option, time: 1.1))
        XCTAssertNil(press(&state, command, mode: "toggle", time: 2))
        XCTAssertNil(state.release(keyCode: command, time: 2.1))
        XCTAssertTrue(state.isRecording)
        XCTAssertEqual(press(&state, option, mode: "toggle", time: 3), .stop(2))
        XCTAssertNil(state.release(keyCode: option, time: 3.1))
        XCTAssertEqual(press(&state, command, mode: "toggle", time: 4), .start(.normal))
    }

    func testSmartTapKeepsRecordingUntilSameShortcutPressedAgain() {
        var state = DictationShortcutState()
        XCTAssertEqual(press(&state, command, mode: "smart", time: 1), .start(.normal))
        XCTAssertNil(state.release(keyCode: command, time: 1.1))
        XCTAssertTrue(state.inToggleMode)
        XCTAssertNil(press(&state, option, mode: "smart", time: 2))
        XCTAssertEqual(press(&state, command, mode: "smart", time: 4), .stop(3))
        XCTAssertNil(state.release(keyCode: command, time: 4.1))
    }

    func testSmartLongPressStopsOnRelease() {
        var state = DictationShortcutState()
        XCTAssertEqual(press(&state, option, mode: "smart", time: 1), .start(.translation))
        XCTAssertEqual(state.release(keyCode: option, time: 2), .stop(1))
        XCTAssertFalse(state.inToggleMode)
    }

    func testModeAndKeyRemainStableIfSettingsChangeDuringRecording() {
        var state = DictationShortcutState()
        XCTAssertEqual(press(&state, option, mode: "toggle", time: 1), .start(.translation))
        XCTAssertNil(state.release(keyCode: option, time: 1.1))
        XCTAssertTrue(state.canHandle(keyCode: option, primaryKeyCode: 62, translationEnabled: false))
        XCTAssertEqual(press(&state, option, mode: "hold", enabled: false, primary: 62, time: 3), .stop(2))
        XCTAssertNil(state.release(keyCode: option, time: 3.1))
        XCTAssertEqual(press(&state, 62, enabled: false, primary: 62, time: 4), .start(.normal))
    }

    func testCancelIgnoresLateReleaseAndNextSessionStartsCleanly() {
        var state = DictationShortcutState()
        XCTAssertEqual(press(&state, option, time: 1), .start(.translation))
        XCTAssertEqual(state.cancel(), .cancel)
        XCTAssertNil(state.release(keyCode: option, time: 2))
        XCTAssertNil(state.cancel())
        XCTAssertEqual(press(&state, command, time: 3), .start(.normal))
    }

    func testRepeatedKeyDownDoesNotStartTwice() {
        var state = DictationShortcutState()
        XCTAssertEqual(press(&state, command, time: 1), .start(.normal))
        XCTAssertNil(press(&state, command, time: 1.1))
        XCTAssertEqual(state.release(keyCode: command, time: 2), .stop(1))
        XCTAssertNil(state.release(keyCode: command, time: 2.1))
    }

    func testNormalSessionNeverInheritsTranslationFlag() {
        var config = AppConfig.defaultConfig
        config.enable_translation = true
        config.translation_target_language = "en"
        let normal = AppDelegate.dictationConfig(config, shortcutKind: .normal)
        let translated = AppDelegate.dictationConfig(config, shortcutKind: .translation)
        XCTAssertTrue(config.enable_translation)
        XCTAssertFalse(normal.enable_translation)
        XCTAssertTrue(translated.enable_translation)
        XCTAssertEqual(translated.translation_target_language, "en")
        config.enable_translation = false
        XCTAssertFalse(AppDelegate.dictationConfig(config, shortcutKind: .translation).enable_translation)
    }
}
