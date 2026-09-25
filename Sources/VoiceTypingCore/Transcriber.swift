import Foundation
import Speech
import AVFoundation

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

// MARK: - Live Stream Session Protocol

public protocol LiveStreamSession: AnyObject {
    func sendAudioChunk(_ chunk: Data)
    func finishAudio()
    func cancel()
}

// MARK: - Gemini Live WebSocket Streaming Session

public final class LiveGeminiStreamSession: NSObject, URLSessionWebSocketDelegate, LiveStreamSession, @unchecked Sendable {
    public let apiKey: String
    public let model: String
    public let language: String
    public let systemPrompt: String

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
    private var hasSentStreamEnd: Bool = false
    private var streamEndSentTime: CFAbsoluteTime = 0
    private var startTime: CFAbsoluteTime = 0
    private var transcriptAccumulator = StreamingTranscriptAccumulator()
    private var modelTurnFallbackText: String = ""
    private var safetyTimer: DispatchSourceTimer?
    private var finalizationTimer: DispatchSourceTimer?
    private var serverCloseReason: String?
    private var serverCloseCode: URLSessionWebSocketTask.CloseCode?

    public init(apiKey: String, model: String = "gemini-3.5-transcribe-live", language: String = "tr", systemPrompt: String = "") {
        self.apiKey = apiKey
        self.model = model.isEmpty ? "gemini-3.5-transcribe-live" : model
        self.language = language
        self.systemPrompt = systemPrompt
    }

