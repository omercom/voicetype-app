import Foundation
import XCTest
@testable import VoiceTypingCore

final class RecoveryStorageSafetyTests: XCTestCase {
    private func mode(_ url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return try XCTUnwrap(attributes[.posixPermissions] as? NSNumber).intValue & 0o777
    }

    func testRecoveryFilesAndNewDirectoryArePrivate() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("VoiceTypingRecoverySafety-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = DictationRecoveryAudioStore(customDirectoryURL: directory)
        let audio = Data(repeating: 42, count: 128)
        XCTAssertTrue(store.saveLastRecording(wavData: audio))
        XCTAssertTrue(store.hasRecovery())
        XCTAssertTrue(store.markFailed(error: "test"))
        XCTAssertTrue(store.hasFailedRecovery())
        XCTAssertEqual(store.getLatestAudioData(), audio)
        XCTAssertEqual(try mode(directory), 0o700)
        XCTAssertEqual(try mode(directory.appendingPathComponent("latest_recovery.wav")), 0o600)
        XCTAssertEqual(try mode(directory.appendingPathComponent("latest_recovery.json")), 0o600)
    }

    func testExistingCallerDirectoryPermissionsAreNotChanged() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("VoiceTypingRecoveryExisting-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path)
        let store = DictationRecoveryAudioStore(customDirectoryURL: directory)
        XCTAssertTrue(store.saveLastRecording(wavData: Data(repeating: 1, count: 50)))
        XCTAssertEqual(try mode(directory), 0o755)
        XCTAssertEqual(try mode(directory.appendingPathComponent("latest_recovery.wav")), 0o600)
    }

    func testRecoveryStatusUsesFileSizeAndRejectsShortRecordings() {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("VoiceTypingRecoverySize-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = DictationRecoveryAudioStore(customDirectoryURL: directory)
        XCTAssertFalse(store.hasRecovery())
        XCTAssertTrue(store.saveLastRecording(wavData: Data(count: 44)))
        XCTAssertFalse(store.hasRecovery())
        XCTAssertTrue(store.saveLastRecording(wavData: Data(count: 45)))
        XCTAssertTrue(store.hasRecovery())
        store.clear()
        XCTAssertFalse(store.hasRecovery())
    }

    func testOverlappingRecordingsKeepFailedOlderAudioWhenNewerSucceeds() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("VoiceTypingRecoveryConcurrent-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = DictationRecoveryAudioStore(customDirectoryURL: directory)
        let first = Data(repeating: 1, count: 128)
        let second = Data(repeating: 2, count: 256)
        let firstID = try XCTUnwrap(store.saveRecording(wavData: first))
        let secondID = try XCTUnwrap(store.saveRecording(wavData: second))
        XCTAssertNotEqual(firstID, secondID)
        XCTAssertTrue(store.markFailed(error: "unverified", recordingID: firstID))
        XCTAssertTrue(store.hasFailedRecovery())
        XCTAssertEqual(store.getLatestAudioData(), second)
        store.clear(recordingID: secondID)
        XCTAssertTrue(store.hasRecovery())
        XCTAssertEqual(store.getLatestAudioData(), first)
        XCTAssertTrue(store.hasFailedRecovery())
        XCTAssertEqual(try mode(directory.appendingPathComponent("recovery_\(firstID.uuidString).wav")), 0o600)
        XCTAssertEqual(try mode(directory.appendingPathComponent("recovery_\(firstID.uuidString).json")), 0o600)
    }

    func testOlderSuccessCannotDeleteOrMarkNewerRecording() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("VoiceTypingRecoveryOrdering-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = DictationRecoveryAudioStore(customDirectoryURL: directory)
        let firstID = try XCTUnwrap(store.saveRecording(wavData: Data(repeating: 1, count: 128)))
        let second = Data(repeating: 2, count: 256)
        let secondID = try XCTUnwrap(store.saveRecording(wavData: second))
        store.clear(recordingID: firstID)
        XCTAssertFalse(store.markFailed(error: "late", recordingID: firstID))
        XCTAssertEqual(store.getLatestAudioData(), second)
        XCTAssertFalse(store.hasFailedRecovery())
        XCTAssertTrue(store.markFailed(error: "second", recordingID: secondID))
        XCTAssertEqual(store.getLatestAudioData(), second)
    }

    func testLegacyRecoverySurvivesNewRecordingAndNilIdentifier() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("VoiceTypingRecoveryLegacy-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = DictationRecoveryAudioStore(customDirectoryURL: directory)
        let legacy = Data(repeating: 3, count: 128)
        XCTAssertTrue(store.saveLastRecording(wavData: legacy))
        XCTAssertTrue(store.markFailed(error: "legacy"))
        let newID = try XCTUnwrap(store.saveRecording(wavData: Data(repeating: 4, count: 128)))
        XCTAssertFalse(store.markFailed(error: "wrong", recordingID: nil))
        store.clear(recordingID: nil)
        store.clear(recordingID: newID)
        XCTAssertTrue(store.hasFailedRecovery())
        XCTAssertEqual(store.getLatestAudioData(), legacy)
    }

    func testExportSelectsUnusedNameWithoutReplacingExistingFiles() {
        let directory = URL(fileURLWithPath: "/test")
        let existing: Set<String> = ["ses.wav", "ses_2.wav"]
        let destination = DictationRecoveryAudioStore.availableExportURL(in: directory, baseName: "ses") {
            existing.contains($0.lastPathComponent)
        }
        XCTAssertEqual(destination.lastPathComponent, "ses_3.wav")
    }
}
