import Foundation
import OSLog

final class RecordingStartCoordinator {
    enum Phase: Equatable {
        case idle
        case preparing(UInt64)
        case starting(UInt64)
        case recording(UInt64)
    }

    enum Outcome: Equatable {
        case ignored
        case targetRejected(UInt64)
        case recorderFailed(UInt64)
        case started(UInt64)
    }

    private(set) var phase: Phase = .idle
    private(set) var attemptCount: UInt64 = 0

    @discardableResult
    func start(
        prepare: (UInt64) -> Void,
        captureTarget: () -> Bool,
        startRecorder: () -> Bool
    ) -> Outcome {
        guard phase == .idle else { return .ignored }

        attemptCount &+= 1
        let attempt = attemptCount
        phase = .preparing(attempt)
        prepare(attempt)

        guard captureTarget() else {
            phase = .idle
            return .targetRejected(attempt)
        }

        phase = .starting(attempt)
        guard startRecorder() else {
            phase = .idle
            return .recorderFailed(attempt)
        }

        phase = .recording(attempt)
        return .started(attempt)
    }

    func finish() {
        phase = .idle
    }
}

struct HUDRevealTiming: Equatable {
    let duration: TimeInterval
    let initialAlpha: Double

    static func resolve(isAlreadyVisible: Bool, currentAlpha: Double, reduceMotion: Bool) -> HUDRevealTiming {
        if reduceMotion {
            return HUDRevealTiming(duration: 0, initialAlpha: 1)
        }
        if isAlreadyVisible {
            return HUDRevealTiming(duration: 0.07, initialAlpha: max(0, currentAlpha))
        }
        return HUDRevealTiming(duration: 0.07, initialAlpha: max(0.28, currentAlpha))
    }
}

final class RecordingStartLatencyTrace: @unchecked Sendable {
    enum Milestone: String, CaseIterable {
        case keyEntry
        case mainHandlerEntry
        case preparingPresented
        case hudRunLoopYield
        case preflightCompleted
        case targetCaptureStarted
        case targetCaptured
        case speechSessionStarted
        case recorderStartEntered
        case recorderStarted
        case firstAudioCallback
        case firstProviderAudio
        case firstInterim
    }

    private static let logger = Logger(
        subsystem: "com.antigravity.VoiceTyping",
        category: "Performance"
    )

    private let lock = NSLock()
    private let provider: String
    private let model: String
    private let startedAt: TimeInterval
    private var times: [Milestone: TimeInterval]
    private var hasLogged = false

    init(provider: String, model: String, now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        self.provider = provider
        self.model = model
        self.startedAt = now
        self.times = [.keyEntry: now]
    }

    func mark(_ milestone: Milestone, now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        lock.lock()
        if times[milestone] == nil {
            times[milestone] = now
        }
        lock.unlock()
    }

    func finish(reason: String) {
        lock.lock()
        guard !hasLogged else {
            lock.unlock()
            return
        }
        hasLogged = true
        let snapshot = times
        lock.unlock()

        let values = Milestone.allCases.compactMap { milestone -> String? in
            guard let time = snapshot[milestone] else { return nil }
            return "\(milestone.rawValue)=\(Int(max(0, time - startedAt) * 1_000))ms"
        }.joined(separator: " ")
        let message = "[RecordLatency] provider=\(provider) model=\(model) \(values) end=\(reason)"
        print(message)
        Self.logger.notice("\(message, privacy: .public)")
    }
}
