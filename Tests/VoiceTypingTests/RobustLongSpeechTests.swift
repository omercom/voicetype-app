import Foundation
import XCTest
@testable import VoiceTypingCore

final class RobustLongSpeechTests: XCTestCase {
    private func makeMono16kWAV(samples: [Int16]) -> Data {
        let sampleRate: UInt32 = 16_000
        let channels: UInt16 = 1
        let bitsPerSample: UInt16 = 16
        let dataSize = UInt32(samples.count * MemoryLayout<Int16>.size)
        let riffSize = UInt32(36) + dataSize
        let byteRate = sampleRate * UInt32(channels) * UInt32(bitsPerSample / 8)
        let blockAlign = channels * (bitsPerSample / 8)

        var data = Data()
        data.append("RIFF".data(using: .ascii)!)
        var le = riffSize.littleEndian
        data.append(Data(bytes: &le, count: 4))
        data.append("WAVE".data(using: .ascii)!)
        data.append("fmt ".data(using: .ascii)!)
        var fmtSize: UInt32 = UInt32(16).littleEndian
        data.append(Data(bytes: &fmtSize, count: 4))
        var pcmTag: UInt16 = UInt16(1).littleEndian
        data.append(Data(bytes: &pcmTag, count: 2))
        var chLE = channels.littleEndian
        data.append(Data(bytes: &chLE, count: 2))
        var srLE = sampleRate.littleEndian
        data.append(Data(bytes: &srLE, count: 4))
        var brLE = byteRate.littleEndian
        data.append(Data(bytes: &brLE, count: 4))
        var baLE = blockAlign.littleEndian
        data.append(Data(bytes: &baLE, count: 2))
        var bpsLE = bitsPerSample.littleEndian
        data.append(Data(bytes: &bpsLE, count: 2))
        data.append("data".data(using: .ascii)!)
        var dsLE = dataSize.littleEndian
        data.append(Data(bytes: &dsLE, count: 4))

        samples.withUnsafeBytes { raw in
            if let base = raw.baseAddress {
                data.append(base.assumingMemoryBound(to: UInt8.self), count: raw.count)
            }
        }
        return data
    }

    func testReleaseTailSilentFinishesAtBaseTail() {
        var policy = ReleaseTailPolicy(baseTail: 0.20, maxTail: 0.60, quietSettle: 0.14, pollInterval: 0.035)
        XCTAssertEqual(policy.decision(elapsed: 0.0, isSpeaking: false), .wait(0.035))
        if case let .wait(remaining) = policy.decision(elapsed: 0.18, isSpeaking: false) {
            XCTAssertEqual(remaining, 0.02, accuracy: 1e-6)
        } else {
            XCTFail("Expected remaining wait interval")
        }
        XCTAssertEqual(policy.decision(elapsed: 0.20, isSpeaking: false), .finish)
    }

    func testReleaseTailExtendsForSpeechThenFinishesAfterQuietSettle() {
        var policy = ReleaseTailPolicy(baseTail: 0.20, maxTail: 0.60, quietSettle: 0.14, pollInterval: 0.035)
        XCTAssertEqual(policy.decision(elapsed: 0.05, isSpeaking: true), .wait(0.035))
        XCTAssertEqual(policy.decision(elapsed: 0.22, isSpeaking: true), .wait(0.035))
        // Konuşma 0.26s civarı biter -> quietSettle (0.14s) dolana kadar bekler, sonra bitirir
        XCTAssertEqual(policy.decision(elapsed: 0.26, isSpeaking: false), .wait(0.035))
        XCTAssertEqual(policy.decision(elapsed: 0.35, isSpeaking: false), .wait(0.035))
        XCTAssertEqual(policy.decision(elapsed: 0.40, isSpeaking: false), .finish)
    }

    func testReleaseTailCapsAtMaxTailDuringContinuousSpeech() {
        var policy = ReleaseTailPolicy(baseTail: 0.20, maxTail: 0.60, quietSettle: 0.14, pollInterval: 0.035)
        _ = policy.decision(elapsed: 0.0, isSpeaking: true)
        _ = policy.decision(elapsed: 0.50, isSpeaking: true)
        XCTAssertEqual(policy.decision(elapsed: 0.60, isSpeaking: true), .finish)
    }

