import Foundation
import AppKit

private class FlippedContentView: NSView {
    override var isFlipped: Bool { return true }
}

public class SettingsWindowController: NSWindowController, NSWindowDelegate {
    public static let shared = SettingsWindowController()

    // Header & Tab Navigation
    private var segmentedControl: NSSegmentedControl!
    private var tabView: NSTabView!

    // Tab 1: İzinler & Kurulum
    private var micStatusLabel: NSTextField!
    private var accStatusLabel: NSTextField!
    private var testStatusLabel: NSTextField!
    private var testAudioResultLabel: NSTextField!
    private var testRecordButton: NSButton!

    // Tab 2: Yapay Zeka & Modeller
    private var providerPopUp: NSPopUpButton!
    private var groqKeyField: NSSecureTextField!
    private var groqModelPopUp: NSPopUpButton!
    private var groqStatusLabel: NSTextField!
    private var geminiKeyField: NSSecureTextField!
    private var geminiModelPopUp: NSPopUpButton!
    private var geminiStatusLabel: NSTextField!

    // Tab 3: Kısayol & Davranış
    private var triggerKeyPopUp: NSPopUpButton!
    private var recordKeyButton: NSButton!
    private var triggerKeyHintLabel: NSTextField!
    private var modePopUp: NSPopUpButton!
    private var languageField: NSTextField!
    private var playSoundsCheckbox: NSButton!
    private var restoreClipboardCheckbox: NSButton!
    private var muteSystemAudioCheckbox: NSButton!

    // Footer
    private var statusMessageLabel: NSTextField!

    // Custom Key Capture State
    private var selectedTriggerKeyCode: Int = 54
    private var isCapturingKey: Bool = false
    private var keyCaptureMonitor: Any?

    public var onConfigUpdated: (() -> Void)?

