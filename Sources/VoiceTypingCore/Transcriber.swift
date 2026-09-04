import Foundation

public struct TranscriptionResult {
    public var success: Bool
    public var text: String
    public var latency: Double
    public var error: String?
    public var provider: String
    public var model: String
}

public class Transcriber {
    public static let shared = Transcriber()

    private var currentTask: URLSessionTask?
    private let lock = NSLock()

    private init() {}

    public func cancel() {
        lock.lock()
        defer { lock.unlock() }
        currentTask?.cancel()
        currentTask = nil
    }

    public func transcribe(
        audioData: Data,
        config: AppConfig,
        completion: @escaping (TranscriptionResult) -> Void
    ) {
        let provider = config.provider.lowercased()
        if provider == "gemini" {
            transcribeGemini(audioData: audioData, config: config, completion: completion)
        } else {
            transcribeGroq(audioData: audioData, config: config, completion: completion)
        }
    }

    // MARK: - Groq Whisper

    public func transcribeGroq(
        audioData: Data,
        config: AppConfig,
        completion: @escaping (TranscriptionResult) -> Void
    ) {
        let apiKey = config.groq_api_key.trimmingCharacters(in: .whitespacesAndNewlines)
        let model = config.groq_model.isEmpty ? "whisper-large-v3-turbo" : config.groq_model

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

    // MARK: - Google Gemini

    public func transcribeGemini(
        audioData: Data,
        config: AppConfig,
        completion: @escaping (TranscriptionResult) -> Void
    ) {
        let apiKey = config.gemini_api_key.trimmingCharacters(in: .whitespacesAndNewlines)
        let model = config.gemini_model.isEmpty ? "gemini-3.5-flash" : config.gemini_model

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
}
