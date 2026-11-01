import AppKit
import ApplicationServices
import Carbon

final class SelectedTextReader {
    private var generation = UUID()
    private let queue = DispatchQueue(label: "com.voicetyping.selected-text", qos: .userInitiated)

    func cancel() { generation = UUID() }

    func read(completion: @escaping (Result<String, Error>) -> Void) {
        cancel()
        let token = generation
        guard AXIsProcessTrusted() else {
            completion(.failure(ReadAloudError.message("Seçili metin için Erişilebilirlik izni gerekli.")))
            return
        }
        guard !IsSecureEventInputEnabled(), let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier else {
            completion(.failure(ReadAloudError.message("Bu alandan metin alınamıyor. Metni kopyalayıp Panoyu Seslendir kullanın.")))
            return
        }
        let pid = app.processIdentifier
        queue.async { [weak self] in
            let result = Self.accessibilitySelection(pid: pid)
            DispatchQueue.main.async {
                guard let self, self.generation == token else { return }
                guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else {
                    completion(.failure(ReadAloudError.message("Öndeki uygulama değişti. Yeniden deneyin.")))
                    return
                }
                switch result {
                case .text(let text): completion(.success(text))
                case .secure: completion(.failure(ReadAloudError.message("Güvenli metin alanları seslendirilmez.")))
                case .empty: completion(.failure(ReadAloudError.message("Önce bir metin seçin.")))
                case .unsupported: self.copySelection(pid: pid, token: token, completion: completion)
                }
            }
        }
    }

    private enum Selection {
        case text(String), secure, empty, unsupported
    }

    private static func accessibilitySelection(pid: pid_t) -> Selection {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.25)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return .unsupported }
        var element = unsafeBitCast(value, to: AXUIElement.self)
        var sawEmpty = false
        for _ in 0..<5 {
            AXUIElementSetMessagingTimeout(element, 0.25)
            var subrole: CFTypeRef?
            AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &subrole)
            if subrole as? String == "AXSecureTextField" { return .secure }
            var selected: CFTypeRef?
            if AXUIElementCopyAttributeValue(element, kAXSelectedTextAttribute as CFString, &selected) == .success,
               let text = selected as? String {
                if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return .text(text) }
                sawEmpty = true
            }
            var parent: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, kAXParentAttribute as CFString, &parent) == .success,
                  let parent, CFGetTypeID(parent) == AXUIElementGetTypeID(), !CFEqual(element, parent) else { break }
            element = unsafeBitCast(parent, to: AXUIElement.self)
        }
        return sawEmpty ? .empty : .unsupported
    }

    private func copySelection(pid: pid_t, token: UUID, completion: @escaping (Result<String, Error>) -> Void) {
        let deadline = ProcessInfo.processInfo.systemUptime + 1.5
        func waitForRelease() {
            guard generation == token else { return }
            guard !IsSecureEventInputEnabled(), NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else {
                completion(.failure(ReadAloudError.message("Metin güvenli biçimde alınamadı.")))
                return
            }
            let flags = CGEventSource.flagsState(.combinedSessionState)
            if !flags.intersection([.maskCommand, .maskAlternate, .maskControl, .maskShift]).isEmpty {
                guard ProcessInfo.processInfo.systemUptime < deadline else {
                    completion(.failure(ReadAloudError.message("Kısayol tuşlarını bırakıp yeniden deneyin.")))
                    return
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: waitForRelease)
                return
            }
            performCopy(pid: pid, token: token, completion: completion)
        }
        waitForRelease()
    }

    private func performCopy(pid: pid_t, token: UUID, completion: @escaping (Result<String, Error>) -> Void) {
        let pasteboard = NSPasteboard.general
        let originalCount = pasteboard.changeCount
        guard let snapshot = TextInjector.shared.captureCompleteClipboardSnapshot(from: pasteboard),
              pasteboard.changeCount == originalCount else {
            completion(.failure(ReadAloudError.message("Pano yedeklenemedi; pano değiştirilmedi.")))
            return
        }
        guard generation == token, !IsSecureEventInputEnabled(),
              NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else {
            completion(.failure(ReadAloudError.message("Öndeki uygulama değişti. Yeniden deneyin.")))
            return
        }
        guard let key = TextInjector.resolvedKeyCodeForCharacter("c") else {
            completion(.failure(ReadAloudError.message("Klavye düzeninde kopyalama tuşu bulunamadı.")))
            return
        }
        let source = CGEventSource(stateID: .privateState)
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: false) else {
            completion(.failure(ReadAloudError.message("Seçili metin kopyalanamadı.")))
            return
        }
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.postToPid(pid)
        up.postToPid(pid)
        let deadline = ProcessInfo.processInfo.systemUptime + 0.6
        func checkCopy() {
            if pasteboard.changeCount != originalCount {
                let copiedCount = pasteboard.changeCount
                let text = pasteboard.string(forType: .string)
                // Never erase a newer clipboard write that arrived while reading.
                if Self.shouldRestoreClipboard(copiedCount: copiedCount, currentCount: pasteboard.changeCount) {
                    TextInjector.shared.restoreClipboardSnapshot(snapshot)
                }
                guard generation == token else { return }
                guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid, let text,
                      !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    completion(.failure(ReadAloudError.message("Seçili metin alınamadı. Kopyalayıp Panoyu Seslendir kullanın.")))
                    return
                }
                completion(.success(text))
                return
            }
            guard ProcessInfo.processInfo.systemUptime < deadline else {
                if generation == token {
                    completion(.failure(ReadAloudError.message("Seçili metin alınamadı. Kopyalayıp Panoyu Seslendir kullanın.")))
                }
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: checkCopy)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: checkCopy)
    }

    static func shouldRestoreClipboard(copiedCount: Int, currentCount: Int) -> Bool {
        copiedCount == currentCount
    }
}
