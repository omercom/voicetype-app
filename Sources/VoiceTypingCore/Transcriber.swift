import Foundation

public struct TranscriptionResult {
    public var success: Bool
    public var text: String
    public var latency: Double
    public var error: String?
    public var provider: String
    public var model: String

    public init(
        success: Bool,
        text: String,
        latency: Double,
        error: String? = nil,
        provider: String,
        model: String
    ) {
        self.success = success
        self.text = text
        self.latency = latency
        self.error = error
        self.provider = provider
        self.model = model
    }
}

// MARK: - Gemini Live WebSocket Streaming Session

public final class LiveGeminiStreamSession: NSObject, URLSessionWebSocketDelegate, @unchecked Sendable {
    public let apiKey: String
    public let model: String
    public let language: String

    public var onInterim: ((String) -> Void)?
    public var onCompletion: ((TranscriptionResult) -> Void)?

    private var session: URLSession?
    private var webSocketTask: URLSessionWebSocketTask?
    private let lock = NSLock()
    private let streamQueue = DispatchQueue(label: "com.voicetyping.gemini.stream", qos: .userInteractive)

    private var isCompleted: Bool = false
    private var isCancelled: Bool = false
    private var isSetupComplete: Bool = false
    private var pendingChunks: [Data] = []
    private var isAudioFinished: Bool = false
    private var startTime: CFAbsoluteTime = 0
    private var accumulatedText: String = ""
    private var latestInterimText: String = ""
    private var safetyTimer: DispatchSourceTimer?
    private var finalizationTimer: DispatchSourceTimer?
    private var serverCloseReason: String?
    private var serverCloseCode: URLSessionWebSocketTask.CloseCode?

    public init(apiKey: String, model: String = "gemini-3.5-transcribe-live", language: String = "tr") {
        self.apiKey = apiKey
        self.model = model.isEmpty ? "gemini-3.5-transcribe-live" : model
        self.language = language
    }

    public func start() {
        lock.lock()
        guard webSocketTask == nil, !isCancelled else {
            lock.unlock()
            return
        }
        startTime = CFAbsoluteTimeGetCurrent()

        let safeChars = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.")
        let encodedKey = apiKey.addingPercentEncoding(withAllowedCharacters: safeChars) ?? apiKey
        let urlString = "wss://generativelanguage.googleapis.com/ws/google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContent?key=\(encodedKey)"
        guard let url = URL(string: urlString) else {
            lock.unlock()
            notifyCompletion(success: false, text: "", error: "Geçersiz Gemini Live WebSocket URL'i.")
            return
        }

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30.0
        let urlSession = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        let ws = urlSession.webSocketTask(with: url)
        self.session = urlSession
        self.webSocketTask = ws
        lock.unlock()

        ws.resume()

        // 1. Setup mesajı gönder
        let lang = language.trimmingCharacters(in: .whitespacesAndNewlines)
        var langCodes: [String] = []
        if !lang.isEmpty && lang.lowercased() != "auto" {
            langCodes.append(lang)
        }

        let modelPath = model.hasPrefix("models/") ? model : "models/\(model)"
        let setupPayload: [String: Any] = [
            "setup": [
                "model": modelPath,
                "generationConfig": [
                    "responseModalities": ["TEXT"]
                ],
                "inputAudioTranscription": [
                    "languageCodes": langCodes
                ]
            ]
        ]

        if let setupData = try? JSONSerialization.data(withJSONObject: setupPayload) {
            ws.send(.data(setupData)) { [weak self] error in
                if let error = error {
                    print("[GeminiLive] Setup gönderme hatası: \(error.localizedDescription)")
                    self?.notifyCompletion(success: false, text: "", error: "Canlı bağlantı kurulumu başarısız: \(error.localizedDescription)")
                }
            }
        }

        // 2. Dinleme döngüsünü başlat
        receiveNextMessage()
    }

