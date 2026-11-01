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
        let snapshot = folder.appendingPathComponent("models/models--atasoglu--seda-v0.2/snapshots/\(SedaTranscriber.revision)")
        XCTAssertFalse(SedaTranscriber.isInstalled(runtimeURL: folder, workerURL: worker))

        func writeMarker(model: String, revision: String) throws {
            let data = try JSONSerialization.data(withJSONObject: ["model": model, "revision": revision])
            try data.write(to: ready)
        }
        try makeFile(python, executable: true)
        try makeFile(ready)
        try makeFile(worker)
        for name in SedaTranscriber.requiredModelFiles {
            try makeFile(snapshot.appendingPathComponent(name))
        }
        XCTAssertFalse(SedaTranscriber.isInstalled(runtimeURL: folder, workerURL: worker), "Bozuk işaretçi kabul edilmemeli")
        try writeMarker(model: "atasoglu/seda-v0.1", revision: SedaTranscriber.revision)
        XCTAssertFalse(SedaTranscriber.isInstalled(runtimeURL: folder, workerURL: worker), "Eski model kabul edilmemeli")
        try writeMarker(model: SedaTranscriber.model, revision: "old-revision")
        XCTAssertFalse(SedaTranscriber.isInstalled(runtimeURL: folder, workerURL: worker), "Yanlış sürüm kabul edilmemeli")
        try writeMarker(model: SedaTranscriber.model, revision: SedaTranscriber.revision)
        XCTAssertTrue(SedaTranscriber.isInstalled(runtimeURL: folder, workerURL: worker))

        for name in SedaTranscriber.requiredModelFiles {
            let file = snapshot.appendingPathComponent(name)
            try FileManager.default.removeItem(at: file)
            XCTAssertFalse(SedaTranscriber.isInstalled(runtimeURL: folder, workerURL: worker), name)
            try makeFile(file)
        }
        try FileManager.default.removeItem(at: ready)
        XCTAssertFalse(SedaTranscriber.isInstalled(runtimeURL: folder, workerURL: worker))
        try writeMarker(model: SedaTranscriber.model, revision: SedaTranscriber.revision)
        XCTAssertFalse(SedaTranscriber.isInstalled(runtimeURL: folder, workerURL: nil))
        try FileManager.default.removeItem(at: worker)
        XCTAssertFalse(SedaTranscriber.isInstalled(runtimeURL: folder, workerURL: worker))
        try makeFile(worker)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: python.path)
        XCTAssertFalse(SedaTranscriber.isInstalled(runtimeURL: folder, workerURL: worker))
    }

    func testWorkerMatchesSelectedModelAndVersion() throws {
        let url = try XCTUnwrap(VoiceTypeResources.url(forResource: "seda_worker", withExtension: "py"))
        let source = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(source.contains("MODEL_REPO = \"\(SedaTranscriber.model)\""))
        XCTAssertTrue(source.contains("MODEL_REVISION = \"\(SedaTranscriber.revision)\""))
        XCTAssertTrue(source.contains("TAIL_PADDING_SAMPLES = 24_000"))
        XCTAssertEqual(SedaTranscriber.runtimeURL.lastPathComponent, "seda-v0.2")
    }

    func testMenuItemUpdatesWhenInstallationChanges() {
        let item = NSMenuItem(title: "Seda-v0.2", action: nil, keyEquivalent: "")
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
        XCTAssertFalse(labels().contains("Seda-v0.2"))
        installed = true
        controller.loadValues()
        XCTAssertTrue(labels().contains("Seda-v0.2"))
        installed = false
        controller.loadValues()
        XCTAssertFalse(labels().contains("Seda-v0.2"))
    }
}
