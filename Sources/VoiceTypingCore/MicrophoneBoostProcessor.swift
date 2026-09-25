import Foundation

/// Mikrofon ses sinyalini Whisper ve deşifre modelleri için optimum seviyeye getiren
/// adaptif otomatik kazanç kontrolü (AGC), gürültü tabanı tahmini ve yumuşak sınırlayıcı.
public final class MicrophoneBoostProcessor: @unchecked Sendable {
    public static let shared = MicrophoneBoostProcessor()

    public static let targetRMS: Float = 0.10
    /// Kaynak uyumluluğu için korunur. 20x doğrusal kazanç yaklaşık +26 dB'dir;
    /// üretim yolu ayrıca daha düşük bir doğrulanmış-konuşma tavanı uygular.
    public static let maximumGain: Float = 20.0
    public static let minimumGain: Float = 1.0
    public static let activationRMS: Float = 0.0015
    public static let peakCeiling: Float = 0.96

    private static let sampleRate = 16_000
    private static let analysisFrameSamples = 320 // 20 ms @ 16 kHz
    private static let startupObservationSamples = 3_200 // 200 ms; örnekler bit-exact unity geçer
    private static let noiseWindowFrames = 25 // Sabit 500 ms pencere
    private static let envelopeWindowFrames = 16 // Sabit 320 ms zamansal modülasyon penceresi
    private static let speechEntryFrames = 3 // Modülasyon doğrulandıktan sonra 60 ms
    private static let speechExitFrames = 12 // 240 ms
    private static let confirmedSpeechMaximumGain: Float = 8.0 // Yaklaşık +18 dB
    private static let boostedNoiseCeilingRMS: Float = 0.008
    private static let minimumNoiseFloor: Float = 0.00020
    private static let initialNoiseFloor: Float = 0.00050
    private static let maximumNoiseObservationRMS: Float = 0.025
    private static let speechEntrySNR: Float = 1.4
    private static let speechExitSNR: Float = 1.30
    private static let minimumDifferenceRatio: Float = 0.065
    private static let minimumEnvelopeModulationDepth: Float = 0.20
    private static let significantEnvelopeChange: Float = 0.025
    private static let minimumEnvelopeChanges = 4
    private static let maximumEnvelopeRoughness: Float = 1.20
    private static let impulseCrestFactor: Float = 4.5
    private static let gainAttackTime: Float = 0.20
    private static let gainReleaseTime: Float = 0.45
    private static let silenceGainReleaseTime: Float = 0.18
    private static let limiterKnee: Float = 0.80
    private static let limiterCeiling: Float = 0.98

    private let lock = NSLock()

    // Sabit süreli analiz akümülatörleri; callback sınırlarından bağımsızdır.
    private var frameSampleCount = 0
    private var frameSumSquares: Float = 0
    private var frameDifferenceSquares: Float = 0
    private var framePeak: Float = 0
    private var previousSample: Float = 0
    private var hasPreviousSample = false
    private var processedSampleCount = 0

    // Sabit boyutlu gürültü gözlem halkası; çalışma sırasında büyümez.
    private var noiseObservations = [Float](repeating: 0, count: MicrophoneBoostProcessor.noiseWindowFrames)
    private var noiseObservationCount = 0
    private var noiseObservationIndex = 0
    private var noiseFloorRMS: Float = MicrophoneBoostProcessor.initialNoiseFloor
    private var envelopeObservations = [Float](repeating: 0, count: MicrophoneBoostProcessor.envelopeWindowFrames)
    private var envelopeObservationCount = 0
    private var envelopeObservationIndex = 0

    private var speechCandidateFrameCount = 0
    private var speechExitFrameCount = 0
    private var speechActive = false
    private var currentGain: Float = 1.0
    private var targetGain: Float = 1.0
    private var activeGainCeiling: Float = 1.0

    public init() {}

    public func reset() {
        lock.lock()
        resetLocked()
        lock.unlock()
    }