    private func receiveNextMessage() {
        lock.lock()
        guard let ws = webSocketTask, !isCancelled, !isCompleted else {
            lock.unlock()
            return
        }
        lock.unlock()

        ws.receive { [weak self] result in
            guard let self = self else { return }

            switch result {
            case .failure(let error):
                self.lock.lock()
                let cancelled = self.isCancelled
                let finished = self.isAudioFinished
                let completed = self.isCompleted
                let hasText = !self.accumulatedText.isEmpty || !self.latestInterimText.isEmpty
                self.lock.unlock()

                if cancelled || completed { return }

                if finished && hasText {
                    // Kullanıcı konuşmayı bitirmişti ve metin elimizde, teslim et
                    self.finishAndComplete()
                } else {
                    DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) { [weak self] in
                        guard let self = self else { return }
                        self.lock.lock()
                        let reason = self.serverCloseReason ?? error.localizedDescription
                        let isFinishedAndEmpty = self.isAudioFinished
                        let code = self.serverCloseCode
                        self.lock.unlock()

                        if isFinishedAndEmpty && (code == .normalClosure || reason.contains("normal")) {
                            self.finishAndComplete()
                        } else {
                            self.notifyCompletion(success: false, text: "", error: "WebSocket bağlantı hatası: \(reason)")
                        }
                    }
                }

            case .success(let message):
                let data: Data?
                switch message {
                case .data(let d): data = d
                case .string(let s): data = s.data(using: .utf8)
                @unknown default: data = nil
                }

                if let data = data {
                    self.handleIncomingData(data)
                }

                // Dinlemeye devam et
                self.receiveNextMessage()
            }
        }
    }

    private func handleIncomingData(_ data: Data) {
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return
        }

        // Sunucu hata yanıtı
        if let errObj = json["error"] as? [String: Any] {
            let message = (errObj["message"] as? String) ?? "Bilinmeyen Gemini Live hatası"
            notifyCompletion(success: false, text: "", error: "Gemini Live Hatası: \(message)")
            return
        }

        // Setup tamamlandı bildirimi
        if json["setupComplete"] != nil {
            streamQueue.async { [weak self] in
                guard let self = self else { return }
                self.lock.lock()
                self.isSetupComplete = true
                let queued = self.pendingChunks
                self.pendingChunks.removeAll()
                let shouldFinish = self.isAudioFinished
                let ws = self.webSocketTask
                self.lock.unlock()

                guard let ws = ws else { return }
                for chunk in queued {
                    self.sendRawChunk(chunk, ws: ws)
                }
                if shouldFinish {
                    self.sendRawStreamEnd(ws: ws)
                }
            }
            return
        }

        if let serverContent = json["serverContent"] as? [String: Any] {
            // Anlık ara metin (Interim transcription)
            if let interimObj = serverContent["interimInputTranscription"] as? [String: Any],
               let interimText = interimObj["text"] as? String {
                let trimmed = interimText.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    lock.lock()
                    self.latestInterimText = trimmed
                    let currentAccum = self.accumulatedText
                    let finished = self.isAudioFinished
                    lock.unlock()

                    let preview: String
                    if currentAccum.isEmpty {
                        preview = trimmed
                    } else if trimmed.hasPrefix(currentAccum) {
                        preview = trimmed
                    } else {
                        preview = "\(currentAccum) \(trimmed)"
                    }
                    onInterim?(preview)

                    if finished {
                        scheduleFinalization(delayMs: 600)
                    }
                }
            }

            // Kesinleşmiş parça (Finalized turn input transcription)
            if let inputObj = serverContent["inputTranscription"] as? [String: Any],
               let text = inputObj["text"] as? String {
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    lock.lock()
                    if self.accumulatedText.isEmpty {
                        self.accumulatedText = trimmed
                    } else {
                        self.accumulatedText += " \(trimmed)"
                    }
                    let current = self.accumulatedText
                    let finished = self.isAudioFinished
                    lock.unlock()
                    onInterim?(current)

                    if finished {
                        scheduleFinalization(delayMs: 500)
                    }
                }
            }

            // Model Turn metin yedeği (eğer transcription yerine modelTurn gelirse)
            if let modelTurn = serverContent["modelTurn"] as? [String: Any],
               let parts = modelTurn["parts"] as? [[String: Any]] {
                let textParts = parts.filter { ($0["thought"] as? Bool) != true }
                let text = textParts.compactMap { $0["text"] as? String }.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty {
                    lock.lock()
                    if self.accumulatedText.isEmpty {
                        self.accumulatedText = text
                    }
                    let current = self.accumulatedText
                    let finished = self.isAudioFinished
                    lock.unlock()
                    onInterim?(current)

                    if finished {
                        scheduleFinalization(delayMs: 500)
                    }
                }
            }

            // Üretim tamamlandı (Turn Complete / Generation Complete)
            let isTurnComplete = (serverContent["turnComplete"] as? Bool) == true ||
                                 (serverContent["generationComplete"] as? Bool) == true
            if isTurnComplete {
                lock.lock()
                let finished = self.isAudioFinished
                lock.unlock()
                if finished {
                    finishAndComplete()
                }
            }
        }
    }

    public func sendAudioChunk(_ pcmData: Data) {
        guard !pcmData.isEmpty else { return }
        streamQueue.async { [weak self] in
            guard let self = self else { return }
            self.lock.lock()
            if self.isAudioFinished || self.isCancelled || self.isCompleted {
                self.lock.unlock()
                return
            }
            if !self.isSetupComplete {
                self.pendingChunks.append(pcmData)
                self.lock.unlock()
                return
            }
            let ws = self.webSocketTask
            self.lock.unlock()

            if let ws = ws {
                self.sendRawChunk(pcmData, ws: ws)
            }
        }
    }

    public func finishAudio() {
        streamQueue.async { [weak self] in
            guard let self = self else { return }
            self.lock.lock()
            if self.isAudioFinished || self.isCancelled || self.isCompleted {
                self.lock.unlock()
                return
            }
            self.isAudioFinished = true
            let ready = self.isSetupComplete
            let ws = self.webSocketTask
            self.lock.unlock()

            if ready, let ws = ws {
                self.sendRawStreamEnd(ws: ws)
            }
        }

        // Güvenlik zamanlayıcısı: 4.5 saniye içinde sonlanmazsa tamamla
        startSafetyTimeout(seconds: 4.5)
    }

    private func sendRawChunk(_ pcmData: Data, ws: URLSessionWebSocketTask) {
        let payload: [String: Any] = [
            "realtimeInput": [
                "audio": [
                    "data": pcmData.base64EncodedString(),
                    "mimeType": "audio/pcm;rate=16000"
                ]
            ]
        ]

        if let data = try? JSONSerialization.data(withJSONObject: payload) {
            ws.send(.data(data)) { error in
                if let error = error {
                    print("[GeminiLive] Ses verisi gönderme hatası: \(error.localizedDescription)")
                }
            }
        }
    }

    private func sendRawStreamEnd(ws: URLSessionWebSocketTask) {
        let endPayload: [String: Any] = [
            "realtimeInput": [
                "audioStreamEnd": true
            ]
        ]

        if let data = try? JSONSerialization.data(withJSONObject: endPayload) {
            ws.send(.data(data)) { error in
                if let error = error {
                    print("[GeminiLive] audioStreamEnd gönderme hatası: \(error.localizedDescription)")
                }
            }
        }
    }

    private func startSafetyTimeout(seconds: Double) {
        cancelSafetyTimer()
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global())
        timer.schedule(deadline: .now() + seconds)
        timer.setEventHandler { [weak self] in
            self?.finishAndComplete()
        }
        timer.resume()
        self.safetyTimer = timer
    }

    private func cancelSafetyTimer() {
        lock.lock()
        safetyTimer?.cancel()
        safetyTimer = nil
        lock.unlock()
    }

    private func scheduleFinalization(delayMs: Int) {
        lock.lock()
        finalizationTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global())
        timer.schedule(deadline: .now() + .milliseconds(delayMs))
        timer.setEventHandler { [weak self] in
            self?.finishAndComplete()
        }
        timer.resume()
        self.finalizationTimer = timer
        lock.unlock()
    }

    private func cancelFinalizationTimer() {
        lock.lock()
        finalizationTimer?.cancel()
        finalizationTimer = nil
        lock.unlock()
    }

    private func finishAndComplete() {
        cancelSafetyTimer()
        cancelFinalizationTimer()

        lock.lock()
        guard !isCompleted else {
            lock.unlock()
            return
        }
        isCompleted = true
        let latency = CFAbsoluteTimeGetCurrent() - startTime
        var text = accumulatedText.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty {
            text = latestInterimText.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let lower = text.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]().,"))
        if lower == "blank_audio" || lower == "sessizlik" || lower == "ses yok" || lower == "boşluk" || lower == "gürültü" {
            text = ""
        }
        let ws = webSocketTask
        webSocketTask = nil
        let sess = session
        session = nil
        let cb = onCompletion
        onCompletion = nil
        onInterim = nil
        lock.unlock()

        ws?.cancel(with: .normalClosure, reason: nil)
        sess?.finishTasksAndInvalidate()

        let result = TranscriptionResult(
            success: true,
            text: text,
            latency: latency,
            error: nil,
            provider: "gemini",
            model: model
        )
        cb?(result)
    }

    public func cancel() {
        cancelSafetyTimer()
        cancelFinalizationTimer()

        lock.lock()
        isCancelled = true
        isCompleted = true
        pendingChunks.removeAll()
        let ws = webSocketTask
        webSocketTask = nil
        let sess = session
        session = nil
        onCompletion = nil
        onInterim = nil
        lock.unlock()

        ws?.cancel(with: .goingAway, reason: nil)
        sess?.invalidateAndCancel()
    }

    public func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        lock.lock()
        self.serverCloseCode = closeCode
        if let reason = reason, let str = String(data: reason, encoding: .utf8), !str.isEmpty {
            self.serverCloseReason = str
        }
        lock.unlock()
    }

    private func notifyCompletion(success: Bool, text: String, error: String?) {
        cancelSafetyTimer()
        cancelFinalizationTimer()

        lock.lock()
        guard !isCompleted else {
            lock.unlock()
            return
        }
        isCompleted = true
        let latency = CFAbsoluteTimeGetCurrent() - startTime
        let ws = webSocketTask
        webSocketTask = nil
        let sess = session
        session = nil
        let cb = onCompletion
        onCompletion = nil
        onInterim = nil
        lock.unlock()

        ws?.cancel(with: .goingAway, reason: nil)
        sess?.invalidateAndCancel()

        let result = TranscriptionResult(
            success: success,
            text: text,
            latency: latency,
            error: error,
            provider: "gemini",
            model: model
        )
        cb?(result)
    }
}

