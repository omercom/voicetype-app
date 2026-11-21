import Foundation

/// Dikte sonrası mikrofon donanımını kısa süre sıcak tutma (Hex `MicrophoneLinger` deseni).
/// Bluetooth kulaklıklarda A2DP stereo profilini korumak için linger devre dışı kalır.
struct MicrophoneLingerPolicy: Equatable {
    var lingerSeconds: TimeInterval
    private(set) var deadline: TimeInterval?

    init(lingerSeconds: TimeInterval = 20.0) {
        self.lingerSeconds = max(0, lingerSeconds)
    }

    mutating func markCaptureStarted() {
        deadline = nil
    }

    /// Kayıt bitişinde linger penceresini hesaplar; hemen kapanmalıysa `nil` döner.
    @discardableResult
    mutating func markCaptureEnded(at now: TimeInterval, isBluetoothRoute: Bool) -> TimeInterval? {
        guard lingerSeconds > 0, !isBluetoothRoute else {
            deadline = nil
            return nil
        }
        deadline = now + lingerSeconds
        return lingerSeconds
    }

    mutating func shouldClose(at now: TimeInterval, isRecording: Bool) -> Bool {
        guard !isRecording else { return false }
        guard let activeDeadline = deadline else { return true }
        if now >= activeDeadline {
            deadline = nil
            return true
        }
        return false
    }

    mutating func clear() {
        deadline = nil
    }
}

/// Uyku/uyanma veya rota değişimi sonrası CoreAudio'nun kesintisiz ama
/// tamamen sıfır (`0.0`) örnek gönderdiği "ölü mikrofon" durumunu yakalar.
struct DigitalSilenceDetector: Equatable {
    let thresholdSeconds: TimeInterval
    let maxRecoveriesPerSession: Int

    private(set) var zeroDuration: TimeInterval = 0
    private(set) var recoveryCount: Int = 0

    init(thresholdSeconds: TimeInterval = 1.8, maxRecoveriesPerSession: Int = 1) {
        self.thresholdSeconds = max(0.2, thresholdSeconds)
        self.maxRecoveriesPerSession = max(0, maxRecoveriesPerSession)
    }

    mutating func reset() {
        zeroDuration = 0
        recoveryCount = 0
    }

    /// Tam sıfır örnek süresi eşiği aştığında kurtarma için bir kez `true` döner.
    mutating func observe(bufferDuration: TimeInterval, maxAbsSample: Float) -> Bool {
        if maxAbsSample > 0 {
            zeroDuration = 0
            return false
        }
        guard bufferDuration > 0, recoveryCount < maxRecoveriesPerSession else {
            return false
        }
        zeroDuration += bufferDuration
        if zeroDuration >= thresholdSeconds {
            recoveryCount += 1
            zeroDuration = 0
            return true
        }
        return false
    }
}

/// Gerçek zamanlı ses thread'inde bloklamadan/log spamlamadan aşırı yük (overload)
/// olaylarını biriktirip belirli aralıkla tek satırda raporlar.
struct AudioOverloadTracker: Equatable {
    let minReportInterval: TimeInterval
    private(set) var pendingCount: Int = 0
    private(set) var lastReportedAt: TimeInterval?

    init(minReportInterval: TimeInterval = 10.0) {
        self.minReportInterval = max(0.1, minReportInterval)
    }

    mutating func record(at now: TimeInterval) -> Int? {
        pendingCount += 1
        if let last = lastReportedAt, now - last < minReportInterval {
            return nil
        }
        let burst = pendingCount
        pendingCount = 0
        lastReportedAt = now
        return burst
    }

    mutating func flush() -> Int {
        let remaining = pendingCount
        pendingCount = 0
        return remaining
    }
}
