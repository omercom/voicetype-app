import XCTest
@testable import VoiceTypingCore

/// SpeechGate: AlwaysWhisper'dan uyarlanan çift eşikli (hysteresis) VAD.
/// Tüm testler `now` değerini enjekte eder; gerçek zaman/mikrofon gerekmez.
final class SpeechGateTests: XCTestCase {

    private func makeGate(
        gateFloorDB: Float = -60.0,
        stayRatio: Float = 0.5,
        minSpeech: TimeInterval = 0.12,
        silenceHold: TimeInterval = 0.4,
        maxSegment: TimeInterval = 8.0,
        calibration: TimeInterval = 0,
        initialNoiseFloorDB: Float = -80.0
    ) -> SpeechGate {
        SpeechGate(
            gateFloorDB: gateFloorDB,
            stayRatio: stayRatio,
            minSpeechSeconds: minSpeech,
            silenceHoldSeconds: silenceHold,
            maxSegmentSeconds: maxSegment,
            calibrationSeconds: calibration,
            initialNoiseFloorDB: initialNoiseFloorDB
        )
    }

    // MARK: - Kalibrasyon

    func testCalibrationLearnsLoudRoomBeforeSpeechIsDeclared() {
        // Gürültülü oda: ortam -45 dB. Kalibrasyon sırasında konuşma ilan
        // edilmemeli, yalnızca taban öğrenilmeli.
        var gate = makeGate(calibration: 0.5)
        for t in stride(from: 0.0, through: 0.45, by: 0.05) {
            gate.update(powerDB: -45.0, now: t)
        }
        XCTAssertEqual(gate.state, .silent, "Kalibrasyon sırasında konuşma ilan edilmemeli")
        // Taban ortam seviyesine yaklaşmış olmalı.
        XCTAssertGreaterThan(gate.noiseFloorDB, -60.0, "Taban gürültülü ortama uyarlanmalı")
    }

    func testCalibrationEndsAndSpeechIsDetectedAfterwards() {
        var gate = makeGate(calibration: 0.5)
        for t in stride(from: 0.0, through: 0.45, by: 0.05) {
            gate.update(powerDB: -70.0, now: t)
        }
        // Kalibrasyon bitti; yüksek ses artık konuşma sayılmalı.
        gate.update(powerDB: -30.0, now: 0.55)
        gate.update(powerDB: -30.0, now: 0.75)
        XCTAssertEqual(gate.state, .speech)
    }

    // MARK: - Eşik matematiği

    func testStayThresholdIsSixDecibelsBelowEnterForHalfRatio() {
        let gate = makeGate()
        let expectedOffset = 20.0 * log10(0.5)   // ~-6.02 dB
        XCTAssertEqual(gate.stayThresholdDB, gate.enterThresholdDB + Float(expectedOffset), accuracy: 0.05)
    }

    func testEnterThresholdNeverDropsBelowGateFloor() {
        var gate = makeGate(gateFloorDB: -60.0)
        // Taban çok düşük olsa bile mutlak taban korunur.
        gate.resetFully()
        XCTAssertGreaterThanOrEqual(gate.enterThresholdDB, -60.0)
    }

    // MARK: - Temel geçişler

    func testSilenceStaysSilent() {
        var gate = makeGate()
        for t in stride(from: 0.0, through: 2.0, by: 0.05) {
            gate.update(powerDB: -80.0, now: t)
        }
        XCTAssertEqual(gate.state, .silent)
        XCTAssertTrue(gate.hasNeverSpoken)
    }

    func testLoudSpeechOpensGateAfterMinimumDuration() {
        var gate = makeGate()
        gate.update(powerDB: -80.0, now: 0.0)
        // İlk konuşma karesi: henüz "speech" değil, aday.
        gate.update(powerDB: -30.0, now: 0.05)
        XCTAssertEqual(gate.state, .silent, "minSpeechSeconds dolmadan açılmamalı")
        // Yeterince uzun sürerse açılır.
        gate.update(powerDB: -30.0, now: 0.20)
        XCTAssertEqual(gate.state, .speech)
    }

