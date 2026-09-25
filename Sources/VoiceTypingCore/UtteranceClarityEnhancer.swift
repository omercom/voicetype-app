import Foundation

public enum ClarityQuality: String, Equatable, Sendable {
    case silent
    case nonSpeech
    case poor
    case fair
    case good
    case excellent
}

public enum ClarityDecision: String, Equatable, Sendable {
    case enhanced
    case unitySilent
    case unityNonSpeech
    case unityLowConfidence
    case unityAlreadyClear
    case unityClipped
}

/// Ölçülen netlik değerleri yalnız sinyal istatistikleridir; ses veya deşifre
/// içeriği taşımaz.
public struct ClarityReport: Equatable, Sendable {
    public let sampleCount: Int
    public let frameCount: Int
    public let estimatedNoiseFloorRMS: Float
    public let robustSpeechRMS: Float
    public let estimatedSNRDB: Float
    public let speechConfidence: Float
    public let speechFrameRatio: Float
    public let envelopeModulationDepth: Float
    public let envelopeRoughness: Float
    public let periodicity: Float
    public let phoneticFlux: Float
    public let spectralEntropy: Float
    public let appliedGain: Float
    public let inputPeak: Float
    public let outputPeak: Float
    public let inputClippingRatio: Float
    public let outputClippingRatio: Float
    public let quality: ClarityQuality
    public let decision: ClarityDecision
}

/// Sağlayıcının ses tüketme biçimine göre kayıt başına yalnız bir işlem yolu
/// seçilir. `utteranceClarity` ile `realtimeBoost` aynı kayıtta birlikte çalışmaz.
public enum RecordingAudioProcessingMode: String, Equatable, Sendable {
    case none
    case realtimeBoost
    case utteranceClarity

    public static func resolve(config: AppConfig) -> RecordingAudioProcessingMode {
        guard config.enable_microphone_boost else { return .none }

        let providerID = TranscriptionProviderRegistry.normalize(config.provider)

        // Gemini tek sağlayıcıdır ki ses tüketme biçimi modele göre değişir:
        // canlı (Live) modeller akış halinde beslenir, REST modelleri ise
        // tamamlanmış bir cümleyi alır. Diğer sağlayıcılar için karar kayıt
        // defterindeki bildirimsel tercihten gelir.
        if providerID == "gemini" {
            let configuredModel = config.gemini_model.trimmingCharacters(in: .whitespacesAndNewlines)
            let effectiveModel = configuredModel.isEmpty
                ? AppConfig.defaultConfig.gemini_model
                : configuredModel
            return ConfigManager.isGeminiLiveModel(effectiveModel)
                ? .realtimeBoost
                : .utteranceClarity
        }

        return TranscriptionProviderRegistry.descriptor(for: providerID).processingMode
    }
}

/// Tam cümleyi gördükten sonra çalışan Robust Modulation-Periodicity
/// Normalization (RMPN). 20 ms karelerde sağlam seviye istatistiklerini,
/// konuşma zarfının zamansal yapısını ve pitch-band periyodikliğini birleştirir.
/// Sonuç tek bir statik kazançtır; gate/expander kullanmadığı için sessiz
/// ünsüzleri kesmez ve AGC pumping üretmez.
public struct UtteranceClarityEnhancer: Sendable {
    private struct FrameStats {
        let rms: Float
        let peak: Float
        let crestFactor: Float
        let differenceRatio: Float
        let periodicity: Float

        var isImpulse: Bool {
            crestFactor >= UtteranceClarityEnhancer.impulseCrestFactor
        }
    }

    private struct Analysis {
        let samples: [Float]
        let sampleCount: Int
        let frameCount: Int
        let noiseFloorRMS: Float
        let speechRMS: Float
        let snrDB: Float
        let confidence: Float
        let speechFrameRatio: Float
        let modulationDepth: Float
        let roughness: Float
        let periodicity: Float
        let phoneticFlux: Float
        let spectralEntropy: Float
        let gain: Float
        let inputPeak: Float
        let inputClippingRatio: Float
        let quality: ClarityQuality
        let decision: ClarityDecision
    }