// MARK: - Transcriber Servisi

public class Transcriber {
    public static let shared = Transcriber()

    private var currentTask: URLSessionTask?
    private var activeLiveSession: LiveGeminiStreamSession?
    private let lock = NSLock()

    private init() {}

    public func cancel() {
        lock.lock()
        defer { lock.unlock() }
        currentTask?.cancel()
        currentTask = nil
        activeLiveSession?.cancel()
        activeLiveSession = nil
    }

    public func startLiveGeminiSession(
        config: AppConfig,
        onInterim: ((String) -> Void)? = nil,
        completion: @escaping (TranscriptionResult) -> Void
    ) -> LiveGeminiStreamSession? {
        let apiKey = config.gemini_api_key.trimmingCharacters(in: .whitespacesAndNewlines)
        let model = config.gemini_model.isEmpty ? "gemini-3.5-transcribe-live" : config.gemini_model

        guard !apiKey.isEmpty else {
            completion(TranscriptionResult(
                success: false,
                text: "",
                latency: 0,
                error: "GEMINI_API_KEY girilmemiş! Lütfen Ayarlar menüsünden API anahtarınızı girin.",
                provider: "gemini",
                model: model
            ))
            return nil
        }

        let session = LiveGeminiStreamSession(apiKey: apiKey, model: model, language: config.language)
        session.onInterim = onInterim
        session.onCompletion = completion

        lock.lock()
        activeLiveSession = session
        lock.unlock()

        session.start()
        return session
    }

