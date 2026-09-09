import Foundation
import AppKit

/// macOS sistem ses efektleri, ses temaları (Modern, Zarif/Subtle, Taktil, Melodik/Chimes)
/// ve ses seviyesi kontrol yöneticisi.
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

    public func reloadConfig() {
        let cfg = ConfigManager.shared.config
        self.isEnabled = cfg.play_sounds
    }

    private func preloadSounds() {
        let theme = ConfigManager.shared.config.sound_theme
        for name in soundNames {
            let key = "\(theme)_\(name)"
            if let sound = generateThemeSound(theme: theme, name: name) ?? loadSound(named: name) {
                soundCache[key] = sound
            }
        }
    }

    // MARK: - Prosedürel Ses Teması Sentezleyici (WAV Generator)

    private func generateThemeSound(theme: String, name: String) -> NSSound? {
        let sampleRate: Double = 44100.0

        struct SoundSpec {
            let duration: Double
            let waveform: (Double) -> Double // t: 0.0 ... 1.0 -> amplitude: -1.0 ... 1.0
        }

        let spec: SoundSpec
        switch (theme.lowercased(), name) {
        // 1. MODERN THEME: Kristal netliğinde dijital chirpler
        case ("modern", "dictation-start"):
            spec = SoundSpec(duration: 0.07) { t in
                let freq = 600.0 + (900.0 - 600.0) * t
                let env = sin(t * .pi)
                return sin(2.0 * .pi * freq * (t * 0.07)) * env
            }
        case ("modern", "dictation-stop"):
            spec = SoundSpec(duration: 0.07) { t in
                let freq = 900.0 - (900.0 - 480.0) * t
                let env = sin(t * .pi)
                return sin(2.0 * .pi * freq * (t * 0.07)) * env
            }
        case ("modern", "paste"):
            spec = SoundSpec(duration: 0.09) { t in
                let freq = t < 0.5 ? 750.0 : 1050.0
                let localT = (t < 0.5 ? t * 2.0 : (t - 0.5) * 2.0)
                let env = sin(localT * .pi)
                return sin(2.0 * .pi * freq * (t * 0.09)) * env
            }
        case ("modern", "cancel"):
            spec = SoundSpec(duration: 0.10) { t in
                let freq = 400.0 - 200.0 * t
                let env = 1.0 - t
                return sin(2.0 * .pi * freq * (t * 0.10)) * env
            }

        // 2. SUBTLE THEME: Yumuşak, düşük frekanslı, kulaklığı yormayan zarif tonlar
        case ("subtle", "dictation-start"):
            spec = SoundSpec(duration: 0.08) { t in
                let env = pow(sin(t * .pi), 1.5)
                return sin(2.0 * .pi * 380.0 * (t * 0.08)) * env * 0.7
            }
        case ("subtle", "dictation-stop"):
            spec = SoundSpec(duration: 0.08) { t in
                let env = pow(sin(t * .pi), 1.5)
                return sin(2.0 * .pi * 290.0 * (t * 0.08)) * env * 0.7
            }
        case ("subtle", "paste"):
            spec = SoundSpec(duration: 0.10) { t in
                let env = pow(sin(t * .pi), 1.2)
                return sin(2.0 * .pi * 480.0 * (t * 0.10)) * env * 0.75
            }
        case ("subtle", "cancel"):
            spec = SoundSpec(duration: 0.11) { t in
                let env = 1.0 - t
                return sin(2.0 * .pi * 220.0 * (t * 0.11)) * env * 0.6
            }

        // 3. TACTILE THEME: Mekanik klavye çıtlaması ve dokunsal perküsif klik
        case ("tactile", "dictation-start"):
            spec = SoundSpec(duration: 0.02) { t in
                let env = exp(-t * 22.0)
                return (sin(2.0 * .pi * 1400.0 * (t * 0.02)) + 0.4 * sin(2.0 * .pi * 600.0 * (t * 0.02))) * env
            }
        case ("tactile", "dictation-stop"):
            spec = SoundSpec(duration: 0.02) { t in
                let env = exp(-t * 22.0)
                return (sin(2.0 * .pi * 950.0 * (t * 0.02)) + 0.3 * sin(2.0 * .pi * 450.0 * (t * 0.02))) * env
            }
        case ("tactile", "paste"):
            spec = SoundSpec(duration: 0.035) { t in
                let localT = t < 0.4 ? t / 0.4 : (t - 0.4) / 0.6
                let env = exp(-localT * 18.0)
                let freq = t < 0.4 ? 1200.0 : 1650.0
                return sin(2.0 * .pi * freq * (t * 0.035)) * env
            }
        case ("tactile", "cancel"):
            spec = SoundSpec(duration: 0.03) { t in
                let env = exp(-t * 15.0)
                return sin(2.0 * .pi * 320.0 * (t * 0.03)) * env
            }

        // 4. CHIMES THEME: Majör akor melodik çan tonları
        case ("chimes", "dictation-start"):
            spec = SoundSpec(duration: 0.14) { t in
                let env = exp(-t * 7.0)
                let c5 = sin(2.0 * .pi * 523.25 * (t * 0.14))
                let e5 = sin(2.0 * .pi * 659.25 * (t * 0.14))
                return (c5 * 0.6 + e5 * 0.4) * env
            }
        case ("chimes", "dictation-stop"):
            spec = SoundSpec(duration: 0.14) { t in
                let env = exp(-t * 7.0)
                let e5 = sin(2.0 * .pi * 659.25 * (t * 0.14))
                let c5 = sin(2.0 * .pi * 523.25 * (t * 0.14))
                return (e5 * 0.5 + c5 * 0.5) * env
            }
        case ("chimes", "paste"):
            spec = SoundSpec(duration: 0.18) { t in
                let env = exp(-t * 6.0)
                let c5 = sin(2.0 * .pi * 523.25 * (t * 0.18))
                let e5 = sin(2.0 * .pi * 659.25 * (t * 0.18))
                let g5 = sin(2.0 * .pi * 783.99 * (t * 0.18))
                return (c5 * 0.35 + e5 * 0.35 + g5 * 0.30) * env
            }
        case ("chimes", "cancel"):
            spec = SoundSpec(duration: 0.15) { t in
                let env = exp(-t * 6.5)
                let d5 = sin(2.0 * .pi * 587.33 * (t * 0.15))
                let bf4 = sin(2.0 * .pi * 466.16 * (t * 0.15))
                return (d5 * 0.5 + bf4 * 0.5) * env
            }

        default:
            return nil
        }

        let totalSamples = Int(spec.duration * sampleRate)
        var pcm = Data()
        pcm.reserveCapacity(totalSamples * 2)

        for i in 0..<totalSamples {
            let t = Double(i) / Double(totalSamples)
            let amp = max(-1.0, min(1.0, spec.waveform(t)))
            let sample = Int16(amp * 32767.0)
            withUnsafeBytes(of: sample.littleEndian) { pcm.append(contentsOf: $0) }
        }

        let wavData = buildWavData(pcmData: pcm, sampleRate: Int(sampleRate), channels: 1, bitsPerSample: 16)
        return NSSound(data: wavData)
    }

    private func buildWavData(pcmData: Data, sampleRate: Int, channels: Int, bitsPerSample: Int) -> Data {
        var data = Data()
        let byteRate = sampleRate * channels * (bitsPerSample / 8)
        let blockAlign = channels * (bitsPerSample / 8)
        let subchunk2Size = pcmData.count
        let chunkSize = 36 + subchunk2Size

        data.append(contentsOf: "RIFF".utf8)
        withUnsafeBytes(of: UInt32(chunkSize).littleEndian) { data.append(contentsOf: $0) }
        data.append(contentsOf: "WAVE".utf8)
        data.append(contentsOf: "fmt ".utf8)
        withUnsafeBytes(of: UInt32(16).littleEndian) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: UInt16(1).littleEndian) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: UInt16(channels).littleEndian) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: UInt32(sampleRate).littleEndian) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: UInt32(byteRate).littleEndian) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: UInt16(blockAlign).littleEndian) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: UInt16(bitsPerSample).littleEndian) { data.append(contentsOf: $0) }
        data.append(contentsOf: "data".utf8)
        withUnsafeBytes(of: UInt32(subchunk2Size).littleEndian) { data.append(contentsOf: $0) }
        data.append(pcmData)

        return data
    }

    private func findSoundURL(named name: String) -> URL? {
        #if SWIFT_PACKAGE
        if let url = Bundle.module.url(forResource: name, withExtension: "wav") {
            return url
        }
        if let url = Bundle.module.url(forResource: name, withExtension: "wav", subdirectory: "Sounds") {
            return url
        }
        #endif

        if let url = Bundle.main.url(forResource: name, withExtension: "wav") {
            return url
        }
        if let url = Bundle.main.url(forResource: name, withExtension: "wav", subdirectory: "Sounds") {
            return url
        }

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

    public func play(_ name: String, customTheme: String? = nil, customVolume: Double? = nil) {
        guard isEnabled else {
            print("[SoundManager] 🔇 Sesler devre dışı (isEnabled = false): \(name)")
            return
        }

        let normalizedName: String
        switch name {
        case "Tink": normalizedName = "dictation-start"
        case "Pop": normalizedName = "dictation-stop"
        case "Glass": normalizedName = "paste"
        case "Basso": normalizedName = "cancel"
        case "Hero": normalizedName = "startup"
        default: normalizedName = name
        }

        let config = ConfigManager.shared.config
        let theme = customTheme ?? config.sound_theme
        let volume = Float(max(0.0, min(1.0, customVolume ?? config.sound_volume)))
        let cacheKey = "\(theme)_\(normalizedName)"

        DispatchQueue.main.async {
            let sound: NSSound?
            if let cached = self.soundCache[cacheKey] {
                sound = cached
            } else if let generated = self.generateThemeSound(theme: theme, name: normalizedName) {
                self.soundCache[cacheKey] = generated
                sound = generated
            } else if let loaded = self.loadSound(named: normalizedName) {
                self.soundCache[cacheKey] = loaded
                sound = loaded
            } else {
                sound = NSSound(named: normalizedName)
            }

            if let sound = sound {
                sound.stop()
                sound.currentTime = 0
                sound.volume = volume
                let ok = sound.play()
                print("[SoundManager] 🔊 Ses çalındı [Tema: \(theme), Vol: \(Int(volume * 100))%]: \(normalizedName) (Sonuç: \(ok))")
            } else {
                print("[SoundManager] ⚠️ Ses yüklenemedi: \(normalizedName)")
            }
        }
    }

    public func testSound(theme: String? = nil, volume: Double? = nil) {
        play("dictation-start", customTheme: theme, customVolume: volume)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.20) {
            self.play("paste", customTheme: theme, customVolume: volume)
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
