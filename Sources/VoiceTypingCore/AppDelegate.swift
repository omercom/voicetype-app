import Foundation
import AppKit

public class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var statusMenuItem: NSMenuItem!
    private var groqMenuItem: NSMenuItem!
    private var geminiMenuItem: NSMenuItem!
    private var holdModeMenuItem: NSMenuItem!
    private var smartModeMenuItem: NSMenuItem!
    private var toggleModeMenuItem: NSMenuItem!
    private var soundEffectsMenuItem: NSMenuItem!
    private var restoreClipboardMenuItem: NSMenuItem!
    private var triggerKeyMenuItems: [NSMenuItem] = []

    private var isTranscribing: Bool = false
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
        // Menu Bar Status Item Oluştur
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.title = "🎙️"
            button.toolTip = readyToolTip
        }

        buildMenu()

        // Ayarlar güncellendiğinde menüyü yenile
        SettingsWindowController.shared.onConfigUpdated = { [weak self] in
            self?.refreshMenuStates()
        }

        // KeyListener bağla
        setupKeyListener()

        // Başlangıç izin kontrolü
        let mic = PermissionManager.shared.getMicrophoneStatus()
        let acc = PermissionManager.shared.getAccessibilityStatus()

        if !acc.status.isAuthorized || !mic.status.isAuthorized {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                SettingsWindowController.shared.showWindow(nil)
            }
        }
    }

    private func buildMenu() {
        let menu = NSMenu()

        // 1. Durum Satırı
        statusMenuItem = NSMenuItem(title: readyMenuText, action: nil, keyEquivalent: "")
        statusMenuItem.isEnabled = false
        menu.addItem(statusMenuItem)

        menu.addItem(NSMenuItem.separator())

        // 2. Ayarlar Penceresi
        let settingsItem = NSMenuItem(title: "⚙️ Ayarlar & İzin Yönetimi...", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        menu.addItem(NSMenuItem.separator())

        // 3. Sağlayıcı Submenu
        let providerMenu = NSMenu()
        groqMenuItem = NSMenuItem(title: "Groq Whisper (~0.3s Hızlı)", action: #selector(selectGroqProvider), keyEquivalent: "")
        groqMenuItem.target = self
        providerMenu.addItem(groqMenuItem)

        geminiMenuItem = NSMenuItem(title: "Google Gemini (Doğal Dil)", action: #selector(selectGeminiProvider), keyEquivalent: "")
        geminiMenuItem.target = self
        providerMenu.addItem(geminiMenuItem)

        let providerParent = NSMenuItem(title: "Sağlayıcı (Provider)", action: nil, keyEquivalent: "")
        providerParent.submenu = providerMenu
        menu.addItem(providerParent)

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

        // 5. Tetikleyici Tuş Submenu (Hızlı Erişim)
        let keyMenu = NSMenu()
        let quickKeys: [(Int, String)] = [
            (54, "Sağ Command (Right ⌘)"),
            (58, "Sol Option (Left ⌥)"),
            (61, "Sağ Option (Right ⌥)"),
            (62, "Sağ Control (Right ⌃)"),
            (63, "Fn / Globe (🌐 fn)")
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
        let customizeItem = NSMenuItem(title: "⚙️ Özel Tuş Ata (Ayarlar)...", action: #selector(openSettingsShortcutTab), keyEquivalent: "")
        customizeItem.target = self
        keyMenu.addItem(customizeItem)

        let keyParent = NSMenuItem(title: "⌨️ Tetikleyici Tuş", action: nil, keyEquivalent: "")
        keyParent.submenu = keyMenu
        menu.addItem(keyParent)

        // 6. Ses Efektleri Toggle
        soundEffectsMenuItem = NSMenuItem(title: "🔊 Ses Efektleri", action: #selector(toggleSoundEffects), keyEquivalent: "")
        soundEffectsMenuItem.target = self
        menu.addItem(soundEffectsMenuItem)

        // 7. Panoyu Geri Yükle Toggle
        restoreClipboardMenuItem = NSMenuItem(title: "📋 Panoyu Geri Yükle", action: #selector(toggleRestoreClipboard), keyEquivalent: "")
        restoreClipboardMenuItem.target = self
        menu.addItem(restoreClipboardMenuItem)

        menu.addItem(NSMenuItem.separator())

        // 8. Test Kaydı
        let testItem = NSMenuItem(title: "🧪 2 Sn Test Kaydı Yap...", action: #selector(testRecordAction), keyEquivalent: "t")
        testItem.target = self
        menu.addItem(testItem)

        menu.addItem(NSMenuItem.separator())

        // 9. Çıkış
        let quitItem = NSMenuItem(title: "🚪 Çıkış (Quit)", action: #selector(quitApp), keyEquivalent: "q")
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

        SoundManager.shared.isEnabled = cfg.play_sounds

        if let button = statusItem.button {
            button.toolTip = readyToolTip
        }
        statusMenuItem.title = readyMenuText
    }

    private func setupKeyListener() {
        let listener = KeyListener.shared

        listener.isBusy = { [weak self] in
            return self?.isTranscribing ?? false
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
            self?.revertStatusTimer?.invalidate()
            self?.revertStatusTimer = nil

            if let button = self?.statusItem.button {
                button.title = title
            }
            self?.statusMenuItem.title = menuText

            if let delay = revertAfter {
                self?.revertStatusTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
                    guard let self = self else { return }
                    if let button = self.statusItem.button {
                        button.title = "🎙️"
                    }
                    self.statusMenuItem.title = self.readyMenuText
                }
            }
        }
    }

    // MARK: - Kayıt ve Deşifre Döngüsü

    private func handleRecordStart() {
        guard !isTranscribing else { return }

        let started = AudioRecorder.shared.start()
        if started {
            SoundManager.shared.playStart()
            setStatus(title: "🔴 Dinliyor...", menuText: "Durum: Dinleniyor (Konuşun)...")
        } else {
            SoundManager.shared.playCancel()
            setStatus(title: "⚠️ Hata", menuText: "Durum: Mikrofon Başlatılamadı!", revertAfter: 2.0)
        }
    }

    private func handleRecordStop(duration: Double) {
        let config = ConfigManager.shared.config

        let (data, actualDuration) = AudioRecorder.shared.stop()

        guard actualDuration >= config.min_record_duration else {
            // Çok kısa basma - kazara dokunma
            setStatus(title: "🎙️", menuText: readyMenuText)
            return
        }

        guard let audioData = data, !audioData.isEmpty else {
            // Sessizlik veya ses alınamadı
            setStatus(title: "🎙️", menuText: readyMenuText)
            return
        }

        SoundManager.shared.playStop()
        isTranscribing = true
        setStatus(title: "⏳ Yazıyor...", menuText: "Durum: Deşifre Ediliyor...")

        Transcriber.shared.transcribe(audioData: audioData, config: config) { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.isTranscribing = false

                if result.success {
                    if !result.text.isEmpty {
                        TextInjector.shared.paste(
                            text: result.text,
                            restoreClipboard: config.restore_clipboard,
                            pasteDelayMs: config.paste_delay_ms
                        )
                        SoundManager.shared.playSuccess()
                        self.setStatus(
                            title: "✅",
                            menuText: "Durum: Yapıştırıldı (\(String(format: "%.2f", result.latency))s)",
                            revertAfter: 1.5
                        )
                    } else {
                        self.setStatus(title: "🎙️", menuText: self.readyMenuText)
                    }
                } else {
                    SoundManager.shared.playCancel()
                    let err = result.error ?? "Bilinmeyen hata"
                    self.setStatus(title: "⚠️ Hata", menuText: "Hata: \(err)", revertAfter: 3.0)
                }
            }
        }
    }

    private func handleCancel() {
        AudioRecorder.shared.cancel()
        Transcriber.shared.cancel()
        isTranscribing = false
        SoundManager.shared.playCancel()
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
        NSApplication.shared.terminate(nil)
    }
}
