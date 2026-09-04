import Foundation
import AppKit

public final class HapticManager {
    public static let shared = HapticManager()

    private init() {}

    /// Dikte başladığında parmak ucuna hafif, tok bir tık verir (.generic)
    public func playStart() {
        guard ConfigManager.shared.config.haptic_feedback else { return }
        DispatchQueue.main.async {
            NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now)
        }
    }

    /// Metin yapıştırıldığında veya işlem başarıyla tamamlandığında onay hissi verir (.alignment)
    public func playSuccess() {
        guard ConfigManager.shared.config.haptic_feedback else { return }
        DispatchQueue.main.async {
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        }
    }

    /// İptal edildiğinde veya hata oluştuğunda hafif bir geri bildirim verir
    public func playCancel() {
        guard ConfigManager.shared.config.haptic_feedback else { return }
        DispatchQueue.main.async {
            NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
        }
    }
}
