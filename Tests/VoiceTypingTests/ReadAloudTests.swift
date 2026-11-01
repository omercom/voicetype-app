import XCTest
@testable import VoiceTypingCore

final class ReadAloudTests: XCTestCase {
    func testTextValidation() throws {
        XCTAssertEqual(try ReadAloudText.validated(" \nMerhaba dünya.\t"), "Merhaba dünya.")
        XCTAssertThrowsError(try ReadAloudText.validated(" \n"))
        XCTAssertEqual(try ReadAloudText.validated(String(repeating: "ş", count: 30000)).count, 30000)
        XCTAssertThrowsError(try ReadAloudText.validated(String(repeating: "ş", count: 30001)))
    }

    func testLongTextChunksPreserveWordsAndStayBounded() {
        let text = String(repeating: "Merhaba dünya. Şimdi uzun bir metni bölüm bölüm okuyoruz.\n", count: 300)
        let chunks = ReadAloudText.chunks(text)
        XCTAssertGreaterThan(chunks.count, 1)
        XCTAssertTrue(chunks.allSatisfy { !$0.isEmpty && $0.unicodeScalars.count <= 350 })
        XCTAssertEqual(chunks.joined(separator: " ").split(whereSeparator: { $0.isWhitespace }),
                       text.split(whereSeparator: { $0.isWhitespace }))
        XCTAssertEqual(ReadAloudText.chunks("Merhaba."), ["Merhaba."])
        XCTAssertEqual(ReadAloudText.chunks(" \n"), [])
    }

    func testUnbrokenUnicodeTextChunksWithoutLoss() {
        let text = String(repeating: "ş😀", count: 1000)
        let chunks = ReadAloudText.chunks(text)
        XCTAssertEqual(chunks.joined(), text)
        XCTAssertTrue(chunks.allSatisfy { $0.unicodeScalars.count <= 350 })
    }

    func testWorkerEvents() throws {
        let id = UUID()
        let json = "{\"event\":\"audio\",\"id\":\"\(id)\",\"duration\":1.5,\"path\":\"/local.wav\"}"
        let event = try JSONDecoder().decode(ReadAloudWorkerEvent.self, from: Data(json.utf8))
        XCTAssertEqual(event.id, id)
        XCTAssertEqual(event.duration, 1.5)
        XCTAssertThrowsError(try JSONDecoder().decode(ReadAloudWorkerEvent.self, from: Data("{\"event\":\"audio\",\"id\":\"../bad\"}".utf8)))
    }

    func testOnlyExpectedAudioPathIsAccepted() {
        let folder = URL(fileURLWithPath: "/private/tmp/read-aloud-test")
        let id = UUID()
        let filename = id.uuidString.lowercased() + ".wav"
        XCTAssertTrue(ReadAloudEngine.isExpectedAudioPath(folder.appendingPathComponent(filename).path, id: id, directory: folder))
        XCTAssertFalse(ReadAloudEngine.isExpectedAudioPath("/private/tmp/\(filename)", id: id, directory: folder))
        XCTAssertFalse(ReadAloudEngine.isExpectedAudioPath(folder.appendingPathComponent("other.wav").path, id: id, directory: folder))
        XCTAssertFalse(ReadAloudEngine.isExpectedAudioPath(folder.appendingPathComponent("../\(filename)").path, id: id, directory: folder))
    }

    func testNewClipboardWritesAreNotOverwritten() {
        XCTAssertTrue(SelectedTextReader.shouldRestoreClipboard(copiedCount: 12, currentCount: 12))
        XCTAssertFalse(SelectedTextReader.shouldRestoreClipboard(copiedCount: 12, currentCount: 13))
    }

    func testMissingRuntimeFailsWithoutStartingProcess() {
        let engine = ReadAloudEngine(pythonURL: URL(fileURLWithPath: "/nonexistent/antalia-python"))
        let failed = expectation(description: "Missing runtime reports an error")
        engine.onFailure = { _, message in
            XCTAssertTrue(message.contains("kurulmadı"))
            failed.fulfill()
        }
        engine.prepare()
        wait(for: [failed], timeout: 1)
        XCTAssertFalse(engine.isReady)
    }

    func testPersistentWorkerAndCleanup() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let fixture = folder.appendingPathComponent("worker.py")
        try """
        import json, os, sys, uuid
        from pathlib import Path
        print('{"event":"ready","device":"cpu"}', flush=True)
        for line in sys.stdin:
            request = json.loads(line)
            path = Path(os.environ['VOICETYPE_TTS_OUTPUT']) / (str(uuid.UUID(request['id'])) + '.wav')
            path.write_bytes(b'fixture')
            print(json.dumps(dict(event='audio', id=request['id'], path=str(path), duration=1.0)), flush=True)
        """.write(to: fixture, atomically: true, encoding: .utf8)
        let engine = ReadAloudEngine(pythonURL: URL(fileURLWithPath: "/usr/bin/python3"), workerURL: fixture)
        defer { engine.shutdown() }
        let finished = expectation(description: "Two requests use one worker")
        let first = UUID(), second = UUID()
        var outputs: [URL] = []
        var readyCount = 0
        engine.onReady = { _ in readyCount += 1 }
        engine.onFailure = { _, message in XCTFail(message); finished.fulfill() }
        engine.onAudio = { id, url, _ in
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
            outputs.append(url)
            if id == first { engine.synthesize("İkinci istek.", id: second) }
            else { XCTAssertEqual(id, second); finished.fulfill() }
        }
        engine.synthesize("Birinci istek.", id: first)
        wait(for: [finished], timeout: 10)
        XCTAssertEqual(readyCount, 1)
        XCTAssertEqual(outputs.count, 2)
        engine.shutdown()
        for url in outputs { XCTAssertFalse(FileManager.default.fileExists(atPath: url.path)) }
    }

    func testRealAntaliaIntegrationWhenRequested() throws {
        guard ProcessInfo.processInfo.environment["VOICETYPE_TEST_ANTALIA"] == "1" else {
            throw XCTSkip("Enable VOICETYPE_TEST_ANTALIA after setup-tts.sh")
        }
        let engine = ReadAloudEngine()
        XCTAssertTrue(engine.isInstalled, "Runtime and bundled worker must exist")
        defer { engine.shutdown() }
        let finished = expectation(description: "Real Antalia produces a WAV")
        var produced: URL?
        engine.onFailure = { _, message in XCTFail(message); finished.fulfill() }
        engine.onAudio = { _, url, duration in
            produced = url
            XCTAssertGreaterThan(duration, 0)
            let data = try? Data(contentsOf: url)
            XCTAssertEqual(data?.prefix(4), Data("RIFF".utf8))
            let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
            XCTAssertEqual((attributes?[.posixPermissions] as? NSNumber)?.intValue, 0o600)
            finished.fulfill()
        }
        engine.synthesize("Merhaba. VoiceType artık seçili Türkçe metni sesli okuyabiliyor.", id: UUID())
        wait(for: [finished], timeout: 90)
        XCTAssertNotNil(produced)
        engine.shutdown()
        if let produced { XCTAssertFalse(FileManager.default.fileExists(atPath: produced.path)) }
    }
}
