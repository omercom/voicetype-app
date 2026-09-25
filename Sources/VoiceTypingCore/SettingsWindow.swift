import Foundation
import AppKit

private class FlippedContentView: NSView {
    override var isFlipped: Bool { return true }
}

public class SettingsWindowController: NSWindowController, NSWindowDelegate, NSToolbarDelegate, NSTextFieldDelegate, NSTextViewDelegate {
    public static let shared = SettingsWindowController()

    // Header & Tab Navigation
    private var segmentedControl: NSSegmentedControl!
    private var tabView: NSTabView!
    private var toolbar: NSToolbar!

    // Tab 1: Genel & Kısayol
    private var triggerKeyPopUp: NSPopUpButton!
    private var recordKeyButton: NSButton!
    private var triggerKeyHintLabel: NSTextField!
    private var modeSegmentedControl: NSSegmentedControl!
    private var modePopUp: NSPopUpButton!
    private var modeInfoLabel: NSTextField!
    private var customVocabField: NSTextField!
    // Tab 2: Gemini Sistem İstemi & Prompt Şablonları
    private var promptSectionLabel: NSTextField!
    private var geminiPromptPresetPopUp: NSPopUpButton!
    private var geminiPromptTextView: NSTextView!
    private var geminiPromptScrollView: NSScrollView!
    private var promptNoteLabel: NSTextField!
    private var promptUnsupportedLabel: NSTextField!

    private let promptPresets: [(name: String, prompt: String)] = [
        (
            "Varsayılan (Doğal Dikte - Konuşulanı Yorumsuz Yaz)",
            "Sen profesyonel bir ses deşifre asistanısın. Kullanıcının konuşmasını dinle ve doğrudan yazıya dök. Asla selamlama, özet, onaylama ('Tabii ki', 'Anladım' gibi) veya fazladan yorum ekleme; sadece konuşulan metni temiz, doğru imla ve akıcı bir dille yaz."
        ),
        (
            "Profesyonel / E-posta (Resmi Dilbilgisi & İmla)",
            "Sen bir yönetici asistanısın. Konuşulan metni resmi, kurumsal ve net bir e-posta / iş yazışması üslubuna dönüştür. İmla ve noktalama kurallarına tam uy, gereksiz laf kalabalıklarını temizle. Sadece nihai metni yaz."
        ),
        (
            "Madde İmleri & Notlar (Tireli Liste Biçimi)",
            "Konuşmayı önemli fikirler ve yapılacak işler (action items) halinde alt alta tireli maddeler (- ...) biçiminde özetle ve listele. Başka hiçbir giriş veya kapanış cümlesi ekleme."
        ),
        (
            "Yazılımcı / Teknik (Kod, Değişken ve Terimleri Koru)",
            "Yazılım geliştiricisi için dikte yapıyorsun. Teknik terimleri, komutları, fonksiyon adlarını, camelCase veya snake_case yapıları kesinlikle bozmadan, doğru İngilizce/Türkçe teknik terminolojiyle yaz."
        ),
        (
            "İngilizceye Çevirerek Yaz (Anında Canlı Çeviri)",
            "Kullanıcının Türkçe veya farklı dilde söylediği sözleri anında akıcı, doğal ve grameri kusursuz bir İngilizce'ye çevirerek yaz. Yalnızca İngilizce çeviriyi döndür, yorum ekleme."
        ),
        (
            "Özel İstemi Kullan...",
            ""
        )
    ]
    private var languageField: NSTextField!
    private var playSoundsCheckbox: NSButton!
    private var hapticFeedbackCheckbox: NSButton!
    private var removeFillerWordsCheckbox: NSButton!
    private var saveHistoryCheckbox: NSButton!
    private var muteSystemAudioCheckbox: NSButton!
    private var backgroundAudioPopUp: NSPopUpButton!
    private var micBoostCheckbox: NSButton!
    private var launchAtLoginCheckbox: NSButton!
    private var showDockIconCheckbox: NSButton!
    private var onlyInTextFieldsCheckbox: NSButton!

    // Tab 2: Yapay Zeka & Modeller
    private var providerSegmentedControl: NSSegmentedControl!
    private var providerPopUp: NSPopUpButton!
    private var providerNoteLabel: NSTextField!
    private var appleStatusLabel: NSTextField!
    private var groqKeyField: NSTextField!
    private var groqModelPopUp: NSPopUpButton!
    private var groqStatusLabel: NSTextField!
    private var geminiKeyField: NSTextField!
    private var geminiModelPopUp: NSPopUpButton!
    private var geminiStatusLabel: NSTextField!
    private var assemblyAIKeyField: NSTextField!
    private var assemblyAIStatusLabel: NSTextField!
    private var geminiModelOptions: [ModelOption] = ConfigManager.availableGeminiModels

    // Tab: Gelişmiş & Kısayollar (Advanced & Snippets)
    private var autoSubmitCheckbox: NSButton!
    private var autoSubmitKeyPopUp: NSPopUpButton!
    private var appProfilesCheckbox: NSButton!
    private var soundThemePopUp: NSPopUpButton!
    private var soundVolumeSlider: NSSlider!
    private var hudStylePopUp: NSPopUpButton!
    private var hudNotchNoteLabel: NSTextField!
    private var soundVolumeLabel: NSTextField!
    private var testSoundButton: NSButton!
    private var voiceSnippetsTextView: NSTextView!
    private var voiceSnippetsScrollView: NSScrollView!
    private var restoreClipboardCheckbox: NSButton!

    // Tab 3: Sistem & İzinler
    private var micStatusLabel: NSTextField!
    private var micActionButton: NSButton!
    private var speechStatusLabel: NSTextField!
    private var speechActionButton: NSButton!
    private var accStatusLabel: NSTextField!
    private var accActionButton: NSButton!
    private var accProgressIndicator: NSProgressIndicator!
    private var accGuideLabel: NSTextField!
    private var lastKnownAccStatus: Bool = false
    private var lastKnownMicStatus: Bool = false
    private var lastKnownSpeechStatus: Bool = false
    private var testStatusLabel: NSTextField!
    private var testAudioResultLabel: NSTextField!
    private var testRecordButton: NSButton!

    // Footer
    private var statusMessageLabel: NSTextField!

    // Auto-Save & Debounce Timers
    private var autoSaveDebounceTimer: Timer?
    private var statusResetTimer: Timer?

    // Custom Key Capture State
    private var selectedTriggerKeyCode: Int = 54
    private var isCapturingKey: Bool = false
    private var keyCaptureMonitor: Any?

    public var onConfigUpdated: (() -> Void)?
    private var permissionPollTimer: Timer?

    private let toolbarTabIdentifiers: [NSToolbarItem.Identifier] = [
        NSToolbarItem.Identifier("general"),
        NSToolbarItem.Identifier("ai"),
        NSToolbarItem.Identifier("advanced"),
        NSToolbarItem.Identifier("permissions"),
        NSToolbarItem.Identifier("about")
    ]

    static func aboutVersionText(
        bundle: Bundle = .main,
        fallbackInfoPlistURL: URL? = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("Info.plist")
    ) -> String {
        let bundledVersion = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        var fallbackVersion: String?
        if let url = fallbackInfoPlistURL,
           let data = try? Data(contentsOf: url),
           let propertyList = try? PropertyListSerialization.propertyList(from: data, format: nil),
           let info = propertyList as? [String: Any] {
            fallbackVersion = info["CFBundleShortVersionString"] as? String
        }
        let version = bundledVersion ?? fallbackVersion ?? "Geliştirme"
        return "Sürüm \(version) • Native macOS • Apple Silicon & Intel"
    }

