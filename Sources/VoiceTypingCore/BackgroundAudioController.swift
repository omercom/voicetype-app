import Foundation

/// Arka plan ses yönetimini (Audio Ducking veya Medya Duraklatma) kullanıcının
/// aktif ayarlarına göre koordine eden merkezi denetleyici.
public final class BackgroundAudioController: @unchecked Sendable {
    public static let shared = BackgroundAudioController()

    private let lock = NSLock()
    private var isAudioDucked: Bool = false
    private var isMediaPaused: Bool = false

    public init() {}

    /// Dikte başladığında arka plan sesini kullanıcının tercihine göre yönetir
    public func handleDictationStarted(config: AppConfig) {
        lock.lock()
        defer { lock.unlock() }

        switch config.background_audio_mode.lowercased() {
        case "ducking":
            let success = AudioDuckingService.shared.duckAudio(to: 0.20)
            isAudioDucked = success
        case "pause":
            MediaPlaybackManager.shared.pauseForDictation()
            isMediaPaused = true
        default:
            // "none" veya tanımsız: Arka plan sesine dokunulmaz
            break
        }
    }

    /// Dikte bittiğinde veya iptal edildiğinde arka plan sesini eski haline getirir
    public func handleDictationEnded(config: AppConfig) {
        lock.lock()
        defer { lock.unlock() }

        if isAudioDucked || AudioDuckingService.shared.isDucked {
            AudioDuckingService.shared.restoreAudio()
            isAudioDucked = false
        }

        if isMediaPaused {
            MediaPlaybackManager.shared.resumeAfterDictation()
            isMediaPaused = false
        }
    }
}
