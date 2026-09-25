import XCTest
@testable import VoiceTypingCore

/// Yeni ayarların geriye uyumluluğunu ve varsayılanlarını doğrular.
/// Kullanıcıların mevcut config.json dosyaları yeni anahtarlar olmadan da
/// sorunsuz yüklenmeye devam etmelidir.
final class AppConfigCompatibilityTests: XCTestCase {

    private func decode(_ json: String) throws -> AppConfig {
        let data = Data(json.utf8)
        return try JSONDecoder().decode(AppConfig.self, from: data)
    }

    func testLegacyConfigWithoutNewKeysStillDecodes() throws {
        // Yeni anahtarlar eklenmeden önce kaydedilmiş tipik bir config.
        let legacy = """
        {
          "provider": "groq",
          "groq_api_key": "test",
          "gemini_api_key": "",
          "groq_model": "whisper-large-v3",
          "gemini_model": "gemini-3.5-transcribe-live",
          "language": "tr",
          "trigger_key": 54,
          "trigger_mode": "hold",
          "play_sounds": true,
          "restore_clipboard": false,
          "paste_delay_ms": 20,
          "min_record_duration": 0.2,
          "mute_system_audio": true,
          "show_dock_icon": false,
          "haptic_feedback": true,
          "remove_filler_words": true,
          "custom_vocabulary": "",
          "dictation_mode": "direct",
          "save_history": true,
          "gemini_system_prompt": "x"
        }
        """
        let cfg = try decode(legacy)
        // Yeni ayarlar güvenli varsayılanlara düşmeli.
        XCTAssertEqual(cfg.hud_style, "pill", "Eski config'ler kapsül modunda kalmalı")
        XCTAssertEqual(cfg.decode_tokens_per_sec, 16)
        XCTAssertEqual(cfg.decode_token_base, 32)
        XCTAssertEqual(cfg.vad_gate_db, -60.0)
        XCTAssertEqual(cfg.vad_stay_ratio, 0.5)
        XCTAssertEqual(cfg.vad_silence_hold_sec, 0.4)
        XCTAssertEqual(cfg.vad_max_segment_sec, 8.0)
    }

    func testUnknownKeysAreIgnored() throws {
        // config.example.json içindeki "_aciklama_*" açıklama anahtarları
        // kod tarafından bilinmez; kod çökmemeli.
        let withComments = """
        {
          "provider": "apple",
          "groq_api_key": "", "gemini_api_key": "",
          "groq_model": "whisper-large-v3",
          "gemini_model": "gemini-3.5-transcribe-live",
          "language": "tr", "trigger_key": 54, "trigger_mode": "hold",
          "play_sounds": true, "restore_clipboard": false,
          "paste_delay_ms": 20, "min_record_duration": 0.2,
          "mute_system_audio": true, "show_dock_icon": false,
          "haptic_feedback": true, "remove_filler_words": true,
          "custom_vocabulary": "", "dictation_mode": "direct",
          "save_history": true, "gemini_system_prompt": "x",
          "_aciklama_vad": "aciklama metni",
          "_aciklama_decode": "baska aciklama",
          "bilinmeyen_anahtar": 12345
        }
        """
        let cfg = try decode(withComments)
        XCTAssertEqual(cfg.provider, "apple")
        XCTAssertEqual(cfg.vad_gate_db, -60.0)
    }

    func testRoundTripPreservesNewKeys() throws {
        var cfg = AppConfig.defaultConfig
        cfg.hud_style = "notch"
        cfg.vad_gate_db = -55
        cfg.vad_max_segment_sec = 12
        cfg.decode_tokens_per_sec = 0

        let data = try JSONEncoder().encode(cfg)
        let restored = try JSONDecoder().decode(AppConfig.self, from: data)

        XCTAssertEqual(restored.hud_style, "notch")
        XCTAssertEqual(restored.vad_gate_db, -55)
        XCTAssertEqual(restored.vad_max_segment_sec, 12)
        XCTAssertEqual(restored.decode_tokens_per_sec, 0)
    }

    func testDefaultConfigUsesSafeNonBreakingValues() {
        let cfg = AppConfig.defaultConfig
        // Varsayılanlar mevcut davranışı korumalı: kapsül modu açık.
        XCTAssertEqual(cfg.hud_style, "pill")
        // Decode tavanı açık ama cömert olmalı (konuşmayı kırpmaz).
        XCTAssertEqual(cfg.decode_tokens_per_sec, 16)
        XCTAssertEqual(cfg.decode_token_base, 32)
        // VAD varsayılanları AlwaysWhisper'ın ölçülmüş değerleriyle aynı.
        XCTAssertEqual(cfg.vad_gate_db, -60.0)
        XCTAssertEqual(cfg.vad_stay_ratio, 0.5)
        XCTAssertEqual(cfg.vad_silence_hold_sec, 0.4)
        XCTAssertEqual(cfg.vad_max_segment_sec, 8.0)
    }

    func testHudPlacementResolution() {
        XCTAssertEqual(HUDPlacement.resolve("notch"), .notch)
        XCTAssertEqual(HUDPlacement.resolve("NOTCH"), .notch)
        XCTAssertEqual(HUDPlacement.resolve("pill"), .pill)
        // Bilinmeyen değer güvenli varsayılana düşmeli, çökmemeli.
        XCTAssertEqual(HUDPlacement.resolve("bilinmeyen"), .pill)
        XCTAssertEqual(HUDPlacement.resolve(""), .pill)
    }
}
