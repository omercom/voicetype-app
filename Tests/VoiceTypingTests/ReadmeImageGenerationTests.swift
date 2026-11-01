import AppKit
import XCTest
@testable import VoiceTypingCore

/// Renders the application's own views with demo data. Run explicitly with
/// VOICETYPE_README_IMAGE_DIR set to a private output directory.
final class ReadmeImageGenerationTests: XCTestCase {
    private func descendants(of view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap { descendants(of: $0) }
    }

    private func png(of view: NSView, background: NSColor? = nil) throws -> Data {
        view.layoutSubtreeIfNeeded()
        view.displayIfNeeded()
        let source = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: source)
        guard let background else {
            return try XCTUnwrap(source.representation(using: .png, properties: [:]))
        }
        let image = NSImage(size: view.bounds.size)
        image.lockFocus()
        background.setFill()
        NSRect(origin: .zero, size: view.bounds.size).fill()
        let overlay = NSImage(size: view.bounds.size)
        overlay.addRepresentation(source)
        overlay.draw(in: NSRect(origin: .zero, size: view.bounds.size))
        image.unlockFocus()
        let tiff = try XCTUnwrap(image.tiffRepresentation)
        let output = try XCTUnwrap(NSBitmapImageRep(data: tiff))
        return try XCTUnwrap(output.representation(using: .png, properties: [:]))
    }

    func testGenerateReadmeImages() throws {
        guard let path = ProcessInfo.processInfo.environment["VOICETYPE_README_IMAGE_DIR"], !path.isEmpty else {
            throw XCTSkip("Set VOICETYPE_README_IMAGE_DIR to render demo screenshots.")
        }
        XCTAssertTrue(Thread.isMainThread)
        _ = NSApplication.shared
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let original = ConfigManager.shared.config
        defer { ConfigManager.shared.update { $0 = original } }
        ConfigManager.shared.update { $0 = .defaultConfig }

        let controller = SettingsWindowController.shared
        controller.selectTab(index: 0)
        let window = try XCTUnwrap(controller.window)
        window.appearance = NSAppearance(named: .darkAqua)
        let frame = try XCTUnwrap(window.contentView?.superview)
        try png(of: frame).write(to: directory.appendingPathComponent("ayarlar.png"))

        let hud = RecordingHUD.shared
        let background = NSColor(calibratedRed: 0.14, green: 0.18, blue: 0.27, alpha: 1)
        for (style, name) in [("notch", "notch-view.png"), ("pill", "kapsul-view.png")] {
            ConfigManager.shared.update { $0.hud_style = style }
            hud.dismiss(animated: false)
            hud.finishPresentationTransitions()
            hud.showRecording()
            hud.finishPresentationTransitions()
            hud.updateInterimText("Merhaba, nasılsın?")
            let root = try XCTUnwrap(hud.rootContentView)
            if style == "notch" {
                let wave = try XCTUnwrap(descendants(of: root).compactMap { $0 as? NotchWaveView }.first)
                wave.render(level: 0.7, mode: .listening, animated: false)
            }
            try png(of: root, background: background).write(to: directory.appendingPathComponent(name))
            hud.dismiss(animated: false)
            hud.finishPresentationTransitions()
        }
    }
}
