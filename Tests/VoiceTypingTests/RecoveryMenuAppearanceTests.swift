import AppKit
import XCTest
@testable import VoiceTypingCore

final class RecoveryMenuAppearanceTests: XCTestCase {
    func testRecoveryActionAlwaysUsesSaveDiskIcon() {
        let item = NSMenuItem(title: "⚠️ Son Sesi Masaüstüne Kaydet", action: nil, keyEquivalent: "")
        AppDelegate.updateRecoveryMenu(item, hasRecovery: true)
        XCTAssertFalse(item.isHidden)
        XCTAssertEqual(item.title, "💾 Son Sesi Masaüstüne Kaydet")

        AppDelegate.updateRecoveryMenu(item, hasRecovery: false)
        XCTAssertTrue(item.isHidden)
        XCTAssertEqual(item.title, "💾 Son Sesi Masaüstüne Kaydet")

        AppDelegate.updateRecoveryMenu(item, hasRecovery: true)
        XCTAssertFalse(item.isHidden)
        XCTAssertEqual(item.title, "💾 Son Sesi Masaüstüne Kaydet")
    }
}
