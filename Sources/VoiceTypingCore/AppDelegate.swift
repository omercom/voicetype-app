import Foundation
import AppKit

public class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var statusMenuItem: NSMenuItem?
    private var toggleRecordMenuItem: NSMenuItem?
    private var appleMenuItem: NSMenuItem!
    private var groqMenuItem: NSMenuItem!
    private var geminiMenuItem: NSMenuItem!
    private var holdModeMenuItem: NSMenuItem!
    private var smartModeMenuItem: NSMenuItem!
    private var toggleModeMenuItem: NSMenuItem!
    private var soundEffectsMenuItem: NSMenuItem!
    private var restoreClipboardMenuItem: NSMenuItem?
    private var muteAudioMenuItem: NSMenuItem!
    private var pauseMediaMenuItem: NSMenuItem!
    private var launchAtLoginMenuItem: NSMenuItem!
    private var triggerKeyMenuItems: [NSMenuItem] = []

    // Geçmiş & Gelişmiş Özellikler
    private var historyParentMenuItem: NSMenuItem!
    private var historyMenu: NSMenu!
    private var hapticMenuItem: NSMenuItem!
    private var fillerWordsMenuItem: NSMenuItem!
    private var saveHistoryMenuItem: NSMenuItem!
    private var onlyInTextFieldsMenuItem: NSMenuItem!

    private var isTranscribing: Bool = false
    private var isFinishingRecord: Bool = false
    private var activeTargetContext: TargetContext?
    private var activeAccessibilityLease: TargetAppAccessibilityLease?
    private var recoverAudioMenuItem: NSMenuItem?
    private var postRollWorkItem: DispatchWorkItem?
    private var currentLiveSession: (any LiveStreamSession)?
    private var lastRecordedAudioData: Data?
    private var revertStatusTimer: Timer?
    private var isExplicitQuit: Bool = false

    public override init() {
        super.init()
    }

    private var readyMenuText: String {
        let keyName = TriggerKeyOption.shortName(for: ConfigManager.shared.config.trigger_key)
        return "Durum: Hazır (\(keyName) Tuşuna Basın)"
    }

    private var readyToolTip: String {
        let keyName = TriggerKeyOption.shortName(for: ConfigManager.shared.config.trigger_key)
        return "Voice Typing (\(keyName) ile Sesle Yazma)"
    }

    public func applicationDidFinishLaunching(_ notification: Notification) {
        // Sistem kapanışı / oturum kapatma durumunda temiz çıkışa izin ver
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.willPowerOffNotification, object: nil, queue: .main) { [weak self] _ in
            self?.isExplicitQuit = true
        }

        // Menu Bar Status Item Oluştur (Sabit premium ses dalgası ikonu)
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = getWaveformIcon()
            button.imagePosition = .imageOnly
            button.title = ""
            button.toolTip = readyToolTip
        }

        buildMenu()

        // Ayarlar güncellendiğinde menüyü yenile
        SettingsWindowController.shared.onConfigUpdated = { [weak self] in
            KeyListener.shared.updateTriggerKeyConfiguration()
            self?.refreshMenuStates()
        }

        // Dikte geçmişi güncellendiğinde menüyü yenile
        DictationHistoryManager.shared.onHistoryUpdated = { [weak self] in
            self?.refreshHistoryMenu()
        }

        // İzinleri başlat ve hazır olduğunda ses ve tuş dinleyicisini aktive et
        startPermissionsFlow()
    }

    private func startPermissionsFlow() {
        // 1. Önce Mikrofon İzni: Eğer henüz sorulmadıysa, doğrudan native macOS sistem diyaloğu açılır.
        // Kullanıcı "İzin Ver" (Allow) dediğinde otomatik onaylanır, ayarlar penceresi açılmaz.
        PermissionManager.shared.requestMicrophonePermission { [weak self] micGranted in
            print("[AppDelegate] Mikrofon izni durumu: \(micGranted)")

            // 2. İkinci Olarak Konuşma Tanıma İzni (Apple Speech): İlk kurulumda mikrofon hemen ardından istenir
            PermissionManager.shared.requestSpeechRecognitionPermission { speechGranted in
                print("[AppDelegate] Konuşma tanıma izni durumu: \(speechGranted)")

                // 3. Erişilebilirlik İzni Kontrolü
                DispatchQueue.main.async {
                    self?.checkAccessibilityAndActivate()
                }
            }
        }
    }

    private func checkAccessibilityAndActivate() {
        if AXIsProcessTrusted() {
            // Her iki izin de tam! Sıfır pencere açılarak sessizce ve hızla hazır moda geçilir
            print("[AppDelegate] ✅ Tüm izinler onaylı. Voice Typing aktif edildi.")
            setupKeyListener()
            SoundManager.shared.playStartup()
            refreshMenuStates()
        } else {
            // Erişilebilirlik izni eksikse, Sistem Ayarları'nı kapatmayan ve izin verilince otomatik kapanan minimal pencereyi göster
            print("[AppDelegate] ⚠️ Erişilebilirlik izni bekleniyor, yönlendirici açılıyor...")
            AccessibilityPromptController.shared.showPrompt { [weak self] in
                print("[AppDelegate] 🎉 Erişilebilirlik izni verildi! Sistem başlatılıyor.")
                self?.setupKeyListener()
                SoundManager.shared.playStartup()
                self?.refreshMenuStates()

                // İzinler tamamlandığında doğrudan Ayarlar penceresindeki İzinler sekmesine git
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    SettingsWindowController.shared.showWindow(nil)
                    SettingsWindowController.shared.selectTab(index: 2) // İzinler sekmesi
                }
            }
        }
    }

    private func buildMenu() {
        let menu = NSMenu()

        // 1. Ayarlar Penceresi (Temiz Apple HIG standardı, çift ikon önlendi)
        let settingsItem = NSMenuItem(title: "Ayarlar...", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        settingsItem.image = nil
        menu.addItem(settingsItem)

        menu.addItem(NSMenuItem.separator())

        // 3. Tetikleyici Tuş Submenu
        let keyMenu = NSMenu()
        let quickKeys: [(Int, String)] = [
            (54, "Sağ Command (Right ⌘)"),
            (58, "Sol Option (Left ⌥)"),
            (61, "Sağ Option (Right ⌥)"),
            (62, "Sağ Control (Right ⌃)"),
            (63, "Fn / Globe (fn)")
        ]
        triggerKeyMenuItems.removeAll()
        for (code, label) in quickKeys {
            let item = NSMenuItem(title: label, action: #selector(selectTriggerKeyAction(_:)), keyEquivalent: "")
            item.tag = code
            item.target = self
            keyMenu.addItem(item)
            triggerKeyMenuItems.append(item)
        }
        keyMenu.addItem(NSMenuItem.separator())
        let customizeItem = NSMenuItem(title: "Özel Tuş Ata...", action: #selector(openSettingsShortcutTab), keyEquivalent: "")
        customizeItem.target = self
        keyMenu.addItem(customizeItem)

        let keyParent = NSMenuItem(title: "Tetikleyici Tuş", action: nil, keyEquivalent: "")
        keyParent.submenu = keyMenu
        menu.addItem(keyParent)

        // 4. Tetikleme Modu Submenu
        let modeMenu = NSMenu()
        holdModeMenuItem = NSMenuItem(title: "Basılı Tut (Push-to-Talk)", action: #selector(selectHoldMode), keyEquivalent: "")
        holdModeMenuItem.target = self
        modeMenu.addItem(holdModeMenuItem)

        smartModeMenuItem = NSMenuItem(title: "Akıllı Hibrit (Smart)", action: #selector(selectSmartMode), keyEquivalent: "")
        smartModeMenuItem.target = self
        modeMenu.addItem(smartModeMenuItem)

        toggleModeMenuItem = NSMenuItem(title: "Aç / Kapa (Toggle)", action: #selector(selectToggleMode), keyEquivalent: "")
        toggleModeMenuItem.target = self
        modeMenu.addItem(toggleModeMenuItem)

        let modeParent = NSMenuItem(title: "Tetikleme Modu", action: nil, keyEquivalent: "")
        modeParent.submenu = modeMenu
        menu.addItem(modeParent)

        // 5. Sağlayıcı Submenu
        let providerMenu = NSMenu()
        appleMenuItem = NSMenuItem(title: "🍎 Apple Speech (0 Kota / API Keysiz)", action: #selector(selectAppleProvider), keyEquivalent: "")
        appleMenuItem.target = self
        providerMenu.addItem(appleMenuItem)

        geminiMenuItem = NSMenuItem(title: "✨ Google Gemini Live (Canlı Akış)", action: #selector(selectGeminiProvider), keyEquivalent: "")
        geminiMenuItem.target = self
        providerMenu.addItem(geminiMenuItem)

        groqMenuItem = NSMenuItem(title: "⚡ Groq Whisper (whisper-large-v3)", action: #selector(selectGroqProvider), keyEquivalent: "")
        groqMenuItem.target = self
        providerMenu.addItem(groqMenuItem)

        let providerParent = NSMenuItem(title: "Sağlayıcı", action: nil, keyEquivalent: "")
        providerParent.submenu = providerMenu
        menu.addItem(providerParent)

        // 5b. Son Dikteler (History) Submenu
        historyMenu = NSMenu()
        historyParentMenuItem = NSMenuItem(title: "Son Dikteler", action: nil, keyEquivalent: "")
        historyParentMenuItem.submenu = historyMenu
        menu.addItem(historyParentMenuItem)
        refreshHistoryMenu()

        menu.addItem(NSMenuItem.separator())

        // 6. Tercihler (Checkmark Seçenekleri)
        soundEffectsMenuItem = NSMenuItem(title: "Ses Efektleri", action: #selector(toggleSoundEffects), keyEquivalent: "")
        soundEffectsMenuItem.target = self
        menu.addItem(soundEffectsMenuItem)

        hapticMenuItem = NSMenuItem(title: "Dokunsal Titreşim (Trackpad)", action: #selector(toggleHapticFeedback), keyEquivalent: "")
        hapticMenuItem.target = self
        menu.addItem(hapticMenuItem)

        fillerWordsMenuItem = NSMenuItem(title: "Dolgu Kelimelerini Temizle", action: #selector(toggleFillerWords), keyEquivalent: "")
        fillerWordsMenuItem.target = self
        menu.addItem(fillerWordsMenuItem)

        pauseMediaMenuItem = NSMenuItem(title: "Konuşurken Medyayı Duraklat (Play/Pause)", action: #selector(togglePauseMediaPlayback), keyEquivalent: "")
        pauseMediaMenuItem.target = self
        menu.addItem(pauseMediaMenuItem)

        muteAudioMenuItem = NSMenuItem(title: "Konuşurken Medyayı Sustur", action: #selector(toggleMuteSystemAudio), keyEquivalent: "")
        muteAudioMenuItem.target = self
        menu.addItem(muteAudioMenuItem)

        saveHistoryMenuItem = NSMenuItem(title: "Dikte Geçmişini Kaydet", action: #selector(toggleSaveHistory), keyEquivalent: "")
        saveHistoryMenuItem.target = self
        menu.addItem(saveHistoryMenuItem)

        onlyInTextFieldsMenuItem = NSMenuItem(title: "Sadece Yazı Alanında Çalıştır", action: #selector(toggleOnlyInTextFields), keyEquivalent: "")
        onlyInTextFieldsMenuItem.target = self
        menu.addItem(onlyInTextFieldsMenuItem)

        launchAtLoginMenuItem = NSMenuItem(title: "Başlangıçta Otomatik Çalıştır", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        launchAtLoginMenuItem.target = self
        menu.addItem(launchAtLoginMenuItem)

        menu.addItem(NSMenuItem.separator())

        // Kurtarma Ses Deposu (Dictation Recovery)
        recoverAudioMenuItem = NSMenuItem(title: "💾 Son Sesi Masaüstüne Kaydet", action: #selector(exportRecoveredAudioAction), keyEquivalent: "")
        recoverAudioMenuItem?.target = self
        if let recItem = recoverAudioMenuItem {
            menu.addItem(recItem)
        }

        menu.addItem(NSMenuItem.separator())

        // 7. Çıkış
        let quitItem = NSMenuItem(title: "Çıkış", action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu
        refreshMenuStates()
    }

    private func refreshMenuStates() {
        let cfg = ConfigManager.shared.config
        appleMenuItem.state = (cfg.provider.lowercased() == "apple") ? .on : .off
        geminiMenuItem.state = (cfg.provider.lowercased() == "gemini") ? .on : .off
        groqMenuItem.state = (cfg.provider.lowercased() == "groq") ? .on : .off

        holdModeMenuItem.state = (cfg.trigger_mode.lowercased() == "hold") ? .on : .off
        smartModeMenuItem.state = (cfg.trigger_mode.lowercased() == "smart") ? .on : .off
        toggleModeMenuItem.state = (cfg.trigger_mode.lowercased() == "toggle") ? .on : .off

        for item in triggerKeyMenuItems {
            item.state = (item.tag == cfg.trigger_key) ? .on : .off
        }

        soundEffectsMenuItem.state = cfg.play_sounds ? .on : .off
        hapticMenuItem?.state = cfg.haptic_feedback ? .on : .off
        fillerWordsMenuItem?.state = cfg.remove_filler_words ? .on : .off
        pauseMediaMenuItem.state = cfg.pause_media_playback ? .on : .off
        muteAudioMenuItem.state = cfg.mute_system_audio ? .on : .off
        saveHistoryMenuItem?.state = cfg.save_history ? .on : .off
        onlyInTextFieldsMenuItem?.state = cfg.only_in_text_fields ? .on : .off
        restoreClipboardMenuItem?.state = cfg.restore_clipboard ? .on : .off
        launchAtLoginMenuItem.state = LaunchAtLoginManager.shared.isEnabled ? .on : .off

        SoundManager.shared.isEnabled = cfg.play_sounds

        if let button = statusItem.button {
            button.toolTip = readyToolTip
            button.image = getWaveformIcon()
            button.title = ""
        }
        statusMenuItem?.title = readyMenuText
        toggleRecordMenuItem?.title = (AudioRecorder.shared.isRecording || isFinishingRecord) ? "Kaydı Bitir ve Deşifre Et" : "Sesle Yazmayı Başlat"
    }

    @objc private func toggleRecordAction() {
        if AudioRecorder.shared.isRecording || isFinishingRecord {
            handleRecordStop(duration: 1.0)
        } else {
            handleRecordStart()
        }
    }

    @objc private func exportRecoveredAudioAction() {
        if let savedURL = DictationRecoveryAudioStore.shared.exportLatestRecoveryToDesktop() {
            RecordingHUD.shared.showSuccess(text: "Ses Masaüstüne Kaydedildi")
            let alert = NSAlert()
            alert.messageText = "Ses Başarıyla Kurtarıldı"
            alert.informativeText = "Son ses kaydınız Masaüstünüze kaydedildi:\n\(savedURL.lastPathComponent)"
            alert.alertStyle = .informational
            alert.addButton(withTitle: "Tamam")
            alert.runModal()
        } else {
            RecordingHUD.shared.showError(message: "Kurtarılacak Ses Yok")
        }
    }

    private func setupKeyListener() {
        let listener = KeyListener.shared

        listener.isBusy = { [weak self] in
            guard let self = self else { return false }
            return self.isTranscribing || self.isFinishingRecord
        }

        listener.onStart = { [weak self] in
            self?.handleRecordStart()
        }

        listener.onStop = { [weak self] duration in
            self?.handleRecordStop(duration: duration)
        }

        listener.onCancel = { [weak self] in
            self?.handleCancel()
        }

        listener.start()
    }

    private func setStatus(title: String, menuText: String, revertAfter: TimeInterval? = nil) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.revertStatusTimer?.invalidate()
            self.revertStatusTimer = nil

            // Menü çubuğundaki sabit premium waveform ikonu bozulmaz.
            self.statusMenuItem?.title = menuText
            self.toggleRecordMenuItem?.title = (AudioRecorder.shared.isRecording || self.isFinishingRecord) ? "⏹️ Kaydı Bitir ve Deşifre Et" : "🎙️ Sesle Yazmayı Başlat (Kayıt)"

            if let delay = revertAfter {
                self.revertStatusTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
                    guard let self = self else { return }
                    self.statusMenuItem?.title = self.readyMenuText
                    self.toggleRecordMenuItem?.title = "🎙️ Sesle Yazmayı Başlat (Kayıt)"
                }
            }
        }
    }

    /// Menü çubuğu için Apple SF Symbols uyumlu, karanlık/aydınlık temaya otomatik uyum sağlayan (isTemplate)
    /// sabit ve zarif ses dalgası (waveform) ikonu döner.
    private func getWaveformIcon() -> NSImage {
        if let image = NSImage(systemSymbolName: "waveform", accessibilityDescription: "Voice Typing") {
            image.isTemplate = true
            return image
        }

        // Vektörel yedek: 5 çubuklu zarif ses dalgası ikonu
        let size = NSSize(width: 18, height: 16)
        let image = NSImage(size: size, flipped: false) { rect in
            let barWidth: CGFloat = 2.0
            let heights: [CGFloat] = [6.0, 12.0, 15.0, 9.0, 4.5]
            let spacing: CGFloat = 1.5
            let totalW = CGFloat(heights.count) * barWidth + CGFloat(heights.count - 1) * spacing
            let startX = (rect.width - totalW) / 2.0

            NSColor.black.setFill()
            for (i, h) in heights.enumerated() {
                let x = startX + CGFloat(i) * (barWidth + spacing)
                let y = (rect.height - h) / 2.0
                let barRect = NSRect(x: x, y: y, width: barWidth, height: h)
                let path = NSBezierPath(roundedRect: barRect, xRadius: 1.0, yRadius: 1.0)
                path.fill()
            }
            return true
        }
        image.isTemplate = true
        return image
    }

    // MARK: - Kayıt ve Deşifre Döngüsü

    private func handleRecordStart() {
        guard !isTranscribing, !isFinishingRecord else { return }

        let config = ConfigManager.shared.config

        // 0. Hedef Metin Alanı Doğrulaması ve Kilidi (Target-Lock)
        if let target = TargetInputManager.shared.captureTargetContext() {
            self.activeTargetContext = target
            print("[AppDelegate] 🎯 Hedef yazı alanı kilitlendi: \(target.appName) (\(target.role)) [PID: \(target.pid)]")
        } else if config.only_in_text_fields {
            print("[AppDelegate] ⚠️ Odakta geçerli bir yazı alanı bulunamadı. Kural gereği kayıt başlatılmadı.")
            SoundManager.shared.playCancel()
            HapticManager.shared.playCancel()
            RecordingHUD.shared.showError(message: "Yazı alanı seçili değil")
            setStatus(title: "⚠️", menuText: "Durum: Yazı Alanı Seçili Değil", revertAfter: 2.0)
            return
        } else {
            if let frontApp = NSWorkspace.shared.frontmostApplication {
                let appRef = AXUIElementCreateApplication(frontApp.processIdentifier)
                self.activeTargetContext = TargetContext(
                    pid: frontApp.processIdentifier,
                    bundleIdentifier: frontApp.bundleIdentifier ?? "",
                    appName: frontApp.localizedName ?? "",
                    runningApp: frontApp,
                    element: appRef,
                    window: nil,
                    role: "AXFallbackApp"
                )
            } else {
                self.activeTargetContext = nil
            }
        }

        let isApple = (config.provider.lowercased() == "apple")
        let geminiModel = config.gemini_model.lowercased()
        let isGeminiLive = (config.provider.lowercased() == "gemini") &&
                           (geminiModel.isEmpty || geminiModel.contains("gemini-3.5-transcribe-live")) &&
                           !config.gemini_api_key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

        var started = false
        if isApple {
            print("[AppDelegate] Sağlayıcı: Apple Speech (Yerel Canlı Akış) başlatılıyor...")
            let session = Transcriber.shared.startLiveAppleSpeechSession(
                config: config,
                onInterim: { interimText in
                    RecordingHUD.shared.updateInterimText(interimText)
                },
                completion: { [weak self] result in
                    self?.handleTranscriptionResult(result: result, config: config)
                }
            )
            self.currentLiveSession = session
            started = AudioRecorder.shared.start { [weak self] chunk in
                self?.currentLiveSession?.sendAudioChunk(chunk)
            }
        } else if isGeminiLive {
            print("[AppDelegate] Sağlayıcı: Google Gemini Live (gemini-3.5-transcribe-live) canlı akış oturumu başlatılıyor...")
            let session = Transcriber.shared.startLiveGeminiSession(
                config: config,
                onInterim: { interimText in
                    RecordingHUD.shared.updateInterimText(interimText)
                },
                completion: { [weak self] result in
                    self?.handleTranscriptionResult(result: result, config: config)
                }
            )
            self.currentLiveSession = session
            started = AudioRecorder.shared.start { [weak self] chunk in
                self?.currentLiveSession?.sendAudioChunk(chunk)
            }
        } else {
            let modelInfo: String = (config.provider.lowercased() == "gemini") ? config.gemini_model : config.groq_model
            print("[AppDelegate] Sağlayıcı: \(config.provider) (\(modelInfo)) ses kaydı başlatılıyor...")
            self.currentLiveSession = nil
            started = AudioRecorder.shared.start()
        }

        if let target = activeTargetContext {
            activeAccessibilityLease = ChromiumAccessibilityController.shared.beginObservation(
                processIdentifier: target.pid,
                bundleIdentifier: target.bundleIdentifier
            )
        }

        if started {
            SoundManager.shared.playStart()
            HapticManager.shared.playStart()
            BackgroundAudioController.shared.handleDictationStarted(config: config)
            if config.mute_system_audio {
                SystemAudioManager.shared.muteForDictation(delay: 0.15)
            }
            setStatus(title: "🔴 Dinliyor...", menuText: "Durum: Dinleniyor (Konuşun)...")
            RecordingHUD.shared.showRecording()
        } else {
            activeAccessibilityLease?.end()
            activeAccessibilityLease = nil
            currentLiveSession?.cancel()
            currentLiveSession = nil
            lastRecordedAudioData = nil
            SystemAudioManager.shared.restoreAfterDictation()
            BackgroundAudioController.shared.handleDictationEnded(config: config)
            SoundManager.shared.playCancel()
            HapticManager.shared.playCancel()
            setStatus(title: "⚠️ Hata", menuText: "Durum: Mikrofon Başlatılamadı!", revertAfter: 2.0)
            RecordingHUD.shared.showError(message: "Mikrofon Başlatılamadı")
        }
    }

    private func handleRecordStop(duration: Double) {
        let config = ConfigManager.shared.config

        guard AudioRecorder.shared.isRecording, !isFinishingRecord, !isTranscribing else { return }

        // Çok kısa basma - kazara dokunma
        guard duration >= config.min_record_duration else {
            activeAccessibilityLease?.end()
            activeAccessibilityLease = nil
            activeTargetContext = nil
            currentLiveSession?.cancel()
            currentLiveSession = nil
            lastRecordedAudioData = nil
            SystemAudioManager.shared.restoreAfterDictation()
            BackgroundAudioController.shared.handleDictationEnded(config: config)
            _ = AudioRecorder.shared.stop()
            RecordingHUD.shared.dismiss(animated: true)
            setStatus(title: "🎙️", menuText: readyMenuText)
            return
        }

        // Kullanıcı arayüzünde anında ve akıcı geri bildirim: HUD ve menü durumunu deşifre moduna al
        isFinishingRecord = true
        setStatus(title: "⏳ Yazıyor...", menuText: "Durum: Deşifre Ediliyor...")
        RecordingHUD.shared.showTranscribing()

        postRollWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self = self, self.isFinishingRecord else { return }
            self.isFinishingRecord = false

            // Mikrofon kaydını durdur ve kalan tüm PCM verisini akıt
            let (data, actualDuration) = AudioRecorder.shared.stop()

            // Mikrofon sustuktan sonra ana ses çıkışını geri aç ve bitiş sesini çal
            SystemAudioManager.shared.restoreAfterDictation()
            SoundManager.shared.playStop()

            guard actualDuration >= config.min_record_duration, let audioData = data, !audioData.isEmpty else {
                // Sessizlik veya ses alınamadı
                self.activeAccessibilityLease?.end()
                self.activeAccessibilityLease = nil
                self.currentLiveSession?.cancel()
                self.currentLiveSession = nil
                self.lastRecordedAudioData = nil
                BackgroundAudioController.shared.handleDictationEnded(config: config)
                RecordingHUD.shared.dismiss(animated: true)
                self.setStatus(title: "🎙️", menuText: self.readyMenuText)
                return
            }

            self.lastRecordedAudioData = audioData
            DictationRecoveryAudioStore.shared.saveLastRecording(wavData: audioData)

            if let liveSession = self.currentLiveSession {
                self.isTranscribing = true
                liveSession.finishAudio()
                return
            }

            self.isTranscribing = true
            Transcriber.shared.transcribe(audioData: audioData, config: config) { [weak self] result in
                self?.handleTranscriptionResult(result: result, config: config)
            }
        }

        // Akustik ve Nöromüsküler Uzatma Penceresi (Post-Roll Grace Period):
        // Kullanıcı konuşmayı bitirdiği anda tuşu bıraksa dahi, son hecelerin / son kelimelerin
        // ve CoreAudio donanım tamponundaki seslerin eksiksiz alınması için mikrofon kısa bir süre daha dinler.
        // Canlı akışta (Gemini Live) ses anlık aktarıldığı için 100ms fazlasıyla yeterlidir.
        // Groq Whisper ve REST modellerinde ise son hecelerin tamponda kalmaması için 180ms uygulanır.
        let postRollDelay: Double = (self.currentLiveSession != nil) ? 0.10 : 0.18
        self.postRollWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + postRollDelay, execute: workItem)
    }

    private func handleTranscriptionResult(result: TranscriptionResult, config: AppConfig) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }

            self.activeAccessibilityLease?.end()
            self.activeAccessibilityLease = nil

            if result.success {
                self.isTranscribing = false
                self.currentLiveSession = nil
                self.lastRecordedAudioData = nil
                DictationRecoveryAudioStore.shared.clear()
                self.recoverAudioMenuItem?.isHidden = true

                print("[Deşifre Başarılı] [\(result.provider.uppercased()) - \(result.model)] (\(String(format: "%.2f", result.latency))s): \"\(result.text)\"")

                if !result.text.isEmpty {
                    let target = self.activeTargetContext
                    self.activeTargetContext = nil

                    let polishedText = TextPolisher.shared.polish(text: result.text, config: config, targetContext: target)
                    guard !polishedText.isEmpty else {
                        BackgroundAudioController.shared.handleDictationEnded(config: config)
                        RecordingHUD.shared.dismiss(animated: true)
                        self.setStatus(title: "🎙️", menuText: self.readyMenuText)
                        return
                    }

                    DictationHistoryManager.shared.addEntry(
                        text: polishedText,
                        provider: result.provider,
                        model: result.model
                    )

                    // Akıllı Boşluk (Smart Spacing): Ardışık diktelerde kelimelerin birbirine yapışmasını önler
                    let textToInject = TextPolisher.applySmartSpacing(polishedText)

                    TextInjector.shared.inject(
                        text: textToInject,
                        targetContext: target,
                        pasteDelayMs: config.paste_delay_ms
                    )
                    SoundManager.shared.playSuccess()
                    HapticManager.shared.playSuccess()
                    BackgroundAudioController.shared.handleDictationEnded(config: config)
                    RecordingHUD.shared.showSuccess(text: "Yapıştırıldı")
                    self.setStatus(
                        title: "✅",
                        menuText: "Durum: Yapıştırıldı (\(String(format: "%.2f", result.latency))s)",
                        revertAfter: 1.5
                    )
                } else {
                    BackgroundAudioController.shared.handleDictationEnded(config: config)
                    RecordingHUD.shared.dismiss(animated: true)
                    self.setStatus(title: "🎙️", menuText: self.readyMenuText)
                }
            } else {
                let err = result.error ?? ""
                let isQuota = err.contains("quota") || err.contains("exceeded") || err.contains("429")
                if !isQuota, let fallbackAudio = self.lastRecordedAudioData {
                    self.lastRecordedAudioData = nil
                    self.currentLiveSession = nil
                    if config.provider.lowercased() == "apple" {
                        print("[AppleSpeech] Canlı akış tamamlanamadı, yerel dosya motoru ile kurtarılıyor...")
                        Transcriber.shared.transcribeAppleSpeech(audioData: fallbackAudio, config: config) { [weak self] appleResult in
                            self?.handleTranscriptionResult(result: appleResult, config: config)
                        }
                        return
                    } else if config.provider.lowercased() == "gemini" {
                        print("[GeminiLive] WebSocket bağlantısı kesildi, REST API ile kurtarılıyor...")
                        self.setStatus(title: "⏳ Yeniden deneniyor...", menuText: "Durum: REST ile deneniyor...")
                        Transcriber.shared.transcribeGemini(audioData: fallbackAudio, config: config) { [weak self] restResult in
                            self?.handleTranscriptionResult(result: restResult, config: config)
                        }
                        return
                    }
                }

                self.isTranscribing = false
                self.currentLiveSession = nil
                self.lastRecordedAudioData = nil
                DictationRecoveryAudioStore.shared.markFailed(error: result.error ?? "Deşifre Hatası")
                self.recoverAudioMenuItem?.isHidden = false
                BackgroundAudioController.shared.handleDictationEnded(config: config)
                SoundManager.shared.playCancel()
                HapticManager.shared.playCancel()
                RecordingHUD.shared.showError(message: "Deşifre Hatası (Ses Korundu)")
                let errMsg = result.error ?? "Bilinmeyen hata"
                self.setStatus(title: "⚠️ Hata", menuText: "Hata: \(errMsg)", revertAfter: 3.0)
            }
        }
    }

    private func handleCancel() {
        activeAccessibilityLease?.end()
        activeAccessibilityLease = nil
        activeTargetContext = nil
        postRollWorkItem?.cancel()
        postRollWorkItem = nil
        isFinishingRecord = false
        currentLiveSession?.cancel()
        currentLiveSession = nil
        lastRecordedAudioData = nil
        SystemAudioManager.shared.restoreAfterDictation()
        BackgroundAudioController.shared.handleDictationEnded(config: ConfigManager.shared.config)
        AudioRecorder.shared.cancel()
        Transcriber.shared.cancel()
        isTranscribing = false
        SoundManager.shared.playCancel()
        HapticManager.shared.playCancel()
        RecordingHUD.shared.dismiss(animated: true)
        setStatus(title: "❌", menuText: "Durum: İptal Edildi", revertAfter: 1.5)
    }

    // MARK: - Menü Eylemleri

    @objc private func openSettings() {
        SettingsWindowController.shared.showWindow(nil)
    }

    @objc private func selectAppleProvider() {
        ConfigManager.shared.update { $0.provider = "apple" }
        refreshMenuStates()
        SettingsWindowController.shared.loadValues()
    }

    @objc private func selectGroqProvider() {
        ConfigManager.shared.update { $0.provider = "groq" }
        refreshMenuStates()
        SettingsWindowController.shared.loadValues()
    }

    @objc private func selectGeminiProvider() {
        ConfigManager.shared.update { $0.provider = "gemini" }
        refreshMenuStates()
        SettingsWindowController.shared.loadValues()
    }

    @objc private func selectHoldMode() {
        ConfigManager.shared.update { $0.trigger_mode = "hold" }
        refreshMenuStates()
    }

    @objc private func selectSmartMode() {
        ConfigManager.shared.update { $0.trigger_mode = "smart" }
        refreshMenuStates()
    }

    @objc private func selectToggleMode() {
        ConfigManager.shared.update { $0.trigger_mode = "toggle" }
        refreshMenuStates()
    }

    @objc private func toggleSoundEffects() {
        let current = ConfigManager.shared.config.play_sounds
        ConfigManager.shared.update { $0.play_sounds = !current }
        refreshMenuStates()
    }

    @objc private func toggleRestoreClipboard() {
        let current = ConfigManager.shared.config.restore_clipboard
        ConfigManager.shared.update { $0.restore_clipboard = !current }
        refreshMenuStates()
    }

    @objc private func togglePauseMediaPlayback() {
        let current = ConfigManager.shared.config.pause_media_playback
        ConfigManager.shared.update { $0.pause_media_playback = !current }
        refreshMenuStates()
    }

    @objc private func toggleMuteSystemAudio() {
        let current = ConfigManager.shared.config.mute_system_audio
        ConfigManager.shared.update { $0.mute_system_audio = !current }
        refreshMenuStates()
    }

    @objc private func toggleLaunchAtLogin() {
        let currentlyEnabled = LaunchAtLoginManager.shared.isEnabled
        LaunchAtLoginManager.shared.setEnabled(!currentlyEnabled)
        refreshMenuStates()
    }

    @objc private func toggleHapticFeedback() {
        let current = ConfigManager.shared.config.haptic_feedback
        ConfigManager.shared.update { $0.haptic_feedback = !current }
        refreshMenuStates()
        SettingsWindowController.shared.loadValues()
        if !current {
            HapticManager.shared.playSuccess()
        }
    }

    @objc private func toggleFillerWords() {
        let current = ConfigManager.shared.config.remove_filler_words
        ConfigManager.shared.update { $0.remove_filler_words = !current }
        refreshMenuStates()
        SettingsWindowController.shared.loadValues()
    }

    @objc private func toggleSaveHistory() {
        let current = ConfigManager.shared.config.save_history
        ConfigManager.shared.update { $0.save_history = !current }
        refreshMenuStates()
        SettingsWindowController.shared.loadValues()
    }

    @objc private func toggleOnlyInTextFields() {
        let current = ConfigManager.shared.config.only_in_text_fields
        ConfigManager.shared.update { $0.only_in_text_fields = !current }
        refreshMenuStates()
        SettingsWindowController.shared.loadValues()
    }

    private func refreshHistoryMenu() {
        guard let menu = historyMenu else { return }
        menu.removeAllItems()

        let entries = DictationHistoryManager.shared.getEntries()
        if entries.isEmpty {
            let emptyItem = NSMenuItem(title: "(Henüz dikte geçmişi yok)", action: nil, keyEquivalent: "")
            emptyItem.isEnabled = false
            menu.addItem(emptyItem)
        } else {
            for (idx, entry) in entries.enumerated() {
                let item = NSMenuItem(title: entry.menuTitle, action: #selector(historyItemClicked(_:)), keyEquivalent: "")
                item.tag = idx
                item.target = self
                item.toolTip = "\(entry.text)\n\n(Tıklayarak panoya kopyalayın)"
                menu.addItem(item)
            }
            menu.addItem(NSMenuItem.separator())
            let clearItem = NSMenuItem(title: "Geçmişi Temizle", action: #selector(clearHistoryAction), keyEquivalent: "")
            clearItem.target = self
            menu.addItem(clearItem)
        }
    }

    @objc private func historyItemClicked(_ sender: NSMenuItem) {
        let entries = DictationHistoryManager.shared.getEntries()
        guard sender.tag >= 0 && sender.tag < entries.count else { return }
        let entry = entries[sender.tag]
        DictationHistoryManager.shared.copyToClipboard(entry: entry)
        setStatus(title: "📋", menuText: "Panoya kopyalandı", revertAfter: 1.5)
    }

    @objc private func clearHistoryAction() {
        DictationHistoryManager.shared.clear()
        setStatus(title: "🗑️", menuText: "Dikte geçmişi temizlendi", revertAfter: 1.5)
    }

    @objc private func selectTriggerKeyAction(_ sender: NSMenuItem) {
        let code = sender.tag
        ConfigManager.shared.update { $0.trigger_key = code }
        KeyListener.shared.resetState()
        KeyListener.shared.updateTriggerKeyConfiguration()
        refreshMenuStates()
        SettingsWindowController.shared.loadValues()
    }

    @objc private func openSettingsShortcutTab() {
        SettingsWindowController.shared.showWindow(nil)
        SettingsWindowController.shared.selectTab(index: 2)
    }

    @objc private func testRecordAction() {
        SettingsWindowController.shared.showWindow(nil)
    }

    @objc private func quitApp() {
        isExplicitQuit = true
        KeyListener.shared.stop()
        GlobeKeySuppressor.shared.restoreOriginal()
        AudioRecorder.shared.cleanTeardown()
        SystemAudioManager.shared.restoreAfterDictation()
        BackgroundAudioController.shared.handleDictationEnded(config: ConfigManager.shared.config)
        RecordingHUD.shared.dismiss(animated: false)
        NSApplication.shared.terminate(nil)
    }

    public func applicationWillTerminate(_ notification: Notification) {
        GlobeKeySuppressor.shared.restoreOriginal()
        AudioRecorder.shared.cleanTeardown()
        SystemAudioManager.shared.restoreAfterDictation()
        BackgroundAudioController.shared.handleDictationEnded(config: ConfigManager.shared.config)
    }

    // MARK: - Dock & Görev Çubuğu Yönetimi

    public func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // Popüler macOS yardımcı uygulamaları standardı (Rectangle, 1Password, Raycast):
        // Ayarlar penceresi kapatıldığında uygulama asla sonlandırılmaz,
        // menü çubuğunda (taskbar) ve arka plan kısayol dinleyicisinde kesintisiz çalışmaya devam eder.
        return false
    }

    public func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if isExplicitQuit {
            return .terminateNow
        }

        // Kullanıcı Dock ikonuna sağ tıklayıp "Çıkış" dediğinde veya Cmd+Q yaptığında:
        // Menü çubuğundaki (taskbar) arka plan servisinin kesilmemesi için
        // yalnızca açık pencereleri kapat, uygulamayı sonlandırma.
        SettingsWindowController.shared.window?.close()
        AccessibilityPromptController.shared.window?.close()
        return .terminateCancel
    }

    public func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        NSApp.activate(ignoringOtherApps: true)
        if let accWindow = AccessibilityPromptController.shared.window, accWindow.isVisible {
            accWindow.makeKeyAndOrderFront(nil)
        } else {
            SettingsWindowController.shared.showWindow(nil)
        }
        return true
    }

    public func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let menu = NSMenu()
        let settingsItem = NSMenuItem(title: "Ayarlar...", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        menu.addItem(NSMenuItem.separator())
        let quitItem = NSMenuItem(title: "Uygulamadan Tamamen Çık", action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
        return menu
    }

    public static func updateDockVisibility(_ show: Bool) {
        DispatchQueue.main.async {
            if show {
                NSApp.setActivationPolicy(.regular)
                NSApp.activate(ignoringOtherApps: true)
            } else {
                NSApp.setActivationPolicy(.accessory)
            }
        }
    }
}
