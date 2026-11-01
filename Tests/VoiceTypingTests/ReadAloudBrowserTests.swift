import XCTest
import Darwin
@testable import VoiceTypingCore

final class ReadAloudBrowserTests: XCTestCase {
    func testCommandsAndTextLimits() throws {
        let id = UUID().uuidString
        func decode(_ action: String, _ text: String = "Merhaba.") throws -> ReadAloudBrowserRequest {
            let data = try JSONSerialization.data(withJSONObject: ["action": action, "id": id, "text": text])
            return try JSONDecoder().decode(ReadAloudBrowserRequest.self, from: data)
        }
        XCTAssertEqual(try decode("speak").validatedText(), "Merhaba.")
        XCTAssertThrowsError(try decode("execute"))
        XCTAssertThrowsError(try decode("stop").validatedText())
        XCTAssertThrowsError(try decode("speak", " ").validatedText())
        XCTAssertEqual(try decode("speak", String(repeating: "ş", count: 30000)).validatedText().count, 30000)
        XCTAssertThrowsError(try decode("speak", String(repeating: "ş", count: 30001)).validatedText())
        XCTAssertThrowsError(try JSONDecoder().decode(ReadAloudBrowserRequest.self,
            from: Data("{\"action\":\"status\",\"id\":12}".utf8)))
    }

    func testSocketRoundTripAndCleanup() throws {
        let folder = URL(fileURLWithPath: "/tmp/vtb-" + UUID().uuidString.prefix(8))
        let url = folder.appendingPathComponent("browser.sock")
        defer { try? FileManager.default.removeItem(at: folder) }
        let bridge = ReadAloudBrowserBridge()
        defer { bridge.stop() }
        let id = UUID()
        bridge.onCommand = { request in
            XCTAssertTrue(Thread.isMainThread)
            XCTAssertEqual(request.id, id)
            XCTAssertEqual(request.text, "Merhaba dünya.")
            return ["ok": true, "state": "playing"]
        }
        try bridge.start(at: url)
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        let done = expectation(description: "Unix command round trip")
        DispatchQueue.global().async {
            let fd = socket(AF_UNIX, SOCK_STREAM, 0)
            defer { close(fd); done.fulfill() }
            var address = sockaddr_un()
            address.sun_family = sa_family_t(AF_UNIX)
            address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
            withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: Array(url.path.utf8) + [0]) }
            let connected = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            guard connected == 0 else { XCTFail("Cannot connect"); return }
            var timeout = timeval(tv_sec: 3, tv_usec: 0)
            setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
            let data = try! JSONSerialization.data(withJSONObject:
                ["action": "speak", "id": id.uuidString, "text": "Merhaba dünya."]) + Data([10])
            data.withUnsafeBytes { XCTAssertEqual(send(fd, $0.baseAddress, $0.count, 0), $0.count) }
            var buffer = [UInt8](repeating: 0, count: 4096)
            let count = recv(fd, &buffer, buffer.count, 0)
            guard count > 0 else { XCTFail("No response"); return }
            let response = try? JSONSerialization.jsonObject(with: Data(buffer.prefix(count))) as? [String: Any]
            XCTAssertEqual(response?["state"] as? String, "playing")
        }
        wait(for: [done], timeout: 5)
        bridge.stop()
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testDoesNotReplaceRegularFile() throws {
        let folder = URL(fileURLWithPath: "/tmp/vtb-" + UUID().uuidString.prefix(8))
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("browser.sock")
        try Data("keep".utf8).write(to: url)
        let bridge = ReadAloudBrowserBridge()
        XCTAssertThrowsError(try bridge.start(at: url))
        bridge.stop()
        XCTAssertEqual(try Data(contentsOf: url), Data("keep".utf8))
    }

    func testForeignStopDoesNotOwnController() {
        let controller = ReadAloudController(engine: ReadAloudEngine(pythonURL: URL(fileURLWithPath: "/missing")))
        let request = ReadAloudBrowserRequest(action: .stop, id: UUID(), text: nil)
        XCTAssertEqual(controller.browserCommand(request)["state"] as? String, "idle")
        let speak = ReadAloudBrowserRequest(action: .speak, id: UUID(), text: "Merhaba.")
        XCTAssertEqual(controller.browserCommand(speak)["ok"] as? Bool, false)
        controller.shutdown()
    }
}
