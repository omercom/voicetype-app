import Foundation

/// Restores only a captured target. Keyboard delivery starts separately, after
/// the application, window and field have all been verified again.
struct TargetFocusRecovery {
    enum Outcome: Equatable {
        case ready
        case unavailable
        case cancelled
    }

    struct Environment {
        var processIsValid: () -> Bool
        var targetIsAvailable: () -> Bool
        var targetIsFocused: () -> Bool
        var applicationIsFocused: () -> Bool
        var activateApplication: () -> Bool
        var windowIsFocused: () -> Bool
        var raiseWindow: () -> Void
        var focusField: () -> Bool
        var isCancelled: () -> Bool
        var now: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
        var wait: (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) }
    }

    static func run(_ env: Environment) -> Outcome {
        guard !env.isCancelled() else { return .cancelled }
        guard env.processIsValid() else { return .unavailable }
        if env.targetIsFocused() { return env.isCancelled() ? .cancelled : .ready }
        guard !env.isCancelled() else { return .cancelled }

        if !env.applicationIsFocused() {
            guard !env.isCancelled() else { return .cancelled }
            guard env.activateApplication() else { return .unavailable }
            let activation = waitUntil(env, condition: env.applicationIsFocused)
            guard activation == .ready else { return activation }
        }
        guard !env.isCancelled() else { return .cancelled }
        guard env.processIsValid() else { return .unavailable }

        if !env.windowIsFocused() {
            guard !env.isCancelled() else { return .cancelled }
            env.raiseWindow()
            let window = waitUntil(env, condition: env.windowIsFocused)
            guard window == .ready else { return window }
        }
        guard !env.isCancelled() else { return .cancelled }
        guard env.targetIsAvailable(), env.applicationIsFocused(), env.windowIsFocused() else { return .unavailable }
        guard !env.isCancelled() else { return .cancelled }
        guard env.focusField() else { return .unavailable }

        let focus = waitUntil(env, condition: env.targetIsFocused)
        guard focus == .ready else { return focus }
        guard !env.isCancelled() else { return .cancelled }
        guard env.targetIsAvailable(), env.targetIsFocused() else { return .unavailable }
        return env.isCancelled() ? .cancelled : .ready
    }

    private static func waitUntil(_ env: Environment, condition: () -> Bool) -> Outcome {
        let deadline = env.now() + 0.8
        while true {
            if env.isCancelled() { return .cancelled }
            if condition() { return env.isCancelled() ? .cancelled : .ready }
            if env.now() >= deadline { return .unavailable }
            env.wait(0.02)
        }
    }
}
