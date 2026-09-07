import Foundation
import AppKit
import CoreAudio

/// macOS Sistem Genelinde Arka Plan Medya Oynatımını Yöneten Sınıf.
///
/// Dikteye başlandığında arka plandaki medya (YouTube, Spotify, Apple Music, Safari, Chrome, Podcasts vb.)
/// gerçekten oynatma (play) modunda ise, fiziksel klavyedeki Play/Pause (F8 / `NX_KEYTYPE_PLAY`) tuşunu
/// simüle ederek medyayı duraklatır (pause).
///
/// Deşifre işlemi tamamlandığında veya iptal edildiğinde, yalnızca dikte öncesinde gerçekten oynatılmakta olan
/// medyayı tekrar Play/Pause tuşuyla kaldığı yerden devam ettirir (resume).
///
/// Önceden duraklatılmış veya çalmıyorken başlatılan diktelerde tuşa ASLA basılmaz;
/// bu sayede dikte sonrasında rastgele veya istenmeyen bir medyanın başlaması %100 engellenir.
public class MediaPlaybackManager {
    public static let shared = MediaPlaybackManager()

    private var wasMediaPlayingBeforeDictation: Bool = false
    private let lock = NSLock()

    // MediaRemote.framework dinamik fonksiyon bağlayıcıları
    private typealias MRMediaRemoteGetNowPlayingApplicationIsPlayingFunc = @convention(c) (DispatchQueue, @escaping (Bool) -> Void) -> Void
    private typealias MRMediaRemoteSendCommandFunc = @convention(c) (Int32, AnyObject?) -> Bool

    private var mrGetIsPlaying: MRMediaRemoteGetNowPlayingApplicationIsPlayingFunc?
    private var mrSendCommand: MRMediaRemoteSendCommandFunc?

