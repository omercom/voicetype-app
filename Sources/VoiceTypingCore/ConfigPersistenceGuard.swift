import Foundation

/// Bozuk veya elle hatalı düzenlenmiş `config.json` dosyalarını sessizce ezmek yerine
/// SHA/FNV özetiyle özel izinli yedeğini koruyan yapılandırma koruyucusu.
enum ConfigPersistenceGuard {
    struct LoadOutcome {
        let config: AppConfig?
        let unreadableOriginalData: Data?
        let errorDescription: String?
    }

    static func load(from url: URL, fileManager: FileManager = .default) -> LoadOutcome {
        guard fileManager.fileExists(atPath: url.path) else {
            return LoadOutcome(config: nil, unreadableOriginalData: nil, errorDescription: nil)
        }
        do {
            let data = try Data(contentsOf: url)
            let decoded = try JSONDecoder().decode(AppConfig.self, from: data)
            return LoadOutcome(config: decoded, unreadableOriginalData: nil, errorDescription: nil)
        } catch {
            let raw = try? Data(contentsOf: url)
            return LoadOutcome(
                config: nil,
                unreadableOriginalData: raw,
                errorDescription: error.localizedDescription
            )
        }
    }

    @discardableResult
    static func backupCorruptConfig(
        originalData: Data,
        nextTo configURL: URL,
        fileManager: FileManager = .default
    ) -> URL? {
        guard !originalData.isEmpty else { return nil }
        let hash = fnv1a64Hex(originalData)
        let backupName = "\(configURL.lastPathComponent).corrupt-\(hash).bak"
        let backupURL = configURL.deletingLastPathComponent().appendingPathComponent(backupName)

        if fileManager.fileExists(atPath: backupURL.path) {
            return backupURL
        }
        do {
            try fileManager.createDirectory(
                at: backupURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try originalData.write(to: backupURL, options: .atomic)
            try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: backupURL.path)
            return backupURL
        } catch {
            print("[ConfigGuard] ⚠️ Bozuk yapılandırma yedeği yazılamadı: \(error.localizedDescription)")
            return nil
        }
    }

    private static func fnv1a64Hex(_ data: Data) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        let prime: UInt64 = 0x100000001b3
        for byte in data {
            hash ^= UInt64(byte)
            hash = hash &* prime
        }
        return String(format: "%016llx", hash)
    }
}
