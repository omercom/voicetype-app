import AppKit
import XCTest
@testable import VoiceTypingCore

final class OptimizationAndHexParityTests: XCTestCase {
    func testMicrophoneLingerPolicyNormalBluetoothAndRestart() {
        var policy = MicrophoneLingerPolicy(lingerSeconds: 20.0)
        XCTAssertEqual(policy.markCaptureEnded(at: 100.0, isBluetoothRoute: false), 20.0)
        XCTAssertFalse(policy.shouldClose(at: 110.0, isRecording: false))
        XCTAssertFalse(policy.shouldClose(at: 125.0, isRecording: true))
        XCTAssertTrue(policy.shouldClose(at: 120.0, isRecording: false))

        // Yeni kayıt linger penceresini temizler
        _ = policy.markCaptureEnded(at: 200.0, isBluetoothRoute: false)
        policy.markCaptureStarted()
        XCTAssertTrue(policy.shouldClose(at: 201.0, isRecording: false))

        // Bluetooth route'da hemen kapanır (A2DP stereo koruması)
        XCTAssertNil(policy.markCaptureEnded(at: 300.0, isBluetoothRoute: true))
        XCTAssertTrue(policy.shouldClose(at: 300.0, isRecording: false))
    }

    func testDigitalSilenceDetectorIgnoresRealNoiseAndTriggersOnceForZeroStream() {
        var detector = DigitalSilenceDetector(thresholdSeconds: 1.8, maxRecoveriesPerSession: 1)

        // Gerçek oda gürültüsü sıfırı sıfırlar ve tetiklemez
        XCTAssertFalse(detector.observe(bufferDuration: 1.2, maxAbsSample: 0.0))
        XCTAssertFalse(detector.observe(bufferDuration: 0.2, maxAbsSample: 0.0005))
        XCTAssertEqual(detector.zeroDuration, 0.0, accuracy: 1e-6)

        // Aralıksız tam sıfır akış 1.8 sn'de tam bir kez tetikler
        XCTAssertFalse(detector.observe(bufferDuration: 1.0, maxAbsSample: 0.0))
        XCTAssertTrue(detector.observe(bufferDuration: 0.9, maxAbsSample: 0.0))
        XCTAssertEqual(detector.recoveryCount, 1)

        // Oturum sınırı dolunca tekrar döngüye girmez
        XCTAssertFalse(detector.observe(bufferDuration: 2.5, maxAbsSample: 0.0))

        detector.reset()
        XCTAssertEqual(detector.recoveryCount, 0)
        XCTAssertEqual(detector.zeroDuration, 0.0)
    }

    func testAudioOverloadTrackerCoalescesAndFlushes() {
        var tracker = AudioOverloadTracker(minReportInterval: 10.0)
        XCTAssertEqual(tracker.record(at: 1.0), 1)
        XCTAssertNil(tracker.record(at: 2.0))
        XCTAssertNil(tracker.record(at: 5.0))
        XCTAssertEqual(tracker.pendingCount, 2)
        XCTAssertEqual(tracker.record(at: 11.5), 3)
        XCTAssertNil(tracker.record(at: 12.0))
        XCTAssertEqual(tracker.flush(), 1)
        XCTAssertEqual(tracker.flush(), 0)
    }

    func testAudioChunkerMergeChunkTranscriptsDeduplicatesOverlapCleanly() {
        XCTAssertEqual(AudioChunker.mergeChunkTranscripts([]), "")
        XCTAssertEqual(
            AudioChunker.mergeChunkTranscripts(["  Merhaba dünya. ", ""]),
            "Merhaba dünya."
        )

        let mergedSingle = AudioChunker.mergeChunkTranscripts([
            "Bugün hava çok güzel görünüyor.",
            "Görünüyor ve yarın toplantıya gidiyoruz."
        ])
        XCTAssertEqual(mergedSingle, "Bugün hava çok güzel görünüyor. ve yarın toplantıya gidiyoruz.")

        let mergedMulti = AudioChunker.mergeChunkTranscripts([
            "İlk bölüm burada bitiyor ve devam ediyor",
            "burada bitiyor ve devam ediyor ikinci bölüm başlıyor"
        ])
        XCTAssertEqual(mergedMulti, "İlk bölüm burada bitiyor ve devam ediyor ikinci bölüm başlıyor")

        let unrelated = AudioChunker.mergeChunkTranscripts([
            "Birinci cümle bitti.",
            "İkinci cümle tamamen farklı."
        ])
        XCTAssertEqual(unrelated, "Birinci cümle bitti. İkinci cümle tamamen farklı.")
    }

