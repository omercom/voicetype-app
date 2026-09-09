import Foundation
import os

/// Mikrofon ses sinyalini Whisper ve deşifre modelleri için optimum seviyeye getiren
/// adaptif otomatik kazanç kontrolü (AGC), gürültü tabanı kilidi ve tanh yumuşak sınırlayıcı.
public final class MicrophoneBoostProcessor: @unchecked Sendable {
    public static let shared = MicrophoneBoostProcessor()

    public static let targetRMS: Float = 0.10
    public static let maximumGain: Float = 20.0
    public static let minimumGain: Float = 1.0
    public static let activationRMS: Float = 0.0015
    public static let peakCeiling: Float = 0.96

    private static let gainAttack: Float = 0.45
    private static let gainRelease: Float = 0.06
    private static let peakDecay: Float = 0.95
    private static let limiterKnee: Float = 0.80
    private static let limiterCeiling: Float = 0.98

    private let lock = NSLock()
    private var currentGain: Float = 1.0
    private var recentPeak: Float = 0.0

    public init() {}

    public func reset() {
        lock.lock()
        currentGain = 1.0
        recentPeak = 0.0
        lock.unlock()
    }

    /// [Float] normalize ses örneklerini ([-1.0, 1.0]) AGC ve soft-limiter ile işler
    public func process(samples: [Float], enabled: Bool = true) -> [Float] {
        guard !samples.isEmpty else { return [] }
        guard enabled else {
            reset()
            return samples
        }

        let inputRMS = Self.calculateRMS(samples)
        let inputPeak = samples.reduce(Float.zero) { max($0, abs($1)) }

        lock.lock()
        recentPeak = max(inputPeak, recentPeak * Self.peakDecay)

        // Sessizlik veya fısıltı altı dip gürültüde kazancı artırma (Oda hışırtısını pompalamayı önler)
        let gain: Float
        if inputRMS < Self.activationRMS {
            gain = currentGain
        } else {
            var desiredGain = min(
                max(Self.targetRMS / inputRMS, Self.minimumGain),
                Self.maximumGain
            )
            if recentPeak > 0 {
                desiredGain = min(desiredGain, Self.peakCeiling / recentPeak)
            }

            let smoothing = desiredGain > currentGain ? Self.gainAttack : Self.gainRelease
            currentGain += (desiredGain - currentGain) * smoothing

            // Ani ses patlamalarında tepe koruması anında devreye girer
            if inputPeak > 0 {
                currentGain = min(currentGain, Self.peakCeiling / inputPeak)
            }
            currentGain = min(max(currentGain, Self.minimumGain), Self.maximumGain)
            gain = currentGain
        }
        lock.unlock()

        guard gain > 1.001 else {
            return samples
        }

        // Tanh soft limiter ile kırpılmayı (clipping) önleyerek yükselt
        return samples.map { Self.softLimited($0 * gain) }
    }

    /// 16-bit PCM ham bayt verisini (Int16) AGC ve soft limiter ile işleyip tekrar Data olarak döner
    public func processPCM16Data(_ data: Data, enabled: Bool = true) -> Data {
        guard enabled, data.count >= 2 else { return data }

        let sampleCount = data.count / 2
        var floatSamples = [Float](repeating: 0, count: sampleCount)

        data.withUnsafeBytes { rawBuffer in
            guard let int16Pointer = rawBuffer.bindMemory(to: Int16.self).baseAddress else { return }
            for i in 0..<sampleCount {
                floatSamples[i] = Float(int16Pointer[i]) / 32768.0
            }
        }

        let boosted = process(samples: floatSamples, enabled: enabled)

        var outputData = Data(count: sampleCount * 2)
        outputData.withUnsafeMutableBytes { rawBuffer in
            guard let int16Pointer = rawBuffer.bindMemory(to: Int16.self).baseAddress else { return }
            for i in 0..<sampleCount {
                let clamped = max(-1.0, min(1.0, boosted[i]))
                int16Pointer[i] = Int16(clamped * 32767.0)
            }
        }

        return outputData
    }

    public static func softLimited(_ sample: Float) -> Float {
        let magnitude = abs(sample)
        guard magnitude > limiterKnee else { return sample }

        let normalizedExcess = (magnitude - limiterKnee) / (limiterCeiling - limiterKnee)
        let limitedMagnitude = limiterKnee + (limiterCeiling - limiterKnee) * tanh(normalizedExcess)
        return sample < 0 ? -limitedMagnitude : limitedMagnitude
    }

    public static func calculateRMS(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        let sumSquares = samples.reduce(Float.zero) { $0 + $1 * $1 }
        return sqrt(sumSquares / Float(samples.count))
    }
}
