import AppKit

final class ReadAloudController: NSObject, NSSoundDelegate {
    var isDictating: (() -> Bool)?
    var onUpdate: ((String, Bool) -> Void)?
    var onError: ((String) -> Void)?
    private let engine: ReadAloudEngine
    private let selection = SelectedTextReader()
    private var requestID: UUID?
    private var selecting = false
    private var sound: NSSound?
    private var audioFile: URL?
    private var device = ""
    private var browserRequestID: UUID?
    private var lastError: String?
    private var chunks: [String] = []
    private var chunkIndex = 0
    private var characterCount = 0
    private var isPaused = false
    private var playbackStarted = false
    var isBusy: Bool { selecting || requestID != nil || sound != nil || isPaused }

    init(engine: ReadAloudEngine = ReadAloudEngine()) {
        self.engine = engine
        super.init()
        engine.onReady = { [weak self] device in
            guard let self else { return }
            self.device = device.uppercased()
            self.update(self.isPaused ? "Okuma duraklatıldı" : self.isBusy ? "Ses hazırlanıyor..." : "Hazır (\(self.device))")
        }
        engine.onAudio = { [weak self] id, url, duration in self?.play(id: id, url: url, duration: duration) }
        engine.onFailure = { [weak self] _, message in
            guard let self else { return }
            let wasRequested = self.isBusy
            self.clearPlayback()
            self.requestID = nil
            self.selecting = false
            self.chunks = []
            self.chunkIndex = 0
            self.isPaused = false
            self.selection.cancel()
            self.lastError = message
            self.update(message)
            if wasRequested { self.onError?(message) }
        }
    }

    func prepare() {
        if engine.isInstalled {
            update("Antalia Mini hazırlanıyor...")
            engine.prepare()
        } else {
            update("Antalia Mini kurulmadı (setup-tts.sh)")
        }
    }

    func toggleSelection() {
        if isBusy { cancel(); return }
        guard allowRequest() else { return }
        selecting = true
        update("Seçili metin alınıyor...")
        selection.read { [weak self] result in
            guard let self, self.selecting else { return }
            self.selecting = false
            switch result {
            case .success(let text): self.speak(text)
            case .failure(let error): self.report(error.localizedDescription)
            }
        }
    }

    func speakClipboard() {
        guard allowRequest() else { return }
        speak(NSPasteboard.general.string(forType: .string) ?? "")
    }

    func speak(_ text: String) {
        guard allowRequest() else { return }
        do {
            let text = try ReadAloudText.validated(text)
            cancel()
            chunks = ReadAloudText.chunks(text)
            characterCount = text.unicodeScalars.count
            startChunk()
        } catch {
            report(error.localizedDescription)
        }
    }

    private func startChunk() {
        guard !isPaused, chunkIndex < chunks.count else { return }
        let id = UUID()
        requestID = id
        update("Ses hazırlanıyor — bölüm \(chunkIndex + 1)/\(chunks.count)")
        engine.synthesize(chunks[chunkIndex], id: id)
    }

    private func allowRequest() -> Bool {
        guard !(isDictating?() ?? false) else {
            report("Dikte sırasında seslendirme başlamaz.")
            return false
        }
        guard engine.isInstalled else {
            report("Antalia Mini kurulmadı. Önce setup-tts.sh çalıştırın.")
            return false
        }
        return true
    }

    private func play(id: UUID, url: URL, duration: Double) {
        guard requestID == id, !(isDictating?() ?? false) else {
            try? FileManager.default.removeItem(at: url)
            return
        }
        requestID = nil
        guard let player = NSSound(contentsOf: url, byReference: false) else {
            try? FileManager.default.removeItem(at: url)
            report("Üretilen ses açılamadı.")
            return
        }
        sound = player
        audioFile = url
        player.delegate = self
        if isPaused { update("Okuma duraklatıldı — bölüm \(chunkIndex + 1)/\(chunks.count)"); return }
        if player.play() {
            playbackStarted = true
            update("Türkçe okunuyor — bölüm \(chunkIndex + 1)/\(chunks.count) — ⌥⌘S / Esc ile durdur")
        } else {
            clearPlayback()
            report("Ses çıkışı başlatılamadı.")
        }
    }

