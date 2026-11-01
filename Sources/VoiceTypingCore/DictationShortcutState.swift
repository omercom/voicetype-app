import Foundation
import CoreGraphics

enum DictationShortcutEvent {
    case flagsChanged(CGEventFlags)
    case keyDown(isRepeat: Bool)
    case keyUp
}

struct DictationShortcutResult {
    let action: DictationShortcutAction?
    let consume: Bool
}

enum DictationShortcutKind: Equatable {
    case normal
    case translation
}

enum DictationShortcutAction: Equatable {
    case start(DictationShortcutKind)
    case stop(TimeInterval)
    case cancel
}

/// Tracks one active dictation so another shortcut cannot change or stop its session.
struct DictationShortcutState {
    static let translationKeyCode: Int64 = 61 // Right Option
    private(set) var pressedKeyCode: Int64?
    private(set) var activeKeyCode: Int64?
    private(set) var isRecording = false
    private(set) var inToggleMode = false
    private var activeKind: DictationShortcutKind?
    private var activeTriggerMode = "hold"
    private var pressStart: TimeInterval = 0
    private var recordingStart: TimeInterval = 0

    static func kind(for keyCode: Int64, primaryKeyCode: Int64, translationEnabled: Bool) -> DictationShortcutKind? {
        // If both bindings are the same, explicit translation takes precedence.
        if translationEnabled && keyCode == translationKeyCode { return .translation }
        if keyCode == primaryKeyCode { return .normal }
        return nil
    }

    func canHandle(keyCode: Int64, primaryKeyCode: Int64, translationEnabled: Bool) -> Bool {
        if let pressedKeyCode, pressedKeyCode != keyCode { return false }
        if let activeKeyCode, activeKeyCode != keyCode { return false }
        return keyCode == pressedKeyCode || keyCode == activeKeyCode ||
            Self.kind(for: keyCode, primaryKeyCode: primaryKeyCode, translationEnabled: translationEnabled) != nil
    }

    mutating func handle(
        keyCode: Int64,
        event: DictationShortcutEvent,
        primaryKeyCode: Int64,
        translationEnabled: Bool,
        triggerMode: String,
        time: TimeInterval
    ) -> DictationShortcutResult {
        // A modifier plus another key is an ordinary system shortcut, not dictation.
        if case .keyDown = event, let pressedKeyCode,
           KeyListener.isModifier(keyCode: pressedKeyCode), keyCode != pressedKeyCode {
            return DictationShortcutResult(action: cancel(), consume: false)
        }
        guard canHandle(keyCode: keyCode, primaryKeyCode: primaryKeyCode,
                        translationEnabled: translationEnabled) else {
            return DictationShortcutResult(action: nil, consume: false)
        }
        if KeyListener.isModifier(keyCode: keyCode) {
            guard case .flagsChanged(let flags) = event else {
                return DictationShortcutResult(action: nil, consume: false)
            }
            let wasPressed = pressedKeyCode == keyCode
            let isPressed = KeyListener.isModifierPressed(keyCode: keyCode, flags: flags, currentKeyDown: wasPressed)
            let action: DictationShortcutAction?
            if isPressed && !wasPressed {
                action = press(keyCode: keyCode, primaryKeyCode: primaryKeyCode,
                               translationEnabled: translationEnabled, triggerMode: triggerMode, time: time)
            } else if !isPressed && wasPressed {
                action = release(keyCode: keyCode, time: time)
            } else {
                action = nil
            }
            return DictationShortcutResult(action: action, consume: false)
        }
        switch event {
        case .keyDown(let isRepeat):
            let action = isRepeat ? nil : press(keyCode: keyCode, primaryKeyCode: primaryKeyCode,
                                                translationEnabled: translationEnabled,
                                                triggerMode: triggerMode, time: time)
            return DictationShortcutResult(action: action, consume: true)
        case .keyUp:
            return DictationShortcutResult(action: release(keyCode: keyCode, time: time), consume: true)
        case .flagsChanged:
            return DictationShortcutResult(action: nil, consume: false)
        }
    }

    mutating func press(
        keyCode: Int64,
        primaryKeyCode: Int64,
        translationEnabled: Bool,
        triggerMode: String,
        time: TimeInterval
    ) -> DictationShortcutAction? {
        guard pressedKeyCode == nil,
              canHandle(keyCode: keyCode, primaryKeyCode: primaryKeyCode, translationEnabled: translationEnabled),
              let kind = activeKind ?? Self.kind(for: keyCode, primaryKeyCode: primaryKeyCode,
                                               translationEnabled: translationEnabled) else { return nil }
        pressedKeyCode = keyCode
        pressStart = time

        if isRecording {
            if activeTriggerMode == "toggle" || (activeTriggerMode == "smart" && inToggleMode) {
                let duration = max(0, time - recordingStart)
                isRecording = false
                inToggleMode = false
                activeKeyCode = nil
                activeKind = nil
                return .stop(duration)
            }
            return nil
        }

        activeKeyCode = keyCode
        activeKind = kind
        activeTriggerMode = triggerMode.lowercased()
        recordingStart = time
        isRecording = true
        inToggleMode = false
        return .start(kind)
    }

    mutating func release(keyCode: Int64, time: TimeInterval) -> DictationShortcutAction? {
        guard pressedKeyCode == keyCode else { return nil }
        pressedKeyCode = nil
        guard isRecording else { return nil }
        if activeTriggerMode == "toggle" { return nil }
        if activeTriggerMode == "smart" && time - pressStart < 0.25 {
            inToggleMode = true
            return nil
        }
        let duration = max(0, time - recordingStart)
        isRecording = false
        inToggleMode = false
        activeKeyCode = nil
        activeKind = nil
        return .stop(duration)
    }

    mutating func cancel() -> DictationShortcutAction? {
        let wasRecording = isRecording
        self = DictationShortcutState()
        return wasRecording ? .cancel : nil
    }
}
