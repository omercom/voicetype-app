import Foundation
import AppKit

private class FlippedContentView: NSView {
    override var isFlipped: Bool { return true }
}

public class SettingsWindowController: NSWindowController, NSWindowDelegate, NSToolbarDelegate {
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
    private var launchAtLoginCheckbox: NSButton!
    private var showDockIconCheckbox: NSButton!

    // Tab 2: Yapay Zeka & Modeller
    private var providerSegmentedControl: NSSegmentedControl!
    private var providerPopUp: NSPopUpButton!
    private var groqKeyField: NSTextField!
    private var groqModelPopUp: NSPopUpButton!
    private var groqStatusLabel: NSTextField!
    private var geminiKeyField: NSTextField!
    private var geminiModelPopUp: NSPopUpButton!
    private var geminiStatusLabel: NSTextField!

    // Tab 3: Sistem & İzinler
    private var micStatusLabel: NSTextField!
    private var micActionButton: NSButton!
    private var accStatusLabel: NSTextField!
    private var accActionButton: NSButton!
    private var accProgressIndicator: NSProgressIndicator!
    private var accGuideLabel: NSTextField!
    private var lastKnownAccStatus: Bool = false
    private var lastKnownMicStatus: Bool = false
    private var testStatusLabel: NSTextField!
    private var testAudioResultLabel: NSTextField!
    private var testRecordButton: NSButton!

    // Footer
    private var statusMessageLabel: NSTextField!

    // Custom Key Capture State
    private var selectedTriggerKeyCode: Int = 54
    private var isCapturingKey: Bool = false
    private var keyCaptureMonitor: Any?

    public var onConfigUpdated: (() -> Void)?
    private var permissionPollTimer: Timer?

    private let toolbarTabIdentifiers: [NSToolbarItem.Identifier] = [
        NSToolbarItem.Identifier("general"),
        NSToolbarItem.Identifier("ai"),
        NSToolbarItem.Identifier("permissions"),
        NSToolbarItem.Identifier("about")
    ]

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
            labels: ["Genel", "Yapay Zeka", "İzinler", "Hakkında"],
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

        let tab3Item = NSTabViewItem(identifier: "tab3")
        tab3Item.view = buildTab3PermissionsView()
        tabView.addTabViewItem(tab3Item)

        let tab4Item = NSTabViewItem(identifier: "tab4")
        tab4Item.view = buildTab4AboutView()
        tabView.addTabViewItem(tab4Item)

        mainContainer.addSubview(tabView)

        // =====================================================================
        // ALT BÖLÜM: FOOTER & ACTIONS
        // =====================================================================
        let bottomSeparator = NSBox(frame: NSRect(x: 24, y: 540, width: 602, height: 1))
        bottomSeparator.boxType = .separator
        mainContainer.addSubview(bottomSeparator)

        statusMessageLabel = NSTextField(labelWithString: "")
        statusMessageLabel.frame = NSRect(x: 24, y: 554, width: 380, height: 22)
        statusMessageLabel.font = NSFont.systemFont(ofSize: 11)
        statusMessageLabel.textColor = .secondaryLabelColor
        mainContainer.addSubview(statusMessageLabel)

        let cancelBtn = NSButton(frame: NSRect(x: 420, y: 550, width: 95, height: 32))
        cancelBtn.title = "Kapat"
        cancelBtn.bezelStyle = .rounded
        cancelBtn.target = self
        cancelBtn.action = #selector(closeClicked)
        mainContainer.addSubview(cancelBtn)

        let saveBtn = NSButton(frame: NSRect(x: 525, y: 550, width: 100, height: 32))
        saveBtn.title = "Kaydet"
        saveBtn.bezelStyle = .rounded
        saveBtn.keyEquivalent = "\r"
        saveBtn.target = self
        saveBtn.action = #selector(saveClicked)
        mainContainer.addSubview(saveBtn)

