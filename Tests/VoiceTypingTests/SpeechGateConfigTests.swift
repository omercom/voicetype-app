import XCTest
@testable import VoiceTypingCore

/// `vad_*` ayarlarının kapıya gerçekten aktarıldığını ve geçersiz değerlerin
/// güvenli aralığa çekildiğini doğrular.
final class SpeechGateConfigTests: XCTestCase {

    private func makeConfig() throws -> AppConfig {
        AppConfig.defaultConfig
    }

    func testGateUsesConfiguredVADValues() throws {
        var config = try makeConfig()
        config.vad_gate_db = -50
        config.vad_stay_ratio = 0.7
        config.vad_silence_hold_sec = 0.8
        config.vad_max_segment_sec = 12

        let gate = SpeechGate(config: config, initialNoiseFloorDB: -75)
        XCTAssertEqual(gate.gateFloorDB, -50, accuracy: 0.001)
        XCTAssertEqual(gate.stayRatio, 0.7, accuracy: 0.001)
        XCTAssertEqual(gate.silenceHoldSeconds, 0.8, accuracy: 0.001)
        XCTAssertEqual(gate.maxSegmentSeconds, 12, accuracy: 0.001)
        XCTAssertEqual(gate.noiseFloorDB, -75, accuracy: 0.001)
    }

    func testDefaultConfigMatchesBuiltInDefaults() throws {
        let gate = SpeechGate(config: try makeConfig())
        XCTAssertEqual(gate.gateFloorDB, SpeechGate.defaultGateFloorDB, accuracy: 0.001)
        XCTAssertEqual(gate.stayRatio, SpeechGate.defaultStayRatio, accuracy: 0.001)
        XCTAssertEqual(gate.silenceHoldSeconds, SpeechGate.defaultSilenceHoldSeconds, accuracy: 0.001)
        XCTAssertEqual(gate.maxSegmentSeconds, SpeechGate.defaultMaxSegmentSeconds, accuracy: 0.001)
    }

    func testGateClampsInvalidConfigValues() throws {
        var config = try makeConfig()
        config.vad_gate_db = 10
        config.vad_stay_ratio = 0
        config.vad_silence_hold_sec = -1
        config.vad_max_segment_sec = .infinity

        let gate = SpeechGate(config: config)
        XCTAssertEqual(gate.gateFloorDB, -20, accuracy: 0.001)
        XCTAssertEqual(gate.stayRatio, 0.05, accuracy: 0.001)
        XCTAssertEqual(gate.silenceHoldSeconds, 0.1, accuracy: 0.001)
        XCTAssertEqual(gate.maxSegmentSeconds, SpeechGate.defaultMaxSegmentSeconds, accuracy: 0.001)
    }
}
