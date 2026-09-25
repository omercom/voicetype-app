import Foundation
import XCTest
@testable import VoiceTypingCore

final class UtteranceClarityEnhancerTests: XCTestCase {
    private let sampleRate = 16_000
    private let speechFrequencies: [Double] = [140, 210, 310, 460, 620, 820, 1_080, 1_480, 2_100]

    func testShortQuietSpeechEnhancesFirstTwoHundredMillisecondsWithStaticGain() {
        let input = speechLikePCM(seconds: 0.40, amplitude: 0.014)
        let result = UtteranceClarityEnhancer().enhancePCM16(input)
        let firstTwoHundredMilliseconds = sampleRate / 5 * MemoryLayout<Int16>.size
        let inputPrefix = Data(input.prefix(firstTwoHundredMilliseconds))
        let outputPrefix = Data(result.data.prefix(firstTwoHundredMilliseconds))
        let inputSuffix = Data(input.dropFirst(firstTwoHundredMilliseconds))
        let outputSuffix = Data(result.data.dropFirst(firstTwoHundredMilliseconds))
        let prefixGain = pcmRMS(outputPrefix) / pcmRMS(inputPrefix)
        let suffixGain = pcmRMS(outputSuffix) / pcmRMS(inputSuffix)

        XCTAssertEqual(result.report.decision, .enhanced)
        XCTAssertGreaterThan(result.report.appliedGain, 2.0)
        XCTAssertGreaterThan(prefixGain, 2.0, "İlk hece startup gözlem penceresine kurban edilmemeli.")
        XCTAssertEqual(prefixGain, suffixGain, accuracy: 0.08, "Tam cümle boyunca tek statik kazanç uygulanmalı.")
    }

    func testHighSNRQuietSpeechApproachesRobustTargetWithoutPumping() {
        let input = speechLikePCM(seconds: 2.0, amplitude: 0.025)
        let result = UtteranceClarityEnhancer().enhancePCM16(input)
        let resultingRobustLevel = result.report.robustSpeechRMS * result.report.appliedGain

        XCTAssertEqual(result.report.quality, .excellent)
        XCTAssertGreaterThan(result.report.estimatedSNRDB, 20)
        XCTAssertEqual(
            resultingRobustLevel,
            UtteranceClarityEnhancer.targetSpeechRMS,
            accuracy: 0.012
        )
        XCTAssertEqual(result.data.count, input.count)
    }

    func testStationaryAndModulatedToneFanNoiseAndKeyboardRemainBitExactUnity() {
        let fixtures: [(String, Data)] = [
            ("tone", stationaryTonePCM(seconds: 3.0, frequency: 200)),
            ("amplitude-modulated-tone", amplitudeModulatedTonePCM(seconds: 3.0)),
            ("fan", stationaryFanPCM(seconds: 3.0)),
            ("amplitude-modulated-fan", amplitudeModulatedFanPCM(seconds: 3.0)),
            ("colored-noise", seededColoredNoisePCM(seconds: 3.0)),
            ("keyboard", dampedKeyboardPCM(seconds: 3.0))
        ]

        for (name, input) in fixtures {
            let result = UtteranceClarityEnhancer().enhancePCM16(input)
            XCTAssertEqual(result.report.appliedGain, 1, accuracy: 0.0001, "\(name) yükseltilmemeli.")
            XCTAssertEqual(result.data, input, "\(name) unity yolunda bit-exact kalmalı.")
            XCTAssertNotEqual(result.report.decision, .enhanced)
        }
    }

    func testLowSNRMixtureDoesNotAmplifyNoiseAggressively() {
        let input = noisySpeechPCM(
            seconds: 3.0,
            speechAmplitude: 0.014,
            noiseAmplitude: 0.050
        )
        let result = UtteranceClarityEnhancer().enhancePCM16(input)

        XCTAssertLessThan(result.report.estimatedSNRDB, 8)
        XCTAssertLessThanOrEqual(result.report.appliedGain, 1.20)
        XCTAssertLessThanOrEqual(pcmRMS(result.data), pcmRMS(input) * 1.20)
    }

    func testLouderModulatedTonalNoiseDominatesQuietSpeechAndStaysNearUnity() {
        let input = tonalNoiseMixedSpeechPCM(
            seconds: 3.0,
            speechAmplitude: 0.008,
            fanAmplitude: 0.025
        )
        let result = UtteranceClarityEnhancer().enhancePCM16(input)

        XCTAssertLessThan(result.report.spectralEntropy, 0.20)
        XCTAssertLessThanOrEqual(result.report.appliedGain, 1.20)
        XCTAssertLessThanOrEqual(pcmRMS(result.data), pcmRMS(input) * 1.20)
    }

