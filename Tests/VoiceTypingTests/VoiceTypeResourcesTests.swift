import XCTest
@testable import VoiceTypingCore

final class VoiceTypeResourcesTests: XCTestCase {
    func testFindsWorkerInPackagedAppWithoutBuildDirectory() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let app = root.appendingPathComponent("VoiceTyping.app")
        let inner = app.appendingPathComponent("Contents/Resources/VoiceTyping_VoiceTypingCore.bundle")

        func makeBundle(_ url: URL, identifier: String, packageType: String) throws {
            let contents = url.appendingPathComponent("Contents")
            try FileManager.default.createDirectory(at: contents.appendingPathComponent("Resources"), withIntermediateDirectories: true)
            let info: [String: String] = [
                "CFBundleIdentifier": identifier,
                "CFBundleName": "VoiceType Resource Test",
                "CFBundlePackageType": packageType
            ]
            let data = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            try data.write(to: contents.appendingPathComponent("Info.plist"))
        }
        try makeBundle(app, identifier: "org.example.voicetype-resource-test", packageType: "APPL")
        try makeBundle(inner, identifier: "org.example.voicetype-core-test", packageType: "BNDL")
        let expected = inner.appendingPathComponent("Contents/Resources/seda_worker.py")
        try Data("fixture".utf8).write(to: expected)

        let bundle = try XCTUnwrap(Bundle(url: app))
        let found = VoiceTypeResources.url(forResource: "seda_worker", withExtension: "py", mainBundle: bundle)
        XCTAssertEqual(found?.standardizedFileURL, expected.standardizedFileURL)
        try FileManager.default.removeItem(at: expected)
        XCTAssertNil(VoiceTypeResources.url(forResource: "seda_worker", withExtension: "py", mainBundle: bundle))
        try FileManager.default.removeItem(at: inner)
        XCTAssertNil(VoiceTypeResources.url(forResource: "seda_worker", withExtension: "py", mainBundle: bundle))
    }

    func testFindsWorkerDuringSwiftPMTests() {
        XCTAssertNotNil(VoiceTypeResources.url(forResource: "seda_worker", withExtension: "py"))
    }
}
