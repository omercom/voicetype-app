import Foundation
import os

/// Tuş bırakıldığı andan metnin hedefe yapıştırılmasına kadar geçen süreyi
/// adım adım ölçer. `RecordingStartLatencyTrace`'in bitiş yolu karşılığıdır.
///
/// Kullanıcının "yavaş" diye hissettiği süre budur: post-roll bekleme, mikrofon
/// durdurma, sağlayıcı yanıtı, metin düzeltme ve yapıştırma. Her adım yalnızca
/// ilk kez işaretlenir; `finish` yalnızca bir kez log yazar.
final class RecordingStopLatencyTrace: @unchecked Sendable {
    enum Milestone: String, CaseIterable {
        case keyRelease
        case postRollFinished
        case recorderStopped
        case providerRequestSent
        case resultReceived
        case polished
        case injectionAttempted
        case injectionCompleted
    }

    private static let logger = Logger(
        subsystem: "com.antigravity.VoiceTyping",
        category: "Performance"
    )

    private let lock = NSLock()
    private let startedAt: TimeInterval
    private var provider: String
    private var model: String = ""
    private var providerLatency: Double?
    private var times: [Milestone: TimeInterval]
    private var hasLogged = false

    init(provider: String, now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        self.provider = provider
        self.startedAt = now
        self.times = [.keyRelease: now]
    }

    func mark(_ milestone: Milestone, now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        lock.lock()
        if times[milestone] == nil {
            times[milestone] = now
        }
        lock.unlock()
    }

    /// Sonuç geldiğinde gerçek sağlayıcı/modeli ve sağlayıcının kendi ölçtüğü
    /// süreyi kaydeder (fallback'te sağlayıcı değişmiş olabilir).
    func markResult(provider: String, model: String, providerLatency: Double,
                    now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        lock.lock()
        if times[.resultReceived] == nil {
            times[.resultReceived] = now
            self.provider = provider
            self.model = model
            self.providerLatency = providerLatency
        }
        lock.unlock()
    }

    /// Tuş bırakıldıktan sonra geçen süre (ms); adım işaretlenmediyse nil.
    func elapsedMs(_ milestone: Milestone) -> Int? {
        lock.lock()
        defer { lock.unlock() }
        guard let time = times[milestone] else { return nil }
        return Int(max(0, time - startedAt) * 1_000)
    }

    func summaryLine(reason: String) -> String {
        lock.lock()
        let snapshot = times
        let provider = self.provider
        let model = self.model
        let providerLatency = self.providerLatency
        lock.unlock()

        var parts = Milestone.allCases.dropFirst().compactMap { milestone -> String? in
            guard let time = snapshot[milestone] else { return nil }
            return "\(milestone.rawValue)=\(Int(max(0, time - startedAt) * 1_000))ms"
        }
        if let providerLatency {
            parts.append("providerLatency=\(Int(max(0, providerLatency) * 1_000))ms")
        }
        let modelPart = model.isEmpty ? "" : " model=\(model)"
        return "[StopLatency] provider=\(provider)\(modelPart) \(parts.joined(separator: " ")) end=\(reason)"
    }

    func finish(reason: String) {
        lock.lock()
        guard !hasLogged else {
            lock.unlock()
            return
        }
        hasLogged = true
        lock.unlock()

        let message = summaryLine(reason: reason)
        print(message)
        Self.logger.notice("\(message, privacy: .public)")
    }

    var isFinished: Bool {
        lock.lock()
        defer { lock.unlock() }
        return hasLogged
    }
}
