import XCTest
import AppKit
@testable import VoiceTypingCore

final class VoiceTypingTests: XCTestCase {

    func testConfigLoadingAndDefaults() {
        let config = ConfigManager.shared.config
        XCTAssertEqual(config.trigger_key, 54, "Tetikleyici tuş 54 (Sağ Command) olmalıdır.")
        XCTAssertTrue(config.provider == "groq" || config.provider == "gemini")
        XCTAssertGreaterThan(config.min_record_duration, 0.0)

        // LaTeX ($) yasağı kontrolü
        for model in ConfigManager.availableGroqModels {
            XCTAssertFalse(model.price.contains("$"), "Fiyat LaTeX ($) işareti içeremez: \(model.price)")
            XCTAssertFalse(model.name.contains("$"), "Model adı ($) içeremez.")
            XCTAssertTrue(model.price.contains("USD") || model.price.contains("Ücretsiz"))
        }

        for model in ConfigManager.availableGeminiModels {
            XCTAssertFalse(model.price.contains("$"), "Gemini fiyat LaTeX ($) içeremez: \(model.price)")
            XCTAssertTrue(model.price.contains("USD") || model.price.contains("Ücretsiz") || model.price.contains("Maliyet"))
        }
    }

    func testConfigUpdateInMemory() {
        let original = ConfigManager.shared.config.restore_clipboard
        let testVal = !original

        ConfigManager.shared.update { $0.restore_clipboard = testVal }
        XCTAssertEqual(ConfigManager.shared.config.restore_clipboard, testVal)

        // Geri al
        ConfigManager.shared.update { $0.restore_clipboard = original }
        XCTAssertEqual(ConfigManager.shared.config.restore_clipboard, original)
    }

    func testPermissionManagerStatuses() {
        let mic = PermissionManager.shared.getMicrophoneStatus()
        XCTAssertFalse(mic.description.isEmpty)
        XCTAssertFalse(mic.badge.isEmpty)

        let acc = PermissionManager.shared.getAccessibilityStatus()
        XCTAssertFalse(acc.description.isEmpty)
        XCTAssertFalse(acc.badge.isEmpty)
    }

    func testSoundManager() {
        let sm = SoundManager.shared
        sm.isEnabled = true
        sm.playStart()
        sm.playStop()
        sm.playSuccess()
        sm.playCancel()

        sm.isEnabled = false
        sm.playStart()
        sm.isEnabled = true
    }

    func testTextInjectorClipboard() {
        let injector = TextInjector.shared
        let original = injector.getClipboard()

        let testStr = "Kadıköy Beşiktaş Şişli 123 Türkçe Karakter Testi: ığüşöç İĞÜŞÖÇ"
        injector.setClipboard(testStr)
        XCTAssertEqual(injector.getClipboard(), testStr)

        // Boş metin testi
        XCTAssertFalse(injector.paste(text: ""))

        // Eski panoyu geri yükle
        injector.setClipboard(original)
    }

    func testAudioRecorder() {
        let recorder = AudioRecorder.shared
        let started = recorder.start()
        XCTAssertTrue(started, "Mikrofon kaydı başlatılabilmeli.")
        XCTAssertTrue(recorder.isRecording)

        Thread.sleep(forTimeInterval: 0.3)

        let (data, duration) = recorder.stop()
        XCTAssertFalse(recorder.isRecording)
        XCTAssertGreaterThan(duration, 0.25)
        // Ortamda ses/mikrofon durumuna göre data nil veya Data olabilir, ancak çökmemelidir.
        if let data = data {
            XCTAssertGreaterThan(data.count, 0)
        }
    }

    func testRealGroqTranscriptionWithSampleAudio() {
        let cfg = ConfigManager.shared.config
        guard !cfg.groq_api_key.isEmpty else {
            print("GROQ_API_KEY bulunamadı, canlı test atlanıyor.")
            return
        }

        let sampleURL = URL(fileURLWithPath: "live_recording.wav")
        guard let audioData = try? Data(contentsOf: sampleURL) else {
            print("live_recording.wav bulunamadı, canlı test atlanıyor.")
            return
        }

        let expectation = XCTestExpectation(description: "Groq transcription completes")

        Transcriber.shared.transcribeGroq(audioData: audioData, config: cfg) { result in
            XCTAssertTrue(result.success, "Groq transcription başarılı olmalı: \(result.error ?? "")")
            XCTAssertFalse(result.text.isEmpty, "Metin boş olmamalı.")
            XCTAssertGreaterThan(result.latency, 0.0)
            print("Canlı Groq Deşifre Sonucu (\(result.latency) sn): \"\(result.text)\"")
            expectation.fulfill()
        }

        wait(for: [expectation], timeout: 10.0)
    }

