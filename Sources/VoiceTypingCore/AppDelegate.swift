import Foundation
import AppKit

public class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var statusMenuItem: NSMenuItem!
    private var toggleRecordMenuItem: NSMenuItem!
    private var groqMenuItem: NSMenuItem!
    private var geminiMenuItem: NSMenuItem!
    private var holdModeMenuItem: NSMenuItem!
    private var smartModeMenuItem: NSMenuItem!
    private var toggleModeMenuItem: NSMenuItem!
    private var soundEffectsMenuItem: NSMenuItem!
    private var restoreClipboardMenuItem: NSMenuItem!
    private var muteAudioMenuItem: NSMenuItem!
    private var launchAtLoginMenuItem: NSMenuItem!
    private var triggerKeyMenuItems: [NSMenuItem] = []

    private var isTranscribing: Bool = false
    private var isFinishingRecord: Bool = false
    private var postRollWorkItem: DispatchWorkItem?
    private var currentLiveSession: LiveGeminiStreamSession?
    private var lastRecordedAudioData: Data?
    private var revertStatusTimer: Timer?

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
            self?.refreshMenuStates()
        }

        // İzinleri başlat ve hazır olduğunda ses ve tuş dinleyicisini aktive et
        startPermissionsFlow()
    }

    private func startPermissionsFlow() {
        // 1. Önce Mikrofon İzni: Eğer henüz sorulmadıysa, doğrudan native macOS sistem diyaloğu açılır.
        // Kullanıcı "İzin Ver" (Allow) dediğinde otomatik onaylanır, ayarlar penceresi açılmaz.
        PermissionManager.shared.requestMicrophonePermission { [weak self] micGranted in
            print("[AppDelegate] Mikrofon izni durumu: \(micGranted)")

            // 2. Erişilebilirlik İzni Kontrolü
            DispatchQueue.main.async {
                self?.checkAccessibilityAndActivate()
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
            }
        }
    }

    private func buildMenu() {
        let menu = NSMenu()

        // 1. Durum Satırı
        statusMenuItem = NSMenuItem(title: readyMenuText, action: nil, keyEquivalent: "")
        statusMenuItem.isEnabled = false
        menu.addItem(statusMenuItem)

        // 1b. Doğrudan Kayıt Başlat / Bitir Menü Öğesi
        toggleRecordMenuItem = NSMenuItem(title: "Sesle Yazmayı Başlat", action: #selector(toggleRecordAction), keyEquivalent: "r")
        toggleRecordMenuItem.target = self
        menu.addItem(toggleRecordMenuItem)

        menu.addItem(NSMenuItem.separator())

        // 2. Ayarlar Penceresi (Temiz Apple HIG standardı, çift ikon önlendi)
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
        geminiMenuItem = NSMenuItem(title: "Google Gemini Live (Canlı Akış)", action: #selector(selectGeminiProvider), keyEquivalent: "")
        geminiMenuItem.target = self
        providerMenu.addItem(geminiMenuItem)

        groqMenuItem = NSMenuItem(title: "Groq Whisper (whisper-large-v3)", action: #selector(selectGroqProvider), keyEquivalent: "")
        groqMenuItem.target = self
        providerMenu.addItem(groqMenuItem)

        let providerParent = NSMenuItem(title: "Sağlayıcı", action: nil, keyEquivalent: "")
        providerParent.submenu = providerMenu
        menu.addItem(providerParent)

        menu.addItem(NSMenuItem.separator())

        // 6. Tercihler (Checkmark Seçenekleri)
        soundEffectsMenuItem = NSMenuItem(title: "Ses Efektleri", action: #selector(toggleSoundEffects), keyEquivalent: "")
        soundEffectsMenuItem.target = self
        menu.addItem(soundEffectsMenuItem)

        muteAudioMenuItem = NSMenuItem(title: "Konuşurken Medyayı Sustur", action: #selector(toggleMuteSystemAudio), keyEquivalent: "")
        muteAudioMenuItem.target = self
        menu.addItem(muteAudioMenuItem)

        restoreClipboardMenuItem = NSMenuItem(title: "Panoyu Geri Yükle", action: #selector(toggleRestoreClipboard), keyEquivalent: "")
        restoreClipboardMenuItem.target = self
        menu.addItem(restoreClipboardMenuItem)

        launchAtLoginMenuItem = NSMenuItem(title: "Başlangıçta Otomatik Çalıştır", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        launchAtLoginMenuItem.target = self
        menu.addItem(launchAtLoginMenuItem)

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
        groqMenuItem.state = (cfg.provider.lowercased() == "groq") ? .on : .off
        geminiMenuItem.state = (cfg.provider.lowercased() == "gemini") ? .on : .off

        holdModeMenuItem.state = (cfg.trigger_mode.lowercased() == "hold") ? .on : .off
        smartModeMenuItem.state = (cfg.trigger_mode.lowercased() == "smart") ? .on : .off
        toggleModeMenuItem.state = (cfg.trigger_mode.lowercased() == "toggle") ? .on : .off

        for item in triggerKeyMenuItems {
            item.state = (item.tag == cfg.trigger_key) ? .on : .off
        }

        soundEffectsMenuItem.state = cfg.play_sounds ? .on : .off
        restoreClipboardMenuItem.state = cfg.restore_clipboard ? .on : .off
        muteAudioMenuItem.state = cfg.mute_system_audio ? .on : .off
        launchAtLoginMenuItem.state = LaunchAtLoginManager.shared.isEnabled ? .on : .off

        SoundManager.shared.isEnabled = cfg.play_sounds

        if let button = statusItem.button {
            button.toolTip = readyToolTip
            button.image = getWaveformIcon()
            button.title = ""
        }
        statusMenuItem.title = readyMenuText
        toggleRecordMenuItem.title = (AudioRecorder.shared.isRecording || isFinishingRecord) ? "Kaydı Bitir ve Deşifre Et" : "Sesle Yazmayı Başlat"
    }

    @objc private func toggleRecordAction() {
        if AudioRecorder.shared.isRecording || isFinishingRecord {
            handleRecordStop(duration: 1.0)
        } else {
            handleRecordStart()
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

            // Menü çubuğundaki sabit premium waveform ikonu bozulmaz;
            // yalnızca açılan menü içerisindeki durum metni güncellenir.
            self.statusMenuItem.title = menuText
            self.toggleRecordMenuItem.title = (AudioRecorder.shared.isRecording || self.isFinishingRecord) ? "⏹️ Kaydı Bitir ve Deşifre Et" : "🎙️ Sesle Yazmayı Başlat (Kayıt)"

            if let delay = revertAfter {
                self.revertStatusTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
                    guard let self = self else { return }
                    self.statusMenuItem.title = self.readyMenuText
                    self.toggleRecordMenuItem.title = "🎙️ Sesle Yazmayı Başlat (Kayıt)"
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

        let geminiModel = config.gemini_model.lowercased()
        let isGeminiLive = (config.provider.lowercased() == "gemini") &&
                           (geminiModel.isEmpty || geminiModel.contains("gemini-3.5-transcribe-live")) &&
                           !config.gemini_api_key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

        var started = false
        if isGeminiLive {
            print("[AppDelegate] Sağlayıcı: Google Gemini Live (gemini-3.5-transcribe-live) canlı akış oturumu başlatılıyor...")
            let session = Transcriber.shared.startLiveGeminiSession(
                config: config,
                onInterim: nil,
                completion: { [weak self] result in
                    self?.handleTranscriptionResult(result: result, config: config)
                }
            )
            self.currentLiveSession = session
            started = AudioRecorder.shared.start { [weak self] chunk in
                self?.currentLiveSession?.sendAudioChunk(chunk)
            }
        } else {
            print("[AppDelegate] Sağlayıcı: \(config.provider) (\(config.provider == "gemini" ? config.gemini_model : config.groq_model)) ses kaydı başlatılıyor...")
            self.currentLiveSession = nil
            started = AudioRecorder.shared.start()
        }

        if started {
            SoundManager.shared.playStart()
            if config.mute_system_audio {
                SystemAudioManager.shared.muteForDictation(delay: 0.15)
            }
            setStatus(title: "🔴 Dinliyor...", menuText: "Durum: Dinleniyor (Konuşun)...")
            RecordingHUD.shared.showRecording()
        } else {
            currentLiveSession?.cancel()
            currentLiveSession = nil
            lastRecordedAudioData = nil
            SystemAudioManager.shared.restoreAfterDictation()
            SoundManager.shared.playCancel()
            setStatus(title: "⚠️ Hata", menuText: "Durum: Mikrofon Başlatılamadı!", revertAfter: 2.0)
            RecordingHUD.shared.showError(message: "Mikrofon Başlatılamadı")
        }
    }

    private func handleRecordStop(duration: Double) {
        let config = ConfigManager.shared.config

        guard AudioRecorder.shared.isRecording, !isFinishingRecord, !isTranscribing else { return }

        // Çok kısa basma - kazara dokunma
        guard duration >= config.min_record_duration else {
            currentLiveSession?.cancel()
            currentLiveSession = nil
            lastRecordedAudioData = nil
            SystemAudioManager.shared.restoreAfterDictation()
            _ = AudioRecorder.shared.stop()
            RecordingHUD.shared.dismiss(animated: true)
            setStatus(title: "🎙️", menuText: readyMenuText)
            return
        }

        // Kullanıcı arayüzünde anında ve akıcı geri bildirim: HUD ve menü durumunu deşifre moduna al
        isFinishingRecord = true
        setStatus(title: "⏳ Yazıyor...", menuText: "Durum: Deşifre Ediliyor...")
        RecordingHUD.shared.showTranscribing()

        // Akustik ve Nöromüsküler Uzatma Penceresi (Post-Roll Grace Period: 280ms):
        // Kullanıcı konuşmayı bitirdiği anda tuşu bıraksa dahi, son hecelerin / son 1-2 kelimenin
        // ve CoreAudio donanım tamponundaki seslerin eksiksiz alınması için mikrofonu 280ms daha dinle.
        postRollWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self = self, self.isFinishingRecord else { return }
            self.isFinishingRecord = false

            // Mikrofon kaydını durdur ve kalan tüm PCM verisini akıt
            let (data, actualDuration) = AudioRecorder.shared.stop()

            // Mikrofon sustuktan sonra arka plan medyasını (müzik vb.) geri aç ve bitiş sesini çal
            SystemAudioManager.shared.restoreAfterDictation()
            SoundManager.shared.playStop()

            guard actualDuration >= config.min_record_duration, let audioData = data, !audioData.isEmpty else {
                // Sessizlik veya ses alınamadı
                self.currentLiveSession?.cancel()
                self.currentLiveSession = nil
                self.lastRecordedAudioData = nil
                RecordingHUD.shared.dismiss(animated: true)
                self.setStatus(title: "🎙️", menuText: self.readyMenuText)
                return
            }

            self.lastRecordedAudioData = audioData

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

        self.postRollWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.28, execute: workItem)
    }

    private func handleTranscriptionResult(result: TranscriptionResult, config: AppConfig) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }

            if result.success {
                self.isTranscribing = false
                self.currentLiveSession = nil
                self.lastRecordedAudioData = nil

                print("[Deşifre Başarılı] [\(result.provider.uppercased()) - \(result.model)] (\(String(format: "%.2f", result.latency))s): \"\(result.text)\"")

                if !result.text.isEmpty {
                    TextInjector.shared.paste(
                        text: result.text,
                        restoreClipboard: config.restore_clipboard,
                        pasteDelayMs: config.paste_delay_ms
                    )
                    SoundManager.shared.playSuccess()
                    RecordingHUD.shared.showSuccess(text: "Yapıştırıldı")
                    self.setStatus(
                        title: "✅",
                        menuText: "Durum: Yapıştırıldı (\(String(format: "%.2f", result.latency))s)",
                        revertAfter: 1.5
                    )
                } else {
                    RecordingHUD.shared.dismiss(animated: true)
                    self.setStatus(title: "🎙️", menuText: self.readyMenuText)
                }
            } else {
                let err = result.error ?? ""
                let isQuota = err.contains("quota") || err.contains("exceeded") || err.contains("429")
                if !isQuota, let fallbackAudio = self.lastRecordedAudioData {
                    // WebSocket ağ/bağlantı kopması durumunda REST fallback ile kurtar
                    self.lastRecordedAudioData = nil
                    self.currentLiveSession = nil
                    print("[GeminiLive] WebSocket bağlantısı kesildi, REST API ile kurtarılıyor...")
                    self.setStatus(title: "⏳ Yeniden deneniyor...", menuText: "Durum: REST ile deneniyor...")
                    Transcriber.shared.transcribeGemini(audioData: fallbackAudio, config: config) { [weak self] restResult in
                        self?.handleTranscriptionResult(result: restResult, config: config)
                    }
                    return
                }

                self.isTranscribing = false
                self.currentLiveSession = nil
                self.lastRecordedAudioData = nil
                SoundManager.shared.playCancel()
                RecordingHUD.shared.showError(message: "Deşifre Hatası")
                let errMsg = result.error ?? "Bilinmeyen hata"
                self.setStatus(title: "⚠️ Hata", menuText: "Hata: \(errMsg)", revertAfter: 3.0)
            }
        }
    }

    private func handleCancel() {
        postRollWorkItem?.cancel()
        postRollWorkItem = nil
        isFinishingRecord = false
        currentLiveSession?.cancel()
        currentLiveSession = nil
        lastRecordedAudioData = nil
        SystemAudioManager.shared.restoreAfterDictation()
        AudioRecorder.shared.cancel()
        Transcriber.shared.cancel()
        isTranscribing = false
        SoundManager.shared.playCancel()
        RecordingHUD.shared.dismiss(animated: true)
        setStatus(title: "❌", menuText: "Durum: İptal Edildi", revertAfter: 1.5)
    }

    // MARK: - Menü Eylemleri

    @objc private func openSettings() {
        SettingsWindowController.shared.showWindow(nil)
    }

    @objc private func selectGroqProvider() {
        ConfigManager.shared.update { $0.provider = "groq" }
        refreshMenuStates()
    }

    @objc private func selectGeminiProvider() {
        ConfigManager.shared.update { $0.provider = "gemini" }
        refreshMenuStates()
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

    @objc private func selectTriggerKeyAction(_ sender: NSMenuItem) {
        let code = sender.tag
        ConfigManager.shared.update { $0.trigger_key = code }
        KeyListener.shared.resetState()
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
        KeyListener.shared.stop()
        AudioRecorder.shared.cancel()
        RecordingHUD.shared.dismiss(animated: false)
        NSApplication.shared.terminate(nil)
    }
}
