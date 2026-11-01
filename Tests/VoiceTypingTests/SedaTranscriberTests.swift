import XCTest
import AppKit
@testable import VoiceTypingCore

final class SedaTranscriberTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: folder)
    }

    private func worker(_ body: String, timeout: Double = 2) throws -> SedaTranscriber {
        let url = folder.appendingPathComponent(UUID().uuidString + ".py")
        let server = """
        import json, sys
        print(json.dumps({'ready': True}), flush=True)
        for line in sys.stdin:
            request = json.loads(line)
            sys.argv = [__file__, '--audio', request['audio']]
            exec(\(String(reflecting: body)))
        """
        try server.write(to: url, atomically: true, encoding: .utf8)
        return SedaTranscriber(pythonURL: URL(fileURLWithPath: "/usr/bin/python3"), workerURL: url,
                               timeoutSeconds: timeout)
    }

    private var wav: Data { Data("RIFF".utf8) + Data(repeating: 0, count: 100) }

    func testTurkishOnlyLanguageValidation() {
        for language in ["tr", "tr-TR", " TR_tr "] { XCTAssertTrue(SedaTranscriber.supportsLanguage(language)) }
        for language in ["en", "en-US", "auto", "", "tr-DE"] { XCTAssertFalse(SedaTranscriber.supportsLanguage(language)) }
        XCTAssertNotNil(SedaTranscriber.readinessMessage(language: "en"))
    }

    func testProviderIsLocalStreamingWithoutApplePermissionOrAPIKey() throws {
        let descriptor = TranscriptionProviderRegistry.descriptor(for: " SEDA ")
        XCTAssertEqual(descriptor.id, "seda")
        XCTAssertEqual(descriptor.capabilities, [.streaming, .batch, .onDevice])
        XCTAssertEqual(descriptor.processingMode, .realtimeBoost)
        XCTAssertFalse(descriptor.isMissingAPIKey(in: AppConfig.defaultConfig))
        XCTAssertTrue(TranscriptionProviderRegistry.supports(.requiresSpeechPermission, providerID: "apple"))
        var config = AppConfig.defaultConfig
        config.provider = "seda"
        let decoded = try JSONDecoder().decode(AppConfig.self, from: JSONEncoder().encode(config))
        XCTAssertEqual(decoded.provider, "seda")
    }

    func testSuccessRunsOfflineWithPrivateAudioAndCleansUp() throws {
        let savedPath = folder.appendingPathComponent("path.txt")
        let engine = try worker("""
        import json, os, pathlib, stat, sys
        path = pathlib.Path(sys.argv[sys.argv.index('--audio') + 1])
        assert os.environ['HF_HUB_OFFLINE'] == '1'
        assert stat.S_IMODE(path.stat().st_mode) == 0o600
        assert stat.S_IMODE(path.parent.stat().st_mode) == 0o700
        pathlib.Path(\(String(reflecting: savedPath.path))).write_text(str(path))
        print(json.dumps({'text': '  merhaba dünya  '}))
        """)
        let done = expectation(description: "result")
        engine.transcribe(audioData: wav, language: "tr") { result in
            XCTAssertTrue(Thread.isMainThread)
            XCTAssertTrue(result.success, result.error ?? "")
            XCTAssertEqual(result.text, "merhaba dünya")
            XCTAssertEqual(result.provider, "seda")
            XCTAssertEqual(result.model, SedaTranscriber.model)
            XCTAssertGreaterThan(result.latency, 0)
            done.fulfill()
        }
        wait(for: [done], timeout: 5)
        let path = try String(contentsOf: savedPath, encoding: .utf8)
        XCTAssertFalse(FileManager.default.fileExists(atPath: path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: URL(fileURLWithPath: path).deletingLastPathComponent().path))
    }

    func testInvalidAndFailedWorkersReturnErrors() throws {
        for script in ["print('not JSON')", "raise SystemExit(1)", "print('x' * 70000)"] {
            let engine = try worker(script)
            let done = expectation(description: "error")
            engine.transcribe(audioData: wav, language: "tr") { result in
                XCTAssertFalse(result.success)
                XCTAssertFalse(result.error?.isEmpty ?? true)
                done.fulfill()
            }
            wait(for: [done], timeout: 5)
        }
    }

    func testSilenceIsAnEmptySuccessfulResult() throws {
        let engine = try worker("print('{\"text\": \"\"}')")
        let done = expectation(description: "silence")
        engine.transcribe(audioData: wav, language: "tr") { result in
            XCTAssertTrue(result.success)
            XCTAssertEqual(result.text, "")
            done.fulfill()
        }
        wait(for: [done], timeout: 3)
    }

    func testTimeoutStopsWorkerAndRemovesWAV() throws {
        let savedPath = folder.appendingPathComponent("path.txt")
        let engine = try worker("""
        import pathlib, signal, sys, time
        signal.signal(signal.SIGTERM, signal.SIG_IGN)
        pathlib.Path(\(String(reflecting: savedPath.path))).write_text(sys.argv[-1])
        time.sleep(30)
        """, timeout: 0.5)
        let done = expectation(description: "timeout")
        engine.transcribe(audioData: wav, language: "tr") { result in
            XCTAssertFalse(result.success)
            done.fulfill()
        }
        wait(for: [done], timeout: 5)
        let path = try String(contentsOf: savedPath, encoding: .utf8)
        XCTAssertFalse(FileManager.default.fileExists(atPath: path))
    }

    func testCancelSuppressesStaleCompletionAndAllowsNextRequest() throws {
        let engine = try worker("import time; time.sleep(0.5); print('{\"text\": \"yeni\"}')")
        let stale = expectation(description: "cancelled callback")
        stale.isInverted = true
        let done = expectation(description: "next request")
        engine.transcribe(audioData: wav, language: "tr") { _ in stale.fulfill() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            engine.cancel()
            engine.transcribe(audioData: self.wav, language: "tr") { result in
                XCTAssertTrue(result.success)
                XCTAssertEqual(result.text, "yeni")
                done.fulfill()
            }
        }
        wait(for: [done, stale], timeout: 2)
    }

    func testInvalidAudioAndUnsupportedLanguageFailBeforeWorkerRuns() throws {
        let engine = try worker("print('{\"text\": \"should not run\"}')")
        for (audio, language) in [(Data(), "tr"), (wav, "en")] {
            let done = expectation(description: "validation")
            engine.transcribe(audioData: audio, language: language) { result in
                XCTAssertFalse(result.success)
                done.fulfill()
            }
            wait(for: [done], timeout: 2)
        }
    }

    func testSettingsSelectionPersistsSedaAndTurkish() throws {
        let original = ConfigManager.shared.config
        let controller = SettingsWindowController.shared
        let callback = controller.onConfigUpdated
        let installationCheck = controller.sedaInstallationCheck
        defer {
            ConfigManager.shared.update { $0 = original }
            controller.onConfigUpdated = callback
            controller.sedaInstallationCheck = installationCheck
            controller.loadValues()
        }
        controller.onConfigUpdated = nil
        controller.sedaInstallationCheck = { true }
        ConfigManager.shared.update { $0.provider = "apple"; $0.language = "en" }
        controller.loadValues()
        controller.selectTab(index: 1)
        func segments(in view: NSView) -> [NSSegmentedControl] {
            (view as? NSSegmentedControl).map { [$0] } ?? view.subviews.flatMap { segments(in: $0) }
        }
        let root = try XCTUnwrap(controller.window?.contentView)
        let control = try XCTUnwrap(segments(in: root).first { control in
            (0..<control.segmentCount).contains { control.label(forSegment: $0) == "Seda-v0.2" }
        })
        let index = try XCTUnwrap(TranscriptionProviderRegistry.all.firstIndex { $0.id == "seda" })
        XCTAssertEqual(control.segmentCount, TranscriptionProviderRegistry.all.count)
        control.selectedSegment = index
        XCTAssertTrue(control.sendAction(control.action, to: control.target))
        XCTAssertEqual(ConfigManager.shared.config.provider, "seda")
        XCTAssertEqual(ConfigManager.shared.config.language, "tr")
    }

    func testPersistentWorkerRestartsAfterProtocolFailure() throws {
        let marker = folder.appendingPathComponent("failed-once")
        let engine = try worker("""
        import pathlib
        marker = pathlib.Path(\(String(reflecting: marker.path)))
        if marker.exists():
            print(json.dumps({'text': 'kurtarıldı'}))
        else:
            marker.touch()
            print('invalid JSON')
        """)
        for index in 0..<2 {
            let done = expectation(description: "restart")
            engine.transcribe(audioData: wav, language: "tr") { result in
                XCTAssertEqual(result.success, index == 1)
                if index == 1 { XCTAssertEqual(result.text, "kurtarıldı") }
                done.fulfill()
            }
            wait(for: [done], timeout: 5)
        }
        engine.cancel()
    }

    func testPersistentWorkerReusesProcessAcrossRequests() throws {
        let engine = try worker("import os; print(json.dumps({'text': str(os.getpid())}))")
        var pids: [String] = []
        for _ in 0..<3 {
            let done = expectation(description: "reused process")
            engine.transcribe(audioData: wav, language: "tr") { result in
                XCTAssertTrue(result.success, result.error ?? "")
                pids.append(result.text)
                done.fulfill()
            }
            wait(for: [done], timeout: 3)
        }
        XCTAssertEqual(Set(pids).count, 1)
        engine.cancel()
    }

    func testInstalledModelThroughSharedTranscriber() throws {
        guard ProcessInfo.processInfo.environment["VOICETYPE_TEST_SEDA"] == "1" else {
            throw XCTSkip("Run setup-stt.sh and set VOICETYPE_TEST_SEDA=1 for the real model test.")
        }
        XCTAssertNil(SedaTranscriber.readinessMessage(language: "tr"))
        var config = AppConfig.defaultConfig
        config.provider = "seda"
        config.language = "tr"
        let sample = ProcessInfo.processInfo.environment["VOICETYPE_SEDA_SAMPLE"]
        let audio = try sample.map { try Data(contentsOf: URL(fileURLWithPath: $0)) }
            ?? AudioRecorder.createWavData(pcmData: Data(repeating: 0, count: 64000))
        defer { Transcriber.shared.cancel() }
        for index in 0..<3 {
            let done = expectation(description: "installed model")
            Transcriber.shared.transcribe(audioData: audio, config: config) { result in
                XCTAssertTrue(result.success, result.error ?? "")
                XCTAssertEqual(result.provider, "seda")
                if sample != nil { XCTAssertFalse(result.text.isEmpty) }
                else { XCTAssertEqual(result.text, "") }
                print("Seda request \(index + 1): \(result.latency) seconds")
                done.fulfill()
            }
            wait(for: [done], timeout: 95)
        }
    }

    func testInstalledModelLiveMatchesBatch() throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["VOICETYPE_TEST_SEDA"] == "1",
              let samplePath = environment["VOICETYPE_SEDA_SAMPLE"],
              let pcmPath = environment["VOICETYPE_SEDA_PCM"] else {
            throw XCTSkip("Provide an installed Seda model and matching WAV/PCM fixtures for the live test.")
        }
        XCTAssertTrue(SedaTranscriber.isInstalled(), "Kurulu v0.2 sağlayıcı listesinde görünmeli")
        let wavData = try Data(contentsOf: URL(fileURLWithPath: samplePath))
        let pcm = try Data(contentsOf: URL(fileURLWithPath: pcmPath))
        XCTAssertGreaterThan(pcm.count, 0)
        XCTAssertEqual(pcm.count % 2, 0)
        let engine = SedaTranscriber()
        defer { engine.cancel() }
        let liveDone = expectation(description: "real Seda live result")
        var partials: [String] = []
        var liveText = ""
        let session = engine.startLive(language: "tr", onInterim: { partials.append($0) }) { result in
            XCTAssertTrue(result.success, result.error ?? "")
            XCTAssertEqual(result.model, SedaTranscriber.model)
            liveText = result.text
            liveDone.fulfill()
        }
        for start in stride(from: 0, to: pcm.count, by: 3200) {
            session.sendAudioChunk(pcm.subdata(in: start..<min(start + 3200, pcm.count)))
        }
        session.finishAudio()
        wait(for: [liveDone], timeout: 95)
        XCTAssertFalse(partials.isEmpty, "Canlı dikte ara metin üretmeli")
        XCTAssertFalse(liveText.isEmpty)
        if let suffix = environment["VOICETYPE_SEDA_EXPECTED_SUFFIX"] {
            XCTAssertTrue(liveText.hasSuffix(suffix), "Son kelimeler eksik: \(liveText)")
        }

        let batchDone = expectation(description: "real Seda batch result")
        engine.transcribe(audioData: wavData, language: "tr") { result in
            XCTAssertTrue(result.success, result.error ?? "")
            XCTAssertEqual(result.text, liveText)
            batchDone.fulfill()
        }
        wait(for: [batchDone], timeout: 95)
    }

    func testMissingRuntimeReturnsSetupHint() {
        let engine = SedaTranscriber(pythonURL: folder.appendingPathComponent("missing"))
        let done = expectation(description: "missing runtime")
        engine.transcribe(audioData: wav, language: "tr") { result in
            XCTAssertFalse(result.success)
            XCTAssertTrue(result.error?.contains("setup-stt.sh") == true)
            done.fulfill()
        }
        wait(for: [done], timeout: 2)
    }
}