    func testAudioChunkerDurationAndShortPassThrough() {
        let samples = Array(repeating: Int16(200), count: 16_000 * 3) // 3s
        let wav = makeMono16kWAV(samples: samples)
        XCTAssertEqual(AudioChunker.pcmDurationSeconds(wavData: wav), 3.0, accuracy: 0.01)

        let chunks = AudioChunker.splitWAV(wav, maxChunkSeconds: 10.0)
        XCTAssertEqual(chunks.count, 1)
        XCTAssertEqual(chunks.first, wav)
    }

    func testAudioChunkerSplitsLongWAVNearSilenceWithValidHeaders() {
        // 0..8s konuşma, 8..9s sessizlik, 9..16s konuşma -> 10s sınırında sessizlik civarından bölmeli
        var samples = [Int16](repeating: 0, count: 16_000 * 16)
        for i in 0..<(16_000 * 8) {
            samples[i] = (i % 40 < 20) ? 9000 : -9000
        }
        for i in (16_000 * 9)..<(16_000 * 16) {
            samples[i] = (i % 40 < 20) ? 9000 : -9000
        }
        let wav = makeMono16kWAV(samples: samples)

        let chunks = AudioChunker.splitWAV(wav, maxChunkSeconds: 10.0, overlapSeconds: 0.5)
        XCTAssertGreaterThanOrEqual(chunks.count, 2)
        for chunk in chunks {
            XCTAssertGreaterThan(chunk.count, 44)
            XCTAssertEqual(String(data: chunk.prefix(4), encoding: .ascii), "RIFF")
            XCTAssertEqual(String(data: chunk.subdata(in: 8..<12), encoding: .ascii), "WAVE")
            XCTAssertLessThanOrEqual(AudioChunker.pcmDurationSeconds(wavData: chunk), 10.6)
        }
        // Örtüşmeli toplam süre orijinal süreden büyük olmalı (kelime kaybı yok)
        let totalChunkSec = chunks.reduce(0.0) { $0 + AudioChunker.pcmDurationSeconds(wavData: $1) }
        XCTAssertGreaterThan(totalChunkSec, 15.5)
    }

    func testDynamicRequestTimeoutScalesWithDurationAndClamps() {
        XCTAssertEqual(AudioChunker.dynamicRequestTimeout(audioSeconds: 2.0, minSeconds: 30, maxSeconds: 180), 30.0)
        let mid = AudioChunker.dynamicRequestTimeout(audioSeconds: 60.0, minSeconds: 30, maxSeconds: 180)
        XCTAssertGreaterThan(mid, 50.0)
        XCTAssertLessThan(mid, 180.0)
        XCTAssertEqual(AudioChunker.dynamicRequestTimeout(audioSeconds: 1000.0, minSeconds: 30, maxSeconds: 180), 180.0)
        XCTAssertEqual(AudioChunker.dynamicRequestTimeout(audioSeconds: .nan, minSeconds: 30, maxSeconds: 180), 30.0)
    }

    func testStreamingAccumulatorNeverErasesOpeningWordsOnShortUnrelatedPartial() {
        var acc = StreamingTranscriptAccumulator()
        acc.receivePartial("Toplantı yarın sabah onda başlayacak ve sunum hazır", receivedAt: 1.0)
        acc.receivePartial("sunum", receivedAt: 1.2)
        XCTAssertTrue(acc.text.contains("Toplantı"))
        XCTAssertTrue(acc.text.contains("başlayacak"))
    }

    func testRecoveryStoreEntryAndPruningPreservesLatestRecovery() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("VoiceTypingRecoveryPrune-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = DictationRecoveryAudioStore(customDirectoryURL: dir)
        let legacyData = Data(repeating: 7, count: 100)
        XCTAssertTrue(store.saveLastRecording(wavData: legacyData))

        var ids: [UUID] = []
        for idx in 0..<4 {
            let wav = makeMono16kWAV(samples: Array(repeating: Int16(100 + idx), count: 800))
            let id = try XCTUnwrap(store.saveRecording(wavData: wav))
            XCTAssertTrue(store.markFailed(error: "err-\(idx)", recordingID: id))
            ids.append(id)
        }

        let entry = try XCTUnwrap(store.latestRecoveryEntry())
        XCTAssertGreaterThan(entry.data.count, 44)

        store.pruneOldRecordings(maxCount: 2, maxAge: 86400)
        let remaining = (try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil))
            .map(\.lastPathComponent)
        XCTAssertTrue(remaining.contains("latest_recovery.wav"))
        let uuidWavs = remaining.filter { $0.hasPrefix("recovery_") && $0.hasSuffix(".wav") }
        XCTAssertLessThanOrEqual(uuidWavs.count, 2)
    }
}