    func testBriefSpikeDoesNotOpenGate() {
        var gate = makeGate()
        gate.update(powerDB: -80.0, now: 0.0)
        gate.update(powerDB: -20.0, now: 0.02)   // çok kısa sıçrama
        gate.update(powerDB: -80.0, now: 0.05)   // hemen bitti
        XCTAssertEqual(gate.state, .silent, "Tek karelik sıçrama konuşma sayılmamalı")
    }

    // MARK: - Hysteresis (çift eşiğin asıl amacı)

    func testSpeechContinuesBelowEnterThreshold() {
        var gate = makeGate()
        gate.update(powerDB: -80.0, now: 0.0)
        gate.update(powerDB: -30.0, now: 0.05)
        gate.update(powerDB: -30.0, now: 0.20)
        XCTAssertEqual(gate.state, .speech)

        // Giriş eşiğinin ALTINDA ama sürdürme eşiğinin ÜSTÜNDE bir seviye:
        // konuşma devam etmeli (tek eşikli kapı burada kapanırdı).
        let betweenThresholds = gate.stayThresholdDB + 1.0
        XCTAssertLessThan(betweenThresholds, gate.enterThresholdDB,
                          "Test varsayımı: ara seviye gerçekten iki eşik arasında olmalı")
        gate.update(powerDB: betweenThresholds, now: 0.25)
        XCTAssertEqual(gate.state, .speech, "Hysteresis: ara seviyede konuşma sürmeli")
    }

    func testSegmentClosesOnlyAfterSilenceHold() {
        var gate = makeGate(silenceHold: 0.4)
        gate.update(powerDB: -80.0, now: 0.0)
        gate.update(powerDB: -30.0, now: 0.05)
        gate.update(powerDB: -30.0, now: 0.20)
        XCTAssertEqual(gate.state, .speech)

        // Konuşma bitti: holding'e geçer ama hemen kapanmaz.
        gate.update(powerDB: -80.0, now: 0.30)
        XCTAssertEqual(gate.state, .holding, "Sessizlik süresi dolmadan kapanmamalı")
        // Süre dolunca kapanır.
        gate.update(powerDB: -80.0, now: 0.75)
        XCTAssertEqual(gate.state, .silent)
    }

    func testMidSentencePauseDoesNotSplitSegment() {
        var gate = makeGate(silenceHold: 0.4)
        gate.update(powerDB: -80.0, now: 0.0)
        gate.update(powerDB: -30.0, now: 0.05)
        gate.update(powerDB: -30.0, now: 0.20)

        // Cümle ortası kısa duraklama (0.2 sn < 0.4 sn).
        gate.update(powerDB: -85.0, now: 0.30)
        XCTAssertEqual(gate.state, .holding)
        gate.update(powerDB: -30.0, now: 0.50)
        XCTAssertEqual(gate.state, .speech, "Kısa duraklama cümleyi bölmemeli")
        // Segment başı hâlâ ilk konuşma: segment birleşik kaldı.
        XCTAssertEqual(gate.speechStartedAt ?? -1, 0.05, accuracy: 0.001)
    }

    // MARK: - maxSegment (sürekli konuşma koruması)

    func testContinuousSpeechClosesSegmentAtMaxDuration() {
        var gate = makeGate(maxSegment: 1.0)
        gate.update(powerDB: -80.0, now: 0.0)
        gate.update(powerDB: -30.0, now: 0.05)
        gate.update(powerDB: -30.0, now: 0.20)
        XCTAssertEqual(gate.state, .speech)

        // Hiç susmadan konuşmaya devam: 1.0 sn'yi geçince segment kapanmalı
        // VE konuşma sürdüğü için hemen yeni segment açılmalı.
        gate.update(powerDB: -30.0, now: 0.60)
        gate.update(powerDB: -30.0, now: 1.10)
        XCTAssertEqual(gate.state, .speech, "Konuşma sürerken yeni segment açılmalı")
        XCTAssertEqual(gate.speechStartedAt ?? -1, 1.10, accuracy: 0.001,
                       "Yeni segment maxSegment anından başlamalı")
    }