    public func transcribe(
        audioData: Data,
        config: AppConfig,
        completion: @escaping (TranscriptionResult) -> Void
    ) {
        let provider = config.provider.lowercased()
        if provider == "gemini" {
            let model = config.gemini_model.isEmpty ? "gemini-3.5-transcribe-live" : config.gemini_model
            if model == "gemini-3.5-transcribe-live" || model == "models/gemini-3.5-transcribe-live" {
                transcribeGeminiLive(audioData: audioData, config: config, completion: completion)
            } else {
                transcribeGemini(audioData: audioData, config: config, completion: completion)
            }
        } else {
            transcribeGroq(audioData: audioData, config: config, completion: completion)
        }
    }

    // MARK: - Gemini Live WebSocket (Tek Seferlik Ses Verisi İle)

    public func transcribeGeminiLive(
        audioData: Data,
        config: AppConfig,
        completion: @escaping (TranscriptionResult) -> Void
    ) {
        let apiKey = config.gemini_api_key.trimmingCharacters(in: .whitespacesAndNewlines)
        let model = config.gemini_model.isEmpty ? "gemini-3.5-transcribe-live" : config.gemini_model

        guard !apiKey.isEmpty else {
            completion(TranscriptionResult(
                success: false,
                text: "",
                latency: 0,
                error: "GEMINI_API_KEY girilmemiş! Lütfen Ayarlar menüsünden API anahtarınızı girin.",
                provider: "gemini",
                model: model
            ))
            return
        }

        // Eğer WAV formatındaysa 44 baytlık RIFF başlığını atla, saf PCM verisini al
        let pcmData: Data
        if audioData.count > 44, String(data: audioData.prefix(4), encoding: .ascii) == "RIFF" {
            pcmData = audioData.subdata(in: 44..<audioData.count)
        } else {
            pcmData = audioData
        }

        let session = LiveGeminiStreamSession(apiKey: apiKey, model: model, language: config.language)

        session.onCompletion = { [weak self] result in
            if result.success {
                completion(result)
            } else if let err = result.error, err.contains("quota") || err.contains("exceeded") || err.contains("429") {
                // Kota aşımında doğrudan hatayı ilet
                completion(result)
            } else {
                // Diğer ağ ve soket kopmalarında REST fallback dene
                print("[GeminiLive] WebSocket başarısız (\(result.error ?? "")), REST fallback deneniyor...")
                self?.transcribeGemini(audioData: audioData, config: config, completion: completion)
            }
        }

        lock.lock()
        activeLiveSession = session
        lock.unlock()

        session.start()

        // 100ms parçalar halinde oturuma aktar ve bitir (setupComplete geldiğinde otomatik akıtılacaktır)
        let chunkSize = 3200
        var offset = 0
        while offset < pcmData.count {
            let end = min(offset + chunkSize, pcmData.count)
            let chunk = pcmData.subdata(in: offset..<end)
            session.sendAudioChunk(chunk)
            offset = end
        }
        session.finishAudio()
    }

