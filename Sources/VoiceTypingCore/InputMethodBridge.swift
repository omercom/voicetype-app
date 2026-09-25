import Foundation
import Carbon

/// VoiceTyping Giriş Yöntemi ile konuşan köprü.
///
/// Akış (ana thread):
/// 1. Mevcut klavye kaynağı saklanır, VoiceTyping giriş yöntemi seçilir.
/// 2. Giriş yöntemi odaktaki alanda etkinleşince (`activated`) metin gönderilir.
/// 3. Giriş yöntemi metni `insertText` ile doğrudan alana yazar ve sonucu bildirir.
/// 4. Önceki klavye kaynağı geri seçilir.
///
/// Herhangi bir adım zaman aşımına uğrarsa `false` döner; çağıran Cmd+V yoluna düşer.
public final class InputMethodBridge {
    public static let shared = InputMethodBridge()

    static let sourceID = "com.antigravity.inputmethod.VoiceTyping"
    static let insertRequest = Notification.Name("com.antigravity.VoiceTyping.ime.insert")
    static let insertResult = Notification.Name("com.antigravity.VoiceTyping.ime.result")
    static let activated = Notification.Name("com.antigravity.VoiceTyping.ime.activated")

    public static var installedURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Input Methods/VoiceTypingIME.app")
    }
    static var tokenURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".voice_typing/ime_token")
    }

    private var token = ""
    private var busy = false

    private init() {}

    /// Uygulama açılışında çağrılır: jetonu yeniler, giriş yöntemini kaydeder
    /// ve etkinleştirir. Giriş yöntemi kurulu değilse sessizce geçer.
    public func prepare() {
        precondition(Thread.isMainThread)
        writeFreshToken()
        guard FileManager.default.fileExists(atPath: Self.installedURL.path) else {
            print("[IME] Giriş yöntemi kurulu değil; Cmd+V kullanılacak.")
            return
        }
        TISRegisterInputSource(Self.installedURL as CFURL)
        if let source = inputSource(), !isEnabled(source) {
            let status = TISEnableInputSource(source)
            print("[IME] Giriş yöntemi etkinleştirildi (durum: \(status)).")
        }
        print("[IME] Hazır: \(isAvailable ? "evet" : "hayır")")
    }

    public var isAvailable: Bool {
        guard let source = inputSource() else { return false }
        return isEnabled(source)
    }

    /// Metni giriş yöntemiyle odaktaki alana yazar. `completion(true)` metnin
    /// istemciye iletildiğini bildirir (alanın gerçekten değiştiği ayrıca doğrulanır).
    public func insert(_ text: String, timeout: TimeInterval = 0.6, completion: @escaping (Bool) -> Void) {
        precondition(Thread.isMainThread)
        guard !busy, let imeSource = inputSource(), isEnabled(imeSource),
              let previous = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue() else {
            completion(false)
            return
        }
        busy = true

        let requestID = UUID().uuidString
        let center = DistributedNotificationCenter.default()
        var observers: [NSObjectProtocol] = []
        var sent = false
        var finished = false

        let finish: (Bool) -> Void = { [weak self] ok in
            guard !finished else { return }
            finished = true
            observers.forEach { center.removeObserver($0) }
            // Kullanıcının klavye düzenine hemen geri dön.
            TISSelectInputSource(previous)
            self?.busy = false
            completion(ok)
        }

        let send: () -> Void = { [weak self] in
            guard let self, !sent, !finished else { return }
            sent = true
            center.postNotificationName(
                Self.insertRequest,
                object: nil,
                userInfo: ["id": requestID, "text": text, "token": self.token],
                deliverImmediately: true
            )
        }

        observers.append(center.addObserver(forName: Self.insertResult, object: nil, queue: .main) { note in
            guard (note.userInfo?["id"] as? String) == requestID else { return }
            let ok = (note.userInfo?["ok"] as? Bool) ?? false
            if !ok { print("[IME] Giriş yöntemi yazamadı: \(note.userInfo?["reason"] ?? "")") }
            finish(ok)
        })
        observers.append(center.addObserver(forName: Self.activated, object: nil, queue: .main) { _ in send() })

        let alreadyCurrent = (TISGetInputSourceProperty(previous, kTISPropertyInputSourceID)
            .map { Unmanaged<CFString>.fromOpaque($0).takeUnretainedValue() as String }) == Self.sourceID
        if alreadyCurrent {
            send()
        } else {
            TISSelectInputSource(imeSource)
        }

        // Etkinleşme bildirimi kaçarsa yine de dene; sonra zaman aşımıyla vazgeç.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { send() }
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { finish(false) }
    }

    // MARK: - Yardımcılar

    private func inputSource() -> TISInputSource? {
        let filter = [kTISPropertyInputSourceID as String: Self.sourceID] as CFDictionary
        guard let list = TISCreateInputSourceList(filter, true)?.takeRetainedValue() as? [TISInputSource] else {
            return nil
        }
        return list.first
    }

    private func isEnabled(_ source: TISInputSource) -> Bool {
        guard let raw = TISGetInputSourceProperty(source, kTISPropertyInputSourceIsEnabled) else { return false }
        return CFBooleanGetValue(Unmanaged<CFBoolean>.fromOpaque(raw).takeUnretainedValue())
    }

    private func writeFreshToken() {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        token = bytes.map { String(format: "%02x", $0) }.joined()
        let url = Self.tokenURL
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: url.path, contents: Data(token.utf8), attributes: [.posixPermissions: 0o600])
    }
}
