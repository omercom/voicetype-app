import Foundation
import AppKit
import ApplicationServices

public final class TargetAppAccessibilityLease {
    private var endAction: (() -> Void)?

    public init(endAction: @escaping () -> Void) {
        self.endAction = endAction
    }

    public func end() {
        let action = endAction
        endAction = nil
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

    public init() {}

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

        let appRef = AXUIElementCreateApplication(pid)

        // Mevcut durumu oku
        var currentValue: AnyObject?
        let readStatus = AXUIElementCopyAttributeValue(appRef, Self.manualAccessibilityAttribute, &currentValue)
        let wasEnabled = (readStatus == .success) && ((currentValue as? NSNumber)?.boolValue == true)

        guard !wasEnabled else {
            // Zaten açık, kapatmaya gerek yok
            return nil
        }

        // Erişilebilirliği aktifleştir
        let setStatus = AXUIElementSetAttributeValue(appRef, Self.manualAccessibilityAttribute, NSNumber(value: true))
        guard setStatus == .success else {
            return nil
        }

        print("[ChromiumAX] ⚡ Erişilebilirlik ağacı uyandırıldı: \(bundleIdentifier ?? "pid \(pid)")")

        return TargetAppAccessibilityLease {
            _ = AXUIElementSetAttributeValue(appRef, Self.manualAccessibilityAttribute, NSNumber(value: false))
            print("[ChromiumAX] 💤 Erişilebilirlik ağacı uykuya alındı: \(bundleIdentifier ?? "pid \(pid)")")
        }
    }
}
