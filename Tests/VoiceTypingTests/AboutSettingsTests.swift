import AppKit
import XCTest
@testable import VoiceTypingCore

final class AboutSettingsTests: XCTestCase {
    private func descendants(of view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap { descendants(of: $0) }
    }

    private func assertTextFits(_ label: NSTextField, file: StaticString = #filePath, line: UInt = #line) throws {
        let font = try XCTUnwrap(label.font, file: file, line: line)
        let required = (label.stringValue as NSString).boundingRect(
            with: NSSize(width: label.bounds.width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: font]
        )
        XCTAssertLessThanOrEqual(ceil(required.height), label.bounds.height, file: file, line: line)
    }

    func testAboutFeaturesAndShortcutsFitTheirCards() throws {
        XCTAssertTrue(Thread.isMainThread)
        let content = try XCTUnwrap(SettingsWindowController.shared.window?.contentView)
        let tabs = try XCTUnwrap(descendants(of: content).compactMap { $0 as? NSTabView }.first)
        let about = try XCTUnwrap(tabs.tabViewItems.first { ($0.identifier as? String) == "tabAbout" }?.view)
        let labels = descendants(of: about).compactMap { $0 as? NSTextField }

        XCTAssertTrue(labels.contains { $0.stringValue.contains("Öne Çıkan Özellikler") })
        let features = try XCTUnwrap(labels.first { $0.stringValue.contains("Seda ile Türkçe") })
        XCTAssertTrue(features.stringValue.contains("Sağ Option"))
        XCTAssertTrue(features.stringValue.contains("Apple Speech"))
        XCTAssertFalse(features.stringValue.contains("Seslendir"))
        try assertTextFits(features)

        let tip = try XCTUnwrap(labels.first { $0.stringValue.contains("Varsayılan ayarda Sağ Command") })
        XCTAssertTrue(tip.stringValue.contains("Sağ Option"))
        try assertTextFits(tip)

        let raycast = try XCTUnwrap(labels.first { $0.stringValue.contains("Start VoiceType Dictation") })
        XCTAssertTrue(raycast.stringValue.contains("Stop VoiceType Dictation"))
        XCTAssertTrue(raycast.stringValue.contains("henüz gerçek kullanımda doğrulanmadı"))
        try assertTextFits(raycast)
    }
}
