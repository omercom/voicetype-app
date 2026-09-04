import Foundation

public struct ModelOption: Identifiable, Codable {
    public var id: String
    public var name: String
    public var price: String
    public var speed: String

    public init(id: String, name: String, price: String, speed: String) {
        self.id = id
        self.name = name
        self.price = price
        self.speed = speed
    }
}

public struct AppConfig: Codable {
    public var provider: String
    public var groq_api_key: String
    public var gemini_api_key: String
    public var groq_model: String
    public var gemini_model: String
    public var language: String
    public var trigger_key: Int
    public var trigger_mode: String
    public var play_sounds: Bool
    public var restore_clipboard: Bool
    public var paste_delay_ms: Int
    public var min_record_duration: Double

    public static let defaultConfig = AppConfig(
        provider: "groq",
        groq_api_key: "",
        gemini_api_key: "",
        groq_model: "whisper-large-v3-turbo",
        gemini_model: "gemini-3.5-flash",
        language: "tr",
        trigger_key: 54,
        trigger_mode: "hold",
        play_sounds: true,
        restore_clipboard: false,
        paste_delay_ms: 20,
        min_record_duration: 0.20
    )
}

public class ConfigManager {
    public static let shared = ConfigManager()

    public private(set) var config: AppConfig
    public private(set) var configURL: URL

    public static let availableGroqModels: [ModelOption] = [
        ModelOption(
            id: "whisper-large-v3-turbo",
            name: "Whisper Large v3 Turbo",
            price: "0.04 USD / saat",
            speed: "~0.3s (Ultra Hızlı)"
        ),
        ModelOption(
            id: "whisper-large-v3",
            name: "Whisper Large v3",
            price: "0.111 USD / saat",
            speed: "~0.6s (Yüksek Doğruluk)"
        )
    ]

    public static let availableGeminiModels: [ModelOption] = [
        ModelOption(
            id: "gemini-3.5-flash",
            name: "Gemini 3.5 Flash",
            price: "Ücretsiz Kota / Düşük Maliyet",
            speed: "~0.7s (Hızlı & Doğal Dil)"
        ),
        ModelOption(
            id: "gemini-3.6-flash",
            name: "Gemini 3.6 Flash",
            price: "Ücretsiz Kota / Düşük Maliyet",
            speed: "~0.8s (Bağlamsal Zeka)"
        ),
        ModelOption(
            id: "gemini-3.5-flash-lite",
            name: "Gemini 3.5 Flash Lite",
            price: "Ücretsiz Kota / Standart",
            speed: "~0.5s (Hafif Model)"
        )
    ]

    private init() {
        let potentialPaths = [
            FileManager.default.currentDirectoryPath + "/config.json",
            Bundle.main.bundlePath + "/Contents/Resources/config.json",
            Bundle.main.bundleURL.deletingLastPathComponent().path + "/config.json",
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".voice_typing_config.json").path
        ]

        var resolvedURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath + "/config.json")
        var loadedConfig: AppConfig? = nil

        for path in potentialPaths {
            let url = URL(fileURLWithPath: path)
            if FileManager.default.fileExists(atPath: path),
               let data = try? Data(contentsOf: url),
               let decoded = try? JSONDecoder().decode(AppConfig.self, from: data) {
                resolvedURL = url
                loadedConfig = decoded
                break
            }
        }

        // Eğer mevcut dizin yazılabilir değilse veya kök dizindeyse, ev dizinindeki dosyayı hedefle
        let parentDir = resolvedURL.deletingLastPathComponent().path
        if !FileManager.default.isWritableFile(atPath: parentDir) || parentDir == "/" {
            resolvedURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".voice_typing_config.json")
        }

        self.configURL = resolvedURL
        self.config = loadedConfig ?? AppConfig.defaultConfig
    }

    public func reload() {
        if let data = try? Data(contentsOf: configURL),
           let decoded = try? JSONDecoder().decode(AppConfig.self, from: data) {
            self.config = decoded
        }
    }

    @discardableResult
    public func update(_ block: (inout AppConfig) -> Void) -> Bool {
        block(&config)
        return save()
    }

    public func save() -> Bool {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(config)
            try data.write(to: configURL, options: .atomic)
            return true
        } catch {
            print("[Hata] Yapılandırma dosyası kaydedilemedi: \(error.localizedDescription)")
            return false
        }
    }
}
