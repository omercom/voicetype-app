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
            if !result.success, let err = result.error, err.contains("503") || err.contains("over capacity") || err.contains("429") || err.contains("Rate limit") || err.contains("rate_limit") {
                print("Groq API geçici olarak aşırı yüklü veya kotalı (503/429): \(err). Canlı test es geçiliyor.")
                expectation.fulfill()
                return
            }
            XCTAssertTrue(result.success, "Groq transcription başarılı olmalı: \(result.error ?? "")")
            XCTAssertFalse(result.text.isEmpty, "Metin boş olmamalı.")
            XCTAssertGreaterThan(result.latency, 0.0)
            print("Canlı Groq Deşifre Sonucu (\(result.latency) sn): \"\(result.text)\"")
            expectation.fulfill()
        }

        wait(for: [expectation], timeout: 15.0)
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
            if !result.success, let err = result.error, err.contains("503") || err.contains("429") || err.contains("Resource has been exhausted") || err.contains("over capacity") {
                print("Gemini API geçici olarak aşırı yüklü veya kotalı: \(err). Canlı test es geçiliyor.")
                expectation.fulfill()
                return
            }
            XCTAssertTrue(result.success, "Gemini transcription başarılı olmalı: \(result.error ?? "")")
            XCTAssertFalse(result.text.isEmpty, "Metin boş olmamalı.")
            XCTAssertTrue(result.text.lowercased().contains("merhaba"), "Deşifre metni 'merhaba' içermeli: \(result.text)")
            XCTAssertGreaterThan(result.latency, 0.0)
            print("Canlı Gemini 3.5 Flash Deşifre Sonucu (\(result.latency) sn): \"\(result.text)\"")
            expectation.fulfill()
        }

        wait(for: [expectation], timeout: 30.0)
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

    func testTriggerKeyOptionHelpers() {
        // Standart tuşlar listesi doğrulaması
        let standardKeys = TriggerKeyOption.standardKeys
        XCTAssertTrue(standardKeys.contains(where: { $0.keyCode == 54 }), "Sağ Command (54) bulunmalı.")
        XCTAssertTrue(standardKeys.contains(where: { $0.keyCode == 58 }), "Sol Option (58) bulunmalı.")
        XCTAssertTrue(standardKeys.contains(where: { $0.keyCode == 61 }), "Sağ Option (61) bulunmalı.")
        XCTAssertTrue(standardKeys.contains(where: { $0.keyCode == 62 }), "Sağ Control (62) bulunmalı.")
        XCTAssertTrue(standardKeys.contains(where: { $0.keyCode == 63 }), "Fn / Globe (63) bulunmalı.")

        // İsim üretimi
        XCTAssertTrue(TriggerKeyOption.name(for: 54).contains("Sağ Command"))
        XCTAssertTrue(TriggerKeyOption.name(for: 58).contains("Sol Option"))
        XCTAssertTrue(TriggerKeyOption.name(for: 61).contains("Sağ Option"))
        XCTAssertTrue(TriggerKeyOption.name(for: 62).contains("Sağ Control"))
        XCTAssertTrue(TriggerKeyOption.name(for: 63).contains("Fn"))
        XCTAssertEqual(TriggerKeyOption.name(for: 122), "F1 Tuşu")
        XCTAssertTrue(TriggerKeyOption.name(for: 999).contains("999"))

        // Kısa isim kontrolü
        XCTAssertEqual(TriggerKeyOption.shortName(for: 54), "Sağ Cmd")
        XCTAssertEqual(TriggerKeyOption.shortName(for: 58), "Sol Option")
        XCTAssertEqual(TriggerKeyOption.shortName(for: 61), "Sağ Option")
        XCTAssertEqual(TriggerKeyOption.shortName(for: 62), "Sağ Ctrl")
        XCTAssertEqual(TriggerKeyOption.shortName(for: 63), "Fn/Globe")
    }

    func testKeyListenerModifierDetection() {
        // Modifier tuşlar
        XCTAssertTrue(KeyListener.isModifier(keyCode: 54)) // Right Cmd
        XCTAssertTrue(KeyListener.isModifier(keyCode: 55)) // Left Cmd
        XCTAssertTrue(KeyListener.isModifier(keyCode: 58)) // Left Option
        XCTAssertTrue(KeyListener.isModifier(keyCode: 61)) // Right Option
        XCTAssertTrue(KeyListener.isModifier(keyCode: 59)) // Left Control
        XCTAssertTrue(KeyListener.isModifier(keyCode: 62)) // Right Control
        XCTAssertTrue(KeyListener.isModifier(keyCode: 63)) // Fn / Globe
        XCTAssertTrue(KeyListener.isModifier(keyCode: 56)) // Left Shift
        XCTAssertTrue(KeyListener.isModifier(keyCode: 60)) // Right Shift

        // Normal tuşlar (modifier olmayan)
        XCTAssertFalse(KeyListener.isModifier(keyCode: 96)) // F5
        XCTAssertFalse(KeyListener.isModifier(keyCode: 49)) // Space
        XCTAssertFalse(KeyListener.isModifier(keyCode: 36)) // Return

        // resetState çökmemeli
        KeyListener.shared.resetState()
    }

    func testGroqConnectionValidation() {
        let expectation = XCTestExpectation(description: "Groq connection test responds")

        // Boş anahtar testi
        Transcriber.shared.testGroqConnection(apiKey: "") { success, message in
            XCTAssertFalse(success)
            XCTAssertTrue(message.contains("Groq API"))
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 2.0)

        // Canlı anahtar testi (mevcutsa)
        let liveKey = ConfigManager.shared.config.groq_api_key
        if !liveKey.isEmpty {
            let liveExpectation = XCTestExpectation(description: "Live Groq connection responds")
            Transcriber.shared.testGroqConnection(apiKey: liveKey) { success, message in
                XCTAssertTrue(success, "Groq canlı bağlantı testi başarılı olmalı: \(message)")
                liveExpectation.fulfill()
            }
            wait(for: [liveExpectation], timeout: 6.0)
        }
    }

    func testGeminiConnectionValidation() {
        let expectation = XCTestExpectation(description: "Gemini connection test responds")

        // Boş anahtar testi
        Transcriber.shared.testGeminiConnection(apiKey: "") { success, message in
            XCTAssertFalse(success)
            XCTAssertTrue(message.contains("Gemini API"))
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 2.0)

        // Canlı anahtar testi (mevcutsa)
        let liveKey = ConfigManager.shared.config.gemini_api_key
        if !liveKey.isEmpty {
            let liveExpectation = XCTestExpectation(description: "Live Gemini connection responds")
            Transcriber.shared.testGeminiConnection(apiKey: liveKey) { success, message in
                XCTAssertTrue(success, "Gemini canlı bağlantı testi başarılı olmalı: \(message)")
                liveExpectation.fulfill()
            }
            wait(for: [liveExpectation], timeout: 6.0)
        }
    }

    func testConfigTriggerKeyPersistence() {
        let originalKey = ConfigManager.shared.config.trigger_key

        // Tuşu 58 (Sol Option) olarak güncelle
        ConfigManager.shared.update { $0.trigger_key = 58 }
        XCTAssertEqual(ConfigManager.shared.config.trigger_key, 58)

        // Geri orijinaline döndür (54)
        ConfigManager.shared.update { $0.trigger_key = originalKey }
        XCTAssertEqual(ConfigManager.shared.config.trigger_key, originalKey)
    }

    func testSettingsWindowInitialization() {
        let controller = SettingsWindowController.shared
        XCTAssertNotNil(controller.window)
        XCTAssertEqual(controller.window?.title, "⚙️ Voice Typing - Ayarlar ve Tercihler")
        controller.refreshPermissionStatuses()
        controller.loadValues()

        // Sekme geçiş kontrolü
        controller.selectTab(index: 1)
        controller.selectTab(index: 2)
        controller.selectTab(index: 0)
    }

    func testCapsLockAndModifierDetection() {
        // Caps Lock (57) modifier listesinde olmalı
        XCTAssertTrue(KeyListener.isModifier(keyCode: 57), "Caps Lock (57) modifier olarak algılanmalı.")
        // Standart tuşlar
        XCTAssertTrue(KeyListener.isModifier(keyCode: 54)) // Right Cmd
        XCTAssertTrue(KeyListener.isModifier(keyCode: 63)) // Fn / Globe
        XCTAssertFalse(KeyListener.isModifier(keyCode: 96)) // F5
    }

    func testGroqModelsDoNotContainTurbo() {
        let models = ConfigManager.availableGroqModels
        XCTAssertFalse(models.contains(where: { $0.id.contains("turbo") }), "whisper-large-v3-turbo modellerden tamamen kaldırılmış olmalıdır.")
        XCTAssertTrue(models.contains(where: { $0.id == "whisper-large-v3" }), "whisper-large-v3 standart model olmalıdır.")
        XCTAssertEqual(ConfigManager.shared.config.groq_model, "whisper-large-v3", "Varsayılan Groq modeli whisper-large-v3 olmalıdır.")
    }

    func testRecordingHUDStateTransitions() {
        let hud = RecordingHUD.shared
        XCTAssertNotNil(hud)

        // 1. Idle / Dismiss
        hud.dismiss(animated: false)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        XCTAssertEqual(hud.currentState, .idle)

        // 2. Recording
        hud.showRecording()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))
        XCTAssertEqual(hud.currentState, .recording)
        XCTAssertTrue(hud.isVisible)

        // 3. Transcribing
        hud.showTranscribing()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))
        XCTAssertEqual(hud.currentState, .transcribing)
        XCTAssertTrue(hud.isVisible)

        // 4. Success
        hud.showSuccess(text: "Yapıştırıldı", autoDismissDelay: 0.1)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        XCTAssertEqual(hud.currentState, .success)

        // 5. Otomatik kapanma
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.35))
        XCTAssertEqual(hud.currentState, .idle)

        // 6. Error durumu
        hud.showError(message: "Test Hatası", autoDismissDelay: 0.1)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        XCTAssertEqual(hud.currentState, .error("Test Hatası"))

        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.35))
        XCTAssertEqual(hud.currentState, .idle)
    }

    func testFloatingHUDPanelFocusProperties() {
        let panel = FloatingHUDPanel(
            contentRect: NSRect(x: 0, y: 0, width: 216, height: 46),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        // Odak (focus) çalamayacağını garanti et
        XCTAssertFalse(panel.canBecomeKey, "Floating HUD asla klavye odağı (key window) alamaz.")
        XCTAssertFalse(panel.canBecomeMain, "Floating HUD asla ana pencere (main window) olamaz.")
    }

    func testRecordingHUDRapidRetriggerDuringDismiss() {
        let hud = RecordingHUD.shared
        // HUD'ı başarı durumuna geçir ve kapatma animasyonunu başlat
        hud.showSuccess(text: "Yapıştırıldı", autoDismissDelay: 0.05)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.06))

        // Dismiss animasyonu sürerken kullanıcı aniden tekrar tetikleyici tuşa basarsa:
        hud.showRecording()
        XCTAssertEqual(hud.currentState, .recording)

        // Dismiss animasyonunun tamamlanma süresini bekle (0.20s + margin)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.30))

        // Önceki dismiss animasyonu bittiğinde yeni kaydı kapatmamış olmalıdır!
        XCTAssertEqual(hud.currentState, .recording, "Kullanıcı konuşurken HUD kapanmamış olmalı.")
        XCTAssertTrue(hud.isVisible, "Kullanıcı konuşurken HUD görünür kalmalı.")

        hud.dismiss(animated: false)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        XCTAssertEqual(hud.currentState, .idle)
    }
}