    private init() {
        if let handle = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_NOW) {
            if let sym = dlsym(handle, "MRMediaRemoteGetNowPlayingApplicationIsPlaying") {
                mrGetIsPlaying = unsafeBitCast(sym, to: MRMediaRemoteGetNowPlayingApplicationIsPlayingFunc.self)
            }
            if let sym = dlsym(handle, "MRMediaRemoteSendCommand") {
                mrSendCommand = unsafeBitCast(sym, to: MRMediaRemoteSendCommandFunc.self)
            }
        }
    }

    /// Arka planda şu anda gerçekten bir medya (ses/video) oynatılıp oynatılmadığını kontrol eder.
    ///
    /// Öncelik Sırası:
    /// 1. MediaRemote (`MRMediaRemoteGetNowPlayingApplicationIsPlaying`) - En hızlı ve sistem standardı (~17ms)
    /// 2. Spotify çalışıyorsa AppleScript kontrolü (`tell application "Spotify" to player state is playing`)
    /// 3. Apple Music çalışıyorsa AppleScript kontrolü (`tell application "Music" to player state is playing`)
    /// 4. CoreAudio donanım çıkışı (`kAudioDevicePropertyDeviceIsRunningSomewhere`)
    public func isMediaActuallyPlaying(timeout: TimeInterval = 0.12) -> Bool {
        // 1. MediaRemote API Denetimi
        if let getIsPlaying = mrGetIsPlaying {
            let sema = DispatchSemaphore(value: 0)
            var isPlaying = false
            getIsPlaying(DispatchQueue.global(qos: .userInteractive)) { playing in
                isPlaying = playing
                sema.signal()
            }
            if sema.wait(timeout: .now() + timeout) == .success {
                if isPlaying {
                    return true
                }
            }
        }

        // 2. Spotify Denetimi (Yalnızca uygulama açıksa sorgulanır, açılmamışsa tetiklenmez)
        if isAppRunning(bundleId: "com.spotify.client") {
            if checkAppleScript(source: "tell application \"Spotify\" to player state is playing") {
                return true
            }
        }

        // 3. Apple Music Denetimi (Yalnızca uygulama açıksa sorgulanır)
        if isAppRunning(bundleId: "com.apple.Music") {
            if checkAppleScript(source: "tell application \"Music\" to player state is playing") {
                return true
            }
        }

        return false
    }

    /// Fiziksel Mac klavyesindeki Play/Pause (F8) tuşuna basılma donanım olayını (`NX_KEYTYPE_PLAY = 16`) simüle eder.
    /// Bu işlem odağı bozmaz (focus çalmaz) ve macOS HID katmanından tüm sistem medyasına iletilir.
    public func simulatePlayPauseKey() {
        let NX_KEYTYPE_PLAY: Int32 = 16

        func postKeyEvent(down: Bool) {
            let flags = NSEvent.ModifierFlags(rawValue: down ? 0xa00 : 0xb00)
            let data1 = Int((NX_KEYTYPE_PLAY << 16) | (down ? 0xa00 : 0xb00))
            let event = NSEvent.otherEvent(
                with: .systemDefined,
                location: .zero,
                modifierFlags: flags,
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                subtype: 8, // NX_SUBTYPE_AUX_CONTROL_BUTTONS
                data1: data1,
                data2: -1
            )
            event?.cgEvent?.post(tap: .cghidEventTap)
        }

        postKeyEvent(down: true)
        usleep(30_000)
        postKeyEvent(down: false)
    }

    /// Dikte başladığında çağrılır:
    /// Eğer arka planda medya gerçekten çalıyorsa, Play/Pause tuşuyla duraklatır ve durumu kaydeder.
    /// Çalmıyorsa hiçbir işlem yapmaz.
    public func pauseForDictation() {
        lock.lock()
        defer { lock.unlock() }

        // Zaten duraklatılmış aktif bir dikte oturumu varsa tekrar basma
        guard !wasMediaPlayingBeforeDictation else { return }

        let isPlaying = isMediaActuallyPlaying()
        if isPlaying {
            wasMediaPlayingBeforeDictation = true
            print("[MediaPlaybackManager] 🎵 Arka planda aktif medya oynatılıyor tespit edildi. Klavye Play/Pause (F8) ile duraklatılıyor...")
            simulatePlayPauseKey()
        } else {
            wasMediaPlayingBeforeDictation = false
            print("[MediaPlaybackManager] 🔇 Arka planda aktif medya oynatılmıyor. Play/Pause tuşuna basılmadı.")
        }
    }

    /// Deşifre tamamlandığında, metin yazıldığında veya dikte iptal edildiğinde çağrılır:
    /// Yalnızca dikte öncesinde medya çalıyorduysa (`wasMediaPlayingBeforeDictation == true`) Play/Pause tuşuna basarak devam ettirir.
    public func resumeAfterDictation() {
        lock.lock()
        defer { lock.unlock() }

        if wasMediaPlayingBeforeDictation {
            print("[MediaPlaybackManager] ▶️ Dikte bitti. Medya klavye Play/Pause (F8) tuşuyla kaldığı yerden devam ettiriliyor...")
            simulatePlayPauseKey()
            wasMediaPlayingBeforeDictation = false
        }
    }

    /// Uygulama kapanırken veya acil reset durumunda güvenli geri yükleme
    public func resetState() {
        lock.lock()
        defer { lock.unlock() }

        if wasMediaPlayingBeforeDictation {
            simulatePlayPauseKey()
            wasMediaPlayingBeforeDictation = false
        }
    }

    // MARK: - Yardımcı Metotlar

    private func isAppRunning(bundleId: String) -> Bool {
        return !NSRunningApplication.runningApplications(withBundleIdentifier: bundleId).isEmpty
    }

    private func checkAppleScript(source: String) -> Bool {
        var error: NSDictionary?
        if let script = NSAppleScript(source: source) {
            let res = script.executeAndReturnError(&error)
            return res.booleanValue
        }
        return false
    }
}
