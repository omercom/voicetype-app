import XCTest
import AppKit
@testable import VoiceTypingCore

final class HUDTransitionTests: XCTestCase {
    func testWaveformRespondsToQuietSpeechAndClampsInvalidPower() {
        XCTAssertEqual(RecordingHUD.waveformLevel(power: -80), 0)
        XCTAssertGreaterThan(RecordingHUD.waveformLevel(power: -52), 0.15)
        XCTAssertGreaterThan(RecordingHUD.waveformLevel(power: -30), RecordingHUD.waveformLevel(power: -52))
        XCTAssertEqual(RecordingHUD.waveformLevel(power: 0), 1)
        XCTAssertEqual(RecordingHUD.waveformLevel(power: .nan), 0)
    }

    func testReducedMotionAudioFeedbackRemainsReactiveAndClamped() {
        XCTAssertEqual(RecordingHUD.reducedMotionAudioOpacity(level: 0), 0.45, accuracy: 0.001)
        XCTAssertGreaterThan(RecordingHUD.reducedMotionAudioOpacity(level: 0.5),
                             RecordingHUD.reducedMotionAudioOpacity(level: 0))
        XCTAssertEqual(RecordingHUD.reducedMotionAudioOpacity(level: 1), 1)
        XCTAssertEqual(RecordingHUD.reducedMotionAudioOpacity(level: 2), 1)
        XCTAssertEqual(RecordingHUD.reducedMotionAudioOpacity(level: -1), 0.45, accuracy: 0.001)
    }
    func testFramesAndOpacityHaveRealIntermediateValues() {
        var now: TimeInterval = 10
        let transition = HUDTransition(schedulesTimer: false, clock: { now })
        var width = 152.0
        var alpha = 0.0
        transition.start(duration: 0.2) { progress in
            width = 152 + 32 * progress
            alpha = progress
        }
        XCTAssertEqual(width, 152)
        now = 10.1
        transition.advance()
        XCTAssertEqual(width, 168, accuracy: 0.001)
        XCTAssertEqual(alpha, 0.5, accuracy: 0.001)
        now = 10.2
        transition.advance()
        transition.finish()
        XCTAssertEqual(width, 184)
        XCTAssertEqual(alpha, 1)
        XCTAssertFalse(transition.isActive)
    }

    func testDismissRevealDismissDiscardsBothObsoleteCompletions() {
        var now: TimeInterval = 0
        let transition = HUDTransition(schedulesTimer: false, clock: { now })
        var alpha = 1.0
        var completions: [String] = []
        transition.start(duration: 1, update: { alpha = 1 - $0 }, completion: { completions.append("old dismiss") })
        now = 0.5
        transition.advance()
        let partialAlpha = alpha
        transition.start(duration: 1, update: { alpha = partialAlpha + (1 - partialAlpha) * $0 }, completion: { completions.append("reveal") })
        XCTAssertEqual(alpha, partialAlpha, "Retrigger must not snap to a stale target")
        now = 0.75
        transition.advance()
        XCTAssertGreaterThan(alpha, partialAlpha)
        let visibleAlpha = alpha
        transition.start(duration: 1, update: { alpha = visibleAlpha * (1 - $0) }, completion: { completions.append("latest dismiss") })
        now = 2
        transition.advance()
        transition.advance()
        XCTAssertEqual(alpha, 0)
        XCTAssertEqual(completions, ["latest dismiss"])
    }

    func testReduceMotionAndFinishingInFlightAreImmediateAndCompleteOnce() {
        let transition = HUDTransition(schedulesTimer: false, clock: { 0 })
        var samples: [Double] = []
        var completions = 0
        transition.start(duration: 0, update: { samples.append($0) }, completion: { completions += 1 })
        XCTAssertEqual(samples, [1])
        XCTAssertFalse(transition.isActive)
        transition.start(duration: 1, update: { samples.append($0) }, completion: { completions += 1 })
        transition.finish()
        transition.finish()
        XCTAssertEqual(samples, [1, 0, 1])
        XCTAssertEqual(completions, 2)
    }

    func testHUDRetriggerCannotRunAnObsoleteDismissCompletion() {
        let hud = RecordingHUD.shared
        hud.dismiss(animated: false)
        defer { hud.dismiss(animated: false) }
        hud.showNotice(message: "Demo", autoDismissDelay: 60)
        hud.finishPresentationTransitions()
        var obsoleteCompletion = false
        hud.dismiss(animated: true) { obsoleteCompletion = true }
        // Reduce Motion completes synchronously, before any retrigger exists.
        let completedSynchronously = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        hud.showNotice(message: "Yeni demo", autoDismissDelay: 60)
        hud.finishPresentationTransitions()
        XCTAssertEqual(obsoleteCompletion, completedSynchronously)
        XCTAssertEqual(hud.currentState, .notice("Yeni demo"))
        XCTAssertTrue(hud.isVisible)
        var latestCompletion = false
        hud.dismiss(animated: true) { latestCompletion = true }
        hud.finishPresentationTransitions()
        XCTAssertTrue(latestCompletion)
        XCTAssertEqual(obsoleteCompletion, completedSynchronously)
        XCTAssertFalse(hud.isVisible)
    }

    func testOffscreenFixedDemoPreview() throws {
        let data = try XCTUnwrap(RecordingHUD.demoPreviewPNG())
        XCTAssertEqual(Array(data.prefix(8)), [137, 80, 78, 71, 13, 10, 26, 10])
        if let path = ProcessInfo.processInfo.environment["VOICETYPING_HUD_PREVIEW_PATH"] {
            try data.write(to: URL(fileURLWithPath: path))
        }
    }

    func testCancelNeverUpdatesOrCompletesLater() {
        var now = 0.0
        let transition = HUDTransition(schedulesTimer: false, clock: { now })
        var samples: [Double] = []
        transition.start(duration: 1, update: { samples.append($0) }, completion: { XCTFail("Cancelled completion") })
        transition.cancel()
        now = 2
        transition.advance()
        transition.finish()
        XCTAssertEqual(samples, [0])
    }

    func testNewBadgeEntersAtTrailingEdgeInsteadOfCrossingMeter() {
        let target = CGRect(x: 150, y: 5, width: 24, height: 24)
        let entry = RecordingHUDLayout.badgeEntryFrame(target: target, panelWidth: 152)
        XCTAssertEqual(entry, CGRect(x: 118, y: 5, width: 24, height: 24))
        XCTAssertEqual(entry.maxX, 142)
        XCTAssertGreaterThan(entry.minX, 46)
        XCTAssertEqual(RecordingHUDLayout.badgeEntryFrame(target: target, panelWidth: 184), target)
    }

    func testCompactBadgeAndStatusStaySeparatedAcrossScreenWidths() {
        for screenWidth in stride(from: 190, through: 1600, by: 10) {
            for textWidth in [0.0, 70, 300, 900] {
                let layout = RecordingHUDLayout.calculate(statusTextWidth: textWidth, warningTextWidth: 24, availableScreenWidth: CGFloat(screenWidth))
                let badge = try! XCTUnwrap(layout.warningFrame)
                XCTAssertEqual(badge.width, 24)
                XCTAssertLessThanOrEqual(layout.statusFrame.maxX + 8, badge.minX)
                XCTAssertLessThanOrEqual(badge.maxX + 10, layout.panelWidth)
                XCTAssertLessThanOrEqual(layout.panelWidth, CGFloat(screenWidth) - 32)
            }
        }
    }
}
