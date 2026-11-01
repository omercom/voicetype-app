import Foundation

/// Replaces the current selection without touching the clipboard. A write is
/// never retried through another mechanism because its delivery may be delayed.
struct SelectedTextTransaction {
    enum Attempt: Equatable {
        case unsupported
        case finished(TextInjector.InjectionOutcome)
    }

    struct Environment {
        var supportsSelectedText: () -> Bool
        var targetChangedReason: () -> String?
        var snapshot: () -> TextInjector.FieldSnapshot
        var writeSelectedText: (String) -> Bool
        var autoSubmit: () -> Void
        var isCancelled: () -> Bool = { false }
        var now: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
        var wait: (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) }
        var readRange: (NSRange) -> String? = { _ in nil }
    }

    static func run(text: String, autoSubmit: Bool, environment env: Environment) -> Attempt {
        guard !env.isCancelled() else { return .finished(.cancelled) }
        guard env.supportsSelectedText() else { return .unsupported }
        guard !env.isCancelled() else { return .finished(.cancelled) }
        if let reason = env.targetChangedReason() { return .finished(.targetChanged(reason: reason)) }
        let before = env.snapshot()
        guard !env.isCancelled() else { return .finished(.cancelled) }
        if let reason = env.targetChangedReason() { return .finished(.targetChanged(reason: reason)) }
        guard !env.isCancelled() else { return .finished(.cancelled) }
        guard env.writeSelectedText(text) else {
            return .finished(.failed(reason: "Metin aktarımı doğrulanamadı; hedefi kontrol edin"))
        }

        guard before.isReadable else { return .finished(.unverifiable) }
        let deadline = env.now() + TextInjector.verificationTimeout(for: text, before: before)
        var result = TextInjector.InjectionOutcome.notInserted
        repeat {
            env.wait(0.05)
            guard !env.isCancelled() else { return .finished(.cancelled) }
            result = TextInjector.outcome(before: before, after: env.snapshot(), insertedText: text,
                                          readRange: env.readRange)
            if result == .verified { break }
        } while env.now() < deadline

        if result == .verified, autoSubmit, !env.isCancelled(),
           env.targetChangedReason() == nil, !env.isCancelled() {
            env.autoSubmit()
        }
        return .finished(result)
    }
}
