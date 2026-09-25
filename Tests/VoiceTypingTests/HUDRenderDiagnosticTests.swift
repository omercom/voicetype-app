import XCTest
import AppKit
@testable import VoiceTypingCore

/// Teşhis amaçlı: gerçek HUD panelini bitmap'e çizip diske yazar.
///
/// "Ekranda hiçbir şey değişmedi" şikayetini tahminle değil, GÖRSEL olarak
/// incelemek için. Panel, mavi zemin üzerine bindirilir; böylece siyah ada
/// formu net görünür (masaüstünde siyah üstüne siyah olabilir).
final class HUDRenderDiagnosticTests: XCTestCase {

    private let outDir = "/Users/omer/.gemini/antigravity/brain/de5bc3fb-dcd8-4c36-88b9-22061862cd38/scratch"

    @discardableResult
    private func dump(_ hud: RecordingHUD, name: String, bg: NSColor) -> NSBitmapImageRep? {
        guard let root = hud.rootContentView else {
            XCTFail("contentView yok"); return nil
        }
        let size = root.bounds.size
        guard size.width > 0, size.height > 0 else {
            XCTFail("boyut sifir"); return nil
        }
        guard let rep = root.bitmapImageRepForCachingDisplay(in: root.bounds) else {
            XCTFail("bitmap yok"); return nil
        }
        root.cacheDisplay(in: root.bounds, to: rep)

        let src = NSImage(size: size)
        src.addRepresentation(rep)

        let out = NSImage(size: size)
        out.lockFocus()
        bg.setFill()
        NSRect(origin: .zero, size: size).fill()
        src.draw(at: .zero, from: NSRect(origin: .zero, size: size),
                 operation: .sourceOver, fraction: 1)
        out.unlockFocus()

        guard let tiff = out.tiffRepresentation,
              let bmp = NSBitmapImageRep(data: tiff),
              let png = bmp.representation(using: .png, properties: [:]) else {
            XCTFail("png yok"); return nil
        }
        let url = URL(fileURLWithPath: "\(outDir)/\(name).png")
        try? png.write(to: url)

        // Kac piksel siyah (dolgu var mi?)
        var dark = 0
        if let r = NSBitmapImageRep(data: tiff) {
            for y in stride(from: 0, to: r.pixelsHigh, by: 3) {
                for x in stride(from: 0, to: r.pixelsWide, by: 3) {
                    if let c = r.colorAt(x: x, y: y), c.brightnessComponent < 0.15 { dark += 1 }
                }
            }
        }
        print("[render] \(name): \(Int(size.width))x\(Int(size.height)) koyu-piksel=\(dark) -> \(url.path)")
        return NSBitmapImageRep(data: tiff)
    }

    func testDumpNotchRender() {
        let orig = ConfigManager.shared.config.hud_style
        ConfigManager.shared.update { $0.hud_style = "notch" }
        defer { ConfigManager.shared.update { $0.hud_style = orig } }

        let hud = RecordingHUD.shared
        hud.dismiss(animated: false)
        hud.showRecording()
        hud.finishPresentationTransitions()
        hud.updateInterimText("Merhaba dünya bu bir çentik testi")

        let rep = dump(hud, name: "hud_notch", bg: .systemBlue)
        hud.dismiss(animated: false)

        // Dolgu gerçekten var mı?
        if let rep {
            let mid = rep.colorAt(x: rep.pixelsWide / 2, y: rep.pixelsHigh / 2)
            print("[render] notch merkez renk: \(mid?.description ?? "nil")")
            XCTAssertNotNil(mid)
        }
    }

    func testDumpPillRender() {
        let orig = ConfigManager.shared.config.hud_style
        ConfigManager.shared.update { $0.hud_style = "pill" }
        defer { ConfigManager.shared.update { $0.hud_style = orig } }

        let hud = RecordingHUD.shared
        hud.dismiss(animated: false)
        hud.showRecording()
        hud.finishPresentationTransitions()
        hud.updateInterimText("Merhaba dünya")

        dump(hud, name: "hud_pill", bg: .systemBlue)
        hud.dismiss(animated: false)
    }
}
