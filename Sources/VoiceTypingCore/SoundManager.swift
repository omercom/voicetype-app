import Foundation
import AppKit

public class SoundManager {
    public static let shared = SoundManager()

    public var isEnabled: Bool = true

    private var soundCache: [String: NSSound] = [:]
    private let soundNames = ["Tink", "Pop", "Glass", "Basso"]

    private init() {
        self.isEnabled = ConfigManager.shared.config.play_sounds
        for name in soundNames {
            if let sound = NSSound(named: name) {
                soundCache[name] = sound
            }
        }
    }

    public func play(_ name: String) {
        guard isEnabled else { return }
        DispatchQueue.main.async {
            if let sound = self.soundCache[name] ?? NSSound(named: name) {
                sound.stop()
                sound.play()
            }
        }
    }

    public func playStart() {
        play("Tink")
    }

    public func playStop() {
        play("Pop")
    }

    public func playSuccess() {
        play("Glass")
    }

    public func playCancel() {
        play("Basso")
    }
}