    private init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 625),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "⚙️ Voice Typing - Ayarlar ve Tercihler"
        window.center()
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self

        setupUI()
        loadValues()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    public func windowWillClose(_ notification: Notification) {
        if isCapturingKey {
            stopCapturingKey(cancelled: true)
        }
        if AudioRecorder.shared.isRecording {
            _ = AudioRecorder.shared.stop()
        }
    }

    public func selectTab(index: Int) {
        guard index >= 0 && index < segmentedControl.segmentCount else { return }
        segmentedControl.selectedSegment = index
        tabView.selectTabViewItem(at: index)
    }

    public override func showWindow(_ sender: Any?) {
        refreshPermissionStatuses()
        loadValues()
        super.showWindow(sender)
        window?.makeKeyAndOrderFront(sender)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func setupUI() {
        guard let window = window, let contentView = window.contentView else { return }

        let mainContainer = FlippedContentView(frame: contentView.bounds)
        mainContainer.autoresizingMask = [.width, .height]
        contentView.addSubview(mainContainer)

        // =====================================================================
        // ÜST BÖLÜM: MODERN SEGMENTED TAB SWITCHER (APPLE HIG ROUNDED STYLE)
        // =====================================================================
        segmentedControl = NSSegmentedControl(
            labels: ["🛡️ İzinler & Kurulum", "🤖 Yapay Zeka & Modeller", "⌨️ Kısayol & Davranış"],
            trackingMode: .selectOne,
            target: self,
            action: #selector(tabSegmentChanged(_:))
        )
        segmentedControl.frame = NSRect(x: 35, y: 14, width: 550, height: 28)
        segmentedControl.selectedSegment = 0
        segmentedControl.segmentStyle = .rounded
        segmentedControl.segmentDistribution = .fillEqually
        mainContainer.addSubview(segmentedControl)

        let topSeparator = NSBox(frame: NSRect(x: 20, y: 52, width: 580, height: 1))
        topSeparator.boxType = .separator
        mainContainer.addSubview(topSeparator)

        // =====================================================================
        // ORTA BÖLÜM: TAB VIEW (NO TABS NO BORDER)
        // =====================================================================
        tabView = NSTabView(frame: NSRect(x: 15, y: 58, width: 590, height: 506))
        tabView.tabViewType = .noTabsNoBorder

        let tab1Item = NSTabViewItem(identifier: "tab1")
        tab1Item.view = buildTab1PermissionsView()
        tabView.addTabViewItem(tab1Item)

        let tab2Item = NSTabViewItem(identifier: "tab2")
        tab2Item.view = buildTab2AIProvidersView()
        tabView.addTabViewItem(tab2Item)

        let tab3Item = NSTabViewItem(identifier: "tab3")
        tab3Item.view = buildTab3ShortcutsView()
        tabView.addTabViewItem(tab3Item)

        mainContainer.addSubview(tabView)

        // =====================================================================
        // ALT BÖLÜM: FOOTER & ACTIONS
        // =====================================================================
        let bottomSeparator = NSBox(frame: NSRect(x: 20, y: 563, width: 580, height: 1))
        bottomSeparator.boxType = .separator
        mainContainer.addSubview(bottomSeparator)

        statusMessageLabel = NSTextField(labelWithString: "")
        statusMessageLabel.frame = NSRect(x: 20, y: 574, width: 370, height: 24)
        statusMessageLabel.font = NSFont.systemFont(ofSize: 11)
        statusMessageLabel.textColor = .secondaryLabelColor
        mainContainer.addSubview(statusMessageLabel)

        let cancelBtn = NSButton(frame: NSRect(x: 395, y: 572, width: 95, height: 32))
        cancelBtn.title = "Kapat"
        cancelBtn.bezelStyle = .rounded
        cancelBtn.target = self
        cancelBtn.action = #selector(closeClicked)
        mainContainer.addSubview(cancelBtn)

        let saveBtn = NSButton(frame: NSRect(x: 500, y: 572, width: 105, height: 32))
        saveBtn.title = "💾 Kaydet"
        saveBtn.bezelStyle = .rounded
        saveBtn.keyEquivalent = "\r"
        saveBtn.target = self
        saveBtn.action = #selector(saveClicked)
        mainContainer.addSubview(saveBtn)
    }

    @objc private func tabSegmentChanged(_ sender: NSSegmentedControl) {
        tabView.selectTabViewItem(at: sender.selectedSegment)
    }

    // =========================================================================
    // TAB 1: 🛡️ İzinler & Kurulum
    // =========================================================================
    private func buildTab1PermissionsView() -> NSView {
        let container = FlippedContentView(frame: NSRect(x: 0, y: 0, width: 590, height: 500))

        // Kart 1: macOS İzinleri
        let permBox = createCardBox(frame: NSRect(x: 10, y: 6, width: 570, height: 215), title: "🛡️ macOS Sistem İzinleri (Zorunlu)")
        let permContent = permBox.contentView as! FlippedContentView

        // Mikrofon
        let micLabel = NSTextField(labelWithString: "🎙️ Mikrofon İzni:")
        micLabel.frame = NSRect(x: 16, y: 40, width: 130, height: 20)
        micLabel.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        permContent.addSubview(micLabel)

        micStatusLabel = NSTextField(labelWithString: "🟢 Yetki Verildi")
        micStatusLabel.frame = NSRect(x: 150, y: 40, width: 220, height: 20)
        micStatusLabel.font = NSFont.systemFont(ofSize: 11)
        permContent.addSubview(micStatusLabel)

        let micBtn = NSButton(frame: NSRect(x: 380, y: 36, width: 175, height: 28))
        micBtn.title = "Sistem Ayarlarını Aç"
        micBtn.bezelStyle = .rounded
        micBtn.target = self
        micBtn.action = #selector(openMicSettingsClicked)
        permContent.addSubview(micBtn)

        // Erişilebilirlik
        let accLabel = NSTextField(labelWithString: "⌨️ Erişilebilirlik:")
        accLabel.frame = NSRect(x: 16, y: 78, width: 130, height: 20)
        accLabel.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        permContent.addSubview(accLabel)

        accStatusLabel = NSTextField(labelWithString: "🟢 Yetki Verildi")
        accStatusLabel.frame = NSRect(x: 150, y: 78, width: 220, height: 20)
        accStatusLabel.font = NSFont.systemFont(ofSize: 11)
        permContent.addSubview(accStatusLabel)

        let accBtn = NSButton(frame: NSRect(x: 380, y: 74, width: 175, height: 28))
        accBtn.title = "Sistem Ayarlarını Aç"
        accBtn.bezelStyle = .rounded
        accBtn.target = self
        accBtn.action = #selector(openAccSettingsClicked)
        permContent.addSubview(accBtn)

        // Açıklama
        let permInfo = NSTextField(labelWithString: "Mikrofon sesi kaydetmek, Erişilebilirlik ise kısayol tuşlarını dinlemek ve metni aktif pencereye yapıştırmak için zorunludur.")
        permInfo.frame = NSRect(x: 16, y: 116, width: 538, height: 34)
        permInfo.font = NSFont.systemFont(ofSize: 11)
        permInfo.textColor = .secondaryLabelColor
        permContent.addSubview(permInfo)

        // Yenile butonu
        let refreshBtn = NSButton(frame: NSRect(x: 380, y: 164, width: 175, height: 30))
        refreshBtn.title = "🔄 İzin Durumunu Yenile"
        refreshBtn.bezelStyle = .rounded
        refreshBtn.target = self
        refreshBtn.action = #selector(refreshPermissionStatuses)
        permContent.addSubview(refreshBtn)

        container.addSubview(permBox)

        // Kart 2: Ses Donanım & Mikrofon Testi
        let testBox = createCardBox(frame: NSRect(x: 10, y: 232, width: 570, height: 260), title: "🧪 Ses Donanım & Mikrofon Testi")
        let testContent = testBox.contentView as! FlippedContentView

        let testInfo = NSTextField(labelWithString: "Mikrofonunuzun ses yakaladığını ve seçili deşifre motorunun çalıştığını test edin:")
        testInfo.frame = NSRect(x: 16, y: 38, width: 538, height: 20)
        testInfo.font = NSFont.systemFont(ofSize: 11)
        testInfo.textColor = .secondaryLabelColor
        testContent.addSubview(testInfo)

        testRecordButton = NSButton(frame: NSRect(x: 16, y: 66, width: 230, height: 32))
        testRecordButton.title = "🎙️ 2 Sn Test Kaydı Yap"
        testRecordButton.bezelStyle = .rounded
        testRecordButton.target = self
        testRecordButton.action = #selector(testRecordClicked)
        testContent.addSubview(testRecordButton)

        // Test Geri Bildirim Kutusu
        let resultContainer = NSBox(frame: NSRect(x: 16, y: 108, width: 538, height: 136))
        resultContainer.boxType = .custom
        resultContainer.isTransparent = false
        resultContainer.borderWidth = 1
        resultContainer.cornerRadius = 8
        resultContainer.borderColor = NSColor.separatorColor.withAlphaComponent(0.2)
        resultContainer.fillColor = NSColor.windowBackgroundColor.withAlphaComponent(0.6)
        resultContainer.titlePosition = .noTitle

        let resultFlipped = FlippedContentView(frame: resultContainer.bounds)
        testStatusLabel = NSTextField(labelWithString: "Durum: Hazır (Mikrofonu test etmek için butona basın)")
        testStatusLabel.frame = NSRect(x: 12, y: 10, width: 514, height: 20)
        testStatusLabel.font = NSFont.systemFont(ofSize: 12, weight: .semibold)
        testStatusLabel.textColor = .secondaryLabelColor
        resultFlipped.addSubview(testStatusLabel)

        testAudioResultLabel = NSTextField(labelWithString: "")
        testAudioResultLabel.frame = NSRect(x: 12, y: 36, width: 514, height: 88)
        testAudioResultLabel.font = NSFont.systemFont(ofSize: 11)
        testAudioResultLabel.textColor = .labelColor
        testAudioResultLabel.maximumNumberOfLines = 4
        resultFlipped.addSubview(testAudioResultLabel)

        resultContainer.contentView = resultFlipped
        testContent.addSubview(resultContainer)

        container.addSubview(testBox)
        return container
    }

    // =========================================================================
    // TAB 2: 🤖 Yapay Zeka & Modeller
    // =========================================================================
    private func buildTab2AIProvidersView() -> NSView {
        let container = FlippedContentView(frame: NSRect(x: 0, y: 0, width: 590, height: 500))

        // Kart 1: Aktif Sağlayıcı
        let provBox = createCardBox(frame: NSRect(x: 10, y: 6, width: 570, height: 64), title: "⚡ Varsayılan Deşifre Motoru")
        let provContent = provBox.contentView as! FlippedContentView

        let provLabel = NSTextField(labelWithString: "Aktif Sağlayıcı:")
        provLabel.frame = NSRect(x: 16, y: 34, width: 130, height: 20)
        provLabel.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        provContent.addSubview(provLabel)

        providerPopUp = NSPopUpButton(frame: NSRect(x: 150, y: 32, width: 405, height: 26), pullsDown: false)
        providerPopUp.addItem(withTitle: "Groq Whisper (whisper-large-v3 - Yüksek Kalite)")
        providerPopUp.addItem(withTitle: "Google Gemini (Doğal Dil & Bağlamsal)")
        provContent.addSubview(providerPopUp)
        container.addSubview(provBox)

        // Kart 2: Groq Whisper
        let groqBox = createCardBox(frame: NSRect(x: 10, y: 78, width: 570, height: 202), title: "⚡ Groq Whisper Yapılandırması")
        let groqContent = groqBox.contentView as! FlippedContentView

        let groqKeyLabel = NSTextField(labelWithString: "Groq API Key:")
        groqKeyLabel.frame = NSRect(x: 16, y: 36, width: 130, height: 20)
        groqKeyLabel.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        groqContent.addSubview(groqKeyLabel)

        groqKeyField = NSSecureTextField(frame: NSRect(x: 150, y: 36, width: 405, height: 22))
        groqKeyField.placeholderString = "gsk_..."
        groqContent.addSubview(groqKeyField)

        let groqModelLabel = NSTextField(labelWithString: "Groq Modeli:")
        groqModelLabel.frame = NSRect(x: 16, y: 70, width: 130, height: 20)
        groqModelLabel.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        groqContent.addSubview(groqModelLabel)

        groqModelPopUp = NSPopUpButton(frame: NSRect(x: 150, y: 68, width: 405, height: 26), pullsDown: false)
        for m in ConfigManager.availableGroqModels {
            groqModelPopUp.addItem(withTitle: "\(m.name) [\(m.price)] - \(m.speed)")
        }
        groqContent.addSubview(groqModelPopUp)

        let testGroqBtn = NSButton(frame: NSRect(x: 150, y: 106, width: 210, height: 28))
        testGroqBtn.title = "🔗 Groq Bağlantısını Test Et"
        testGroqBtn.bezelStyle = .rounded
        testGroqBtn.target = self
        testGroqBtn.action = #selector(testGroqConnectionClicked)
        groqContent.addSubview(testGroqBtn)

        let getGroqKeyBtn = NSButton(frame: NSRect(x: 370, y: 106, width: 185, height: 28))
        getGroqKeyBtn.title = "🌐 API Anahtarı Al"
        getGroqKeyBtn.bezelStyle = .rounded
        getGroqKeyBtn.target = self
        getGroqKeyBtn.action = #selector(openGroqConsoleClicked)
        groqContent.addSubview(getGroqKeyBtn)

        groqStatusLabel = NSTextField(labelWithString: "")
        groqStatusLabel.frame = NSRect(x: 150, y: 144, width: 405, height: 44)
        groqStatusLabel.font = NSFont.systemFont(ofSize: 11)
        groqStatusLabel.textColor = .secondaryLabelColor
        groqStatusLabel.maximumNumberOfLines = 2
        groqContent.addSubview(groqStatusLabel)

        container.addSubview(groqBox)

        // Kart 3: Google Gemini
        let geminiBox = createCardBox(frame: NSRect(x: 10, y: 288, width: 570, height: 204), title: "🧠 Google Gemini Yapılandırması")
        let geminiContent = geminiBox.contentView as! FlippedContentView

        let geminiKeyLabel = NSTextField(labelWithString: "Gemini API Key:")
        geminiKeyLabel.frame = NSRect(x: 16, y: 36, width: 130, height: 20)
        geminiKeyLabel.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        geminiContent.addSubview(geminiKeyLabel)

        geminiKeyField = NSSecureTextField(frame: NSRect(x: 150, y: 36, width: 405, height: 22))
        geminiKeyField.placeholderString = "AIzaSy..."
        geminiContent.addSubview(geminiKeyField)

        let geminiModelLabel = NSTextField(labelWithString: "Gemini Modeli:")
        geminiModelLabel.frame = NSRect(x: 16, y: 70, width: 130, height: 20)
        geminiModelLabel.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        geminiContent.addSubview(geminiModelLabel)

        geminiModelPopUp = NSPopUpButton(frame: NSRect(x: 150, y: 68, width: 405, height: 26), pullsDown: false)
        for m in ConfigManager.availableGeminiModels {
            geminiModelPopUp.addItem(withTitle: "\(m.name) [\(m.price)] - \(m.speed)")
        }
        geminiContent.addSubview(geminiModelPopUp)

        let testGeminiBtn = NSButton(frame: NSRect(x: 150, y: 106, width: 210, height: 28))
        testGeminiBtn.title = "🔗 Gemini Bağlantısını Test Et"
        testGeminiBtn.bezelStyle = .rounded
        testGeminiBtn.target = self
        testGeminiBtn.action = #selector(testGeminiConnectionClicked)
        geminiContent.addSubview(testGeminiBtn)

        let getGeminiKeyBtn = NSButton(frame: NSRect(x: 370, y: 106, width: 185, height: 28))
        getGeminiKeyBtn.title = "🌐 API Anahtarı Al"
        getGeminiKeyBtn.bezelStyle = .rounded
        getGeminiKeyBtn.target = self
        getGeminiKeyBtn.action = #selector(openGeminiConsoleClicked)
        geminiContent.addSubview(getGeminiKeyBtn)

        geminiStatusLabel = NSTextField(labelWithString: "")
        geminiStatusLabel.frame = NSRect(x: 150, y: 144, width: 405, height: 44)
        geminiStatusLabel.font = NSFont.systemFont(ofSize: 11)
        geminiStatusLabel.textColor = .secondaryLabelColor
        geminiStatusLabel.maximumNumberOfLines = 2
        geminiContent.addSubview(geminiStatusLabel)

        container.addSubview(geminiBox)
        return container
    }

    // =========================================================================
    // TAB 3: ⌨️ Kısayol & Davranış
    // =========================================================================
    private func buildTab3ShortcutsView() -> NSView {
        let container = FlippedContentView(frame: NSRect(x: 0, y: 0, width: 590, height: 500))

        // Kart 1: Tetikleme Tuşu
        let triggerBox = createCardBox(frame: NSRect(x: 10, y: 6, width: 570, height: 150), title: "⌨️ Tetikleme Tuşu (Trigger Key)")
        let triggerContent = triggerBox.contentView as! FlippedContentView

        let keyLabel = NSTextField(labelWithString: "Tetikleyici Tuş:")
        keyLabel.frame = NSRect(x: 16, y: 38, width: 130, height: 20)
        keyLabel.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        triggerContent.addSubview(keyLabel)

        triggerKeyPopUp = NSPopUpButton(frame: NSRect(x: 150, y: 36, width: 255, height: 26), pullsDown: false)
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
        triggerContent.addSubview(triggerKeyPopUp)

        recordKeyButton = NSButton(frame: NSRect(x: 415, y: 35, width: 140, height: 28))
        recordKeyButton.title = "🎯 Özel Tuş Ata"
        recordKeyButton.bezelStyle = .rounded
        recordKeyButton.target = self
        recordKeyButton.action = #selector(recordKeyButtonClicked)
        triggerContent.addSubview(recordKeyButton)

        triggerKeyHintLabel = NSTextField(labelWithString: "Aktif Kısayol: Sağ Command (Right ⌘)")
        triggerKeyHintLabel.frame = NSRect(x: 150, y: 72, width: 405, height: 20)
        triggerKeyHintLabel.font = NSFont.systemFont(ofSize: 11)
        triggerKeyHintLabel.textColor = .secondaryLabelColor
        triggerContent.addSubview(triggerKeyHintLabel)

        let keyDesc = NSTextField(labelWithString: "Sağ Command tuşu çoğu Mac klavyesinde başparmakla kolayca basılabildiği için önerilir. İsteğe göre Option, Control, Fn veya özel bir tuş seçebilirsiniz.")
        keyDesc.frame = NSRect(x: 16, y: 98, width: 538, height: 38)
        keyDesc.font = NSFont.systemFont(ofSize: 11)
        keyDesc.textColor = .secondaryLabelColor
        triggerContent.addSubview(keyDesc)

        container.addSubview(triggerBox)

        // Kart 2: Mod & Dil
        let modeBox = createCardBox(frame: NSRect(x: 10, y: 164, width: 570, height: 155), title: "⚙️ Çalışma Modu ve Dil")
        let modeContent = modeBox.contentView as! FlippedContentView

        let modeLabel = NSTextField(labelWithString: "Tetikleme Modu:")
        modeLabel.frame = NSRect(x: 16, y: 38, width: 130, height: 20)
        modeLabel.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        modeContent.addSubview(modeLabel)

        modePopUp = NSPopUpButton(frame: NSRect(x: 150, y: 36, width: 405, height: 26), pullsDown: false)
        modePopUp.addItem(withTitle: "Basılı Tut (Push-to-Talk) - Tuşa basılı tut konuş, bırak yaz")
        modePopUp.addItem(withTitle: "Akıllı Hibrit (Smart) - Kısa tıkla aç-kapa, uzun bas tut-konuş")
        modePopUp.addItem(withTitle: "Aç / Kapa (Toggle) - Tuşa tıkla başlasın, tıkla dursun")
        modeContent.addSubview(modePopUp)

        let langLabel = NSTextField(labelWithString: "Konuşma Dili:")
        langLabel.frame = NSRect(x: 16, y: 76, width: 130, height: 20)
        langLabel.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        modeContent.addSubview(langLabel)

        languageField = NSTextField(frame: NSRect(x: 150, y: 76, width: 90, height: 22))
        languageField.placeholderString = "tr"
        modeContent.addSubview(languageField)

        let langHint = NSTextField(labelWithString: "('tr': Türkçe, 'en': İngilizce, 'auto': Otomatik Algıla)")
        langHint.frame = NSRect(x: 250, y: 76, width: 305, height: 20)
        langHint.font = NSFont.systemFont(ofSize: 11)
        langHint.textColor = .secondaryLabelColor
        modeContent.addSubview(langHint)

        let modeInfo = NSTextField(labelWithString: "Basılı Tut modunda tuş bırakıldığında ses kaydı hemen durdurulur ve metin otomatik yapıştırılır.")
        modeInfo.frame = NSRect(x: 16, y: 110, width: 538, height: 32)
        modeInfo.font = NSFont.systemFont(ofSize: 11)
        modeInfo.textColor = .secondaryLabelColor
        modeContent.addSubview(modeInfo)

        container.addSubview(modeBox)

        // Kart 3: Sistem & Pano
        let sysBox = createCardBox(frame: NSRect(x: 10, y: 327, width: 570, height: 185), title: "🔊 Ses ve Pano Tercihleri")
        let sysContent = sysBox.contentView as! FlippedContentView

        playSoundsCheckbox = NSButton(checkboxWithTitle: "Sistem ses efektlerini çal (Başlangıç, bitiş ve başarı bildirim tonları)", target: nil, action: nil)
        playSoundsCheckbox.frame = NSRect(x: 16, y: 34, width: 538, height: 22)
        sysContent.addSubview(playSoundsCheckbox)

        muteSystemAudioCheckbox = NSButton(checkboxWithTitle: "Konuşurken arka plan sesini/müziği sustur (YouTube, Müzik, Video vb.)", target: nil, action: nil)
        muteSystemAudioCheckbox.frame = NSRect(x: 16, y: 64, width: 538, height: 22)
        sysContent.addSubview(muteSystemAudioCheckbox)

        restoreClipboardCheckbox = NSButton(checkboxWithTitle: "Metin yapıştırıldıktan sonra eski pano içeriğini geri yükle", target: nil, action: nil)
        restoreClipboardCheckbox.frame = NSRect(x: 16, y: 94, width: 538, height: 22)
        sysContent.addSubview(restoreClipboardCheckbox)

        let clipInfo = NSTextField(labelWithString: "YouTube, müzik veya video seslerinin mikrofona karışmasını önlemek için konuşurken sistem sesi 0ms ile susturulur, bitince otomatik geri açılır.")
        clipInfo.frame = NSRect(x: 16, y: 124, width: 538, height: 38)
        clipInfo.font = NSFont.systemFont(ofSize: 11)
        clipInfo.textColor = .secondaryLabelColor
        sysContent.addSubview(clipInfo)

        container.addSubview(sysBox)
        return container
    }

    // =========================================================================
    // YARDIMCI GÖRÜNÜM ÜRETİCİLERİ
    // =========================================================================
    private func createCardBox(frame: NSRect, title: String) -> NSBox {
        let box = NSBox(frame: frame)
        box.boxType = .custom
        box.isTransparent = false
        box.borderWidth = 1
        box.cornerRadius = 10
        box.borderColor = NSColor.separatorColor.withAlphaComponent(0.25)
        box.fillColor = NSColor.controlBackgroundColor.withAlphaComponent(0.4)
        box.titlePosition = .noTitle

        let cardContent = FlippedContentView(frame: NSRect(x: 0, y: 0, width: frame.width, height: frame.height))

        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.frame = NSRect(x: 16, y: 10, width: frame.width - 32, height: 20)
        titleLabel.font = NSFont.systemFont(ofSize: 13, weight: .bold)
        titleLabel.textColor = .labelColor
        cardContent.addSubview(titleLabel)

        box.contentView = cardContent
        return box
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

    public func loadValues() {
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
        muteSystemAudioCheckbox.state = cfg.mute_system_audio ? .on : .off

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
        recordKeyButton.title = "⌨️ Tuşa Basın (Esc: İptal)..."
        recordKeyButton.highlight(true)
        triggerKeyHintLabel.stringValue = "Klavyenizden herhangi bir tuşa veya modifier'a basın..."
        triggerKeyHintLabel.textColor = .systemBlue

        keyCaptureMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] event in
            guard let self = self, self.isCapturingKey else { return event }

            let code = Int(event.keyCode)

            // Esc tuşu ile iptal
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
        recordKeyButton.title = "🎯 Özel Tuş Ata"
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
        // Eski özel tuş geçici öğelerini temizle (standart olmayanları sil)
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
        triggerKeyHintLabel.stringValue = "Aktif Kısayol: \(name) (#\(selectedTriggerKeyCode))"
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
        let triggerKey = selectedTriggerKeyCode

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
        }

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