    static func setupPayload(model: String, language: String, systemPrompt: String) -> [String: Any] {
        let nativeAudio = ConfigManager.isGeminiNativeAudioLiveModel(model)
        var setup: [String: Any] = [
            "model": model.hasPrefix("models/") ? model : "models/\(model)",
            "generationConfig": [
                // Native audio Live models reject TEXT-only response modality.
                "responseModalities": nativeAudio ? ["AUDIO"] : ["TEXT"]
            ],
            "inputAudioTranscription": [String: Any]()
        ]

        // Native audio models infer language automatically. The older transcribe
        // Live model accepts an explicit language code.
        let lang = language.trimmingCharacters(in: .whitespacesAndNewlines)
        if !nativeAudio && !lang.isEmpty && lang.lowercased() != "auto" {
            setup["inputAudioTranscription"] = ["languageCodes": [lang]]
        }

        if ConfigManager.isGeminiExtendedThinkingModel(model) {
            setup["thinkingConfig"] = ["thinkingLevel": "low"]
        }

        let prompt = systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if !prompt.isEmpty && ConfigManager.supportsSystemPrompt(model: model) {
            setup["systemInstruction"] = [
                "parts": [
                    ["text": prompt]
                ]
            ]
        }
        return ["setup": setup]
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
        let setupPayload = Self.setupPayload(
            model: model,
            language: language,
            systemPrompt: systemPrompt
        )

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
                let hasText = !self.transcriptAccumulator.text.isEmpty || !self.modelTurnFallbackText.isEmpty
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
            // Anlık ara metin (Interim transcription - Yalnızca canlı HUD görsel önizlemesi içindir)
            if let interimObj = serverContent["interimInputTranscription"] as? [String: Any],
               let interimText = interimObj["text"] as? String {
                let trimmed = Self.cleanNoiseTags(interimText)
                if !trimmed.isEmpty {
                    lock.lock()
                    let preview = GeminiTranscriptProcessor.applyPartial(
                        accumulator: &self.transcriptAccumulator,
                        text: trimmed,
                        receivedAt: ProcessInfo.processInfo.systemUptime
                    )
                    let callback = self.onInterim
                    lock.unlock()

                    callback?(preview)
                }
            }

            // Kesinleşmiş parça (Finalized turn input transcription)
            if let inputObj = serverContent["inputTranscription"] as? [String: Any],
               let text = inputObj["text"] as? String {
                let trimmed = Self.cleanNoiseTags(text)
                if !trimmed.isEmpty {
                    lock.lock()
                    let current = GeminiTranscriptProcessor.applyFinal(
                        accumulator: &self.transcriptAccumulator,
                        text: trimmed
                    )
                    let endSent = self.hasSentStreamEnd
                    let callback = self.onInterim
                    lock.unlock()
                    callback?(current)

                    // Eğer kullanıcı konuşmayı bitirdiyse (streamEnd yollandıysa),
                    // generationComplete sinyali beklenir. Eğer generationComplete gecikirse
                    // bu son inputTranscription'dan 750ms sonra otomatik tamamla:
                    if endSent {
                        scheduleFinalization(delayMs: 750)
                    }
                }
            }

            // Model Turn metin yedeği (yalnızca inputTranscription hiç gelmediyse yedek olarak kullanılır)
            if let modelTurn = serverContent["modelTurn"] as? [String: Any],
               let parts = modelTurn["parts"] as? [[String: Any]] {
                let textParts = parts.filter { ($0["thought"] as? Bool) != true }
                let text = textParts.compactMap { $0["text"] as? String }.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty {
                    lock.lock()
                    self.modelTurnFallbackText = text
                    let hasAccum = !self.transcriptAccumulator.committedText.isEmpty
                    let endSent = self.hasSentStreamEnd
                    lock.unlock()

                    if !hasAccum {
                        onInterim?(text)
                    }

                    if endSent {
                        scheduleFinalization(delayMs: 500)
                    }
                }
            }

            // Üretim tamamlandı (Turn Complete / Generation Complete)
            let isTurnComplete = (serverContent["turnComplete"] as? Bool) == true ||
                                 (serverContent["generationComplete"] as? Bool) == true
            if isTurnComplete {
                lock.lock()
                let endSent = self.hasSentStreamEnd
                lock.unlock()

                // Kullanıcı konuşmayı bitirdikten sonra gelen generationComplete / turnComplete,
                // Gemini'nin tüm ses akışını başarıyla işleyip bitirdiğini gösterir.
                // Son paketlerin düşmesi için 50ms tanı ve derhal tamamla!
                if endSent {
                    scheduleFinalization(delayMs: 50)
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
        lock.lock()
        hasSentStreamEnd = true
        streamEndSentTime = CFAbsoluteTimeGetCurrent()
        lock.unlock()

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

        // Kullanıcının belirttiği gibi: Gemini Live'ın yanıtı tamamlamasını (generationComplete / turnComplete)
        // bekliyoruz. Normalde sunucu bu sinyali 150-300ms içinde gönderir ve 50ms içinde anında tamamlanır.
        // Olası bir ağ veya sunucu gecikmesinde erken kesilip eksik/mükerrer olmaması için güvenlik süresini 3000ms yapıyoruz.
        scheduleFinalization(delayMs: 3000)
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

    // MARK: - Normalizasyon ve Mükerrer İfade Çözümleme


    public static func cleanNoiseTags(_ text: String) -> String {
        StreamingTranscriptReconciler.clean(text)
    }

    public static func normalizeTokens(_ text: String) -> [String] {
        let lower = text.lowercased(with: Locale(identifier: "tr_TR"))
        var cleaned = ""
        cleaned.reserveCapacity(lower.count)
        for char in lower {
            if char.isLetter || char.isNumber {
                cleaned.append(char)
            } else {
                cleaned.append(" ")
            }
        }
        return cleaned.split(separator: " ").map(String.init).filter { !$0.isEmpty }
    }

    public static func isCovered(subText: String, in fullText: String) -> Bool {
        let subTokens = normalizeTokens(subText)
        guard !subTokens.isEmpty else { return true }
        let fullTokens = normalizeTokens(fullText)
        guard !fullTokens.isEmpty else { return false }

        if subTokens.count > fullTokens.count {
            return false
        }

        let maxStart = fullTokens.count - subTokens.count
        for start in 0...maxStart {
            var matches = true
            for i in 0..<subTokens.count {
                if fullTokens[start + i] != subTokens[i] {
                    matches = false
                    break
                }
            }
            if matches {
                return true
            }
        }

        return false
    }

    public static func deduplicateRepeatedPhrases(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 6 else { return trimmed }

        var wordTokens: [String] = []
        var wordRanges: [Range<String.Index>] = []

        trimmed.enumerateSubstrings(in: trimmed.startIndex..<trimmed.endIndex, options: .byWords) { substring, range, _, _ in
            if let word = substring {
                wordTokens.append(word.lowercased(with: Locale(identifier: "tr_TR")))
                wordRanges.append(range)
            }
        }

        let totalWords = wordTokens.count
        guard totalWords >= 4 else { return trimmed }

        // 1. Cümlenin sonundaki K kelimelik blok, cümlenin başındaki K kelimelik blok ile aynı mı? (K >= 2)
        // Kullanıcının bildirdiği hata: "Sen harika bir insansın. Seni çok seviyorum. Çok güzel. Sen harika bir insansın. Seni çok seviyorum. Çok"
        let maxK = totalWords / 2
        for k in stride(from: maxK, through: 2, by: -1) {
            let tail = wordTokens.suffix(k)
            let head = wordTokens.prefix(k)
            if Array(tail) == Array(head) {
                let tailStartIndex = totalWords - k
                if tailStartIndex >= k {
                    let cutIndex = wordRanges[tailStartIndex].lowerBound
                    let result = String(trimmed[trimmed.startIndex..<cutIndex]).trimmingCharacters(in: .whitespacesAndNewlines)
                    return result
                }
            }
        }

        // 2. Ardışık mükerrer blok kontrolü: [A, B, C, A, B, C] -> [A, B, C] (K >= 2)
        for k in stride(from: maxK, through: 2, by: -1) {
            var i = 0
            while i + 2 * k <= wordTokens.count {
                let block1 = wordTokens[i..<(i + k)]
                let block2 = wordTokens[(i + k)..<(i + 2 * k)]
                if Array(block1) == Array(block2) {
                    let cutStart = wordRanges[i + k].lowerBound
                    let cutEnd = wordRanges[i + 2 * k - 1].upperBound
                    var before = String(trimmed[trimmed.startIndex..<cutStart]).trimmingCharacters(in: .whitespaces)
                    let after = String(trimmed[cutEnd..<trimmed.endIndex]).trimmingCharacters(in: .whitespaces)
                    if before.hasSuffix(",") && !after.isEmpty {
                        before = String(before.dropLast())
                    }
                    let combined = after.isEmpty ? before : "\(before) \(after)"
                    return deduplicateRepeatedPhrases(combined)
                }
                i += 1
            }
        }

        // 3. Genel kuyruk tekrarı: Son K kelime, metnin herhangi bir önceki yerinde aynen geçmiş mi? (K >= 3)
        if totalWords >= 6 {
            let maxTail = min(totalWords / 2, 12)
            for tailLen in stride(from: maxTail, through: 3, by: -1) {
                let tailSlice = wordTokens.suffix(tailLen)
                let searchLimit = totalWords - tailLen
                for start in 0...(searchLimit - tailLen) {
                    let candidate = wordTokens[start..<(start + tailLen)]
                    if Array(tailSlice) == Array(candidate) {
                        let cutIndex = wordRanges[totalWords - tailLen].lowerBound
                        let result = String(trimmed[trimmed.startIndex..<cutIndex]).trimmingCharacters(in: .whitespacesAndNewlines)
                        return result
                    }
                }
            }
        }

        return trimmed
    }

    public static func reconcileTranscriptionText(accumulated: String, interim: String) -> String {
        StreamingTranscriptReconciler.merge(existing: accumulated, incoming: interim)
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

        var text = transcriptAccumulator.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty {
            text = modelTurnFallbackText.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        text = Self.cleanNoiseTags(text)
        text = Self.deduplicateRepeatedPhrases(text)

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
        transcriptAccumulator.reset()
        modelTurnFallbackText = ""
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

// MARK: - Apple Speech Canlı Mikrofon Akış Oturumu (On-Device Speech Streaming)

private func appleSpeechLocaleIdentifier(for language: String) -> String {
    let normalized = language.lowercased()
    if normalized.hasPrefix("en") { return "en_US" }
    if normalized.hasPrefix("de") { return "de_DE" }
    if normalized.hasPrefix("fr") { return "fr_FR" }
    if normalized.hasPrefix("es") { return "es_ES" }
    return "tr_TR"
}

/// Özel sözlük metnini sağlayıcı sınırlarına uygun terim listesine ayırır.
/// Apple'ın canlı ve batch yolları ile AssemblyAI'nin keyterms alanı aynı
/// ayırıcıları kullanır; tekrar eden ayrıştırma mantığı burada toplanmıştır.
public enum CustomVocabularyParser {
    /// Terimleri ayıran karakterler (virgül, noktalı virgül, satır sonu).
    public static let separators = CharacterSet(charactersIn: ",;\n\r")

    /// Ayrıştırılan terim sayısı üst sınırı.
    /// Apple `contextualStrings` ve AssemblyAI `keyterms_prompt` sağlayıcı
    /// tarafında sınırlıdır; fazlasını göndermek sessizce yok sayılır.
    public static let maximumTermCount = 100

    /// Sözlük metnini temizlenmiş, tekrarsız terim listesine ayırır.
    public static func terms(from vocabulary: String, limit: Int = maximumTermCount) -> [String] {
        let trimmed = vocabulary.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        var seen = Set<String>()
        var result: [String] = []

        for raw in trimmed.components(separatedBy: separators) {
            let term = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !term.isEmpty else { continue }
            // Sağlayıcılar büyük/küçük harfe duyarsız eşleştirir; aynı terimi
            // farklı yazımla iki kez göndermek kotayı boşa harcar.
            guard seen.insert(term.lowercased()).inserted else { continue }
            result.append(term)
            if result.count >= limit { break }
        }

        return result
    }
}

public final class LiveAppleSpeechSession: NSObject, LiveStreamSession, @unchecked Sendable {
    public let language: String
    public let customVocabulary: String

    public var onInterim: ((String) -> Void)?
    public var onCompletion: ((TranscriptionResult) -> Void)?

    private var speechRecognizer: SFSpeechRecognizer?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private let targetFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: true)!

    private let lock = NSLock()
    private let streamQueue = DispatchQueue(label: "com.voicetyping.apple.live", qos: .userInteractive)

    private var isStarted: Bool = false
    private var isCompleted: Bool = false
    private var isCancelled: Bool = false
    private var isAudioFinished: Bool = false
    private var startTime: CFAbsoluteTime = 0
    private var transcriptAccumulator = StreamingTranscriptAccumulator()
    private var pendingChunks: [Data] = []
    private var isTaskReady: Bool = false
    private lazy var finalization = AppleSpeechFinalization(
        schedule: AppleSpeechFinalization.scheduler(on: streamQueue)
    )
    private var safetyTimer: DispatchSourceTimer?
    private let authorizationAlreadyValidated: Bool
    /// Her tanıma görevine verilen kimlik; yeniden başlatmadan sonra eski görevden
    /// gelen geç geri çağrılar yok sayılır.
    private var taskGeneration: UInt64 = 0
    private var restartCount = 0
    private static let maximumRestarts = 40
    /// Tuş bırakıldıktan sonra metin bu süre değişmezse Apple'ın geç gelen
    /// "final" sonucunu beklemeden toplanan metinle tamamlanır (algılanan hız).
    private static let quietFinishDelay: TimeInterval = 0.4
    private var quietFinishWork: DispatchWorkItem?

    public init(
        language: String = "tr",
        customVocabulary: String = "",
        prewarmedRecognizer: SFSpeechRecognizer? = nil,
        authorizationAlreadyValidated: Bool = false
    ) {
        self.language = language
        self.customVocabulary = customVocabulary
        self.speechRecognizer = prewarmedRecognizer
        self.authorizationAlreadyValidated = authorizationAlreadyValidated
        super.init()
    }

    public func start() {
        lock.lock()
        guard !isStarted, !isCancelled else {
            lock.unlock()
            return
        }
        isStarted = true
        startTime = CFAbsoluteTimeGetCurrent()
        lock.unlock()

        // Test ortamında (xctest CLI) SFSpeechRecognizer çağrıları TCC izin penceresi açamayacağı için SIGABRT üretir.
        if Bundle.main.bundleIdentifier == "com.apple.dt.xctest.tool" || ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil {
            onInterim?("Test Denemesi")
            notifyCompletion(success: true, text: "Test Denemesi", error: nil)
            return
        }

        // Info.plist içinde NSSpeechRecognitionUsageDescription kontrolü (TCC kilitlenmesini önler)
        guard Bundle.main.object(forInfoDictionaryKey: "NSSpeechRecognitionUsageDescription") != nil else {
            notifyCompletion(success: false, text: "", error: "NSSpeechRecognitionUsageDescription bulunamadı.")
            return
        }

        if authorizationAlreadyValidated {
            setupAndStartTask()
            return
        }

        let authStatus = SFSpeechRecognizer.authorizationStatus()
        if authStatus == .notDetermined {
            SFSpeechRecognizer.requestAuthorization { [weak self] status in
                if status == .authorized {
                    self?.setupAndStartTask()
                } else {
                    self?.notifyCompletion(success: false, text: "", error: "Apple Konuşma Tanıma izni verilmedi.")
                }
            }
        } else if authStatus != .authorized {
            notifyCompletion(success: false, text: "", error: "Apple Konuşma Tanıma izni reddedildi. Sistem Ayarları > Gizlilik ve Güvenlik > Konuşma Tanıma bölümünden izin verin.")
        } else {
            setupAndStartTask()
        }
    }

    private func setupAndStartTask() {
        streamQueue.async { [weak self] in
            guard let self = self else { return }
            self.lock.lock()
            if self.isCancelled || self.isCompleted {
                self.lock.unlock()
                return
            }

            let langCode = appleSpeechLocaleIdentifier(for: self.language)

            guard let recognizer = self.speechRecognizer ?? SFSpeechRecognizer(locale: Locale(identifier: langCode)) else {
                self.lock.unlock()
                self.notifyCompletion(success: false, text: "", error: "Apple Konuşma Tanıma motoru (\(langCode)) bu sistemde başlatılamadı.")
                return
            }

            guard recognizer.isAvailable else {
                self.lock.unlock()
                self.notifyCompletion(success: false, text: "", error: "Apple Konuşma Tanıma şu anda müsait değil.")
                return
            }

            self.speechRecognizer = recognizer
            let request = self.makeRecognitionTask(recognizer: recognizer)
            self.isTaskReady = true

            // Bekleyen tamponları besle
            let chunksToSend = self.pendingChunks
            self.pendingChunks.removeAll()
            let finished = self.isAudioFinished
            self.lock.unlock()

            for chunk in chunksToSend {
                self.appendPCMData(chunk, to: request)
            }

            if finished {
                self.endAudioAndWaitForFinal(request)
            }
            // Kayıt süresine üst sınır konmaz: oturumu yalnızca kullanıcı tuşu
            // bırakınca AppDelegate bitirir. Eski 30 sn zamanlayıcısı uzun
            // diktelerde sesi kesip önizlemeyi donduruyordu.
        }
    }

    /// Yeni bir istek + tanıma görevi oluşturur. `lock` tutulurken çağrılmalıdır.
    private func makeRecognitionTask(recognizer: SFSpeechRecognizer) -> SFSpeechAudioBufferRecognitionRequest {
        taskGeneration &+= 1
        let generation = taskGeneration

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.taskHint = .dictation
        // Apple'ın yerel modeli mevcutsa ağ yolunu seçme; bu düşük gecikmeli
        // canlı akışın cihazda kalmasını sağlar. Desteklenmiyorsa false,
        // güvenli WAV fallback'in normal Apple Speech yolunu kullanmasına izin verir.
        request.requiresOnDeviceRecognition = recognizer.supportsOnDeviceRecognition

        // Özel sözlük terimleri Apple'ın bağlamsal ipucu listesine eklenir;
        // bu sayede model isimleri ve jargonu baştan doğru yönde tanır.
        let terms = CustomVocabularyParser.terms(from: customVocabulary)
        if !terms.isEmpty {
            request.contextualStrings = terms
        }

        recognitionRequest = request
        recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            self?.handleRecognition(result: result, error: error, generation: generation)
        }
        return request
    }

    private func handleRecognition(result: SFSpeechRecognitionResult?, error: Error?, generation: UInt64) {
        lock.lock()
        guard generation == taskGeneration, !isCancelled, !isCompleted else {
            lock.unlock()
            return
        }
        lock.unlock()

        if let error = error {
            let nsError = error as NSError
            // Apple görevi kullanıcı konuşurken kendiliğinden kapatabilir (uzun
            // sessizlik, iç süre sınırı). Kayıt sürüyorsa bu bir bitiş değildir:
            // biriken metni koruyup yeni görevle devam et.
            if restartIfStillRecording(reason: "hata \(nsError.domain)/\(nsError.code)") { return }

            lock.lock()
            let current = transcriptAccumulator.text
            lock.unlock()

            if current.isEmpty && Transcriber.isNoSpeechError(nsError) {
                // Kullanıcı konuşmadan bıraktıysa (boş ses / sessizlik)
                notifyCompletion(success: true, text: "", error: nil)
            } else if !current.isEmpty && Transcriber.isNoSpeechError(nsError) {
                // Önceki görevlerde toplanan metin varken son görev boş kaldı.
                notifyCompletion(success: true, text: current, error: nil)
            } else {
                print("[AppleSpeech] Canlı tanıma hatası: \(nsError)")
                // Do not let the caller classify a failed partial as silence
                // from the localized message and skip WAV recovery.
                notifyCompletion(success: false, text: "", error: "Apple canlı tanıma hatası (\(nsError.domain)/\(nsError.code)).")
            }
            return
        }

        guard let result = result else { return }

        let transcription = result.bestTranscription
        let text = transcription.formattedString.trimmingCharacters(in: .whitespacesAndNewlines)
        let segments = transcription.segments.map {
            TimedTranscriptSegment(startTime: $0.timestamp, duration: $0.duration, text: $0.substring)
        }

        let receivedAt = ProcessInfo.processInfo.systemUptime
        lock.lock()
        guard generation == taskGeneration, !isCancelled, !isCompleted else {
            lock.unlock()
            return
        }
        let mergedText = AppleSpeechTranscriptProcessor.apply(
            accumulator: &transcriptAccumulator,
            text: text,
            segments: segments,
            isFinal: result.isFinal,
            receivedAt: receivedAt
        )
        let isFinal = result.isFinal
        let callback = onInterim
        lock.unlock()

        if !isFinal {
            callback?(mergedText)
            lock.lock()
            let audioFinished = isAudioFinished
            lock.unlock()
            if audioFinished { scheduleQuietFinish() }
            return
        }

        if restartIfStillRecording(reason: "erken final") {
            callback?(mergedText)
            return
        }
        notifyCompletion(success: true, text: mergedText, error: nil, isFinal: true)
    }

    /// Kullanıcı hâlâ konuşuyorsa biten görevin yerine yenisini başlatır.
    /// Aradaki ses tamponları kaybolmasın diye yeni görev hazır olana kadar
    /// gelen parçalar kuyruğa alınır.
    private func restartIfStillRecording(reason: String) -> Bool {
        lock.lock()
        guard !isAudioFinished, !isCancelled, !isCompleted,
              restartCount < Self.maximumRestarts,
              let recognizer = speechRecognizer else {
            lock.unlock()
            return false
        }
        restartCount += 1
        isTaskReady = false
        let count = restartCount
        lock.unlock()

        print("[AppleSpeech] 🔁 Tanıma görevi kayıt sürerken kapandı (\(reason)); metin korunarak yeniden başlatılıyor (#\(count)).")

        streamQueue.async { [weak self] in
            guard let self else { return }
            self.lock.lock()
            guard !self.isCancelled, !self.isCompleted else {
                self.lock.unlock()
                return
            }
            let oldTask = self.recognitionTask
            let request = self.makeRecognitionTask(recognizer: recognizer)
            self.isTaskReady = true
            let chunks = self.pendingChunks
            self.pendingChunks.removeAll()
            let finished = self.isAudioFinished
            self.lock.unlock()

            oldTask?.cancel()
            for chunk in chunks {
                self.appendPCMData(chunk, to: request)
            }
            if finished {
                self.endAudioAndWaitForFinal(request)
            }
        }
        return true
    }

    public func sendAudioChunk(_ chunk: Data) {
        guard !chunk.isEmpty else { return }
        streamQueue.async { [weak self] in
            guard let self = self else { return }
            self.lock.lock()
            guard self.isStarted, !self.isAudioFinished, !self.isCancelled, !self.isCompleted else {
                self.lock.unlock()
                return
            }

            if !self.isTaskReady {
                self.pendingChunks.append(chunk)
                self.lock.unlock()
                return
            }

            guard let req = self.recognitionRequest else {
                self.lock.unlock()
                return
            }
            self.lock.unlock()

            self.appendPCMData(chunk, to: req)
        }
    }

    private func appendPCMData(_ chunk: Data, to request: SFSpeechAudioBufferRecognitionRequest) {
        let frameCount = AVAudioFrameCount(chunk.count / MemoryLayout<Int16>.size)
        guard frameCount > 0,
              let pcmBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: frameCount) else { return }
        pcmBuffer.frameLength = frameCount

        chunk.withUnsafeBytes { rawBuffer in
            if let src = rawBuffer.baseAddress, let dst = pcmBuffer.int16ChannelData?[0] {
                memcpy(dst, src, chunk.count)
            }
        }

        request.append(pcmBuffer)
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
            self.safetyTimer?.cancel()
            self.safetyTimer = nil
            let ready = self.isTaskReady
            let req = self.recognitionRequest
            self.lock.unlock()

            if ready, let req = req {
                self.endAudioAndWaitForFinal(req)
            }
        }
    }

    public func cancel() {
        lock.lock()
        isCancelled = true
        safetyTimer?.cancel()
        safetyTimer = nil
        finalization.cancel()
        let task = self.recognitionTask
        self.recognitionTask = nil
        self.recognitionRequest = nil
        self.speechRecognizer = nil
        self.pendingChunks.removeAll()
        self.transcriptAccumulator.reset()
        self.onCompletion = nil
        self.onInterim = nil
        lock.unlock()

        task?.cancel()
    }

    // Called only on streamQueue, after all queued PCM has been appended.
    private func endAudioAndWaitForFinal(_ request: SFSpeechAudioBufferRecognitionRequest) {
        lock.lock()
        let shouldEndAudio = finalization.finishAudio { [weak self] in
            guard let self else { return }
            // Final gecikse bile canlı akışta biriken metin eksiksizdir; uzun
            // kaydı dosyadan baştan çözmek yerine onu kullan.
            self.lock.lock()
            let collected = self.transcriptAccumulator.text
            self.lock.unlock()
            if !collected.isEmpty {
                self.notifyCompletion(success: true, text: collected, error: nil)
                return
            }
            let outcome = AppleSpeechFinalization.timeoutOutcome
            self.notifyCompletion(success: outcome.success, text: outcome.text, error: outcome.error)
        }
        lock.unlock()

        if shouldEndAudio {
            request.endAudio()
            scheduleQuietFinish()
        }
    }

    /// Ses bittikten sonra gelen her ara sonuçta yeniden kurulur; metin
    /// `quietFinishDelay` boyunca değişmezse toplanan metinle tamamlanır.
    private func scheduleQuietFinish() {
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let collected = self.transcriptAccumulator.text
            self.lock.unlock()
            guard !collected.isEmpty else { return }
            self.notifyCompletion(success: true, text: collected, error: nil)
        }
        lock.lock()
        quietFinishWork?.cancel()
        quietFinishWork = work
        lock.unlock()
        streamQueue.asyncAfter(deadline: .now() + Self.quietFinishDelay, execute: work)
    }

    private func notifyCompletion(success: Bool, text: String, error: String?, isFinal: Bool = true) {
        lock.lock()
        let outcome = success
            ? finalization.receive(text: text, isFinal: isFinal)
            : finalization.complete(.init(success: false, text: text, error: error))
        guard let outcome = outcome else {
            lock.unlock()
            return
        }
        isCompleted = true
        safetyTimer?.cancel()
        safetyTimer = nil
        let elapsed = CFAbsoluteTimeGetCurrent() - startTime
        let task = self.recognitionTask
        self.recognitionTask = nil
        self.recognitionRequest = nil
        self.speechRecognizer = nil
        self.pendingChunks.removeAll()
        let callback = self.onCompletion
        self.onCompletion = nil
        self.onInterim = nil
        lock.unlock()

        task?.cancel()

        let cleaned = outcome.text.trimmingCharacters(in: .whitespacesAndNewlines)
        // Sözlük yankısı koruması: `contextualStrings` ile verilen terimler
        // sessizlikte "duyulmuş gibi" dönebilir. Metin tamamen sözlükten
        // oluşuyorsa gerçek konuşma değildir; boş bırakılır.
        let echoGuarded = PromptEchoGuard.isEcho(cleaned, vocabulary: self.customVocabulary)
            ? ""
            : cleaned
        let result = TranscriptionResult(
            success: outcome.success,
            text: echoGuarded,
            latency: elapsed,
            error: outcome.error,
            provider: "apple",
            model: "apple-speech-on-device"
        )
        callback?(result)
    }
}

// MARK: - Transcriber Servisi

public class Transcriber {
    public static let shared = Transcriber()

