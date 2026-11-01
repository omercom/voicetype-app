import XCTest
@testable import VoiceTypingCore

final class SedaLiveTranscriberTests: XCTestCase {
    private var folder: URL!
    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: folder) }

    private func worker(_ body: String, timeout: Double = 2) throws -> SedaTranscriber {
        let url = folder.appendingPathComponent("worker.py")
        try body.write(to: url, atomically: true, encoding: .utf8)
        return SedaTranscriber(pythonURL: URL(fileURLWithPath: "/usr/bin/python3"), workerURL: url, timeoutSeconds: timeout)
    }

    private let server = """
    import json, sys, os, base64, time
    time.sleep(0.1)
    print(json.dumps({'ready': True}), flush=True)
    for line in sys.stdin:
        r = json.loads(line)
        if 'audio' in r:
            print(json.dumps({'text': str(os.getpid())}), flush=True)
            continue
        op = r['op']
        if op == 'start':
            data = b''
            event = {'event': 'started', 'id': r['id']}
        elif op == 'audio':
            data += base64.b64decode(r['pcm'])
            event = {'event': 'interim', 'id': r['id'], 'text': 'merhaba'}
        else:
            assert data == bytes([17]) * 3200 + bytes(1280)
            event = {'event': 'final', 'id': r['id'], 'text': str(os.getpid())}
        print(json.dumps(event), flush=True)
    """

    func testInterimBeforeFinishAndProcessReuseAcrossLiveAndBatch() throws {
        let engine = try worker(server)
        defer { engine.cancel() }
        var pids: [String] = []
        for _ in 0..<2 {
            let interim = expectation(description: "interim before finish")
            let done = expectation(description: "live final")
            var seen = false
            let session = engine.startLive(language: "tr", onInterim: { text in
                XCTAssertTrue(Thread.isMainThread)
                XCTAssertEqual(text, "merhaba")
                if !seen { seen = true; interim.fulfill() }
            }, completion: { result in
                XCTAssertTrue(result.success, result.error ?? "")
                pids.append(result.text)
                done.fulfill()
            })
            session.sendAudioChunk(Data(repeating: 17, count: 3200))
            wait(for: [interim], timeout: 3)
            session.sendAudioChunk(Data(repeating: 0, count: 1280))
            session.finishAudio()
            session.finishAudio()
            wait(for: [done], timeout: 3)
        }
        let batch = expectation(description: "batch same worker")
        engine.transcribe(audioData: Data("RIFF".utf8) + Data(repeating: 0, count: 100), language: "tr") { result in
            XCTAssertTrue(result.success, result.error ?? "")
            pids.append(result.text)
            batch.fulfill()
        }
        wait(for: [batch], timeout: 3)
        XCTAssertEqual(Set(pids).count, 1)
    }

    func testColdAudioAndFinishBuffer() throws {
        let engine = try worker(server)
        defer { engine.cancel() }
        let done = expectation(description: "cold finish")
        let session = engine.startLive(language: "tr", onInterim: nil) { result in
            XCTAssertTrue(result.success, result.error ?? "")
            done.fulfill()
        }
        session.sendAudioChunk(Data(repeating: 17, count: 3200) + Data(repeating: 0, count: 1280))
        session.finishAudio()
        wait(for: [done], timeout: 3)
    }

    func testInvalidEventsAndEarlyFinalFail() throws {
        for event in ["{'event': 'final', 'id': r['id'], 'text': 'early'}",
                      "{'event': 'interim', 'id': '00000000-0000-0000-0000-000000000000', 'text': 'stale'}",
                      "{'event': 'unknown', 'id': r['id']}"] {
            let engine = try worker("""
            import json, sys
            print(json.dumps({'ready': True}), flush=True)
            r = json.loads(sys.stdin.readline())
            print(json.dumps(\(event)), flush=True)
            sys.stdin.read()
            """)
            let done = expectation(description: "invalid protocol")
            let session = engine.startLive(language: "tr", onInterim: { _ in XCTFail("stale interim") }) { result in
                XCTAssertFalse(result.success)
                done.fulfill()
            }
            wait(for: [done], timeout: 3)
            session.cancel()
        }
    }

    func testFinalTimeoutStopsUnresponsiveWorker() throws {
        let engine = try worker("""
        import json, sys, time, signal
        signal.signal(signal.SIGTERM, signal.SIG_IGN)
        print(json.dumps({'ready': True}), flush=True)
        for line in sys.stdin:
            r = json.loads(line)
            if r['op'] == 'start':
                print(json.dumps({'event': 'started', 'id': r['id']}), flush=True)
            if r['op'] == 'finish':
                time.sleep(30)
        """, timeout: 0.3)
        let done = expectation(description: "live timeout")
        let session = engine.startLive(language: "tr", onInterim: nil) { result in
            XCTAssertFalse(result.success)
            done.fulfill()
        }
        session.finishAudio()
        wait(for: [done], timeout: 5)
        engine.cancel()
    }

    func testCancelledSessionCannotStopNextSession() throws {
        let engine = try worker(server)
        defer { engine.cancel() }
        let stale = expectation(description: "cancelled callbacks")
        stale.isInverted = true
        let old = engine.startLive(language: "tr", onInterim: { _ in stale.fulfill() }) { _ in stale.fulfill() }
        old.cancel()
        let done = expectation(description: "next session")
        let next = engine.startLive(language: "tr", onInterim: nil) { result in
            XCTAssertTrue(result.success, result.error ?? "")
            done.fulfill()
        }
        old.cancel()
        next.sendAudioChunk(Data(repeating: 17, count: 3200) + Data(repeating: 0, count: 1280))
        next.finishAudio()
        wait(for: [done, stale], timeout: 3)
    }

    func testInstalledModelLiveMatchesBatch() throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["VOICETYPE_TEST_SEDA"] == "1", let path = environment["VOICETYPE_SEDA_SAMPLE"] else {
            throw XCTSkip("Enable VOICETYPE_TEST_SEDA and provide a PCM16 WAV sample.")
        }
        let wav = try Data(contentsOf: URL(fileURLWithPath: path))
        // Locate the WAV data chunk rather than assuming a 44-byte header.
        var cursor = 12
        var pcm = Data()
        while cursor + 8 <= wav.count {
            let size = (0..<4).reduce(0) { $0 | Int(wav[cursor + 4 + $1]) << (8 * $1) }
            if wav[cursor..<cursor + 4] == Data("data".utf8) {
                pcm = Data(wav[cursor + 8..<min(cursor + 8 + size, wav.count)])
                break
            }
            cursor += 8 + size + size % 2
        }
        XCTAssertFalse(pcm.isEmpty)
        let engine = SedaTranscriber()
        defer { engine.cancel() }
        var batchText = ""
        let batch = expectation(description: "real WAV")
        engine.transcribe(audioData: wav, language: "tr") { result in
            XCTAssertTrue(result.success, result.error ?? "")
            batchText = result.text
            batch.fulfill()
        }
        wait(for: [batch], timeout: 95)
        for index in 0..<2 {
            let done = expectation(description: "real live")
            let interim = expectation(description: "real interim before finish")
            var seen = false
            var finished = false
            let start = ProcessInfo.processInfo.systemUptime
            let session = engine.startLive(language: "tr", onInterim: { text in
                if !seen {
                    seen = true
                    XCTAssertFalse(finished)
                    XCTAssertFalse(text.isEmpty)
                    print("Seda live \(index + 1) first interim: \(ProcessInfo.processInfo.systemUptime - start) seconds")
                    interim.fulfill()
                }
            }, completion: { result in
                XCTAssertTrue(result.success, result.error ?? "")
                XCTAssertEqual(result.text, batchText)
                print("Seda live \(index + 1) final latency: \(result.latency) seconds")
                done.fulfill()
            })
            let audio = pcm
            DispatchQueue.global(qos: .userInitiated).async {
                for offset in stride(from: 0, to: audio.count, by: 3200) {
                    session.sendAudioChunk(Data(audio[offset..<min(offset + 3200, audio.count)]))
                    Thread.sleep(forTimeInterval: 0.1)
                }
                DispatchQueue.main.async { finished = true; session.finishAudio() }
            }
            wait(for: [interim, done], timeout: 95)
        }
    }
}
