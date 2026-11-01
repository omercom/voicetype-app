import AppKit

/// External automation may start dictation only in the application selected by the caller.
enum AutomationStartDecision: String {
    case ready
    case busy
    case missingTarget = "missing-target"
    case targetChanged = "target-changed"
    case unsupportedTarget = "unsupported-target"

    static func resolve(expected: String?, frontmost: String?, ownBundle: String?, busy: Bool) -> Self {
        if busy { return .busy }
        guard let expected = expected?.trimmingCharacters(in: .whitespacesAndNewlines), !expected.isEmpty else {
            return .missingTarget
        }
        let excluded = [ownBundle, "com.raycast.macos", "com.apple.dock", "com.apple.controlcenter", "com.apple.notificationcenterui"]
        guard !excluded.compactMap({ $0 }).contains(expected) else { return .unsupportedTarget }
        guard expected == frontmost else { return .targetChanged }
        return .ready
    }

    static func acceptsCapture(
        expected: String?, frontmostBundle: String?, frontmostPID: pid_t?,
        capturedBundle: String?, capturedPID: pid_t?
    ) -> Bool {
        guard let expected else { return true }
        guard let frontmostPID, let capturedPID else { return false }
        return expected == frontmostBundle && expected == capturedBundle && frontmostPID == capturedPID
    }
}

@objc(VoiceTypeStartDictationCommand)
public final class VoiceTypeStartDictationCommand: NSScriptCommand {
    public override func performDefaultImplementation() -> Any? {
        guard Thread.isMainThread, let delegate = NSApp.delegate as? AppDelegate else { return "unavailable" }
        return delegate.startAutomationDictation(expectedBundleIdentifier: directParameter as? String)
    }
}

@objc(VoiceTypeStopDictationCommand)
public final class VoiceTypeStopDictationCommand: NSScriptCommand {
    public override func performDefaultImplementation() -> Any? {
        guard Thread.isMainThread, let delegate = NSApp.delegate as? AppDelegate else { return "unavailable" }
        return delegate.stopAutomationDictation()
    }
}

@objc(VoiceTypeOpenSettingsCommand)
public final class VoiceTypeOpenSettingsCommand: NSScriptCommand {
    public override func performDefaultImplementation() -> Any? {
        guard Thread.isMainThread, let delegate = NSApp.delegate as? AppDelegate else { return "unavailable" }
        delegate.openAutomationSettings()
        return "opened"
    }
}

@objc(VoiceTypeAutomationStatusCommand)
public final class VoiceTypeAutomationStatusCommand: NSScriptCommand {
    public override func performDefaultImplementation() -> Any? {
        guard Thread.isMainThread, NSApp.delegate is AppDelegate else { return "unavailable" }
        return "ready"
    }
}