    // MARK: - Groq Whisper

    public func transcribeGroq(
        audioData: Data,
        config: AppConfig,
        completion: @escaping (TranscriptionResult) -> Void
    ) {
        let apiKey = config.groq_api_key.trimmingCharacters(in: .whitespacesAndNewlines)
        let model = (config.groq_model.isEmpty || config.groq_model == "whisper-large-v3-turbo") ? "whisper-large-v3" : config.groq_model

        guard !apiKey.isEmpty else {
            completion(TranscriptionResult(
                success: false,
                text: "",
                latency: 0,
                error: "GROQ_API_KEY girilmemiş! Lütfen Ayarlar menüsünden API anahtarınızı girin.",
                provider: "groq",
                model: model
            ))
            return
        }

        guard let url = URL(string: "https://api.groq.com/openai/v1/audio/transcriptions") else {
            completion(TranscriptionResult(
                success: false,
                text: "",
                latency: 0,
                error: "Geçersiz Groq URL'i.",
                provider: "groq",
                model: model
            ))
            return
        }

        let boundary = "Boundary-\(UUID().uuidString)"
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 20.0
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        var body = Data()

        // Model
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"model\"\r\n\r\n".data(using: .utf8)!)
        body.append("\(model)\r\n".data(using: .utf8)!)

