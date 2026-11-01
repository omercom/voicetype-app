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
    private let ownsExistingDirectory: Bool
    private let lock = NSLock()

    public init(customDirectoryURL: URL? = nil) {
        self.ownsExistingDirectory = customDirectoryURL == nil
        if let custom = customDirectoryURL {
            self.directoryURL = custom
        } else {
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            self.directoryURL = appSupport.appendingPathComponent("VoiceTyping/voice_recovery", isDirectory: true)
        }
        self.latestAudioURL = directoryURL.appendingPathComponent("latest_recovery.wav")
        self.latestMetadataURL = directoryURL.appendingPathComponent("latest_recovery.json")

        _ = ensureDirectoryExists()
    }

    @discardableResult
    private func ensureDirectoryExists() -> Bool {
        let existed = fileManager.fileExists(atPath: directoryURL.path)
        do {
            if !existed {
                try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
            }
            // A caller-supplied existing folder may contain unrelated files.
            // Tighten only the app's own folder or one this store created.
            if !existed || ownsExistingDirectory {
                try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directoryURL.path)
            }
            return true
        } catch {
            print("[RecoveryAudioStore] ⚠️ Kurtarma klasörü hazırlanamadı: \(error.localizedDescription)")
            return false
        }
    }

    private func writePrivate(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: .atomic)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private func audioByteCount(at url: URL) -> Int? {
        guard let attributes = try? fileManager.attributesOfItem(atPath: url.path),
              attributes[.type] as? FileAttributeType == .typeRegular,
              let size = attributes[.size] as? NSNumber else { return nil }
        return size.intValue
    }

    private func audioByteCount() -> Int? {
        audioByteCount(at: latestAudioURL)
    }

    private func urls(for recordingID: UUID) -> (audio: URL, metadata: URL) {
        let name = "recovery_\(recordingID.uuidString)"
        return (directoryURL.appendingPathComponent("\(name).wav"),
                directoryURL.appendingPathComponent("\(name).json"))
    }

    private struct RecoveryFiles {
        let audio: URL
        let metadata: URL
        let timestamp: Date
    }

    // Called with lock held. Include files from older versions and interrupted writes.
    private func recoveryFiles(includeShort: Bool = false) -> [RecoveryFiles] {
        let entries = (try? fileManager.contentsOfDirectory(at: directoryURL, includingPropertiesForKeys: nil)) ?? []
        let candidates: [RecoveryFiles] = entries.compactMap { audio in
            let name = audio.lastPathComponent
            let metadata: URL
            if name == "latest_recovery.wav" {
                metadata = latestMetadataURL
            } else {
                guard name.hasPrefix("recovery_"), name.hasSuffix(".wav") else { return nil }
                let id = String(name.dropFirst("recovery_".count).dropLast(".wav".count))
                guard UUID(uuidString: id) != nil else { return nil }
                metadata = audio.deletingPathExtension().appendingPathExtension("json")
            }
            guard let size = audioByteCount(at: audio), includeShort || size > 44,
                  let attributes = try? fileManager.attributesOfItem(atPath: audio.path) else { return nil }
            let savedMetadata = (try? Data(contentsOf: metadata))
                .flatMap { try? JSONDecoder().decode(DictationRecoveryMetadata.self, from: $0) }
            let timestamp = savedMetadata?.timestamp ?? (attributes[.creationDate] as? Date)
                ?? (attributes[.modificationDate] as? Date) ?? .distantPast
            return RecoveryFiles(audio: audio, metadata: metadata, timestamp: timestamp)
        }
        return candidates
    }

    private func latestRecoveryFiles(includeShort: Bool = false) -> RecoveryFiles? {
        recoveryFiles(includeShort: includeShort).max {
            $0.timestamp == $1.timestamp
                ? $0.audio.lastPathComponent < $1.audio.lastPathComponent
                : $0.timestamp < $1.timestamp
        }
    }

    /// Store each in-flight dictation independently so later callbacks cannot erase it.
    @discardableResult
    public func saveRecording(wavData: Data) -> UUID? {
        lock.lock()
        defer { lock.unlock() }
        guard ensureDirectoryExists() else { return nil }
        let id = UUID()
        let files = urls(for: id)
        do {
            try writePrivate(wavData, to: files.audio)
        } catch {
            print("[RecoveryAudioStore] ⚠️ Ses kurtarma dosyası yazılamadı: \(error.localizedDescription)")
            return nil
        }
        let metadata = DictationRecoveryMetadata(timestamp: Date(), byteCount: wavData.count, isFailed: false)
        do {
            try writePrivate(JSONEncoder().encode(metadata), to: files.metadata)
        } catch {
            // The WAV is still recoverable after a metadata write failure.
            print("[RecoveryAudioStore] ⚠️ Kurtarma metadata'sı yazılamadı: \(error.localizedDescription)")
        }
        return id
    }

    @discardableResult
    public func markFailed(error: String, recordingID: UUID?) -> Bool {
        guard let recordingID else { return false }
        lock.lock()
        defer { lock.unlock() }
        let files = urls(for: recordingID)
        guard ensureDirectoryExists(), let byteCount = audioByteCount(at: files.audio), byteCount > 44 else { return false }
        let previous = (try? Data(contentsOf: files.metadata))
            .flatMap { try? JSONDecoder().decode(DictationRecoveryMetadata.self, from: $0) }
        let metadata = DictationRecoveryMetadata(timestamp: previous?.timestamp ?? Date(), byteCount: byteCount,
                                                 isFailed: true, lastError: error)
        do {
            try writePrivate(JSONEncoder().encode(metadata), to: files.metadata)
        } catch {
            print("[RecoveryAudioStore] ⚠️ Kurtarma metadata'sı yazılamadı: \(error.localizedDescription)")
        }
        return true
    }

    public func clear(recordingID: UUID?) {
        guard let recordingID else { return }
        lock.lock()
        defer { lock.unlock() }
        let files = urls(for: recordingID)
        try? fileManager.removeItem(at: files.audio)
        try? fileManager.removeItem(at: files.metadata)
    }

    /// Tamamlanan son ses kaydını kurtarma deposuna geçici olarak yazar.
    @discardableResult
    public func saveLastRecording(wavData: Data) -> Bool {
        lock.lock()
        defer { lock.unlock() }

        guard ensureDirectoryExists() else { return false }
        do {
            try writePrivate(wavData, to: latestAudioURL)
            let metadata = DictationRecoveryMetadata(
                timestamp: Date(),
                byteCount: wavData.count,
                isFailed: false,
                lastError: nil
            )
            let metaData = try JSONEncoder().encode(metadata)
            try writePrivate(metaData, to: latestMetadataURL)
            return true
        } catch {
            print("[RecoveryAudioStore] ⚠️ Ses kurtarma dosyası yazılamadı: \(error.localizedDescription)")
            return false
        }
    }

    /// Deşifre başarısız olduğunda kaydı 'kurtarılabilir başarısız kayıt' olarak işaretler.
    @discardableResult
    public func markFailed(error: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }

        guard ensureDirectoryExists(), let byteCount = audioByteCount() else { return false }

        let metadata = DictationRecoveryMetadata(
            timestamp: Date(),
            byteCount: byteCount,
            isFailed: true,
            lastError: error
        )
        do {
            let metaData = try JSONEncoder().encode(metadata)
            try writePrivate(metaData, to: latestMetadataURL)
            print("[RecoveryAudioStore] 🛡️ Başarısız deşifre sesi kurtarma deposunda güvenle saklandı (\(byteCount) bayt).")
            return true
        } catch {
            print("[RecoveryAudioStore] ⚠️ Kurtarma metadata'sı yazılamadı: \(error.localizedDescription)")
            return byteCount > 44
        }
    }

    /// Kurtarılabilir bir ses kaydının mevcut olup olmadığını döner.
    /// Uygulama deşifre sırasında kapanmışsa metadata henüz failed olarak
    /// işaretlenmemiş olabilir; bu kayıt da kullanıcıya sunulmalıdır.
    public func hasRecovery() -> Bool {
        lock.lock()
        defer { lock.unlock() }

        return latestRecoveryFiles() != nil
    }

    /// Depoda teknik hata sonrası tutulan bir kayıt olup olmadığını döner.
    public func hasFailedRecovery() -> Bool {
        lock.lock()
        defer { lock.unlock() }

        return recoveryFiles(includeShort: true).contains { files in
            guard let data = try? Data(contentsOf: files.metadata),
                  let metadata = try? JSONDecoder().decode(DictationRecoveryMetadata.self, from: data) else { return false }
            return metadata.isFailed
        }
    }

    /// Son ses kaydı verisini döner
    public func getLatestAudioData() -> Data? {
        lock.lock()
        defer { lock.unlock() }

        guard let files = latestRecoveryFiles(includeShort: true) else { return nil }
        return try? Data(contentsOf: files.audio)
    }

    static func availableExportURL(in directory: URL, baseName: String, exists: (URL) -> Bool) -> URL {
        var candidate = directory.appendingPathComponent("\(baseName).wav")
        var suffix = 2
        while exists(candidate) {
            candidate = directory.appendingPathComponent("\(baseName)_\(suffix).wav")
            suffix += 1
        }
        return candidate
    }

    /// Son kurtarma kaydını kullanıcının Masaüstüne "VoiceTyping_Kurtarilan_Ses.wav" olarak kopyalar
    public func exportLatestRecoveryToDesktop() -> URL? {
        lock.lock()
        defer { lock.unlock() }

        guard let desktopURL = fileManager.urls(for: .desktopDirectory, in: .userDomainMask).first,
              let files = latestRecoveryFiles(includeShort: true) else {
            return nil
        }

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        let dateStr = formatter.string(from: Date())
        let destURL = Self.availableExportURL(in: desktopURL, baseName: "VoiceTyping_Kurtarilan_\(dateStr)") {
            fileManager.fileExists(atPath: $0.path)
        }

        do {
            try fileManager.copyItem(at: files.audio, to: destURL)
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
