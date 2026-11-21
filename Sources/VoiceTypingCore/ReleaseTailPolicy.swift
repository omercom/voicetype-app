import Foundation

/// Tuş bırakıldıktan sonra son kelimenin/nefesin kesilmemesi için uyarlanabilir
/// kuyruk penceresini yönetir (Hex `POST_RELEASE_TAIL` / `MAX_RELEASE_TAIL` yaklaşımı).
struct ReleaseTailPolicy: Equatable {
    enum Decision: Equatable {
        case wait(TimeInterval)
        case finish
    }

    let baseTail: TimeInterval
    let maxTail: TimeInterval
    let quietSettle: TimeInterval
    let pollInterval: TimeInterval

    private var hasSeenActiveSpeech = false
    private var quietSince: TimeInterval?

    init(
        baseTail: TimeInterval = 0.20,
        maxTail: TimeInterval = 0.60,
        quietSettle: TimeInterval = 0.14,
        pollInterval: TimeInterval = 0.035
    ) {
        self.baseTail = baseTail
        self.maxTail = max(baseTail, maxTail)
        self.quietSettle = quietSettle
        self.pollInterval = pollInterval
    }

    mutating func decision(elapsed: TimeInterval, isSpeaking: Bool) -> Decision {
        if isSpeaking {
            hasSeenActiveSpeech = true
            quietSince = nil
        } else if hasSeenActiveSpeech && quietSince == nil {
            quietSince = elapsed
        }

        if elapsed >= maxTail {
            return .finish
        }

        if elapsed < baseTail {
            return .wait(min(pollInterval, max(0.01, baseTail - elapsed)))
        }

        if !hasSeenActiveSpeech {
            return .finish
        }

        if !isSpeaking, let quietStart = quietSince, elapsed - quietStart >= quietSettle {
            return .finish
        }

        return .wait(min(pollInterval, max(0.01, maxTail - elapsed)))
    }
}