    private func resetLocked() {
        frameSampleCount = 0
        frameSumSquares = 0
        frameDifferenceSquares = 0
        framePeak = 0
        previousSample = 0
        hasPreviousSample = false
        processedSampleCount = 0
        noiseObservations = [Float](repeating: 0, count: Self.noiseWindowFrames)
        noiseObservationCount = 0
        noiseObservationIndex = 0
        noiseFloorRMS = Self.initialNoiseFloor
        envelopeObservations = [Float](repeating: 0, count: Self.envelopeWindowFrames)
        envelopeObservationCount = 0
        envelopeObservationIndex = 0
        speechCandidateFrameCount = 0
        speechExitFrameCount = 0
        speechActive = false
        currentGain = 1.0
        targetGain = 1.0
        activeGainCeiling = 1.0
    }

    /// [Float] normalize ses örneklerini ([-1.0, 1.0]) AGC ve soft-limiter ile işler.
    /// Public API örnekleme hızı taşımadığı için bu yol, kayıt PCM yolu gibi 16 kHz kabul edilir.
    public func process(samples: [Float], enabled: Bool = true) -> [Float] {
        guard !samples.isEmpty else { return [] }
        guard enabled else {
            reset()
            return samples
        }

        lock.lock()
        defer { lock.unlock() }

        var output = [Float](repeating: 0, count: samples.count)
        for index in samples.indices {
            output[index] = processSampleLocked(samples[index])
        }
        return output
    }

    private static let attackStep = smoothingFactor(samples: 1, timeConstant: gainAttackTime)
    private static let releaseStep = smoothingFactor(samples: 1, timeConstant: gainReleaseTime)
    private static let silenceReleaseStep = smoothingFactor(samples: 1, timeConstant: silenceGainReleaseTime)

    private static func smoothingFactor(samples: Int, timeConstant: Float) -> Float {
        guard samples > 0 else { return 0 }
        let duration = Float(samples) / Float(sampleRate)
        return 1.0 - exp(-duration / timeConstant)
    }

    private func processSampleLocked(_ input: Float) -> Float {
        updateInterpolatedGainLocked()

        var output = input
        let magnitude = abs(input)
        if currentGain > 1.001 {
            var appliedGain = min(currentGain, activeGainCeiling)
            if magnitude > 0 {
                appliedGain = min(appliedGain, max(Self.minimumGain, Self.peakCeiling / magnitude))
            }
            output = Self.softLimited(input * appliedGain)
        }

        accumulateAnalysisLocked(input)
        return output
    }

    private func updateInterpolatedGainLocked() {
        let smoothing: Float
        if targetGain > currentGain {
            smoothing = Self.attackStep
        } else if targetGain <= Self.minimumGain && !speechActive {
            smoothing = Self.silenceReleaseStep
        } else {
            smoothing = Self.releaseStep
        }

        currentGain += (targetGain - currentGain) * smoothing
        currentGain = min(max(currentGain, Self.minimumGain), activeGainCeiling)
        if targetGain == Self.minimumGain && abs(currentGain - Self.minimumGain) < 0.001 {
            currentGain = Self.minimumGain
        }
    }

    private func accumulateAnalysisLocked(_ sample: Float) {
        frameSumSquares += sample * sample
        framePeak = max(framePeak, abs(sample))
        if hasPreviousSample {
            let difference = sample - previousSample
            frameDifferenceSquares += difference * difference
        } else {
            hasPreviousSample = true
        }
        previousSample = sample
        frameSampleCount += 1
        processedSampleCount += 1

        guard frameSampleCount == Self.analysisFrameSamples else { return }
        analyzeCompletedFrameLocked()
        frameSampleCount = 0
        frameSumSquares = 0
        frameDifferenceSquares = 0
        framePeak = 0
    }

