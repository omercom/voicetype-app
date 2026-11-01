import Foundation

struct ReadAloudWorkerEvent: Decodable {
    let event: String
    let id: UUID?
    let path: String?
    let duration: Double?
    let message: String?
    let device: String?
}

enum ReadAloudText {
    static let maximumCharacters = 30000

    static func validated(_ text: String) throws -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ReadAloudError.message("Önce bir metin seçin veya kopyalayın.") }
        guard trimmed.unicodeScalars.count <= maximumCharacters else {
            throw ReadAloudError.message("Seslendirme en fazla 30.000 karakter kabul eder. Daha küçük bir bölüm seçin.")
        }
        return trimmed
    }

    /// Bound each synthesis request so playback starts before the whole document is produced.
    static func chunks(_ text: String, limit: Int = 350) -> [String] {
        precondition(limit > 0)
        let scalars = Array(text.unicodeScalars)
        var result: [String] = []
        var start = 0
        while start < scalars.count {
            var end = min(start + limit, scalars.count)
            if end < scalars.count {
                let candidates = (start..<end).reversed()
                let sentence = candidates.first { index in
                    index > start + limit / 3 && ".!?\n".unicodeScalars.contains(scalars[index])
                        && CharacterSet.whitespacesAndNewlines.contains(scalars[index + 1])
                }
                let space = candidates.first { CharacterSet.whitespacesAndNewlines.contains(scalars[$0]) }
                if let cut = sentence ?? space { end = cut + 1 }
            }
            let part = String(String.UnicodeScalarView(scalars[start..<end]))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !part.isEmpty { result.append(part) }
            start = end
        }
        return result
    }
}

enum ReadAloudError: LocalizedError {
    case message(String)
    var errorDescription: String? {
        if case .message(let value) = self { return value }
        return nil
    }
}

/// All lifecycle and callbacks run on the main thread. stdout carries no user text.
final class ReadAloudEngine {
    var onReady: ((String) -> Void)?
    var onAudio: ((UUID, URL, Double) -> Void)?
    var onFailure: ((UUID?, String) -> Void)?
    private(set) var isReady = false
    private var process: Process?
    private var input: Pipe?
    private var output: Pipe?
    private var buffer = Data()
    private var directory: URL?
    private var session = UUID()
    private var pending: (id: UUID, text: String)?
    private var timeout: DispatchWorkItem?
    private let pythonURL: URL
    private let workerURL: URL?

    init(pythonURL: URL? = nil, workerURL: URL? = nil) {
        self.pythonURL = pythonURL ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".voice_typing/tts/.venv/bin/python")
        self.workerURL = workerURL ?? Bundle.module.url(forResource: "antalia_worker", withExtension: "py")
    }

    var isInstalled: Bool { FileManager.default.isExecutableFile(atPath: pythonURL.path) && workerURL != nil }

    func prepare() {
        guard process == nil else { return }
        guard isInstalled, let workerURL else {
            onFailure?(pending?.id, "Antalia Mini kurulmadı. Önce setup-tts.sh çalıştırın.")
            pending = nil
            return
        }
        let token = UUID()
        session = token
        let task = Process()
        let stdin = Pipe(), stdout = Pipe()
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("voicetype-tts-\(token)")
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            var environment = ProcessInfo.processInfo.environment
            environment["HF_HUB_OFFLINE"] = "1"
            environment["PYTHONUNBUFFERED"] = "1"
            environment["VOICETYPE_TTS_OUTPUT"] = folder.path
            task.executableURL = pythonURL
            task.arguments = ["-u", workerURL.path]
            task.environment = environment
            task.standardInput = stdin
            task.standardOutput = stdout
            task.standardError = FileHandle.nullDevice
            directory = folder
            process = task
            input = stdin
            output = stdout
            stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
                let data = handle.availableData
                DispatchQueue.main.async { self?.receive(data, session: token) }
            }
            task.terminationHandler = { [weak self] _ in
                DispatchQueue.main.async {
                    guard let self, self.session == token else { return }
                    self.fail("Antalia Mini süreci kapandı. Yeniden seslendirmeyi deneyin.")
                }
            }
            try task.run()
            armTimeout()
        } catch {
            fail("Antalia Mini başlatılamadı. setup-tts.sh ile kurulumu kontrol edin.")
        }
    }

    func synthesize(_ text: String, id: UUID) {
        pending = (id, text)
        if isReady { sendPending() } else { prepare() }
    }

    private func sendPending() {
        guard let pending, let input else { return }
        do {
            var data = try JSONSerialization.data(withJSONObject: ["id": pending.id.uuidString, "text": pending.text])
            data.append(0x0A)
            try input.fileHandleForWriting.write(contentsOf: data)
            armTimeout()
        } catch {
            fail("Seslendirme isteği gönderilemedi.")
        }
    }

    private func receive(_ data: Data, session token: UUID) {
        guard session == token, !data.isEmpty else { return }
        buffer.append(data)
        guard buffer.count <= 65536 else { fail("Antalia Mini yanıtı geçersiz."); return }
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer.prefix(upTo: newline)
            buffer.removeSubrange(...newline)
            guard let event = try? JSONDecoder().decode(ReadAloudWorkerEvent.self, from: line) else {
                fail("Antalia Mini yanıtı okunamadı.")
                return
            }
            switch event.event {
            case "ready":
                isReady = true
                timeout?.cancel()
                onReady?(event.device ?? "cpu")
                sendPending()
            case "audio":
                guard let id = event.id, pending?.id == id, let directory,
                      let path = event.path, let duration = event.duration,
                      duration.isFinite, duration > 0,
                      Self.isExpectedAudioPath(path, id: id, directory: directory) else {
                    fail("Antalia Mini ses çıktısı geçersiz.")
                    return
                }
                timeout?.cancel()
                pending = nil
                onAudio?(id, URL(fileURLWithPath: path), duration)
            case "error":
                fail(event.message ?? "Antalia Mini ses üretemedi.")
                return
            default:
                fail("Antalia Mini olay türü geçersiz.")
                return
            }
        }
    }

    static func isExpectedAudioPath(_ path: String, id: UUID, directory: URL) -> Bool {
        let expected = directory.appendingPathComponent("\(id.uuidString.lowercased()).wav").standardizedFileURL
        return URL(fileURLWithPath: path).standardizedFileURL == expected
    }

    private func armTimeout() {
        timeout?.cancel()
        let token = session
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.session == token else { return }
            self.fail("Seslendirme zaman aşımına uğradı.")
        }
        timeout = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 90, execute: work)
    }

    private func fail(_ message: String) {
        let id = pending?.id
        shutdown()
        onFailure?(id, message)
    }

    func shutdown() {
        session = UUID()
        timeout?.cancel()
        timeout = nil
        pending = nil
        isReady = false
        output?.fileHandleForReading.readabilityHandler = nil
        try? input?.fileHandleForWriting.close()
        if let process, process.isRunning { process.terminate() }
        process = nil
        input = nil
        output = nil
        buffer.removeAll()
        if let directory { try? FileManager.default.removeItem(at: directory) }
        directory = nil
    }
}
