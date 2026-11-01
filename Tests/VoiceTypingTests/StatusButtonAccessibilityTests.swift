import AppKit
import XCTest
@testable import VoiceTypingCore

final class StatusButtonAccessibilityTests: XCTestCase {
    func testShortcutHelpUpdatesWithoutLeavingATooltip() throws {
        XCTAssertTrue(Thread.isMainThread)
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        defer { NSStatusBar.system.removeStatusItem(item) }
        let button = try XCTUnwrap(item.button)
        var config = AppConfig.defaultConfig

        button.toolTip = "Eski açıklama"
        AppDelegate.updateStatusButtonAccessibility(button, config: config)
        XCTAssertNil(button.toolTip)
        XCTAssertEqual(button.accessibilityLabel(), "Voice Typing")
        XCTAssertEqual(button.accessibilityHelp(), "Sağ Cmd ile Sesle Yazma")

        config.enable_translation = true
        AppDelegate.updateStatusButtonAccessibility(button, config: config)
        XCTAssertNil(button.toolTip)
        XCTAssertEqual(button.accessibilityHelp(), "Sağ Cmd: Dikte · Sağ Option: Çeviri")

        config.trigger_key = 61
        AppDelegate.updateStatusButtonAccessibility(button, config: config)
        XCTAssertNil(button.toolTip)
        XCTAssertEqual(button.accessibilityHelp(), "Sağ Option: Çeviri · Normal dikte için başka tuş seçin")

        config.enable_translation = false
        AppDelegate.updateStatusButtonAccessibility(button, config: config)
        XCTAssertNil(button.toolTip)
        XCTAssertEqual(button.accessibilityHelp(), "Sağ Option ile Sesle Yazma")
    }
}
