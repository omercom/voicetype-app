import Foundation

/// Arka plan ses yönetimini (Audio Ducking veya Medya Duraklatma) kullanıcının
/// aktif ayarlarına göre koordine eden merkezi denetleyici.
public final class BackgroundAudioController: @unchecked Sendable {
    public static let shared = BackgroundAudioController()

    // Medya sorguları ve CoreAudio işlemleri ana thread'i bloklayabildiği için
    // aynı seri kuyrukta çalıştırılır. Böylece start/end/cancel çağrıları FIFO
    // sırasını korur ve bitiş işlemi, başlangıç işleminin önüne geçemez.
    private let workQueue = DispatchQueue(
        label: "com.voicetyping.background-audio",
        qos: .utility
    )
    private let workQueueKey = DispatchSpecificKey<Void>()

    // Bu durum yalnızca workQueue üzerinde okunur ve yazılır.
    private var isAudioDucked: Bool = false
    private var isMediaPaused: Bool = false

    public init() {
        workQueue.setSpecific(key: workQueueKey, value: ())
    }

    /// Dikte başladığında arka plan sesini kullanıcının tercihine göre yönetir.
    /// İşlem ana thread'e dönmeden seri arka plan kuyruğuna bırakılır.
    public func handleDictationStarted(config: AppConfig) {
        workQueue.async { [weak self] in
            self?.performDictationStarted(config: config)
        }
    }

    private func performDictationStarted(config: AppConfig) {
        switch config.background_audio_mode.lowercased() {
        case "ducking":
            guard !isAudioDucked else { return }
            isAudioDucked = AudioDuckingService.shared.duckAudio(to: 0.20)
        case "pause":
            guard !isMediaPaused else { return }
            MediaPlaybackManager.shared.pauseForDictation()
            // MediaPlaybackManager kendi içinde, dikte öncesinde medya çalıp
            // çalmadığını saklar; burada yalnızca bu oturumun pause isteğini
            // restore aşamasına taşırız.
            isMediaPaused = true
        default:
            // "none" veya tanımsız: Arka plan sesine dokunulmaz.
            break
        }
    }

    /// Dikte bittiğinde veya iptal edildiğinde arka plan sesini eski haline getirir.
    /// Başlangıçtan sonra kuyruğa eklendiği için restoration, başlangıç işlemi
    /// tamamlanmadan çalışamaz.
    public func handleDictationEnded(config: AppConfig) {
        workQueue.async { [weak self] in
            self?.performDictationEnded()
        }
    }

    private func performDictationEnded() {
        if isAudioDucked || AudioDuckingService.shared.isDucked {
            AudioDuckingService.shared.restoreAudio()
            isAudioDucked = false
        }

        if isMediaPaused {
            MediaPlaybackManager.shared.resumeAfterDictation()
            isMediaPaused = false
        }
    }

    /// Uygulama kapanmadan önce kuyruğa alınmış ses işlemlerinin tamamlanmasını
    /// bekler. Normal dikte akışında çağırmak gerekmez; termination cleanup için
    /// restoration'ın süreç sonlanmadan bitmesini garanti eder.
    public func waitForPendingWork() {
        guard DispatchQueue.getSpecific(key: workQueueKey) == nil else { return }
        workQueue.sync {}
    }
}
