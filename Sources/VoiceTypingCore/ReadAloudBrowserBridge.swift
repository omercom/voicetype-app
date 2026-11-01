import Foundation
import Darwin

struct ReadAloudBrowserRequest: Decodable {
    enum Action: String, Decodable { case speak, stop, pause, resume, status }
    let action: Action
    let id: UUID
    let text: String?

    func validatedText() throws -> String {
        guard action == .speak, let text else { throw ReadAloudError.message("Geçersiz tarayıcı komutu.") }
        return try ReadAloudText.validated(text)
    }
}

/// A private Unix socket, not a web server. Only peers belonging to this user are accepted.
final class ReadAloudBrowserBridge {
    var onCommand: ((ReadAloudBrowserRequest) -> [String: Any])?
    private let queue = DispatchQueue(label: "com.voicetyping.browser-accept")
    private let clients = DispatchQueue(label: "com.voicetyping.browser-client", attributes: .concurrent)
    private var source: DispatchSourceRead?
    private var generation = UUID()
    private var socketURL: URL?
    static let maximumBytes = 262144

    func start(at customURL: URL? = nil) throws {
        guard source == nil else { return }
        let url = customURL ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".voice_typing/tts/browser.sock")
        let folder = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        if let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) {
            guard attributes[.type] as? FileAttributeType == .typeSocket,
                  (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == getuid() else {
                throw ReadAloudError.message("Tarayıcı kanalı güvenli biçimde açılamadı.")
            }
            try FileManager.default.removeItem(at: url)
        }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let path = Array(url.path.utf8) + [0]
        guard path.count <= MemoryLayout.size(ofValue: address.sun_path) else {
            throw ReadAloudError.message("Tarayıcı kanalı yolu çok uzun.")
        }
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in buffer.copyBytes(from: path) }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw ReadAloudError.message("Tarayıcı kanalı oluşturulamadı.") }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0, chmod(url.path, 0o600) == 0, listen(fd, 8) == 0,
              fcntl(fd, F_SETFL, O_NONBLOCK) == 0 else {
            close(fd)
            if bound == 0 { unlink(url.path) }
            throw ReadAloudError.message("Tarayıcı kanalı açılamadı.")
        }
        socketURL = url
        let token = UUID()
        generation = token
        let listener = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        listener.setEventHandler { [weak self] in
            for _ in 0..<8 {
                let client = accept(fd, nil, nil)
                guard client >= 0 else { break }
                guard let self else { close(client); continue }
                self.clients.async { [weak self] in
                    guard let self else { close(client); return }
                    self.receive(client, token: token)
                }
            }
        }
        listener.setCancelHandler { close(fd) }
        source = listener
        listener.resume()
    }

    private func receive(_ fd: Int32, token: UUID) {
        var uid: uid_t = 0, gid: gid_t = 0
        guard getpeereid(fd, &uid, &gid) == 0, uid == getuid() else { close(fd); return }
        _ = fcntl(fd, F_SETFL, 0)
        var timeout = timeval(tv_sec: 2, tv_usec: 0)
        var noSignal: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)
        while buffer.count <= Self.maximumBytes {
            let count = recv(fd, &chunk, chunk.count, 0)
            guard count > 0 else { close(fd); return }
            buffer.append(contentsOf: chunk.prefix(count))
            guard buffer.count <= Self.maximumBytes else { break }
            if let newline = buffer.firstIndex(of: 10) {
                guard let request = try? JSONDecoder().decode(ReadAloudBrowserRequest.self, from: buffer.prefix(upTo: newline)) else {
                    Self.reply(["ok": false, "error": "Geçersiz tarayıcı komutu."], fd: fd)
                    return
                }
                DispatchQueue.main.async { [weak self] in
                    let response: [String: Any]
                    if let self, self.generation == token, let command = self.onCommand {
                        response = command(request)
                    } else { response = ["ok": false, "error": "VoiceType bağlantısı kapandı."] }
                    DispatchQueue.global(qos: .userInitiated).async { Self.reply(response, fd: fd) }
                }
                return
            }
        }
        Self.reply(["ok": false, "error": "Tarayıcı isteği çok büyük."], fd: fd)
    }

    private static func reply(_ response: [String: Any], fd: Int32) {
        defer { close(fd) }
        guard var data = try? JSONSerialization.data(withJSONObject: response) else { return }
        data.append(10)
        data.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            var sent = 0
            while sent < bytes.count {
                let count = send(fd, base.advanced(by: sent), bytes.count - sent, 0)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { return }
                sent += count
            }
        }
    }

    func stop() {
        generation = UUID()
        source?.cancel()
        source = nil
        if let socketURL { unlink(socketURL.path) }
        socketURL = nil
    }

    deinit { stop() }
}
