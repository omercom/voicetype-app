import Foundation

/// Runs on TextInjector's serial queue. No callback may enqueue a later clipboard
/// write: the next transaction must not start until this one releases ownership.
struct ClipboardPasteTransaction {
    struct Environment {
        var prepare: () -> Bool
        var preparationFailureReason: () -> String = { "Metin panoya yazılamadı" }
        var ownsClipboard: () -> Bool
        var targetChangedReason: () -> String?
        var snapshot: () -> TextInjector.FieldSnapshot
        var sendPaste: () -> Bool
        var restore: () -> Void
        var autoSubmit: () -> Void
        var rollbackBeforeSending: () -> Void = {}
        var isCancelled: () -> Bool = { false }
        var now: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
        var wait: (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) }
        var readRange: (NSRange) -> String? = { _ in nil }
    }

    static func run(
        text: String,
        pasteDelay: TimeInterval,
        restoreClipboard: Bool,
        autoSubmit: Bool,
        environment env: Environment,
        onAttempted: () -> Void = {}
    ) -> TextInjector.InjectionOutcome {
        guard !env.isCancelled() else { return .cancelled }
        guard env.prepare() else {
            return env.isCancelled() ? .cancelled : .failed(reason: env.preparationFailureReason())
        }
        func cancelBeforeSending() -> TextInjector.InjectionOutcome {
            if restoreClipboard, env.ownsClipboard() { env.rollbackBeforeSending() }
            return .cancelled
        }
        var remainingDelay = pasteDelay > 0 ? min(pasteDelay, 2) : 0
        while remainingDelay > 0 {
            let interval = min(remainingDelay, 0.05)
            env.wait(interval)
            remainingDelay -= interval
            guard !env.isCancelled() else { return cancelBeforeSending() }
        }
        guard !env.isCancelled() else { return cancelBeforeSending() }
        guard env.ownsClipboard() else { return .failed(reason: "Pano başka bir işlem tarafından değiştirildi") }
        if let reason = env.targetChangedReason() {
            if env.isCancelled() { return cancelBeforeSending() }
            return env.ownsClipboard() ? .targetChanged(reason: reason)
                : .failed(reason: "Pano başka bir işlem tarafından değiştirildi")
        }
        let before = env.snapshot()
        guard !env.isCancelled() else { return cancelBeforeSending() }
        guard env.ownsClipboard() else { return .failed(reason: "Pano başka bir işlem tarafından değiştirildi") }
        // AX snapshot reads may block long enough for the user to change focus.
        if let reason = env.targetChangedReason() {
            if env.isCancelled() { return cancelBeforeSending() }
            return env.ownsClipboard() ? .targetChanged(reason: reason)
                : .failed(reason: "Pano başka bir işlem tarafından değiştirildi")
        }
        guard !env.isCancelled() else { return cancelBeforeSending() }
        guard env.ownsClipboard() else { return .failed(reason: "Pano başka bir işlem tarafından değiştirildi") }
        guard env.sendPaste() else { return .failed(reason: "Yapıştırma tuşu gönderilemedi") }
        onAttempted()

        // An unreadable editor gives no delivery acknowledgement. Keep the text
        // available indefinitely rather than restoring the clipboard after 500ms.
        // Also hold the queue for the observation window, so a following paste
        // cannot immediately replace text that a slow editor has not read yet.
        let deadline = env.now() + TextInjector.verificationTimeout(for: text, before: before)
        var result: TextInjector.InjectionOutcome = before.isReadable ? .notInserted : .unverifiable
        repeat {
            env.wait(0.05)
            if env.isCancelled() { return .cancelled }
            if before.isReadable {
                result = TextInjector.outcome(before: before, after: env.snapshot(), insertedText: text,
                                              readRange: env.readRange)
            }
            if result == .verified { break }
        } while env.now() < deadline

        // Never retry Cmd+V: delayed updates must not produce duplicate text.
        guard !env.isCancelled() else { return .cancelled }
        guard result == .verified else {
            if env.ownsClipboard() { return result }
            if result == .unverifiable { return .unverifiableClipboardChanged }
            return .failed(reason: "Aktarım doğrulanamadı; pano başka bir işlem tarafından değiştirildi")
        }
        if restoreClipboard, env.ownsClipboard() { env.restore() }
        if autoSubmit, !env.isCancelled(), env.targetChangedReason() == nil, !env.isCancelled() { env.autoSubmit() }
        return .verified
    }
}
