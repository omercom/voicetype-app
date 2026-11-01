import XCTest
import AppKit
@testable import VoiceTypingCore

final class TargetFocusSettingsTests: XCTestCase {
    func testOldConfigurationDefaultsToRestoringTheOriginalTarget() throws {
        let config = try JSONDecoder().decode(AppConfig.self, from: Data("{}".utf8))
        XCTAssertTrue(config.restore_target_focus)
        XCTAssertTrue(AppConfig.defaultConfig.restore_target_focus)
    }

    func testBothPoliciesSurviveConfigurationRoundTrip() throws {
        for restore in [true, false] {
            var config = AppConfig.defaultConfig
            config.restore_target_focus = restore
            let encoded = try JSONEncoder().encode(config)
            let decoded = try JSONDecoder().decode(AppConfig.self, from: encoded)
            XCTAssertEqual(decoded.restore_target_focus, restore)
        }
    }

    func testSettingsOffersBothChoicesAndLoadsCurrentPolicy() {
        XCTAssertTrue(Thread.isMainThread)
        let controller = SettingsWindowController.shared
        let picker = controller.targetFocusPopUp!
        XCTAssertEqual(picker.itemTitles, ["Hedef: İlk alana dön", "Hedef değişirse uyar"])
        XCTAssertEqual(picker.indexOfSelectedItem, ConfigManager.shared.config.restore_target_focus ? 0 : 1)
        XCTAssertEqual(picker.action, NSSelectorFromString("targetFocusChanged:"))
        XCTAssertTrue(picker.target === controller)
        XCTAssertNotNil(picker.superview)
        XCTAssertGreaterThanOrEqual(picker.frame.minX, 0)
        XCTAssertLessThanOrEqual(picker.frame.maxX, picker.superview!.bounds.maxX)
    }
}
