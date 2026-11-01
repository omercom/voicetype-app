import Foundation
import AppKit

private struct DictationPermissionSnapshot {
    let accessibilityGranted: Bool
    let microphoneStatus: PermissionStatus
    let speechStatus: PermissionStatus

    func readinessMessage(for config: AppConfig) -> String? {
        guard accessibilityGranted else {
            return "Erişilebilirlik izni gerekli"
        }

        switch microphoneStatus {
        case .authorized:
            break
        case .restricted:
            return "Mikrofon erişimi kısıtlı"
        default:
            return "Mikrofon izni gerekli"
        }

        // Sağlayıcı gereksinimleri kayıt defterindeki yeteneklerden türetilir:
        // Apple Speech Konuşma Tanıma izni ister, bulut
        // sağlayıcıları ise API anahtarı. Kullanıcıya gösterilen metinler
        // önceki sürümle birebir aynı tutulmuştur.
        let descriptor = TranscriptionProviderRegistry.descriptor(for: config.provider)

        if descriptor.capabilities.contains(.requiresSpeechPermission) {
            guard speechStatus == .authorized else {
                return speechStatus == .restricted
                    ? "Apple Speech erişimi kısıtlı"
                    : "Apple Speech izni gerekli"
            }
        } else if descriptor.isMissingAPIKey(in: config) {
            return "\(descriptor.readinessShortName) API anahtarı gerekli"
        }

        if descriptor.id == "seda" {
            return SedaTranscriber.readinessMessage(language: config.language)
        }

        return nil
    }
}