    // MARK: - Adaptif gürültü tabanı

    func testQuietRoomLetsWhisperThrough() {
        // Sessiz odada taban çok düşük → fısıltı konuşma açabilmeli.
        var gate = makeGate(gateFloorDB: -60.0)
        for t in stride(from: 0.0, through: 1.0, by: 0.05) {
            gate.update(powerDB: -85.0, now: t)
        }
        // Fısıltı seviyesi (-58 dB), mutlak tabanın (-60) üstünde.
        gate.update(powerDB: -58.0, now: 1.05)
        gate.update(powerDB: -58.0, now: 1.25)
        XCTAssertEqual(gate.state, .speech, "Sessiz odada fısıltı algılanmalı")
    }

    func testNoisyRoomRaisesEnterThreshold() {
        // Gürültülü ortam kalibrasyonla öğrenilmeli: sürekli -45 dB.
        var gate = makeGate(gateFloorDB: -60.0, calibration: 0.5)
        for t in stride(from: 0.0, through: 0.60, by: 0.05) {
            gate.update(powerDB: -45.0, now: t)
        }
        // Taban yükseldiği için giriş eşiği mutlak tabandan yukarı çıkmalı.
        XCTAssertGreaterThan(gate.enterThresholdDB, -60.0,
                             "Gürültülü odada eşik adaptif olarak yükselmeli")
        XCTAssertEqual(gate.state, .silent,
                       "Ortam gürültüsü tek başına konuşma sayılmamalı")
    }

    // MARK: - Güvenlik / sınır durumları

    func testInvalidPowerValuesAreTreatedAsSilence() {
        var gate = makeGate()
        gate.update(powerDB: .nan, now: 0.0)
        gate.update(powerDB: .infinity, now: 0.05)
        gate.update(powerDB: -.infinity, now: 0.10)
        XCTAssertEqual(gate.state, .silent, "Geçersiz güç değerleri çökmemeli")
    }

    func testExtremePowerValuesAreSafe() {
        var gate = makeGate()
        gate.update(powerDB: -160.0, now: 0.0)
        gate.update(powerDB: 0.0, now: 0.05)
        gate.update(powerDB: 0.0, now: 0.20)
        XCTAssertEqual(gate.state, .speech)
    }

    func testStoppingRecordingResetsGate() {
        var gate = makeGate()
        gate.update(powerDB: -30.0, now: 0.05)
        gate.update(powerDB: -30.0, now: 0.20)
        XCTAssertEqual(gate.state, .speech)
        gate.update(powerDB: -30.0, now: 0.30, isRecording: false)
        XCTAssertEqual(gate.state, .silent)
    }

    func testResetFullyClearsLearnedNoiseFloor() {
        var gate = makeGate()
        for t in stride(from: 0.0, through: 2.0, by: 0.05) {
            gate.update(powerDB: -50.0, now: t)
        }
        let learned = gate.noiseFloorDB
        gate.resetFully()
        XCTAssertGreaterThan(gate.noiseFloorDB, learned, "Sıfırlama tabanı başlangıca döndürmeli")
    }

    func testHasNeverSpokenFalseAfterSpeechEnded() {
        var gate = makeGate()
        gate.update(powerDB: -80.0, now: 0.0)
        gate.update(powerDB: -30.0, now: 0.05)
        gate.update(powerDB: -30.0, now: 0.20)
        XCTAssertEqual(gate.state, .speech)
        // Konuşmanın bittiği ilk örnek damgalanır (0.30) ve sessizlik süresi
        // oradan ölçülür; 0.30 + 0.4 = 0.70 sonrasında segment kapanır.
        gate.update(powerDB: -85.0, now: 0.30)
        XCTAssertEqual(gate.state, .holding)
        gate.update(powerDB: -85.0, now: 0.75)
        XCTAssertEqual(gate.state, .silent)
        XCTAssertFalse(gate.hasNeverSpoken, "Konuşma bittiyse 'hiç konuşulmadı' false olmalı")
    }
}