    func sound(_ sound: NSSound, didFinishPlaying flag: Bool) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.sound === sound else { return }
            self.clearPlayback()
            guard flag else {
                self.chunks = []
                self.report("Ses oynatma kesildi. Yeniden deneyin.")
                return
            }
            self.chunkIndex += 1
            if self.chunkIndex < self.chunks.count {
                if self.isPaused { self.update("Okuma duraklatıldı") }
                else { self.startChunk() }
            }
            else { self.isPaused = false; self.update("Hazır (\(self.device))") }
        }
    }

    private func clearPlayback() {
        let previous = sound
        sound = nil
        previous?.delegate = nil
        previous?.stop()
        if let audioFile { try? FileManager.default.removeItem(at: audioFile) }
        audioFile = nil
        playbackStarted = false
    }

    private func pause() throws {
        guard isBusy, !isPaused, chunkIndex < chunks.count else { return }
        if let sound, playbackStarted, !sound.pause() {
            throw ReadAloudError.message("Ses duraklatılamadı. Yeniden deneyin.")
        }
        isPaused = true
        update("Okuma duraklatıldı — bölüm \(chunkIndex + 1)/\(chunks.count)")
    }

    private func resume() throws {
        guard isPaused else { return }
        guard !(isDictating?() ?? false) else { throw ReadAloudError.message("Dikte sırasında seslendirme devam etmez.") }
        if let sound {
            guard playbackStarted ? sound.resume() : sound.play() else {
                throw ReadAloudError.message("Ses devam ettirilemedi. Yeniden deneyin.")
            }
            playbackStarted = true
            isPaused = false
            update("Türkçe okunuyor — bölüm \(chunkIndex + 1)/\(chunks.count) — ⌥⌘S / Esc ile durdur")
        } else {
            isPaused = false
            if requestID != nil { update("Ses hazırlanıyor — bölüm \(chunkIndex + 1)/\(chunks.count)") }
            else { startChunk() }
        }
    }

    func cancel() {
        selection.cancel()
        selecting = false
        if requestID != nil { engine.shutdown() }
        requestID = nil
        browserRequestID = nil
        lastError = nil
        chunks = []
        chunkIndex = 0
        characterCount = 0
        isPaused = false
        clearPlayback()
        update(engine.isReady ? "Hazır (\(device))" : "Okuma durduruldu")
    }

    func shutdown() {
        cancel()
        engine.shutdown()
    }

    private func report(_ message: String) {
        lastError = message
        update(message)
        onError?(message)
    }

    private func update(_ message: String) { onUpdate?(message, isBusy) }

    func browserCommand(_ request: ReadAloudBrowserRequest) -> [String: Any] {
        do {
            switch request.action {
            case .speak:
                let text = try request.validatedText()
                guard !(isDictating?() ?? false) else { throw ReadAloudError.message("Dikte sırasında seslendirme başlamaz.") }
                guard engine.isInstalled else { throw ReadAloudError.message("Önce setup-tts.sh ile Antalia Mini motorunu kurun.") }
                speak(text)
                if let lastError { throw ReadAloudError.message(lastError) }
                browserRequestID = request.id
            case .stop:
                if browserRequestID == request.id { cancel() }
            case .pause:
                if browserRequestID == request.id { try pause() }
            case .resume:
                if browserRequestID == request.id { try resume() }
            case .status: break
            }
            guard browserRequestID == request.id else { return ["ok": true, "state": "idle"] }
            if let lastError { return ["ok": false, "state": "failed", "error": lastError] }
            return ["ok": true, "state": isPaused ? "paused" : sound != nil ? "playing" : requestID != nil ? "preparing" : "idle",
                    "stage": engine.isReady ? "synthesizing" : "loading",
                    "characters": characterCount, "totalChunks": chunks.count,
                    "positionSeconds": sound?.currentTime ?? 0,
                    "completedChunks": chunkIndex, "currentChunk": min(chunkIndex + 1, chunks.count)]
        } catch {
            return ["ok": false, "error": error.localizedDescription]
        }
    }

    /// macOS supplies a service-specific pasteboard, not the user's general clipboard.
    @objc func speakText(_ pasteboard: NSPasteboard, userData: String?,
                         error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        guard !(isDictating?() ?? false) else {
            error.pointee = "Dikte sırasında seslendirme başlamaz."
            return
        }
        do {
            let text = try ReadAloudText.validated(pasteboard.string(forType: .string)
                ?? pasteboard.string(forType: NSPasteboard.PasteboardType("NSStringPboardType")) ?? "")
            guard engine.isInstalled else { throw ReadAloudError.message("Önce setup-tts.sh ile Antalia Mini motorunu kurun.") }
            speak(text)
        } catch let failure {
            error.pointee = failure.localizedDescription as NSString
        }
    }
}
