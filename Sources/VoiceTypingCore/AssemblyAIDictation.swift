import Foundation

public enum AssemblyAIDictationError: Error, Equatable, LocalizedError {
    case missingAPIKey
    case invalidWAV
    case unsupportedWAVFormat
    case audioTooLong(maximumSeconds: Double)
    case requestEncodingFailed

    public var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return "AssemblyAI API anahtarı eksik."
        case .invalidWAV:
            return "Ses verisi geçerli bir WAV dosyası değil."
        case .unsupportedWAVFormat:
            return "AssemblyAI Dictation yalnızca 16-bit PCM WAV sesi kabul eder."
        case .audioTooLong(let maximumSeconds):
            return "AssemblyAI Dictation sesi en fazla \(Int(maximumSeconds)) saniye olabilir."
        case .requestEncodingFailed:
            return "AssemblyAI Dictation isteği kodlanamadı."
        }
    }
}

public enum AssemblyAIDictation {
    public static let endpoint = URL(string: "https://dictation.assemblyai.com/v1/transcribe/live")!
    /// Dictation API does not expose model selection, but AssemblyAI documents
    /// that the service runs on Universal-3.5 Pro.
    public static let model = "universal-3.5-pro"
    public static let maximumAudioDuration: TimeInterval = 120
    public static let requiredBitsPerSample = 16

    public static func makeRequest(
        apiKey: String,
        wavData: Data,
        language: String,
        customVocabulary: String
    ) throws -> URLRequest {
        try makeRequest(
            apiKey: apiKey,
            wavData: wavData,
            language: language,
            customVocabulary: customVocabulary,
            boundary: "VoiceTyping-\(UUID().uuidString)"
        )
    }

    static func makeRequest(
        apiKey: String,
        wavData: Data,
        language: String,
        customVocabulary: String,
        boundary: String
    ) throws -> URLRequest {
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty else {
            throw AssemblyAIDictationError.missingAPIKey
        }

        try validateWAV(wavData)

        var config: [String: Any] = [
            "language_codes": [normalizedLanguage(language)],
            "stt_prompt": contextualPrompt(language: language)
        ]
        let keyterms = parsedKeyterms(customVocabulary)
        if !keyterms.isEmpty {
            config["keyterms_prompt"] = keyterms
        }

        guard JSONSerialization.isValidJSONObject(config),
              let configData = try? JSONSerialization.data(withJSONObject: config, options: [.sortedKeys]) else {
            throw AssemblyAIDictationError.requestEncodingFailed
        }

        var body = Data()
        append("--\(boundary)\r\n", to: &body)
        append("Content-Disposition: form-data; name=\"config\"\r\n", to: &body)
        append("Content-Type: application/json\r\n\r\n", to: &body)
        body.append(configData)
        append("\r\n", to: &body)

        append("--\(boundary)\r\n", to: &body)
        append("Content-Disposition: form-data; name=\"audio\"; filename=\"audio.wav\"\r\n", to: &body)
        append("Content-Type: audio/wav\r\n\r\n", to: &body)
        body.append(wavData)
        append("\r\n--\(boundary)--\r\n", to: &body)

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue(trimmedKey, forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = body
        return request
    }

    public static func parseResponse(
        data: Data,
        statusCode: Int,
        latency: Double = 0
    ) -> TranscriptionResult {
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]

        guard statusCode == 200 else {
            let message = errorMessage(from: json)
                ?? "AssemblyAI Dictation isteği başarısız (HTTP \(statusCode))."
            return TranscriptionResult(
                success: false,
                text: "",
                latency: latency,
                error: message,
                provider: "AssemblyAI",
                model: model
            )
        }

        guard let json else {
            return TranscriptionResult(
                success: false,
                text: "",
                latency: latency,
                error: "AssemblyAI Dictation yanıtı okunamadı.",
                provider: "AssemblyAI",
                model: model
            )
        }

        let rewritten = nonemptyString(json["llm_response"])
        let transcript = nonemptyString(json["text"]) ?? ""
        return TranscriptionResult(
            success: true,
            text: rewritten ?? transcript,
            latency: latency,
            provider: "AssemblyAI",
            model: model
        )
    }

    static func normalizedLanguage(_ language: String) -> String {
        let trimmed = language.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed.caseInsensitiveCompare("auto") == .orderedSame {
            return "tr"
        }
        if trimmed.replacingOccurrences(of: "_", with: "-").caseInsensitiveCompare("tr-TR") == .orderedSame {
            return "tr"
        }
        return trimmed
    }

