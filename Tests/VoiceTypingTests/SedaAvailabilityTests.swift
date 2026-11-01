import XCTest
import AppKit
@testable import VoiceTypingCore

final class SedaAvailabilityTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: folder)
    }

    private func makeFile(_ url: URL, executable: Bool = false) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("fixture".utf8).write(to: url)
        if executable {
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        }
    }

    func testInstallationRequiresRuntimeMarkerModelFilesAndWorker() throws {
        let python = folder.appendingPathComponent(".venv/bin/python")
        let ready = folder.appendingPathComponent("ready.json")
        let worker = folder.appendingPathComponent("seda_worker.py")
        let snapshot = folder.appendingPathComponent("models/models--atasoglu--seda-v0.1/snapshots/\(SedaTranscriber.revision)")
        XCTAssertFalse(SedaTranscriber.isInstalled(runtimeURL: folder, workerURL: worker))

        try makeFile(python, executable: true)
        try makeFile(ready)
        try makeFile(worker)
        for name in SedaTranscriber.requiredModelFiles {
            try makeFile(snapshot.appendingPathComponent(name))
        }
        XCTAssertTrue(SedaTranscriber.isInstalled(runtimeURL: folder, workerURL: worker))

        for name in SedaTranscriber.requiredModelFiles {
            let file = snapshot.appendingPathComponent(name)
            try FileManager.default.removeItem(at: file)
            XCTAssertFalse(SedaTranscriber.isInstalled(runtimeURL: folder, workerURL: worker), name)
            try makeFile(file)
        }
        try FileManager.default.removeItem(at: ready)
        XCTAssertFalse(SedaTranscriber.isInstalled(runtimeURL: folder, workerURL: worker))
        try makeFile(ready)
        XCTAssertFalse(SedaTranscriber.isInstalled(runtimeURL: folder, workerURL: nil))
        try FileManager.default.removeItem(at: worker)
        XCTAssertFalse(SedaTranscriber.isInstalled(runtimeURL: folder, workerURL: worker))
        try makeFile(worker)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: python.path)
        XCTAssertFalse(SedaTranscriber.isInstalled(runtimeURL: folder, workerURL: worker))
    }

    func testMenuItemUpdatesWhenInstallationChanges() {
        let item = NSMenuItem(title: "Seda-v0.1", action: nil, keyEquivalent: "")
        AppDelegate.updateSedaMenuItem(item, installed: false, activeProvider: "apple")
        XCTAssertTrue(item.isHidden)
        XCTAssertEqual(item.state, .off)

        AppDelegate.updateSedaMenuItem(item, installed: true, activeProvider: "seda")
        XCTAssertFalse(item.isHidden)
        XCTAssertEqual(item.state, .on)

        AppDelegate.updateSedaMenuItem(item, installed: false, activeProvider: "seda")
        XCTAssertTrue(item.isHidden)
        XCTAssertEqual(item.state, .on)
    }

    func testProviderListsPreserveOrderAndUnavailableSelection() {
        let withoutSeda = TranscriptionProviderRegistry.selectable(sedaInstalled: false)
        let withSeda = TranscriptionProviderRegistry.selectable(sedaInstalled: true)
        XCTAssertEqual(withSeda.map(\.id), TranscriptionProviderRegistry.all.map(\.id))
        XCTAssertEqual(withoutSeda.map(\.id), withSeda.map(\.id).filter { $0 != "seda" })
        XCTAssertEqual(TranscriptionProviderRegistry.selectedID(at: -1, in: withoutSeda, preserving: "seda"), "seda")
        XCTAssertEqual(TranscriptionProviderRegistry.selectedID(at: 0, in: withoutSeda, preserving: "seda"), "apple")
    }

    func testSettingsRefreshesTheVisibleProviderList() throws {
        let controller = SettingsWindowController.shared
        let originalCheck = controller.sedaInstallationCheck
        defer {
            controller.sedaInstallationCheck = originalCheck
            controller.loadValues()
        }
        var installed = false
        controller.sedaInstallationCheck = { installed }
        controller.loadValues()
        controller.selectTab(index: 1)

        func descendants(_ view: NSView) -> [NSView] {
            [view] + view.subviews.flatMap { descendants($0) }
        }
        let root = try XCTUnwrap(controller.window?.contentView)
        let control = try XCTUnwrap(descendants(root).compactMap { $0 as? NSSegmentedControl }.first { control in
            (0..<control.segmentCount).contains { control.label(forSegment: $0) == "Apple Speech" }
                && (0..<control.segmentCount).contains { control.label(forSegment: $0) == "Gemini" }
        })
        func labels() -> [String] {
            (0..<control.segmentCount).compactMap { control.label(forSegment: $0) }
        }
        XCTAssertFalse(labels().contains("Seda-v0.1"))
        installed = true
        controller.loadValues()
        XCTAssertTrue(labels().contains("Seda-v0.1"))
        installed = false
        controller.loadValues()
        XCTAssertFalse(labels().contains("Seda-v0.1"))
    }
}