    public static let sampleRate = 16_000
    public static let frameSampleCount = 320 // 20 ms @ 16 kHz
    public static let targetSpeechRMS: Float = 0.065
    public static let maximumGain: Float = 8.0
    public static let boostedNoiseCeilingRMS: Float = 0.010

    private static let minimumAnalyzedFrameSamples = 160
    private static let minimumFrameCount = 3
    private static let minimumActivationRMS: Float = 0.00035
    private static let minimumNoiseFloorRMS: Float = 0.00008
    private static let speechEnergyFloorRatio: Float = 1.18
    private static let minimumDifferenceRatio: Float = 0.05
    private static let impulseCrestFactor: Float = 4.8
    private static let limiterKnee: Float = 0.82
    private static let limiterCeiling: Float = 0.98
    private static let clippingThreshold: Float = 0.98
    private static let maximumInputClippingRatio: Float = 0.001
    private static let minimumEnhancementConfidence: Float = 0.18
    private static let minimumMeaningfulGain: Float = 1.08
    private static let peakCeiling: Float = 0.92
    private static let pitchLags = Array(stride(from: 32, through: 160, by: 8))
    private static let spectralWindowSampleCount = 1_600 // Entropi için 100 ms
    private static let phoneticWindowSampleCount = 800 // Değişim için 50 ms
    private static let phoneticWindowHopSamples = 400 // 25 ms
    private static let spectralShapeLags = [1, 2, 4, 8, 16, 32, 64]
    private static let maximumEntropyWindows = 12
    private static let goertzelCoefficients: [Double] = stride(from: 80, through: 4_000, by: 40).map { frequency in
        2.0 * cos(2.0 * .pi * Double(frequency) / Double(sampleRate))
    }
    private static let spectralWindow: [Float] = (0..<spectralWindowSampleCount).map { index in
        0.5 - 0.5 * cos(2.0 * .pi * Float(index) / Float(spectralWindowSampleCount - 1))
    }

    public init() {}

    public func analyzePCM16(_ data: Data) -> ClarityReport {
        let analysis = Self.analyze(data)
        let predictedPeak: Float
        let predictedClippingRatio: Float
        if analysis.gain > 1.0 {
            predictedPeak = abs(Self.softLimited(analysis.inputPeak * analysis.gain))
            predictedClippingRatio = predictedPeak >= Self.clippingThreshold ? analysis.inputClippingRatio : 0
        } else {
            predictedPeak = analysis.inputPeak
            predictedClippingRatio = analysis.inputClippingRatio
        }
        return Self.makeReport(
            analysis: analysis,
            outputPeak: predictedPeak,
            outputClippingRatio: predictedClippingRatio
        )
    }

    public func enhancePCM16(_ data: Data) -> (data: Data, report: ClarityReport) {
        let analysis = Self.analyze(data)
        guard analysis.gain > 1.0, analysis.sampleCount > 0 else {
            return (
                data,
                Self.makeReport(
                    analysis: analysis,
                    outputPeak: analysis.inputPeak,
                    outputClippingRatio: analysis.inputClippingRatio
                )
            )
        }

        var quantizedSamples = [Int16](repeating: 0, count: analysis.sampleCount)
        var outputPeak: Float = 0
        var clippedSampleCount = 0
        for index in 0..<analysis.sampleCount {
            let processed = Self.softLimited(analysis.samples[index] * analysis.gain)
            let clamped = max(-1.0, min(1.0, processed))
            let magnitude = abs(clamped)
            outputPeak = max(outputPeak, magnitude)
            if magnitude >= Self.clippingThreshold {
                clippedSampleCount += 1
            }
            quantizedSamples[index] = Int16((clamped * 32_767.0).rounded()).littleEndian
        }

        var output = quantizedSamples.withUnsafeBytes { Data($0) }
        let processedByteCount = analysis.sampleCount * MemoryLayout<Int16>.size
        if data.count > processedByteCount {
            output.append(data[processedByteCount])
        }

        let outputClippingRatio = analysis.sampleCount > 0
            ? Float(clippedSampleCount) / Float(analysis.sampleCount)
            : 0
        return (
            output,
            Self.makeReport(
                analysis: analysis,
                outputPeak: outputPeak,
                outputClippingRatio: outputClippingRatio
            )
        )
    }