    func testBelowSubmissionThresholdChangingAlarmCannotBePromotedToAudio() {
        let input = changingHarmonicAlarmPCM(seconds: 1.0, peakPCMCount: 23)
        XCTAssertTrue(AudioRecorder.isPCM16Silent(data: input, minAmplitude: 24))

        // Bu adversarial sinyal el yapımı konuşma özelliklerini geçebilse bile
        // üretim finalizer'ı ham PCM gönderim eşiğini değişmez kural olarak korur.
        let directEnhancement = UtteranceClarityEnhancer().enhancePCM16(input)
        let prepared = AudioRecorder.prepareRecordingPCM(
            input,
            processingMode: .utteranceClarity
        )

        XCTAssertGreaterThanOrEqual(directEnhancement.report.appliedGain, 1)
        XCTAssertNil(prepared.report)
        XCTAssertEqual(prepared.data, input)
        XCTAssertTrue(AudioRecorder.isPCM16Silent(data: prepared.data, minAmplitude: 24))
    }

    func testOneHundredFortyMillisecondQuietSpeechWithSilenceCanBeEnhanced() {
        let input = speechWithSilencePCM(
            speechSeconds: 0.14,
            leadingSilenceSeconds: 0.08,
            trailingSilenceSeconds: 0.18,
            amplitude: 0.018
        )
        let result = UtteranceClarityEnhancer().enhancePCM16(input)

        XCTAssertEqual(result.report.decision, .enhanced)
        XCTAssertGreaterThan(result.report.appliedGain, 1.5)
        let leadingSilenceBytes = Int(0.08 * Double(sampleRate)) * MemoryLayout<Int16>.size
        XCTAssertEqual(result.data.prefix(leadingSilenceBytes), input.prefix(leadingSilenceBytes))
    }

    func testLimiterNeverIncreasesClippingRatio() {
        let input = generatedPCM16(seconds: 2.0) { index, time in
            if index % 4_000 == 0 { return 0.995 }
            return self.speechSample(time: time, amplitude: 0.020)
        }
        let result = UtteranceClarityEnhancer().enhancePCM16(input)

        XCTAssertLessThanOrEqual(result.report.outputClippingRatio, result.report.inputClippingRatio)
        XCTAssertLessThan(result.report.outputPeak, 0.981)
        XCTAssertLessThanOrEqual(pcmClippingRatio(result.data), pcmClippingRatio(input))
    }

    func testPCMByteCountTrailingByteAndDeterminismArePreserved() {
        var input = speechLikePCM(seconds: 0.50, amplitude: 0.016)
        input.append(0xAB)
        let enhancer = UtteranceClarityEnhancer()
        let first = enhancer.enhancePCM16(input)
        let second = enhancer.enhancePCM16(input)

        XCTAssertEqual(first.data.count, input.count)
        XCTAssertEqual(first.data.last, 0xAB)
        XCTAssertEqual(first.data, second.data)
        XCTAssertEqual(first.report, second.report)
        XCTAssertEqual(first.report.sampleCount, input.count / MemoryLayout<Int16>.size)
    }

    func testOddOffsetDataUsesUnalignedSafePCMReads() {
        let aligned = speechLikePCM(seconds: 0.50, amplitude: 0.016)
        var storage = Data([0x7F])
        storage.append(aligned)
        let oddOffsetView = storage.dropFirst()
        let enhancer = UtteranceClarityEnhancer()
        let alignedResult = enhancer.enhancePCM16(aligned)
        let unalignedResult = enhancer.enhancePCM16(oddOffsetView)

        XCTAssertEqual(unalignedResult.data, alignedResult.data)
        XCTAssertEqual(unalignedResult.report, alignedResult.report)
        XCTAssertEqual(
            AudioRecorder.isPCM16Silent(data: oddOffsetView),
            AudioRecorder.isPCM16Silent(data: aligned)
        )
    }

    func testAnalysisDoesNotMutatePCMAndMatchesEnhancementPlan() {
        let input = speechLikePCM(seconds: 0.60, amplitude: 0.014)
        let enhancer = UtteranceClarityEnhancer()
        let analysis = enhancer.analyzePCM16(input)
        let enhanced = enhancer.enhancePCM16(input)

        XCTAssertEqual(analysis.appliedGain, enhanced.report.appliedGain, accuracy: 0.0001)
        XCTAssertEqual(analysis.decision, enhanced.report.decision)
        XCTAssertEqual(analysis.quality, enhanced.report.quality)
        XCTAssertEqual(input, speechLikePCM(seconds: 0.60, amplitude: 0.014))
    }

