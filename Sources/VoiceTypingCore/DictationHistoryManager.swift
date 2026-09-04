import Foundation
import AppKit

public struct DictationEntry: Identifiable, Codable {
    public var id: UUID
    public var text: String
    public var timestamp: Date
    public var provider: String
    public var model: String

    public init(id: UUID = UUID(), text: String, timestamp: Date = Date(), provider: String, model: String) {
        self.id = id
        self.text = text
        self.timestamp = timestamp
        self.provider = provider
        self.model = model
    }

    /// Menüde gösterilecek kısa önizleme ve saat damgası (örn: "19:25 • Merhaba dünya...")
    public var menuTitle: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        let timeStr = formatter.string(from: timestamp)

        var singleLine = text
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if singleLine.count > 42 {
            let idx = singleLine.index(singleLine.startIndex, offsetBy: 40)
            singleLine = String(singleLine[..<idx]) + "..."
        }

        return "\(timeStr) • \(singleLine)"
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

    public func addEntry(text: String, provider: String, model: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard ConfigManager.shared.config.save_history else { return }

        lock.lock()
        let newEntry = DictationEntry(text: trimmed, provider: provider, model: model)
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