    private static func analyze(_ data: Data) -> Analysis {
        let sampleCount = data.count / MemoryLayout<Int16>.size
        guard sampleCount > 0 else {
            return emptyAnalysis(sampleCount: 0, inputPeak: 0, clippingRatio: 0)
        }

        var samples = [Float](repeating: 0, count: sampleCount)
        var inputPeak: Float = 0
        var clippingCount = 0
        data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
            for index in 0..<sampleCount {
                let rawSample = buffer.loadUnaligned(
                    fromByteOffset: index * MemoryLayout<Int16>.size,
                    as: Int16.self
                )
                let value = Float(Int16(littleEndian: rawSample)) / 32_768.0
                samples[index] = value
                let magnitude = abs(value)
                inputPeak = max(inputPeak, magnitude)
                if magnitude >= clippingThreshold {
                    clippingCount += 1
                }
            }
        }

        let clippingRatio = Float(clippingCount) / Float(sampleCount)
        var frames: [FrameStats] = []
        frames.reserveCapacity((sampleCount + frameSampleCount - 1) / frameSampleCount)

        var frameStart = 0
        while frameStart < sampleCount {
            let count = min(frameSampleCount, sampleCount - frameStart)
            guard count >= minimumAnalyzedFrameSamples else { break }
            frames.append(frameStats(samples: samples, start: frameStart, count: count))
            frameStart += count
        }

        guard frames.count >= minimumFrameCount else {
            return emptyAnalysis(
                samples: samples,
                sampleCount: sampleCount,
                frameCount: frames.count,
                inputPeak: inputPeak,
                clippingRatio: clippingRatio
            )
        }

        let frameRMSValues = frames.map(\.rms)
        let rawLowerEnvelope = quantile(frameRMSValues, 0.20)
        let speechEnergyFloor = max(minimumActivationRMS, rawLowerEnvelope * speechEnergyFloorRatio)
        let candidateIndices = frames.indices.filter { index in
            let frame = frames[index]
            return !frame.isImpulse
                && frame.rms >= speechEnergyFloor
                && frame.differenceRatio >= minimumDifferenceRatio
        }

        guard candidateIndices.count >= minimumFrameCount,
              let firstCandidate = candidateIndices.first,
              let lastCandidate = candidateIndices.last else {
            let isSilent = inputPeak < minimumActivationRMS
            return Analysis(
                samples: samples,
                sampleCount: sampleCount,
                frameCount: frames.count,
                noiseFloorRMS: max(minimumNoiseFloorRMS, rawLowerEnvelope),
                speechRMS: 0,
                snrDB: -160,
                confidence: 0,
                speechFrameRatio: 0,
                modulationDepth: 0,
                roughness: 0,
                periodicity: 0,
                phoneticFlux: 0,
                spectralEntropy: 0,
                gain: 1,
                inputPeak: inputPeak,
                inputClippingRatio: clippingRatio,
                quality: isSilent ? .silent : .nonSpeech,
                decision: isSilent ? .unitySilent : .unityNonSpeech
            )
        }

        let activeSpan = firstCandidate...lastCandidate
        let candidateFrames = candidateIndices.map { frames[$0] }
        let envelopeCeiling = quantile(candidateFrames.map(\.rms), 0.85)
        let activeRMS = activeSpan.map { index in
            // Seyrek klavye/click darbeleri konuşma zarfının pürüzlülüğünü
            // bozmasın; darbenin kendisi çıkışta soft limiter tarafından korunur.
            min(frames[index].rms, envelopeCeiling)
        }
        let smoothedEnvelope = movingAverage3(activeRMS)
        let envelopeMedian = quantile(smoothedEnvelope, 0.50)
        let modulationDepth = envelopeMedian > minimumNoiseFloorRMS
            ? (quantile(smoothedEnvelope, 0.85) - quantile(smoothedEnvelope, 0.15)) / envelopeMedian
            : 0
        let roughness = envelopeRoughness(smoothedEnvelope)
        let impulseFrameCount = activeSpan.reduce(into: 0) { count, index in
            if frames[index].isImpulse { count += 1 }
        }
        let impulseRatio = Float(impulseFrameCount) / Float(activeSpan.count)
        let speechFrameRatio = Float(candidateIndices.count) / Float(activeSpan.count)
        let robustSpeechRMS = quantile(candidateFrames.map(\.rms), 0.60)
        let periodicity = quantile(candidateFrames.map(\.periodicity), 0.60)
        let phoneticFlux = phoneticSpectralFlux(
            samples: samples,
            firstFrame: firstCandidate,
            lastFrame: lastCandidate,
            energyFloor: speechEnergyFloor
        )
        let phoneticConfidence = smoothstep(phoneticFlux, low: 0.025, high: 0.050)
        let spectralEntropy = robustSpectralEntropy(
            samples: samples,
            firstFrame: firstCandidate,
            lastFrame: lastCandidate,
            energyFloor: speechEnergyFloor
        )
        let spectralDiversityConfidence = smoothstep(spectralEntropy, low: 0.175, high: 0.215)

