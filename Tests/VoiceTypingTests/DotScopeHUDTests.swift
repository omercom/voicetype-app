import AppKit
import XCTest
@testable import VoiceTypingCore

final class DotScopeHUDTests: XCTestCase {
    func testHUDSpringConvergesAndFollowsTarget() {
        var spring = HUDSpring(at: 0.0)
        for _ in 0..<180 {
            spring.stepTo(1.0, spec: .morph, dt: 1.0 / 120.0)
        }
        XCTAssertEqual(spring.x, 1.0, accuracy: 1e-2)
        XCTAssertEqual(spring.target, 1.0)
    }

    func testDotScopeSimulationTransitionsAndPalettes() {
        let sim = DotScopeSimulation(tuning: .compactDefault)
        sim.restart(reduceMotion: false)
        for _ in 0..<50 {
            sim.advance(dt: 1.0 / 120.0, stage: .recording, visible: true, loudnessDB: -18.0, reduceMotion: false)
        }
        let recPose = sim.pose()
        XCTAssertGreaterThan(recPose.opacity, 0.5)
        XCTAssertGreaterThan(recPose.live, 0.5)
        XCTAssertEqual(sim.dots.count, DotScopeTuning.compactDefault.columns * DotScopeTuning.compactDefault.rows)
        XCTAssertFalse(sim.dots.contains { !$0.x.isFinite || !$0.y.isFinite })

        var tuning = sim.tuning
        tuning.processingStyle = .sweep
        sim.updateTuning(tuning)
        sim.accentMode = .translation
        for _ in 0..<50 {
            sim.advance(dt: 1.0 / 120.0, stage: .processing, visible: true, loudnessDB: -120.0, reduceMotion: false)
        }
        let procPose = sim.pose()
        XCTAssertGreaterThan(procPose.cool, 0.5)
        XCTAssertGreaterThan(procPose.palette.base.z, 0.5)

        sim.advance(dt: 0.1, stage: .done, visible: true, loudnessDB: -120.0, reduceMotion: false)
        XCTAssertGreaterThan(sim.pose().rippleIntensity, 0.0)
    }

    func testDemoLoudnessIsBounded() {
        for step in stride(from: Float(0.0), through: Float(3.0), by: 0.05) {
            let db = DotScopeSimulation.demoLoudness(at: step)
            XCTAssertTrue(db.isFinite)
            XCTAssertLessThanOrEqual(db, -6.0)
            XCTAssertGreaterThanOrEqual(db, -65.0)
        }
    }

    func testDotScopeViewDrawsVisiblePixelsInCompactAndDotsOnlyModes() throws {
        for dotsOnly in [false, true] {
            let size = dotsOnly ? NSSize(width: 34, height: 22) : NSSize(width: 132, height: 38)
            let view = DotScopeView(frame: NSRect(origin: .zero, size: size),
                                    tuning: dotsOnly ? DotScopeTuning(columns: 15, rows: 7, spacing: 2.1, recordingWidth: 34, processingWidth: 34, height: 22) : .compactDefault,
                                    dotsOnly: dotsOnly)
            view.setStage(.recording)
            view.pushAudioLevel(dBFS: -14.0)
            for _ in 0..<12 {
                view.step(dt: 1.0 / 60.0, visible: true, reduceMotion: false)
            }
            let rep = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: rep)

            var litPixels = 0
            for y in 0..<rep.pixelsHigh {
                for x in 0..<rep.pixelsWide {
                    if let color = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB),
                       color.alphaComponent > 0.15 {
                        litPixels += 1
                    }
                }
            }
            XCTAssertGreaterThan(litPixels, 20, "dotsOnly=\(dotsOnly) görünür piksel üretmeli")
        }
    }

    func testHUDPlacementAndConfigDefaultsCompatibility() throws {
        XCTAssertEqual(HUDPlacement.resolve("pill"), .pill)
        XCTAssertEqual(HUDPlacement.resolve("notch"), .notch)
        XCTAssertEqual(HUDPlacement.resolve("compact"), .compact)
        XCTAssertEqual(HUDPlacement.resolve("hex"), .compact)
        XCTAssertEqual(HUDPlacement.resolve("HEX"), .compact)

        XCTAssertEqual(AppConfig.defaultConfig.hud_style, "pill")
        XCTAssertEqual(AppConfig.defaultConfig.hud_processing_effect, "flow")
        XCTAssertTrue(AppConfig.defaultConfig.enable_repaste_shortcut)

        // Eski config JSON'larında yeni anahtarlar olmasa da sorunsuz decode edilmeli
        let legacyJSON = """
        {"provider":"apple","hud_style":"pill"}
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(AppConfig.self, from: legacyJSON)
        XCTAssertEqual(decoded.hud_style, "pill")
        XCTAssertEqual(decoded.hud_processing_effect, "flow")
        XCTAssertTrue(decoded.enable_repaste_shortcut)
    }

    func testNotchShapeRimGlowDoesNotBleedOntoTopBezelEdge() throws {
        let view = NotchShapeView(frame: NSRect(x: 0, y: 0, width: 400, height: 76))
        view.fillColor = NSColor(calibratedWhite: 0.0, alpha: 1.0)
        view.rimGlowColor = NSColor(calibratedRed: 1.0, green: 0.82, blue: 0.40, alpha: 1.0)
        view.rimGlowIntensity = 0.9

        let rep = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep)

        // Üst merkez çerçeve kenarı (çentik kamerasının birleştiği yer) tamamen siyah kalmalı
        let topMid = try XCTUnwrap(rep.colorAt(x: rep.pixelsWide / 2, y: 1)?.usingColorSpace(.sRGB))
        XCTAssertLessThan(topMid.brightnessComponent, 0.02)

        // Alt kenarda (AppKit koordinatında bottom -> bitmap altında veya üstünde) belirgin taşma olmamalı ve ortası koyu kalmalı
        let center = try XCTUnwrap(rep.colorAt(x: rep.pixelsWide / 2, y: rep.pixelsHigh / 2)?.usingColorSpace(.sRGB))
        XCTAssertLessThan(center.brightnessComponent, 0.03)
    }

    func testNotchTwoTierRecordingAndInterimTransitions() {
        let original = ConfigManager.shared.config.hud_style
        ConfigManager.shared.update { $0.hud_style = "notch" }
        defer { ConfigManager.shared.update { $0.hud_style = original } }

        let hud = RecordingHUD.shared
        hud.dismiss(animated: false)
        hud.showPreparing()
        hud.finishPresentationTransitions()
        XCTAssertTrue(hud.isVisible)

        hud.showRecording()
        hud.finishPresentationTransitions()
        let compactSize = hud.rootContentView?.bounds.size ?? .zero
        XCTAssertGreaterThan(compactSize.width, 280)
        XCTAssertGreaterThan(compactSize.height, 34)

        hud.updateInterimText("Merhaba, bu bir test diktesidir")
        hud.finishPresentationTransitions()
        let expandedSize = hud.rootContentView?.bounds.size ?? .zero
        XCTAssertGreaterThanOrEqual(expandedSize.width, compactSize.width)
        XCTAssertGreaterThanOrEqual(expandedSize.height, compactSize.height)

        hud.dismiss(animated: false)
    }
}
