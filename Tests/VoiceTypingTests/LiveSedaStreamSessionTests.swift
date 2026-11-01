import XCTest
import AppKit
@testable import VoiceTypingCore

final class LiveSedaStreamSessionTests: XCTestCase {
    func testLiveInterimAppearsInPillAndNotchHUD() throws {
        let original = ConfigManager.shared.config.hud_style
        let hud = RecordingHUD.shared
        defer { hud.dismiss(animated: false); ConfigManager.shared.update { $0.hud_style = original } }
        func labels(_ view: NSView) -> [NSTextField] {
            (view as? NSTextField).map { [$0] } ?? view.subviews.flatMap { labels($0) }
        }
        for style in ["pill", "notch"] {
            ConfigManager.shared.update { $0.hud_style = style }
            hud.dismiss(animated: false)
            hud.showRecording()
            let shown = expectation(description: "HUD interim")
            let session = LiveSedaStreamSession(id: UUID(), onInterim: { text in
                hud.updateInterimText(text)
                shown.fulfill()
            }, completion: { _ in }, cancelWorker: {})
            session.receiveInterim("merhaba dünya")
            wait(for: [shown], timeout: 2)
            hud.finishPresentationTransitions()
            let root = try XCTUnwrap(hud.rootContentView)
            XCTAssertTrue(hud.isVisible)
            XCTAssertTrue(labels(root).contains { $0.stringValue == "merhaba dünya" && !$0.isHidden })
            hud.showTranscribing()
            XCTAssertTrue(labels(root).contains { $0.stringValue == "merhaba dünya" })
            session.cancel()
        }
    }

    func testColdBufferPreservesFIFOAndFinalShortChunk() {
        let flushed = expectation(description: "flushed")
        let session = LiveSedaStreamSession(id: UUID(), onInterim: nil, completion: { _ in }, cancelWorker: {})
        let pcm = Data(repeating: 17, count: 6400) + Data(repeating: 0, count: 1280)
        session.sendAudioChunk(pcm)
        session.finishAudio()
        session.finishAudio()
        session.sendAudioChunk(Data(repeating: 99, count: 3200))
        var operations: [String] = []
        var received = Data()
        session.attach(writer: { command in
            operations.append(command["op"] as! String)
            if let encoded = command["pcm"] as? String { received.append(Data(base64Encoded: encoded)!) }
            if command["op"] as? String == "finish" { flushed.fulfill() }
        }, onFinish: {}, onFailure: { XCTFail("unexpected failure") })
        wait(for: [flushed], timeout: 2)
        XCTAssertEqual(operations, ["start", "audio", "audio", "audio", "finish"])
        XCTAssertEqual(received, pcm)
        XCTAssertTrue(session.hasSentFinish)
        session.cancel()
    }

    func testInvalidPCMBeforeAttachFailsOnce() {
        let failed = expectation(description: "failed")
        let stopped = expectation(description: "stopped")
        let session = LiveSedaStreamSession(id: UUID(), onInterim: nil, completion: { result in
            XCTAssertFalse(result.success)
            failed.fulfill()
        }, cancelWorker: {})
        session.sendAudioChunk(Data([1]))
        session.finishAudio()
        session.attach(writer: { _ in XCTFail("invalid PCM must not be sent") }, onFinish: {}, onFailure: { stopped.fulfill() })
        wait(for: [failed, stopped], timeout: 2)
    }

    func testCancelSuppressesQueuedCallbacksAndCompletionIsUnique() {
        let stale = expectation(description: "stale callbacks")
        stale.isInverted = true
        let session = LiveSedaStreamSession(id: UUID(), onInterim: { _ in stale.fulfill() },
                                            completion: { _ in stale.fulfill() }, cancelWorker: {})
        session.receiveInterim("eski")
        session.complete(text: "eski")
        session.complete(text: "tekrar")
        session.cancel()
        wait(for: [stale], timeout: 0.2)
    }
}