        // Periyodik enerji ancak spektral şekil de fonemler gibi değişiyorsa
        // konuşma tarafından açıklanmış sayılır. Böylece genliği dalgalanan sabit
        // ton/fan uğultusu gürültü tabanından yanlışlıkla düşülmez.
        let residualNoise = frames.map { frame in
            let voicedConfidence = smoothstep(frame.periodicity, low: 0.25, high: 0.55)
            let explainedSpeech = voicedConfidence
                * phoneticConfidence
                * spectralDiversityConfidence
            return frame.rms * max(0.08, 1.0 - explainedSpeech)
        }
        let noiseFloor = max(minimumNoiseFloorRMS, quantile(residualNoise, 0.20))
        let snrDB = robustSpeechRMS > 0
            ? max(-20, min(60, 20.0 * log10(robustSpeechRMS / noiseFloor)))
            : -160

        let modulationConfidence: Float
        if activeSpan.count < 15 {
            // 300 ms'den kısa komutlarda tam bir hece/zarf çevrimi görülmeyebilir;
            // spektral çeşitlilik ve fonetik flux yine zorunlu güvenlik kapılarıdır.
            modulationConfidence = smoothstep(modulationDepth, low: 0.06, high: 0.18)
        } else {
            modulationConfidence = smoothstep(modulationDepth, low: 0.12, high: 0.40)
        }
        let smoothEnvelopeConfidence = 1.0 - smoothstep(roughness, low: 0.95, high: 1.45)
        let periodicityConfidence = smoothstep(periodicity, low: 0.30, high: 0.60)
        let coverageConfidence = smoothstep(speechFrameRatio, low: 0.10, high: 0.30)
        let impulseSafety = 1.0 - smoothstep(impulseRatio, low: 0.10, high: 0.35)
        let structuralConfidence = modulationConfidence
            * smoothEnvelopeConfidence
            * periodicityConfidence
            * phoneticConfidence
            * spectralDiversityConfidence
            * coverageConfidence
            * impulseSafety
        let snrConfidence = smoothstep(snrDB, low: 6.0, high: 14.0)
        let confidence = max(0, min(1, structuralConfidence * snrConfidence))
        let quality = classifyQuality(
            inputPeak: inputPeak,
            structuralConfidence: structuralConfidence,
            snrDB: snrDB
        )

        var gain: Float = 1
        let decision: ClarityDecision
        if clippingRatio > maximumInputClippingRatio {
            decision = .unityClipped
        } else if structuralConfidence < minimumEnhancementConfidence {
            decision = .unityNonSpeech
        } else if confidence < minimumEnhancementConfidence {
            decision = .unityLowConfidence
        } else {
            let levelGain = targetSpeechRMS / max(robustSpeechRMS, minimumNoiseFloorRMS)
            let noiseGain = boostedNoiseCeilingRMS / noiseFloor
            let robustPeak = quantile(candidateFrames.map(\.peak), 0.95)
            let peakGain = peakCeiling / max(robustPeak, minimumNoiseFloorRMS)
            let boundedGain = min(maximumGain, levelGain, noiseGain, peakGain)
            let confidenceWeightedGain = 1.0 + (max(1.0, boundedGain) - 1.0) * confidence

            if confidenceWeightedGain >= minimumMeaningfulGain {
                gain = confidenceWeightedGain
                decision = .enhanced
            } else {
                decision = .unityAlreadyClear
            }
        }

