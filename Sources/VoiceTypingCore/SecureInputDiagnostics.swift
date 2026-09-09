import Foundation
import Carbon.HIToolbox
import IOKit

public struct SecureInputStatus: Equatable, Sendable {
    public let isActive: Bool
    public let description: String

    public init(isActive: Bool, description: String) {
        self.isActive = isActive
        self.description = description
    }
}

/// macOS Güvenli Giriş (Secure Event Input) durumunu tespit eden teşhis servisi.
/// Parola alanları (1Password, Terminal sudo, Safari parola kutuları) aktifken
/// macOS güvenlik amacıyla CGEvent dinleyicilerini ve sentetik Cmd+V tuş simülasyonunu engeller.
public final class SecureInputDiagnostics {
    public static let shared = SecureInputDiagnostics()

    public init() {}

    /// Sistemde güvenli girişin (Secure Event Input) devrede olup olmadığını kontrol eder
    public static func isSecureInputActive() -> Bool {
        return IsSecureEventInputEnabled()
    }

    /// Güvenli giriş durumunun detaylı özetini döner
    public static func checkStatus() -> SecureInputStatus {
        let active = IsSecureEventInputEnabled()
        if active {
            return SecureInputStatus(
                isActive: true,
                description: "Güvenli Giriş Aktif: Sistem parola veya korumalı bir girdi alanında olduğu için sentetik tuşlama kısıtlanmıştır."
            )
        } else {
            return SecureInputStatus(
                isActive: false,
                description: "Normal: Güvenli giriş devrede değil, tüm klavye ve erişilebilirlik eylemleri serbest."
            )
        }
    }
}