    func testConfigPersistenceGuardBacksUpCorruptConfigWithPrivatePermissions() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("VoiceTypingConfigGuard-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let configURL = dir.appendingPathComponent("config.json")
        let corruptBytes = Data("{ \"provider\": ".utf8)
        try corruptBytes.write(to: configURL)

        let outcome = ConfigPersistenceGuard.load(from: configURL)
        XCTAssertNil(outcome.config)
        XCTAssertEqual(outcome.unreadableOriginalData, corruptBytes)
        XCTAssertNotNil(outcome.errorDescription)

        let backup1 = try XCTUnwrap(ConfigPersistenceGuard.backupCorruptConfig(originalData: corruptBytes, nextTo: configURL))
        let backup2 = try XCTUnwrap(ConfigPersistenceGuard.backupCorruptConfig(originalData: corruptBytes, nextTo: configURL))
        XCTAssertEqual(backup1, backup2)
        XCTAssertEqual(try Data(contentsOf: backup1), corruptBytes)

        let attrs = try FileManager.default.attributesOfItem(atPath: backup1.path)
        let mode = try XCTUnwrap(attrs[.posixPermissions] as? NSNumber).intValue & 0o777
        XCTAssertEqual(mode, 0o600)
    }

    func testExtraTriggerKeyOptionsAndMouseMappingAndConfigDefaults() throws {
        XCTAssertTrue(TriggerKeyOption.standardKeys.contains(where: { $0.keyCode == 176 }))
        XCTAssertFalse(KeyListener.isModifier(keyCode: 176))

        XCTAssertNil(KeyListener.mappedMouseVirtualKeyCode(buttonNumber: 0, configuredButton: 0))
        XCTAssertNil(KeyListener.mappedMouseVirtualKeyCode(buttonNumber: 1, configuredButton: 1))
        XCTAssertNil(KeyListener.mappedMouseVirtualKeyCode(buttonNumber: 3, configuredButton: 0))
        XCTAssertEqual(KeyListener.mappedMouseVirtualKeyCode(buttonNumber: 3, configuredButton: 3), 10_003)
        XCTAssertEqual(KeyListener.mappedMouseVirtualKeyCode(buttonNumber: 4, configuredButton: 4), 10_004)
        XCTAssertNil(KeyListener.mappedMouseVirtualKeyCode(buttonNumber: 3, configuredButton: 4))

        XCTAssertEqual(AppConfig.defaultConfig.keep_microphone_warm_seconds, 20)
        XCTAssertFalse(AppConfig.defaultConfig.enable_caps_lock_dictation)
        XCTAssertEqual(AppConfig.defaultConfig.mouse_trigger_button, 0)

        let legacyJSON = "{}".data(using: .utf8)!
        let decoded = try JSONDecoder().decode(AppConfig.self, from: legacyJSON)
        XCTAssertEqual(decoded.keep_microphone_warm_seconds, 20)
        XCTAssertFalse(decoded.enable_caps_lock_dictation)
        XCTAssertEqual(decoded.mouse_trigger_button, 0)
    }

    func testNotchWaveViewPreparingListeningAndProcessingRenderVisiblePixels() throws {
        let view = NotchWaveView(frame: NSRect(origin: .zero, size: NotchWaveView.size))
        for mode in [NotchWaveView.Mode.preparing, .listening, .processing] {
            view.render(level: mode == .listening ? 0.75 : 0.0, mode: mode, animated: false)
            let rep = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: rep)

            var litPixels = 0
            for y in 0..<rep.pixelsHigh {
                for x in 0..<rep.pixelsWide {
                    if let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB), c.alphaComponent > 0.1 {
                        litPixels += 1
                    }
                }
            }
            XCTAssertGreaterThan(litPixels, 10, "mode=\(mode) görünür piksel üretmeli")
        }
    }
}