    static func contextualPrompt(language: String) -> String {
        switch normalizedLanguage(language).lowercased() {
        case "tr":
            return "A person dictating natural Turkish text into a macOS text field, using conversational language, names, short commands, and occasional software terminology."
        case "en":
            return "A person dictating natural English text into a macOS text field, using conversational language, names, short commands, and occasional software terminology."
        default:
            return "A person dictating natural text into a macOS text field, using conversational language, names, short commands, and occasional software terminology."
        }
    }

    static func parsedKeyterms(_ customVocabulary: String) -> [String] {
        // Ayırma ve tekilleştirme mantığı artık ortak yardımcıda; Apple ve
        // AssemblyAI aynı sözlük girdisinden aynı terim listesini üretir.
        return CustomVocabularyParser.terms(from: customVocabulary)
    }

    private static func append(_ string: String, to data: inout Data) {
        data.append(Data(string.utf8))
    }

    private static func nonemptyString(_ value: Any?) -> String? {
        guard let string = value as? String else { return nil }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func errorMessage(from json: [String: Any]?) -> String? {
        guard let json else { return nil }
        return readableError(json["detail"]) ?? readableError(json["error"])
    }

    private static func readableError(_ value: Any?) -> String? {
        if let message = nonemptyString(value) {
            return message
        }
        if let dictionary = value as? [String: Any] {
            return nonemptyString(dictionary["message"])
                ?? nonemptyString(dictionary["msg"])
                ?? nonemptyString(dictionary["detail"])
        }
        if let items = value as? [Any] {
            let messages = items.compactMap(readableError)
            return messages.isEmpty ? nil : messages.joined(separator: "; ")
        }
        return nil
    }

    private static func validateWAV(_ data: Data) throws {
        guard data.count >= 12,
              ascii(in: data, range: 0..<4) == "RIFF",
              ascii(in: data, range: 8..<12) == "WAVE" else {
            throw AssemblyAIDictationError.invalidWAV
        }

        var offset = 12
        var format: (audioFormat: UInt16, byteRate: UInt32, bitsPerSample: UInt16)?
        var audioByteCount: UInt32?

        while offset + 8 <= data.count {
            guard let chunkSize = uint32LE(in: data, at: offset + 4) else {
                throw AssemblyAIDictationError.invalidWAV
            }
            let payloadOffset = offset + 8
            let payloadSize = Int(chunkSize)
            guard payloadSize <= data.count - payloadOffset else {
                throw AssemblyAIDictationError.invalidWAV
            }

            let chunkID = ascii(in: data, range: offset..<(offset + 4))
            if chunkID == "fmt " {
                guard payloadSize >= 16,
                      let audioFormat = uint16LE(in: data, at: payloadOffset),
                      let byteRate = uint32LE(in: data, at: payloadOffset + 8),
                      let bitsPerSample = uint16LE(in: data, at: payloadOffset + 14) else {
                    throw AssemblyAIDictationError.invalidWAV
                }
                format = (audioFormat, byteRate, bitsPerSample)
            } else if chunkID == "data" {
                audioByteCount = chunkSize
            }

            let paddedSize = payloadSize + (payloadSize % 2)
            guard paddedSize <= data.count - payloadOffset else { break }
            offset = payloadOffset + paddedSize
        }

        guard let format, audioByteCount != nil else {
            throw AssemblyAIDictationError.invalidWAV
        }
        guard format.audioFormat == 1,
              format.bitsPerSample == UInt16(requiredBitsPerSample),
              format.byteRate > 0 else {
            throw AssemblyAIDictationError.unsupportedWAVFormat
        }

        let duration = Double(audioByteCount!) / Double(format.byteRate)
        guard duration <= maximumAudioDuration else {
            throw AssemblyAIDictationError.audioTooLong(maximumSeconds: maximumAudioDuration)
        }
    }

    private static func ascii(in data: Data, range: Range<Int>) -> String? {
        guard range.lowerBound >= 0, range.upperBound <= data.count else { return nil }
        return String(data: data.subdata(in: range), encoding: .ascii)
    }

    private static func uint16LE(in data: Data, at offset: Int) -> UInt16? {
        guard offset >= 0, offset + 2 <= data.count else { return nil }
        return UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
    }

    private static func uint32LE(in data: Data, at offset: Int) -> UInt32? {
        guard offset >= 0, offset + 4 <= data.count else { return nil }
        return UInt32(data[offset])
            | (UInt32(data[offset + 1]) << 8)
            | (UInt32(data[offset + 2]) << 16)
            | (UInt32(data[offset + 3]) << 24)
    }
}