    private init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 650, height: 595),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Voice Typing - Ayarlar"
        window.isReleasedWhenClosed = false
        window.level = .normal
        window.hidesOnDeactivate = false
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.toolbarStyle = .preference

        super.init(window: window)
        window.delegate = self

        setupToolbar(window: window)
        setupUI()
        loadValues()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // =========================================================================
    // NSToolbar Delegasyonu (TG Pro / Apple Preferences Toolbar Standardı)
    // =========================================================================
    private func setupToolbar(window: NSWindow) {
        toolbar = NSToolbar(identifier: "VoiceTypingPreferencesToolbar")
        toolbar.allowsUserCustomization = false
        toolbar.autosavesConfiguration = false
        toolbar.displayMode = .iconAndLabel
        toolbar.delegate = self
        window.toolbar = toolbar
        toolbar.selectedItemIdentifier = toolbarTabIdentifiers[0]
    }

    public func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        let item = NSToolbarItem(itemIdentifier: itemIdentifier)
        switch itemIdentifier.rawValue {
        case "general":
            item.label = "Genel"
            item.paletteLabel = "Genel"
            item.image = NSImage(systemSymbolName: "command", accessibilityDescription: "Genel")
            item.target = self
            item.action = #selector(toolbarTabClicked(_:))
            return item
        case "ai":
            item.label = "Yapay Zeka"
            item.paletteLabel = "Yapay Zeka"
            item.image = NSImage(systemSymbolName: "brain.head.profile", accessibilityDescription: "Yapay Zeka") ?? NSImage(systemSymbolName: "sparkles", accessibilityDescription: "Yapay Zeka")
            item.target = self
            item.action = #selector(toolbarTabClicked(_:))
            return item
        case "advanced":
            item.label = "Gelişmiş"
            item.paletteLabel = "Gelişmiş & Kısayollar"
            item.image = NSImage(systemSymbolName: "slider.horizontal.3", accessibilityDescription: "Gelişmiş") ?? NSImage(systemSymbolName: "gearshape.2", accessibilityDescription: "Gelişmiş")
            item.target = self
            item.action = #selector(toolbarTabClicked(_:))
            return item
        case "permissions":
            item.label = "İzinler"
            item.paletteLabel = "İzinler"
            item.image = NSImage(systemSymbolName: "checkmark.shield", accessibilityDescription: "İzinler")
            item.target = self
            item.action = #selector(toolbarTabClicked(_:))
            return item
        case "about":
            item.label = "Hakkında"
            item.paletteLabel = "Hakkında"
            item.image = NSImage(systemSymbolName: "info.circle", accessibilityDescription: "Hakkında")
            item.target = self
            item.action = #selector(toolbarTabClicked(_:))
            return item
        default:
            return nil
        }
    }

    public func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        return toolbarTabIdentifiers
    }

    public func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        return toolbarTabIdentifiers
    }

    public func toolbarSelectableItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        return toolbarTabIdentifiers
    }

    @objc private func toolbarTabClicked(_ sender: NSToolbarItem) {
        if let idx = toolbarTabIdentifiers.firstIndex(of: sender.itemIdentifier) {
            selectTab(index: idx)
        }
    }

    // =========================================================================
    // Arayüz Kurulumu (Two-Column Form Grid Layout)
    // =========================================================================
    private func setupUI() {
        guard let window = window, let contentView = window.contentView else { return }

        let mainContainer = FlippedContentView(frame: contentView.bounds)
        mainContainer.autoresizingMask = [.width, .height]
        contentView.addSubview(mainContainer)

        // Testler ve klavye kısayolları için senkronize segmented control
        segmentedControl = NSSegmentedControl(
            labels: ["Genel", "Yapay Zeka", "Gelişmiş", "İzinler", "Hakkında"],
            trackingMode: .selectOne,
            target: self,
            action: #selector(tabSegmentChanged(_:))
        )
        segmentedControl.isHidden = true
        mainContainer.addSubview(segmentedControl)

        // =====================================================================
        // ORTA BÖLÜM: TAB VIEW (NO TABS NO BORDER)
        // =====================================================================
        tabView = NSTabView(frame: NSRect(x: 0, y: 0, width: 650, height: 535))
        tabView.tabViewType = .noTabsNoBorder

        let tab1Item = NSTabViewItem(identifier: "tab1")
        tab1Item.view = buildTab1GeneralView()
        tabView.addTabViewItem(tab1Item)

        let tab2Item = NSTabViewItem(identifier: "tab2")
        tab2Item.view = buildTab2AIProvidersView()
        tabView.addTabViewItem(tab2Item)

        let tab3Item = NSTabViewItem(identifier: "tabAdvanced")
        tab3Item.view = buildTabAdvancedView()
        tabView.addTabViewItem(tab3Item)

        let tab4Item = NSTabViewItem(identifier: "tabPermissions")
        tab4Item.view = buildTab3PermissionsView()
        tabView.addTabViewItem(tab4Item)

        let tab5Item = NSTabViewItem(identifier: "tabAbout")
        tab5Item.view = buildTab4AboutView()
        tabView.addTabViewItem(tab5Item)

        mainContainer.addSubview(tabView)

        // =====================================================================
        // ALT BÖLÜM: FOOTER & ACTIONS
        // =====================================================================
        let bottomSeparator = NSBox(frame: NSRect(x: 24, y: 540, width: 602, height: 1))
        bottomSeparator.boxType = .separator
        mainContainer.addSubview(bottomSeparator)

        statusMessageLabel = NSTextField(labelWithString: "Değişiklikler anında kaydedilir.")
        statusMessageLabel.frame = NSRect(x: 24, y: 554, width: 480, height: 22)
        statusMessageLabel.font = NSFont.systemFont(ofSize: 11)
        statusMessageLabel.textColor = .secondaryLabelColor
        mainContainer.addSubview(statusMessageLabel)

        let closeBtn = NSButton(frame: NSRect(x: 525, y: 550, width: 100, height: 32))
        closeBtn.title = "Kapat"
        closeBtn.bezelStyle = .rounded
        closeBtn.keyEquivalent = "\u{1b}"
        closeBtn.target = self
        closeBtn.action = #selector(closeClicked)
        mainContainer.addSubview(closeBtn)

        window.initialFirstResponder = mainContainer
    }

    @objc private func tabSegmentChanged(_ sender: NSSegmentedControl) {
        selectTab(index: sender.selectedSegment)
    }

    public func selectTab(index: Int) {
        guard index >= 0 && index < tabView.numberOfTabViewItems else { return }

        // Sekme değişirken bekleyen metin alanı otomatik kayıtlarını anında diske yaz
        if autoSaveDebounceTimer != nil {
            autoSaveDebounceTimer?.invalidate()
            autoSaveDebounceTimer = nil
            autoSave(showMessage: false)
        }

        tabView.selectTabViewItem(at: index)
        if index < toolbarTabIdentifiers.count {
            toolbar?.selectedItemIdentifier = toolbarTabIdentifiers[index]
        }
        if index < segmentedControl.segmentCount {
            segmentedControl.selectedSegment = index
        }
        // Sekme değiştiğinde herhangi bir metin kutusunun otomatik seçilmesini (mavi odak çerçevesi ve metin vurgusu) önle
        DispatchQueue.main.async { [weak self] in
            self?.window?.makeFirstResponder(nil)
        }
    }

    // =========================================================================
    // TAB 1: Genel & Kısayol (Two-Column Layout)
    // =========================================================================
    private func buildTab1GeneralView() -> NSView {
        let container = FlippedContentView(frame: NSRect(x: 0, y: 0, width: 650, height: 550))

        // 1. Kısayol Tuşu
        let keyLabel = createSectionLabel(text: "Tetikleyici Tuş", y: 18)
        container.addSubview(keyLabel)

        triggerKeyPopUp = NSPopUpButton(frame: NSRect(x: 175, y: 16, width: 260, height: 26), pullsDown: false)
        for opt in TriggerKeyOption.standardKeys {
            let item = NSMenuItem(title: opt.name, action: nil, keyEquivalent: "")
            item.tag = opt.keyCode
            triggerKeyPopUp.menu?.addItem(item)
        }
        let customChoiceItem = NSMenuItem(title: "Özel Tuş Ata...", action: nil, keyEquivalent: "")
        customChoiceItem.tag = -1
        triggerKeyPopUp.menu?.addItem(customChoiceItem)
        triggerKeyPopUp.target = self
        triggerKeyPopUp.action = #selector(triggerKeyPopUpChanged(_:))
        container.addSubview(triggerKeyPopUp)

        recordKeyButton = NSButton(frame: NSRect(x: 445, y: 15, width: 170, height: 28))
        recordKeyButton.title = "Özel Tuş Yakala"
        recordKeyButton.bezelStyle = .rounded
        recordKeyButton.target = self
        recordKeyButton.action = #selector(recordKeyButtonClicked)
        container.addSubview(recordKeyButton)

        triggerKeyHintLabel = NSTextField(labelWithString: "Aktif Kısayol: Sağ Command (Right ⌘)")
        triggerKeyHintLabel.frame = NSRect(x: 175, y: 46, width: 440, height: 18)
        triggerKeyHintLabel.font = NSFont.systemFont(ofSize: 11)
        triggerKeyHintLabel.textColor = .secondaryLabelColor
        container.addSubview(triggerKeyHintLabel)

        let keyNote = createNoteLabel(text: "Bas-konuş için klavyede başparmağınızla kolayca basabileceğiniz Sağ Command önerilir.", y: 64)
        container.addSubview(keyNote)

        // Ayırıcı
        container.addSubview(createSeparator(y: 92))

        // 2. Tetikleme Modu
        let modeLabel = createSectionLabel(text: "Tetikleme Modu", y: 104)
        container.addSubview(modeLabel)

        modeSegmentedControl = NSSegmentedControl(
            labels: ["Basılı Tut (Push-to-Talk)", "Akıllı Hibrit", "Aç / Kapa"],
            trackingMode: .selectOne,
            target: self,
            action: #selector(modeSegmentedChanged(_:))
        )
        modeSegmentedControl.frame = NSRect(x: 175, y: 102, width: 440, height: 26)
        modeSegmentedControl.segmentStyle = .rounded
        modeSegmentedControl.segmentDistribution = .fillEqually
        modeSegmentedControl.selectedSegment = 0
        container.addSubview(modeSegmentedControl)

        // Gizli yedek popup
        modePopUp = NSPopUpButton(frame: NSRect(x: 175, y: 102, width: 440, height: 26), pullsDown: false)
        modePopUp.addItem(withTitle: "Basılı Tut (Push-to-Talk) - Tuşa basılı tut konuş, bırak yaz")
        modePopUp.addItem(withTitle: "Akıllı Hibrit (Smart) - Kısa tıkla aç-kapa, uzun bas tut-konuş")
        modePopUp.addItem(withTitle: "Aç / Kapa (Toggle) - Tuşa tıkla başlasın, tıkla dursun")
        modePopUp.isHidden = true
        container.addSubview(modePopUp)

        modeInfoLabel = createNoteLabel(text: "Basılı Tut: Tuşa basılı tutun ve konuşun, bıraktığınız anda metin otomatik yapıştırılır.", y: 130)
        container.addSubview(modeInfoLabel)

        // Ayırıcı
        container.addSubview(createSeparator(y: 158))

        // 3. Özel Sözlük (Terim Havuzu)
        let vocabLabel = createSectionLabel(text: "Özel Sözlük", y: 172)
        container.addSubview(vocabLabel)

        customVocabField = createSingleLineInputField(
            frame: NSRect(x: 175, y: 170, width: 440, height: 24),
            placeholder: "Kubernetes, PostgreSQL, Next.js, SPM..."
        )
        customVocabField.delegate = self
        container.addSubview(customVocabField)

        let vocabNote = createNoteLabel(text: "Teknik terimleri virgülle ayırarak girin. Whisper ve Gemini modelleri bu kelimeleri öncelikli tanır.", y: 196)
        container.addSubview(vocabNote)

        // Ayırıcı
        container.addSubview(createSeparator(y: 224))

        // 4. Konuşma Dili
        let langLabel = createSectionLabel(text: "Konuşma Dili", y: 238)
        container.addSubview(langLabel)

        languageField = createSingleLineInputField(
            frame: NSRect(x: 175, y: 236, width: 60, height: 24),
            placeholder: "tr",
            isMonospaced: false
        )
        languageField.alignment = .center
        languageField.delegate = self
        container.addSubview(languageField)

        let langHint = NSTextField(labelWithString: "('tr': Türkçe, 'en': İngilizce, 'auto': Otomatik Algıla)")
        langHint.frame = NSRect(x: 245, y: 239, width: 370, height: 20)
        langHint.font = NSFont.systemFont(ofSize: 11)
        langHint.textColor = .secondaryLabelColor
        container.addSubview(langHint)

        // Ayırıcı
        container.addSubview(createSeparator(y: 266))

        // 5. Seçenekler (Tercihler)
        let optsLabel = createSectionLabel(text: "Seçenekler", y: 280)
        container.addSubview(optsLabel)

        hapticFeedbackCheckbox = NSButton(checkboxWithTitle: "Dokunsal titreşim (Trackpad Force Touch tıkı)", target: self, action: #selector(checkboxChanged(_:)))
        hapticFeedbackCheckbox.frame = NSRect(x: 175, y: 278, width: 440, height: 18)
        container.addSubview(hapticFeedbackCheckbox)

        removeFillerWordsCheckbox = NSButton(checkboxWithTitle: "Dolgu kelimelerini otomatik temizle ('ııı', 'şey', 'yani', 'hımm')", target: self, action: #selector(checkboxChanged(_:)))
        removeFillerWordsCheckbox.frame = NSRect(x: 175, y: 300, width: 440, height: 18)
        container.addSubview(removeFillerWordsCheckbox)

        saveHistoryCheckbox = NSButton(checkboxWithTitle: "Dikte geçmişini menü çubuğunda sakla (Son 15 dikte)", target: self, action: #selector(checkboxChanged(_:)))
        saveHistoryCheckbox.frame = NSRect(x: 175, y: 322, width: 440, height: 18)
        container.addSubview(saveHistoryCheckbox)

        playSoundsCheckbox = NSButton(checkboxWithTitle: "Sistem ses efektlerini çal", target: self, action: #selector(checkboxChanged(_:)))
        playSoundsCheckbox.frame = NSRect(x: 175, y: 344, width: 440, height: 18)
        container.addSubview(playSoundsCheckbox)

        micBoostCheckbox = NSButton(checkboxWithTitle: "Mikrofon Akıllı Kazanç (AGC Boost - Fısıltı Güçlendirme & Tanh Sınırlayıcı)", target: self, action: #selector(checkboxChanged(_:)))
        micBoostCheckbox.frame = NSRect(x: 175, y: 366, width: 440, height: 18)
        container.addSubview(micBoostCheckbox)

        launchAtLoginCheckbox = NSButton(checkboxWithTitle: "Mac açıldığında otomatik başlat", target: self, action: #selector(checkboxChanged(_:)))
        launchAtLoginCheckbox.frame = NSRect(x: 175, y: 388, width: 440, height: 18)
        container.addSubview(launchAtLoginCheckbox)

        showDockIconCheckbox = NSButton(checkboxWithTitle: "Dock simgesini kalıcı olarak göster", target: self, action: #selector(checkboxChanged(_:)))
        showDockIconCheckbox.frame = NSRect(x: 175, y: 410, width: 440, height: 18)
        container.addSubview(showDockIconCheckbox)

        onlyInTextFieldsCheckbox = NSButton(checkboxWithTitle: "Yalnızca yazı yazma alanındayken çalıştır (Target-Lock)", target: self, action: #selector(checkboxChanged(_:)))
        onlyInTextFieldsCheckbox.frame = NSRect(x: 175, y: 432, width: 440, height: 18)
        container.addSubview(onlyInTextFieldsCheckbox)

        // Dummy backwards compatibility
        muteSystemAudioCheckbox = NSButton(checkboxWithTitle: "", target: self, action: #selector(checkboxChanged(_:)))
        muteSystemAudioCheckbox.isHidden = true
        container.addSubview(muteSystemAudioCheckbox)

        // Ayırıcı
        container.addSubview(createSeparator(y: 456))

        // 6. Arka Plan Sesi Yönetimi
        let bgAudioLabel = createSectionLabel(text: "Arka Plan Sesi", y: 470)
        container.addSubview(bgAudioLabel)

        backgroundAudioPopUp = NSPopUpButton(frame: NSRect(x: 175, y: 468, width: 440, height: 26), pullsDown: false)
        backgroundAudioPopUp.addItem(withTitle: "🔉 Ses Kısma (Audio Ducking - %20'ye İndir) [Varsayılan]")
        backgroundAudioPopUp.addItem(withTitle: "⏸️ Medyayı Duraklat (Play/Pause Tuşu)")
        backgroundAudioPopUp.addItem(withTitle: "❌ Arka Plan Sesine Dokunma (Kapalı)")
        backgroundAudioPopUp.target = self
        backgroundAudioPopUp.action = #selector(backgroundAudioChanged(_:))
        container.addSubview(backgroundAudioPopUp)

        let bgAudioHint = createNoteLabel(text: "Dikte sırasında arka plandaki müzik veya video sesini otomatik kısar veya duraklatır.", y: 498)
        container.addSubview(bgAudioHint)

        return container
    }

    @objc private func modeSegmentedChanged(_ sender: NSSegmentedControl) {
        modePopUp.selectItem(at: sender.selectedSegment)
        updateModeInfoText(for: sender.selectedSegment)
        autoSave()
    }

    @objc private func backgroundAudioChanged(_ sender: NSPopUpButton) {
        autoSave()
    }

    private func updateModeInfoText(for index: Int) {
        switch index {
        case 1:
            modeInfoLabel.stringValue = "Akıllı Hibrit: Tuşa hızlı dokunursanız aç-kapa yapar; basılı tutarsanız bırakınca deşifre eder."
        case 2:
            modeInfoLabel.stringValue = "Aç / Kapa: Tuşa bastığınızda dinleme başlar, tekrar bastığınızda durup metni yapıştırır."
        default:
            modeInfoLabel.stringValue = "Basılı Tut: Tuşa basılı tutun ve konuşun, bıraktığınız anda metin otomatik yapıştırılır."
        }
    }

    // =========================================================================
    // TAB 2: Yapay Zeka & Modeller (Two-Column Layout)
    // =========================================================================
    private func buildTab2AIProvidersView() -> NSView {
        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 650, height: 535))
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false

        let container = FlippedContentView(frame: NSRect(x: 0, y: 0, width: 635, height: 840))
        scrollView.documentView = container

        // 1. Aktif Sağlayıcı (Active Provider)
        let provLabel = createSectionLabel(text: "Aktif Sağlayıcı", y: 16)
        container.addSubview(provLabel)

        providerSegmentedControl = NSSegmentedControl(
            labels: ["🍎 Apple", "✨ Gemini", "⚡ Groq", "🎙 AssemblyAI"],
            trackingMode: .selectOne,
            target: self,
            action: #selector(providerSegmentedChanged(_:))
        )
        providerSegmentedControl.frame = NSRect(x: 175, y: 14, width: 440, height: 26)
        providerSegmentedControl.segmentStyle = .rounded
        providerSegmentedControl.segmentDistribution = .fillEqually
        providerSegmentedControl.selectedSegment = 0
        container.addSubview(providerSegmentedControl)

        // Gizli yedek popup
        providerPopUp = NSPopUpButton(frame: NSRect(x: 175, y: 14, width: 440, height: 26), pullsDown: false)
        providerPopUp.addItem(withTitle: "Apple Speech (Canlı Akış / 0 Kota)")
        providerPopUp.addItem(withTitle: "Google Gemini Live (Canlı Akış)")
        providerPopUp.addItem(withTitle: "Groq Whisper (whisper-large-v3)")
        providerPopUp.addItem(withTitle: "AssemblyAI Dictation API (Universal-3.5 Pro)")
        providerPopUp.isHidden = true
        container.addSubview(providerPopUp)

        providerNoteLabel = createNoteLabel(text: "🍎 Apple Speech: Uygun sistemlerde yerel konuşma tanıma ile çalışır. API anahtarı gerekmez; Apple Speech izni gerekir.", y: 46)
        container.addSubview(providerNoteLabel)

        container.addSubview(createSeparator(y: 78))

        // 2. 🍎 Apple Speech (Yerel / On-Device Speech)
        let appleSection = createSectionLabel(text: "Apple Speech", y: 92)
        container.addSubview(appleSection)

        appleStatusLabel = NSTextField(labelWithString: "🟢 Apple Speech kullanılabilir")
        appleStatusLabel.frame = NSRect(x: 175, y: 90, width: 440, height: 22)
        appleStatusLabel.font = NSFont.systemFont(ofSize: 12.5, weight: .medium)
        appleStatusLabel.textColor = .systemGreen
        container.addSubview(appleStatusLabel)

        let appleNote = createNoteLabel(text: "Konuşma tanıma izni ve macOS'un desteklediği dil modeli gerekir; sonuç kalitesi sisteme ve dile bağlıdır.", y: 116)
        container.addSubview(appleNote)

        container.addSubview(createSeparator(y: 148))

        // 3. Google Gemini Live
        let geminiSection = createSectionLabel(text: "Google Gemini", y: 162)
        container.addSubview(geminiSection)

        geminiKeyField = createSingleLineInputField(
            frame: NSRect(x: 175, y: 160, width: 440, height: 24),
            placeholder: "AIzaSy...",
            isSecure: true
        )
        geminiKeyField.delegate = self
        container.addSubview(geminiKeyField)

        geminiModelPopUp = NSPopUpButton(frame: NSRect(x: 175, y: 192, width: 440, height: 26), pullsDown: false)
        for m in geminiModelOptions {
            geminiModelPopUp.addItem(withTitle: m.name)
        }
        geminiModelPopUp.target = self
        geminiModelPopUp.action = #selector(geminiModelChanged(_:))
        container.addSubview(geminiModelPopUp)

        let testGeminiBtn = NSButton(frame: NSRect(x: 175, y: 226, width: 145, height: 28))
        testGeminiBtn.title = "Bağlantıyı Test Et"
        testGeminiBtn.bezelStyle = .rounded
        testGeminiBtn.target = self
        testGeminiBtn.action = #selector(testGeminiConnectionClicked)
        container.addSubview(testGeminiBtn)

        let getGeminiKeyBtn = NSButton(frame: NSRect(x: 326, y: 226, width: 140, height: 28))
        getGeminiKeyBtn.title = "API Anahtarı Al ↗"
        getGeminiKeyBtn.bezelStyle = .rounded
        getGeminiKeyBtn.target = self
        getGeminiKeyBtn.action = #selector(openGeminiConsoleClicked)
        container.addSubview(getGeminiKeyBtn)

        let refreshGeminiBtn = NSButton(frame: NSRect(x: 475, y: 226, width: 140, height: 28))
        refreshGeminiBtn.title = "Modelleri Webden Yenile"
        refreshGeminiBtn.bezelStyle = .rounded
        refreshGeminiBtn.target = self
        refreshGeminiBtn.action = #selector(refreshGeminiModelsClicked)
        container.addSubview(refreshGeminiBtn)

        geminiStatusLabel = NSTextField(wrappingLabelWithString: "")
        geminiStatusLabel.frame = NSRect(x: 175, y: 258, width: 440, height: 32)
        geminiStatusLabel.font = NSFont.systemFont(ofSize: 11)
        geminiStatusLabel.textColor = .secondaryLabelColor
        geminiStatusLabel.maximumNumberOfLines = 2
        container.addSubview(geminiStatusLabel)

        let geminiNote = createNoteLabel(text: "WebSocket canlı akışı sayesinde konuşurken kelimeler doğrudan canlı işlenir.", y: 294)
        container.addSubview(geminiNote)

        container.addSubview(createSeparator(y: 324))

        // 4. Groq Whisper
        let groqSection = createSectionLabel(text: "Groq Whisper", y: 338)
        container.addSubview(groqSection)

        groqKeyField = createSingleLineInputField(
            frame: NSRect(x: 175, y: 336, width: 440, height: 24),
            placeholder: "gsk_...",
            isSecure: true
        )
        groqKeyField.delegate = self
        container.addSubview(groqKeyField)

        groqModelPopUp = NSPopUpButton(frame: NSRect(x: 175, y: 368, width: 440, height: 26), pullsDown: false)
        for m in ConfigManager.availableGroqModels {
            groqModelPopUp.addItem(withTitle: m.name)
        }
        groqModelPopUp.target = self
        groqModelPopUp.action = #selector(groqModelChanged(_:))
        container.addSubview(groqModelPopUp)

        let testGroqBtn = NSButton(frame: NSRect(x: 175, y: 402, width: 145, height: 28))
        testGroqBtn.title = "Bağlantıyı Test Et"
        testGroqBtn.bezelStyle = .rounded
        testGroqBtn.target = self
        testGroqBtn.action = #selector(testGroqConnectionClicked)
        container.addSubview(testGroqBtn)

        let getGroqKeyBtn = NSButton(frame: NSRect(x: 326, y: 402, width: 140, height: 28))
        getGroqKeyBtn.title = "API Anahtarı Al ↗"
        getGroqKeyBtn.bezelStyle = .rounded
        getGroqKeyBtn.target = self
        getGroqKeyBtn.action = #selector(openGroqConsoleClicked)
        container.addSubview(getGroqKeyBtn)

        groqStatusLabel = NSTextField(wrappingLabelWithString: "")
        groqStatusLabel.frame = NSRect(x: 175, y: 434, width: 440, height: 32)
        groqStatusLabel.font = NSFont.systemFont(ofSize: 11)
        groqStatusLabel.textColor = .secondaryLabelColor
        groqStatusLabel.maximumNumberOfLines = 2
        container.addSubview(groqStatusLabel)

        let groqNote = createNoteLabel(text: "Whisper Large modelini Groq LPU bulut donanımında ~0.3 saniyede tamamlar.", y: 470)
        container.addSubview(groqNote)

        container.addSubview(createSeparator(y: 500))

        // 5. AssemblyAI Dictation
        let assemblySection = createSectionLabel(text: "AssemblyAI", y: 514)
        container.addSubview(assemblySection)

        assemblyAIKeyField = createSingleLineInputField(
            frame: NSRect(x: 175, y: 512, width: 440, height: 24),
            placeholder: "AssemblyAI API anahtarı",
            isSecure: true
        )
        assemblyAIKeyField.delegate = self
        container.addSubview(assemblyAIKeyField)

        let assemblyModelLabel = NSTextField(labelWithString: "Dictation API · Universal-3.5 Pro tabanlı · Gönderime hazır metin")
        assemblyModelLabel.frame = NSRect(x: 175, y: 544, width: 440, height: 20)
        assemblyModelLabel.font = NSFont.systemFont(ofSize: 11.5, weight: .medium)
        assemblyModelLabel.textColor = .secondaryLabelColor
        container.addSubview(assemblyModelLabel)

        let testAssemblyBtn = NSButton(frame: NSRect(x: 175, y: 572, width: 145, height: 28))
        testAssemblyBtn.title = "Bağlantıyı Test Et"
        testAssemblyBtn.bezelStyle = .rounded
        testAssemblyBtn.target = self
        testAssemblyBtn.action = #selector(testAssemblyAIConnectionClicked)
        container.addSubview(testAssemblyBtn)

        let getAssemblyKeyBtn = NSButton(frame: NSRect(x: 326, y: 572, width: 140, height: 28))
        getAssemblyKeyBtn.title = "API Anahtarı Al ↗"
        getAssemblyKeyBtn.bezelStyle = .rounded
        getAssemblyKeyBtn.target = self
        getAssemblyKeyBtn.action = #selector(openAssemblyAIConsoleClicked)
        container.addSubview(getAssemblyKeyBtn)

        assemblyAIStatusLabel = NSTextField(wrappingLabelWithString: "")
        assemblyAIStatusLabel.frame = NSRect(x: 175, y: 604, width: 440, height: 32)
        assemblyAIStatusLabel.font = NSFont.systemFont(ofSize: 11)
        assemblyAIStatusLabel.textColor = .secondaryLabelColor
        assemblyAIStatusLabel.maximumNumberOfLines = 2
        container.addSubview(assemblyAIStatusLabel)

        let assemblyNote = createNoteLabel(text: "Kayıt bitince ham metin ve gönderime hazır temizlenmiş metin birlikte alınır; ses AssemblyAI bulutuna gönderilir.", y: 640)
        container.addSubview(assemblyNote)

        container.addSubview(createSeparator(y: 676))

        // 6. Gemini Sistem İstemi (System Instruction / Cevap & Yazım Tarzı)
        promptSectionLabel = createSectionLabel(text: "Sistem İstemi", y: 690)
        container.addSubview(promptSectionLabel)

        geminiPromptPresetPopUp = NSPopUpButton(frame: NSRect(x: 175, y: 688, width: 440, height: 26), pullsDown: false)
        for preset in promptPresets {
            geminiPromptPresetPopUp.addItem(withTitle: preset.name)
        }
        geminiPromptPresetPopUp.target = self
        geminiPromptPresetPopUp.action = #selector(promptPresetChanged(_:))
        container.addSubview(geminiPromptPresetPopUp)

        geminiPromptScrollView = NSScrollView(frame: NSRect(x: 175, y: 718, width: 440, height: 54))
        geminiPromptScrollView.hasVerticalScroller = true
        geminiPromptScrollView.hasHorizontalScroller = false
        geminiPromptScrollView.autohidesScrollers = true
        geminiPromptScrollView.borderType = .bezelBorder

        let contentSize = geminiPromptScrollView.contentSize
        geminiPromptTextView = NSTextView(frame: NSRect(x: 0, y: 0, width: contentSize.width, height: contentSize.height))
        geminiPromptTextView.minSize = NSSize(width: 0.0, height: contentSize.height)
        geminiPromptTextView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        geminiPromptTextView.isVerticallyResizable = true
        geminiPromptTextView.isHorizontallyResizable = false
        geminiPromptTextView.autoresizingMask = [.width]
        geminiPromptTextView.textContainer?.containerSize = NSSize(width: contentSize.width, height: CGFloat.greatestFiniteMagnitude)
        geminiPromptTextView.textContainer?.widthTracksTextView = true
        geminiPromptTextView.font = NSFont.systemFont(ofSize: 11)
        geminiPromptTextView.isRichText = false
        geminiPromptTextView.delegate = self
        geminiPromptScrollView.documentView = geminiPromptTextView
        container.addSubview(geminiPromptScrollView)

        promptNoteLabel = createNoteLabel(text: "Gemini bu sistem talimatına (systemInstruction) göre çıktıyı biçimlendirir ve üslubu belirler.", y: 778)
        container.addSubview(promptNoteLabel)

        promptUnsupportedLabel = NSTextField(wrappingLabelWithString: "ℹ️ Seçili Gemini modeli saf ses deşifre (ASR) içindir; konuşulanları doğrudan metne döker. Sistem istemi ve sohbet özellikleri bu model seçicisinde kullanılmaz.")
        promptUnsupportedLabel.frame = NSRect(x: 175, y: 690, width: 440, height: 42)
        promptUnsupportedLabel.font = NSFont.systemFont(ofSize: 11)
        promptUnsupportedLabel.textColor = .secondaryLabelColor
        promptUnsupportedLabel.isHidden = true
        container.addSubview(promptUnsupportedLabel)

        return scrollView
    }

    private func updateProviderNote(for provider: String) {
        switch provider {
        case "apple":
            providerNoteLabel.stringValue = "🍎 Apple Speech: Uygun sistemlerde yerel konuşma tanıma ile çalışır. API anahtarı gerekmez; Apple Speech izni gerekir."
        case "gemini":
            providerNoteLabel.stringValue = "✨ Google Gemini: API anahtarı ve internet bağlantısı gerekir; seçili modele göre canlı veya normal deşifre kullanılır."
        case "groq":
            providerNoteLabel.stringValue = "⚡ Groq Whisper: API anahtarı ve internet bağlantısı gerekir; ses kaydı bulutta işlenir."
        case "assemblyai":
            providerNoteLabel.stringValue = "🎙 AssemblyAI Dictation API: Sesi gönderime hazır metne dönüştürür; dolgu ve öz-düzeltmeleri varsayılan olarak temizler."
        default:
            providerNoteLabel.stringValue = "Sağlayıcı ayarını kontrol edin."
        }
    }

    private func updateProviderStatusLabels() {
        let speech = PermissionManager.shared.getSpeechRecognitionStatus()
        if speech.status == .authorized {
            appleStatusLabel.stringValue = "🟢 Apple Speech hazır"
            appleStatusLabel.textColor = .systemGreen
        } else {
            appleStatusLabel.stringValue = "🟡 Apple Speech izni gerekli"
            appleStatusLabel.textColor = .systemOrange
        }

        let geminiKey = geminiKeyField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if geminiKey.isEmpty {
            geminiStatusLabel.stringValue = "🟡 API anahtarı girilmedi"
            geminiStatusLabel.textColor = .systemOrange
        } else {
            geminiStatusLabel.stringValue = "🟢 API anahtarı girildi · Kullanımdan önce bağlantıyı test edin"
            geminiStatusLabel.textColor = .systemGreen
        }

        let assemblyKey = assemblyAIKeyField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if assemblyKey.isEmpty {
            assemblyAIStatusLabel.stringValue = "🟡 API anahtarı girilmedi"
            assemblyAIStatusLabel.textColor = .systemOrange
        } else {
            assemblyAIStatusLabel.stringValue = "🟢 API anahtarı girildi · Kullanımdan önce bağlantıyı test edin"
            assemblyAIStatusLabel.textColor = .systemGreen
        }

        let groqKey = groqKeyField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if groqKey.isEmpty {
            groqStatusLabel.stringValue = "🟡 API anahtarı girilmedi"
            groqStatusLabel.textColor = .systemOrange
        } else {
            groqStatusLabel.stringValue = "🟢 API anahtarı girildi · Kullanımdan önce bağlantıyı test edin"
            groqStatusLabel.textColor = .systemGreen
        }
    }

    private func updateSystemPromptVisibility() {
        let supportsPrompt = TranscriptionProviderRegistry.supports(.initialPrompt, providerID: selectedProviderID)
        let geminiIdx = max(0, geminiModelPopUp.indexOfSelectedItem)
        let modelId = (geminiIdx < geminiModelOptions.count)
            ? geminiModelOptions[geminiIdx].id
            : AppConfig.defaultConfig.gemini_model

        // Sağlayıcı istem desteklemeli VE seçili model bunu kabul etmeli
        // (ör. saf ses "transcribe" modelleri system_instruction almaz).
        let isSupported = supportsPrompt && ConfigManager.supportsSystemPrompt(model: modelId)

        geminiPromptPresetPopUp.isHidden = !isSupported
        geminiPromptScrollView.isHidden = !isSupported
        promptNoteLabel.isHidden = !isSupported
        promptUnsupportedLabel.isHidden = isSupported

        if isSupported {
            promptSectionLabel.textColor = .labelColor
        } else {
            promptSectionLabel.textColor = .secondaryLabelColor
        }
    }

    private var selectedGeminiModelID: String {
        let index = geminiModelPopUp?.indexOfSelectedItem ?? -1
        guard index >= 0, index < geminiModelOptions.count else {
            return AppConfig.defaultConfig.gemini_model
        }
        return geminiModelOptions[index].id
    }

    @objc private func geminiModelChanged(_ sender: NSPopUpButton) {
        updateSystemPromptVisibility()
        autoSave()
    }

    @objc private func refreshGeminiModelsClicked() {
        let key = geminiKeyField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else {
            geminiStatusLabel.stringValue = "⚠️ Önce Gemini API anahtarını girin."
            geminiStatusLabel.textColor = .systemOrange
            SoundManager.shared.playCancel()
            return
        }

        let selectedID = selectedGeminiModelID
        geminiStatusLabel.stringValue = "⏳ Transkripsiyon modelleri webden kontrol ediliyor..."
        geminiStatusLabel.textColor = .systemBlue

        GeminiModelCatalog.fetch(apiKey: key) { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                switch result {
                case .success(var models):
                    if !models.contains(where: { $0.id == selectedID }),
                       let known = ConfigManager.availableGeminiModels.first(where: { $0.id == selectedID }) {
                        models.append(known)
                    }
                    guard !models.isEmpty else {
                        self.geminiStatusLabel.stringValue = "⚠️ Erişilebilir transkripsiyon modeli bulunamadı."
                        self.geminiStatusLabel.textColor = .systemOrange
                        return
                    }
                    self.geminiModelOptions = models
                    self.geminiModelPopUp.removeAllItems()
                    for model in models {
                        self.geminiModelPopUp.addItem(withTitle: model.name)
                    }
                    if let index = models.firstIndex(where: { $0.id == selectedID }) {
                        self.geminiModelPopUp.selectItem(at: index)
                    } else {
                        self.geminiModelPopUp.selectItem(at: 0)
                    }
                    self.updateSystemPromptVisibility()
                    let liveCount = models.filter { ConfigManager.isGeminiLiveModel($0.id) }.count
                    self.geminiStatusLabel.stringValue = "🟢 Web listesi güncel · \(models.count) transkripsiyon modeli (\(liveCount) canlı)"
                    self.geminiStatusLabel.textColor = .systemGreen
                    SoundManager.shared.playSuccess()
                case .failure(let error):
                    let detail: String
                    if let catalogError = error as? GeminiModelCatalogError {
                        switch catalogError {
                        case .httpStatus(let code): detail = "HTTP \(code)"
                        default: detail = "Bağlantı kurulamadı"
                        }
                    } else {
                        detail = "Bağlantı kurulamadı"
                    }
                    self.geminiStatusLabel.stringValue = "⚠️ Web modeli alınamadı (\(detail)); yerleşik liste kullanılacak."
                    self.geminiStatusLabel.textColor = .systemOrange
                    SoundManager.shared.playCancel()
                }
            }
        }
    }

    @objc private func groqModelChanged(_ sender: NSPopUpButton) {
        updateSystemPromptVisibility()
        autoSave()
    }

    @objc private func promptPresetChanged(_ sender: NSPopUpButton) {
        let idx = sender.indexOfSelectedItem
        if idx >= 0 && idx < promptPresets.count - 1 {
            geminiPromptTextView.string = promptPresets[idx].prompt
        }
        autoSave()
    }

    /// Kayıt defterindeki sıraya göre segment indeksini döndürür.
    /// Segment denetimi bu sırayla oluşturulur; bilinmeyen kimlik varsayılana düşer.
    private func providerSegmentIndex(for providerID: String) -> Int {
        let normalized = TranscriptionProviderRegistry.normalize(providerID)
        return TranscriptionProviderRegistry.all.firstIndex { $0.id == normalized } ?? 0
    }

    @objc private func providerSegmentedChanged(_ sender: NSSegmentedControl) {
        let providers = TranscriptionProviderRegistry.all
        let index = sender.selectedSegment
        guard index >= 0, index < providers.count else { return }

        let provider = providers[index].id
        providerPopUp.selectItem(at: index)
        updateProviderNote(for: provider)
        updateProviderStatusLabels()
        updateSystemPromptVisibility()
        autoSave()
        // autoSave provider bilgisini ConfigManager'a yazdıktan sonra izin
        // sekmesinin "gerekli / gerekli değil" durumunu yeni sağlayıcıya göre yenile.
        refreshPermissionStatuses()
    }

    // =========================================================================
    // TAB: Gelişmiş & Kısayollar (Auto-Submit, App Profiles, Voice Snippets, Sound Themes)
    // =========================================================================
    private func buildTabAdvancedView() -> NSView {
        let container = FlippedContentView(frame: NSRect(x: 0, y: 0, width: 650, height: 570))

        // 1. Otomatik Gönderim (Auto-Submit / Enter)
        let autoSubmitLabel = createSectionLabel(text: "Otomatik Gönderim", y: 16)
        container.addSubview(autoSubmitLabel)

        autoSubmitCheckbox = NSButton(
            checkboxWithTitle: "Dikte bitince otomatik gönder (Auto-Submit / Enter)",
            target: self,
            action: #selector(checkboxChanged(_:))
        )
        autoSubmitCheckbox.frame = NSRect(x: 175, y: 14, width: 440, height: 18)
        container.addSubview(autoSubmitCheckbox)

        let keyLabel = NSTextField(labelWithString: "Gönderim Tuşu:")
        keyLabel.frame = NSRect(x: 175, y: 38, width: 95, height: 20)
        keyLabel.font = NSFont.systemFont(ofSize: 11)
        container.addSubview(keyLabel)

        autoSubmitKeyPopUp = NSPopUpButton(frame: NSRect(x: 270, y: 34, width: 220, height: 26), pullsDown: false)
        autoSubmitKeyPopUp.addItem(withTitle: "Return / Enter (⏎)")
        autoSubmitKeyPopUp.addItem(withTitle: "Command + Return (⌘⏎)")
        autoSubmitKeyPopUp.addItem(withTitle: "Shift + Return (⇧⏎)")
        autoSubmitKeyPopUp.addItem(withTitle: "Tab (⇥)")
        autoSubmitKeyPopUp.target = self
        autoSubmitKeyPopUp.action = #selector(autoSubmitKeyChanged(_:))
        container.addSubview(autoSubmitKeyPopUp)

        let autoSubmitNote = createNoteLabel(
            text: "ChatGPT, Claude, Cursor, Slack veya Terminal'de dikte yapıştırıldığı an mesajı/komutu el değmeden doğrudan gönderir.",
            y: 62
        )
        container.addSubview(autoSubmitNote)

        // Ayırıcı
        container.addSubview(createSeparator(y: 88))

        // 2. Uygulama Profilleri (App Profiles)
        let profileLabel = createSectionLabel(text: "Uygulama Profili", y: 100)
        container.addSubview(profileLabel)

        appProfilesCheckbox = NSButton(
            checkboxWithTitle: "Hedef uygulamaya göre akıllı biçimlendir (App Profiles)",
            target: self,
            action: #selector(checkboxChanged(_:))
        )
        appProfilesCheckbox.frame = NSRect(x: 175, y: 98, width: 440, height: 18)
        container.addSubview(appProfilesCheckbox)

        let profileNote = createNoteLabel(
            text: "Terminal ve IDE'lerde küçük harf ve noktasız komut satırı stili; WhatsApp/Slack'te doğal sohbet; Mail/Docs'ta tam resmi imla kuralları uygular.",
            y: 122
        )
        container.addSubview(profileNote)

        // Ayırıcı
        container.addSubview(createSeparator(y: 148))

        // 3. Ses Temaları & Ses Seviyesi (Sound Themes)
        let soundThemeLabel = createSectionLabel(text: "Ses Teması & Efekt", y: 160)
        container.addSubview(soundThemeLabel)

        soundThemePopUp = NSPopUpButton(frame: NSRect(x: 175, y: 156, width: 220, height: 26), pullsDown: false)
        soundThemePopUp.addItem(withTitle: "Modern (Dijital Chirp)")
        soundThemePopUp.addItem(withTitle: "Zarif / Subtle (Yumuşak Akustik)")
        soundThemePopUp.addItem(withTitle: "Taktil (Mekanik Klik Sesi)")
        soundThemePopUp.addItem(withTitle: "Melodik / Chimes (Majör Çanlar)")
        soundThemePopUp.target = self
        soundThemePopUp.action = #selector(soundThemeChanged(_:))
        container.addSubview(soundThemePopUp)

        testSoundButton = NSButton(frame: NSRect(x: 405, y: 155, width: 100, height: 28))
        testSoundButton.title = "Sesi Dene"
        testSoundButton.bezelStyle = .rounded
        testSoundButton.target = self
        testSoundButton.action = #selector(testSoundButtonClicked)
        container.addSubview(testSoundButton)

        let volLabel = NSTextField(labelWithString: "Ses Düzeyi:")
        volLabel.frame = NSRect(x: 175, y: 190, width: 80, height: 20)
        volLabel.font = NSFont.systemFont(ofSize: 11)
        container.addSubview(volLabel)

        soundVolumeSlider = NSSlider(value: 0.8, minValue: 0.0, maxValue: 1.0, target: self, action: #selector(soundVolumeSliderChanged(_:)))
        soundVolumeSlider.frame = NSRect(x: 255, y: 188, width: 200, height: 22)
        container.addSubview(soundVolumeSlider)

        soundVolumeLabel = NSTextField(labelWithString: "Ses: %80")
        soundVolumeLabel.frame = NSRect(x: 465, y: 190, width: 80, height: 20)
        soundVolumeLabel.font = NSFont.systemFont(ofSize: 11)
        soundVolumeLabel.textColor = .secondaryLabelColor
        container.addSubview(soundVolumeLabel)

        // Ayırıcı
        container.addSubview(createSeparator(y: 218))

        // 4. Sesli Kısayollar ve Metin Genişletici (Voice Snippets)
        let snippetsLabel = createSectionLabel(text: "Sesli Kısayollar", y: 230)
        container.addSubview(snippetsLabel)

        let snippetsDesc = NSTextField(labelWithString: "Her satıra 'Tetikleyici = Genişletilmiş Metin' formatında yazın:")
        snippetsDesc.frame = NSRect(x: 175, y: 228, width: 330, height: 18)
        snippetsDesc.font = NSFont.systemFont(ofSize: 11)
        snippetsDesc.textColor = .secondaryLabelColor
        container.addSubview(snippetsDesc)

        let insertSampleBtn = NSButton(frame: NSRect(x: 510, y: 224, width: 105, height: 24))
        insertSampleBtn.title = "+ Örnek Ekle"
        insertSampleBtn.bezelStyle = .rounded
        insertSampleBtn.font = NSFont.systemFont(ofSize: 11)
        insertSampleBtn.target = self
        insertSampleBtn.action = #selector(insertSampleSnippetsClicked)
        container.addSubview(insertSampleBtn)

        voiceSnippetsScrollView = NSScrollView(frame: NSRect(x: 175, y: 252, width: 440, height: 95))
        voiceSnippetsScrollView.hasVerticalScroller = true
        voiceSnippetsScrollView.borderType = .bezelBorder
        voiceSnippetsScrollView.autohidesScrollers = true

        voiceSnippetsTextView = NSTextView(frame: NSRect(x: 0, y: 0, width: 420, height: 95))
        voiceSnippetsTextView.minSize = NSSize(width: 0.0, height: 95)
        voiceSnippetsTextView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        voiceSnippetsTextView.isVerticallyResizable = true
        voiceSnippetsTextView.isHorizontallyResizable = false
        voiceSnippetsTextView.autoresizingMask = [.width]
        voiceSnippetsTextView.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        voiceSnippetsTextView.delegate = self
        voiceSnippetsScrollView.documentView = voiceSnippetsTextView
        container.addSubview(voiceSnippetsScrollView)

        let snippetsExample = NSTextField(wrappingLabelWithString: "💡 Örnek: 'kısayol mail' dediğinizde 'ornek@sirket.com' yapıştırılır. Cümle içinde ('dosyayı kısayol mail adresime yolla') veya tek başına kullanılabilir.")
        snippetsExample.frame = NSRect(x: 175, y: 352, width: 440, height: 40)
        snippetsExample.font = NSFont.systemFont(ofSize: 11)
        snippetsExample.textColor = .secondaryLabelColor
        container.addSubview(snippetsExample)

        container.addSubview(createSeparator(y: 408))

        // 5. Pano davranışı
        let clipboardLabel = createSectionLabel(text: "Pano", y: 422)
        container.addSubview(clipboardLabel)

        restoreClipboardCheckbox = NSButton(
            checkboxWithTitle: "Dikte sonrası önceki panoyu geri yükle",
            target: self,
            action: #selector(checkboxChanged(_:))
        )
        restoreClipboardCheckbox.frame = NSRect(x: 175, y: 420, width: 440, height: 18)
        container.addSubview(restoreClipboardCheckbox)

        let clipboardNote = createNoteLabel(
            text: "Açıksa Voice Typing metni yapıştırdıktan kısa süre sonra eski pano içeriğini geri getirir. Pano yöneticisi kullanıyorsanız önerilir.",
            y: 444
        )
        container.addSubview(clipboardNote)

        container.addSubview(createSeparator(y: 470))

        // 6. Gösterge Stili (HUD)
        let hudLabel = createSectionLabel(text: "Gösterge Stili", y: 484)
        container.addSubview(hudLabel)

        hudStylePopUp = NSPopUpButton(frame: NSRect(x: 175, y: 480, width: 300, height: 26), pullsDown: false)
        hudStylePopUp.addItem(withTitle: "Alt-ortada kapsül (varsayılan)")
        hudStylePopUp.addItem(withTitle: "MacBook çentiği · Dynamic Island")
        hudStylePopUp.target = self
        hudStylePopUp.action = #selector(hudStyleChanged(_:))
        container.addSubview(hudStylePopUp)

        hudNotchNoteLabel = createNoteLabel(
            text: "Dynamic Island yalnızca çentikli MacBook ekranlarında görünür. Çentik yoksa kapsül alt-ortada kalır.",
            y: 506
        )
        container.addSubview(hudNotchNoteLabel)

        // Yazı boyutu ayarı KALDIRILDI: çentik modunda boyut otomatik
        // hesaplanır (sabit genişliğe sığdırma + okunabilirlik tabanı).
        // Etkisi olmayan bir kontrol göstermek yanıltıcı olurdu.
        let hudAutoNote = createNoteLabel(
            text: "Yazı boyutu otomatiktir: ada genişliği sabittir, uzun metin alt satırlara sarar ve yazı gerektiği kadar küçülür (okunabilirlik sınırına kadar).",
            y: 528
        )
        container.addSubview(hudAutoNote)

        return container
    }

    @objc private func hudStyleChanged(_ sender: NSPopUpButton) {
        let style = sender.indexOfSelectedItem == 1 ? "notch" : "pill"
        ConfigManager.shared.update { $0.hud_style = style }
        updateHudControls()
    }

    /// Ada seçeneğini mevcut donanıma göre etkinleştirir/pasifleştirir.
    private func updateHudControls() {
        let hasNotch = RecordingHUD.notchedScreen() != nil
        let notchItem = hudStylePopUp.item(at: 1)
        notchItem?.isEnabled = hasNotch
        if !hasNotch {
            hudNotchNoteLabel.stringValue = "Bu ekranda çentik bulunamadı; Dynamic Island kullanılamaz."
        }
    }

    @objc private func insertSampleSnippetsClicked() {
        let sample = "kısayol iban = TR33 0006 1005 1234 5678 90\nkısayol adres = Atatürk Bulvarı No: 42 Ankara"
        let current = voiceSnippetsTextView.string.trimmingCharacters(in: .whitespacesAndNewlines)
        if current.isEmpty {
            voiceSnippetsTextView.string = "kısayol mail = ornek@sirket.com\n" + sample
        } else if !current.contains("kısayol iban") {
            voiceSnippetsTextView.string = current + "\n" + sample
        }
        autoSave()
    }

    @objc private func autoSubmitKeyChanged(_ sender: NSPopUpButton) {
        autoSave()
    }

    @objc private func soundThemeChanged(_ sender: NSPopUpButton) {
        autoSave()
    }

    @objc private func soundVolumeSliderChanged(_ sender: NSSlider) {
        soundVolumeLabel.stringValue = "Ses: \(Int(sender.doubleValue * 100))%"
        autoSave()
    }

    @objc private func testSoundButtonClicked() {
        let themeIdx = soundThemePopUp.indexOfSelectedItem
        let theme: String
        switch themeIdx {
        case 1: theme = "subtle"
        case 2: theme = "tactile"
        case 3: theme = "chimes"
        default: theme = "modern"
        }
        let vol = soundVolumeSlider.doubleValue
        SoundManager.shared.testSound(theme: theme, volume: vol)
    }

    // =========================================================================
    // TAB 3: Sistem & İzinler (Native macOS Two-Column Layout & Hardware Test)
    // =========================================================================
    private func buildTab3PermissionsView() -> NSView {
        let container = FlippedContentView(frame: NSRect(x: 0, y: 0, width: 650, height: 535))

        // 1. MİKROFON İZNİ
        let micSectionLabel = createSectionLabel(text: "Mikrofon İzni", y: 20)
        container.addSubview(micSectionLabel)

        micStatusLabel = NSTextField(labelWithString: "🟢 Yetki Verildi (Aktif)")
        micStatusLabel.frame = NSRect(x: 175, y: 20, width: 275, height: 22)
        micStatusLabel.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        micStatusLabel.textColor = .systemGreen
        container.addSubview(micStatusLabel)

        micActionButton = NSButton(frame: NSRect(x: 465, y: 17, width: 150, height: 28))
        micActionButton.title = "Sistem Ayarları"
        micActionButton.bezelStyle = .rounded
        micActionButton.target = self
        micActionButton.action = #selector(openMicSettingsClicked)
        container.addSubview(micActionButton)

        let micNote = createNoteLabel(text: "Ses kaydı ve yapay zeka ile deşifre için gereklidir.", y: 44)
        container.addSubview(micNote)

        // Ayırıcı
        container.addSubview(createSeparator(y: 72))

        // 2. KONUŞMA TANIMA İZNİ (Apple Speech)
        let speechSectionLabel = createSectionLabel(text: "Konuşma Tanıma", y: 86)
        container.addSubview(speechSectionLabel)

        speechStatusLabel = NSTextField(labelWithString: "🟢 Yetki Verildi (Aktif)")
        speechStatusLabel.frame = NSRect(x: 175, y: 86, width: 275, height: 22)
        speechStatusLabel.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        speechStatusLabel.textColor = .systemGreen
        container.addSubview(speechStatusLabel)

        speechActionButton = NSButton(frame: NSRect(x: 465, y: 83, width: 150, height: 28))
        speechActionButton.title = "Sistem Ayarları"
        speechActionButton.bezelStyle = .rounded
        speechActionButton.target = self
        speechActionButton.action = #selector(openSpeechSettingsClicked)
        container.addSubview(speechActionButton)

        let speechNote = createNoteLabel(text: "Apple Speech ve yerel ses tanıma motorunun sesinizi çözümlemesi için gereklidir.", y: 110)
        container.addSubview(speechNote)

        // Ayırıcı
        container.addSubview(createSeparator(y: 138))

        // 3. ERİŞİLEBİLİRLİK İZNİ
        let accSectionLabel = createSectionLabel(text: "Erişilebilirlik", y: 152)
        container.addSubview(accSectionLabel)

        accStatusLabel = NSTextField(labelWithString: "🟢 Yetki Verildi (Aktif)")
        accStatusLabel.frame = NSRect(x: 175, y: 152, width: 275, height: 22)
        accStatusLabel.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        accStatusLabel.textColor = .systemGreen
        container.addSubview(accStatusLabel)

        accActionButton = NSButton(frame: NSRect(x: 465, y: 149, width: 150, height: 28))
        accActionButton.title = "Sistem Ayarları"
        accActionButton.bezelStyle = .rounded
        accActionButton.target = self
        accActionButton.action = #selector(openAccSettingsClicked)
        container.addSubview(accActionButton)

        let accNote = createNoteLabel(text: "Global kısayolu, aktif yazı alanını ve Cmd+V ile metin gönderimini kullanmak içindir; Mikrofon izninden ayrıdır.", y: 176)
        container.addSubview(accNote)

        // Canlı Algılama Göstergesi (Yalnızca izin beklenirken görünür)
        accProgressIndicator = NSProgressIndicator(frame: NSRect(x: 175, y: 204, width: 14, height: 14))
        accProgressIndicator.style = .spinning
        accProgressIndicator.controlSize = .small
        accProgressIndicator.isDisplayedWhenStopped = false
        container.addSubview(accProgressIndicator)

        accGuideLabel = NSTextField(labelWithString: "İzin kapsamı: global kısayolu algılama, odaklı alanı bulma ve deşifreyi hedef uygulamaya gönderme.")
        accGuideLabel.frame = NSRect(x: 195, y: 203, width: 420, height: 18)
        accGuideLabel.font = NSFont.systemFont(ofSize: 10.5)
        accGuideLabel.textColor = .secondaryLabelColor
        container.addSubview(accGuideLabel)

        // Ayırıcı
        container.addSubview(createSeparator(y: 222))

        // 4. MİKROFON DONANIM VE DEŞİFRE TESTİ
        let testSectionLabel = createSectionLabel(text: "Donanım Testi", y: 236)
        container.addSubview(testSectionLabel)

        testRecordButton = NSButton(frame: NSRect(x: 175, y: 233, width: 170, height: 28))
        testRecordButton.title = "2 Sn Test Kaydı Yap"
        testRecordButton.bezelStyle = .rounded
        testRecordButton.target = self
        testRecordButton.action = #selector(testRecordClicked)
        container.addSubview(testRecordButton)

        testStatusLabel = NSTextField(labelWithString: "Durum: Hazır (Butona basıp konuşun)")
        testStatusLabel.frame = NSRect(x: 355, y: 237, width: 260, height: 20)
        testStatusLabel.font = NSFont.systemFont(ofSize: 11.5, weight: .medium)
        testStatusLabel.textColor = .secondaryLabelColor
        container.addSubview(testStatusLabel)

        let testNote = NSTextField(labelWithString: "Mikrofon ve seçili yapay zeka modelini 2 saniyelik sesle test edin.")
        testNote.frame = NSRect(x: 175, y: 265, width: 440, height: 18)
        testNote.font = NSFont.systemFont(ofSize: 11)
        testNote.textColor = .secondaryLabelColor
        container.addSubview(testNote)

        let resultContainer = NSBox(frame: NSRect(x: 175, y: 289, width: 440, height: 115))
        resultContainer.boxType = .custom
        resultContainer.isTransparent = false
        resultContainer.borderWidth = 1
        resultContainer.cornerRadius = 8
        resultContainer.borderColor = NSColor.separatorColor.withAlphaComponent(0.20)
        resultContainer.fillColor = NSColor.windowBackgroundColor.withAlphaComponent(0.40)
        resultContainer.titlePosition = .noTitle

        let resultFlipped = FlippedContentView(frame: resultContainer.bounds)
        testAudioResultLabel = NSTextField(wrappingLabelWithString: "Test butonuna bastıktan sonra konuşun; ses seviyesi ve model deşifresi burada görüntülenir.")
        testAudioResultLabel.frame = NSRect(x: 12, y: 10, width: 416, height: 95)
        testAudioResultLabel.font = NSFont.systemFont(ofSize: 11.5)
        testAudioResultLabel.textColor = .secondaryLabelColor
        testAudioResultLabel.maximumNumberOfLines = 5
        resultFlipped.addSubview(testAudioResultLabel)

        resultContainer.contentView = resultFlipped
        container.addSubview(resultContainer)

        let tipLabel = NSTextField(labelWithString: "💡 İzinler tamamlandığında Sistem Ayarları gizlenir; açık işleriniz sonlandırılmaz.")
        tipLabel.frame = NSRect(x: 175, y: 416, width: 440, height: 20)
        tipLabel.font = NSFont.systemFont(ofSize: 10.5)
        tipLabel.textColor = .tertiaryLabelColor
        container.addSubview(tipLabel)

        return container
    }

    // =========================================================================
    // TAB 4: Hakkında (Centered Apple Showcase)
    // =========================================================================
    private func buildTab4AboutView() -> NSView {
        let container = FlippedContentView(frame: NSRect(x: 0, y: 0, width: 650, height: 535))

        // 1. Ortalanmış Uygulama İkonu (64x64)
        let iconView = NSImageView(frame: NSRect(x: (650 - 64) / 2, y: 16, width: 64, height: 64))
        if let iconUrl = Bundle.main.url(forResource: "AppIcon", withExtension: "icns") ??
                         Bundle.main.url(forResource: "AppIcon", withExtension: "icns", subdirectory: "VoiceTyping_VoiceTypingCore.bundle"),
           let img = NSImage(contentsOf: iconUrl) {
            iconView.image = img
        } else if #available(macOS 11.0, *), let img = NSImage(systemSymbolName: "waveform.circle.fill", accessibilityDescription: "Voice Typing") {
            iconView.image = img
            iconView.contentTintColor = .systemBlue
        }
        iconView.imageScaling = .scaleProportionallyUpOrDown
        container.addSubview(iconView)

        // 2. Ortalanmış Başlık ve Sürüm
        let appTitle = NSTextField(labelWithString: "Voice Typing for macOS")
        appTitle.frame = NSRect(x: (650 - 450) / 2, y: 88, width: 450, height: 24)
        appTitle.font = NSFont.systemFont(ofSize: 17, weight: .bold)
        appTitle.alignment = .center
        container.addSubview(appTitle)

        let versionLabel = NSTextField(labelWithString: Self.aboutVersionText())
        versionLabel.frame = NSRect(x: (650 - 450) / 2, y: 114, width: 450, height: 18)
        versionLabel.font = NSFont.systemFont(ofSize: 11)
        versionLabel.textColor = .secondaryLabelColor
        versionLabel.alignment = .center
        container.addSubview(versionLabel)

        // 3. Ortalanmış Özellikler Kartı
        let featuresCard = NSBox(frame: NSRect(x: 45, y: 140, width: 560, height: 152))
        featuresCard.boxType = .custom
        featuresCard.cornerRadius = 8
        featuresCard.borderWidth = 1
        featuresCard.borderColor = NSColor.separatorColor.withAlphaComponent(0.22)
        featuresCard.fillColor = NSColor.windowBackgroundColor.withAlphaComponent(0.4)
        featuresCard.titlePosition = .noTitle

        let featuresContent = FlippedContentView(frame: featuresCard.bounds)
        let cardTitle = NSTextField(labelWithString: "✨ Öne Çıkan Yetenekler")
        cardTitle.frame = NSRect(x: 16, y: 10, width: 528, height: 18)
        cardTitle.font = NSFont.systemFont(ofSize: 12, weight: .semibold)
        cardTitle.textColor = .labelColor
        featuresContent.addSubview(cardTitle)

        let featureItems = [
            "• Google Gemini 3.5 Transcribe Live (Gerçek Zamanlı WebSocket Akışı)",
            "• Groq Whisper Large v3 (Düşük Gecikmeli Bulut Deşifre Motoru)",
            "• Akustik Uzatma Penceresi (Son hece ve kelimelerin kesilmesini önler)",
            "• Akıllı Metin Enjeksiyonu (Doğrudan imlece basma ve pano koruması)",
            "• Konuşurken arka plan sesini/müziği akıllıca duraklatma",
            "• Kararlı metin algılama (Settled Silence Debounce)"
        ]
        let featuresText = NSTextField(wrappingLabelWithString: featureItems.joined(separator: "\n"))
        featuresText.frame = NSRect(x: 16, y: 32, width: 528, height: 112)
        featuresText.font = NSFont.systemFont(ofSize: 11.5)
        featuresText.textColor = .secondaryLabelColor
        featuresContent.addSubview(featuresText)
        featuresCard.contentView = featuresContent
        container.addSubview(featuresCard)

        // 4. Ortalanmış Hızlı Kullanım İpucu Kartı
        let tipCard = NSBox(frame: NSRect(x: 45, y: 304, width: 560, height: 72))
        tipCard.boxType = .custom
        tipCard.cornerRadius = 8
        tipCard.borderWidth = 1
        tipCard.borderColor = NSColor.separatorColor.withAlphaComponent(0.22)
        tipCard.fillColor = NSColor.windowBackgroundColor.withAlphaComponent(0.3)
        tipCard.titlePosition = .noTitle

        let tipContent = FlippedContentView(frame: tipCard.bounds)
        let tipTitle = NSTextField(labelWithString: "💡 Hızlı Kullanım İpucu:")
        tipTitle.frame = NSRect(x: 16, y: 8, width: 528, height: 18)
        tipTitle.font = NSFont.systemFont(ofSize: 11.5, weight: .semibold)
        tipTitle.textColor = .systemBlue
        tipContent.addSubview(tipTitle)

        let tipText = NSTextField(wrappingLabelWithString: "Herhangi bir metin alanında imlecinizi konumlandırın. Tetikleyici tuşa (varsayılan Sağ Command ⌘) basılı tutarak konuşun ve bırakın. Konuştuğunuz metin anında imlecin bulunduğu yere yapıştırılır.")
        tipText.frame = NSRect(x: 16, y: 28, width: 528, height: 36)
        tipText.font = NSFont.systemFont(ofSize: 11)
        tipText.textColor = .secondaryLabelColor
        tipContent.addSubview(tipText)
        tipCard.contentView = tipContent
        container.addSubview(tipCard)

        return container
    }

    // =========================================================================
    // YARDIMCI GÖRÜNÜM ÜRETİCİLERİ (TG Pro Layout Helpers)
    // =========================================================================
    private func createSectionLabel(text: String, y: CGFloat) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.frame = NSRect(x: 32, y: y, width: 135, height: 20)
        label.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        label.alignment = .left
        label.textColor = .labelColor
        return label
    }

    private func createNoteLabel(text: String, y: CGFloat) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.frame = NSRect(x: 175, y: y, width: 440, height: 28)
        label.font = NSFont.systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        return label
    }

    private func createSubCheckboxNote(text: String, y: CGFloat) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.frame = NSRect(x: 175, y: y, width: 440, height: 16)
        label.font = NSFont.systemFont(ofSize: 10.5)
        label.textColor = .secondaryLabelColor
        return label
    }

    private func createSeparator(y: CGFloat) -> NSBox {
        let box = NSBox(frame: NSRect(x: 32, y: y, width: 586, height: 1))
        box.boxType = .separator
        return box
    }

    private func createSingleLineInputField(
        frame: NSRect,
        placeholder: String,
        isMonospaced: Bool = true,
        isSecure: Bool = false
    ) -> NSTextField {
        let textField: NSTextField
        if isSecure {
            textField = NSSecureTextField(frame: frame)
        } else {
            textField = NSTextField(frame: frame)
        }
        textField.placeholderString = placeholder
        if isMonospaced {
            textField.font = NSFont.monospacedSystemFont(ofSize: 11.5, weight: .regular)
        } else {
            textField.font = NSFont.systemFont(ofSize: 12)
        }
        textField.maximumNumberOfLines = 1
        textField.usesSingleLineMode = true
        textField.lineBreakMode = .byClipping
        if let cell = textField.cell as? NSTextFieldCell {
            cell.wraps = false
            cell.isScrollable = true
            cell.usesSingleLineMode = true
            cell.lineBreakMode = .byClipping
        }
        return textField
    }

    // =========================================================================
    // PENCERE AÇILIŞ VE KONUMLANDIRMA (True Screen Centering)
    // =========================================================================
    public override func showWindow(_ sender: Any?) {
        refreshPermissionStatuses()
        loadValues()

        super.showWindow(sender)

        // Apple TG Pro standardı: Ekranın tam ortasında (visibleFrame merkezinde) konumlandır
        if let window = window, let screen = window.screen ?? NSScreen.main {
            let visible = screen.visibleFrame
            let winFrame = window.frame
            let x = visible.origin.x + (visible.width - winFrame.width) / 2.0
            let y = visible.origin.y + (visible.height - winFrame.height) / 2.0
            window.setFrameOrigin(NSPoint(x: x, y: y))
        }

        window?.makeKeyAndOrderFront(sender)
        NSApp.activate(ignoringOtherApps: true)
        // Pencere ilk açıldığında metin kutularının otomatik seçilmesini (mavi odak çerçevesi ve metin vurgusu) önle
        DispatchQueue.main.async { [weak self] in
            self?.window?.makeFirstResponder(nil)
        }
        startPermissionPollTimer()
    }

    public func windowWillClose(_ notification: Notification) {
        autoSaveDebounceTimer?.invalidate()
        autoSaveDebounceTimer = nil
        statusResetTimer?.invalidate()
        statusResetTimer = nil
        autoSave(showMessage: false)

        stopPermissionPollTimer()
        if isCapturingKey {
            stopCapturingKey(cancelled: true)
        }
        if AudioRecorder.shared.isRecording {
            _ = AudioRecorder.shared.stop()
        }
    }

    private func startPermissionPollTimer() {
        stopPermissionPollTimer()
        permissionPollTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.refreshPermissionStatuses()
        }
    }

    private func stopPermissionPollTimer() {
        permissionPollTimer?.invalidate()
        permissionPollTimer = nil
    }

    // =========================================================================
    // VERİ YÜKLEME VE SENKRONİZASYON
    // =========================================================================
    @objc public func refreshPermissionStatuses() {
        let wasMicAuthorized = lastKnownMicStatus
        let wasSpeechAuthorized = lastKnownSpeechStatus
        let wasAccAuthorized = lastKnownAccStatus
        let speechRequired = TranscriptionProviderRegistry
            .supports(.onDevice, providerID: ConfigManager.shared.config.provider)
        let mic = PermissionManager.shared.getMicrophoneStatus()
        micStatusLabel.stringValue = "\(mic.badge) \(mic.description)"
        switch mic.status {
        case .authorized:
            micStatusLabel.textColor = .systemGreen
            micActionButton?.title = "Sistem Ayarları"
            lastKnownMicStatus = true
        case .denied:
            micStatusLabel.textColor = .systemRed
            micActionButton?.title = "Sistem Ayarlarını Aç"
            lastKnownMicStatus = false
        case .notDetermined:
            micStatusLabel.textColor = .systemOrange
            micActionButton?.title = "İzin Ver"
            lastKnownMicStatus = false
        default:
            micStatusLabel.textColor = .systemOrange
            micActionButton?.title = "İzin Ver"
            lastKnownMicStatus = false
        }

        let speech = PermissionManager.shared.getSpeechRecognitionStatus()
        if !speechRequired {
            speechStatusLabel.stringValue = "⚪ Gerekli değil (Apple Speech seçili değil)"
            speechStatusLabel.textColor = .secondaryLabelColor
            speechActionButton?.title = "Apple Speech'i seç"
            speechActionButton?.isEnabled = false
            lastKnownSpeechStatus = true
        } else {
            speechStatusLabel.stringValue = "\(speech.badge) \(speech.description)"
            speechActionButton?.isEnabled = true
            switch speech.status {
            case .authorized:
                speechStatusLabel.textColor = .systemGreen
                speechActionButton?.title = "Sistem Ayarları"
                lastKnownSpeechStatus = true
            case .denied:
                speechStatusLabel.textColor = .systemRed
                speechActionButton?.title = "Sistem Ayarlarını Aç"
                lastKnownSpeechStatus = false
            case .notDetermined:
                speechStatusLabel.textColor = .systemOrange
                speechActionButton?.title = "İzin Ver"
                lastKnownSpeechStatus = false
            default:
                speechStatusLabel.textColor = .systemOrange
                speechActionButton?.title = "İzin Ver"
                lastKnownSpeechStatus = false
            }
        }

        let acc = PermissionManager.shared.getAccessibilityStatus()
        accStatusLabel.stringValue = "\(acc.badge) \(acc.description)"
        switch acc.status {
        case .authorized:
            accStatusLabel.textColor = .systemGreen
            accActionButton?.title = "Sistem Ayarları"
            accProgressIndicator?.stopAnimation(nil)
            if !lastKnownAccStatus && permissionPollTimer != nil {
                accGuideLabel?.stringValue = "✅ Yetki verildi! Voice Typing kullanıma hazır."
                accGuideLabel?.textColor = .systemGreen
            }
            lastKnownAccStatus = true
        case .denied:
            accStatusLabel.textColor = .systemRed
            accActionButton?.title = "Sistem Ayarlarını Aç"
            lastKnownAccStatus = false
        default:
            accStatusLabel.textColor = .systemOrange
            accActionButton?.title = "İzin Ver"
            lastKnownAccStatus = false
        }

        let allRequiredPermissionsGranted = mic.status == .authorized &&
            acc.status == .authorized &&
            (!speechRequired || speech.status == .authorized)
        let becameReady = permissionPollTimer != nil &&
            allRequiredPermissionsGranted &&
            (!wasMicAuthorized || !wasAccAuthorized || (speechRequired && !wasSpeechAuthorized))
        if becameReady {
            SoundManager.shared.playSuccess()
            PermissionManager.shared.closeSystemSettings()
        }
    }

    public func loadValues() {
        autoSaveDebounceTimer?.invalidate()
        autoSaveDebounceTimer = nil
        statusResetTimer?.invalidate()
        statusResetTimer = nil

        let cfg = ConfigManager.shared.config

        // Provider — segment sırası kayıt defterindeki sağlayıcı sırasıyla
        // birebir aynıdır; arayüz bu listeyi tek kaynak olarak kullanır.
        let providerIndex = providerSegmentIndex(for: cfg.provider)
        providerPopUp.selectItem(at: providerIndex)
        providerSegmentedControl.selectedSegment = providerIndex
        updateProviderNote(for: TranscriptionProviderRegistry.normalize(cfg.provider))

        // Groq
        groqKeyField.stringValue = cfg.groq_api_key
        if let idx = ConfigManager.availableGroqModels.firstIndex(where: { $0.id == cfg.groq_model }) {
            groqModelPopUp.selectItem(at: idx)
        } else {
            groqModelPopUp.selectItem(at: 0)
        }

        // AssemblyAI
        assemblyAIKeyField.stringValue = cfg.assemblyai_api_key

        // Gemini
        geminiKeyField.stringValue = cfg.gemini_api_key
        if let idx = geminiModelOptions.firstIndex(where: { $0.id == cfg.gemini_model }) {
            geminiModelPopUp.selectItem(at: idx)
        } else {
            geminiModelPopUp.selectItem(at: 0)
        }

        updateProviderStatusLabels()

        // Language
        languageField.stringValue = cfg.language

        // Trigger Key
        selectedTriggerKeyCode = cfg.trigger_key
        updateTriggerKeyUI()

        // Trigger Mode
        let modeIdx: Int
        switch cfg.trigger_mode.lowercased() {
        case "smart":
            modeIdx = 1
        case "toggle":
            modeIdx = 2
        default:
            modeIdx = 0
        }
        modePopUp.selectItem(at: modeIdx)
        modeSegmentedControl.selectedSegment = modeIdx
        updateModeInfoText(for: modeIdx)

        // Gemini Sistem İstemi (System Prompt)
        let currentPrompt = cfg.gemini_system_prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let promptToDisplay = currentPrompt.isEmpty ? AppConfig.defaultGeminiSystemPrompt : currentPrompt
        geminiPromptTextView.string = promptToDisplay
        if let matchIdx = promptPresets.firstIndex(where: { $0.prompt == promptToDisplay }) {
            geminiPromptPresetPopUp.selectItem(at: matchIdx)
        } else {
            geminiPromptPresetPopUp.selectItem(at: promptPresets.count - 1)
        }

        // Özel Sözlük
        customVocabField.stringValue = cfg.custom_vocabulary

        // Onay Kutuları
        hapticFeedbackCheckbox.state = cfg.haptic_feedback ? .on : .off
        removeFillerWordsCheckbox.state = cfg.remove_filler_words ? .on : .off
        saveHistoryCheckbox.state = cfg.save_history ? .on : .off
        playSoundsCheckbox.state = cfg.play_sounds ? .on : .off
        micBoostCheckbox.state = cfg.enable_microphone_boost ? .on : .off
        muteSystemAudioCheckbox.state = (cfg.pause_media_playback || cfg.mute_system_audio) ? .on : .off
        launchAtLoginCheckbox.state = LaunchAtLoginManager.shared.isEnabled ? .on : .off
        showDockIconCheckbox.state = cfg.show_dock_icon ? .on : .off
        onlyInTextFieldsCheckbox.state = cfg.only_in_text_fields ? .on : .off

        // Arka Plan Ses Yönetimi
        switch cfg.background_audio_mode.lowercased() {
        case "ducking":
            backgroundAudioPopUp.selectItem(at: 0)
        case "pause":
            backgroundAudioPopUp.selectItem(at: 1)
        default:
            backgroundAudioPopUp.selectItem(at: 2)
        }

        // Gelişmiş: Auto-Submit
        autoSubmitCheckbox.state = cfg.enable_auto_submit ? .on : .off
        switch cfg.auto_submit_key.lowercased() {
        case "cmd_return", "cmd+return":
            autoSubmitKeyPopUp.selectItem(at: 1)
        case "shift_return", "shift+return":
            autoSubmitKeyPopUp.selectItem(at: 2)
        case "tab":
            autoSubmitKeyPopUp.selectItem(at: 3)
        default:
            autoSubmitKeyPopUp.selectItem(at: 0)
        }

        // Gelişmiş: App Profiles
        appProfilesCheckbox.state = cfg.enable_app_profiles ? .on : .off

        // Gelişmiş: Sound Theme & Volume
        switch cfg.sound_theme.lowercased() {
        case "subtle":
            soundThemePopUp.selectItem(at: 1)
        case "tactile":
            soundThemePopUp.selectItem(at: 2)
        case "chimes":
            soundThemePopUp.selectItem(at: 3)
        default:
            soundThemePopUp.selectItem(at: 0)
        }
        soundVolumeSlider.doubleValue = cfg.sound_volume
        soundVolumeLabel.stringValue = "Ses: \(Int(cfg.sound_volume * 100))%"

        // Gösterge stili: yazı boyutu artık ayarlanmaz (otomatik hesaplanır).
        hudStylePopUp.selectItem(at: HUDPlacement.resolve(cfg.hud_style) == .notch ? 1 : 0)
        updateHudControls()

        // Gelişmiş: Voice Snippets. Alanı örnek metinle doldurmak yerine boş
        // bırakıyoruz; böylece kullanıcı ayarlarda dolaşırken örnek bir snippet
        // istemeden etkinleşmez. Örnek için "+ Örnek Ekle" kullanılabilir.
        voiceSnippetsTextView.string = AppConfig.formatVoiceSnippets(cfg.voice_snippets)

        // Gelişmiş: Pano
        restoreClipboardCheckbox.state = cfg.restore_clipboard ? .on : .off

        updateSystemPromptVisibility()

        statusMessageLabel.stringValue = "Değişiklikler anında kaydedilir."
        statusMessageLabel.textColor = .secondaryLabelColor
        refreshPermissionStatuses()
    }

    // =========================================================================
    // KISAYOL TUŞU YAKALAMA (KEY CAPTURE)
    // =========================================================================
    @objc private func triggerKeyPopUpChanged(_ sender: NSPopUpButton) {
        let tag = sender.selectedTag()
        if tag == -1 {
            startCapturingKey()
        } else if tag > 0 {
            selectedTriggerKeyCode = tag
            updateTriggerKeyHint()
            autoSave()
        }
    }

    @objc private func recordKeyButtonClicked() {
        if isCapturingKey {
            stopCapturingKey(cancelled: true)
        } else {
            startCapturingKey()
        }
    }

    private func startCapturingKey() {
        guard !isCapturingKey else { return }
        isCapturingKey = true
        recordKeyButton.title = "Tuşa Basın (Esc)..."
        recordKeyButton.highlight(true)
        triggerKeyHintLabel.stringValue = "Klavyenizden herhangi bir tuşa basın..."
        triggerKeyHintLabel.textColor = .systemBlue

        keyCaptureMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] event in
            guard let self = self, self.isCapturingKey else { return event }

            let code = Int(event.keyCode)

            if event.type == .keyDown && code == 53 {
                self.stopCapturingKey(cancelled: true)
                return nil
            }

            if event.type == .flagsChanged {
                let isMod = KeyListener.isModifier(keyCode: Int64(code))
                if isMod {
                    let isPressed = !event.modifierFlags.intersection([.command, .option, .control, .shift, .function, .capsLock]).isEmpty || (event.modifierFlags.rawValue & 0x0080207F) != 0
                    if isPressed {
                        self.stopCapturingKey(capturedKeyCode: code)
                        return nil
                    }
                }
            } else if event.type == .keyDown {
                if !event.isARepeat {
                    self.stopCapturingKey(capturedKeyCode: code)
                    return nil
                }
            }

            return event
        }
    }

    private func stopCapturingKey(capturedKeyCode: Int? = nil, cancelled: Bool = false) {
        if let monitor = keyCaptureMonitor {
            NSEvent.removeMonitor(monitor)
            keyCaptureMonitor = nil
        }
        isCapturingKey = false
        recordKeyButton.title = "Özel Tuş Yakala"
        recordKeyButton.highlight(false)

        if let code = capturedKeyCode, !cancelled {
            selectedTriggerKeyCode = code
            SoundManager.shared.playSuccess()
            updateTriggerKeyUI()
            autoSave()
        } else {
            updateTriggerKeyUI()
        }
    }

    private func updateTriggerKeyUI() {
        let standardKeyCodes = Set(TriggerKeyOption.standardKeys.map { $0.keyCode })
        if let menu = triggerKeyPopUp.menu {
            for item in menu.items where item.tag != -1 && !standardKeyCodes.contains(item.tag) {
                menu.removeItem(item)
            }
        }

        if let item = triggerKeyPopUp.itemArray.first(where: { $0.tag == selectedTriggerKeyCode }) {
            triggerKeyPopUp.select(item)
        } else {
            let title = "Özel: \(TriggerKeyOption.name(for: selectedTriggerKeyCode))"
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.tag = selectedTriggerKeyCode
            let insertIdx = max(0, triggerKeyPopUp.numberOfItems - 1)
            triggerKeyPopUp.menu?.insertItem(item, at: insertIdx)
            triggerKeyPopUp.select(item)
        }
        updateTriggerKeyHint()
    }

    private func updateTriggerKeyHint() {
        let name = TriggerKeyOption.name(for: selectedTriggerKeyCode)
        triggerKeyHintLabel.stringValue = "Aktif Kısayol: \(name)"
        triggerKeyHintLabel.textColor = .secondaryLabelColor
    }

    // =========================================================================
    // TEST EYLEMLERİ (BAĞLANTI & SES)
    // =========================================================================
    @objc private func testGroqConnectionClicked() {
        let key = groqKeyField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else {
            groqStatusLabel.stringValue = "⚠️ Lütfen önce Groq API anahtarını girin."
            groqStatusLabel.textColor = .systemOrange
            SoundManager.shared.playCancel()
            return
        }

        groqStatusLabel.stringValue = "⏳ Groq bağlantısı test ediliyor..."
        groqStatusLabel.textColor = .systemBlue

        Transcriber.shared.testGroqConnection(apiKey: key) { [weak self] success, message in
            DispatchQueue.main.async {
                self?.groqStatusLabel.stringValue = message
                self?.groqStatusLabel.textColor = success ? .systemGreen : .systemRed
                if success {
                    SoundManager.shared.playSuccess()
                } else {
                    SoundManager.shared.playCancel()
                }
            }
        }
    }

    @objc private func testAssemblyAIConnectionClicked() {
        let key = assemblyAIKeyField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else {
            assemblyAIStatusLabel.stringValue = "⚠️ Lütfen önce AssemblyAI API anahtarını girin."
            assemblyAIStatusLabel.textColor = .systemOrange
            SoundManager.shared.playCancel()
            return
        }

        assemblyAIStatusLabel.stringValue = "⏳ Dictation API anahtarı doğrulanıyor..."
        assemblyAIStatusLabel.textColor = .systemBlue

        Transcriber.shared.testAssemblyAIConnection(apiKey: key) { [weak self] success, message in
            DispatchQueue.main.async {
                self?.assemblyAIStatusLabel.stringValue = message
                self?.assemblyAIStatusLabel.textColor = success ? .systemGreen : .systemRed
                if success {
                    SoundManager.shared.playSuccess()
                } else {
                    SoundManager.shared.playCancel()
                }
            }
        }
    }

    @objc private func testGeminiConnectionClicked() {
        let key = geminiKeyField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else {
            geminiStatusLabel.stringValue = "⚠️ Lütfen önce Gemini API anahtarını girin."
            geminiStatusLabel.textColor = .systemOrange
            SoundManager.shared.playCancel()
            return
        }

        geminiStatusLabel.stringValue = "⏳ Gemini bağlantısı test ediliyor..."
        geminiStatusLabel.textColor = .systemBlue

        Transcriber.shared.testGeminiConnection(apiKey: key) { [weak self] success, message in
            DispatchQueue.main.async {
                self?.geminiStatusLabel.stringValue = message
                self?.geminiStatusLabel.textColor = success ? .systemGreen : .systemRed
                if success {
                    SoundManager.shared.playSuccess()
                } else {
                    SoundManager.shared.playCancel()
                }
            }
        }
    }

    @objc private func openGroqConsoleClicked() {
        if let url = URL(string: "https://console.groq.com/keys") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func openGeminiConsoleClicked() {
        if let url = URL(string: "https://aistudio.google.com/app/apikey") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func openAssemblyAIConsoleClicked() {
        if let url = URL(string: "https://www.assemblyai.com/dashboard/api-keys") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func testRecordClicked() {
        guard !AudioRecorder.shared.isRecording else {
            testStatusLabel.stringValue = "⚠️ Başka bir kayıt devam ediyor. Önce onu bitirin."
            testStatusLabel.textColor = .systemOrange
            return
        }

        testStatusLabel.stringValue = "🔴 2 saniyelik test kaydı yapılıyor, lütfen konuşun..."
        testStatusLabel.textColor = .systemRed
        testAudioResultLabel.stringValue = ""
        SoundManager.shared.playStart()

        let started = AudioRecorder.shared.start()
        guard started else {
            testStatusLabel.stringValue = "❌ Kayıt başlatılamadı (Mikrofon erişimini kontrol edin)."
            testStatusLabel.textColor = .systemRed
            SoundManager.shared.playCancel()
            return
        }

        testRecordButton.isEnabled = false
        testRecordButton.title = "Kaydediliyor..."

        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            guard let self = self else { return }
            let (data, dur) = AudioRecorder.shared.stop()
            SoundManager.shared.playStop()
            self.testRecordButton.title = "Deşifre ediliyor..."

            guard let audioData = data, !audioData.isEmpty else {
                self.testRecordButton.isEnabled = true
                self.testRecordButton.title = "2 Sn Test Kaydı Yap"
                self.testStatusLabel.stringValue = "⚠️ Ses yakalanamadı (Sessizlik veya mikrofon kapalı)."
                self.testStatusLabel.textColor = .systemOrange
                SoundManager.shared.playCancel()
                return
            }

            self.testStatusLabel.stringValue = "⏳ Deşifre ediliyor (\(String(format: "%.1f", dur)) sn ses)..."
            self.testStatusLabel.textColor = .systemBlue

            var testConfig = ConfigManager.shared.config
            testConfig.provider = self.selectedProviderID
            testConfig.groq_api_key = self.groqKeyField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            testConfig.gemini_api_key = self.geminiKeyField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)

            let groqIdx = max(0, self.groqModelPopUp.indexOfSelectedItem)
            if groqIdx < ConfigManager.availableGroqModels.count {
                testConfig.groq_model = ConfigManager.availableGroqModels[groqIdx].id
            } else {
                testConfig.groq_model = "whisper-large-v3"
            }

            let geminiIdx = max(0, self.geminiModelPopUp.indexOfSelectedItem)
            if geminiIdx < geminiModelOptions.count {
                testConfig.gemini_model = geminiModelOptions[geminiIdx].id
            } else {
                testConfig.gemini_model = AppConfig.defaultConfig.gemini_model
            }

            let lang = self.languageField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if !lang.isEmpty { testConfig.language = lang }

            Transcriber.shared.transcribe(audioData: audioData, config: testConfig) { res in
                DispatchQueue.main.async {
                    let recognizedText = res.text.trimmingCharacters(in: .whitespacesAndNewlines)
                    self.testRecordButton.isEnabled = true
                    self.testRecordButton.title = "2 Sn Test Kaydı Yap"

                    if res.success && !recognizedText.isEmpty {
                        self.testStatusLabel.stringValue = "✅ Deşifre başarılı (\(String(format: "%.2f", res.latency)) sn - \(res.provider))"
                        self.testStatusLabel.textColor = .systemGreen
                        self.testAudioResultLabel.stringValue = "\"\(recognizedText)\""
                        SoundManager.shared.playSuccess()
                    } else if res.success || Transcriber.isNoSpeechMessage(res.error ?? "") {
                        self.testStatusLabel.stringValue = "⚠️ Ses algılanmadı. Lütfen test sırasında konuşun."
                        self.testStatusLabel.textColor = .systemOrange
                        self.testAudioResultLabel.stringValue = "Mikrofon çalışıyor olabilir; ancak deşifre edilecek konuşma bulunamadı."
                        SoundManager.shared.playCancel()
                    } else {
                        self.testStatusLabel.stringValue = "❌ Deşifre hatası (\(res.provider))"
                        self.testStatusLabel.textColor = .systemRed
                        self.testAudioResultLabel.stringValue = res.error ?? "Bilinmeyen hata"
                        SoundManager.shared.playCancel()
                    }
                }
            }
        }
    }

    // =========================================================================
    // SİSTEM AYARLARI BUTONLARI & KAYDET
    // =========================================================================
    @objc private func openMicSettingsClicked() {
        let mic = PermissionManager.shared.getMicrophoneStatus()
        if mic.status == .notDetermined {
            PermissionManager.shared.requestMicrophonePermission { [weak self] granted in
                self?.refreshPermissionStatuses()
                if granted {
                    SoundManager.shared.playSuccess()
                }
            }
        } else {
            PermissionManager.shared.openMicrophoneSettings()
        }
        startPermissionPollTimer()
    }

    @objc private func openSpeechSettingsClicked() {
        let speech = PermissionManager.shared.getSpeechRecognitionStatus()
        if speech.status == .notDetermined {
            PermissionManager.shared.requestSpeechRecognitionPermission { [weak self] granted in
                self?.refreshPermissionStatuses()
                if granted {
                    SoundManager.shared.playSuccess()
                }
            }
        } else {
            PermissionManager.shared.openSpeechRecognitionSettings()
        }
        startPermissionPollTimer()
    }

    @objc private func openAccSettingsClicked() {
        if !AXIsProcessTrusted() {
            accGuideLabel?.stringValue = "Sistem Ayarları açıldı. 'VoiceTyping' anahtarını açın... (Otomatik algılanıyor)"
            accGuideLabel?.textColor = .systemBlue
            accProgressIndicator?.startAnimation(nil)
            PermissionManager.shared.openAccessibilitySettings()
        } else {
            PermissionManager.shared.openAccessibilitySettings()
        }
        startPermissionPollTimer()
    }

    @objc private func closeClicked() {
        if isCapturingKey {
            stopCapturingKey(cancelled: true)
        }
        window?.close()
    }

    // =========================================================================
    // OTOMATİK KAYIT & METİN DELEGELERİ (Modeless Auto-Save & Debounce)
    // =========================================================================
    @objc private func checkboxChanged(_ sender: NSButton) {
        autoSave()
    }

    public func controlTextDidChange(_ obj: Notification) {
        updateProviderStatusLabels()
        scheduleAutoSave()
    }

    public func controlTextDidEndEditing(_ obj: Notification) {
        autoSaveDebounceTimer?.invalidate()
        autoSaveDebounceTimer = nil
        autoSave()
    }

    public func textDidChange(_ notification: Notification) {
        scheduleAutoSave()
    }

    private func scheduleAutoSave() {
        autoSaveDebounceTimer?.invalidate()
        autoSaveDebounceTimer = Timer.scheduledTimer(withTimeInterval: 0.35, repeats: false) { [weak self] _ in
            self?.autoSave()
        }
    }

    /// Segment denetiminde seçili sağlayıcının kimliği.
    /// Segment→kimlik eşlemesi tek yerde tutulur; daha önce iki ayrı switch
    /// birbiriyle tutarsızdı ve canlı test akışı AssemblyAI'yi yanlış
    /// sağlayıcıya eşliyordu.
    private var selectedProviderID: String {
        let providers = TranscriptionProviderRegistry.all
        let index = providerSegmentedControl.selectedSegment
        guard index >= 0, index < providers.count else {
            return TranscriptionProviderRegistry.defaultProviderID
        }
        return providers[index].id
    }

    @objc public func autoSave(showMessage: Bool = true) {
        let selectedProvider = selectedProviderID

        let groqKey = groqKeyField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let geminiKey = geminiKeyField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let assemblyAIKey = assemblyAIKeyField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)

        let groqIdx = max(0, groqModelPopUp.indexOfSelectedItem)
        let groqModel = (groqIdx < ConfigManager.availableGroqModels.count)
            ? ConfigManager.availableGroqModels[groqIdx].id
            : "whisper-large-v3"

        let geminiIdx = max(0, geminiModelPopUp.indexOfSelectedItem)
        let geminiModel = (geminiIdx < geminiModelOptions.count)
            ? geminiModelOptions[geminiIdx].id
            : AppConfig.defaultConfig.gemini_model

        let language = languageField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)

        let modeStr: String
        switch modePopUp.indexOfSelectedItem {
        case 1: modeStr = "smart"
        case 2: modeStr = "toggle"
        default: modeStr = "hold"
        }

        let rawPrompt = geminiPromptTextView.string.trimmingCharacters(in: .whitespacesAndNewlines)
        let geminiPrompt = rawPrompt.isEmpty ? AppConfig.defaultGeminiSystemPrompt : rawPrompt

        let customVocab = customVocabField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let hapticOn = hapticFeedbackCheckbox.state == .on
        let removeFillerOn = removeFillerWordsCheckbox.state == .on
        let saveHistOn = saveHistoryCheckbox.state == .on
        let onlyInTextFieldsOn = onlyInTextFieldsCheckbox.state == .on

        let playSounds = playSoundsCheckbox.state == .on
        let micBoostOn = micBoostCheckbox.state == .on
        let launchLogin = launchAtLoginCheckbox.state == .on
        let showDock = showDockIconCheckbox.state == .on
        let triggerKey = selectedTriggerKeyCode

        let bgAudioIdx = backgroundAudioPopUp.indexOfSelectedItem
        let bgAudioMode: String
        switch bgAudioIdx {
        case 0: bgAudioMode = "ducking"
        case 1: bgAudioMode = "pause"
        default: bgAudioMode = "none"
        }

        // Gelişmiş Ayarlar
        let autoSubmitOn = autoSubmitCheckbox.state == .on
        let autoSubmitKey: String
        switch autoSubmitKeyPopUp.indexOfSelectedItem {
        case 1: autoSubmitKey = "cmd_return"
        case 2: autoSubmitKey = "shift_return"
        case 3: autoSubmitKey = "tab"
        default: autoSubmitKey = "return"
        }

        let appProfilesOn = appProfilesCheckbox.state == .on

        let soundTheme: String
        switch soundThemePopUp.indexOfSelectedItem {
        case 1: soundTheme = "subtle"
        case 2: soundTheme = "tactile"
        case 3: soundTheme = "chimes"
        default: soundTheme = "modern"
        }

        let soundVolume = soundVolumeSlider.doubleValue
        let snippetsText = voiceSnippetsTextView.string
        let snippets = AppConfig.parseVoiceSnippets(from: snippetsText)

        LaunchAtLoginManager.shared.setEnabled(launchLogin)

        let success = ConfigManager.shared.update { cfg in
            cfg.provider = selectedProvider
            cfg.groq_api_key = groqKey
            cfg.gemini_api_key = geminiKey
            cfg.assemblyai_api_key = assemblyAIKey
            cfg.groq_model = groqModel
            cfg.gemini_model = geminiModel
            cfg.language = language.isEmpty ? "tr" : language
            cfg.trigger_key = triggerKey
            cfg.trigger_mode = modeStr
            cfg.dictation_mode = "direct"
            cfg.gemini_system_prompt = geminiPrompt
            cfg.custom_vocabulary = customVocab
            cfg.haptic_feedback = hapticOn
            cfg.remove_filler_words = removeFillerOn
            cfg.save_history = saveHistOn
            cfg.play_sounds = playSounds
            cfg.restore_clipboard = restoreClipboardCheckbox.state == .on
            cfg.background_audio_mode = bgAudioMode
            cfg.enable_microphone_boost = micBoostOn
            cfg.pause_media_playback = (bgAudioMode == "pause")
            cfg.mute_system_audio = (bgAudioMode == "ducking" || bgAudioMode == "pause")
            cfg.show_dock_icon = showDock
            cfg.only_in_text_fields = onlyInTextFieldsOn
            cfg.enable_auto_submit = autoSubmitOn
            cfg.auto_submit_key = autoSubmitKey
            cfg.enable_app_profiles = appProfilesOn
            cfg.sound_theme = soundTheme
            cfg.sound_volume = soundVolume
            cfg.voice_snippets = snippets
            cfg.hud_style = hudStylePopUp.indexOfSelectedItem == 1 ? "notch" : "pill"
        }

        AppDelegate.updateDockVisibility(showDock)
        SoundManager.shared.isEnabled = playSounds
        KeyListener.shared.resetState()

        if success {
            onConfigUpdated?()
            if showMessage {
                statusMessageLabel.stringValue = "✓ Kaydedildi"
                statusMessageLabel.textColor = .systemGreen
                statusResetTimer?.invalidate()
                statusResetTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: false) { [weak self] _ in
                    self?.statusMessageLabel.stringValue = "Değişiklikler anında kaydedilir."
                    self?.statusMessageLabel.textColor = .secondaryLabelColor
                }
            }
        } else {
            if showMessage {
                statusMessageLabel.stringValue = "❌ Kayıt başarısız oldu! config.json yazılamadı."
                statusMessageLabel.textColor = .systemRed
            }
        }
    }

    @objc public func saveClicked() {
        autoSave(showMessage: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.window?.close()
        }
    }
}