    func testRecordingProcessingModeKeepsRealtimeAndOfflinePathsExclusive() {
        var config = AppConfig.defaultConfig
        config.enable_microphone_boost = true

        config.provider = "assemblyai"
        XCTAssertEqual(RecordingAudioProcessingMode.resolve(config: config), .utteranceClarity)

        config.provider = "groq"
        XCTAssertEqual(RecordingAudioProcessingMode.resolve(config: config), .utteranceClarity)

        config.provider = "apple"
        XCTAssertEqual(RecordingAudioProcessingMode.resolve(config: config), .realtimeBoost)

        config.provider = "gemini"
        config.gemini_model = "gemini-3.5-transcribe-live"
        XCTAssertEqual(RecordingAudioProcessingMode.resolve(config: config), .realtimeBoost)

        config.gemini_model = ""
        XCTAssertEqual(RecordingAudioProcessingMode.resolve(config: config), .realtimeBoost)

        config.gemini_model = "gemini-3.5-transcribe"
        XCTAssertEqual(RecordingAudioProcessingMode.resolve(config: config), .utteranceClarity)

        config.enable_microphone_boost = false
        XCTAssertEqual(RecordingAudioProcessingMode.resolve(config: config), .none)
    }

    private func generatedPCM16(seconds: Double, sample: (Int, Double) -> Float) -> Data {
        let sampleCount = Int(seconds * Double(sampleRate))
        var data = Data(count: sampleCount * MemoryLayout<Int16>.size)
        data.withUnsafeMutableBytes { buffer in
            guard let samples = buffer.bindMemory(to: Int16.self).baseAddress else { return }
            for index in 0..<sampleCount {
                let value = max(-1.0, min(1.0, sample(index, Double(index) / Double(sampleRate))))
                samples[index] = Int16((value * 32_767.0).rounded())
            }
        }
        return data
    }

    private func speechSample(time: Double, amplitude: Float) -> Float {
        let envelope = 0.62
            + 0.23 * sin(2 * .pi * 3.1 * time)
            + 0.15 * sin(2 * .pi * 5.3 * time)
        // Göreli bant enerjileri zamanla değişir; yalnız toplam genliği modüle
        // edilen dar bantlı bir ton/fan gerçek konuşma yerine geçmemeli.
        var carrier: Double = 0
        for (index, frequency) in speechFrequencies.enumerated() {
            let phaseIndex = Double(index)
            let weight = 0.16
                + 0.10 * sin(2 * .pi * (1.1 + phaseIndex * 0.37) * time + phaseIndex * 0.7)
            carrier += weight * sin(2 * .pi * frequency * time + phaseIndex * 0.2)
        }
        return amplitude * Float(envelope * carrier)
    }

    private func speechLikePCM(seconds: Double, amplitude: Float) -> Data {
        generatedPCM16(seconds: seconds) { _, time in
            self.speechSample(time: time, amplitude: amplitude)
        }
    }

    private func stationaryTonePCM(seconds: Double, frequency: Double, amplitude: Float = 0.010) -> Data {
        generatedPCM16(seconds: seconds) { _, time in
            amplitude * Float(sin(2 * .pi * frequency * time))
        }
    }

    private func stationaryFanPCM(seconds: Double, amplitude: Float = 0.010) -> Data {
        generatedPCM16(seconds: seconds) { _, time in
            amplitude * Float(fanCarrier(time: time))
        }
    }

    private func amplitudeModulatedTonePCM(
        seconds: Double,
        amplitude: Float = 0.010
    ) -> Data {
        generatedPCM16(seconds: seconds) { _, time in
            amplitude * Float(modulationEnvelope(time: time) * sin(2 * .pi * 200 * time))
        }
    }

    private func amplitudeModulatedFanPCM(
        seconds: Double,
        amplitude: Float = 0.010
    ) -> Data {
        generatedPCM16(seconds: seconds) { _, time in
            amplitude * Float(modulationEnvelope(time: time) * fanCarrier(time: time))
        }
    }

    private func tonalNoiseMixedSpeechPCM(
        seconds: Double,
        speechAmplitude: Float,
        fanAmplitude: Float
    ) -> Data {
        generatedPCM16(seconds: seconds) { _, time in
            self.speechSample(time: time, amplitude: speechAmplitude)
                + fanAmplitude * Float(self.modulationEnvelope(time: time) * self.fanCarrier(time: time))
        }
    }

