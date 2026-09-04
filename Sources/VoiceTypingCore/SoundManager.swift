import Foundation
import AppKit

public class SoundManager {
    public static let shared = SoundManager()

    public var isEnabled: Bool = true

    private var soundCache: [String: NSSound] = [:]
    private let soundNames = [
        "dictation-start",
        "dictation-stop",
        "paste",
        "startup",
        "cancel"
    ]

    private init() {
        self.isEnabled = ConfigManager.shared.config.play_sounds
        preloadSounds()
    }

    private func preloadSounds() {
        for name in soundNames {
            if let sound = loadSound(named: name) {
                soundCache[name] = sound
                print("[SoundManager] ✅ Ses belleğe yüklendi: \(name)")
            } else {
                print("[SoundManager] ⚠️ Ses yüklenemedi: \(name)")
            }
        }
    }

    private func findSoundURL(named name: String) -> URL? {
        #if SWIFT_PACKAGE
        // 1. Bundle.module (SPM generated resource bundle)
        if let url = Bundle.module.url(forResource: name, withExtension: "wav") {
            return url
        }
        if let url = Bundle.module.url(forResource: name, withExtension: "wav", subdirectory: "Sounds") {
            return url
        }
        #endif

        // 2. Bundle.main
        if let url = Bundle.main.url(forResource: name, withExtension: "wav") {
            return url
        }
        if let url = Bundle.main.url(forResource: name, withExtension: "wav", subdirectory: "Sounds") {
            return url
        }

        // 3. Main bundle Resources folder
        if let resURL = Bundle.main.resourceURL {
            let direct = resURL.appendingPathComponent("\(name).wav")
            if FileManager.default.fileExists(atPath: direct.path) {
                return direct
            }
            let inSounds = resURL.appendingPathComponent("Sounds/\(name).wav")
            if FileManager.default.fileExists(atPath: inSounds.path) {
                return inSounds
            }
            let inBundle = resURL.appendingPathComponent("VoiceTyping_VoiceTypingCore.bundle/\(name).wav")
            if FileManager.default.fileExists(atPath: inBundle.path) {
                return inBundle
            }
        }

        // 4. Standalone binary adjacent bundle
        let exeDir = Bundle.main.bundleURL.deletingLastPathComponent()
        let adjacentBundle = exeDir.appendingPathComponent("VoiceTyping_VoiceTypingCore.bundle/\(name).wav")
        if FileManager.default.fileExists(atPath: adjacentBundle.path) {
            return adjacentBundle
        }

        // 5. Development project path fallback
        let cwd = FileManager.default.currentDirectoryPath
        let devURL = URL(fileURLWithPath: "\(cwd)/Sources/VoiceTypingCore/Resources/Sounds/\(name).wav")
        if FileManager.default.fileExists(atPath: devURL.path) {
            return devURL
        }

        return nil
    }

    private func loadSound(named name: String) -> NSSound? {
        if let url = findSoundURL(named: name) {
            if let sound = NSSound(contentsOf: url, byReference: true) {
                return sound
            }
        }

        // System sound fallback
        let fallbackMap: [String: String] = [
            "dictation-start": "Tink",
            "dictation-stop": "Pop",
            "paste": "Glass",
            "startup": "Hero",
            "cancel": "Basso"
        ]
        if let fallbackName = fallbackMap[name] {
            return NSSound(named: fallbackName)
        }

        return NSSound(named: name)
    }

    public func play(_ name: String) {
        guard isEnabled else {
            print("[SoundManager] 🔇 Sesler devre dışı (isEnabled = false): \(name)")
            return
        }

        // Legacy name mapping
        let normalizedName: String
        switch name {
        case "Tink":
            normalizedName = "dictation-start"
        case "Pop":
            normalizedName = "dictation-stop"
        case "Glass":
            normalizedName = "paste"
        case "Basso":
            normalizedName = "cancel"
        case "Hero":
            normalizedName = "startup"
        default:
            normalizedName = name
        }

        DispatchQueue.main.async {
            let sound: NSSound?
            if let cached = self.soundCache[normalizedName] {
                sound = cached
            } else if let loaded = self.loadSound(named: normalizedName) {
                self.soundCache[normalizedName] = loaded
                sound = loaded
            } else {
                sound = NSSound(named: normalizedName)
            }

            if let sound = sound {
                sound.stop()
                sound.currentTime = 0
                sound.volume = 1.0
                let ok = sound.play()
                print("[SoundManager] 🔊 Ses çalındı: \(normalizedName) (Sonuç: \(ok))")
            } else {
                print("[SoundManager] ⚠️ Ses yüklenemedi: \(normalizedName)")
            }
        }
    }

    public func playStart() {
        play("dictation-start")
    }

    public func playStop() {
        play("dictation-stop")
    }

    public func playSuccess() {
        play("paste")
    }

    public func playStartup() {
        play("startup")
    }

    public func playCancel() {
        play("cancel")
    }
}
