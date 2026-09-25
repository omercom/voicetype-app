import Foundation
import AppKit
import AVFoundation
import Speech

public enum PermissionStatus {
    case authorized
    case denied
    case restricted
    case notDetermined
    case unknown

    public var badge: String {
        switch self {
        case .authorized: return "🟢"
        case .denied: return "🔴"
        case .restricted: return "🟠"
        case .notDetermined: return "🟡"
        case .unknown: return "⚪"
        }
    }

    public var isAuthorized: Bool {
        return self == .authorized
    }
}

/// macOS'un genel adı "Erişilebilirlik" olan iznin VoiceTyping içindeki
/// gerçek kullanım alanlarını tek yerde tutar. İzin ekranı, Ayarlar ve
/// dokümantasyon aynı kapsamı anlatmalıdır.
public enum AccessibilityPermissionInfo {
    public static var currentTriggerKeyName: String {
        TriggerKeyOption.shortName(for: ConfigManager.shared.config.trigger_key)
    }

    public static func usageDescription(triggerKeyName: String = currentTriggerKeyName) -> String {
        """
        VoiceTyping menü çubuğunda arka planda çalıştığı için bu izni ister:

        • Global kısayolu (\(triggerKeyName)) ve Esc'i, başka bir uygulama öndeyken algılar. Yalnızca tuş olayını kontrol eder; normal yazı içeriğini kaydetmez.
        • O anda odakta olan uygulamayı ve düzenlenebilir yazı alanını bulur; konuşma bitince odağı aynı yere geri getirir.
        • Deşifre edilen metni panoya koyup sentetik Cmd+V ile hedef uygulamaya, isteğe bağlı Enter ile gönderir.
        """
    }

    public static let privacyNotice = "Bu, macOS'un geniş kapsamlı bir sistem iznidir. VoiceTyping bunu ekran içeriğini, dosyaları veya normal klavye metnini okumak için kullanmaz; yine de yalnızca güvendiğiniz uygulamalara verin. Mikrofon ve Apple Speech izinleri bundan ayrıdır."

    public static let missingPermissionEffect = "İzin verilmezse global bas-konuş kısayolu ve deşifreyi otomatik olarak hedef uygulamaya yazma çalışmaz."
}

public class PermissionManager {
    public static let shared = PermissionManager()

    /// Konuşma tanıma izni yanıtı için üst sınır (saniye).
    ///
    /// Sistem diyaloğu kullanıcıyı bekletebilir; bu yüzden süre cömert
    /// tutuldu. Amaç, callback hiç gelmediğinde başlatma akışının sonsuza
    /// kadar kilitli kalmasını engellemek.
    static let authorizationTimeout: TimeInterval = 20.0

    private init() {}

    // MARK: - Microphone

    public func getMicrophoneStatus() -> (status: PermissionStatus, description: String, badge: String) {
        let auth = AVCaptureDevice.authorizationStatus(for: .audio)
        switch auth {
        case .authorized:
            return (.authorized, "Yetki Verildi (Aktif)", PermissionStatus.authorized.badge)
        case .denied:
            return (.denied, "Erişim Reddedildi", PermissionStatus.denied.badge)
        case .restricted:
            return (.restricted, "Kısıtlı (MDM)", PermissionStatus.restricted.badge)
        case .notDetermined:
            return (.notDetermined, "Henüz İstenmedi", PermissionStatus.notDetermined.badge)
        @unknown default:
            return (.unknown, "Bilinmeyen", PermissionStatus.unknown.badge)
        }
    }

