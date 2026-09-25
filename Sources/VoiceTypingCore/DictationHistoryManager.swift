import Foundation
import AppKit

public struct DictationEntry: Identifiable, Codable, Equatable {
    public var id: UUID
    public var text: String
    public var timestamp: Date
    public var provider: String
    public var model: String
    public var appName: String?

    public init(
        id: UUID = UUID(),
        text: String,
        timestamp: Date = Date(),
        provider: String,
        model: String,
        appName: String? = nil
    ) {
        self.id = id
        self.text = text
        self.timestamp = timestamp
        self.provider = provider
        self.model = model
        self.appName = appName
    }

    enum CodingKeys: String, CodingKey {
        case id, text, timestamp, provider, model, appName
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        text = try container.decode(String.self, forKey: .text)
        timestamp = try container.decodeIfPresent(Date.self, forKey: .timestamp) ?? Date()
        provider = try container.decodeIfPresent(String.self, forKey: .provider) ?? "apple"
        model = try container.decodeIfPresent(String.self, forKey: .model) ?? ""
        appName = try container.decodeIfPresent(String.self, forKey: .appName)
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    /// Menüde gösterilecek kısa önizleme, uygulama etiketi ve saat damgası (örn: "19:25 • [Xcode] Merhaba dünya...")
    public var menuTitle: String {
        let timeStr = Self.timeFormatter.string(from: timestamp)

        var singleLine = text
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let appTag = (appName?.isEmpty == false) ? "[\(appName!)] " : ""
        let maxTextLen = max(42 - appTag.count, 15)

        if singleLine.count > maxTextLen {
            let idx = singleLine.index(singleLine.startIndex, offsetBy: maxTextLen - 2)
            singleLine = String(singleLine[..<idx]) + "..."
        }

        return "\(timeStr) • \(appTag)\(singleLine)"
    }
}

public final class DictationHistoryManager {
    public static let shared = DictationHistoryManager()

    private let maxEntries = 15
    private var entries: [DictationEntry] = []
    private let lock = NSLock()
    private let fileURL: URL

    public var onHistoryUpdated: (() -> Void)?

    private init() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let dir = home.appendingPathComponent(".voice_typing")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.fileURL = dir.appendingPathComponent("history.json")
        loadFromDisk()
    }

    // MARK: - API

    public func getEntries() -> [DictationEntry] {
        lock.lock()
        defer { lock.unlock() }
        return entries
    }

    public func addEntry(text: String, provider: String, model: String, appName: String? = nil) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard ConfigManager.shared.config.save_history else { return }

        lock.lock()
        let newEntry = DictationEntry(
            text: trimmed,
            provider: provider,
            model: model,
            appName: appName
        )
        entries.insert(newEntry, at: 0)
        if entries.count > maxEntries {
            entries = Array(entries.prefix(maxEntries))
        }
        let snapshot = entries
        lock.unlock()

        saveToDisk(entries: snapshot)
        DispatchQueue.main.async { [weak self] in
            self?.onHistoryUpdated?()
        }
    }

    public func clear() {
        lock.lock()
        entries.removeAll()
        lock.unlock()

        saveToDisk(entries: [])
        DispatchQueue.main.async { [weak self] in
            self?.onHistoryUpdated?()
        }
    }

    public func copyToClipboard(entry: DictationEntry) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(entry.text, forType: .string)

        HapticManager.shared.playSuccess()
        SoundManager.shared.playSuccess()
    }

    // MARK: - Dışa Aktarma (Export - Speakr file_exporter esintisi)

    /// Dikte geçmişini Markdown biçiminde dışa aktarır.
    /// Şablon belirtilirse PromptTemplate ile değişkenler çözümlenir:
    /// `{{tarih}}`, `{{saat}}`, `{{uygulama}}`, `{{saglayici}}`, `{{model}}`, `{{metin}}`.
    public func exportToMarkdown(itemTemplate: String? = nil) -> String {
        lock.lock()
        let currentEntries = entries
        lock.unlock()

        guard !currentEntries.isEmpty else {
            return "# VoiceType Dikte Geçmişi\n\nHenüz kayıtlı bir dikte bulunmuyor.\n"
        }

        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd"
        let timeFormatter = DateFormatter()
        timeFormatter.dateFormat = "HH:mm:ss"

        let templateString = itemTemplate ?? "### {{tarih}} {{saat}} • {{uygulama}} ({{saglayici}} - {{model}})\n{{metin}}\n"

        var output = "# VoiceType Dikte Geçmişi\n"
        output += "*Dışa aktarılma zamanı: \(dateFormatter.string(from: Date())) \(timeFormatter.string(from: Date()))*\n\n---\n\n"

        for entry in currentEntries {
            let values: [String: String] = [
                "tarih": dateFormatter.string(from: entry.timestamp),
                "saat": timeFormatter.string(from: entry.timestamp),
                "uygulama": entry.appName ?? "Genel",
                "saglayici": entry.provider,
                "model": entry.model,
                "metin": entry.text,
                "text": entry.text
            ]
            output += PromptTemplate.render(templateString, values: values) + "\n"
        }

        return output
    }

    /// Dikte geçmişini belirtilen dizine (varsayılan: ~/.voice_typing/) Markdown dosyası olarak kaydeder.
    @discardableResult
    public func exportToFile(destinationDirectory: URL? = nil, itemTemplate: String? = nil) throws -> URL {
        let dir = destinationDirectory ?? fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        let filename = "voicetype_history_\(formatter.string(from: Date())).md"
        let targetURL = dir.appendingPathComponent(filename)

        let markdown = exportToMarkdown(itemTemplate: itemTemplate)
        try markdown.write(to: targetURL, atomically: true, encoding: .utf8)
        return targetURL
    }

    // MARK: - Disk İşlemleri

    private func loadFromDisk() {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        do {
            let data = try Data(contentsOf: fileURL)
            let loaded = try JSONDecoder().decode([DictationEntry].self, from: data)
            lock.lock()
            self.entries = Array(loaded.prefix(maxEntries))
            lock.unlock()
        } catch {
            print("[DictationHistory] Geçmiş okuma hatası: \(error.localizedDescription)")
        }
    }

    private func saveToDisk(entries: [DictationEntry]) {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self = self else { return }
            do {
                let encoder = JSONEncoder()
                encoder.outputFormatting = .prettyPrinted
                let data = try encoder.encode(entries)
                try data.write(to: self.fileURL, options: .atomic)
            } catch {
                print("[DictationHistory] Geçmiş kaydetme hatası: \(error.localizedDescription)")
            }
        }
    }
}
