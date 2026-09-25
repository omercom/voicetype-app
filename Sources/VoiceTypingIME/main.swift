import Cocoa
import InputMethodKit

// VoiceTyping Giriş Yöntemi
//
// Görünmez bir macOS giriş yöntemi (InputMethodKit). Klavyeye hiçbir şekilde
// müdahale etmez: tüm tuşlar olduğu gibi uygulamaya geçer. Tek görevi,
// VoiceTyping ana uygulamasından gelen dikte metnini odaktaki alana
// `insertText` ile doğrudan yazmaktır — pano ve sentetik Cmd+V kullanılmaz.
//
// İletişim: dağıtık bildirimler. Her istek, ana uygulamanın yalnızca bu
// kullanıcının okuyabildiği dosyaya (0600) yazdığı rastgele jetonu taşır;
// jeton eşleşmeyen istekler yok sayılır.

enum IMEProtocol {
    static let insertRequest = Notification.Name("com.antigravity.VoiceTyping.ime.insert")
    static let insertResult = Notification.Name("com.antigravity.VoiceTyping.ime.result")
    static let activated = Notification.Name("com.antigravity.VoiceTyping.ime.activated")
    static var tokenURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".voice_typing/ime_token")
    }
}

@objc(VoiceTypingInputController)
final class VoiceTypingInputController: IMKInputController {
    /// En son etkinleşen denetleyici; istemci (odaktaki alan) ona aittir.
    static weak var current: VoiceTypingInputController?

    override func activateServer(_ sender: Any!) {
        super.activateServer(sender)
        Self.current = self
        DistributedNotificationCenter.default().postNotificationName(
            IMEProtocol.activated, object: nil, userInfo: nil, deliverImmediately: true
        )
    }

    override func deactivateServer(_ sender: Any!) {
        if Self.current === self { Self.current = nil }
        super.deactivateServer(sender)
    }

    /// Hiçbir tuşu işlemeyiz; klavye normal çalışmaya devam eder.
    override func handle(_ event: NSEvent!, client sender: Any!) -> Bool { false }

    func insert(_ text: String) -> Bool {
        guard let client = client() else { return false }
        client.insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0))
        return true
    }
}

final class Bridge: NSObject {
    func start() {
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(handleInsert(_:)),
            name: IMEProtocol.insertRequest,
            object: nil,
            suspensionBehavior: .deliverImmediately
        )
    }

    @objc private func handleInsert(_ note: Notification) {
        guard let info = note.userInfo,
              let id = info["id"] as? String,
              let text = info["text"] as? String,
              let token = info["token"] as? String else { return }

        let expected = (try? String(contentsOf: IMEProtocol.tokenURL, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let expected, !expected.isEmpty, token == expected else { return }

        let ok = VoiceTypingInputController.current?.insert(text) ?? false
        DistributedNotificationCenter.default().postNotificationName(
            IMEProtocol.insertResult,
            object: nil,
            userInfo: ["id": id, "ok": ok, "reason": ok ? "" : "istemci yok"],
            deliverImmediately: true
        )
    }
}

let connectionName = Bundle.main.infoDictionary?["InputMethodConnectionName"] as? String
    ?? "VoiceTypingIME_Connection"
let server = IMKServer(name: connectionName, bundleIdentifier: Bundle.main.bundleIdentifier)
let bridge = Bridge()
bridge.start()
_ = server
NSApplication.shared.run()
