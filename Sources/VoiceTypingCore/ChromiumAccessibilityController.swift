import Foundation
import AppKit
import ApplicationServices

public final class TargetAppAccessibilityLease {
    private let lock = NSLock()
    private var endAction: (() -> Void)?

    public init(endAction: @escaping () -> Void) {
        self.endAction = endAction
    }

    public func end() {
        lock.lock()
        let action = endAction
        endAction = nil
        lock.unlock()
        action?()
    }

    deinit {
        end()
    }
}

/// Google Chrome, Arc, Brave ve Electron tabanlı uygulamalarda (Slack, VS Code, Cursor, Notion)
/// varsayılan olarak uykuda olan macOS Erişilebilirlik (AX) ağacını geçici olarak uyandıran denetleyici.
public final class ChromiumAccessibilityController {
    public static let shared = ChromiumAccessibilityController()

    private static let manualAccessibilityAttribute = "AXManualAccessibility" as CFString

    public static let chromiumBundleIdentifiers: Set<String> = [
        "com.google.Chrome",
        "com.google.Chrome.canary",
        "com.brave.Browser",
        "company.thebrowser.Browser", // Arc
        "com.microsoft.edgemac",
        "com.operasoftware.Opera",
        "com.vivaldi.Vivaldi",
        "org.chromium.Chromium"
    ]

    public static let popularElectronBundleIdentifiers: Set<String> = [
        "com.microsoft.VSCode",
        "com.todesktop.230313mzl4w4u92", // Cursor
        "com.tinyspeck.slackmacgap",      // Slack
        "com.hnc.Discord",               // Discord
        "notion.id",                     // Notion
        "md.obsidian",                   // Obsidian
        "com.github.GitHubClient"        // GitHub Desktop
    ]

    private let lock = NSLock()
    private var ownedObservations: [pid_t: Int] = [:]
    private let readEnabled: (pid_t) -> Bool
    private let setEnabled: (pid_t, Bool) -> Bool

    public convenience init() {
        self.init(
            readEnabled: { pid in
                let appRef = AXUIElementCreateApplication(pid)
                var value: AnyObject?
                let status = AXUIElementCopyAttributeValue(appRef, Self.manualAccessibilityAttribute, &value)
                return status == .success && ((value as? NSNumber)?.boolValue == true)
            },
            setEnabled: { pid, enabled in
                let appRef = AXUIElementCreateApplication(pid)
                return AXUIElementSetAttributeValue(appRef, Self.manualAccessibilityAttribute, NSNumber(value: enabled)) == .success
            }
        )
    }

    init(readEnabled: @escaping (pid_t) -> Bool, setEnabled: @escaping (pid_t, Bool) -> Bool) {
        self.readEnabled = readEnabled
        self.setEnabled = setEnabled
    }

    /// Verilen uygulamanın Chromium veya Electron tabanlı olup olmadığını tespit eder
    public func isChromiumOrElectron(bundleIdentifier: String?, bundleURL: URL? = nil) -> Bool {
        guard let bundleIdentifier = bundleIdentifier else { return false }
        if Self.chromiumBundleIdentifiers.contains(bundleIdentifier) ||
           Self.popularElectronBundleIdentifiers.contains(bundleIdentifier) {
            return true
        }

        if let bundleURL = bundleURL {
            let frameworkURL = bundleURL
                .appendingPathComponent("Contents", isDirectory: true)
                .appendingPathComponent("Frameworks", isDirectory: true)
                .appendingPathComponent("Electron Framework.framework", isDirectory: true)
            return FileManager.default.fileExists(atPath: frameworkURL.path)
        }

        return false
    }

    /// Hedef uygulamanın erişilebilirlik ağacını dikte süresince uyandırır
    public func beginObservation(
        processIdentifier: pid_t?,
        bundleIdentifier: String?,
        bundleURL: URL? = nil
    ) -> TargetAppAccessibilityLease? {
        guard let pid = processIdentifier,
              isChromiumOrElectron(bundleIdentifier: bundleIdentifier, bundleURL: bundleURL) else {
            return nil
        }

        lock.lock()
        if let count = ownedObservations[pid] {
            ownedObservations[pid] = count + 1
        } else {
            // Zaten kullanıcı veya başka bir uygulama tarafından açıldıysa sahiplenme.
            guard !readEnabled(pid), setEnabled(pid, true) else {
                lock.unlock()
                return nil
            }
            ownedObservations[pid] = 1
            print("[ChromiumAX] ⚡ Erişilebilirlik ağacı uyandırıldı: \(bundleIdentifier ?? "pid \(pid)")")
        }
        lock.unlock()

        return TargetAppAccessibilityLease { [self] in
            endObservation(pid: pid, bundleIdentifier: bundleIdentifier)
        }
    }

    private func endObservation(pid: pid_t, bundleIdentifier: String?) {
        lock.lock()
        defer { lock.unlock() }
        guard let count = ownedObservations[pid] else { return }
        if count > 1 {
            ownedObservations[pid] = count - 1
        } else {
            ownedObservations.removeValue(forKey: pid)
            _ = setEnabled(pid, false)
            print("[ChromiumAX] 💤 Erişilebilirlik ağacı uykuya alındı: \(bundleIdentifier ?? "pid \(pid)")")
        }
    }
}
