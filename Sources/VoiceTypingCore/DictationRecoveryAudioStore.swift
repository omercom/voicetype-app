import Foundation
import AppKit

public struct DictationRecoveryMetadata: Codable, Equatable, Sendable {
    public let timestamp: Date
    public let byteCount: Int
    public let isFailed: Bool
    public let lastError: String?

    public init(timestamp: Date, byteCount: Int, isFailed: Bool, lastError: String? = nil) {
        self.timestamp = timestamp
        self.byteCount = byteCount
        self.isFailed = isFailed
        self.lastError = lastError
    }
}

/// Ağ veya API kesintilerinde kullanıcının ses kaydının kaybolmasını önleyen
/// ve başarısız kaydı kurtarma/dışa aktarma olanağı sağlayan ses saklama deposu.
public final class DictationRecoveryAudioStore: @unchecked Sendable {
    public static let shared = DictationRecoveryAudioStore()

    private let fileManager = FileManager.default
    private let directoryURL: URL
    private let latestAudioURL: URL
    private let latestMetadataURL: URL
    private let lock = NSLock()

    public init(customDirectoryURL: URL? = nil) {
        if let custom = customDirectoryURL {
            self.directoryURL = custom
        } else {
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            self.directoryURL = appSupport.appendingPathComponent("VoiceTyping/voice_recovery", isDirectory: true)
        }
        self.latestAudioURL = directoryURL.appendingPathComponent("latest_recovery.wav")
        self.latestMetadataURL = directoryURL.appendingPathComponent("latest_recovery.json")

        ensureDirectoryExists()
    }

    private func ensureDirectoryExists() {
        if !fileManager.fileExists(atPath: directoryURL.path) {
            try? fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        }
    }

    /// Tamamlanan son ses kaydını kurtarma deposuna geçici olarak yazar
    public func saveLastRecording(wavData: Data) {
        lock.lock()
        defer { lock.unlock() }

        ensureDirectoryExists()
        do {
            try wavData.write(to: latestAudioURL, options: .atomic)
            let metadata = DictationRecoveryMetadata(
                timestamp: Date(),
                byteCount: wavData.count,
                isFailed: false,
                lastError: nil
            )
            if let metaData = try? JSONEncoder().encode(metadata) {
                try? metaData.write(to: latestMetadataURL, options: .atomic)
            }
        } catch {
            print("[RecoveryAudioStore] ⚠️ Ses kurtarma dosyası yazılamadı: \(error.localizedDescription)")
        }
    }

    /// Deşifre başarısız olduğunda kaydı 'kurtarılabilir başarısız kayıt' olarak işaretler
    public func markFailed(error: String) {
        lock.lock()
        defer { lock.unlock() }

        guard fileManager.fileExists(atPath: latestAudioURL.path),
              let data = try? Data(contentsOf: latestAudioURL) else {
            return
        }

        let metadata = DictationRecoveryMetadata(
            timestamp: Date(),
            byteCount: data.count,
            isFailed: true,
            lastError: error
        )
        if let metaData = try? JSONEncoder().encode(metadata) {
            try? metaData.write(to: latestMetadataURL, options: .atomic)
        }
        print("[RecoveryAudioStore] 🛡️ Başarısız deşifre sesi kurtarma deposunda güvenle saklandı (\(data.count) bayt).")
    }

    /// Başarısız veya kurtarılabilir bir kayıt olup olmadığını döner
    public func hasFailedRecovery() -> Bool {
        lock.lock()
        defer { lock.unlock() }

        guard fileManager.fileExists(atPath: latestAudioURL.path),
              fileManager.fileExists(atPath: latestMetadataURL.path),
              let metaData = try? Data(contentsOf: latestMetadataURL),
              let metadata = try? JSONDecoder().decode(DictationRecoveryMetadata.self, from: metaData) else {
            return false
        }

        return metadata.isFailed
    }

    /// Son ses kaydı verisini döner
    public func getLatestAudioData() -> Data? {
        lock.lock()
        defer { lock.unlock() }

        guard fileManager.fileExists(atPath: latestAudioURL.path) else { return nil }
        return try? Data(contentsOf: latestAudioURL)
    }

    /// Son kurtarma kaydını kullanıcının Masaüstüne "VoiceTyping_Kurtarilan_Ses.wav" olarak kopyalar
    public func exportLatestRecoveryToDesktop() -> URL? {
        lock.lock()
        defer { lock.unlock() }

        guard let desktopURL = fileManager.urls(for: .desktopDirectory, in: .userDomainMask).first,
              fileManager.fileExists(atPath: latestAudioURL.path) else {
            return nil
        }

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        let dateStr = formatter.string(from: Date())
        let destURL = desktopURL.appendingPathComponent("VoiceTyping_Kurtarilan_\(dateStr).wav")

        do {
            if fileManager.fileExists(atPath: destURL.path) {
                try fileManager.removeItem(at: destURL)
            }
            try fileManager.copyItem(at: latestAudioURL, to: destURL)
            print("[RecoveryAudioStore] 💾 Kurtarılan ses masaüstüne kopyalandı: \(destURL.path)")
            return destURL
        } catch {
            print("[RecoveryAudioStore] ❌ Masaüstüne dışa aktarma hatası: \(error.localizedDescription)")
            return nil
        }
    }

    /// Başarılı yapıştırma veya kullanıcının talebi sonrası depoyu temizler
    public func clear() {
        lock.lock()
        defer { lock.unlock() }

        try? fileManager.removeItem(at: latestAudioURL)
        try? fileManager.removeItem(at: latestMetadataURL)
    }
}