        // Language
        let lang = config.language.trimmingCharacters(in: .whitespacesAndNewlines)
        if !lang.isEmpty && lang.lowercased() != "auto" {
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"language\"\r\n\r\n".data(using: .utf8)!)
            body.append("\(lang)\r\n".data(using: .utf8)!)
        }

        // Response format
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"response_format\"\r\n\r\n".data(using: .utf8)!)
        body.append("json\r\n".data(using: .utf8)!)

        // Audio File
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"audio.wav\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: audio/wav\r\n\r\n".data(using: .utf8)!)
        body.append(audioData)
        body.append("\r\n".data(using: .utf8)!)

        // Closing Boundary
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)

        request.httpBody = body

        let startTime = CFAbsoluteTimeGetCurrent()

        lock.lock()
        let task = URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            let latency = CFAbsoluteTimeGetCurrent() - startTime
            self?.lock.lock()
            self?.currentTask = nil
            self?.lock.unlock()

            if let error = error {
                if (error as NSError).code == NSURLErrorCancelled {
                    return
                }
                completion(TranscriptionResult(
                    success: false,
                    text: "",
                    latency: latency,
                    error: "Bağlantı hatası: \(error.localizedDescription)",
                    provider: "groq",
                    model: model
                ))
                return
            }

            guard let httpResponse = response as? HTTPURLResponse else {
                completion(TranscriptionResult(
                    success: false,
                    text: "",
                    latency: latency,
                    error: "Sunucudan yanıt alınamadı.",
                    provider: "groq",
                    model: model
                ))
                return
            }

            guard let data = data else {
                completion(TranscriptionResult(
                    success: false,
                    text: "",
                    latency: latency,
                    error: "Boş yanıt alındı.",
                    provider: "groq",
                    model: model
                ))
                return
            }

            if httpResponse.statusCode == 200 {
                if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let rawText = json["text"] as? String {
                    var cleaned = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
                    let lower = cleaned.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]().,"))
                    if lower == "blank_audio" || lower == "music" || lower == "sessizlik" || lower == "ses yok" || lower == "boşluk" || lower == "müzik" {
                        cleaned = ""
                    }
                    completion(TranscriptionResult(
                        success: true,
                        text: cleaned,
                        latency: latency,
                        error: nil,
                        provider: "groq",
                        model: model
                    ))
                } else {
                    completion(TranscriptionResult(
                        success: false,
                        text: "",
                        latency: latency,
                        error: "Groq yanıtı çözülemedi.",
                        provider: "groq",
                        model: model
                    ))
                }
            } else {
                let errStr = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? [String: Any]
                let message = (errStr?["message"] as? String) ?? (String(data: data, encoding: .utf8) ?? "HTTP \(httpResponse.statusCode)")
                completion(TranscriptionResult(
                    success: false,
                    text: "",
                    latency: latency,
                    error: "Groq Hatası (\(httpResponse.statusCode)): \(message)",
                    provider: "groq",
                    model: model
                ))
            }
        }
        self.currentTask = task
        lock.unlock()
        task.resume()
    }

    // MARK: - Google Gemini REST API

    public func transcribeGemini(
        audioData: Data,
        config: AppConfig,
        completion: @escaping (TranscriptionResult) -> Void
    ) {
        let apiKey = config.gemini_api_key.trimmingCharacters(in: .whitespacesAndNewlines)
        var model = config.gemini_model.isEmpty ? "gemini-3.5-flash" : config.gemini_model
        if model == "gemini-3.5-transcribe-live" || model == "models/gemini-3.5-transcribe-live" {
            // REST için transcribe veya 3.5-flash kullan
            model = "gemini-3.5-transcribe"
        }

        guard !apiKey.isEmpty else {
            completion(TranscriptionResult(
                success: false,
                text: "",
                latency: 0,
                error: "GEMINI_API_KEY girilmemiş! Lütfen Ayarlar menüsünden API anahtarınızı girin.",
                provider: "gemini",
                model: model
            ))
            return
        }

        let urlString = "https://generativelanguage.googleapis.com/v1beta/models/\(model):generateContent?key=\(apiKey)"
        guard let url = URL(string: urlString) else {
            completion(TranscriptionResult(
                success: false,
                text: "",
                latency: 0,
                error: "Geçersiz Gemini URL'i.",
                provider: "gemini",
                model: model
            ))
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 25.0
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let prompt = """
        Sen bir ses deşifre (transcription) sistemisin. Bu ses kaydındaki konuşmayı harfi harfine, doğru imla ve noktalama ile yazıya dök. Eğer ses kaydında belirgin bir insan konuşması yoksa, ortam gürültüsü veya sessizlik varsa kesinlikle hiçbir şey yazma, sadece boş bırak. Asla selamlama, özet veya fazladan yorum ekleme. Sadece konuşulan metni döndür.
        """

        let base64Audio = audioData.base64EncodedString()
        let payload: [String: Any] = [
            "contents": [
                [
                    "parts": [
                        ["text": prompt],
                        [
                            "inline_data": [
                                "mime_type": "audio/wav",
                                "data": base64Audio
                            ]
                        ]
                    ]
                ]
            ]
        ]

        guard let httpBody = try? JSONSerialization.data(withJSONObject: payload) else {
            completion(TranscriptionResult(
                success: false,
                text: "",
                latency: 0,
                error: "Gemini istek gövdesi oluşturulamadı.",
                provider: "gemini",
                model: model
            ))
            return
        }
        request.httpBody = httpBody

        let startTime = CFAbsoluteTimeGetCurrent()

        lock.lock()
        let task = URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            let latency = CFAbsoluteTimeGetCurrent() - startTime
            self?.lock.lock()
            self?.currentTask = nil
            self?.lock.unlock()

            if let error = error {
                if (error as NSError).code == NSURLErrorCancelled {
                    return
                }
                completion(TranscriptionResult(
                    success: false,
                    text: "",
                    latency: latency,
                    error: "Bağlantı hatası: \(error.localizedDescription)",
                    provider: "gemini",
                    model: model
                ))
                return
            }

            guard let httpResponse = response as? HTTPURLResponse else {
                completion(TranscriptionResult(
                    success: false,
                    text: "",
                    latency: latency,
                    error: "Sunucudan yanıt alınamadı.",
                    provider: "gemini",
                    model: model
                ))
                return
            }

            guard let data = data else {
                completion(TranscriptionResult(
                    success: false,
                    text: "",
                    latency: latency,
                    error: "Boş yanıt alındı.",
                    provider: "gemini",
                    model: model
                ))
                return
            }

            if httpResponse.statusCode == 200 {
                if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let candidates = json["candidates"] as? [[String: Any]],
                   let firstCand = candidates.first,
                   let content = firstCand["content"] as? [String: Any],
                   let parts = content["parts"] as? [[String: Any]] {
                    let textParts = parts.filter { ($0["thought"] as? Bool) != true }
                    let rawText = textParts.compactMap { $0["text"] as? String }.joined(separator: " ")
                    var cleaned = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
                    let lower = cleaned.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]().,"))
                    if lower == "sessizlik" || lower == "ses yok" || lower == "boşluk" || lower == "gürültü" || lower == "konuşma yok" || lower == "blank_audio" {
                        cleaned = ""
                    }
                    completion(TranscriptionResult(
                        success: true,
                        text: cleaned,
                        latency: latency,
                        error: nil,
                        provider: "gemini",
                        model: model
                    ))
                } else {
                    completion(TranscriptionResult(
                        success: true,
                        text: "",
                        latency: latency,
                        error: nil,
                        provider: "gemini",
                        model: model
                    ))
                }
            } else {
                let errObj = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? [String: Any]
                let message = (errObj?["message"] as? String) ?? (String(data: data, encoding: .utf8) ?? "HTTP \(httpResponse.statusCode)")
                completion(TranscriptionResult(
                    success: false,
                    text: "",
                    latency: latency,
                    error: "Gemini Hatası (\(httpResponse.statusCode)): \(message)",
                    provider: "gemini",
                    model: model
                ))
            }
        }
        self.currentTask = task
        lock.unlock()
        task.resume()
    }

    // MARK: - Bağlantı ve API Anahtarı Doğrulama

    public func testGroqConnection(apiKey: String, completion: @escaping (Bool, String) -> Void) {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else {
            completion(false, "Lütfen Groq API anahtarını girin.")
            return
        }

        guard let url = URL(string: "https://api.groq.com/openai/v1/models") else {
            completion(false, "Geçersiz Groq URL'i.")
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 10.0
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")

        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error = error {
                completion(false, "Bağlantı hatası: \(error.localizedDescription)")
                return
            }

            guard let http = response as? HTTPURLResponse else {
                completion(false, "Sunucudan yanıt alınamadı.")
                return
            }

            if http.statusCode == 200 {
                completion(true, "Bağlantı başarılı! Groq API hazır.")
            } else if http.statusCode == 401 {
                completion(false, "Yetkilendirme hatası (401): Geçersiz Groq API anahtarı.")
            } else {
                let msg = (data != nil) ? (String(data: data!, encoding: .utf8) ?? "") : ""
                completion(false, "Groq HTTP \(http.statusCode): \(msg.prefix(80))")
            }
        }.resume()
    }

    public func testGeminiConnection(apiKey: String, completion: @escaping (Bool, String) -> Void) {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else {
            completion(false, "Lütfen Gemini API anahtarını girin.")
            return
        }

        guard let encodedKey = key.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models?key=\(encodedKey)") else {
            completion(false, "Geçersiz Gemini URL'i.")
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 10.0

        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error = error {
                completion(false, "Bağlantı hatası: \(error.localizedDescription)")
                return
            }

            guard let http = response as? HTTPURLResponse else {
                completion(false, "Sunucudan yanıt alınamadı.")
                return
            }

            if http.statusCode == 200 {
                completion(true, "Bağlantı başarılı! Gemini API hazır.")
            } else if http.statusCode == 400 || http.statusCode == 403 {
                completion(false, "Yetkilendirme hatası (\(http.statusCode)): Geçersiz Gemini API anahtarı.")
            } else {
                let msg = (data != nil) ? (String(data: data!, encoding: .utf8) ?? "") : ""
                completion(false, "Gemini HTTP \(http.statusCode): \(msg.prefix(80))")
            }
        }.resume()
    }
}
