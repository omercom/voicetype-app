import XCTest
@testable import VoiceTypingCore

final class DeliveryFeedbackTests: XCTestCase {
    func testUnverifiedDeliveryClosesHUDAndKeepsRecoveryStatus() {
        var events: [String] = []
        AppDelegate.presentUnverifiedDelivery(
            clipboardChanged: false, recoveryAvailable: true,
            dismissHUD: { events.append("dismiss") },
            showStatus: { events.append($0) }
        )
        XCTAssertEqual(events, ["dismiss", "Aktarım doğrulanamadı · Ses korundu"])
    }

    func testChangedClipboardIsReportedWithoutClaimingFailureOrSuccess() {
        var events: [String] = []
        AppDelegate.presentUnverifiedDelivery(
            clipboardChanged: true, recoveryAvailable: false,
            dismissHUD: { events.append("dismiss") },
            showStatus: { events.append($0) }
        )
        XCTAssertEqual(events, ["dismiss", "Aktarım doğrulanamadı · Pano değişti · Hedefi kontrol edin"])
    }
}