    private func analyzeCompletedFrameLocked() {
        let count = Float(Self.analysisFrameSamples)
        let rms = sqrt(frameSumSquares / count)
        let differenceRMS = sqrt(frameDifferenceSquares / max(1, count - 1))
        let differenceRatio = differenceRMS / max(rms, Self.minimumNoiseFloor)
        let crestFactor = framePeak / max(rms, Self.minimumNoiseFloor)
        let isImpulse = crestFactor >= Self.impulseCrestFactor

        let hasSpeechLikeStructure = !isImpulse
            && rms >= Self.activationRMS
            && differenceRatio >= Self.minimumDifferenceRatio
        addEnvelopeObservationLocked(rms)
        let hasPersistentEnvelopeModulation = envelopeHasPersistentModulationLocked()
        let entryFloor = max(Self.activationRMS, noiseFloorRMS * Self.speechEntrySNR)
        let hasPersistentSpeechPattern = hasSpeechLikeStructure && hasPersistentEnvelopeModulation
        let isSpeechCandidate = hasPersistentSpeechPattern && rms >= entryFloor

        if speechActive {
            let exitFloor = max(Self.activationRMS * 0.8, noiseFloorRMS * Self.speechExitSNR)
            if !isImpulse && rms >= exitFloor {
                speechExitFrameCount = 0
            } else {
                speechExitFrameCount += 1
                if speechExitFrameCount >= Self.speechExitFrames {
                    speechActive = false
                    speechExitFrameCount = 0
                }
            }
        } else if isSpeechCandidate {
            speechCandidateFrameCount += 1
            if speechCandidateFrameCount >= Self.speechEntryFrames {
                speechActive = true
                speechCandidateFrameCount = 0
                speechExitFrameCount = 0
            }
        } else {
            speechCandidateFrameCount = 0
        }

        let isStartupObservation = processedSampleCount <= Self.startupObservationSamples
        if isStartupObservation {
            // İlk 200 ms'de frekans içeriğinden bağımsız olarak her kalıcı,
            // darbe olmayan çerçeveyi öğren. Çıkış bu sırada her zaman unity'dir.
            if !isImpulse && rms <= Self.maximumNoiseObservationRMS {
                addNoiseObservationLocked(max(rms, Self.minimumNoiseFloor))
            }
        } else if !speechActive && speechCandidateFrameCount == 0 && !hasPersistentSpeechPattern && !isImpulse && rms <= Self.maximumNoiseObservationRMS {
            // Yapısal ama konuşma olarak doğrulanmamış ton/gürültü yeni bir
            // platoya yalnızca yukarı yönde uyum sağlayabilir; mevcut güvenlik
            // sınırını aşağı çekemez. Yapısız sessizlik aşağı rebasing yapabilir.
            if !hasSpeechLikeStructure || rms >= noiseFloorRMS {
                addNoiseObservationLocked(max(rms, Self.minimumNoiseFloor))
            }
        }

        let noiseLimit = Self.boostedNoiseCeilingRMS / max(noiseFloorRMS, Self.minimumNoiseFloor)
        activeGainCeiling = min(
            Self.confirmedSpeechMaximumGain,
            max(Self.minimumGain, noiseLimit)
        )
        currentGain = min(currentGain, activeGainCeiling)

        guard processedSampleCount >= Self.startupObservationSamples, speechActive else {
            targetGain = Self.minimumGain
            return
        }

        // Konuşma içindeki kısa boşluklarda yüksek hedef kazanç üretme; çıkış
        // histerezisi sürerken kazanç sessizce unity'ye döner.
        let usableSpeechFloor = max(Self.activationRMS, noiseFloorRMS * 1.10)
        guard rms >= usableSpeechFloor else {
            targetGain = Self.minimumGain
            return
        }

        let levelGain = Self.targetRMS / rms
        let peakGain = framePeak > 0 ? Self.peakCeiling / framePeak : activeGainCeiling
        targetGain = min(
            max(Self.minimumGain, levelGain),
            activeGainCeiling,
            max(Self.minimumGain, peakGain)
        )
    }

    private func addEnvelopeObservationLocked(_ rms: Float) {
        envelopeObservations[envelopeObservationIndex] = rms
        envelopeObservationIndex = (envelopeObservationIndex + 1) % Self.envelopeWindowFrames
        envelopeObservationCount = min(envelopeObservationCount + 1, Self.envelopeWindowFrames)
    }

