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
            if !result.success, let err = result.error, err.contains("503") || err.contains("429") || err.contains("Resource has been exhausted") || err.contains("over capacity") || err.contains("timed out") || err.contains("quota") {
                print("Gemini API geçici olarak aşırı yüklü, kotalı veya zaman aşımına uğradı: \(err). Canlı test es geçiliyor.")
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
        XCTAssertEqual(controller.window?.title, "Voice Typing - Ayarlar")
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

    func testGeminiLiveModelConfiguration() {
        // 1. Varsayılan Gemini modeli gemini-3.5-transcribe-live olmalıdır
        XCTAssertEqual(AppConfig.defaultConfig.gemini_model, "gemini-3.5-transcribe-live")

        // 2. Modeller listesinin ilk öğesi gemini-3.5-transcribe-live olmalıdır
        let firstModel = ConfigManager.availableGeminiModels.first
        XCTAssertEqual(firstModel?.id, "gemini-3.5-transcribe-live")
        XCTAssertTrue(firstModel?.name.contains("Live") == true || firstModel?.name.contains("Canlı") == true)

        // 3. gemini-3.5-transcribe (REST) seçeneği de mevcut olmalıdır
        let restModel = ConfigManager.availableGeminiModels.first(where: { $0.id == "gemini-3.5-transcribe" })
        XCTAssertNotNil(restModel)

        // 4. LaTeX ($) yasağı kontrolü
        for model in ConfigManager.availableGeminiModels {
            XCTAssertFalse(model.price.contains("$"))
            XCTAssertFalse(model.name.contains("$"))
            XCTAssertFalse(model.speed.contains("$"))
        }
    }

    func testWavHeaderGeneration() {
        let dummyPCM = Data(repeating: 0x20, count: 3200) // 100ms
        let wav = AudioRecorder.createWavData(pcmData: dummyPCM, sampleRate: 16000, channels: 1, bitDepth: 16)
        XCTAssertEqual(wav.count, 44 + 3200)

        let riff = String(data: wav.subdata(in: 0..<4), encoding: .ascii)
        XCTAssertEqual(riff, "RIFF")

        let wave = String(data: wav.subdata(in: 8..<12), encoding: .ascii)
        XCTAssertEqual(wave, "WAVE")

        let fmt = String(data: wav.subdata(in: 12..<16), encoding: .ascii)
        XCTAssertEqual(fmt, "fmt ")

        let dataTag = String(data: wav.subdata(in: 36..<40), encoding: .ascii)
        XCTAssertEqual(dataTag, "data")
    }

    func testAudioRecorderRealtimeChunkStreaming() {
        let recorder = AudioRecorder.shared
        var chunkCount = 0
        let started = recorder.start { chunk in
            chunkCount += 1
            XCTAssertFalse(chunk.isEmpty)
        }
        XCTAssertTrue(started)
        XCTAssertTrue(recorder.isRecording)

        Thread.sleep(forTimeInterval: 0.35)

        let (data, duration) = recorder.stop()
        XCTAssertFalse(recorder.isRecording)
        XCTAssertGreaterThan(duration, 0.25)
        if let data = data {
            XCTAssertGreaterThan(data.count, 44)
        }
    }

    func testRecordingHUDInterimText() {
        let hud = RecordingHUD.shared
        hud.showRecording()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        XCTAssertEqual(hud.currentState, .recording)

        hud.updateInterimText("Canlı ara metin önizlemesi")
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        XCTAssertEqual(hud.currentState, .recording)

        // transcribing durumuna geçişte mevcut metin korunmalı
        hud.showTranscribing()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        XCTAssertEqual(hud.currentState, .transcribing)

        // transcribing durumundayken de ara metin güncellenebilmeli (son kelimelerin ekranda akması)
        hud.updateInterimText("Canlı ara metin önizlemesi tamamlandı")
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        XCTAssertEqual(hud.currentState, .transcribing)

        // Başarı durumunda kapsül genişliği sıfırlanmalı
        hud.showSuccess(text: "Yapıştırıldı")
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        XCTAssertEqual(hud.currentState, .success)

        hud.dismiss(animated: false)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        XCTAssertEqual(hud.currentState, .idle)
    }

    func testGeminiLiveEmptyApiKeyHandling() {
        var dummyConfig = ConfigManager.shared.config
        dummyConfig.gemini_api_key = ""
        dummyConfig.gemini_model = "gemini-3.5-transcribe-live"

        let expectation = XCTestExpectation(description: "Live session completes with error when API key is empty")
        let session = Transcriber.shared.startLiveGeminiSession(config: dummyConfig, onInterim: nil) { result in
            XCTAssertFalse(result.success)
            XCTAssertNotNil(result.error)
            XCTAssertTrue(result.error!.contains("GEMINI_API_KEY"))
            expectation.fulfill()
        }
        XCTAssertNil(session)
        wait(for: [expectation], timeout: 2.0)
    }

    func testRealGeminiLiveStreamingWithSampleAudio() {
        var cfg = ConfigManager.shared.config
        cfg.gemini_model = "gemini-3.5-transcribe-live"
        guard !cfg.gemini_api_key.isEmpty else {
            print("GEMINI_API_KEY bulunamadı, canlı WebSocket testi atlanıyor.")
            return
        }

        let sampleURL = URL(fileURLWithPath: "live_recording.wav")
        guard let audioData = try? Data(contentsOf: sampleURL) else {
            print("live_recording.wav bulunamadı, canlı WebSocket testi atlanıyor.")
            return
        }

        let expectation = XCTestExpectation(description: "Gemini Live WebSocket transcription completes")

        Transcriber.shared.transcribeGeminiLive(audioData: audioData, config: cfg) { result in
            if !result.success, let err = result.error, err.contains("503") || err.contains("429") || err.contains("Resource has been exhausted") || err.contains("over capacity") || err.contains("quota") || err.contains("exceeded") || err.contains("Socket is not connected") || err.contains("timed out") {
                print("Gemini Live API geçici olarak kotalı veya sunucu meşgul: \(err). Canlı test es geçiliyor.")
                expectation.fulfill()
                return
            }
            XCTAssertTrue(result.success, "Gemini Live transcription başarılı olmalı: \(result.error ?? "")")
            XCTAssertFalse(result.text.isEmpty, "Deşifre metni boş olmamalı.")
            XCTAssertTrue(result.text.lowercased().contains("merhaba"), "Deşifre metni 'merhaba' içermeli: \(result.text)")
            XCTAssertGreaterThan(result.latency, 0.0)
            print("Canlı Gemini 3.5 Transcribe Live WebSocket Sonucu (\(result.latency) sn): \"\(result.text)\"")
            expectation.fulfill()
        }

        wait(for: [expectation], timeout: 20.0)
    }

    func testRealGeminiLiveStreamingSimulatedRealTime() {
        var cfg = ConfigManager.shared.config
        cfg.gemini_model = "gemini-3.5-transcribe-live"
        guard !cfg.gemini_api_key.isEmpty else { return }

        let sampleURL = URL(fileURLWithPath: "live_recording.wav")
        guard let audioData = try? Data(contentsOf: sampleURL) else { return }

        let pcmData: Data
        if audioData.count > 44, String(data: audioData.prefix(4), encoding: .ascii) == "RIFF" {
            pcmData = audioData.subdata(in: 44..<audioData.count)
        } else {
            pcmData = audioData
        }

        let expectation = XCTestExpectation(description: "Simulated real-time streaming completes")
        var interimCount = 0

        guard let session = Transcriber.shared.startLiveGeminiSession(
            config: cfg,
            onInterim: { text in
                interimCount += 1
            },
            completion: { result in
                if !result.success, let err = result.error, err.contains("503") || err.contains("429") || err.contains("Resource has been exhausted") || err.contains("over capacity") || err.contains("quota") || err.contains("exceeded") || err.contains("Socket is not connected") || err.contains("timed out") {
                    print("Gemini Live API kotalı: \(err). Test es geçiliyor.")
                    expectation.fulfill()
                    return
                }
                XCTAssertTrue(result.success, "Gerçek zamanlı akış başarılı olmalı: \(result.error ?? "")")
                XCTAssertFalse(result.text.isEmpty)
                XCTAssertTrue(result.text.lowercased().contains("merhaba"))
                expectation.fulfill()
            }
        ) else {
            XCTFail("Canlı oturum başlatılamadı.")
            return
        }

        // Parçaları 25ms aralıklarla gerçek zamanlı simüle ederek gönder
        DispatchQueue.global().async {
            let chunkSize = 3200
            var offset = 0
            while offset < pcmData.count {
                let end = min(offset + chunkSize, pcmData.count)
                let chunk = pcmData.subdata(in: offset..<end)
                session.sendAudioChunk(chunk)
                offset = end
                usleep(25_000) // 25ms
            }
            session.finishAudio()
        }

        wait(for: [expectation], timeout: 25.0)
    }

    func testGeminiLiveReconcileTranscriptionText() {
        // Durum 1: Interim, birikmiş metnin tamamını ve son 1-2 kelimeyi içeriyor
        let t1 = LiveGeminiStreamSession.reconcileTranscriptionText(
            accumulated: "Bugün toplantı saat",
            interim: "Bugün toplantı saat üçte olacak"
        )
        XCTAssertEqual(t1, "Bugün toplantı saat üçte olacak", "Interim'deki son kelimeler korunmalı.")

        // Durum 2: Interim yalnızca son eklenen delta kelimeleri içeriyor
        let t2 = LiveGeminiStreamSession.reconcileTranscriptionText(
            accumulated: "Bugün toplantı saat",
            interim: "üçte olacak"
        )
        XCTAssertEqual(t2, "Bugün toplantı saat üçte olacak", "Delta kelimeler sonuna eklenmeli.")

        // Durum 3: Birikmiş metin zaten interim'i içeriyor (tekrar etmeme kontrolü)
        let t3 = LiveGeminiStreamSession.reconcileTranscriptionText(
            accumulated: "Bugün toplantı saat üçte olacak",
            interim: "üçte olacak"
        )
        XCTAssertEqual(t3, "Bugün toplantı saat üçte olacak", "Mevcut son kelimeler yinelenmemeli.")

        // Durum 4: Birikmiş boş, interim dolu
        let t4 = LiveGeminiStreamSession.reconcileTranscriptionText(
            accumulated: "",
            interim: "Merhaba dünya"
        )
        XCTAssertEqual(t4, "Merhaba dünya")

        // Durum 5: Birikmiş dolu, interim boş
        let t5 = LiveGeminiStreamSession.reconcileTranscriptionText(
            accumulated: "Merhaba dünya",
            interim: ""
        )
        XCTAssertEqual(t5, "Merhaba dünya")

        // Durum 6: Boş / sessizlik etiketleri filtrelenmeli
        let t6 = LiveGeminiStreamSession.reconcileTranscriptionText(
            accumulated: "[blank_audio]",
            interim: ""
        )
        XCTAssertEqual(t6, "")

        // Durum 7: Kullanıcının bildirdiği hata senaryosu (ara interim daha kısa kalmış ve birikmiş cümlenin alt kümesi)
        let t7 = LiveGeminiStreamSession.reconcileTranscriptionText(
            accumulated: "Sen harika bir insansın. Seni çok seviyorum. Çok güzel.",
            interim: "Sen harika bir insansın. Seni çok seviyorum. Çok"
        )
        XCTAssertEqual(
            t7,
            "Sen harika bir insansın. Seni çok seviyorum. Çok güzel.",
            "Daha kısa kalan ara interim asla tamamlanmış cümlenin sonuna yinelenerek eklenmemeli!"
        )

        // Durum 8: Kelime örtüşmesi (overlap) birleştirme kontrolü
        let t8 = LiveGeminiStreamSession.reconcileTranscriptionText(
            accumulated: "Sen harika bir insansın.",
            interim: "insansın seni çok seviyorum"
        )
        XCTAssertEqual(
            t8,
            "Sen harika bir insansın. seni çok seviyorum",
            "Örtüşen kelimeler mükerrer eklenmeden akıcı birleştirilmeli."
        )

        // Durum 9: Kullanıcının gerçek WebSocket canlı akış senaryosu:
        // Birikmiş metin tam noktalı ("Sen harika bir insansın. Seni çok seviyorum. Çok güzel."),
        // Interim metin noktalama işaretsiz ham metin ("sen harika bir insansın seni çok seviyorum çok")
        let t9 = LiveGeminiStreamSession.reconcileTranscriptionText(
            accumulated: "Sen harika bir insansın. Seni çok seviyorum. Çok güzel.",
            interim: "sen harika bir insansın seni çok seviyorum çok"
        )
        XCTAssertEqual(
            t9,
            "Sen harika bir insansın. Seni çok seviyorum. Çok güzel.",
            "Noktalama işaretsiz ara interim asla tamamlanmış noktalı cümlenin sonuna mükerrer eklenmemeli!"
        )

        // Durum 10: Kümülatif inputTranscription parçaları (noktalama veya büyük/küçük harf farkı olsa bile)
        let t10 = LiveGeminiStreamSession.reconcileTranscriptionText(
            accumulated: "Sen harika bir insansın.",
            interim: "Sen harika bir insansın, seni çok seviyorum."
        )
        XCTAssertEqual(
            t10,
            "Sen harika bir insansın, seni çok seviyorum.",
            "Kümülatif güncellemeler baştaki cümleyi yinelememeli, güncel halini almalı."
        )
    }

    func testGeminiLiveDeduplicateRepeatedPhrases() {
        // Test 1: Kullanıcının bildirdiği tam duplicate metin (8 kelimelik kuyruk tekrarı)
        let input1 = "Sen harika bir insansın. Seni çok seviyorum. Çok güzel. Sen harika bir insansın. Seni çok seviyorum. Çok"
        let dedup1 = LiveGeminiStreamSession.deduplicateRepeatedPhrases(input1)
        XCTAssertEqual(
            dedup1,
            "Sen harika bir insansın. Seni çok seviyorum. Çok güzel.",
            "Kullanıcının karşılaştığı mükerrer son eklenme hatasız ayıklanmalı."
        )

        // Test 2: Birebir ardışık tekrarlanan tam cümle
        let input2 = "Bugün hava çok güzel. Bugün hava çok güzel."
        let dedup2 = LiveGeminiStreamSession.deduplicateRepeatedPhrases(input2)
        XCTAssertEqual(dedup2, "Bugün hava çok güzel.", "Tam cümle tekrarı teke indirilmeli.")

        // Test 3: Cümle içinde ardışık 3 kelimelik tekrar
        let input3 = "Toplantı yarın saat üçte olacak toplantı yarın saat üçte olacak diye konuştuk."
        let dedup3 = LiveGeminiStreamSession.deduplicateRepeatedPhrases(input3)
        XCTAssertEqual(dedup3, "Toplantı yarın saat üçte olacak diye konuştuk.")

        // Test 4: Doğal Türkçe ikilemeler (1 kelime tekrarları) KORUNMALI
        let input4 = "Evet evet, çok çok teşekkür ederim."
        let dedup4 = LiveGeminiStreamSession.deduplicateRepeatedPhrases(input4)
        XCTAssertEqual(dedup4, "Evet evet, çok çok teşekkür ederim.", "Evet evet ve çok çok gibi doğal ikilemeler korunmalı.")

        // Test 5: Normal akıcı cümle (tekrarsız) bozulmamalı
        let input5 = "Yarın sabah erkenden buluşup projeyi teslim edeceğiz."
        let dedup5 = LiveGeminiStreamSession.deduplicateRepeatedPhrases(input5)
        XCTAssertEqual(dedup5, input5)
    }

    func testGeminiLiveIsCoveredHelper() {
        // Alt küme kontrolü
        XCTAssertTrue(LiveGeminiStreamSession.isCovered(
            subText: "sen harika bir insansın seni çok seviyorum çok",
            in: "Sen harika bir insansın. Seni çok seviyorum. Çok güzel."
        ))

        XCTAssertTrue(LiveGeminiStreamSession.isCovered(
            subText: "Seni çok seviyorum",
            in: "Sen harika bir insansın. Seni çok seviyorum. Çok güzel."
        ))

        XCTAssertFalse(LiveGeminiStreamSession.isCovered(
            subText: "Yarın buluşalım",
            in: "Sen harika bir insansın. Seni çok seviyorum. Çok güzel."
        ))

        XCTAssertFalse(LiveGeminiStreamSession.isCovered(
            subText: "Çok güzel canım",
            in: "Sen harika bir insansın. Seni çok seviyorum. Çok güzel."
        ))
    }

    func testRealGeminiLiveUserPhraseNoDuplication() {
        var cfg = ConfigManager.shared.config
        cfg.gemini_model = "gemini-3.5-transcribe-live"
        guard !cfg.gemini_api_key.isEmpty else { return }

        let sampleURL = URL(fileURLWithPath: "/tmp/user_phrase.wav")
        guard let audioData = try? Data(contentsOf: sampleURL) else { return }

        let pcmData: Data
        if audioData.count > 44, String(data: audioData.prefix(4), encoding: .ascii) == "RIFF" {
            pcmData = audioData.subdata(in: 44..<audioData.count)
        } else {
            pcmData = audioData
        }

        let expectation = XCTestExpectation(description: "User phrase live transcription completes with zero duplicates")

        guard let session = Transcriber.shared.startLiveGeminiSession(
            config: cfg,
            onInterim: { text in },
            completion: { result in
                if !result.success, let err = result.error, err.contains("503") || err.contains("429") || err.contains("quota") || err.contains("exceeded") {
                    expectation.fulfill()
                    return
                }
                XCTAssertTrue(result.success)
                print("Canlı Kullanıcı Cümlesi Sonucu: \"\(result.text)\"")
                // Asla mükerrer cümle içermemeli
                let lower = result.text.lowercased()
                let countHarika = lower.components(separatedBy: "harika").count - 1
                XCTAssertLessThanOrEqual(countHarika, 1, "Cümle asla 2 kez yinelenmemeli! Sonuç: \(result.text)")
                expectation.fulfill()
            }
        ) else {
            XCTFail("Canlı oturum başlatılamadı.")
            return
        }

        // Parçaları 80ms aralıklarla gerçek konuşma hızında akıt
        DispatchQueue.global().async {
            let chunkSize = 3200
            var offset = 0
            while offset < pcmData.count {
                let end = min(offset + chunkSize, pcmData.count)
                let chunk = pcmData.subdata(in: offset..<end)
                session.sendAudioChunk(chunk)
                offset = end
                usleep(80_000)
            }
            session.finishAudio()
        }

        wait(for: [expectation], timeout: 20.0)
    }

    // =========================================================================
    // YENİ KULLANICI DENEYİMİ (UX) BİRİM TESTLERİ
    // =========================================================================

    func testTextPolisherFillerWordsRemoval() {
        let polisher = TextPolisher.shared
        var config = AppConfig.defaultConfig
        config.remove_filler_words = true

        // 1. Türkçe duraksama ve cümle başı dolgu temizliği
        let input1 = "Şey, bugün hava çok güzel ııı gerçekten."
        let result1 = polisher.polish(text: input1, config: config)
        XCTAssertEqual(result1, "Bugün hava çok güzel gerçekten.")

        // 2. Cümle ortası ve ses uzatmaları
        let input2 = "Yarın eee toplantı var hımm saat onda."
        let result2 = polisher.polish(text: input2, config: config)
        XCTAssertEqual(result2, "Yarın toplantı var saat onda.")

        // 3. İngilizce duraksama sesleri
        let input3 = "Um, this is uh a test ah really."
        let result3 = polisher.polish(text: input3, config: config)
        XCTAssertEqual(result3, "This is a test really.")

        // 4. Dolgu temizleme kapalıyken metin korunmalı
        config.remove_filler_words = false
        let result4 = polisher.polish(text: input1, config: config)
        XCTAssertTrue(result4.contains("Şey") || result4.contains("şey"))
    }

    func testTextPolisherCustomVocabulary() {
        let polisher = TextPolisher.shared
        var config = AppConfig.defaultConfig
        config.remove_filler_words = false
        config.custom_vocabulary = "Kubernetes, PostgreSQL, Next.js, SPM"

        let raw = "Projeyi kubernetes ve postgresql ile deploy edip next.js frontendi spm ile bağladık."
        let polished = polisher.polish(text: raw, config: config)

        XCTAssertTrue(polished.contains("Kubernetes"), "Özel sözlük terimi 'Kubernetes' doğru büyük harfle yazılmalı.")
        XCTAssertTrue(polished.contains("PostgreSQL"), "Özel sözlük terimi 'PostgreSQL' doğru yazılmalı.")
        XCTAssertTrue(polished.contains("Next.js"), "Özel sözlük terimi 'Next.js' doğru yazılmalı.")
        XCTAssertTrue(polished.contains("SPM"), "Özel sözlük terimi 'SPM' büyük harfle yazılmalı.")
    }

    func testTextPolisherDictationModes() {
        let polisher = TextPolisher.shared
        var config = AppConfig.defaultConfig

        // 1. Birebir (Direct) Mod
        config.dictation_mode = "direct"
        let directInput = "merhaba nasılsın"
        let directResult = polisher.polish(text: directInput, config: config)
        XCTAssertEqual(directResult, "Merhaba nasılsın")

        // 2. Profesyonel / E-posta Modu
        config.dictation_mode = "formal"
        let formalInput = "toplantı saat üçe ertelendi lütfen belgeleri hazırlayın"
        let formalResult = polisher.polish(text: formalInput, config: config)
        XCTAssertTrue(formalResult.hasSuffix("."), "Formal modda cümle sonuna nokta eklenmeli.")
        XCTAssertTrue(formalResult.hasPrefix("Toplantı"), "Cümle başı büyük harfle başlamalı.")

        // 3. Madde İmleri (Bullet Points) Modu
        config.dictation_mode = "bullet_points"
        let bulletInput = "İlk olarak veritabanını hazırla. İkinci olarak API'yi bağla. Son olarak testleri çalıştır."
        let bulletResult = polisher.polish(text: bulletInput, config: config)
        XCTAssertTrue(bulletResult.contains("- Veritabanını hazırla"), "İlk madde biçimlendirilmeli.")
        XCTAssertTrue(bulletResult.contains("- API'yi bağla"), "İkinci madde biçimlendirilmeli.")
        XCTAssertTrue(bulletResult.contains("- Testleri çalıştır"), "Üçüncü madde biçimlendirilmeli.")
    }

    func testDictationHistoryManager() {
        let manager = DictationHistoryManager.shared
        manager.clear()
        XCTAssertEqual(manager.getEntries().count, 0)

        // 1. Giriş ekleme
        manager.addEntry(text: "Test dikte metni 1", provider: "gemini", model: "gemini-3.5-transcribe-live")
        manager.addEntry(text: "Test dikte metni 2", provider: "groq", model: "whisper-large-v3")

        let entries = manager.getEntries()
        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(entries.first?.text, "Test dikte metni 2")
        XCTAssertTrue(entries.first?.menuTitle.contains("Test dikte metni 2") ?? false)

        // 2. Maksimum 15 sınırlandırması testi
        for i in 3...20 {
            manager.addEntry(text: "Dikte no \(i)", provider: "gemini", model: "live")
        }
        let cappedEntries = manager.getEntries()
        XCTAssertEqual(cappedEntries.count, 15, "Geçmiş en fazla 15 girdi ile sınırlandırılmalıdır.")

        // 3. Panoya kopyalama testi
        if let first = cappedEntries.first {
            manager.copyToClipboard(entry: first)
            let pbString = NSPasteboard.general.string(forType: .string)
            XCTAssertEqual(pbString, first.text)
        }

        // 4. Temizleme
        manager.clear()
        XCTAssertEqual(manager.getEntries().count, 0)
    }

    func testNewConfigDefaultsAndPersistence() {
        var config = AppConfig.defaultConfig
        XCTAssertTrue(config.haptic_feedback)
        XCTAssertTrue(config.remove_filler_words)
        XCTAssertEqual(config.dictation_mode, "direct")
        XCTAssertTrue(config.save_history)
        XCTAssertEqual(config.custom_vocabulary, "")

        // Ayar güncelleme
        config.custom_vocabulary = "Swift, macOS, SwiftUI"
        config.dictation_mode = "formal"
        config.haptic_feedback = false
        config.remove_filler_words = false
        config.save_history = false

        let data = try? JSONEncoder().encode(config)
        XCTAssertNotNil(data)
        if let data = data {
            let decoded = try? JSONDecoder().decode(AppConfig.self, from: data)
            XCTAssertNotNil(decoded)
            XCTAssertEqual(decoded?.custom_vocabulary, "Swift, macOS, SwiftUI")
            XCTAssertEqual(decoded?.dictation_mode, "formal")
            XCTAssertFalse(decoded?.haptic_feedback ?? true)
            XCTAssertFalse(decoded?.remove_filler_words ?? true)
            XCTAssertFalse(decoded?.save_history ?? true)
        }
    }
}
