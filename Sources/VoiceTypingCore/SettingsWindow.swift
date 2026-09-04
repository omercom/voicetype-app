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
    private var languageField: NSTextField!
    private var playSoundsCheckbox: NSButton!
    private var restoreClipboardCheckbox: NSButton!
    private var muteSystemAudioCheckbox: NSButton!
    private var launchAtLoginCheckbox: NSButton!
    private var showDockIconCheckbox: NSButton!

    // Tab 2: Yapay Zeka & Modeller
    private var providerSegmentedControl: NSSegmentedControl!
    private var providerPopUp: NSPopUpButton!
    private var groqKeyField: NSSecureTextField!
    private var groqModelPopUp: NSPopUpButton!
    private var groqStatusLabel: NSTextField!
    private var geminiKeyField: NSSecureTextField!
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
            contentRect: NSRect(x: 0, y: 0, width: 650, height: 495),
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
        tabView = NSTabView(frame: NSRect(x: 0, y: 0, width: 650, height: 435))
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
        let bottomSeparator = NSBox(frame: NSRect(x: 24, y: 440, width: 602, height: 1))
        bottomSeparator.boxType = .separator
        mainContainer.addSubview(bottomSeparator)

        statusMessageLabel = NSTextField(labelWithString: "")
        statusMessageLabel.frame = NSRect(x: 24, y: 454, width: 380, height: 22)
        statusMessageLabel.font = NSFont.systemFont(ofSize: 11)
        statusMessageLabel.textColor = .secondaryLabelColor
        mainContainer.addSubview(statusMessageLabel)

        let cancelBtn = NSButton(frame: NSRect(x: 420, y: 450, width: 95, height: 32))
        cancelBtn.title = "Kapat"
        cancelBtn.bezelStyle = .rounded
        cancelBtn.target = self
        cancelBtn.action = #selector(closeClicked)
        mainContainer.addSubview(cancelBtn)

        let saveBtn = NSButton(frame: NSRect(x: 525, y: 450, width: 100, height: 32))
        saveBtn.title = "Kaydet"
        saveBtn.bezelStyle = .rounded
        saveBtn.keyEquivalent = "\r"
        saveBtn.target = self
        saveBtn.action = #selector(saveClicked)
        mainContainer.addSubview(saveBtn)
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
    }

    // =========================================================================
    // TAB 1: Genel & Kısayol (Two-Column Layout)
    // =========================================================================
    private func buildTab1GeneralView() -> NSView {
        let container = FlippedContentView(frame: NSRect(x: 0, y: 0, width: 650, height: 435))

        // 1. Kısayol Tuşu
        let keyLabel = createSectionLabel(text: "Tetikleyici Tuş", y: 22)
        container.addSubview(keyLabel)

        triggerKeyPopUp = NSPopUpButton(frame: NSRect(x: 175, y: 20, width: 260, height: 26), pullsDown: false)
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

        recordKeyButton = NSButton(frame: NSRect(x: 445, y: 19, width: 170, height: 28))
        recordKeyButton.title = "Özel Tuş Yakala"
        recordKeyButton.bezelStyle = .rounded
        recordKeyButton.target = self
        recordKeyButton.action = #selector(recordKeyButtonClicked)
        container.addSubview(recordKeyButton)

        triggerKeyHintLabel = NSTextField(labelWithString: "Aktif Kısayol: Sağ Command (Right ⌘)")
        triggerKeyHintLabel.frame = NSRect(x: 175, y: 50, width: 440, height: 18)
        triggerKeyHintLabel.font = NSFont.systemFont(ofSize: 11)
        triggerKeyHintLabel.textColor = .secondaryLabelColor
        container.addSubview(triggerKeyHintLabel)

        let keyNote = createNoteLabel(text: "Bas-konuş için klavyede başparmağınızla kolayca basabileceğiniz Sağ Command önerilir.", y: 70)
        container.addSubview(keyNote)

        // Ayırıcı
        container.addSubview(createSeparator(y: 104))

        // 2. Tetikleme Modu
        let modeLabel = createSectionLabel(text: "Tetikleme Modu", y: 118)
        container.addSubview(modeLabel)

        modeSegmentedControl = NSSegmentedControl(
            labels: ["Basılı Tut (Push-to-Talk)", "Akıllı Hibrit", "Aç / Kapa"],
            trackingMode: .selectOne,
            target: self,
            action: #selector(modeSegmentedChanged(_:))
        )
        modeSegmentedControl.frame = NSRect(x: 175, y: 116, width: 440, height: 26)
        modeSegmentedControl.segmentStyle = .rounded
        modeSegmentedControl.segmentDistribution = .fillEqually
        modeSegmentedControl.selectedSegment = 0
        container.addSubview(modeSegmentedControl)

        // Gizli yedek popup (test ve geriye dönük uyumluluk için)
        modePopUp = NSPopUpButton(frame: NSRect(x: 175, y: 116, width: 440, height: 26), pullsDown: false)
        modePopUp.addItem(withTitle: "Basılı Tut (Push-to-Talk) - Tuşa basılı tut konuş, bırak yaz")
        modePopUp.addItem(withTitle: "Akıllı Hibrit (Smart) - Kısa tıkla aç-kapa, uzun bas tut-konuş")
        modePopUp.addItem(withTitle: "Aç / Kapa (Toggle) - Tuşa tıkla başlasın, tıkla dursun")
        modePopUp.isHidden = true
        container.addSubview(modePopUp)

        modeInfoLabel = createNoteLabel(text: "Basılı Tut: Tuşa basılı tutun ve konuşun, bıraktığınız anda metin otomatik yapıştırılır.", y: 148)
        container.addSubview(modeInfoLabel)

        // Ayırıcı
        container.addSubview(createSeparator(y: 182))

        // 3. Konuşma Dili
        let langLabel = createSectionLabel(text: "Konuşma Dili", y: 194)
        container.addSubview(langLabel)

        languageField = NSTextField(frame: NSRect(x: 175, y: 192, width: 60, height: 24))
        languageField.alignment = .center
        languageField.font = NSFont.systemFont(ofSize: 12)
        languageField.placeholderString = "tr"
        container.addSubview(languageField)

        let langHint = NSTextField(labelWithString: "('tr': Türkçe, 'en': İngilizce, 'auto': Otomatik Algıla)")
        langHint.frame = NSRect(x: 245, y: 195, width: 370, height: 20)
        langHint.font = NSFont.systemFont(ofSize: 11)
        langHint.textColor = .secondaryLabelColor
        container.addSubview(langHint)

        // Ayırıcı
        container.addSubview(createSeparator(y: 228))

        // 4. Tercihler (TG Pro tarzı sol başlık + sağ onay kutuları)
        let optsLabel = createSectionLabel(text: "Seçenekler", y: 238)
        container.addSubview(optsLabel)

        muteSystemAudioCheckbox = NSButton(checkboxWithTitle: "Konuşurken arka plan medyasını/müziği sustur", target: nil, action: nil)
        muteSystemAudioCheckbox.frame = NSRect(x: 175, y: 236, width: 440, height: 18)
        container.addSubview(muteSystemAudioCheckbox)
        container.addSubview(createSubCheckboxNote(text: "YouTube, müzik veya video seslerinin mikrofona karışmasını önler.", y: 254))

        playSoundsCheckbox = NSButton(checkboxWithTitle: "Sistem ses efektlerini çal", target: nil, action: nil)
        playSoundsCheckbox.frame = NSRect(x: 175, y: 272, width: 440, height: 18)
        container.addSubview(playSoundsCheckbox)
        container.addSubview(createSubCheckboxNote(text: "Kayıt başlangıç, bitiş ve deşifre bildirim tonları.", y: 290))

        restoreClipboardCheckbox = NSButton(checkboxWithTitle: "Metin yapıştırıldıktan sonra panoyu geri yükle", target: nil, action: nil)
        restoreClipboardCheckbox.frame = NSRect(x: 175, y: 308, width: 440, height: 18)
        container.addSubview(restoreClipboardCheckbox)
        container.addSubview(createSubCheckboxNote(text: "Önceden kopyalanmış pano içeriğini kaybetmeden korur.", y: 326))

        launchAtLoginCheckbox = NSButton(checkboxWithTitle: "Mac açıldığında otomatik başlat", target: nil, action: nil)
        launchAtLoginCheckbox.frame = NSRect(x: 175, y: 344, width: 440, height: 18)
        container.addSubview(launchAtLoginCheckbox)
        container.addSubview(createSubCheckboxNote(text: "Menü çubuğunda arka planda sessizce hazır bekler.", y: 362))

        showDockIconCheckbox = NSButton(checkboxWithTitle: "Dock simgesini göster (Alt görev çubuğu)", target: nil, action: nil)
        showDockIconCheckbox.frame = NSRect(x: 175, y: 380, width: 440, height: 18)
        container.addSubview(showDockIconCheckbox)
        container.addSubview(createSubCheckboxNote(text: "Voice Typing'i ekranın altındaki Dock çubuğunda ve Cmd+Tab menüsünde gösterir.", y: 398))

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
        let container = FlippedContentView(frame: NSRect(x: 0, y: 0, width: 650, height: 435))

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

        geminiKeyField = NSSecureTextField(frame: NSRect(x: 175, y: 84, width: 295, height: 24))
        geminiKeyField.placeholderString = "AIzaSy..."
        container.addSubview(geminiKeyField)

        let getGeminiKeyBtn = NSButton(frame: NSRect(x: 480, y: 82, width: 135, height: 28))
        getGeminiKeyBtn.title = "API Anahtarı Al"
        getGeminiKeyBtn.bezelStyle = .rounded
        getGeminiKeyBtn.target = self
        getGeminiKeyBtn.action = #selector(openGeminiConsoleClicked)
        container.addSubview(getGeminiKeyBtn)

        geminiModelPopUp = NSPopUpButton(frame: NSRect(x: 175, y: 116, width: 440, height: 26), pullsDown: false)
        for m in ConfigManager.availableGeminiModels {
            geminiModelPopUp.addItem(withTitle: "\(m.name) [\(m.price)] - \(m.speed)")
        }
        container.addSubview(geminiModelPopUp)

        let testGeminiBtn = NSButton(frame: NSRect(x: 175, y: 150, width: 135, height: 28))
        testGeminiBtn.title = "Bağlantıyı Test Et"
        testGeminiBtn.bezelStyle = .rounded
        testGeminiBtn.target = self
        testGeminiBtn.action = #selector(testGeminiConnectionClicked)
        container.addSubview(testGeminiBtn)

        geminiStatusLabel = NSTextField(wrappingLabelWithString: "")
        geminiStatusLabel.frame = NSRect(x: 320, y: 152, width: 295, height: 38)
        geminiStatusLabel.font = NSFont.systemFont(ofSize: 11)
        geminiStatusLabel.textColor = .secondaryLabelColor
        geminiStatusLabel.maximumNumberOfLines = 2
        container.addSubview(geminiStatusLabel)

        let geminiNote = createNoteLabel(text: "WebSocket canlı akışı sayesinde konuşurken kelimeler doğrudan canlı işlenir.", y: 194)
        container.addSubview(geminiNote)

        container.addSubview(createSeparator(y: 220))

        // 3. Groq Whisper
        let groqSection = createSectionLabel(text: "Groq Whisper", y: 234)
        container.addSubview(groqSection)

        groqKeyField = NSSecureTextField(frame: NSRect(x: 175, y: 232, width: 295, height: 24))
        groqKeyField.placeholderString = "gsk_..."
        container.addSubview(groqKeyField)

        let getGroqKeyBtn = NSButton(frame: NSRect(x: 480, y: 230, width: 135, height: 28))
        getGroqKeyBtn.title = "API Anahtarı Al"
        getGroqKeyBtn.bezelStyle = .rounded
        getGroqKeyBtn.target = self
        getGroqKeyBtn.action = #selector(openGroqConsoleClicked)
        container.addSubview(getGroqKeyBtn)

        groqModelPopUp = NSPopUpButton(frame: NSRect(x: 175, y: 264, width: 440, height: 26), pullsDown: false)
        for m in ConfigManager.availableGroqModels {
            groqModelPopUp.addItem(withTitle: "\(m.name) [\(m.price)] - \(m.speed)")
        }
        container.addSubview(groqModelPopUp)

        let testGroqBtn = NSButton(frame: NSRect(x: 175, y: 298, width: 135, height: 28))
        testGroqBtn.title = "Bağlantıyı Test Et"
        testGroqBtn.bezelStyle = .rounded
        testGroqBtn.target = self
        testGroqBtn.action = #selector(testGroqConnectionClicked)
        container.addSubview(testGroqBtn)

        groqStatusLabel = NSTextField(wrappingLabelWithString: "")
        groqStatusLabel.frame = NSRect(x: 320, y: 300, width: 295, height: 38)
        groqStatusLabel.font = NSFont.systemFont(ofSize: 11)
        groqStatusLabel.textColor = .secondaryLabelColor
        groqStatusLabel.maximumNumberOfLines = 2
        container.addSubview(groqStatusLabel)

        let groqNote = createNoteLabel(text: "Whisper Large modelini Groq LPU bulut donanımında ~0.3 saniyede tamamlar.", y: 342)
        container.addSubview(groqNote)

        return container
    }

    @objc private func providerSegmentedChanged(_ sender: NSSegmentedControl) {
        // sender index 0 -> Gemini, index 1 -> Groq
        // providerPopUp index 0 -> Groq, index 1 -> Gemini
        let popUpIndex = (sender.selectedSegment == 0) ? 1 : 0
        providerPopUp.selectItem(at: popUpIndex)
    }

    // =========================================================================
    // TAB 3: Sistem & İzinler (Interactive Permission Cards & Hardware Test)
    // =========================================================================
    private func buildTab3PermissionsView() -> NSView {
        let container = FlippedContentView(frame: NSRect(x: 0, y: 0, width: 650, height: 435))

        // Başlık
        let headerLabel = NSTextField(labelWithString: "Gerekli macOS İzinleri")
        headerLabel.frame = NSRect(x: 32, y: 12, width: 300, height: 20)
        headerLabel.font = NSFont.systemFont(ofSize: 13, weight: .bold)
        container.addSubview(headerLabel)

        let subLabel = NSTextField(labelWithString: "Voice Typing'in çalışması için gereken iki temel sistem izni aşağıdadır:")
        subLabel.frame = NSRect(x: 32, y: 32, width: 586, height: 16)
        subLabel.font = NSFont.systemFont(ofSize: 11)
        subLabel.textColor = .secondaryLabelColor
        container.addSubview(subLabel)

        // 1. KART: MİKROFON İZNİ
        let micBox = NSBox(frame: NSRect(x: 32, y: 52, width: 586, height: 60))
        micBox.boxType = .custom
        micBox.cornerRadius = 8
        micBox.borderWidth = 1
        micBox.borderColor = NSColor.separatorColor.withAlphaComponent(0.25)
        micBox.fillColor = NSColor.windowBackgroundColor.withAlphaComponent(0.4)
        micBox.titlePosition = .noTitle
        let micContent = FlippedContentView(frame: micBox.bounds)

        let micIcon = NSImageView(frame: NSRect(x: 14, y: 16, width: 28, height: 28))
        if #available(macOS 11.0, *), let img = NSImage(systemSymbolName: "mic.fill", accessibilityDescription: nil) {
            micIcon.image = img
            micIcon.contentTintColor = .systemBlue
        }
        micContent.addSubview(micIcon)

        let micTitle = NSTextField(labelWithString: "Mikrofon Erişimi")
        micTitle.frame = NSRect(x: 52, y: 11, width: 220, height: 18)
        micTitle.font = NSFont.systemFont(ofSize: 12.5, weight: .semibold)
        micContent.addSubview(micTitle)

        let micDesc = NSTextField(labelWithString: "Sesinizi kaydedip yapay zeka modeline aktarmak için zorunludur.")
        micDesc.frame = NSRect(x: 52, y: 31, width: 310, height: 16)
        micDesc.font = NSFont.systemFont(ofSize: 10.5)
        micDesc.textColor = .secondaryLabelColor
        micContent.addSubview(micDesc)

        micStatusLabel = NSTextField(labelWithString: "🟢 Yetki Verildi")
        micStatusLabel.frame = NSRect(x: 370, y: 19, width: 120, height: 20)
        micStatusLabel.font = NSFont.systemFont(ofSize: 11.5, weight: .medium)
        micStatusLabel.textColor = .systemGreen
        micContent.addSubview(micStatusLabel)

        micActionButton = NSButton(frame: NSRect(x: 495, y: 15, width: 80, height: 28))
        micActionButton.title = "Ayarlar"
        micActionButton.bezelStyle = .rounded
        micActionButton.target = self
        micActionButton.action = #selector(openMicSettingsClicked)
        micContent.addSubview(micActionButton)

        micBox.contentView = micContent
        container.addSubview(micBox)

        // 2. KART: ERİŞİLEBİLİRLİK İZNİ
        let accBox = NSBox(frame: NSRect(x: 32, y: 118, width: 586, height: 60))
        accBox.boxType = .custom
        accBox.cornerRadius = 8
        accBox.borderWidth = 1
        accBox.borderColor = NSColor.separatorColor.withAlphaComponent(0.25)
        accBox.fillColor = NSColor.windowBackgroundColor.withAlphaComponent(0.4)
        accBox.titlePosition = .noTitle
        let accContent = FlippedContentView(frame: accBox.bounds)

        let accIcon = NSImageView(frame: NSRect(x: 14, y: 16, width: 28, height: 28))
        if #available(macOS 11.0, *), let img = NSImage(systemSymbolName: "hand.raised.fill", accessibilityDescription: nil) {
            accIcon.image = img
            accIcon.contentTintColor = .systemPurple
        }
        accContent.addSubview(accIcon)

        let accTitle = NSTextField(labelWithString: "Erişilebilirlik İzni")
        accTitle.frame = NSRect(x: 52, y: 11, width: 220, height: 18)
        accTitle.font = NSFont.systemFont(ofSize: 12.5, weight: .semibold)
        accContent.addSubview(accTitle)

        let accDesc = NSTextField(labelWithString: "Klavye kısayolunu dinlemek ve metni imlece yazmak için zorunludur.")
        accDesc.frame = NSRect(x: 52, y: 31, width: 310, height: 16)
        accDesc.font = NSFont.systemFont(ofSize: 10.5)
        accDesc.textColor = .secondaryLabelColor
        accContent.addSubview(accDesc)

        accStatusLabel = NSTextField(labelWithString: "🟢 Yetki Verildi")
        accStatusLabel.frame = NSRect(x: 370, y: 19, width: 120, height: 20)
        accStatusLabel.font = NSFont.systemFont(ofSize: 11.5, weight: .medium)
        accStatusLabel.textColor = .systemGreen
        accContent.addSubview(accStatusLabel)

        accActionButton = NSButton(frame: NSRect(x: 495, y: 15, width: 80, height: 28))
        accActionButton.title = "Ayarlar"
        accActionButton.bezelStyle = .rounded
        accActionButton.target = self
        accActionButton.action = #selector(openAccSettingsClicked)
        accContent.addSubview(accActionButton)

        accBox.contentView = accContent
        container.addSubview(accBox)

        // Canlı Rehber ve Spinner (Erişilebilirlik bekleme durumunda)
        accProgressIndicator = NSProgressIndicator(frame: NSRect(x: 34, y: 184, width: 16, height: 16))
        accProgressIndicator.style = .spinning
        accProgressIndicator.controlSize = .small
        accProgressIndicator.isDisplayedWhenStopped = false
        container.addSubview(accProgressIndicator)

        accGuideLabel = NSTextField(labelWithString: "İzinler Sistem Ayarları'ndan otomatik olarak anlık algılanmaktadır.")
        accGuideLabel.frame = NSRect(x: 56, y: 183, width: 562, height: 18)
        accGuideLabel.font = NSFont.systemFont(ofSize: 11)
        accGuideLabel.textColor = .secondaryLabelColor
        container.addSubview(accGuideLabel)

        container.addSubview(createSeparator(y: 207))

        // 3. BÖLÜM: MİKROFON DONANIM & SES TESTİ
        let testHeader = NSTextField(labelWithString: "Mikrofon Donanım ve Deşifre Testi")
        testHeader.frame = NSRect(x: 32, y: 217, width: 300, height: 20)
        testHeader.font = NSFont.systemFont(ofSize: 13, weight: .bold)
        container.addSubview(testHeader)

        let testSub = NSTextField(labelWithString: "Mikrofonunuzun ses yakaladığından ve modelin metin ürettiğinden emin olun:")
        testSub.frame = NSRect(x: 32, y: 237, width: 586, height: 16)
        testSub.font = NSFont.systemFont(ofSize: 11)
        testSub.textColor = .secondaryLabelColor
        container.addSubview(testSub)

        testRecordButton = NSButton(frame: NSRect(x: 32, y: 257, width: 210, height: 28))
        testRecordButton.title = "2 Saniyelik Test Kaydı Yap"
        testRecordButton.bezelStyle = .rounded
        testRecordButton.target = self
        testRecordButton.action = #selector(testRecordClicked)
        container.addSubview(testRecordButton)

        testStatusLabel = NSTextField(labelWithString: "Durum: Hazır (Butona basıp konuşun)")
        testStatusLabel.frame = NSRect(x: 252, y: 261, width: 366, height: 20)
        testStatusLabel.font = NSFont.systemFont(ofSize: 11.5, weight: .medium)
        testStatusLabel.textColor = .secondaryLabelColor
        container.addSubview(testStatusLabel)

        let resultContainer = NSBox(frame: NSRect(x: 32, y: 292, width: 586, height: 125))
        resultContainer.boxType = .custom
        resultContainer.isTransparent = false
        resultContainer.borderWidth = 1
        resultContainer.cornerRadius = 8
        resultContainer.borderColor = NSColor.separatorColor.withAlphaComponent(0.20)
        resultContainer.fillColor = NSColor.windowBackgroundColor.withAlphaComponent(0.5)
        resultContainer.titlePosition = .noTitle

        let resultFlipped = FlippedContentView(frame: resultContainer.bounds)
        testAudioResultLabel = NSTextField(wrappingLabelWithString: "")
        testAudioResultLabel.frame = NSRect(x: 14, y: 10, width: 558, height: 105)
        testAudioResultLabel.font = NSFont.systemFont(ofSize: 11.5)
        testAudioResultLabel.textColor = .labelColor
        testAudioResultLabel.maximumNumberOfLines = 5
        resultFlipped.addSubview(testAudioResultLabel)

        resultContainer.contentView = resultFlipped
        container.addSubview(resultContainer)

        return container
    }

    // =========================================================================
    // TAB 4: Hakkında (Centered Apple Showcase)
    // =========================================================================
    private func buildTab4AboutView() -> NSView {
        let container = FlippedContentView(frame: NSRect(x: 0, y: 0, width: 650, height: 435))

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
            "• 280ms Akustik Uzatma Penceresi (Son kelimelerin kesilmesini önler)",
            "• Konuşurken arka plan sesini/müziği akıllıca duraklatma",
            "• Kararlı metin algılama (Settled Silence Debounce)",
            "• Sıfır telemetri ve güvenli yerel pano entegrasyonu"
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

        // 5. Ortalanmış Alt Bilgi
        let footerLabel = NSTextField(labelWithString: "Antigravity AI • macOS için Optimize Edildi")
        footerLabel.frame = NSRect(x: 45, y: 396, width: 560, height: 18)
        footerLabel.font = NSFont.systemFont(ofSize: 10.5)
        footerLabel.textColor = .tertiaryLabelColor
        footerLabel.alignment = .center
        container.addSubview(footerLabel)

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
            micActionButton?.title = "Ayarlar"
        case .denied:
            micStatusLabel.textColor = .systemRed
            micActionButton?.title = "Ayarları Aç"
        case .notDetermined:
            micStatusLabel.textColor = .systemOrange
            micActionButton?.title = "İzin Ver"
        default:
            micStatusLabel.textColor = .systemOrange
            micActionButton?.title = "İzin Ver"
        }

        let acc = PermissionManager.shared.getAccessibilityStatus()
        accStatusLabel.stringValue = "\(acc.badge) \(acc.description)"
        switch acc.status {
        case .authorized:
            accStatusLabel.textColor = .systemGreen
            accActionButton?.title = "Ayarlar"
            accProgressIndicator?.stopAnimation(nil)
            if !lastKnownAccStatus && permissionPollTimer != nil {
                accGuideLabel?.stringValue = "✅ Yetki verildi! Voice Typing kullanıma hazır."
                accGuideLabel?.textColor = .systemGreen
                SoundManager.shared.playSuccess()
            }
            lastKnownAccStatus = true
        case .denied:
            accStatusLabel.textColor = .systemRed
            accActionButton?.title = "Ayarları Aç"
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

        // Checkboxes
        playSoundsCheckbox.state = cfg.play_sounds ? .on : .off
        restoreClipboardCheckbox.state = cfg.restore_clipboard ? .on : .off
        muteSystemAudioCheckbox.state = cfg.mute_system_audio ? .on : .off
        launchAtLoginCheckbox.state = LaunchAtLoginManager.shared.isEnabled ? .on : .off
        showDockIconCheckbox.state = cfg.show_dock_icon ? .on : .off

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

        let playSounds = playSoundsCheckbox.state == .on
        let restoreClip = restoreClipboardCheckbox.state == .on
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
            cfg.play_sounds = playSounds
            cfg.restore_clipboard = restoreClip
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