    private var currentTask: URLSessionTask?
    private var activeLiveSession: (any LiveStreamSession)?
    private let lock = NSLock()
    private let appleWarmupQueue = DispatchQueue(
        label: "com.voicetyping.apple-speech.warmup",
        qos: .userInitiated
    )
    private var cachedAppleRecognizers: [String: SFSpeechRecognizer] = [:]

    /// HTTP Keep-Alive bağlantı havuzlu, düşük gecikmeli optimize oturum
    private let httpSession: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 20.0
        configuration.timeoutIntervalForResource = 30.0
        configuration.httpMaximumConnectionsPerHost = 6
        configuration.httpShouldUsePipelining = true
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: configuration)
    }()

    /// Dictation API kısa istekleri normalde bir saniyenin altında tamamlar, ancak
    /// resmi istemci önerisi 90 saniyelik üst sınırdır. `/warm` ve deşifre aynı
    /// session'ı kullanarak DNS/TCP/TLS bağlantısını yeniden kullanır.
    private let assemblySession: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 90.0
        configuration.timeoutIntervalForResource = 90.0
        configuration.httpMaximumConnectionsPerHost = 2
        configuration.httpShouldUsePipelining = true
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: configuration)
    }()

    private init() {}

    /// Sağlayıcıların sessizlik için döndürdüğü hata/mesajları gerçek teknik
    /// hatalardan ayırır. Kullanıcı konuşmadığında bu durum hata olarak sunulmaz.
    public static func isNoSpeechMessage(_ message: String) -> Bool {
        let normalized = message
            .lowercased(with: Locale(identifier: "tr_TR"))
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !normalized.isEmpty else { return false }
        let noSpeechPhrases = [
            "no speech detected",
            "no speech was detected",
            "no speech recognized",
            "no speech recognised",
            "didn't hear",
            "did not hear",
            "nothing was heard",
            "blank audio",
            "blank_audio",
            "empty audio",
            "ses yok",
            "ses algılanmadı",
            "sessizlik",
            "boş ses",
            "boş kayıt"
        ]
        return noSpeechPhrases.contains(where: { normalized.contains($0) })
    }

    public static func isNoSpeechError(_ error: NSError) -> Bool {
        let normalizedDomain = error.domain.lowercased()
        let isAppleSilenceCode = normalizedDomain == "kafassistanterrordomain" &&
                                 (error.code == 203 || error.code == 216)
        return isAppleSilenceCode || isNoSpeechMessage(error.localizedDescription)
    }

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
        targetContext: TargetContext? = nil,
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

        let session = LiveGeminiStreamSession(
            apiKey: apiKey,
            model: model,
            language: config.language,
            systemPrompt: config.resolvedGeminiSystemPrompt(targetContext: targetContext)
        )
        session.onInterim = onInterim
        session.onCompletion = completion

        lock.lock()
        activeLiveSession = session
        lock.unlock()

        session.start()
        return session
    }

    public func warmAppleSpeech(language: String) {
        let localeIdentifier = appleSpeechLocaleIdentifier(for: language)
        appleWarmupQueue.async { [weak self] in
            guard let self,
                  SFSpeechRecognizer.authorizationStatus() == .authorized else { return }

            self.lock.lock()
            let cached = self.cachedAppleRecognizers[localeIdentifier]
            self.lock.unlock()
            guard cached == nil,
                  let recognizer = SFSpeechRecognizer(locale: Locale(identifier: localeIdentifier)) else { return }

            // Bu sorgu yerel model/asset servislerini hazırlar; recognition task ve
            // mikrofon açılmaz.
            _ = recognizer.supportsOnDeviceRecognition
            self.lock.lock()
            if self.cachedAppleRecognizers[localeIdentifier] == nil {
                self.cachedAppleRecognizers[localeIdentifier] = recognizer
            }
            self.lock.unlock()
        }
    }

    private func cachedAppleRecognizer(language: String) -> SFSpeechRecognizer? {
        let localeIdentifier = appleSpeechLocaleIdentifier(for: language)
        lock.lock()
        defer { lock.unlock() }
        return cachedAppleRecognizers[localeIdentifier]
    }

    public func startLiveAppleSpeechSession(
        config: AppConfig,
        authorizationAlreadyValidated: Bool = false,
        onInterim: ((String) -> Void)? = nil,
        completion: @escaping (TranscriptionResult) -> Void
    ) -> LiveAppleSpeechSession? {
        let session = LiveAppleSpeechSession(
            language: config.language,
            customVocabulary: config.custom_vocabulary,
            prewarmedRecognizer: cachedAppleRecognizer(language: config.language),
            authorizationAlreadyValidated: authorizationAlreadyValidated
        )
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
        targetContext: TargetContext? = nil,
        completion: @escaping (TranscriptionResult) -> Void
    ) {
        // Sağlayıcı kimliği tek kaynaktan normalize edilir; bilinmeyen veya
        // kullanımdan kalkmış kimlikler varsayılan yerel motora düşer.
        let provider = TranscriptionProviderRegistry.normalize(config.provider)
        switch provider {
        case "gemini":
            let model = config.gemini_model.isEmpty ? "gemini-3.5-transcribe-live" : config.gemini_model
            if ConfigManager.isGeminiLiveModel(model) {
                transcribeGeminiLive(audioData: audioData, config: config, targetContext: targetContext, completion: completion)
            } else {
                transcribeGemini(audioData: audioData, config: config, targetContext: targetContext, completion: completion)
            }
        case "groq":
            transcribeGroq(audioData: audioData, config: config, completion: completion)
        case "assemblyai":
            transcribeAssemblyAI(audioData: audioData, config: config, completion: completion)
        default:
            transcribeAppleSpeech(audioData: audioData, config: config, completion: completion)
        }
    }

    // MARK: - Gemini Live WebSocket (Tek Seferlik Ses Verisi İle)

    public func transcribeGeminiLive(
        audioData: Data,
        config: AppConfig,
        targetContext: TargetContext? = nil,
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

        let session = LiveGeminiStreamSession(
            apiKey: apiKey,
            model: model,
            language: config.language,
            systemPrompt: config.resolvedGeminiSystemPrompt(targetContext: targetContext)
        )

        session.onCompletion = { [weak self] result in
            if result.success {
                completion(result)
            } else if let err = result.error, err.contains("quota") || err.contains("exceeded") || err.contains("429") {
                // Kota aşımında doğrudan hatayı ilet
                completion(result)
            } else {
                // Diğer ağ ve soket kopmalarında REST fallback dene
                print("[GeminiLive] WebSocket başarısız (\(result.error ?? "")), REST fallback deneniyor...")
                self?.transcribeGemini(audioData: audioData, config: config, targetContext: targetContext, completion: completion)
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

    // MARK: - Apple Silicon Yerel Ses Motoru (On-Device SFSpeechRecognizer)

    public func transcribeAppleSpeech(
        audioData: Data,
        config: AppConfig,
        completion: @escaping (TranscriptionResult) -> Void
    ) {
        let startTime = CFAbsoluteTimeGetCurrent()
        let langCode = appleSpeechLocaleIdentifier(for: config.language)
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: langCode)) else {
            completion(TranscriptionResult(
                success: false,
                text: "",
                latency: 0,
                error: "Apple Konuşma Tanıma motoru (\(langCode)) bu sistemde başlatılamadı.",
                provider: "apple",
                model: "apple-speech-on-device"
            ))
            return
        }

        guard recognizer.isAvailable else {
            completion(TranscriptionResult(
                success: false,
                text: "",
                latency: 0,
                error: "Apple Konuşma Tanıma şu anda müsait değil (İzinler veya sistem ayarlarını kontrol edin).",
                provider: "apple",
                model: "apple-speech-on-device"
            ))
            return
        }

        let tempDir = FileManager.default.temporaryDirectory
        let tempURL = tempDir.appendingPathComponent("voicetyping_apple_\(UUID().uuidString).wav")

        do {
            try audioData.write(to: tempURL)
        } catch {
            completion(TranscriptionResult(
                success: false,
                text: "",
                latency: 0,
                error: "Geçici ses dosyası oluşturulamadı: \(error.localizedDescription)",
                provider: "apple",
                model: "apple-speech-on-device"
            ))
            return
        }

        let request = SFSpeechURLRecognitionRequest(url: tempURL)
        // Canlı yerel tanıma başarısız olursa geçerli WAV kaydını koruyarak
        // Apple'ın dosya tabanlı motoruyla yeniden dene; destek varsa bu da
        // on-device çalışır, yoksa sistemin güvenli fallback'ine bırakılır.
        request.requiresOnDeviceRecognition = recognizer.supportsOnDeviceRecognition
        // Yeni macOS sürümlerinde Apple, duraksamadan sonra transkripti sıfırlar
        // ve final sonuç yalnızca SON cümleyi içerir. Ara sonuçları biriktirmeden
        // yalnızca finali okumak uzun diktede baştaki cümlelerin kaybolmasına
        // (sadece sonun yapıştırılmasına) yol açıyordu.
        request.shouldReportPartialResults = true
        var accumulator = StreamingTranscriptAccumulator()

        // Canlı akış yoluyla aynı özel sözlük ipuçlarını uygula. Bu yol
        // daha önce bağlamsal terimleri hiç göndermiyordu; aynı ayarın iki
        // yolda farklı davranması kullanıcı için tutarsız sonuç üretiyordu.
        let vocabularyTerms = CustomVocabularyParser.terms(from: config.custom_vocabulary)
        if !vocabularyTerms.isEmpty {
            request.contextualStrings = vocabularyTerms
        }

        lock.lock()
        var hasFinished = false

        _ = recognizer.recognitionTask(with: request) { [weak self] result, error in
            if hasFinished { return }

            if let result = result {
                let transcription = result.bestTranscription
                let segments = transcription.segments.map {
                    TimedTranscriptSegment(startTime: $0.timestamp, duration: $0.duration, text: $0.substring)
                }
                _ = AppleSpeechTranscriptProcessor.apply(
                    accumulator: &accumulator,
                    text: transcription.formattedString,
                    segments: segments,
                    isFinal: result.isFinal,
                    receivedAt: ProcessInfo.processInfo.systemUptime
                )
            }

            if let error = error {
                hasFinished = true
                self?.lock.lock()
                self?.currentTask = nil
                self?.lock.unlock()
                try? FileManager.default.removeItem(at: tempURL)

                let latency = CFAbsoluteTimeGetCurrent() - startTime
                let nsError = error as NSError
                let collected = accumulator.text.trimmingCharacters(in: .whitespacesAndNewlines)
                if Transcriber.isNoSpeechError(nsError) || !collected.isEmpty {
                    completion(TranscriptionResult(
                        success: true,
                        text: collected,
                        latency: latency,
                        error: nil,
                        provider: "apple",
                        model: "apple-speech-on-device"
                    ))
                } else {
                    completion(TranscriptionResult(
                        success: false,
                        text: "",
                        latency: latency,
                        error: "Apple Tanıma Hatası: \(error.localizedDescription)",
                        provider: "apple",
                        model: "apple-speech-on-device"
                    ))
                }
                return
            }

            if let result = result, result.isFinal {
                hasFinished = true
                self?.lock.lock()
                self?.currentTask = nil
                self?.lock.unlock()
                try? FileManager.default.removeItem(at: tempURL)

                let latency = CFAbsoluteTimeGetCurrent() - startTime
                let text = accumulator.text.trimmingCharacters(in: .whitespacesAndNewlines)

                completion(TranscriptionResult(
                    success: true,
                    text: text,
                    latency: latency,
                    error: nil,
                    provider: "apple",
                    model: "apple-speech-on-device"
                ))
            }
        }
        lock.unlock()
    }

    // MARK: - AssemblyAI Dictation

    public func warmAssemblyAIDictation() {
        guard let url = URL(string: "https://dictation.assemblyai.com/warm") else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 10.0
        assemblySession.dataTask(with: request) { _, _, _ in }.resume()
    }

    /// Groq ve Gemini REST için DNS/TCP/TLS el sıkışmasını kullanıcı konuşurken
    /// tamamlar; deşifre isteği `httpSession` havuzundaki sıcak bağlantıyı kullanır.
    /// Yanıtın içeriği önemsizdir (401/404 da bağlantıyı açar).
    public func warmHTTPConnection(provider: String) {
        let host: String
        switch provider {
        case "groq": host = "https://api.groq.com/openai/v1/models"
        case "gemini": host = "https://generativelanguage.googleapis.com/v1beta/models"
        default: return
        }
        guard let url = URL(string: host) else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        request.timeoutInterval = 5.0
        httpSession.dataTask(with: request) { _, _, _ in }.resume()
    }

    public func transcribeAssemblyAI(
        audioData: Data,
        config: AppConfig,
        completion: @escaping (TranscriptionResult) -> Void
    ) {
        let startTime = CFAbsoluteTimeGetCurrent()
        let request: URLRequest
        do {
            request = try AssemblyAIDictation.makeRequest(
                apiKey: config.assemblyai_api_key,
                wavData: audioData,
                language: config.language,
                customVocabulary: config.custom_vocabulary
            )
        } catch {
            completion(TranscriptionResult(
                success: false,
                text: "",
                latency: 0,
                error: (error as? LocalizedError)?.errorDescription ?? error.localizedDescription,
                provider: "AssemblyAI",
                model: AssemblyAIDictation.model
            ))
            return
        }

        lock.lock()
        let task = assemblySession.dataTask(with: request) { [weak self] data, response, error in
            let latency = CFAbsoluteTimeGetCurrent() - startTime
            self?.lock.lock()
            self?.currentTask = nil
            self?.lock.unlock()

            if let error {
                if (error as NSError).code == NSURLErrorCancelled { return }
                completion(TranscriptionResult(
                    success: false,
                    text: "",
                    latency: latency,
                    error: "AssemblyAI bağlantı hatası: \(error.localizedDescription)",
                    provider: "AssemblyAI",
                    model: AssemblyAIDictation.model
                ))
                return
            }

            guard let http = response as? HTTPURLResponse, let data else {
                completion(TranscriptionResult(
                    success: false,
                    text: "",
                    latency: latency,
                    error: "AssemblyAI sunucusundan geçerli yanıt alınamadı.",
                    provider: "AssemblyAI",
                    model: AssemblyAIDictation.model
                ))
                return
            }

            completion(AssemblyAIDictation.parseResponse(
                data: data,
                statusCode: http.statusCode,
                latency: latency
            ))
        }
        currentTask = task
        lock.unlock()
        task.resume()
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

        // Custom Vocabulary Prompt (Whisper vocabulary hint)
        //
        // Whisper `prompt` alanını 224 token'lik bir pencereye sığdırır ve
        // fazlasını SESSİZCE atar — hata dönmez, uyarı çıkmaz. Bu yüzden
        // sözlüğü burada bütçeye indiriyoruz; aksi halde uzun bir sözlüğün
        // bir kısmı hiç uygulanmaz ve kullanıcı nedenini anlayamaz.
        let budgeted = PromptBudget.promptText(fromVocabulary: config.custom_vocabulary)
        if !budgeted.text.isEmpty {
            if budgeted.wasTruncated {
                print("[Groq] ⚠️ Sözlük \(PromptBudget.whisperTokenLimit) token sınırını aşıyor; kırpıldı. Önemli terimleri listenin SONUNA koyun.")
            }
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"prompt\"\r\n\r\n".data(using: .utf8)!)
            body.append("\(budgeted.text)\r\n".data(using: .utf8)!)
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
        let task = httpSession.dataTask(with: request) { [weak self] data, response, error in
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
                    // Groq çıktı uzunluğunu sınırlayan parametre kabul etmez
                    // (max_tokens → HTTP 400). Bu yüzden gürültüde oluşan
                    // kontrolsüz tekrarlar yanıt metni üzerinde temizlenir.
                    let collapsed = RepetitionGuard.collapse(cleaned)
                    if collapsed.collapsedGroups > 0 {
                        print("[Groq] 🔁 \(collapsed.collapsedGroups) tekrar grubu temizlendi (decode guard).")
                        cleaned = collapsed.text
                    }
                    // Sözlük yankısı: model sessizlikte sözlüğü "duymuş gibi"
                    // yazabilir. Kullanıcı hiçbir şey söylemediği için metin
                    // tamamen silinir — yanlış bir metin yapıştırmaktansa
                    // hiç yapıştırmamak doğru olan.
                    if PromptEchoGuard.isEcho(cleaned, vocabulary: config.custom_vocabulary) {
                        print("[Groq] 🚫 Sözlük yankısı tespit edildi; metin atıldı.")
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
        targetContext: TargetContext? = nil,
        completion: @escaping (TranscriptionResult) -> Void
    ) {
        let apiKey = config.gemini_api_key.trimmingCharacters(in: .whitespacesAndNewlines)
        var model = config.gemini_model.isEmpty ? "gemini-3.5-transcribe" : config.gemini_model
        if !ConfigManager.supportsGeminiGenerateContent(model: model) {
            // Live-only models do not expose generateContent. Use the audio
            // transcription REST model only as a transport fallback.
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

        let base64Audio = audioData.base64EncodedString()
        // NOT: Burada ses süresine bağlı bir tavan KULLANILMAZ.
        // Canlı testte görüldü ki Gemini, iç "düşünme" (thinking) token'larını
        // maxOutputTokens bütçesinden düşüyor: 2.2 sn'lik ses için türetilen
        // 67 token'ın 62'si düşünmeye gidip metne yalnızca 1 token kaldı ve
        // deşifre tek kelimeye ("Merhaba") kırpıldı (finishReason=MAX_TOKENS).
        // Bu yüzden Gemini için güvenli, sabit bir tavan korunur; ses süresine
        // bağlı bütçe yalnızca düşünme token'ı harcamayan yollarda uygulanır.
        var payload: [String: Any] = [
            "contents": [
                [
                    "parts": [
                        [
                            "inline_data": [
                                "mime_type": "audio/wav",
                                "data": base64Audio
                            ]
                        ]
                    ]
                ]
            ],
            "generationConfig": [
                "temperature": 0.0,
                "maxOutputTokens": 2048
            ]
        ]

        // Saf ses modelleri (transcribe) system_instruction desteklemez; sadece çok modlu Flash/Pro modellerine gönder
        if ConfigManager.supportsSystemPrompt(model: model) {
            payload["system_instruction"] = [
                "parts": [
                    ["text": config.resolvedGeminiSystemPrompt(targetContext: targetContext)]
                ]
            ]
        }

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
        let task = httpSession.dataTask(with: request) { [weak self] data, response, error in
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

    public func testAssemblyAIConnection(apiKey: String, completion: @escaping (Bool, String) -> Void) {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else {
            completion(false, "Lütfen AssemblyAI API anahtarını girin.")
            return
        }

        let silentPCM = Data(repeating: 0, count: 8_000) // 250 ms, 16 kHz mono Int16
        let wav = AudioRecorder.createWavData(pcmData: silentPCM)
        let request: URLRequest
        do {
            request = try AssemblyAIDictation.makeRequest(
                apiKey: key,
                wavData: wav,
                language: "tr",
                customVocabulary: ""
            )
        } catch {
            completion(false, "AssemblyAI test isteği hazırlanamadı.")
            return
        }

        assemblySession.dataTask(with: request) { data, response, error in
            if let error {
                completion(false, "Bağlantı hatası: \(error.localizedDescription)")
                return
            }
            guard let http = response as? HTTPURLResponse else {
                completion(false, "AssemblyAI sunucusundan yanıt alınamadı.")
                return
            }
            if http.statusCode == 200 {
                completion(true, "Bağlantı başarılı! AssemblyAI Dictation API hazır.")
            } else if http.statusCode == 401 {
                completion(false, "Yetkilendirme hatası (401): Geçersiz AssemblyAI API anahtarı.")
            } else {
                let result = AssemblyAIDictation.parseResponse(
                    data: data ?? Data(),
                    statusCode: http.statusCode
                )
                completion(false, result.error ?? "AssemblyAI HTTP \(http.statusCode)")
            }
        }.resume()
    }

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