        window.initialFirstResponder = mainContainer
    }

    @objc private func tabSegmentChanged(_ sender: NSSegmentedControl) {
        selectTab(index: sender.selectedSegment)
    }

    public func selectTab(index: Int) {
        guard index >= 0 && index < tabView.numberOfTabViewItems else { return }
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
        let container = FlippedContentView(frame: NSRect(x: 0, y: 0, width: 650, height: 535))

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

        hapticFeedbackCheckbox = NSButton(checkboxWithTitle: "Dokunsal titreşim (Trackpad Force Touch tıkı)", target: nil, action: nil)
        hapticFeedbackCheckbox.frame = NSRect(x: 175, y: 278, width: 440, height: 18)
        container.addSubview(hapticFeedbackCheckbox)

        removeFillerWordsCheckbox = NSButton(checkboxWithTitle: "Dolgu kelimelerini otomatik temizle ('ııı', 'şey', 'yani', 'hımm')", target: nil, action: nil)
        removeFillerWordsCheckbox.frame = NSRect(x: 175, y: 302, width: 440, height: 18)
        container.addSubview(removeFillerWordsCheckbox)

        saveHistoryCheckbox = NSButton(checkboxWithTitle: "Dikte geçmişini menü çubuğunda sakla (Son 15 dikte)", target: nil, action: nil)
        saveHistoryCheckbox.frame = NSRect(x: 175, y: 326, width: 440, height: 18)
        container.addSubview(saveHistoryCheckbox)

        muteSystemAudioCheckbox = NSButton(checkboxWithTitle: "Konuşurken arka plan medyasını/müziği duraklat", target: nil, action: nil)
        muteSystemAudioCheckbox.frame = NSRect(x: 175, y: 350, width: 440, height: 18)
        container.addSubview(muteSystemAudioCheckbox)

        playSoundsCheckbox = NSButton(checkboxWithTitle: "Sistem ses efektlerini çal", target: nil, action: nil)
        playSoundsCheckbox.frame = NSRect(x: 175, y: 374, width: 440, height: 18)
        container.addSubview(playSoundsCheckbox)

        launchAtLoginCheckbox = NSButton(checkboxWithTitle: "Mac açıldığında otomatik başlat", target: nil, action: nil)
        launchAtLoginCheckbox.frame = NSRect(x: 175, y: 398, width: 440, height: 18)
        container.addSubview(launchAtLoginCheckbox)

        showDockIconCheckbox = NSButton(checkboxWithTitle: "Dock simgesini kalıcı olarak göster", target: nil, action: nil)
        showDockIconCheckbox.frame = NSRect(x: 175, y: 422, width: 440, height: 18)
        container.addSubview(showDockIconCheckbox)

        return container
    }

    @objc private func modeSegmentedChanged(_ sender: NSSegmentedControl) {
        modePopUp.selectItem(at: sender.selectedSegment)
        updateModeInfoText(for: sender.selectedSegment)
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
        let container = FlippedContentView(frame: NSRect(x: 0, y: 0, width: 650, height: 535))

        // 1. Aktif Sağlayıcı
        let provLabel = createSectionLabel(text: "Aktif Sağlayıcı", y: 16)
        container.addSubview(provLabel)

        providerSegmentedControl = NSSegmentedControl(
            labels: ["Google Gemini Live (Önerilen)", "Groq Whisper"],
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
        providerPopUp.addItem(withTitle: "Groq Whisper (whisper-large-v3 - Yüksek Kalite)")
        providerPopUp.addItem(withTitle: "Google Gemini (Doğal Dil & Bağlamsal)")
        providerPopUp.isHidden = true
        container.addSubview(providerPopUp)

        let provNote = createNoteLabel(text: "Düşük gecikme ve gerçek zamanlı konuşma akışı için Google Gemini Live önerilir.", y: 44)
        container.addSubview(provNote)

        container.addSubview(createSeparator(y: 72))

        // 2. Google Gemini
        let geminiSection = createSectionLabel(text: "Google Gemini", y: 86)
        container.addSubview(geminiSection)

        geminiKeyField = createSingleLineInputField(
            frame: NSRect(x: 175, y: 84, width: 440, height: 24),
            placeholder: "AIzaSy..."
        )
        container.addSubview(geminiKeyField)

        geminiModelPopUp = NSPopUpButton(frame: NSRect(x: 175, y: 116, width: 440, height: 26), pullsDown: false)
        for m in ConfigManager.availableGeminiModels {
            geminiModelPopUp.addItem(withTitle: m.name)
        }
        geminiModelPopUp.target = self
        geminiModelPopUp.action = #selector(geminiModelChanged(_:))
        container.addSubview(geminiModelPopUp)

        let testGeminiBtn = NSButton(frame: NSRect(x: 175, y: 150, width: 145, height: 28))
        testGeminiBtn.title = "Bağlantıyı Test Et"
        testGeminiBtn.bezelStyle = .rounded
        testGeminiBtn.target = self
        testGeminiBtn.action = #selector(testGeminiConnectionClicked)
        container.addSubview(testGeminiBtn)

        let getGeminiKeyBtn = NSButton(frame: NSRect(x: 326, y: 150, width: 140, height: 28))
        getGeminiKeyBtn.title = "API Anahtarı Al ↗"
        getGeminiKeyBtn.bezelStyle = .rounded
        getGeminiKeyBtn.target = self
        getGeminiKeyBtn.action = #selector(openGeminiConsoleClicked)
        container.addSubview(getGeminiKeyBtn)

        geminiStatusLabel = NSTextField(wrappingLabelWithString: "")
        geminiStatusLabel.frame = NSRect(x: 175, y: 182, width: 440, height: 32)
        geminiStatusLabel.font = NSFont.systemFont(ofSize: 11)
        geminiStatusLabel.textColor = .secondaryLabelColor
        geminiStatusLabel.maximumNumberOfLines = 2
        container.addSubview(geminiStatusLabel)

        let geminiNote = createNoteLabel(text: "WebSocket canlı akışı sayesinde konuşurken kelimeler doğrudan canlı işlenir.", y: 218)
        container.addSubview(geminiNote)

        container.addSubview(createSeparator(y: 242))

        // 3. Groq Whisper
        let groqSection = createSectionLabel(text: "Groq Whisper", y: 256)
        container.addSubview(groqSection)

        groqKeyField = createSingleLineInputField(
            frame: NSRect(x: 175, y: 254, width: 440, height: 24),
            placeholder: "gsk_..."
        )
        container.addSubview(groqKeyField)

        groqModelPopUp = NSPopUpButton(frame: NSRect(x: 175, y: 286, width: 440, height: 26), pullsDown: false)
        for m in ConfigManager.availableGroqModels {
            groqModelPopUp.addItem(withTitle: m.name)
        }
        groqModelPopUp.target = self
        groqModelPopUp.action = #selector(groqModelChanged(_:))
        container.addSubview(groqModelPopUp)

        let testGroqBtn = NSButton(frame: NSRect(x: 175, y: 320, width: 145, height: 28))
        testGroqBtn.title = "Bağlantıyı Test Et"
        testGroqBtn.bezelStyle = .rounded
        testGroqBtn.target = self
        testGroqBtn.action = #selector(testGroqConnectionClicked)
        container.addSubview(testGroqBtn)

        let getGroqKeyBtn = NSButton(frame: NSRect(x: 326, y: 320, width: 140, height: 28))
        getGroqKeyBtn.title = "API Anahtarı Al ↗"
        getGroqKeyBtn.bezelStyle = .rounded
        getGroqKeyBtn.target = self
        getGroqKeyBtn.action = #selector(openGroqConsoleClicked)
        container.addSubview(getGroqKeyBtn)

        groqStatusLabel = NSTextField(wrappingLabelWithString: "")
        groqStatusLabel.frame = NSRect(x: 175, y: 352, width: 440, height: 32)
        groqStatusLabel.font = NSFont.systemFont(ofSize: 11)
        groqStatusLabel.textColor = .secondaryLabelColor
        groqStatusLabel.maximumNumberOfLines = 2
        container.addSubview(groqStatusLabel)

        let groqNote = createNoteLabel(text: "Whisper Large modelini Groq LPU bulut donanımında ~0.3 saniyede tamamlar.", y: 388)
        container.addSubview(groqNote)

        container.addSubview(createSeparator(y: 410))

        // 4. Gemini Sistem İstemi (System Instruction / Cevap & Yazım Tarzı)
        promptSectionLabel = createSectionLabel(text: "Sistem İstemi", y: 422)
        container.addSubview(promptSectionLabel)

        geminiPromptPresetPopUp = NSPopUpButton(frame: NSRect(x: 175, y: 420, width: 440, height: 26), pullsDown: false)
        for preset in promptPresets {
            geminiPromptPresetPopUp.addItem(withTitle: preset.name)
        }
        geminiPromptPresetPopUp.target = self
        geminiPromptPresetPopUp.action = #selector(promptPresetChanged(_:))
        container.addSubview(geminiPromptPresetPopUp)

        geminiPromptScrollView = NSScrollView(frame: NSRect(x: 175, y: 450, width: 440, height: 54))
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
        geminiPromptScrollView.documentView = geminiPromptTextView
        container.addSubview(geminiPromptScrollView)

        promptNoteLabel = createNoteLabel(text: "Gemini bu sistem talimatına (systemInstruction) göre çıktıyı biçimlendirir ve üslubu belirler.", y: 508)
        container.addSubview(promptNoteLabel)

        promptUnsupportedLabel = NSTextField(wrappingLabelWithString: "ℹ️ Seçili model saf ses deşifre (ASR) modelidir; konuşulanları doğrudan birebir metne döker. Sistem istemi, üslup ve anında çeviri özellikleri yalnızca Gemini Flash modellerinde (örn: Gemini 3.6 Flash) desteklenir.")
        promptUnsupportedLabel.frame = NSRect(x: 175, y: 422, width: 440, height: 42)
        promptUnsupportedLabel.font = NSFont.systemFont(ofSize: 11)
        promptUnsupportedLabel.textColor = .secondaryLabelColor
        promptUnsupportedLabel.isHidden = true
        container.addSubview(promptUnsupportedLabel)

        return container
    }

    private func updateSystemPromptVisibility() {
        let isGemini = (providerSegmentedControl.selectedSegment == 0)
        let geminiIdx = max(0, geminiModelPopUp.indexOfSelectedItem)
        let modelId = (geminiIdx < ConfigManager.availableGeminiModels.count)
            ? ConfigManager.availableGeminiModels[geminiIdx].id
            : "gemini-3.5-transcribe-live"

        let isSupported = isGemini && ConfigManager.supportsSystemPrompt(model: modelId)

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

    @objc private func geminiModelChanged(_ sender: NSPopUpButton) {
        updateSystemPromptVisibility()
    }

    @objc private func groqModelChanged(_ sender: NSPopUpButton) {
        updateSystemPromptVisibility()
    }

    @objc private func promptPresetChanged(_ sender: NSPopUpButton) {
        let idx = sender.indexOfSelectedItem
        if idx >= 0 && idx < promptPresets.count - 1 {
            geminiPromptTextView.string = promptPresets[idx].prompt
        }
    }

    @objc private func providerSegmentedChanged(_ sender: NSSegmentedControl) {
        // sender index 0 -> Gemini, index 1 -> Groq
        // providerPopUp index 0 -> Groq, index 1 -> Gemini
        let popUpIndex = (sender.selectedSegment == 0) ? 1 : 0
        providerPopUp.selectItem(at: popUpIndex)
        updateSystemPromptVisibility()
    }

    // =========================================================================
    // TAB 3: Sistem & İzinler (Native macOS Two-Column Layout & Hardware Test)
    // =========================================================================
    private func buildTab3PermissionsView() -> NSView {
        let container = FlippedContentView(frame: NSRect(x: 0, y: 0, width: 650, height: 535))

        // 1. MİKROFON İZNİ
        let micSectionLabel = createSectionLabel(text: "Mikrofon İzni", y: 22)
        container.addSubview(micSectionLabel)

        micStatusLabel = NSTextField(labelWithString: "🟢 Yetki Verildi (Aktif)")
        micStatusLabel.frame = NSRect(x: 175, y: 22, width: 275, height: 22)
        micStatusLabel.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        micStatusLabel.textColor = .systemGreen
        container.addSubview(micStatusLabel)

        micActionButton = NSButton(frame: NSRect(x: 465, y: 19, width: 150, height: 28))
        micActionButton.title = "Sistem Ayarları"
        micActionButton.bezelStyle = .rounded
        micActionButton.target = self
        micActionButton.action = #selector(openMicSettingsClicked)
        container.addSubview(micActionButton)

        let micNote = createNoteLabel(text: "Ses kaydı ve yapay zeka ile deşifre için gereklidir.", y: 48)
        container.addSubview(micNote)

        // Ayırıcı
        container.addSubview(createSeparator(y: 78))

        // 2. ERİŞİLEBİLİRLİK İZNİ
        let accSectionLabel = createSectionLabel(text: "Erişilebilirlik", y: 94)
        container.addSubview(accSectionLabel)

        accStatusLabel = NSTextField(labelWithString: "🟢 Yetki Verildi (Aktif)")
        accStatusLabel.frame = NSRect(x: 175, y: 94, width: 275, height: 22)
        accStatusLabel.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        accStatusLabel.textColor = .systemGreen
        container.addSubview(accStatusLabel)

        accActionButton = NSButton(frame: NSRect(x: 465, y: 91, width: 150, height: 28))
        accActionButton.title = "Sistem Ayarları"
        accActionButton.bezelStyle = .rounded
        accActionButton.target = self
        accActionButton.action = #selector(openAccSettingsClicked)
        container.addSubview(accActionButton)

        let accNote = createNoteLabel(text: "Kısayol tuşunu dinlemek ve metni imlece yazmak için gereklidir.", y: 120)
        container.addSubview(accNote)

        // Canlı Algılama Göstergesi (Yalnızca izin beklenirken görünür)
        accProgressIndicator = NSProgressIndicator(frame: NSRect(x: 175, y: 147, width: 14, height: 14))
        accProgressIndicator.style = .spinning
        accProgressIndicator.controlSize = .small
        accProgressIndicator.isDisplayedWhenStopped = false
        container.addSubview(accProgressIndicator)

        accGuideLabel = NSTextField(labelWithString: "")
        accGuideLabel.frame = NSRect(x: 195, y: 145, width: 420, height: 18)
        accGuideLabel.font = NSFont.systemFont(ofSize: 10.5)
        accGuideLabel.textColor = .secondaryLabelColor
        container.addSubview(accGuideLabel)

        // Ayırıcı
        container.addSubview(createSeparator(y: 168))

        // 3. MİKROFON DONANIM VE DEŞİFRE TESTİ
        let testSectionLabel = createSectionLabel(text: "Donanım Testi", y: 184)
        container.addSubview(testSectionLabel)

        testRecordButton = NSButton(frame: NSRect(x: 175, y: 181, width: 170, height: 28))
        testRecordButton.title = "2 Sn Test Kaydı Yap"
        testRecordButton.bezelStyle = .rounded
        testRecordButton.target = self
        testRecordButton.action = #selector(testRecordClicked)
        container.addSubview(testRecordButton)

        testStatusLabel = NSTextField(labelWithString: "Durum: Hazır (Butona basıp konuşun)")
        testStatusLabel.frame = NSRect(x: 355, y: 185, width: 260, height: 20)
        testStatusLabel.font = NSFont.systemFont(ofSize: 11.5, weight: .medium)
        testStatusLabel.textColor = .secondaryLabelColor
        container.addSubview(testStatusLabel)

        let testNote = NSTextField(labelWithString: "Mikrofon ve seçili yapay zeka modelini 2 saniyelik sesle test edin.")
        testNote.frame = NSRect(x: 175, y: 213, width: 440, height: 18)
        testNote.font = NSFont.systemFont(ofSize: 11)
        testNote.textColor = .secondaryLabelColor
        container.addSubview(testNote)

        let resultContainer = NSBox(frame: NSRect(x: 175, y: 237, width: 440, height: 125))
        resultContainer.boxType = .custom
        resultContainer.isTransparent = false
        resultContainer.borderWidth = 1
        resultContainer.cornerRadius = 8
        resultContainer.borderColor = NSColor.separatorColor.withAlphaComponent(0.20)
        resultContainer.fillColor = NSColor.windowBackgroundColor.withAlphaComponent(0.40)
        resultContainer.titlePosition = .noTitle

        let resultFlipped = FlippedContentView(frame: resultContainer.bounds)
        testAudioResultLabel = NSTextField(wrappingLabelWithString: "Test butonuna bastıktan sonra konuşun; ses seviyesi ve model deşifresi burada görüntülenir.")
        testAudioResultLabel.frame = NSRect(x: 12, y: 10, width: 416, height: 105)
        testAudioResultLabel.font = NSFont.systemFont(ofSize: 11.5)
        testAudioResultLabel.textColor = .secondaryLabelColor
        testAudioResultLabel.maximumNumberOfLines = 5
        resultFlipped.addSubview(testAudioResultLabel)

        resultContainer.contentView = resultFlipped
        container.addSubview(resultContainer)

        let tipLabel = NSTextField(labelWithString: "💡 İzin verildiğinde macOS Sistem Ayarları penceresi otomatik kapatılır.")
        tipLabel.frame = NSRect(x: 175, y: 372, width: 440, height: 20)
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

        let versionLabel = NSTextField(labelWithString: "Sürüm 2.0 • Native Swift 6 / Apple Silicon & Intel")
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

    private func createSingleLineInputField(frame: NSRect, placeholder: String, isMonospaced: Bool = true) -> NSTextField {
        let textField = NSTextField(frame: frame)
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
        let mic = PermissionManager.shared.getMicrophoneStatus()
        micStatusLabel.stringValue = "\(mic.badge) \(mic.description)"
        switch mic.status {
        case .authorized:
            micStatusLabel.textColor = .systemGreen
            micActionButton?.title = "Sistem Ayarları"
            if !lastKnownMicStatus && permissionPollTimer != nil {
                SoundManager.shared.playSuccess()
                PermissionManager.shared.closeSystemSettings()
            }
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
                SoundManager.shared.playSuccess()
                PermissionManager.shared.closeSystemSettings()
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
    }

    public func loadValues() {
        let cfg = ConfigManager.shared.config

        // Provider
        if cfg.provider.lowercased() == "gemini" {
            providerPopUp.selectItem(at: 1)
            providerSegmentedControl.selectedSegment = 0
        } else {
            providerPopUp.selectItem(at: 0)
            providerSegmentedControl.selectedSegment = 1
        }

        // Groq
        groqKeyField.stringValue = cfg.groq_api_key
        if let idx = ConfigManager.availableGroqModels.firstIndex(where: { $0.id == cfg.groq_model }) {
            groqModelPopUp.selectItem(at: idx)
        } else {
            groqModelPopUp.selectItem(at: 0)
        }

        // Gemini
        geminiKeyField.stringValue = cfg.gemini_api_key
        if let idx = ConfigManager.availableGeminiModels.firstIndex(where: { $0.id == cfg.gemini_model }) {
            geminiModelPopUp.selectItem(at: idx)
        } else {
            geminiModelPopUp.selectItem(at: 0)
        }

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
        muteSystemAudioCheckbox.state = cfg.mute_system_audio ? .on : .off
        launchAtLoginCheckbox.state = LaunchAtLoginManager.shared.isEnabled ? .on : .off
        showDockIconCheckbox.state = cfg.show_dock_icon ? .on : .off

        updateSystemPromptVisibility()

        statusMessageLabel.stringValue = "Ayarlar başarıyla yüklendi."
        statusMessageLabel.textColor = .secondaryLabelColor
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

    @objc private func testRecordClicked() {
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

        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            guard let self = self else { return }
            let (data, dur) = AudioRecorder.shared.stop()
            SoundManager.shared.playStop()
            self.testRecordButton.isEnabled = true

            guard let audioData = data, !audioData.isEmpty else {
                self.testStatusLabel.stringValue = "⚠️ Ses yakalanamadı (Sessizlik veya mikrofon kapalı)."
                self.testStatusLabel.textColor = .systemOrange
                SoundManager.shared.playCancel()
                return
            }

            self.testStatusLabel.stringValue = "⏳ Deşifre ediliyor (\(String(format: "%.1f", dur)) sn ses)..."
            self.testStatusLabel.textColor = .systemBlue

            var testConfig = ConfigManager.shared.config
            let selectedProvider = self.providerPopUp.indexOfSelectedItem == 1 ? "gemini" : "groq"
            testConfig.provider = selectedProvider
            testConfig.groq_api_key = self.groqKeyField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            testConfig.gemini_api_key = self.geminiKeyField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)

            let groqIdx = max(0, self.groqModelPopUp.indexOfSelectedItem)
            if groqIdx < ConfigManager.availableGroqModels.count {
                testConfig.groq_model = ConfigManager.availableGroqModels[groqIdx].id
            } else {
                testConfig.groq_model = "whisper-large-v3"
            }

            let geminiIdx = max(0, self.geminiModelPopUp.indexOfSelectedItem)
            if geminiIdx < ConfigManager.availableGeminiModels.count {
                testConfig.gemini_model = ConfigManager.availableGeminiModels[geminiIdx].id
            } else {
                testConfig.gemini_model = "gemini-3.5-transcribe-live"
            }

            let lang = self.languageField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if !lang.isEmpty { testConfig.language = lang }

            Transcriber.shared.transcribe(audioData: audioData, config: testConfig) { res in
                DispatchQueue.main.async {
                    if res.success {
                        self.testStatusLabel.stringValue = "✅ Deşifre Başarılı! (\(String(format: "%.2f", res.latency)) sn - \(res.provider))"
                        self.testStatusLabel.textColor = .systemGreen
                        self.testAudioResultLabel.stringValue = "\"\(res.text)\""
                        SoundManager.shared.playSuccess()
                    } else {
                        self.testStatusLabel.stringValue = "❌ Deşifre Hatası (\(res.provider))"
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

    @objc private func saveClicked() {
        let selectedProvider = providerPopUp.indexOfSelectedItem == 1 ? "gemini" : "groq"
        let groqKey = groqKeyField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let geminiKey = geminiKeyField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)

        let groqIdx = max(0, groqModelPopUp.indexOfSelectedItem)
        let groqModel = (groqIdx < ConfigManager.availableGroqModels.count)
            ? ConfigManager.availableGroqModels[groqIdx].id
            : "whisper-large-v3"

        let geminiIdx = max(0, geminiModelPopUp.indexOfSelectedItem)
        let geminiModel = (geminiIdx < ConfigManager.availableGeminiModels.count)
            ? ConfigManager.availableGeminiModels[geminiIdx].id
            : "gemini-3.5-transcribe-live"

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

        let playSounds = playSoundsCheckbox.state == .on
        let muteAudio = muteSystemAudioCheckbox.state == .on
        let launchLogin = launchAtLoginCheckbox.state == .on
        let showDock = showDockIconCheckbox.state == .on
        let triggerKey = selectedTriggerKeyCode

        LaunchAtLoginManager.shared.setEnabled(launchLogin)

        let success = ConfigManager.shared.update { cfg in
            cfg.provider = selectedProvider
            cfg.groq_api_key = groqKey
            cfg.gemini_api_key = geminiKey
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
            cfg.restore_clipboard = false
            cfg.mute_system_audio = muteAudio
            cfg.show_dock_icon = showDock
        }

        AppDelegate.updateDockVisibility(showDock)
        SoundManager.shared.isEnabled = playSounds
        KeyListener.shared.resetState()

        if success {
            statusMessageLabel.stringValue = "✅ Ayarlar kaydedildi ve uygulandı!"
            statusMessageLabel.textColor = .systemGreen
            SoundManager.shared.playSuccess()
            onConfigUpdated?()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                self?.window?.close()
            }
        } else {
            statusMessageLabel.stringValue = "❌ Kayıt başarısız oldu! config.json yazılamadı."
            statusMessageLabel.textColor = .systemRed
            SoundManager.shared.playCancel()
        }
    }
}
