import Foundation
import AppKit

private class FlippedContentView: NSView {
    override var isFlipped: Bool { return true }
}

public class SettingsWindowController: NSWindowController {
    public static let shared = SettingsWindowController()

    // UI Referansları
    private var micStatusLabel: NSTextField!
    private var accStatusLabel: NSTextField!

    private var providerPopUp: NSPopUpButton!
    private var groqKeyField: NSSecureTextField!
    private var groqModelPopUp: NSPopUpButton!
    private var geminiKeyField: NSSecureTextField!
    private var geminiModelPopUp: NSPopUpButton!
    private var languageField: NSTextField!

    private var modePopUp: NSPopUpButton!
    private var playSoundsCheckbox: NSButton!
    private var restoreClipboardCheckbox: NSButton!

    private var statusMessageLabel: NSTextField!

    public var onConfigUpdated: (() -> Void)?

    private init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 680),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "⚙️ Voice Typing - Ayarlar ve İzin Yönetimi"
        window.center()
        window.isReleasedWhenClosed = false
        super.init(window: window)

        setupUI()
        loadValues()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    public override func showWindow(_ sender: Any?) {
        refreshPermissionStatuses()
        loadValues()
        super.showWindow(sender)
        window?.makeKeyAndOrderFront(sender)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func setupUI() {
        guard let contentView = window?.contentView else { return }

        let scrollView = NSScrollView(frame: contentView.bounds)
        scrollView.autoresizingMask = [.width, .height]
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false

        let container = FlippedContentView(frame: NSRect(x: 0, y: 0, width: 600, height: 660))
        scrollView.documentView = container
        contentView.addSubview(scrollView)

        var y: CGFloat = 15

        // =====================================================================
        // 1. ÜST BÖLÜM: İZİNLER (Microphone & Accessibility)
        // =====================================================================
        let permBox = NSBox(frame: NSRect(x: 20, y: y, width: 560, height: 140))
        permBox.title = "🛡️ macOS Sistem İzinleri (Gerekli)"
        permBox.titleFont = NSFont.boldSystemFont(ofSize: 13)

        // Mikrofon İzni
        let micLabel = NSTextField(labelWithString: "Mikrofon İzni:")
        micLabel.frame = NSRect(x: 15, y: 80, width: 100, height: 20)
        micLabel.font = NSFont.systemFont(ofSize: 12)
        permBox.contentView?.addSubview(micLabel)

        micStatusLabel = NSTextField(labelWithString: "🟢 Yetki Verildi")
        micStatusLabel.frame = NSRect(x: 120, y: 80, width: 230, height: 20)
        micStatusLabel.font = NSFont.systemFont(ofSize: 11)
        permBox.contentView?.addSubview(micStatusLabel)

        let micBtn = NSButton(frame: NSRect(x: 355, y: 77, width: 190, height: 26))
        micBtn.title = "Sistem Ayarlarını Aç"
        micBtn.bezelStyle = .rounded
        micBtn.target = self
        micBtn.action = #selector(openMicSettingsClicked)
        permBox.contentView?.addSubview(micBtn)

        // Erişilebilirlik İzni
        let accLabel = NSTextField(labelWithString: "Erişilebilirlik:")
        accLabel.frame = NSRect(x: 15, y: 45, width: 100, height: 20)
        accLabel.font = NSFont.systemFont(ofSize: 12)
        permBox.contentView?.addSubview(accLabel)

        accStatusLabel = NSTextField(labelWithString: "🟢 Yetki Verildi")
        accStatusLabel.frame = NSRect(x: 120, y: 45, width: 230, height: 20)
        accStatusLabel.font = NSFont.systemFont(ofSize: 11)
        permBox.contentView?.addSubview(accStatusLabel)

        let accBtn = NSButton(frame: NSRect(x: 355, y: 42, width: 190, height: 26))
        accBtn.title = "Sistem Ayarlarını Aç"
        accBtn.bezelStyle = .rounded
        accBtn.target = self
        accBtn.action = #selector(openAccSettingsClicked)
        permBox.contentView?.addSubview(accBtn)

        // İzinleri Yenile Butonu
        let refreshBtn = NSButton(frame: NSRect(x: 355, y: 10, width: 190, height: 24))
        refreshBtn.title = "🔄 İzin Durumunu Yenile"
        refreshBtn.bezelStyle = .inline
        refreshBtn.target = self
        refreshBtn.action = #selector(refreshPermissionStatuses)
        permBox.contentView?.addSubview(refreshBtn)

        container.addSubview(permBox)
        y += 150

        // =====================================================================
        // 2. ORTA BÖLÜM: YAPAY ZEKA MODELİ VE SAĞLAYICI
        // =====================================================================
        let aiBox = NSBox(frame: NSRect(x: 20, y: y, width: 560, height: 260))
        aiBox.title = "🤖 Yapay Zeka Sağlayıcısı ve Modeller"
        aiBox.titleFont = NSFont.boldSystemFont(ofSize: 13)

        // Aktif Sağlayıcı
        let provLabel = NSTextField(labelWithString: "Aktif Sağlayıcı:")
        provLabel.frame = NSRect(x: 15, y: 200, width: 130, height: 20)
        aiBox.contentView?.addSubview(provLabel)

        providerPopUp = NSPopUpButton(frame: NSRect(x: 150, y: 198, width: 390, height: 26), pullsDown: false)
        providerPopUp.addItem(withTitle: "Groq Whisper (~0.3s Ultra Hızlı - Önerilen)")
        providerPopUp.addItem(withTitle: "Google Gemini (Doğal Dil & Bağlamsal)")
        aiBox.contentView?.addSubview(providerPopUp)

        // Groq API Key
        let groqKeyLabel = NSTextField(labelWithString: "Groq API Key:")
        groqKeyLabel.frame = NSRect(x: 15, y: 165, width: 130, height: 20)
        aiBox.contentView?.addSubview(groqKeyLabel)

        groqKeyField = NSSecureTextField(frame: NSRect(x: 150, y: 165, width: 390, height: 22))
        groqKeyField.placeholderString = "gsk_..."
        aiBox.contentView?.addSubview(groqKeyField)

        // Groq Modeli
        let groqModelLabel = NSTextField(labelWithString: "Groq Modeli:")
        groqModelLabel.frame = NSRect(x: 15, y: 130, width: 130, height: 20)
        aiBox.contentView?.addSubview(groqModelLabel)

        groqModelPopUp = NSPopUpButton(frame: NSRect(x: 150, y: 128, width: 390, height: 26), pullsDown: false)
        for m in ConfigManager.availableGroqModels {
            groqModelPopUp.addItem(withTitle: "\(m.name) [\(m.price)] - \(m.speed)")
        }
        aiBox.contentView?.addSubview(groqModelPopUp)

        // Gemini API Key
        let geminiKeyLabel = NSTextField(labelWithString: "Gemini API Key:")
        geminiKeyLabel.frame = NSRect(x: 15, y: 95, width: 130, height: 20)
        aiBox.contentView?.addSubview(geminiKeyLabel)

        geminiKeyField = NSSecureTextField(frame: NSRect(x: 150, y: 95, width: 390, height: 22))
        geminiKeyField.placeholderString = "AIzaSy..."
        aiBox.contentView?.addSubview(geminiKeyField)

        // Gemini Modeli
        let geminiModelLabel = NSTextField(labelWithString: "Gemini Modeli:")
        geminiModelLabel.frame = NSRect(x: 15, y: 60, width: 130, height: 20)
        aiBox.contentView?.addSubview(geminiModelLabel)

        geminiModelPopUp = NSPopUpButton(frame: NSRect(x: 150, y: 58, width: 390, height: 26), pullsDown: false)
        for m in ConfigManager.availableGeminiModels {
            geminiModelPopUp.addItem(withTitle: "\(m.name) [\(m.price)] - \(m.speed)")
        }
        aiBox.contentView?.addSubview(geminiModelPopUp)

        // Dil (Language)
        let langLabel = NSTextField(labelWithString: "Konuşma Dili:")
        langLabel.frame = NSRect(x: 15, y: 25, width: 130, height: 20)
        aiBox.contentView?.addSubview(langLabel)

        languageField = NSTextField(frame: NSRect(x: 150, y: 25, width: 120, height: 22))
        languageField.placeholderString = "tr (veya auto, en)"
        aiBox.contentView?.addSubview(languageField)

        let langHint = NSTextField(labelWithString: "('tr': Türkçe, 'en': İngilizce, 'auto': Otomatik algıla)")
        langHint.frame = NSRect(x: 280, y: 25, width: 260, height: 20)
        langHint.font = NSFont.systemFont(ofSize: 11)
        langHint.textColor = .secondaryLabelColor
        aiBox.contentView?.addSubview(langHint)

        container.addSubview(aiBox)
        y += 270

        // =====================================================================
        // 3. TERCİHLER VE DAVRANIŞ (Preferences)
        // =====================================================================
        let prefBox = NSBox(frame: NSRect(x: 20, y: y, width: 560, height: 130))
        prefBox.title = "⚙️ Çalışma Tercihleri"
        prefBox.titleFont = NSFont.boldSystemFont(ofSize: 13)

        // Tetikleme Modu
        let modeLabel = NSTextField(labelWithString: "Tetikleme Modu:")
        modeLabel.frame = NSRect(x: 15, y: 75, width: 130, height: 20)
        prefBox.contentView?.addSubview(modeLabel)

        modePopUp = NSPopUpButton(frame: NSRect(x: 150, y: 73, width: 390, height: 26), pullsDown: false)
        modePopUp.addItem(withTitle: "Basılı Tut (Push-to-Talk) - Sağ Cmd basılı tut konuş, bırak yaz")
        modePopUp.addItem(withTitle: "Akıllı Hibrit (Smart) - Kısa tıkla aç-kapa, uzun bas tut-konuş")
        modePopUp.addItem(withTitle: "Aç / Kapa (Toggle) - Tıkla başlasın, tıkla dursun")
        prefBox.contentView?.addSubview(modePopUp)

        // Ses Efektleri Checkbox
        playSoundsCheckbox = NSButton(checkboxWithTitle: "Sistem ses efektlerini çal (Tink, Pop, Glass)", target: nil, action: nil)
        playSoundsCheckbox.frame = NSRect(x: 15, y: 45, width: 400, height: 20)
        prefBox.contentView?.addSubview(playSoundsCheckbox)

        // Panoyu Geri Yükle Checkbox
        restoreClipboardCheckbox = NSButton(checkboxWithTitle: "Metin yapıştırıldıktan sonra eski panoyu geri yükle", target: nil, action: nil)
        restoreClipboardCheckbox.frame = NSRect(x: 15, y: 20, width: 450, height: 20)
        prefBox.contentView?.addSubview(restoreClipboardCheckbox)

        container.addSubview(prefBox)
        y += 140

        // =====================================================================
        // 4. ALT BÖLÜM: BİLGİLENDİRME VE BUTONLAR
        // =====================================================================
        statusMessageLabel = NSTextField(labelWithString: "")
        statusMessageLabel.frame = NSRect(x: 20, y: y, width: 560, height: 20)
        statusMessageLabel.font = NSFont.systemFont(ofSize: 11)
        statusMessageLabel.textColor = .secondaryLabelColor
        container.addSubview(statusMessageLabel)
        y += 26

        let testBtn = NSButton(frame: NSRect(x: 20, y: y, width: 180, height: 32))
        testBtn.title = "🧪 2 Sn Test Kaydı Yap"
        testBtn.bezelStyle = .rounded
        testBtn.target = self
        testBtn.action = #selector(testRecordClicked)
        container.addSubview(testBtn)

        let cancelBtn = NSButton(frame: NSRect(x: 350, y: y, width: 100, height: 32))
        cancelBtn.title = "Kapat"
        cancelBtn.bezelStyle = .rounded
        cancelBtn.target = self
        cancelBtn.action = #selector(closeClicked)
        container.addSubview(cancelBtn)

        let saveBtn = NSButton(frame: NSRect(x: 460, y: y, width: 120, height: 32))
        saveBtn.title = "💾 Kaydet"
        saveBtn.bezelStyle = .rounded
        saveBtn.keyEquivalent = "\r"
        saveBtn.target = self
        saveBtn.action = #selector(saveClicked)
        container.addSubview(saveBtn)
    }

    @objc public func refreshPermissionStatuses() {
        let mic = PermissionManager.shared.getMicrophoneStatus()
        micStatusLabel.stringValue = "\(mic.badge) \(mic.description)"
        switch mic.status {
        case .authorized:
            micStatusLabel.textColor = .systemGreen
        case .denied:
            micStatusLabel.textColor = .systemRed
        default:
            micStatusLabel.textColor = .systemOrange
        }

        let acc = PermissionManager.shared.getAccessibilityStatus()
        accStatusLabel.stringValue = "\(acc.badge) \(acc.description)"
        switch acc.status {
        case .authorized:
            accStatusLabel.textColor = .systemGreen
        case .denied:
            accStatusLabel.textColor = .systemRed
        default:
            accStatusLabel.textColor = .systemOrange
        }
    }

    private func loadValues() {
        let cfg = ConfigManager.shared.config

        // Provider
        if cfg.provider.lowercased() == "gemini" {
            providerPopUp.selectItem(at: 1)
        } else {
            providerPopUp.selectItem(at: 0)
        }

        // Groq
        groqKeyField.stringValue = cfg.groq_api_key
        if let idx = ConfigManager.availableGroqModels.firstIndex(where: { $0.id == cfg.groq_model }) {
            groqModelPopUp.selectItem(at: idx)
        }

        // Gemini
        geminiKeyField.stringValue = cfg.gemini_api_key
        if let idx = ConfigManager.availableGeminiModels.firstIndex(where: { $0.id == cfg.gemini_model }) {
            geminiModelPopUp.selectItem(at: idx)
        }

        // Language
        languageField.stringValue = cfg.language

        // Mode
        switch cfg.trigger_mode.lowercased() {
        case "smart":
            modePopUp.selectItem(at: 1)
        case "toggle":
            modePopUp.selectItem(at: 2)
        default:
            modePopUp.selectItem(at: 0)
        }

        // Checkboxes
        playSoundsCheckbox.state = cfg.play_sounds ? .on : .off
        restoreClipboardCheckbox.state = cfg.restore_clipboard ? .on : .off

        statusMessageLabel.stringValue = "Ayarlar config.json dosyasından başarıyla yüklendi."
    }

    @objc private func openMicSettingsClicked() {
        PermissionManager.shared.openMicrophoneSettings()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            self?.refreshPermissionStatuses()
        }
    }

    @objc private func openAccSettingsClicked() {
        PermissionManager.shared.openAccessibilitySettings()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            self?.refreshPermissionStatuses()
        }
    }

    @objc private func closeClicked() {
        window?.close()
    }

    @objc private func saveClicked() {
        let selectedProvider = providerPopUp.indexOfSelectedItem == 1 ? "gemini" : "groq"
        let groqKey = groqKeyField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let geminiKey = geminiKeyField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)

        let groqIdx = max(0, groqModelPopUp.indexOfSelectedItem)
        let groqModel = ConfigManager.availableGroqModels[groqIdx].id

        let geminiIdx = max(0, geminiModelPopUp.indexOfSelectedItem)
        let geminiModel = ConfigManager.availableGeminiModels[geminiIdx].id

        let language = languageField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)

        let modeStr: String
        switch modePopUp.indexOfSelectedItem {
        case 1: modeStr = "smart"
        case 2: modeStr = "toggle"
        default: modeStr = "hold"
        }

        let playSounds = playSoundsCheckbox.state == .on
        let restoreClip = restoreClipboardCheckbox.state == .on

        let success = ConfigManager.shared.update { cfg in
            cfg.provider = selectedProvider
            cfg.groq_api_key = groqKey
            cfg.gemini_api_key = geminiKey
            cfg.groq_model = groqModel
            cfg.gemini_model = geminiModel
            cfg.language = language.isEmpty ? "tr" : language
            cfg.trigger_mode = modeStr
            cfg.play_sounds = playSounds
            cfg.restore_clipboard = restoreClip
        }

        SoundManager.shared.isEnabled = playSounds

        if success {
            statusMessageLabel.stringValue = "✅ Ayarlar başarıyla kaydedildi ve uygulandı!"
            statusMessageLabel.textColor = .systemGreen
            SoundManager.shared.playSuccess()
            onConfigUpdated?()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
                self?.window?.close()
            }
        } else {
            statusMessageLabel.stringValue = "❌ Kayıt başarısız oldu! config.json yazılamadı."
            statusMessageLabel.textColor = .systemRed
            SoundManager.shared.playCancel()
        }
    }

    @objc private func testRecordClicked() {
        statusMessageLabel.stringValue = "🎙️ 2 saniyelik test kaydı yapılıyor, lütfen konuşun..."
        statusMessageLabel.textColor = .systemBlue
        SoundManager.shared.playStart()

        let started = AudioRecorder.shared.start()
        guard started else {
            statusMessageLabel.stringValue = "❌ Test kaydı başlatılamadı (Mikrofon erişimi kontrol edin)."
            statusMessageLabel.textColor = .systemRed
            SoundManager.shared.playCancel()
            return
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            let (data, dur) = AudioRecorder.shared.stop()
            SoundManager.shared.playStop()

            guard let audioData = data, !audioData.isEmpty else {
                self?.statusMessageLabel.stringValue = "⚠️ Ses algılanmadı (Sessizlik veya mikrofon kapalı)."
                self?.statusMessageLabel.textColor = .systemOrange
                SoundManager.shared.playCancel()
                return
            }

            self?.statusMessageLabel.stringValue = "⏳ Deşifre ediliyor (\(String(format: "%.1f", dur)) sn ses)..."

            var testConfig = ConfigManager.shared.config
            if let strongSelf = self {
                let selectedProvider = strongSelf.providerPopUp.indexOfSelectedItem == 1 ? "gemini" : "groq"
                testConfig.provider = selectedProvider
                testConfig.groq_api_key = strongSelf.groqKeyField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
                testConfig.gemini_api_key = strongSelf.geminiKeyField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
                let groqIdx = max(0, strongSelf.groqModelPopUp.indexOfSelectedItem)
                if groqIdx < ConfigManager.availableGroqModels.count {
                    testConfig.groq_model = ConfigManager.availableGroqModels[groqIdx].id
                }
                let geminiIdx = max(0, strongSelf.geminiModelPopUp.indexOfSelectedItem)
                if geminiIdx < ConfigManager.availableGeminiModels.count {
                    testConfig.gemini_model = ConfigManager.availableGeminiModels[geminiIdx].id
                }
                let lang = strongSelf.languageField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
                if !lang.isEmpty { testConfig.language = lang }
            }

            Transcriber.shared.transcribe(audioData: audioData, config: testConfig) { res in
                DispatchQueue.main.async {
                    if res.success {
                        self?.statusMessageLabel.stringValue = "✅ Başarılı (\(String(format: "%.2f", res.latency)) sn): \"\(res.text)\""
                        self?.statusMessageLabel.textColor = .systemGreen
                        SoundManager.shared.playSuccess()
                    } else {
                        self?.statusMessageLabel.stringValue = "❌ Deşifre Hatası: \(res.error ?? "Bilinmeyen hata")"
                        self?.statusMessageLabel.textColor = .systemRed
                        SoundManager.shared.playCancel()
                    }
                }
            }
        }
    }
}
