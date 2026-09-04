import Foundation
import ServiceManagement

/// macOS başlangıcında (Login / Startup) uygulamanın otomatik olarak
/// arka planda sessizce başlatılmasını sağlayan LaunchAgent ve SMAppService yöneticisi.
public class LaunchAtLoginManager {
    public static let shared = LaunchAtLoginManager()

    public let plistLabel = "com.antigravity.VoiceTyping"

    private var plistURL: URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent("Library/LaunchAgents/\(plistLabel).plist")
    }

    private init() {}

    /// Başlangıçta çalışmanın aktif olup olmadığını kontrol eder
    public var isEnabled: Bool {
        if #available(macOS 13.0, *) {
            if Bundle.main.bundleURL.path.hasPrefix("/Applications") {
                if SMAppService.mainApp.status == .enabled {
                    return true
                }
            }
        }
        return FileManager.default.fileExists(atPath: plistURL.path)
    }

    /// Başlangıçta çalışmayı açar veya kapatır
    public func setEnabled(_ enabled: Bool) {
        if #available(macOS 13.0, *) {
            if Bundle.main.bundleURL.path.hasPrefix("/Applications") {
                do {
                    if enabled {
                        if SMAppService.mainApp.status != .enabled {
                            try SMAppService.mainApp.register()
                            print("[LaunchAtLoginManager] ✅ SMAppService başarıyla kaydedildi.")
                        }
                    } else {
                        if SMAppService.mainApp.status == .enabled {
                            try SMAppService.mainApp.unregister()
                            print("[LaunchAtLoginManager] 🛑 SMAppService kaydı silindi.")
                        }
                    }
                    return
                } catch {
                    print("[LaunchAtLoginManager] ⚠️ SMAppService uyarısı (\(error.localizedDescription)), standart LaunchAgent yöntemine geçiliyor...")
                }
            }
        }

        if enabled {
            setupLaunchAgent()
        } else {
            removeLaunchAgent()
        }
    }

    /// ~/Library/LaunchAgents altına otomatik başlangıç plist dosyasını oluşturur
    public func setupLaunchAgent(targetBinaryPath: String? = nil) {
        let launchAgentsDir = plistURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: launchAgentsDir, withIntermediateDirectories: true)

        let binaryPath: String
        if let custom = targetBinaryPath {
            binaryPath = custom
        } else if Bundle.main.bundleURL.path.contains(".app") {
            binaryPath = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/VoiceTyping").path
        } else {
            binaryPath = Bundle.main.executableURL?.path ?? "/Applications/VoiceTyping.app/Contents/MacOS/VoiceTyping"
        }

        let plistContent = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Label</key>
            <string>\(plistLabel)</string>
            <key>ProgramArguments</key>
            <array>
                <string>\(binaryPath)</string>
            </array>
            <key>RunAtLoad</key>
            <true/>
            <key>ProcessType</key>
            <string>Interactive</string>
        </dict>
        </plist>
        """

        do {
            try plistContent.write(to: plistURL, atomically: true, encoding: .utf8)
            print("[LaunchAtLoginManager] ✅ LaunchAgent plist oluşturuldu: \(plistURL.path)")
        } catch {
            print("[LaunchAtLoginManager] ❌ LaunchAgent yazılamadı: \(error)")
        }
    }

    public func removeLaunchAgent() {
        if FileManager.default.fileExists(atPath: plistURL.path) {
            try? FileManager.default.removeItem(at: plistURL)
            print("[LaunchAtLoginManager] 🗑️ LaunchAgent plist silindi: \(plistURL.path)")
        }
    }
}
