import Foundation
import Darwin

/// CPU-only local STT. A reusable worker keeps the model loaded between dictations.
final class SedaTranscriber {
    static let model = "atasoglu/seda-v0.2"
    static let revision = "62e2cc1615a63c433b6956214a548267ada5a774"
    static let runtimeURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".voice_typing/stt/seda-v0.2")
    private let pythonURL: URL
    private let workerURL: URL?
    private let timeoutSeconds: Double
    private let queue = DispatchQueue(label: "com.voicetyping.seda", qos: .userInitiated)
    private let lock = NSLock()
    private var generation = UUID()
    private var process: Process?
    private var inputPipe: Pipe?
    private var outputPipe: Pipe?
    private var responseBuffer = Data()
    private var isBusy = false
    private var workerUsable = false

    init(pythonURL: URL? = nil, workerURL: URL? = nil, timeoutSeconds: Double = 90) {
        self.pythonURL = pythonURL ?? Self.runtimeURL.appendingPathComponent(".venv/bin/python")
        self.workerURL = workerURL ?? VoiceTypeResources.url(forResource: "seda_worker", withExtension: "py")
        self.timeoutSeconds = timeoutSeconds
    }

    deinit {
        try? inputPipe?.fileHandleForWriting.close()
        if let process { stopLocked(process) }
    }

    static func supportsLanguage(_ language: String) -> Bool {
        ["tr", "tr-tr", "tr_tr"].contains(language.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
    }

    static let requiredModelFiles = [
        "encoder.int8.onnx", "decoder.onnx", "joiner.int8.onnx", "tokens.txt", "lm/rnnlm.int8.onnx", "lm/2gram.fst"
    ]

    static func isInstalled(
        runtimeURL: URL = runtimeURL,
        workerURL: URL? = VoiceTypeResources.url(forResource: "seda_worker", withExtension: "py")
    ) -> Bool {
        struct Installation: Decodable {
            let model: String
            let revision: String
        }
        let python = runtimeURL.appendingPathComponent(".venv/bin/python")
        let snapshot = runtimeURL.appendingPathComponent("models/models--atasoglu--seda-v0.2/snapshots/\(revision)")
        guard let data = try? Data(contentsOf: runtimeURL.appendingPathComponent("ready.json")),
              let installation = try? JSONDecoder().decode(Installation.self, from: data),
              installation.model == model, installation.revision == revision else { return false }
        return FileManager.default.isExecutableFile(atPath: python.path)
            && requiredModelFiles.allSatisfy { FileManager.default.isReadableFile(atPath: snapshot.appendingPathComponent($0).path) }
            && workerURL.map { FileManager.default.isReadableFile(atPath: $0.path) } == true
    }

    static func readinessMessage(language: String) -> String? {
        guard supportsLanguage(language) else { return "Seda-v0.2 yalnızca Türkçe destekler. Dil ayarını tr yapın." }
        guard isInstalled() else { return "Seda-v0.2 kurulmadı. Önce setup-stt.sh çalıştırın." }
        return nil
    }

    func cancel() {
        lock.lock()
        generation = UUID()
        if let process { stopLocked(process) }
        lock.unlock()
    }

    /// Called under lock. SIGKILL bounds shutdown even if native inference stalls.
    private func stopLocked(_ task: Process) {
        workerUsable = false
        guard task.isRunning else { return }
        task.terminate()
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
            if task.isRunning { Darwin.kill(task.processIdentifier, SIGKILL) }
        }
    }

    private struct WorkerResponse: Decodable {
        let ready: Bool?
        let text: String?
        let error: String?
        let event: String?
        let id: UUID?
    }

    private func readResponse(_ output: FileHandle) throws -> WorkerResponse {
        while true {
            if let newline = responseBuffer.firstIndex(of: 10) {
                let line = Data(responseBuffer.prefix(upTo: newline))
                responseBuffer.removeSubrange(...newline)
                guard let response = try? JSONDecoder().decode(WorkerResponse.self, from: line) else {
                    throw SedaError.message("Seda-v0.2 yanıtı okunamadı.")
                }
                return response
            }
            let chunk = output.availableData
            guard !chunk.isEmpty else {
                throw SedaError.message("Seda-v0.2 kapandı veya zaman aşımına uğradı. setup-stt.sh ile kontrol edin.")
            }
            responseBuffer.append(chunk)
            guard responseBuffer.count <= 65536 else { throw SedaError.message("Seda-v0.2 yanıtı çok büyük.") }
        }
    }

    private func ensureWorker(token: UUID) throws -> (Process, FileHandle, FileHandle, Bool) {
        guard FileManager.default.isExecutableFile(atPath: pythonURL.path), workerURL != nil else {
            throw SedaError.message("Seda-v0.2 kurulmadı. Önce setup-stt.sh çalıştırın.")
        }
        lock.lock()
        guard generation == token else { lock.unlock(); throw SedaError.message("Dikte iptal edildi.") }
        let isNew = !workerUsable || process?.isRunning != true
        if isNew {
            try? inputPipe?.fileHandleForWriting.close()
            try? outputPipe?.fileHandleForReading.close()
            let task = Process(), input = Pipe(), output = Pipe()
            task.executableURL = pythonURL
            task.arguments = ["-u", workerURL!.path, "--serve"]
            var environment = ProcessInfo.processInfo.environment
            environment["HF_HUB_OFFLINE"] = "1"
            environment["HF_HUB_DISABLE_TELEMETRY"] = "1"
            environment["VOICETYPE_SEDA_HOME"] = Self.runtimeURL.path
            task.environment = environment
            task.standardInput = input
            task.standardOutput = output
            task.standardError = FileHandle.nullDevice
            _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
            do { try task.run() }
            catch { lock.unlock(); throw SedaError.message("Seda-v0.2 başlatılamadı. setup-stt.sh ile kontrol edin.") }
            process = task; inputPipe = input; outputPipe = output
            responseBuffer.removeAll(); workerUsable = true
        }
        let task = process!, input = inputPipe!.fileHandleForWriting, output = outputPipe!.fileHandleForReading
        lock.unlock()
        return (task, input, output, isNew)
    }

    private func runPersistent(audioURL: URL, token: UUID) throws -> String {
        let (task, input, output, isNew) = try ensureWorker(token: token)
        var succeeded = false
        let timer = DispatchSource.makeTimerSource(queue: .global())
        timer.schedule(deadline: .now() + timeoutSeconds)
        timer.setEventHandler {
            self.lock.lock()
            if self.process === task, self.generation == token { self.stopLocked(task) }
            self.lock.unlock()
        }
        timer.resume()
        defer {
            timer.cancel()
            if !succeeded {
                lock.lock(); stopLocked(task); lock.unlock()
                task.waitUntilExit()
                try? input.close(); try? output.close()
                lock.lock()
                if process === task { process = nil; inputPipe = nil; outputPipe = nil }
                lock.unlock()
            }
        }
        if isNew, try readResponse(output).ready != true { throw SedaError.message("Seda-v0.2 yüklenemedi.") }
        let request = try JSONSerialization.data(withJSONObject: ["audio": audioURL.path]) + Data([10])
        lock.lock()
        guard generation == token, task.isRunning, workerUsable else { lock.unlock(); throw SedaError.message("Dikte iptal edildi.") }
        do { try input.write(contentsOf: request); lock.unlock() }
        catch { lock.unlock(); throw SedaError.message("Seda-v0.2 bağlantısı kapandı.") }
        let response = try readResponse(output)
        guard let text = response.text else { throw SedaError.message(response.error ?? "Seda-v0.2 yanıtı okunamadı.") }
        succeeded = true
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func runLive(_ session: LiveSedaStreamSession, token: UUID) throws -> String {
        let (task, input, output, isNew) = try ensureWorker(token: token)
        var succeeded = false
        let timer = DispatchSource.makeTimerSource(queue: .global())
        timer.schedule(deadline: .now() + timeoutSeconds)
        timer.setEventHandler {
            self.lock.lock()
            if self.process === task, self.generation == token { self.stopLocked(task) }
            self.lock.unlock()
        }
        timer.resume()
        defer {
            timer.cancel()
            if !succeeded {
                lock.lock(); stopLocked(task); lock.unlock()
                task.waitUntilExit()
                try? input.close(); try? output.close()
                lock.lock()
                if process === task { process = nil; inputPipe = nil; outputPipe = nil }
                lock.unlock()
            }
        }
        if isNew, try readResponse(output).ready != true { throw SedaError.message("Seda-v0.2 yüklenemedi.") }
        // Recording duration is separate from model-start and finish timeouts.
        timer.schedule(deadline: .now() + 600 + timeoutSeconds)
        session.attach(writer: { [weak self] message in
            guard self?.isCurrent(token) == true, task.isRunning else {
                throw SedaError.message("Seda-v0.2 canlı oturumu kapandı.")
            }
            let data = try JSONSerialization.data(withJSONObject: message) + Data([10])
            try input.write(contentsOf: data)
        }, onFinish: { timer.schedule(deadline: .now() + self.timeoutSeconds) },
        onFailure: { [weak self] in self?.stopWorker(token: token) })
        while true {
            let response = try readResponse(output)
            if let error = response.error { throw SedaError.message(error) }
            guard response.id == token else { throw SedaError.message("Seda-v0.2 oturum yanıtı geçersiz.") }
            switch response.event {
            case "started": break
            case "interim":
                guard let text = response.text else { throw SedaError.message("Seda-v0.2 canlı metni eksik.") }
                session.receiveInterim(text)
            case "final":
                guard session.hasSentFinish else { throw SedaError.message("Seda-v0.2 canlı oturumu erken sonlandı.") }
                guard let text = response.text else { throw SedaError.message("Seda-v0.2 nihai metni eksik.") }
                succeeded = true
                return text
            default: throw SedaError.message("Seda-v0.2 canlı yanıtı okunamadı.")
            }
        }
    }

    private func run(audioData: Data, token: UUID) throws -> String {
        guard FileManager.default.isExecutableFile(atPath: pythonURL.path), workerURL != nil else {
            throw SedaError.message("Seda-v0.2 kurulmadı. Önce setup-stt.sh çalıştırın.")
        }
        guard audioData.count > 44, audioData.count <= 20_000_000,
              audioData.prefix(4) == Data("RIFF".utf8) else {
            throw SedaError.message("Seda-v0.2 için geçerli bir WAV kaydı gerekir (en fazla 20 MB).")
        }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("voicetype-seda-\(token)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: folder) }
        let audioURL = folder.appendingPathComponent("audio.wav")
        try audioData.write(to: audioURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: audioURL.path)
        return try runPersistent(audioURL: audioURL, token: token)
    }

    private func isCurrent(_ token: UUID) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return generation == token
    }

    private func stopWorker(token: UUID) {
        lock.lock()
        if generation == token, let process { stopLocked(process) }
        lock.unlock()
    }

    func startLive(language: String, onInterim: ((String) -> Void)?,
                   completion: @escaping (TranscriptionResult) -> Void) -> LiveSedaStreamSession {
        lock.lock()
        if isBusy, let process { stopLocked(process) }
        generation = UUID()
        isBusy = true
        let token = generation
        lock.unlock()
        let session = LiveSedaStreamSession(id: token, onInterim: { [weak self] text in
            guard self?.isCurrent(token) == true else { return }
            onInterim?(text)
        }, completion: { [weak self] result in
            guard self?.isCurrent(token) == true else { return }
            completion(result)
        }, cancelWorker: { [weak self] in self?.stopWorker(token: token) })
        queue.async {
            do {
                guard Self.supportsLanguage(language) else {
                    throw SedaError.message("Seda-v0.2 yalnızca Türkçe destekler. Dil ayarını tr yapın.")
                }
                let text = try self.runLive(session, token: token)
                self.lock.lock()
                if self.generation == token { self.isBusy = false }
                self.lock.unlock()
                session.complete(text: text)
            } catch {
                self.lock.lock()
                if self.generation == token { self.isBusy = false }
                self.lock.unlock()
                session.complete(error: error.localizedDescription)
            }
        }
        return session
    }

    func transcribe(audioData: Data, language: String, completion: @escaping (TranscriptionResult) -> Void) {
        lock.lock()
        if isBusy, let process { stopLocked(process) }
        generation = UUID()
        isBusy = true
        let token = generation
        lock.unlock()
        queue.async {
            let start = ProcessInfo.processInfo.systemUptime
            var result: TranscriptionResult
            do {
                guard Self.supportsLanguage(language) else {
                    throw SedaError.message("Seda-v0.2 yalnızca Türkçe destekler. Dil ayarını tr yapın.")
                }
                let text = try self.run(audioData: audioData, token: token)
                result = TranscriptionResult(success: true, text: text, latency: 0, provider: "seda", model: Self.model)
            } catch {
                result = TranscriptionResult(success: false, text: "", latency: 0,
                                             error: error.localizedDescription, provider: "seda", model: Self.model)
            }
            result.latency = ProcessInfo.processInfo.systemUptime - start
            let finalResult = result
            self.lock.lock()
            if self.generation == token { self.isBusy = false }
            self.lock.unlock()
            DispatchQueue.main.async {
                self.lock.lock()
                let current = self.generation == token
                self.lock.unlock()
                if current { completion(finalResult) }
            }
        }
    }
}

private enum SedaError: LocalizedError {
    case message(String)
    var errorDescription: String? {
        if case .message(let message) = self { return message }
        return nil
    }
}
