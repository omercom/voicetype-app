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

    private var projectRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
    }

    private func makeBundle(in directory: URL, version: String?) throws -> Bundle {
        let bundleURL = directory.appendingPathComponent("VersionTest.bundle", isDirectory: true)
        let contents = bundleURL.appendingPathComponent("Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        var info: [String: Any] = ["CFBundleIdentifier": "org.example.version-test.\(UUID().uuidString)",
                                   "CFBundlePackageType": "BNDL"]
        if let version { info["CFBundleShortVersionString"] = version }
        let data = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        try data.write(to: contents.appendingPathComponent("Info.plist"))
        return try XCTUnwrap(Bundle(url: bundleURL))
    }

    func testAboutVersionUsesBundledVersionInsteadOfFallback() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("VoiceTypingAboutVersion-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let bundle = try makeBundle(in: directory, version: "3.4.5")
        let text = SettingsWindowController.aboutVersionText(
            bundle: bundle, fallbackInfoPlistURL: projectRoot.appendingPathComponent("Info.plist")
        )
        XCTAssertEqual(text, "Sürüm 3.4.5 • Native macOS • Apple Silicon & Intel")
    }

    func testAboutVersionUsesProjectVersionForUnbundledBuilds() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("VoiceTypingAboutFallback-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let bundle = try makeBundle(in: directory, version: nil)
        let infoURL = projectRoot.appendingPathComponent("Info.plist")
        let data = try Data(contentsOf: infoURL)
        let info = try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        let version = try XCTUnwrap(info["CFBundleShortVersionString"] as? String)
        XCTAssertNotNil(version.range(of: #"^[0-9]+\.[0-9]+\.[0-9]+$"#, options: .regularExpression))
        XCTAssertEqual(SettingsWindowController.aboutVersionText(bundle: bundle, fallbackInfoPlistURL: infoURL),
                       "Sürüm \(version) • Native macOS • Apple Silicon & Intel")
    }

    func testReadmeUsesGeneralSettingsImageWithoutAboutImage() throws {
        let readme = try String(contentsOf: projectRoot.appendingPathComponent("README.md"), encoding: .utf8)
        XCTAssertTrue(readme.contains("docs/images/ayarlar.png\" alt=\"VoiceType genel ayarlar ekranı"))
        XCTAssertFalse(readme.localizedCaseInsensitiveContains("docs/images/hakkinda"))
        XCTAssertFalse(readme.localizedCaseInsensitiveContains("docs/images/about"))
    }

    func testAboutFeaturesAndShortcutsFitTheirCards() throws {
        XCTAssertTrue(Thread.isMainThread)
        let content = try XCTUnwrap(SettingsWindowController.shared.window?.contentView)
        let tabs = try XCTUnwrap(descendants(of: content).compactMap { $0 as? NSTabView }.first)
        let about = try XCTUnwrap(tabs.tabViewItems.first { ($0.identifier as? String) == "tabAbout" }?.view)
        let labels = descendants(of: about).compactMap { $0 as? NSTextField }

        XCTAssertTrue(labels.contains { $0.stringValue == SettingsWindowController.aboutVersionText() })
        XCTAssertTrue(labels.contains { $0.stringValue.contains("Öne Çıkan Özellikler") })
        let features = try XCTUnwrap(labels.first { $0.stringValue.contains("Seda ile Türkçe") })
        XCTAssertTrue(features.stringValue.contains("Sağ Option"))
        XCTAssertTrue(features.stringValue.contains("Apple Speech"))
        XCTAssertFalse(features.stringValue.contains("Seslendir"))
        try assertTextFits(features)

        let tip = try XCTUnwrap(labels.first { $0.stringValue.contains("Varsayılan ayarda Sağ Command") })
        XCTAssertTrue(tip.stringValue.contains("Sağ Option"))
        try assertTextFits(tip)

        XCTAssertFalse(labels.contains { $0.stringValue.localizedCaseInsensitiveContains("Raycast") })
        XCTAssertFalse(labels.contains { $0.stringValue.contains("Start VoiceType Dictation") })

    }
}