    public func requestMicrophonePermission(completion: @escaping (Bool) -> Void) {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        if status == .notDetermined {
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                DispatchQueue.main.async {
                    completion(granted)
                }
            }
        } else {
            DispatchQueue.main.async {
                completion(status == .authorized)
            }
        }
    }

    public func openMicrophoneSettings() {
        requestMicrophonePermission { _ in
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
                NSWorkspace.shared.open(url)
            }
        }
    }

    // MARK: - Speech Recognition (Apple Speech)

    public func getSpeechRecognitionStatus() -> (status: PermissionStatus, description: String, badge: String) {
        // Test veya CLI ortamı kontrolü (xctest SIGABRT önleme)
        if Bundle.main.bundleIdentifier == "com.apple.dt.xctest.tool" || ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil {
            return (.authorized, "Yetki Verildi (Aktif)", PermissionStatus.authorized.badge)
        }
        guard Bundle.main.object(forInfoDictionaryKey: "NSSpeechRecognitionUsageDescription") != nil else {
            return (.denied, "Erişim Reddedildi", PermissionStatus.denied.badge)
        }
        let auth = SFSpeechRecognizer.authorizationStatus()
        switch auth {
        case .authorized:
            return (.authorized, "Yetki Verildi (Aktif)", PermissionStatus.authorized.badge)
        case .denied:
            return (.denied, "Erişim Reddedildi", PermissionStatus.denied.badge)
        case .restricted:
            return (.restricted, "Kısıtlı (MDM)", PermissionStatus.restricted.badge)
        case .notDetermined:
            return (.notDetermined, "Henüz İstenmedi", PermissionStatus.notDetermined.badge)
        @unknown default:
            return (.unknown, "Bilinmeyen", PermissionStatus.unknown.badge)
        }
    }

    /// Konuşma tanıma izni isteğinde bulunur ve **her durumda** sonuç döner.
    ///
    /// ## Neden timeout koruması var
    ///
    /// `SFSpeechRecognizer.requestAuthorization` callback'i garanti etmez:
    /// TCC durumu değiştiğinde, imza uyuşmadığında veya sistem isteği
    /// düşürdüğünde **hiç çağrılmayabilir**. Çağıran taraf bu callback'e
    /// zincirleme bağlı olduğu için (bkz. `startPermissionsFlow`), callback
    /// gelmezse uygulama başlatma akışı orada kilitleniyordu: tuş dinleyicisi
    /// hiç kurulmuyor, kısayol sessizce ölü kalıyordu ve ekranda hiçbir hata
    /// görünmüyordu. Bu koruma, akışın her koşulda ilerlemesini garanti eder.
    public func requestSpeechRecognitionPermission(completion: @escaping (Bool) -> Void) {
        if Bundle.main.bundleIdentifier == "com.apple.dt.xctest.tool" || ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil {
            DispatchQueue.main.async { completion(true) }
            return
        }
        guard Bundle.main.object(forInfoDictionaryKey: "NSSpeechRecognitionUsageDescription") != nil else {
            DispatchQueue.main.async { completion(false) }
            return
        }

        // Callback yalnızca BİR kez çalışsın (timeout + gerçek yanıt yarışı).
        var hasCompleted = false
        let completionLock = NSLock()
        let finish: (Bool) -> Void = { granted in
            completionLock.lock()
            let alreadyDone = hasCompleted
            hasCompleted = true
            completionLock.unlock()
            guard !alreadyDone else { return }
            DispatchQueue.main.async { completion(granted) }
        }

        let status = SFSpeechRecognizer.authorizationStatus()
        guard status == .notDetermined else {
            finish(status == .authorized)
            return
        }

        SFSpeechRecognizer.requestAuthorization { authStatus in
            finish(authStatus == .authorized)
        }

        // Emniyet supabı: makul sürede yanıt gelmezse mevcut durumu oku ve
        // akışı serbest bırak. Kullanıcı izni sonradan verirse uygulama
        // `applicationDidBecomeActive` ile durumu tazeler.
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.authorizationTimeout) {
            let current = SFSpeechRecognizer.authorizationStatus()
            if current == .notDetermined {
                print("[PermissionManager] ⚠️ Konuşma tanıma izni yanıtı \(Self.authorizationTimeout) sn içinde gelmedi; "
                      + "akış serbest bırakılıyor. İzin verilince uygulama otomatik toparlanır.")
            }
            finish(current == .authorized)
        }
    }

    public func openSpeechRecognitionSettings() {
        requestSpeechRecognitionPermission { _ in
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_SpeechRecognition") {
                NSWorkspace.shared.open(url)
            }
        }
    }

    // MARK: - Accessibility

    public func getAccessibilityStatus() -> (status: PermissionStatus, description: String, badge: String) {
        let trusted = AXIsProcessTrusted()
        if trusted {
            return (.authorized, "Yetki Verildi (Aktif)", PermissionStatus.authorized.badge)
        } else {
            return (.denied, "Yetki Verilmedi (Gerekli)", PermissionStatus.denied.badge)
        }
    }

    public func requestAccessibilityPermission(showSystemPrompt: Bool = false) {
        if showSystemPrompt {
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)
        } else {
            _ = AXIsProcessTrusted()
        }
    }

    public func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - Auto Close System Settings

    public func closeSystemSettings() {
        DispatchQueue.main.async {
            let bundleIDs = ["com.apple.systempreferences", "com.apple.SystemSettings"]
            for id in bundleIDs {
                for app in NSWorkspace.shared.runningApplications where app.bundleIdentifier == id {
                    // Sistem Ayarları'nı sonlandırmak kullanıcının başka bir
                    // ayar işini de kapatabilir. Gizlemek aynı UX'i sağlar ve
                    // kullanıcının açık işini kaybetme riskini ortadan kaldırır.
                    app.hide()
                }
            }
        }
    }
}