public class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var statusMenuItem: NSMenuItem?
    private var toggleRecordMenuItem: NSMenuItem?
    private var appleMenuItem: NSMenuItem!
    private var groqMenuItem: NSMenuItem!
    private var geminiMenuItem: NSMenuItem!
    private var assemblyAIMenuItem: NSMenuItem!
    private var sedaMenuItem: NSMenuItem!
    private var holdModeMenuItem: NSMenuItem!
    private var smartModeMenuItem: NSMenuItem!
    private var toggleModeMenuItem: NSMenuItem!
    private var soundEffectsMenuItem: NSMenuItem!
    private var restoreClipboardMenuItem: NSMenuItem?
    private var muteAudioMenuItem: NSMenuItem!
    private var pauseMediaMenuItem: NSMenuItem!
    private var launchAtLoginMenuItem: NSMenuItem!
    private var triggerKeyMenuItems: [NSMenuItem] = []

    private let readAloud = ReadAloudController()
    private let readAloudHotKey = ReadAloudHotKey()
    private let readAloudBrowserBridge = ReadAloudBrowserBridge()
    private var readAloudStatusItem: NSMenuItem?
    private var readAloudStopItem: NSMenuItem?
    private var readAloudShortcutItem: NSMenuItem?

    // Geçmiş & Gelişmiş Özellikler
    private var historyParentMenuItem: NSMenuItem!
    private var historyMenu: NSMenu!
    private var hapticMenuItem: NSMenuItem!
    private var fillerWordsMenuItem: NSMenuItem!
    private var saveHistoryMenuItem: NSMenuItem!
    private var onlyInTextFieldsMenuItem: NSMenuItem!
    private var inputMethodMenuItem: NSMenuItem!
    private var providerParentMenuItem: NSMenuItem!

    private var isTranscribing: Bool = false
    private var isFinishingRecord: Bool = false
    private var activeTargetContext: TargetContext?
    private var activeDictationConfig: AppConfig?
    private var activeAccessibilityLease: TargetAppAccessibilityLease?
    private var recoverAudioMenuItem: NSMenuItem?
    private var postRollWorkItem: DispatchWorkItem?
    private var currentLiveSession: (any LiveStreamSession)?
    private var liveTranslation: LiveTranslationCoordinator?
    private var lastRecordedAudioData: Data?
    private var revertStatusTimer: Timer?
    private var isExplicitQuit: Bool = false
    private let recordingStartCoordinator = RecordingStartCoordinator()
    private var activeStartLatencyTrace: RecordingStartLatencyTrace?
    private var isPreparingRecord = false
    private var pendingRecordStartGeneration: UInt64 = 0
    private var deliveryGate = DictationDeliveryGate()
    private var permissionSnapshot: DictationPermissionSnapshot?

    public override init() {
        super.init()
    }

    private var readyMenuText: String {
        let config = ConfigManager.shared.config
        let keyName = TriggerKeyOption.shortName(for: config.trigger_key)
        if config.enable_translation {
            return config.trigger_key == 61
                ? "Hazır (Sağ Option: Çeviri · Normal dikte için başka tuş seçin)"
                : "Hazır (\(keyName): Dikte · Sağ Option: Çeviri)"
        }
        return "Durum: Hazır (\(keyName) Tuşuna Basın)"
    }

    private var readyToolTip: String {
        let config = ConfigManager.shared.config
        let keyName = TriggerKeyOption.shortName(for: config.trigger_key)
        if config.enable_translation {
            return config.trigger_key == 61
                ? "Sağ Option: Çeviri · Normal dikte için başka tuş seçin"
                : "\(keyName): Dikte · Sağ Option: Çeviri"
        }
        return "Voice Typing (\(keyName) ile Sesle Yazma)"
    }

    /// Recorder tamamlanan her oturum için WAV döndürür; ağ/yerel deşifreye
    /// yalnızca gerçek PCM içeren ve dijital sessizlik olmayan kayıt gönderilir.
    static func shouldSubmitRecording(_ data: Data?) -> Bool {
        guard let data = data, data.count > 44 else { return false }
        return !AudioRecorder.isAudioSilent(data: data)
    }

    /// Canlı oturumda sessizlik dahil her PCM bloğu süre ve sıra korunarak iletilir.
    static func livePCMChunkForForwarding(_ data: Data) -> Data {
        data
    }

    /// A recorder callback must keep forwarding to its own session, even if a
    /// later recording has already replaced currentLiveSession.
    static func liveAudioForwarder(
        for session: (any LiveStreamSession)?,
        onAudio: @escaping () -> Void
    ) -> (Data) -> Void {
        { chunk in
            guard let session else { return }
            onAudio()
            session.sendAudioChunk(livePCMChunkForForwarding(chunk))
        }
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
        setupReadAloud()

        // First-use AppKit layer creation and procedural sound synthesis must not
        // sit on the dictation keydown path. This does not open the microphone.
        RecordingHUD.shared.warm()
        _ = SoundManager.shared
        _ = AudioRecorder.shared

        // Ayarlar güncellendiğinde menüyü yenile
        SettingsWindowController.shared.onConfigUpdated = { [weak self] in
            KeyListener.shared.updateTriggerKeyConfiguration()
            self?.refreshPermissionSnapshot()
            if TranscriptionProviderRegistry.supports(.requiresSpeechPermission, providerID: ConfigManager.shared.config.provider),
               self?.permissionSnapshot?.speechStatus == .authorized {
                Transcriber.shared.warmAppleSpeech(language: ConfigManager.shared.config.language)
            }
            self?.refreshHistoryMenu()
            self?.refreshMenuStates()
        }

        // Dikte geçmişi güncellendiğinde menüyü yenile
        DictationHistoryManager.shared.onHistoryUpdated = { [weak self] in
            self?.refreshHistoryMenu()
        }

        // İzinleri başlat ve hazır olduğunda ses ve tuş dinleyicisini aktive et
        startPermissionsFlow()
    }

    public func applicationDidBecomeActive(_ notification: Notification) {
        // Kullanıcı Sistem Ayarları'ndan döndüğünde izin cache'i güncellenir.
        // Kayıt hot path'i bu sayede TCC IPC'si çalıştırmadan karar verebilir.
        refreshPermissionSnapshot()
        refreshMenuStates()
    }

    private func startPermissionsFlow() {
        // Mikrofon her sağlayıcı için gereklidir. Apple Speech izni ise yalnızca
        // Apple sağlayıcısı seçiliyken istenir; bulut sağlayıcı kullanan kişiye
        // gereksiz bir sistem izin penceresi göstermeyiz.
        PermissionManager.shared.requestMicrophonePermission { [weak self] micGranted in
            let provider = TranscriptionProviderRegistry.normalize(ConfigManager.shared.config.provider)
            let needsSpeechPermission = TranscriptionProviderRegistry.supports(.requiresSpeechPermission, providerID: provider)
            print("[AppDelegate] Mikrofon izni durumu: \(micGranted)")
            if micGranted {
                AudioRecorder.shared.warm()
            }

            guard needsSpeechPermission, micGranted else {
                if !needsSpeechPermission {
                    print("[AppDelegate] Apple Speech izni atlandı (aktif sağlayıcı: \(provider)).")
                }
                DispatchQueue.main.async {
                    self?.checkAccessibilityAndActivate()
                }
                return
            }

            PermissionManager.shared.requestSpeechRecognitionPermission { speechGranted in
                print("[AppDelegate] Konuşma tanıma izni durumu: \(speechGranted)")
                if speechGranted {
                    Transcriber.shared.warmAppleSpeech(language: ConfigManager.shared.config.language)
                }
                DispatchQueue.main.async {
                    self?.checkAccessibilityAndActivate()
                }
            }
        }
    }

    private func checkAccessibilityAndActivate() {
        refreshPermissionSnapshot()
        if permissionSnapshot?.accessibilityGranted == true {
            // Erişilebilirlik hazır olduğunda tuş dinleyicisi kurulabilir. Mikrofon
            // veya sağlayıcı izni eksikse kullanıcıya kayıt anında anlamlı bilgi verilir.
            print("[AppDelegate] ✅ Erişilebilirlik hazır. Voice Typing aktif edildi.")
            setupKeyListener()
            SoundManager.shared.playStartup()
            refreshMenuStates()
        } else {
            // Erişilebilirlik izni eksikse, Sistem Ayarları'nı kapatmayan ve izin verilince otomatik kapanan minimal pencereyi göster
            print("[AppDelegate] ⚠️ Erişilebilirlik izni bekleniyor, yönlendirici açılıyor...")
            AccessibilityPromptController.shared.showPrompt { [weak self] in
                print("[AppDelegate] 🎉 Erişilebilirlik izni verildi! Sistem başlatılıyor.")
                self?.refreshPermissionSnapshot()
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
        // Menü her açıldığında durumlar tazelenir (ör. giriş yöntemi Sistem
        // Ayarları'ndan yeni etkinleştirildiyse onay işareti hemen düzelir).
        menu.delegate = self

        // Durum ve menüden hızlı kayıt kontrolü. Bu öğeler daha önce yalnızca
        // değişken olarak tutuluyordu; kullanıcı menüden kayıt başlatamıyordu.
        statusMenuItem = NSMenuItem(title: readyMenuText, action: nil, keyEquivalent: "")
        statusMenuItem?.isEnabled = false
        if let statusMenuItem {
            menu.addItem(statusMenuItem)
        }

        toggleRecordMenuItem = NSMenuItem(title: "🎙️ Sesle Yazmayı Başlat (Kayıt)", action: #selector(toggleRecordAction), keyEquivalent: "")
        toggleRecordMenuItem?.target = self
        if let toggleRecordMenuItem {
            menu.addItem(toggleRecordMenuItem)
        }

        menu.addItem(NSMenuItem.separator())

        // 1. Ayarlar Penceresi (Temiz Apple HIG standardı, çift ikon önlendi)
        let settingsItem = NSMenuItem(title: "Ayarlar...", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        settingsItem.image = nil
        menu.addItem(settingsItem)

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

        // 5. Sağlayıcı Submenu
        let providerMenu = NSMenu()
        appleMenuItem = NSMenuItem(title: "Apple (cihaz içi, ücretsiz)", action: #selector(selectAppleProvider), keyEquivalent: "")
        appleMenuItem.target = self
        providerMenu.addItem(appleMenuItem)

        geminiMenuItem = NSMenuItem(title: "Gemini (canlı önizleme)", action: #selector(selectGeminiProvider), keyEquivalent: "")
        geminiMenuItem.target = self
        providerMenu.addItem(geminiMenuItem)

        groqMenuItem = NSMenuItem(title: "Groq Whisper (en hızlı)", action: #selector(selectGroqProvider), keyEquivalent: "")
        groqMenuItem.target = self
        providerMenu.addItem(groqMenuItem)

        assemblyAIMenuItem = NSMenuItem(title: "AssemblyAI", action: #selector(selectAssemblyAIProvider), keyEquivalent: "")
        assemblyAIMenuItem.target = self
        providerMenu.addItem(assemblyAIMenuItem)

        sedaMenuItem = NSMenuItem(title: "Harfiyen · Seda-v0.1 (yerel Türkçe)", action: #selector(selectSedaProvider), keyEquivalent: "")
        sedaMenuItem.target = self
        providerMenu.addItem(sedaMenuItem)

        // Ses tanıma motoru menüden tek tıkla değişir; başlık etkin olanı gösterir.
        providerParentMenuItem = NSMenuItem(title: "Ses Tanıma", action: nil, keyEquivalent: "")
        providerParentMenuItem.submenu = providerMenu
        menu.addItem(providerParentMenuItem)

        // 5b. Son Dikteler (History) Submenu
        historyMenu = NSMenu()
        historyParentMenuItem = NSMenuItem(title: "Son Dikteler", action: nil, keyEquivalent: "")
        historyParentMenuItem.submenu = historyMenu
        menu.addItem(historyParentMenuItem)
        refreshHistoryMenu()

        let speechMenu = NSMenu()
        speechMenu.autoenablesItems = false
        readAloudStatusItem = NSMenuItem(title: "Seslendirme: Hazırlanıyor", action: nil, keyEquivalent: "")
        readAloudStatusItem?.isEnabled = false
        speechMenu.addItem(readAloudStatusItem!)
        let selectedItem = NSMenuItem(title: "Seçili Metni Seslendir (⌥⌘S)", action: #selector(speakSelectedText), keyEquivalent: "")
        selectedItem.target = self
        speechMenu.addItem(selectedItem)
        let clipboardItem = NSMenuItem(title: "Panoyu Seslendir", action: #selector(speakClipboardText), keyEquivalent: "")
        clipboardItem.target = self
        speechMenu.addItem(clipboardItem)
        readAloudStopItem = NSMenuItem(title: "Okumayı Durdur (Esc)", action: #selector(stopReadAloud), keyEquivalent: "")
        readAloudStopItem?.target = self
        readAloudStopItem?.isEnabled = false
        speechMenu.addItem(readAloudStopItem!)
        readAloudShortcutItem = NSMenuItem(title: "Global Kısayol: ⌥⌘S", action: nil, keyEquivalent: "")
        readAloudShortcutItem?.isEnabled = false
        speechMenu.addItem(readAloudShortcutItem!)
        let disclosure = NSMenuItem(title: "Yapay zekâ sesi · Türkçe · EMA Lightning", action: nil, keyEquivalent: "")
        disclosure.isEnabled = false
        speechMenu.addItem(disclosure)
        let speechParent = NSMenuItem(title: "Metni Seslendir", action: nil, keyEquivalent: "")
        speechParent.submenu = speechMenu
        menu.addItem(speechParent)

        // Sade menü: yalnızca sık kullanılanlar. Tetikleyici tuş, mod
        // ve tüm tercihler Ayarlar penceresinde (öğeler durum takibi için
        // oluşturulur ama menüye eklenmez).

        soundEffectsMenuItem = NSMenuItem(title: "Ses Efektleri", action: #selector(toggleSoundEffects), keyEquivalent: "")
        soundEffectsMenuItem.target = self

        hapticMenuItem = NSMenuItem(title: "Dokunsal Titreşim (Trackpad)", action: #selector(toggleHapticFeedback), keyEquivalent: "")
        hapticMenuItem.target = self

        fillerWordsMenuItem = NSMenuItem(title: "Dolgu Kelimelerini Temizle", action: #selector(toggleFillerWords), keyEquivalent: "")
        fillerWordsMenuItem.target = self

        pauseMediaMenuItem = NSMenuItem(title: "Konuşurken Medyayı Duraklat (Play/Pause)", action: #selector(togglePauseMediaPlayback), keyEquivalent: "")
        pauseMediaMenuItem.target = self

        muteAudioMenuItem = NSMenuItem(title: "Konuşurken Medyayı Sustur", action: #selector(toggleMuteSystemAudio), keyEquivalent: "")
        muteAudioMenuItem.target = self

        saveHistoryMenuItem = NSMenuItem(title: "Dikte Geçmişini Kaydet", action: #selector(toggleSaveHistory), keyEquivalent: "")
        saveHistoryMenuItem.target = self

        onlyInTextFieldsMenuItem = NSMenuItem(title: "Sadece Yazı Alanında Çalıştır", action: #selector(toggleOnlyInTextFields), keyEquivalent: "")
        onlyInTextFieldsMenuItem.target = self

        inputMethodMenuItem = NSMenuItem(title: "Panoyu Kullanmadan Yaz", action: #selector(toggleDirectTyping), keyEquivalent: "")
        inputMethodMenuItem.target = self

        launchAtLoginMenuItem = NSMenuItem(title: "Başlangıçta Otomatik Çalıştır", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        launchAtLoginMenuItem.target = self

        menu.addItem(NSMenuItem.separator())

        // Kurtarma Ses Deposu (Dictation Recovery)
        recoverAudioMenuItem = NSMenuItem(title: "💾 Son Sesi Masaüstüne Kaydet", action: #selector(exportRecoveredAudioAction), keyEquivalent: "")
        recoverAudioMenuItem?.target = self
        if let recItem = recoverAudioMenuItem {
            menu.addItem(recItem)
        }

        // 7. Çıkış
        let quitItem = NSMenuItem(title: "Çıkış", action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu
        refreshMenuStates()
    }

    private func refreshPermissionSnapshot() {
        // Konuşma Tanıma izni yalnızca Apple Speech kullanan sağlayıcılar için
        // anlamlıdır; bulut sağlayıcılarında gereksiz TCC sorgusu yapılmaz.
        let requiresSpeechPermission = TranscriptionProviderRegistry
            .descriptor(for: ConfigManager.shared.config.provider)
            .capabilities
            .contains(.requiresSpeechPermission)
        let speechStatus: PermissionStatus = requiresSpeechPermission
            ? PermissionManager.shared.getSpeechRecognitionStatus().status
            : .authorized

        permissionSnapshot = DictationPermissionSnapshot(
            accessibilityGranted: AXIsProcessTrusted(),
            microphoneStatus: PermissionManager.shared.getMicrophoneStatus().status,
            speechStatus: speechStatus
        )
    }

    private func dictationReadinessMessage(config: AppConfig? = nil) -> String? {
        if permissionSnapshot == nil {
            refreshPermissionSnapshot()
        }
        return permissionSnapshot?.readinessMessage(for: config ?? ConfigManager.shared.config)
    }

    private func showPrerequisiteNotice(_ message: String) {
        SoundManager.shared.playCancel()
        HapticManager.shared.playCancel()
        RecordingHUD.shared.showNotice(message: message, autoDismissDelay: 2.4)
        setStatus(title: "ℹ️", menuText: message, revertAfter: 2.4)
    }

    private func refreshMenuStates() {
        let cfg = ConfigManager.shared.config
        // Menü işaretleri gerçekte kullanılacak sağlayıcıyı yansıtmalı; tanınmayan
        // bir kimlik varsayılana düştüğü için menü de onu işaretler.
        let activeProvider = TranscriptionProviderRegistry.normalize(cfg.provider)
        appleMenuItem.state = (activeProvider == "apple") ? .on : .off
        geminiMenuItem.state = (activeProvider == "gemini") ? .on : .off
        groqMenuItem.state = (activeProvider == "groq") ? .on : .off
        assemblyAIMenuItem.state = (activeProvider == "assemblyai") ? .on : .off
        sedaMenuItem.state = (activeProvider == "seda") ? .on : .off
        let providerNames = ["apple": "Apple", "gemini": "Gemini", "groq": "Groq", "assemblyai": "AssemblyAI", "seda": "Seda-v0.1"]
        providerParentMenuItem?.title = "Ses Tanıma: \(providerNames[activeProvider] ?? activeProvider)"

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
        inputMethodMenuItem?.state = cfg.type_text_directly ? .on : .off
        inputMethodMenuItem?.toolTip = "Metni pano ve Cmd+V yerine doğrudan alana yazar (Mac uygulamaları) veya karakter olarak gönderir (tarayıcı, Slack vb.). Olmazsa Cmd+V'ye düşer."
        restoreClipboardMenuItem?.state = cfg.restore_clipboard ? .on : .off
        launchAtLoginMenuItem.state = LaunchAtLoginManager.shared.isEnabled ? .on : .off

        SoundManager.shared.isEnabled = cfg.play_sounds

        if let button = statusItem.button {
            button.toolTip = readyToolTip
            button.image = getWaveformIcon()
            button.title = ""
        }

        let isRecording = AudioRecorder.shared.isRecording
        if isTranscribing || isFinishingRecord {
            toggleRecordMenuItem?.title = "⏳ Deşifre ediliyor..."
            toggleRecordMenuItem?.isEnabled = false
        } else if isRecording {
            toggleRecordMenuItem?.title = "⏹️ Kaydı Bitir ve Deşifre Et"
            toggleRecordMenuItem?.isEnabled = true
        } else {
            toggleRecordMenuItem?.title = "🎙️ Sesle Yazmayı Başlat (Kayıt)"
            toggleRecordMenuItem?.isEnabled = true
        }

        if !isRecording && !isTranscribing && !isFinishingRecord && revertStatusTimer == nil {
            statusMenuItem?.title = dictationReadinessMessage().map { "Durum: \($0)" } ?? readyMenuText
        }
        recoverAudioMenuItem?.isHidden = !DictationRecoveryAudioStore.shared.hasRecovery()
    }

    @objc private func toggleRecordAction() {
        if isPreparingRecord {
            cancelPendingRecordStart(reason: "menuStop")
        } else if AudioRecorder.shared.isRecording || isFinishingRecord {
            handleRecordStop(duration: AudioRecorder.shared.currentRecordingDuration())
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
            RecordingHUD.shared.showNotice(message: "Kurtarılacak ses yok")
            setStatus(title: "ℹ️", menuText: "Kurtarılacak ses yok", revertAfter: 1.8)
        }
    }

    private var isDictationActive: Bool {
        isPreparingRecord || isTranscribing || isFinishingRecord || AudioRecorder.shared.isRecording
    }

    private func setupReadAloud() {
        readAloud.isDictating = { [weak self] in self?.isDictationActive ?? false }
        readAloud.onUpdate = { [weak self] message, busy in
            self?.readAloudStatusItem?.title = "Seslendirme: \(message)"
            self?.readAloudStopItem?.isEnabled = busy
        }
        readAloud.onError = { [weak self] message in
            guard let self, !self.isDictationActive else { NSSound.beep(); return }
            RecordingHUD.shared.showNotice(message: message, autoDismissDelay: 3)
        }
        NSApplication.shared.servicesProvider = readAloud
        NSUpdateDynamicServices()
        readAloudHotKey.onPressed = { [weak self] in self?.readAloud.toggleSelection() }
        let result = readAloudHotKey.start()
        if result != 0 {
            readAloudShortcutItem?.title = "⌥⌘S kaydedilemedi (\(result)); Servisler veya menüyü kullanın"
        }
        readAloudBrowserBridge.onCommand = { [weak self] request in
            self?.readAloud.browserCommand(request) ?? ["ok": false, "error": "VoiceType kapandı."]
        }
        do { try readAloudBrowserBridge.start() }
        catch {
            let item = NSMenuItem(title: "Chrome bağlantısı açılamadı", action: nil, keyEquivalent: "")
            item.isEnabled = false
            readAloudStatusItem?.menu?.addItem(item)
        }
        readAloud.prepare()
    }

    @objc private func speakSelectedText() { readAloud.toggleSelection() }
    @objc private func speakClipboardText() { readAloud.speakClipboard() }
    @objc private func stopReadAloud() { readAloud.cancel() }

    private func setupKeyListener() {
        let listener = KeyListener.shared

        listener.isBusy = { [weak self] in
            guard let self = self else { return false }
            return self.isPreparingRecord || self.isTranscribing || self.isFinishingRecord || AudioRecorder.shared.isRecording || self.readAloud.isBusy
        }

        listener.onShortcutStart = { [weak self] triggeredAt, kind in
            self?.handleRecordStart(triggeredAt: triggeredAt, shortcutKind: kind)
        }

        listener.onStop = { [weak self] duration in
            self?.handleRecordStop(duration: duration)
        }

        listener.onCancel = { [weak self] in
            guard let self else { return }
            if self.isDictationActive { self.handleCancel() }
            else if self.readAloud.isBusy { self.readAloud.cancel() }
            else { self.handleCancel() }
        }

        listener.start()
    }

    private func setStatus(title: String, menuText: String, revertAfter: TimeInterval? = nil) {
        let update = { [weak self] in
            guard let self = self else { return }
            self.revertStatusTimer?.invalidate()
            self.revertStatusTimer = nil

            // Menü çubuğundaki sabit premium waveform ikonu bozulmaz.
            self.statusMenuItem?.title = menuText
            if self.isTranscribing || self.isFinishingRecord {
                self.toggleRecordMenuItem?.title = "⏳ Deşifre ediliyor..."
                self.toggleRecordMenuItem?.isEnabled = false
            } else if AudioRecorder.shared.isRecording {
                self.toggleRecordMenuItem?.title = "⏹️ Kaydı Bitir ve Deşifre Et"
                self.toggleRecordMenuItem?.isEnabled = true
            } else {
                self.toggleRecordMenuItem?.title = "🎙️ Sesle Yazmayı Başlat (Kayıt)"
                self.toggleRecordMenuItem?.isEnabled = true
            }

            if let delay = revertAfter {
                self.revertStatusTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
                    guard let self = self else { return }
                    self.revertStatusTimer = nil
                    self.statusMenuItem?.title = self.dictationReadinessMessage().map { "Durum: \($0)" } ?? self.readyMenuText
                    self.toggleRecordMenuItem?.title = "🎙️ Sesle Yazmayı Başlat (Kayıt)"
                    self.toggleRecordMenuItem?.isEnabled = true
                }
            }
        }

        // Kayıt başarılı olduktan sonra UI güncellemesi, ana thread'i
        // bloklayabilecek medya/CoreAudio işlerinden önce görünür hale gelir.
        if Thread.isMainThread {
            update()
        } else {
            DispatchQueue.main.async(execute: update)
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

    /// Gecikme izlerinde ve günlüklerde gösterilen etkin model adını döndürür.
    /// Sağlayıcı kimliği zaten normalize edilmiş olarak beklenir.
    private static func effectiveModelName(for provider: String, config: AppConfig) -> String {
        switch provider {
        case "apple":
            return "SFSpeechRecognizer"
        case "gemini":
            return config.gemini_model
        case "assemblyai":
            return AssemblyAIDictation.model
        case "seda":
            return SedaTranscriber.model
        default:
            return config.groq_model
        }
    }

    private func makeLiveTranslation(config: AppConfig, target: TargetContext?) -> LiveTranslationCoordinator {
        LiveTranslationCoordinator(
            polish: { text in
                TextPolisher.shared.polish(text: text, config: config, targetContext: target)
            },
            request: { text, completion in
                let task = TranslationService.shared.translateCancellable(
                    text: text, from: config.language, to: config.translation_target_language,
                    config: config, timeout: 6.0, completion: completion
                )
                return task.map { task in { task.cancel() } }
            }
        )
    }

    static func dictationConfig(_ config: AppConfig, shortcutKind: DictationShortcutKind) -> AppConfig {
        var snapshot = config
        snapshot.enable_translation = config.enable_translation && shortcutKind == .translation
        return snapshot
    }

    private func handleRecordStart(triggeredAt: TimeInterval? = nil, shortcutKind: DictationShortcutKind = .normal) {
        let handlerEnteredAt = ProcessInfo.processInfo.systemUptime
        guard !isPreparingRecord, !isTranscribing, !isFinishingRecord, !AudioRecorder.shared.isRecording else { return }
        // TTS must stop before the microphone starts to avoid transcribing our own voice.
        readAloud.cancel()

        let config = Self.dictationConfig(ConfigManager.shared.config, shortcutKind: shortcutKind)
        activeDictationConfig = config
        liveTranslation?.cancel()
        liveTranslation = nil
        let provider = TranscriptionProviderRegistry.normalize(config.provider)
        let effectiveModel = Self.effectiveModelName(for: provider, config: config)

        let trace = RecordingStartLatencyTrace(
            provider: provider,
            model: effectiveModel,
            now: triggeredAt ?? handlerEnteredAt
        )
        trace.mark(.mainHandlerEntry, now: handlerEnteredAt)
        activeStartLatencyTrace = trace

        isPreparingRecord = true
        pendingRecordStartGeneration &+= 1
        let generation = pendingRecordStartGeneration
        deliveryGate.begin(generation)

        // Görsel tepki tüm TCC, AX ve CoreAudio işlerinden önce gelir. Devamı bir
        // sonraki main-run-loop turuna bırakılır; WindowServer hazırlık kapsülünü
        // gerçekten sunabilir ve spinner ağır başlangıç boyunca donmuş görünmez.
        RecordingHUD.shared.showPreparing()
        trace.mark(.preparingPresented)

        if provider == "assemblyai" {
            // DNS/TCP/TLS el sıkışmasını kullanıcı konuşurken tamamla; gerçek
            // transkripsiyon aynı URLSession bağlantı havuzunu yeniden kullanır.
            Transcriber.shared.warmAssemblyAIDictation()
        } else if provider == "groq" || (provider == "gemini" && !ConfigManager.isGeminiLiveModel(effectiveModel)) {
            Transcriber.shared.warmHTTPConnection(provider: provider)
        }

        DispatchQueue.main.async { [weak self] in
            self?.continueRecordStart(
                config: config,
                provider: provider,
                effectiveModel: effectiveModel,
                generation: generation,
                trace: trace
            )
        }
    }

    private func continueRecordStart(
        config: AppConfig,
        provider: String,
        effectiveModel: String,
        generation: UInt64,
        trace: RecordingStartLatencyTrace
    ) {
        guard isPreparingRecord, pendingRecordStartGeneration == generation else {
            trace.finish(reason: "cancelledBeforeStart")
            return
        }
        trace.mark(.hudRunLoopYield)

        if permissionSnapshot == nil {
            refreshPermissionSnapshot()
        }
        if let readinessMessage = dictationReadinessMessage(config: config) {
            activeDictationConfig = nil
            isPreparingRecord = false
            if readinessMessage.contains("Erişilebilirlik") {
                AccessibilityPromptController.shared.showPrompt()
            } else if permissionSnapshot?.microphoneStatus == .notDetermined {
                PermissionManager.shared.requestMicrophonePermission { [weak self] granted in
                    if granted { AudioRecorder.shared.warm() }
                    self?.refreshPermissionSnapshot()
                }
            } else if provider == "apple", permissionSnapshot?.speechStatus == .notDetermined {
                PermissionManager.shared.requestSpeechRecognitionPermission { [weak self] granted in
                    if granted {
                        Transcriber.shared.warmAppleSpeech(language: config.language)
                    }
                    self?.refreshPermissionSnapshot()
                }
            }
            KeyListener.shared.resetState()
            showPrerequisiteNotice(readinessMessage)
            trace.finish(reason: "prerequisite")
            activeStartLatencyTrace = nil
            return
        }
        trace.mark(.preflightCompleted)

        let isApple = provider == "apple"
        let geminiModel = config.gemini_model.lowercased()
        let isGeminiLive = provider == "gemini" &&
                           (geminiModel.isEmpty || ConfigManager.isGeminiLiveModel(geminiModel)) &&
                           !config.gemini_api_key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let audioProcessingMode = RecordingAudioProcessingMode.resolve(config: config)

        let outcome = recordingStartCoordinator.start(
            prepare: { _ in },
            captureTarget: { [self] in
                trace.mark(.targetCaptureStarted)
                if let target = TargetInputManager.shared.captureTargetContext() {
                    activeTargetContext = target
                    print("[AppDelegate] 🎯 Hedef yazı alanı kilitlendi: \(target.appName) (\(target.role)) [PID: \(target.pid)]")
                } else if config.only_in_text_fields {
                    print("[AppDelegate] ⚠️ Odakta geçerli bir yazı alanı bulunamadı. Kural gereği kayıt başlatılmadı.")
                    activeTargetContext = nil
                    return false
                } else if let frontApp = NSWorkspace.shared.frontmostApplication {
                    let appRef = AXUIElementCreateApplication(frontApp.processIdentifier)
                    activeTargetContext = TargetContext(
                        pid: frontApp.processIdentifier,
                        bundleIdentifier: frontApp.bundleIdentifier ?? "",
                        appName: frontApp.localizedName ?? "",
                        runningApp: frontApp,
                        element: appRef,
                        window: nil,
                        role: "AXFallbackApp"
                    )
                } else {
                    activeTargetContext = nil
                }
                trace.mark(.targetCaptured)
                return true
            },
            startRecorder: { [self] in
                // Her dikte oturumu kapıyı sıfırlar: yeni oturumun ilk anları
                // ortam gürültüsünü yeniden kalibre eder.
                AudioRecorder.shared.resetSpeechGate()
                guard let attempt = deliveryGate.currentAttempt(generation) else { return false }
                if config.enable_translation {
                    liveTranslation = makeLiveTranslation(config: config, target: activeTargetContext)
                }
                let firstAudio: () -> Void = { trace.mark(.firstAudioCallback) }
                let providerAudio: () -> Void = { trace.mark(.firstProviderAudio) }
                let onInterim: (String) -> Void = { [weak self] interimText in
                    DispatchQueue.main.async { [weak self] in
                        guard self?.deliveryGate.acceptsResult(generation, attempt: attempt) == true else { return }
                        trace.mark(.firstInterim)
                        trace.finish(reason: "firstInterim")
                        if AudioRecorder.shared.isRecording {
                            self?.liveTranslation?.observe(interimText)
                        }
                        RecordingHUD.shared.updateInterimText(interimText)
                    }
                }
                let onCompletion: (TranscriptionResult) -> Void = { [weak self] result in
                    trace.finish(reason: "completion")
                    self?.handleTranscriptionResult(result: result, config: config, generation: generation, attempt: attempt)
                }
                let started: Bool
                if isApple {
                    print("[AppDelegate] Sağlayıcı: Apple Speech (Yerel Canlı Akış) başlatılıyor...")
                    let session = Transcriber.shared.startLiveAppleSpeechSession(
                        config: config,
                        authorizationAlreadyValidated: true,
                        onInterim: onInterim,
                        completion: onCompletion
                    )
                    currentLiveSession = session
                    trace.mark(.speechSessionStarted)
                    trace.mark(.recorderStartEntered)
                    started = AudioRecorder.shared.start(
                        onAudioChunk: Self.liveAudioForwarder(for: session, onAudio: providerAudio),
                        onFirstAudioBuffer: firstAudio,
                        processingMode: audioProcessingMode
                    )
                } else if provider == "seda" {
                    let session = Transcriber.shared.startLiveSedaSession(
                        config: config,
                        onInterim: onInterim,
                        completion: onCompletion
                    )
                    currentLiveSession = session
                    trace.mark(.speechSessionStarted)
                    trace.mark(.recorderStartEntered)
                    started = AudioRecorder.shared.start(
                        onAudioChunk: Self.liveAudioForwarder(for: session, onAudio: providerAudio),
                        onFirstAudioBuffer: firstAudio,
                        processingMode: audioProcessingMode
                    )
                } else if isGeminiLive {
                    print("[AppDelegate] Sağlayıcı: Google Gemini Live (\(config.gemini_model)) canlı akış oturumu başlatılıyor...")
                    let session = Transcriber.shared.startLiveGeminiSession(
                        config: config,
                        targetContext: activeTargetContext,
                        onInterim: onInterim,
                        completion: onCompletion
                    )
                    currentLiveSession = session
                    trace.mark(.speechSessionStarted)
                    trace.mark(.recorderStartEntered)
                    started = AudioRecorder.shared.start(
                        onAudioChunk: Self.liveAudioForwarder(for: session, onAudio: providerAudio),
                        onFirstAudioBuffer: firstAudio,
                        processingMode: audioProcessingMode
                    )
                } else {
                    print("[AppDelegate] Sağlayıcı: \(config.provider) (\(effectiveModel)) ses kaydı başlatılıyor...")
                    currentLiveSession = nil
                    trace.mark(.recorderStartEntered)
                    started = AudioRecorder.shared.start(
                        onFirstAudioBuffer: firstAudio,
                        processingMode: audioProcessingMode
                    )
                }
                if started {
                    trace.mark(.recorderStarted)
                }
                return started
            }
        )

        isPreparingRecord = false
        switch outcome {
        case .ignored:
            activeDictationConfig = nil
            KeyListener.shared.resetState()
            RecordingHUD.shared.showNotice(message: "Kayıt başlatılamadı · Tekrar deneyin")
            recordingStartCoordinator.finish()
            trace.finish(reason: "ignored")
            activeStartLatencyTrace = nil
            return
        case .targetRejected:
            activeDictationConfig = nil
            KeyListener.shared.resetState()
            SoundManager.shared.playCancel()
            HapticManager.shared.playCancel()
            RecordingHUD.shared.showNotice(message: "Yazı alanı seçili değil")
            setStatus(title: "ℹ️", menuText: "Yazı alanı seçili değil", revertAfter: 2.0)
            trace.finish(reason: "targetRejected")
            activeStartLatencyTrace = nil
            return
        case .recorderFailed:
            KeyListener.shared.resetState()
            liveTranslation?.cancel()
            liveTranslation = nil
            activeDictationConfig = nil
            deliveryGate.finish()
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
            trace.finish(reason: "recorderFailed")
            activeStartLatencyTrace = nil
            return
        case .started:
            break
        }

        // Recorder başarıyla açıldıktan sonra kullanıcıya geri bildirim ver;
        // aşağıdaki medya/CoreAudio işlemleri ana thread'i bekletmemelidir.
        setStatus(title: "🔴 Dinliyor...", menuText: config.enable_translation
                  ? "Durum: Dinleniyor · Çeviri"
                  : "Durum: Dinleniyor · Dikte")
        RecordingHUD.shared.showRecording()

        SoundManager.shared.playStart()
        HapticManager.shared.playStart()
        BackgroundAudioController.shared.handleDictationStarted(config: config)
        if config.mute_system_audio {
            SystemAudioManager.shared.muteForDictation(delay: 0.15)
        }

        if let target = activeTargetContext {
            activeAccessibilityLease = ChromiumAccessibilityController.shared.beginObservation(
                processIdentifier: target.pid,
                bundleIdentifier: target.bundleIdentifier,
                bundleURL: target.runningApp?.bundleURL
            )
        }
    }

    private func cancelPendingRecordStart(reason: String) {
        guard isPreparingRecord else { return }
        liveTranslation?.cancel()
        liveTranslation = nil
        activeDictationConfig = nil
        pendingRecordStartGeneration &+= 1
        deliveryGate.finish()
        isPreparingRecord = false
        recordingStartCoordinator.finish()
        activeStartLatencyTrace?.finish(reason: reason)
        activeStartLatencyTrace = nil
        activeTargetContext = nil
        KeyListener.shared.resetState()
        RecordingHUD.shared.showNotice(message: "Kayıt başlamadan bırakıldı", autoDismissDelay: 1.1)
        setStatus(title: "ℹ️", menuText: "Kayıt başlamadan bırakıldı", revertAfter: 1.1)
    }

    private func handleRecordStop(duration: Double) {
        let config = activeDictationConfig ?? ConfigManager.shared.config

        if isPreparingRecord {
            cancelPendingRecordStart(reason: "releasedBeforeStart")
            return
        }

        guard AudioRecorder.shared.isRecording, !isFinishingRecord, !isTranscribing else { return }

        recordingStartCoordinator.finish()
        activeStartLatencyTrace?.finish(reason: "stop")
        activeStartLatencyTrace = nil

        // Çok kısa basma - kazara dokunma
        guard duration >= config.min_record_duration else {
            liveTranslation?.cancel()
            liveTranslation = nil
            activeDictationConfig = nil
            deliveryGate.finish()
            activeAccessibilityLease?.end()
            activeAccessibilityLease = nil
            activeTargetContext = nil
            currentLiveSession?.cancel()
            currentLiveSession = nil
            lastRecordedAudioData = nil
            SystemAudioManager.shared.restoreAfterDictation()
            BackgroundAudioController.shared.handleDictationEnded(config: config)
            _ = AudioRecorder.shared.stop()
            RecordingHUD.shared.showNotice(message: "Kayıt çok kısa")
            setStatus(title: "ℹ️", menuText: "Kayıt çok kısa — tekrar deneyin", revertAfter: 1.5)
            return
        }

        // Kullanıcı arayüzünde anında ve akıcı geri bildirim: HUD ve menü durumunu deşifre moduna al
        isFinishingRecord = true
        setStatus(title: "⏳ Yazıyor...", menuText: "Durum: Deşifre Ediliyor...")
        RecordingHUD.shared.showTranscribing()

        postRollWorkItem?.cancel()
        let generation = pendingRecordStartGeneration
        let workItem = DispatchWorkItem { [weak self] in
            guard let self = self, self.isFinishingRecord else { return }
            self.isFinishingRecord = false

            // Mikrofon kaydını durdur ve kalan tüm PCM verisini akıt
            let (data, actualDuration) = AudioRecorder.shared.stop()

            // Mikrofon sustuktan sonra ana ses çıkışını geri aç ve bitiş sesini çal
            SystemAudioManager.shared.restoreAfterDictation()
            SoundManager.shared.playStop()

            guard actualDuration >= config.min_record_duration,
                  let audioData = data,
                  Self.shouldSubmitRecording(audioData) else {
                // Tamamlanmış fakat gerçek konuşma içermeyen kayıt sağlayıcıya gönderilmez.
                self.liveTranslation?.cancel()
                self.liveTranslation = nil
                self.activeDictationConfig = nil
                self.deliveryGate.finish()
                self.activeAccessibilityLease?.end()
                self.activeAccessibilityLease = nil
                self.currentLiveSession?.cancel()
                self.currentLiveSession = nil
                self.activeTargetContext = nil
                self.lastRecordedAudioData = nil
                BackgroundAudioController.shared.handleDictationEnded(config: config)
                RecordingHUD.shared.showNotice(message: "Ses algılanmadı · Tekrar deneyin")
                self.setStatus(title: "🔇", menuText: "Ses algılanmadı — tekrar deneyin", revertAfter: 1.8)
                return
            }

            self.lastRecordedAudioData = audioData
            _ = DictationRecoveryAudioStore.shared.saveLastRecording(wavData: audioData)

            if let liveSession = self.currentLiveSession {
                self.isTranscribing = true
                liveSession.finishAudio()
                return
            }

            guard let attempt = self.deliveryGate.currentAttempt(generation) else { return }
            self.isTranscribing = true
            Transcriber.shared.transcribe(
                audioData: audioData,
                config: config,
                targetContext: self.activeTargetContext
            ) { [weak self] result in
                self?.handleTranscriptionResult(result: result, config: config, generation: generation, attempt: attempt)
            }
        }

        // Akustik ve Nöromüsküler Uzatma Penceresi (Post-Roll Grace Period):
        // Kullanıcı konuşmayı bitirdiği anda tuşu bıraksa dahi, son hecelerin / son kelimelerin
        // ve CoreAudio donanım tamponundaki seslerin eksiksiz alınması için mikrofon kısa bir süre daha dinler.
        // Streaming transport does not eliminate the acoustic tail at key release.
        let postRollDelay: Double = 0.18
        self.postRollWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + postRollDelay, execute: workItem)
    }

    private func handleTranscriptionResult(result: TranscriptionResult, config: AppConfig, generation: UInt64, attempt: UInt64) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self, self.deliveryGate.acceptsResult(generation, attempt: attempt) else { return }

            // Canlı sağlayıcı, post-roll penceresinde bile sonucu mikrofon
            // kapanmadan bildirebilir. Hedefe erken metin yapıştırmamak için
            // mikrofon tamamen durana kadar her canlı sonucu fallback'e bırak.
            if AudioRecorder.shared.isRecording {
                print("[AppDelegate] ⚠️ Canlı deşifre mikrofon kapanmadan sonlandı; kayıt bitince WAV fallback kullanılacak.")
                self.liveTranslation?.invalidateInterims()
                _ = self.deliveryGate.advanceAttempt(generation, after: attempt)
                self.currentLiveSession = nil
                return
            }

            if result.success {
                guard self.deliveryGate.beginDelivery(generation) else { return }
                self.isTranscribing = true
                self.currentLiveSession = nil
                self.lastRecordedAudioData = nil

                print("[Deşifre Başarılı] [\(result.provider.uppercased()) - \(result.model)] uzunluk=\(result.text.utf16.count), süre=\(String(format: "%.2f", result.latency))s")

                let recognizedText = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !recognizedText.isEmpty {
                    let target = self.activeTargetContext
                    self.activeTargetContext = nil

                    let polishedText = TextPolisher.shared.polish(text: recognizedText, config: config, targetContext: target)
                    guard !polishedText.isEmpty else {
                        self.finishDictationDelivery()
                        let recoveryAvailable = DictationRecoveryAudioStore.shared.markFailed(error: "Metin oluşturulamadı")
                        self.recoverAudioMenuItem?.isHidden = !recoveryAvailable
                        BackgroundAudioController.shared.handleDictationEnded(config: config)
                        let message = recoveryAvailable ? "Metin oluşturulamadı · Ses korundu" : "Metin oluşturulamadı · Ses kurtarılamadı"
                        RecordingHUD.shared.showNotice(message: message)
                        self.setStatus(title: "ℹ️", menuText: message, revertAfter: 2.2)
                        return
                    }

                    let injectFinalText: (String) -> Void = { [weak self] text in
                        guard let self = self, self.deliveryGate.beginInjection(generation) else { return }

                        DictationHistoryManager.shared.addEntry(
                            text: text,
                            provider: result.provider,
                            model: result.model,
                            appName: target?.appName
                        )

                        // Akıllı Boşluk (Smart Spacing): Ardışık diktelerde kelimelerin birbirine yapışmasını önler
                        let textToInject = TextPolisher.applySmartSpacing(text)

                        let injectionStarted = TextInjector.shared.inject(
                            text: textToInject,
                            targetContext: target,
                            pasteDelayMs: config.paste_delay_ms
                        ) { [weak self] outcome in
                            guard let self, self.deliveryGate.isDelivering(generation) else { return }
                            self.presentInjectionOutcome(outcome, latency: result.latency)
                        }
                        BackgroundAudioController.shared.handleDictationEnded(config: config)

                        if !injectionStarted {
                            self.finishDictationDelivery()
                            let recoveryAvailable = DictationRecoveryAudioStore.shared.markFailed(error: "Metin hedef alana yapıştırılamadı")
                            self.recoverAudioMenuItem?.isHidden = !recoveryAvailable
                            SoundManager.shared.playCancel()
                            HapticManager.shared.playCancel()
                            let message = recoveryAvailable ? "Yapıştırılamadı · Ses korundu" : "Yapıştırılamadı · Ses kurtarılamadı"
                            RecordingHUD.shared.showError(message: message, autoDismissDelay: 2.4)
                            self.setStatus(title: "⚠️", menuText: message, revertAfter: 2.4)
                        }
                    }

                    if config.enable_translation {
                        RecordingHUD.shared.showTranscribing()
                        self.setStatus(title: "🌐", menuText: "Çevriliyor...", revertAfter: 4.0)

                        let translation = self.liveTranslation ?? self.makeLiveTranslation(config: config, target: target)
                        self.liveTranslation = translation
                        translation.finish(text: polishedText) { [weak self] translationResult in
                            DispatchQueue.main.async {
                                guard let self = self, self.deliveryGate.isDelivering(generation) else { return }
                                if translationResult.wasFallback {
                                    if let err = translationResult.errorMessage, !err.isEmpty {
                                        print("[Translation] ⚠️ Çeviri yapılamadı (\(err)), orijinal metin iletiliyor.")
                                    }
                                    RecordingHUD.shared.showNotice(message: "Çeviri yapılamadı · Orijinal metin kullanılacak", autoDismissDelay: 2.0)
                                    self.setStatus(title: "ℹ️", menuText: "Çeviri yapılamadı — Orijinal metin kullanılacak", revertAfter: 2.2)
                                    injectFinalText(polishedText)
                                } else {
                                    injectFinalText(translationResult.text)
                                }
                            }
                        }
                    } else {
                        injectFinalText(polishedText)
                    }
                } else {
                    self.finishDictationDelivery()
                    self.activeTargetContext = nil
                    DictationRecoveryAudioStore.shared.clear()
                    self.recoverAudioMenuItem?.isHidden = true
                    BackgroundAudioController.shared.handleDictationEnded(config: config)
                    RecordingHUD.shared.showNotice(message: "Ses algılanmadı · Tekrar deneyin")
                    self.setStatus(title: "🔇", menuText: "Ses algılanmadı — tekrar deneyin", revertAfter: 1.8)
                }
            } else {
                let err = result.error ?? ""
                if Transcriber.isNoSpeechMessage(err) {
                    self.finishDictationDelivery()
                    self.currentLiveSession = nil
                    self.activeTargetContext = nil
                    self.lastRecordedAudioData = nil
                    DictationRecoveryAudioStore.shared.clear()
                    self.recoverAudioMenuItem?.isHidden = true
                    BackgroundAudioController.shared.handleDictationEnded(config: config)
                    RecordingHUD.shared.showNotice(message: "Ses algılanmadı · Tekrar deneyin")
                    self.setStatus(title: "🔇", menuText: "Ses algılanmadı — tekrar deneyin", revertAfter: 1.8)
                    return
                }

                let normalizedError = err.lowercased()
                let isQuota = normalizedError.contains("quota") || normalizedError.contains("exceeded") || normalizedError.contains("429")
                let fallbackProvider = TranscriptionProviderRegistry.normalize(config.provider)
                if !isQuota, let fallbackAudio = self.lastRecordedAudioData,
                   ["apple", "seda", "gemini"].contains(fallbackProvider),
                   let fallbackAttempt = self.deliveryGate.advanceAttempt(generation, after: attempt) {
                    self.liveTranslation?.invalidateInterims()
                    self.lastRecordedAudioData = nil
                    self.currentLiveSession = nil
                    if fallbackProvider == "apple" {
                        print("[AppleSpeech] Canlı akış tamamlanamadı, yerel dosya motoru ile kurtarılıyor...")
                        self.setStatus(title: "⏳ Tamamlanıyor...", menuText: "Durum: Kaydedilen ses yeniden çözümleniyor...")
                        Transcriber.shared.transcribeAppleSpeech(audioData: fallbackAudio, config: config) { [weak self] appleResult in
                            self?.handleTranscriptionResult(result: appleResult, config: config, generation: generation, attempt: fallbackAttempt)
                        }
                        return
                    } else if fallbackProvider == "seda" {
                        self.setStatus(title: "⏳ Tamamlanıyor...", menuText: "Durum: Yerel ses kaydı yeniden çözümleniyor...")
                        Transcriber.shared.transcribe(audioData: fallbackAudio, config: config) { [weak self] localResult in
                            self?.handleTranscriptionResult(result: localResult, config: config, generation: generation, attempt: fallbackAttempt)
                        }
                        return
                    } else if fallbackProvider == "gemini" {
                        print("[GeminiLive] WebSocket bağlantısı kesildi, REST API ile kurtarılıyor...")
                        self.setStatus(title: "⏳ Yeniden deneniyor...", menuText: "Durum: REST ile deneniyor...")
                        Transcriber.shared.transcribeGemini(
                            audioData: fallbackAudio,
                            config: config,
                            targetContext: self.activeTargetContext
                        ) { [weak self] restResult in
                            self?.handleTranscriptionResult(result: restResult, config: config, generation: generation, attempt: fallbackAttempt)
                        }
                        return
                    }
                }

                self.finishDictationDelivery()
                self.currentLiveSession = nil
                self.activeTargetContext = nil
                self.lastRecordedAudioData = nil
                let rawError = result.error?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let errMsg = rawError.isEmpty ? "Bilinmeyen hata" : rawError
                let recoveryAvailable = DictationRecoveryAudioStore.shared.markFailed(error: errMsg)
                self.recoverAudioMenuItem?.isHidden = !recoveryAvailable
                BackgroundAudioController.shared.handleDictationEnded(config: config)
                SoundManager.shared.playCancel()
                HapticManager.shared.playCancel()
                let compactError = errMsg.replacingOccurrences(of: "\n", with: " ")
                let visibleError = compactError.count > 96
                    ? String(compactError.prefix(93)) + "..."
                    : compactError
                let failureMessage = recoveryAvailable ? "Deşifre başarısız · Ses korundu" : "Deşifre başarısız · Ses kurtarılamadı"
                RecordingHUD.shared.showError(message: failureMessage, autoDismissDelay: 3.0)
                self.setStatus(title: "⚠️ Hata", menuText: "Hata: \(visibleError)", revertAfter: 3.0)
            }
        }
    }

    private func finishDictationDelivery() {
        isTranscribing = false
        liveTranslation?.cancel()
        liveTranslation = nil
        activeDictationConfig = nil
        deliveryGate.finish()
        activeAccessibilityLease?.end()
        activeAccessibilityLease = nil
    }

    /// Aktarımın gerçek sonucunu ve ses kurtarma durumunu kullanıcıya gösterir.
    private func presentInjectionOutcome(_ outcome: TextInjector.InjectionOutcome, latency: Double) {
        finishDictationDelivery()
        var recoveryAvailable = false
        if outcome == .verified {
            DictationRecoveryAudioStore.shared.clear()
            recoverAudioMenuItem?.isHidden = true
        } else {
            recoveryAvailable = DictationRecoveryAudioStore.shared.markFailed(error: "Metin teslimi doğrulanamadı")
            recoverAudioMenuItem?.isHidden = !recoveryAvailable
        }
        switch outcome {
        case .verified:
            // Başarı sesi çalınmaz: tuş bırakılınca "mikrofon kapandı" sesi zaten
            // çalıyor; hızlanan akışta ikisi art arda "çift ses" gibi duyuluyordu.
            HapticManager.shared.playSuccess()
            // Başarı bildirimi gösterilmez: metnin ekrana gelmesi yeterli geri
            // bildirimdir. Ada hemen çentiğe geri çekilir.
            RecordingHUD.shared.dismiss(animated: true)
            setStatus(title: "✅", menuText: "Durum: Yapıştırıldı (\(String(format: "%.2f", latency))s)", revertAfter: 1.5)
        case .unverifiable:
            let message = recoveryAvailable ? "Aktarım doğrulanamadı · Ses korundu" : "Aktarım doğrulanamadı · Hedefi kontrol edin"
            RecordingHUD.shared.showNotice(message: message, autoDismissDelay: 2.6)
            setStatus(title: "ℹ️", menuText: message, revertAfter: 2.6)
        case let .targetChanged(reason):
            SoundManager.shared.playCancel()
            HapticManager.shared.playCancel()
            let message = "\(reason) · Metin panoda (⌘V)"
            RecordingHUD.shared.showNotice(message: message, autoDismissDelay: 2.6)
            setStatus(title: "📋", menuText: message, revertAfter: 2.6)
        case .notInserted:
            SoundManager.shared.playCancel()
            HapticManager.shared.playCancel()
            let message = recoveryAvailable ? "Alan güncellenmedi · Ses korundu" : "Alan güncellenmedi · Hedefi kontrol edin"
            RecordingHUD.shared.showError(message: message, autoDismissDelay: 2.6)
            setStatus(title: "📋", menuText: message, revertAfter: 2.6)
        case let .failed(reason):
            SoundManager.shared.playCancel()
            RecordingHUD.shared.showError(message: reason, autoDismissDelay: 3)
            setStatus(title: "⚠️", menuText: reason, revertAfter: 3)
        case .cancelled:
            RecordingHUD.shared.dismiss(animated: true)
            setStatus(title: "ℹ️", menuText: "Aktarım iptal edildi", revertAfter: 1.5)
        }
    }

    private func handleCancel() {
        liveTranslation?.cancel()
        liveTranslation = nil
        activeDictationConfig = nil
        deliveryGate.finish()
        TextInjector.shared.cancelPendingInjections()
        recordingStartCoordinator.finish()
        activeStartLatencyTrace?.finish(reason: "cancelled")
        activeStartLatencyTrace = nil
        if isPreparingRecord {
            cancelPendingRecordStart(reason: "cancelledPreparing")
            return
        }

        activeAccessibilityLease?.end()
        activeAccessibilityLease = nil
        activeTargetContext = nil
        postRollWorkItem?.cancel()
        postRollWorkItem = nil
        isFinishingRecord = false
        // Recorder cancel önce tamamlanır; böylece tap'ten üretilmiş ve sıraya
        // alınmış son PCM blokları, canlı oturum kapatılmadan önce güvenle
        // tüketilir (cancel akışında teslim edilmez ama yarışamaz).
        AudioRecorder.shared.cancel()
        currentLiveSession?.cancel()
        currentLiveSession = nil
        lastRecordedAudioData = nil
        SystemAudioManager.shared.restoreAfterDictation()
        BackgroundAudioController.shared.handleDictationEnded(config: ConfigManager.shared.config)
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
        refreshPermissionSnapshot()
        if permissionSnapshot?.speechStatus == .authorized {
            Transcriber.shared.warmAppleSpeech(language: ConfigManager.shared.config.language)
        }
        refreshMenuStates()
        SettingsWindowController.shared.loadValues()
    }

    @objc private func selectGroqProvider() {
        ConfigManager.shared.update { $0.provider = "groq" }
        refreshPermissionSnapshot()
        refreshMenuStates()
        SettingsWindowController.shared.loadValues()
    }

    @objc private func selectGeminiProvider() {
        ConfigManager.shared.update { $0.provider = "gemini" }
        refreshPermissionSnapshot()
        refreshMenuStates()
        SettingsWindowController.shared.loadValues()
    }

    @objc private func selectAssemblyAIProvider() {
        ConfigManager.shared.update { $0.provider = "assemblyai" }
        refreshPermissionSnapshot()
        refreshMenuStates()
        SettingsWindowController.shared.loadValues()
    }

    @objc private func selectSedaProvider() {
        ConfigManager.shared.update { $0.provider = "seda"; $0.language = "tr" }
        refreshPermissionSnapshot()
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
        refreshHistoryMenu()
        refreshMenuStates()
        SettingsWindowController.shared.loadValues()
    }

    @objc private func toggleDirectTyping() {
        let current = ConfigManager.shared.config.type_text_directly
        ConfigManager.shared.update { $0.type_text_directly = !current }
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

        guard ConfigManager.shared.config.save_history else {
            historyParentMenuItem?.title = "Son Dikteler (Kapalı)"
            let disabledItem = NSMenuItem(title: "(Geçmiş kaydı kapalı)", action: nil, keyEquivalent: "")
            disabledItem.isEnabled = false
            menu.addItem(disabledItem)
            return
        }

        historyParentMenuItem?.title = "Son Dikteler"
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
            let exportItem = NSMenuItem(title: "Markdown Olarak Dışa Aktar", action: #selector(exportHistoryAction), keyEquivalent: "")
            exportItem.target = self
            menu.addItem(exportItem)
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

    @objc private func exportHistoryAction() {
        do {
            let url = try DictationHistoryManager.shared.exportToFile()
            NSWorkspace.shared.activateFileViewerSelecting([url])
            setStatus(title: "📝", menuText: "Geçmiş Markdown olarak aktarıldı", revertAfter: 2.0)
        } catch {
            setStatus(title: "⚠️", menuText: "Dışa aktarma hatası: \(error.localizedDescription)", revertAfter: 2.0)
        }
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

    private func cleanupActiveDictationForTermination() {
        deliveryGate.finish()
        TextInjector.shared.cancelPendingInjections()
        postRollWorkItem?.cancel()
        postRollWorkItem = nil
        activeAccessibilityLease?.end()
        activeAccessibilityLease = nil
        currentLiveSession?.cancel()
        currentLiveSession = nil
        Transcriber.shared.cancel()
        AudioRecorder.shared.cleanTeardown()
        SystemAudioManager.shared.restoreAfterDictation()
        BackgroundAudioController.shared.handleDictationEnded(config: ConfigManager.shared.config)
        BackgroundAudioController.shared.waitForPendingWork()
        RecordingHUD.shared.dismiss(animated: false)
        isFinishingRecord = false
        isTranscribing = false
    }

    @objc private func quitApp() {
        isExplicitQuit = true
        KeyListener.shared.stop()
        GlobeKeySuppressor.shared.restoreOriginal()
        cleanupActiveDictationForTermination()
        NSApplication.shared.terminate(nil)
    }

    public func applicationWillTerminate(_ notification: Notification) {
        readAloudBrowserBridge.stop()
        readAloudHotKey.stop()
        readAloud.shutdown()
        GlobeKeySuppressor.shared.restoreOriginal()
        cleanupActiveDictationForTermination()
    }

    // MARK: - Dock & Görev Çubuğu Yönetimi

    public func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // Popüler macOS yardımcı uygulamaları standardı (Rectangle, 1Password, Raycast):
        // Ayarlar penceresi kapatıldığında uygulama asla sonlandırılmaz,
        // menü çubuğunda (taskbar) ve arka plan kısayol dinleyicisinde kesintisiz çalışmaya devam eder.
        return false
    }

    public func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // Cmd+Q ve Dock > Çıkış, macOS kullanıcı beklentisine uygun olarak
        // uygulamayı gerçekten kapatır. Menü çubuğu uygulaması olduğu için
        // ayar penceresini kapatmak uygulamayı sonlandırmaz; bu callback yalnızca
        // gerçek terminate isteği geldiğinde çalışır.
        isExplicitQuit = true
        SettingsWindowController.shared.window?.close()
        AccessibilityPromptController.shared.window?.close()
        return .terminateNow
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


extension AppDelegate: NSMenuDelegate {
    public func menuWillOpen(_ menu: NSMenu) {
        refreshMenuStates()
    }
}