    private func modulationEnvelope(time: Double) -> Double {
        0.65
            + 0.30 * sin(2 * .pi * 3.1 * time)
            + 0.05 * sin(2 * .pi * 5.3 * time)
    }

    private func fanCarrier(time: Double) -> Double {
        0.62 * sin(2 * .pi * 90 * time)
            + 0.24 * sin(2 * .pi * 200 * time)
            + 0.14 * sin(2 * .pi * 500 * time)
    }

    private func seededColoredNoisePCM(seconds: Double, amplitude: Float = 0.025) -> Data {
        var state: UInt32 = 0xC0FFEE
        var filtered: Float = 0
        return generatedPCM16(seconds: seconds) { _, _ in
            state = 1_664_525 &* state &+ 1_013_904_223
            let white = Float(Int32(bitPattern: state)) / Float(Int32.max)
            filtered = filtered * 0.86 + white * 0.14
            return filtered * amplitude
        }
    }

    private func speechWithSilencePCM(
        speechSeconds: Double,
        leadingSilenceSeconds: Double,
        trailingSilenceSeconds: Double,
        amplitude: Float
    ) -> Data {
        let totalSeconds = leadingSilenceSeconds + speechSeconds + trailingSilenceSeconds
        return generatedPCM16(seconds: totalSeconds) { _, time in
            guard time >= leadingSilenceSeconds,
                  time < leadingSilenceSeconds + speechSeconds else { return 0 }
            return self.speechSample(
                time: time - leadingSilenceSeconds,
                amplitude: amplitude
            )
        }
    }

    private func changingHarmonicAlarmPCM(
        seconds: Double,
        peakPCMCount: Float
    ) -> Data {
        let peak = peakPCMCount / 32_767.0
        return generatedPCM16(seconds: seconds) { _, time in
            let sweepRate = 2.7
            let phase = 2 * Double.pi * (
                155 * time
                    + 24 / (2 * Double.pi * sweepRate) * sin(2 * Double.pi * sweepRate * time)
            )
            var harmonicSum: Double = 0
            for harmonic in 1...10 {
                let index = Double(harmonic)
                let changingWeight = (1.0 / index)
                    * (0.72 + 0.28 * sin(2 * .pi * (1.3 + index * 0.17) * time + index))
                harmonicSum += changingWeight * sin(index * phase + index * 0.21)
            }
            return max(-peak, min(peak, Float(harmonicSum * 4.0) * peak))
        }
    }

    private func noisySpeechPCM(
        seconds: Double,
        speechAmplitude: Float,
        noiseAmplitude: Float
    ) -> Data {
        var state: UInt32 = 0xC0FFEE
        var filtered: Float = 0
        return generatedPCM16(seconds: seconds) { _, time in
            state = 1_664_525 &* state &+ 1_013_904_223
            let white = Float(Int32(bitPattern: state)) / Float(Int32.max)
            filtered = filtered * 0.86 + white * 0.14
            return self.speechSample(time: time, amplitude: speechAmplitude)
                + filtered * noiseAmplitude
        }
    }

    private func dampedKeyboardPCM(seconds: Double) -> Data {
        generatedPCM16(seconds: seconds) { index, time in
            let samplesPerStrike = 2_880
            let strikeOffset = index % samplesPerStrike
            guard strikeOffset < 480 else { return 0 }
            let envelope = exp(-Double(strikeOffset) / 70.0)
            let impact = sin(2 * .pi * 1_700 * time)
                + 0.55 * sin(2 * .pi * 2_900 * time)
            return Float(0.08 * envelope * impact)
        }
    }

    private func pcmRMS(_ data: Data) -> Float {
        let sampleCount = data.count / MemoryLayout<Int16>.size
        guard sampleCount > 0 else { return 0 }
        return data.withUnsafeBytes { buffer in
            let samples = buffer.bindMemory(to: Int16.self)
            var sum: Double = 0
            for index in 0..<sampleCount {
                let value = Double(Int16(littleEndian: samples[index])) / 32_768.0
                sum += value * value
            }
            return Float(sqrt(sum / Double(sampleCount)))
        }
    }

    private func pcmClippingRatio(_ data: Data) -> Float {
        let sampleCount = data.count / MemoryLayout<Int16>.size
        guard sampleCount > 0 else { return 0 }
        return data.withUnsafeBytes { buffer in
            let samples = buffer.bindMemory(to: Int16.self)
            var clipped = 0
            for index in 0..<sampleCount {
                let value = abs(Float(Int16(littleEndian: samples[index])) / 32_768.0)
                if value >= 0.98 { clipped += 1 }
            }
            return Float(clipped) / Float(sampleCount)
        }
    }
}