    func testGroqEmptyApiKeyErrorHandling() {
        var dummyConfig = ConfigManager.shared.config
        dummyConfig.groq_api_key = ""

        let expectation = XCTestExpectation(description: "Groq returns error for missing key")
        Transcriber.shared.transcribeGroq(audioData: Data([0, 1, 2]), config: dummyConfig) { result in
            XCTAssertFalse(result.success)
            XCTAssertNotNil(result.error)
            XCTAssertTrue(result.error!.contains("GROQ_API_KEY"))
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 2.0)
    }

    func testGeminiEmptyApiKeyErrorHandling() {
        var dummyConfig = ConfigManager.shared.config
        dummyConfig.gemini_api_key = ""

        let expectation = XCTestExpectation(description: "Gemini returns error for missing key")
        Transcriber.shared.transcribeGemini(audioData: Data([0, 1, 2]), config: dummyConfig) { result in
            XCTAssertFalse(result.success)
            XCTAssertNotNil(result.error)
            XCTAssertTrue(result.error!.contains("GEMINI_API_KEY"))
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 2.0)
    }

    func testAudioRecorderCancel() {
        let recorder = AudioRecorder.shared
        _ = recorder.start()
        XCTAssertTrue(recorder.isRecording)
        recorder.cancel()
        XCTAssertFalse(recorder.isRecording)
    }

    func testTextInjectorComplexStrings() {
        let injector = TextInjector.shared
        let original = injector.getClipboard()

        let complex = "🎙️ Multiline\nTab\tSpecial: \"'\\ & <xml> 🚀\nTürkçe: şçöğüı"
        injector.setClipboard(complex)
        XCTAssertEqual(injector.getClipboard(), complex)

        injector.setClipboard(original)
    }

    func testRealGeminiTranscriptionWithSampleAudio() {
        var cfg = ConfigManager.shared.config
        cfg.gemini_model = "gemini-3.5-flash"
        guard !cfg.gemini_api_key.isEmpty else {
            print("GEMINI_API_KEY bulunamadı, canlı test atlanıyor.")
            return
        }

        let sampleURL = URL(fileURLWithPath: "live_recording.wav")
        guard let audioData = try? Data(contentsOf: sampleURL) else {
            print("live_recording.wav bulunamadı, canlı test atlanıyor.")
            return
        }

        let expectation = XCTestExpectation(description: "Gemini transcription completes")

        Transcriber.shared.transcribeGemini(audioData: audioData, config: cfg) { result in
            XCTAssertTrue(result.success, "Gemini transcription başarılı olmalı: \(result.error ?? "")")
            XCTAssertFalse(result.text.isEmpty, "Metin boş olmamalı.")
            XCTAssertTrue(result.text.lowercased().contains("merhaba"), "Deşifre metni 'merhaba' içermeli: \(result.text)")
            XCTAssertGreaterThan(result.latency, 0.0)
            print("Canlı Gemini 3.5 Flash Deşifre Sonucu (\(result.latency) sn): \"\(result.text)\"")
            expectation.fulfill()
        }

        wait(for: [expectation], timeout: 15.0)
    }

    func testAudioRecorderSilenceDetection() {
        // 1. live_recording.wav gerçek ses içerir -> Sessiz OLMAMALI
        let sampleURL = URL(fileURLWithPath: "live_recording.wav")
        if let audioData = try? Data(contentsOf: sampleURL) {
            let isSilent = AudioRecorder.isAudioSilent(data: audioData)
            XCTAssertFalse(isSilent, "Gerçek ses kaydı sessiz olarak işaretlenmemelidir.")
        }

        // 2. Saf dijital sıfırlardan oluşan veri -> Sessiz OLMALI
        let silentWav = Data(count: 44 + 3200) // 44 byte header + 1600 Int16 zeros
        let isSilentZeros = AudioRecorder.isAudioSilent(data: silentWav)
        XCTAssertTrue(isSilentZeros, "Sıfır genlikli ses sessiz olarak algılanmalıdır.")

        // 3. Eşik üstü genlik örneği
        var loudWav = silentWav
        let loudSample: Int16 = 500
        loudWav.withUnsafeMutableBytes { ptr in
            let samplePtr = ptr.baseAddress!.advanced(by: 44).assumingMemoryBound(to: Int16.self)
            samplePtr[10] = loudSample
        }
        let isSilentLoud = AudioRecorder.isAudioSilent(data: loudWav)
        XCTAssertFalse(isSilentLoud, "Yüksek genlikli ses kaydı sessiz işaretlenmemelidir.")
    }
}
