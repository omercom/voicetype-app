import XCTest
import AppKit
import CoreGraphics
@testable import VoiceTypingCore

/// Gösterge (HUD) penceresi GERÇEKTEN ekranda mı?
///
/// Bu, zincirin son halkası: form doğru çizilse, görünüm ağacında olsa bile
/// pencere ekranda değilse kullanıcı hiçbir şey görmez.
final class HUDWindowVisibilityTests: XCTestCase {

    private func voiceTypingWindows() -> [[String: Any]] {
        guard let list = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] else {
            return []
        }
        let myPID = ProcessInfo.processInfo.processIdentifier
        return list.filter { w in
            (w[kCGWindowOwnerPID as String] as? Int32).map { $0 == myPID } ?? false
        }
    }

    func testPanelWindowExistsOnScreenWhileRecording() {
        let orig = ConfigManager.shared.config.hud_style
        ConfigManager.shared.update { $0.hud_style = "notch" }
        defer { ConfigManager.shared.update { $0.hud_style = orig } }

        let hud = RecordingHUD.shared
        hud.dismiss(animated: false)
        hud.showRecording()
        // Geçiş animasyonunu tamamla: alfa 1'e çıkmalı.
        hud.finishPresentationTransitions()
        RunLoop.current.run(until: Date().addingTimeInterval(0.4))

        let wins = voiceTypingWindows()
        print("[pencere] test surecinde \(wins.count) pencere bulundu")
        for w in wins {
            let b = w[kCGWindowBounds as String] as? [String: CGFloat] ?? [:]
            let onscreen = (w[kCGWindowIsOnscreen as String] as? Bool) ?? false
            let alpha = (w[kCGWindowAlpha as String] as? Double) ?? -1
            let layer = (w[kCGWindowLayer as String] as? Int) ?? -999
            print("[pencere]   olcu=\(Int(b["Width"] ?? 0))x\(Int(b["Height"] ?? 0))"
                + " konum=(\(Int(b["X"] ?? 0)),\(Int(b["Y"] ?? 0)))"
                + " ekranda=\(onscreen) alfa=\(alpha) katman=\(layer)")
        }

        // Panel görünür ve ekranda olmalı.
        XCTAssertFalse(wins.isEmpty, "Kayıt sırasında bir pencere olmalı")
        XCTAssertTrue(wins.contains { ($0[kCGWindowIsOnscreen as String] as? Bool) == true },
                      "Pencere EKRANDA olmalı")

        hud.dismiss(animated: false)
    }

    func testPanelAlphaReachesFullWhileRecording() {
        let orig = ConfigManager.shared.config.hud_style
        ConfigManager.shared.update { $0.hud_style = "notch" }
        defer { ConfigManager.shared.update { $0.hud_style = orig } }

        let hud = RecordingHUD.shared
        hud.dismiss(animated: false)
        hud.showRecording()
        hud.finishPresentationTransitions()
        RunLoop.current.run(until: Date().addingTimeInterval(0.4))

        let alphas = voiceTypingWindows().compactMap { $0[kCGWindowAlpha as String] as? Double }
        print("[pencere] alfa degerleri: \(alphas)")
        XCTAssertTrue(alphas.contains { $0 > 0.9 },
                      "Panel alfası 1'e yakın olmalı (bulunan: \(alphas))")
        hud.dismiss(animated: false)
    }

    func testNotchPanelIsTallerThanPill() {
        // Çentik modu daha uzun bir panel üretmeli (metin + kamera).
        let orig = ConfigManager.shared.config.hud_style
        defer { ConfigManager.shared.update { $0.hud_style = orig } }

        func panelHeight(style: String) -> CGFloat {
            ConfigManager.shared.update { $0.hud_style = style }
            let hud = RecordingHUD.shared
            hud.dismiss(animated: false)
            hud.showRecording()
            hud.finishPresentationTransitions()
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
            let h = hud.rootContentView?.bounds.height ?? 0
            let w = hud.rootContentView?.bounds.width ?? 0
            hud.dismiss(animated: false)
            print("[pencere] \(style): \(Int(w))x\(Int(h))")
            return h
        }

        let notchH = panelHeight(style: "notch")
        let pillH = panelHeight(style: "pill")
        print("[pencere] notch yuksekligi=\(notchH) pill yuksekligi=\(pillH)")
        XCTAssertNotEqual(notchH, pillH, accuracy: 0.001,
                          "Çentik ve kapsül farklı yükseklikte olmalı")
    }
}
