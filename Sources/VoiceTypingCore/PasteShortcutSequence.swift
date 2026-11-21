import Foundation

/// Sends one shortcut to the already-validated target. After V is sent, both
/// keys must be released even if cancellation or focus changes in the meantime.
struct PasteShortcutSequence {
    enum Event: Equatable {
        case commandDown
        case pasteDown
        case pasteUp
        case commandUp
    }

    static func run(
        isSafe: () -> Bool,
        post: (Event) -> Void,
        wait: (TimeInterval) -> Void
    ) -> Bool {
        guard isSafe() else { return false }
        post(.commandDown)
        wait(0.01)

        guard isSafe() else {
            post(.commandUp)
            return false
        }

        post(.pasteDown)
        wait(0.025)
        post(.pasteUp)
        wait(0.01)
        post(.commandUp)
        return true
    }
}
