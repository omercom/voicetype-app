import Foundation

/// Serial transport preserves every PCM block, including silence and the final tail.
final class LiveSedaStreamSession: LiveStreamSession {
    let id: UUID
    private let queue = DispatchQueue(label: "com.voicetyping.seda.stream", qos: .userInitiated)
    private let lock = NSLock()
    private var cancelled = false
    private var terminal = false
    private var finishTime: TimeInterval?
    private var finishSent = false
    private let startTime = ProcessInfo.processInfo.systemUptime
    private var acceptingAudio = true
    private var byteCount = 0
    private var pending: [Command] = []
    private var writer: (([String: Any]) throws -> Void)?
    private var onFinish: (() -> Void)?
    private var onTransportFailure: (() -> Void)?
    private let onInterim: ((String) -> Void)?
    private let completion: (TranscriptionResult) -> Void
    private let cancelWorker: () -> Void

    private enum Command { case audio(Data), finish }

    init(id: UUID, onInterim: ((String) -> Void)?, completion: @escaping (TranscriptionResult) -> Void,
         cancelWorker: @escaping () -> Void) {
        self.id = id
        self.onInterim = onInterim
        self.completion = completion
        self.cancelWorker = cancelWorker
    }

    private var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return cancelled
    }

    private var isStopped: Bool {
        lock.lock(); defer { lock.unlock() }
        return cancelled || terminal
    }

    var finalLatency: Double {
        lock.lock(); defer { lock.unlock() }
        return ProcessInfo.processInfo.systemUptime - (finishTime ?? startTime)
    }

    var hasSentFinish: Bool {
        lock.lock(); defer { lock.unlock() }
        return finishSent
    }

    func sendAudioChunk(_ chunk: Data) {
        guard !chunk.isEmpty else { return }
        queue.async {
            guard !self.isStopped, self.acceptingAudio else { return }
            self.byteCount += chunk.count
            guard chunk.count % 2 == 0, self.byteCount <= 19_200_000 else {
                self.failTransport("Seda-v0.1 geçerli PCM16 ve en fazla 10 dakika ses kabul eder.")
                return
            }
            // Even callers with large buffers use bounded 100 ms protocol packets.
            for offset in stride(from: 0, to: chunk.count, by: 3200) {
                self.sendOrBuffer(.audio(Data(chunk[offset..<min(offset + 3200, chunk.count)])))
            }
        }
    }

    func finishAudio() {
        lock.lock()
        if finishTime == nil { finishTime = ProcessInfo.processInfo.systemUptime }
        lock.unlock()
        queue.async {
            guard !self.isStopped, self.acceptingAudio else { return }
            self.acceptingAudio = false
            self.sendOrBuffer(.finish)
        }
    }

    func cancel() {
        lock.lock(); cancelled = true; lock.unlock()
        cancelWorker()
        queue.async { self.pending.removeAll(); self.writer = nil }
    }

    func attach(writer: @escaping ([String: Any]) throws -> Void, onFinish: @escaping () -> Void,
                onFailure: @escaping () -> Void) {
        queue.async {
            guard !self.isStopped else { onFailure(); return }
            self.writer = writer
            self.onFinish = onFinish
            self.onTransportFailure = onFailure
            do { try writer(["op": "start", "id": self.id.uuidString]) }
            catch { self.failTransport("Seda-v0.1 canlı oturumu başlatılamadı."); return }
            let commands = self.pending
            self.pending.removeAll()
            for command in commands { self.sendOrBuffer(command) }
        }
    }

    func receiveInterim(_ text: String) {
        DispatchQueue.main.async {
            guard !self.isCancelled else { return }
            self.onInterim?(text)
        }
    }

    func complete(text: String = "", error: String? = nil) {
        lock.lock()
        guard !terminal else { lock.unlock(); return }
        terminal = true
        lock.unlock()
        let result = TranscriptionResult(success: error == nil,
                                         text: text.trimmingCharacters(in: .whitespacesAndNewlines),
                                         latency: finalLatency, error: error, provider: "seda", model: SedaTranscriber.model)
        queue.async {
            self.acceptingAudio = false
            self.pending.removeAll()
            self.writer = nil
            self.onFinish = nil
            self.onTransportFailure = nil
        }
        DispatchQueue.main.async {
            guard !self.isCancelled else { return }
            self.completion(result)
        }
    }

    private func failTransport(_ message: String) {
        acceptingAudio = false
        pending.removeAll()
        writer = nil
        complete(error: message)
        if let onTransportFailure { onTransportFailure() } else { cancelWorker() }
    }

    private func sendOrBuffer(_ command: Command) {
        guard !isStopped else { return }
        guard let writer else { pending.append(command); return }
        do {
            switch command {
            case .audio(let data):
                try writer(["op": "audio", "id": id.uuidString, "pcm": data.base64EncodedString()])
            case .finish:
                onFinish?()
                lock.lock(); finishSent = true; lock.unlock()
                try writer(["op": "finish", "id": id.uuidString])
            }
        } catch { failTransport("Seda-v0.1 canlı bağlantısı kapandı.") }
    }
}