        return Analysis(
            samples: samples,
            sampleCount: sampleCount,
            frameCount: frames.count,
            noiseFloorRMS: noiseFloor,
            speechRMS: robustSpeechRMS,
            snrDB: snrDB,
            confidence: confidence,
            speechFrameRatio: speechFrameRatio,
            modulationDepth: modulationDepth,
            roughness: roughness,
            periodicity: periodicity,
            phoneticFlux: phoneticFlux,
            spectralEntropy: spectralEntropy,
            gain: gain,
            inputPeak: inputPeak,
            inputClippingRatio: clippingRatio,
            quality: quality,
            decision: decision
        )
    }

    private static func frameStats(samples: [Float], start: Int, count: Int) -> FrameStats {
        var sum: Double = 0
        var sumSquares: Double = 0
        var differenceSquares: Double = 0
        for offset in 0..<count {
            let value = samples[start + offset]
            sum += Double(value)
            sumSquares += Double(value * value)
            if offset > 0 {
                let difference = value - samples[start + offset - 1]
                differenceSquares += Double(difference * difference)
            }
        }

        let mean = Float(sum / Double(count))
        let variance = max(0, Float(sumSquares / Double(count)) - mean * mean)
        let rms = sqrt(variance)
        var peak: Float = 0
        for offset in 0..<count {
            peak = max(peak, abs(samples[start + offset] - mean))
        }
        let differenceRMS = count > 1
            ? sqrt(Float(differenceSquares / Double(count - 1)))
            : 0
        let differenceRatio = differenceRMS / max(rms, minimumNoiseFloorRMS)
        let crestFactor = peak / max(rms, minimumNoiseFloorRMS)
        let periodicity = normalizedPeriodicity(
            samples: samples,
            start: start,
            count: count,
            mean: mean,
            rms: rms
        )
        return FrameStats(
            rms: rms,
            peak: peak,
            crestFactor: crestFactor,
            differenceRatio: differenceRatio,
            periodicity: periodicity
        )
    }

    private static func normalizedPeriodicity(
        samples: [Float],
        start: Int,
        count: Int,
        mean: Float,
        rms: Float
    ) -> Float {
        guard rms >= minimumNoiseFloorRMS else { return 0 }
        var best: Float = 0
        for lag in pitchLags where lag < count / 2 {
            var dot: Double = 0
            var leftEnergy: Double = 0
            var rightEnergy: Double = 0
            let pairCount = count - lag
            for offset in 0..<pairCount {
                let left = Double(samples[start + offset] - mean)
                let right = Double(samples[start + offset + lag] - mean)
                dot += left * right
                leftEnergy += left * left
                rightEnergy += right * right
            }
            let denominator = sqrt(leftEnergy * rightEnergy)
            if denominator > 0 {
                best = max(best, Float(abs(dot) / denominator))
            }
        }
        return min(1, best)
    }

    private static func robustSpectralEntropy(
        samples: [Float],
        firstFrame: Int,
        lastFrame: Int,
        energyFloor: Float
    ) -> Float {
        let firstSample = firstFrame * frameSampleCount
        let endSample = min(samples.count, (lastFrame + 1) * frameSampleCount)
        let availableWindowCount = (endSample - firstSample) / spectralWindowSampleCount
        guard availableWindowCount > 0 else { return 0 }

        let selectedWindowCount = min(maximumEntropyWindows, availableWindowCount)
        var entropyValues: [Float] = []
        entropyValues.reserveCapacity(selectedWindowCount)
        for selection in 0..<selectedWindowCount {
            let windowIndex: Int
            if selectedWindowCount == 1 {
                windowIndex = 0
            } else {
                windowIndex = selection * (availableWindowCount - 1) / (selectedWindowCount - 1)
            }
            let start = firstSample + windowIndex * spectralWindowSampleCount
            let measurement = spectralShape(
                samples: samples,
                start: start,
                count: spectralWindowSampleCount
            )
            guard measurement.rms >= energyFloor * 0.75 else { continue }
            entropyValues.append(spectralEntropy(samples: samples, start: start))
        }
        return quantile(entropyValues, 0.50)
    }

    private static func spectralEntropy(samples: [Float], start: Int) -> Float {
        var mean: Double = 0
        for offset in 0..<spectralWindowSampleCount {
            mean += Double(samples[start + offset])
        }
        mean /= Double(spectralWindowSampleCount)

        var powers = [Double](repeating: 0, count: goertzelCoefficients.count)
        var totalPower: Double = 0
        for (coefficientIndex, coefficient) in goertzelCoefficients.enumerated() {
            var previous: Double = 0
            var previousPrevious: Double = 0
            for offset in 0..<spectralWindowSampleCount {
                let centered = Double(samples[start + offset]) - mean
                let windowed = centered * Double(spectralWindow[offset])
                let current = windowed + coefficient * previous - previousPrevious
                previousPrevious = previous
                previous = current
            }
            let power = max(
                0,
                previous * previous
                    + previousPrevious * previousPrevious
                    - coefficient * previous * previousPrevious
            )
            powers[coefficientIndex] = power
            totalPower += power
        }

        guard totalPower > Double.leastNonzeroMagnitude else { return 0 }
        var entropy: Double = 0
        for power in powers where power > 0 {
            let probability = power / totalPower
            entropy -= probability * log(probability)
        }
        return Float(entropy / log(Double(powers.count)))
    }

    private static func phoneticSpectralFlux(
        samples: [Float],
        firstFrame: Int,
        lastFrame: Int,
        energyFloor: Float
    ) -> Float {
        let firstSample = firstFrame * frameSampleCount
        let endSample = min(samples.count, (lastFrame + 1) * frameSampleCount)
        guard endSample - firstSample >= phoneticWindowSampleCount + phoneticWindowHopSamples else {
            return 0
        }

        var fluxValues: [Float] = []
        var previousShape: [Float]?
        var windowStart = firstSample
        while windowStart + phoneticWindowSampleCount <= endSample {
            let measurement = spectralShape(
                samples: samples,
                start: windowStart,
                count: phoneticWindowSampleCount
            )
            if measurement.rms >= energyFloor * 0.75 {
                if let previousShape {
                    var squaredDistance: Float = 0
                    for index in measurement.values.indices {
                        let delta = measurement.values[index] - previousShape[index]
                        squaredDistance += delta * delta
                    }
                    fluxValues.append(sqrt(squaredDistance / Float(measurement.values.count)))
                }
                previousShape = measurement.values
            } else {
                // Sessizlik üzerinden iki ayrı konuşma parçasını karşılaştırmak
                // yapay spektral değişim üretir; yeni segmentte referansı sıfırla.
                previousShape = nil
            }
            windowStart += phoneticWindowHopSamples
        }
        return quantile(fluxValues, 0.50)
    }

    private static func spectralShape(
        samples: [Float],
        start: Int,
        count: Int
    ) -> (rms: Float, values: [Float]) {
        var sum: Double = 0
        var sumSquares: Double = 0
        for offset in 0..<count {
            let value = samples[start + offset]
            sum += Double(value)
            sumSquares += Double(value * value)
        }
        let mean = Float(sum / Double(count))
        let variance = max(0, Float(sumSquares / Double(count)) - mean * mean)
        let rms = sqrt(variance)
        let denominator = max(rms, minimumNoiseFloorRMS)
        var shape: [Float] = []
        shape.reserveCapacity(spectralShapeLags.count)

        for lag in spectralShapeLags where lag < count {
            var differenceSquares: Double = 0
            for offset in lag..<count {
                let difference = samples[start + offset] - samples[start + offset - lag]
                differenceSquares += Double(difference * difference)
            }
            let differenceRMS = sqrt(Float(differenceSquares / Double(count - lag)))
            shape.append(differenceRMS / denominator)
        }
        return (rms, shape)
    }

    private static func movingAverage3(_ values: [Float]) -> [Float] {
        guard values.count > 1 else { return values }
        return values.indices.map { index in
            let lower = max(0, index - 1)
            let upper = min(values.count - 1, index + 1)
            var sum: Float = 0
            for neighbor in lower...upper {
                sum += values[neighbor]
            }
            return sum / Float(upper - lower + 1)
        }
    }

    private static func envelopeRoughness(_ values: [Float]) -> Float {
        guard values.count >= 3 else { return 2 }
        var previousDelta = values[1] - values[0]
        var totalVariation = abs(previousDelta)
        var secondDifference: Float = 0
        for index in 2..<values.count {
            let delta = values[index] - values[index - 1]
            totalVariation += abs(delta)
            secondDifference += abs(delta - previousDelta)
            previousDelta = delta
        }
        guard totalVariation > minimumNoiseFloorRMS else { return 2 }
        return secondDifference / totalVariation
    }

    private static func quantile(_ values: [Float], _ probability: Float) -> Float {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        guard sorted.count > 1 else { return sorted[0] }
        let boundedProbability = max(0, min(1, probability))
        let position = Float(sorted.count - 1) * boundedProbability
        let lowerIndex = Int(position.rounded(.down))
        let upperIndex = min(sorted.count - 1, lowerIndex + 1)
        let fraction = position - Float(lowerIndex)
        return sorted[lowerIndex] + (sorted[upperIndex] - sorted[lowerIndex]) * fraction
    }

    private static func smoothstep(_ value: Float, low: Float, high: Float) -> Float {
        guard high > low else { return value >= high ? 1 : 0 }
        let normalized = max(0, min(1, (value - low) / (high - low)))
        return normalized * normalized * (3.0 - 2.0 * normalized)
    }

    private static func classifyQuality(
        inputPeak: Float,
        structuralConfidence: Float,
        snrDB: Float
    ) -> ClarityQuality {
        if inputPeak < minimumActivationRMS { return .silent }
        if structuralConfidence < minimumEnhancementConfidence { return .nonSpeech }
        if snrDB < 6 { return .poor }
        if snrDB < 12 { return .fair }
        if snrDB < 20 { return .good }
        return .excellent
    }

    private static func softLimited(_ sample: Float) -> Float {
        let magnitude = abs(sample)
        guard magnitude > limiterKnee else { return sample }
        let normalizedExcess = (magnitude - limiterKnee) / (limiterCeiling - limiterKnee)
        let limitedMagnitude = limiterKnee + (limiterCeiling - limiterKnee) * tanh(normalizedExcess)
        return sample < 0 ? -limitedMagnitude : limitedMagnitude
    }

    private static func makeReport(
        analysis: Analysis,
        outputPeak: Float,
        outputClippingRatio: Float
    ) -> ClarityReport {
        ClarityReport(
            sampleCount: analysis.sampleCount,
            frameCount: analysis.frameCount,
            estimatedNoiseFloorRMS: analysis.noiseFloorRMS,
            robustSpeechRMS: analysis.speechRMS,
            estimatedSNRDB: analysis.snrDB,
            speechConfidence: analysis.confidence,
            speechFrameRatio: analysis.speechFrameRatio,
            envelopeModulationDepth: analysis.modulationDepth,
            envelopeRoughness: analysis.roughness,
            periodicity: analysis.periodicity,
            phoneticFlux: analysis.phoneticFlux,
            spectralEntropy: analysis.spectralEntropy,
            appliedGain: analysis.gain,
            inputPeak: analysis.inputPeak,
            outputPeak: outputPeak,
            inputClippingRatio: analysis.inputClippingRatio,
            outputClippingRatio: outputClippingRatio,
            quality: analysis.quality,
            decision: analysis.decision
        )
    }

    private static func emptyAnalysis(
        samples: [Float] = [],
        sampleCount: Int,
        frameCount: Int = 0,
        inputPeak: Float,
        clippingRatio: Float
    ) -> Analysis {
        Analysis(
            samples: samples,
            sampleCount: sampleCount,
            frameCount: frameCount,
            noiseFloorRMS: minimumNoiseFloorRMS,
            speechRMS: 0,
            snrDB: -160,
            confidence: 0,
            speechFrameRatio: 0,
            modulationDepth: 0,
            roughness: 0,
            periodicity: 0,
            phoneticFlux: 0,
            spectralEntropy: 0,
            gain: 1,
            inputPeak: inputPeak,
            inputClippingRatio: clippingRatio,
            quality: inputPeak < minimumActivationRMS ? .silent : .nonSpeech,
            decision: inputPeak < minimumActivationRMS ? .unitySilent : .unityNonSpeech
        )
    }
}
