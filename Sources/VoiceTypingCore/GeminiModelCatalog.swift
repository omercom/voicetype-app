import Foundation

public enum GeminiModelCatalogError: Error, Equatable {
    case missingAPIKey
    case invalidURL
    case invalidResponse
    case httpStatus(Int)
    case invalidPayload
}

/// Fetches only dedicated Gemini transcription models that this API key can access.
/// General Live, Flash, TTS, image and translation models are intentionally excluded.
/// The model list is never persisted and the key is never included in errors.
public enum GeminiModelCatalog {
    private static let endpoint = URL(string: "https://generativelanguage.googleapis.com/v1beta/models")!

    public static func fetch(
        apiKey: String,
        session: URLSession = .shared,
        completion: @escaping (Result<[ModelOption], Error>) -> Void
    ) {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else {
            completion(.failure(GeminiModelCatalogError.missingAPIKey))
            return
        }

        var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "pageSize", value: "1000"),
            URLQueryItem(name: "key", value: key)
        ]
        guard let url = components?.url else {
            completion(.failure(GeminiModelCatalogError.invalidURL))
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 10.0
        session.dataTask(with: request) { data, response, error in
            if error != nil {
                completion(.failure(GeminiModelCatalogError.invalidResponse))
                return
            }
            guard let http = response as? HTTPURLResponse else {
                completion(.failure(GeminiModelCatalogError.invalidResponse))
                return
            }
            guard http.statusCode == 200 else {
                completion(.failure(GeminiModelCatalogError.httpStatus(http.statusCode)))
                return
            }
            guard let data else {
                completion(.failure(GeminiModelCatalogError.invalidPayload))
                return
            }
            do {
                completion(.success(try parse(data: data)))
            } catch {
                completion(.failure(error))
            }
        }.resume()
    }

    static func parse(data: Data) throws -> [ModelOption] {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = root["models"] as? [[String: Any]] else {
            throw GeminiModelCatalogError.invalidPayload
        }

        var options: [String: ModelOption] = [:]
        for model in models {
            let rawName = (model["baseModelId"] as? String)
                ?? (model["name"] as? String)?.replacingOccurrences(of: "models/", with: "")
            guard let rawName else { continue }
            let id = ConfigManager.normalizedGeminiModelID(rawName)
            guard !id.isEmpty else { continue }

            let actions = Set((model["supportedGenerationMethods"] as? [String] ?? [])
                .map { $0.lowercased() })
            let lowerID = id.lowercased()
            let isTranscriptionModel = lowerID.contains("transcribe")
            let isLive = isTranscriptionModel && actions.contains("bidigeneratecontent")
            let isREST = isTranscriptionModel && actions.contains("generatecontent")
            let isExcluded = lowerID.contains("tts") || lowerID.contains("image") ||
                lowerID.contains("embedding") || lowerID.contains("veo") || lowerID.contains("translate")
            guard !isExcluded && (isLive || isREST) else { continue }

            let displayName = (model["displayName"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let name = displayName?.isEmpty == false ? displayName! : id
            let optionName: String
            let speed: String
            if ConfigManager.isGeminiExtendedThinkingModel(id) {
                optionName = "\(name) (Canlı Akış · Muhakeme)"
                speed = "Daha fazla muhakeme"
            } else if isLive {
                optionName = "\(name) (Canlı Akış)"
                speed = "En düşük gecikme"
            } else {
                optionName = "\(name) (REST · Saf Ses Deşifre)"
                speed = "Standart"
            }

            options[id] = ModelOption(
                id: id,
                name: optionName,
                price: "Maliyet: Google API",
                speed: speed
            )
        }

        return options.values.sorted { lhs, rhs in
            let lhsLive = ConfigManager.isGeminiLiveModel(lhs.id)
            let rhsLive = ConfigManager.isGeminiLiveModel(rhs.id)
            if lhsLive != rhsLive { return lhsLive && !rhsLive }
            if lhs.id.contains("extended-thinking") != rhs.id.contains("extended-thinking") {
                return !lhs.id.contains("extended-thinking")
            }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }
}
