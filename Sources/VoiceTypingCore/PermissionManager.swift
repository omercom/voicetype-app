import Foundation
import AppKit
import AVFoundation

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

public class PermissionManager {
    public static let shared = PermissionManager()

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
            completion(status == .authorized)
        }
    }

    public func openMicrophoneSettings() {
        requestMicrophonePermission { _ in
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
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
                    app.terminate()
                }
            }
        }
    }
}
