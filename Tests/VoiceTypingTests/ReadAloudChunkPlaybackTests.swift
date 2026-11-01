import XCTest
@testable import VoiceTypingCore

final class ReadAloudChunkPlaybackTests: XCTestCase {
    private func fixture(duration: Double = 0.1, delay: Double = 0) throws -> (URL, ReadAloudController) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let worker = folder.appendingPathComponent("worker.py")
        try """
        import json, os, sys, time, uuid, wave
        from pathlib import Path
        print('{"event":"ready","device":"cpu"}', flush=True)
        for line in sys.stdin:
            request = json.loads(line)
            time.sleep(\(delay))
            path = Path(os.environ['VOICETYPE_TTS_OUTPUT']) / (str(uuid.UUID(request['id'])) + '.wav')
            with wave.open(str(path), 'wb') as wav:
                wav.setnchannels(1)
                wav.setsampwidth(2)
                wav.setframerate(24000)
                wav.writeframes(b'\\0' * \(Int(duration * 48000)))
            print(json.dumps(dict(event='audio', id=request['id'], path=str(path), duration=\(duration))), flush=True)
        """.write(to: worker, atomically: true, encoding: .utf8)
        let engine = ReadAloudEngine(pythonURL: URL(fileURLWithPath: "/usr/bin/python3"), workerURL: worker)
        return (folder, ReadAloudController(engine: engine))
    }

    func testAllChunksPlayInOrderAndFinish() throws {
        let (folder, controller) = try fixture()
        defer { controller.onUpdate = nil; controller.shutdown(); try? FileManager.default.removeItem(at: folder) }
        let id = UUID()
        let text = String(repeating: "Merhaba dünya. ", count: 80)
        let total = ReadAloudText.chunks(text).count
        let done = expectation(description: "Every chunk completed")
        var playing: [Int] = []
        controller.onError = { XCTFail($0) }
        controller.onUpdate = { message, busy in
            let state = controller.browserCommand(ReadAloudBrowserRequest(action: .status, id: id, text: nil))
            if message.hasPrefix("Türkçe okunuyor"), let current = state["currentChunk"] as? Int { playing.append(current) }
            if !busy && message.hasPrefix("Hazır"), !playing.isEmpty { done.fulfill() }
        }
        let accepted = controller.browserCommand(ReadAloudBrowserRequest(action: .speak, id: id, text: text))
        XCTAssertEqual(accepted["state"] as? String, "preparing")
        XCTAssertEqual(accepted["totalChunks"] as? Int, total)
        wait(for: [done], timeout: 10)
        XCTAssertEqual(playing, Array(1...total))
        let state = controller.browserCommand(ReadAloudBrowserRequest(action: .status, id: id, text: nil))
        XCTAssertEqual(state["state"] as? String, "idle")
        XCTAssertEqual(state["completedChunks"] as? Int, total)
    }

    func testCancelDropsRemainingChunks() throws {
        let (folder, controller) = try fixture()
        defer { controller.onUpdate = nil; controller.shutdown(); try? FileManager.default.removeItem(at: folder) }
        let id = UUID()
        let done = expectation(description: "Cancellation remains idle")
        var playing = 0
        controller.onUpdate = { message, _ in
            if message.hasPrefix("Türkçe okunuyor") {
                playing += 1
                _ = controller.browserCommand(ReadAloudBrowserRequest(action: .stop, id: id, text: nil))
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { done.fulfill() }
            }
        }
        _ = controller.browserCommand(ReadAloudBrowserRequest(action: .speak, id: id,
            text: String(repeating: "Merhaba dünya. ", count: 80)))
        wait(for: [done], timeout: 5)
        XCTAssertEqual(playing, 1)
        XCTAssertFalse(controller.isBusy)
    }

    func testPausePreservesPositionAndResumeContinuesSameChunk() throws {
        let (folder, controller) = try fixture(duration: 1)
        defer { controller.onUpdate = nil; controller.shutdown(); try? FileManager.default.removeItem(at: folder) }
        let id = UUID()
        let done = expectation(description: "Paused position preserved and resumed")
        var scheduled = false
        controller.onError = { XCTFail($0) }
        controller.onUpdate = { message, _ in
            guard message.hasPrefix("Türkçe okunuyor"), !scheduled else { return }
            scheduled = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                let paused = controller.browserCommand(.init(action: .pause, id: id, text: nil))
                XCTAssertEqual(paused["state"] as? String, "paused")
                let position = paused["positionSeconds"] as? Double ?? -1
                XCTAssertGreaterThan(position, 0.05)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                    let state = controller.browserCommand(.init(action: .status, id: id, text: nil))
                    XCTAssertEqual(state["state"] as? String, "paused")
                    XCTAssertEqual(state["currentChunk"] as? Int, 1)
                    XCTAssertEqual(state["positionSeconds"] as? Double ?? -2, position, accuracy: 0.03)
                    _ = controller.browserCommand(.init(action: .resume, id: UUID(), text: nil))
                    XCTAssertEqual(controller.browserCommand(.init(action: .status, id: id, text: nil))["state"] as? String, "paused")
                    let resumed = controller.browserCommand(.init(action: .resume, id: id, text: nil))
                    XCTAssertEqual(resumed["state"] as? String, "playing")
                    XCTAssertGreaterThanOrEqual(resumed["positionSeconds"] as? Double ?? -2, position - 0.03)
                    _ = controller.browserCommand(.init(action: .pause, id: UUID(), text: nil))
                    XCTAssertEqual(controller.browserCommand(.init(action: .status, id: id, text: nil))["state"] as? String, "playing")
                    done.fulfill()
                }
            }
        }
        _ = controller.browserCommand(.init(action: .speak, id: id, text: String(repeating: "Merhaba dünya. ", count: 80)))
        wait(for: [done], timeout: 5)
    }

    func testPauseDuringPreparationHoldsAudioAndCanStop() throws {
        let (folder, controller) = try fixture(duration: 1, delay: 0.2)
        defer { controller.onUpdate = nil; controller.shutdown(); try? FileManager.default.removeItem(at: folder) }
        let id = UUID()
        let done = expectation(description: "Prepared audio stays paused")
        _ = controller.browserCommand(.init(action: .speak, id: id, text: String(repeating: "Merhaba dünya. ", count: 80)))
        XCTAssertEqual(controller.browserCommand(.init(action: .pause, id: id, text: nil))["state"] as? String, "paused")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
            let state = controller.browserCommand(.init(action: .status, id: id, text: nil))
            XCTAssertEqual(state["state"] as? String, "paused")
            XCTAssertEqual(state["positionSeconds"] as? Double, 0)
            XCTAssertEqual(state["completedChunks"] as? Int, 0)
            XCTAssertEqual(controller.browserCommand(.init(action: .resume, id: id, text: nil))["state"] as? String, "playing")
            XCTAssertEqual(controller.browserCommand(.init(action: .pause, id: id, text: nil))["state"] as? String, "paused")
            _ = controller.browserCommand(.init(action: .stop, id: id, text: nil))
            XCTAssertFalse(controller.isBusy)
            XCTAssertEqual(controller.browserCommand(.init(action: .resume, id: id, text: nil))["state"] as? String, "idle")
            done.fulfill()
        }
        wait(for: [done], timeout: 5)
    }
}