    private func envelopeHasPersistentModulationLocked() -> Bool {
        guard envelopeObservationCount >= 8 else { return false }
        let startIndex = envelopeObservationCount == Self.envelopeWindowFrames ? envelopeObservationIndex : 0
        var minimum = Float.greatestFiniteMagnitude
        var maximum: Float = 0
        var sum: Float = 0
        var significantChanges = 0
        var rises = 0
        var falls = 0
        var totalVariation: Float = 0
        var secondDifference: Float = 0
        var previousDelta: Float?
        var previous: Float?

        for offset in 0..<envelopeObservationCount {
            let value = envelopeObservations[(startIndex + offset) % Self.envelopeWindowFrames]
            minimum = min(minimum, value)
            maximum = max(maximum, value)
            sum += value
            if let previous = previous {
                let delta = value - previous
                totalVariation += abs(delta)
                if let previousDelta = previousDelta {
                    secondDifference += abs(delta - previousDelta)
                }
                previousDelta = delta
                let normalizedChange = delta / max(previous, Self.minimumNoiseFloor)
                if normalizedChange >= Self.significantEnvelopeChange {
                    significantChanges += 1
                    rises += 1
                } else if normalizedChange <= -Self.significantEnvelopeChange {
                    significantChanges += 1
                    falls += 1
                }
            }
            previous = value
        }

        let mean = sum / Float(envelopeObservationCount)
        let modulationDepth = (maximum - minimum) / max(mean, Self.minimumNoiseFloor)
        let roughness = secondDifference / max(totalVariation, Self.minimumNoiseFloor)
        return modulationDepth >= Self.minimumEnvelopeModulationDepth
            && significantChanges >= Self.minimumEnvelopeChanges
            && rises > 0
            && falls > 0
            && roughness <= Self.maximumEnvelopeRoughness
    }

    private func addNoiseObservationLocked(_ rms: Float) {
        noiseObservations[noiseObservationIndex] = rms
        noiseObservationIndex = (noiseObservationIndex + 1) % Self.noiseWindowFrames
        noiseObservationCount = min(noiseObservationCount + 1, Self.noiseWindowFrames)

        var minimum = Float.greatestFiniteMagnitude
        var sum: Float = 0
        for index in 0..<noiseObservationCount {
            let observation = noiseObservations[index]
            minimum = min(minimum, observation)
            sum += observation
        }
        let mean = sum / Float(noiseObservationCount)
        // Alt zarf ile ortalama arasında sabit ağırlıklı sağlam tahmin; tek bir
        // yüksek gözlem tabanı hızla yukarı taşıyamaz.
        noiseFloorRMS = min(
            Self.maximumNoiseObservationRMS,
            max(Self.minimumNoiseFloor, minimum + (mean - minimum) * 0.10)
        )
    }

    /// 16-bit PCM ham bayt verisini AGC ve soft limiter ile işler. Çıktı byte sayısı
    /// ve varsa tek trailing byte aynen korunur; unity yolunda PCM bit-exact kalır.
    public func processPCM16Data(_ data: Data, enabled: Bool = true) -> Data {
        guard enabled, data.count >= MemoryLayout<Int16>.size else {
            if !enabled { reset() }
            return data
        }

        lock.lock()
        defer { lock.unlock() }

        let sampleCount = data.count / MemoryLayout<Int16>.size
        var outputData = Data(count: data.count)
        outputData.withUnsafeMutableBytes { outputBuffer in
            data.withUnsafeBytes { inputBuffer in
                guard let input = inputBuffer.bindMemory(to: Int16.self).baseAddress,
                      let output = outputBuffer.bindMemory(to: Int16.self).baseAddress else { return }

                for index in 0..<sampleCount {
                    let rawSample = input[index]
                    let normalized = Float(rawSample) / 32768.0
                    let processed = processSampleLocked(normalized)
                    if processed == normalized {
                        output[index] = rawSample
                    } else {
                        let clamped = max(-1.0, min(1.0, processed))
                        output[index] = Int16(clamped * 32767.0)
                    }
                }

                let processedByteCount = sampleCount * MemoryLayout<Int16>.size
                if data.count > processedByteCount {
                    outputBuffer[processedByteCount] = inputBuffer[processedByteCount]
                }
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
