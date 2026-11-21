import Foundation
import AppKit
import QuartzCore

public enum HUDState: Equatable {
    case idle
    case preparing
    case recording
    case transcribing
    case success
    case notice(String)
    case error(String)
}

public enum HUDPlacement: String {
    /// Alt-ortada yüzen kapsül (varsayılan, mevcut davranış).
    case pill
    /// MacBook çentiğine yapışan Dynamic Island.
    case notch
    /// Hex tarzı saf Metal Dot Scope mini kapsül (metinsiz odak modu).
    case compact

    public static func resolve(_ raw: String) -> HUDPlacement {
        let normalized = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if normalized == "hex" { return .compact }
        return HUDPlacement(rawValue: normalized) ?? .pill
    }
}

struct RecordingHUDLayout: Equatable {
    let panelWidth: CGFloat
    let statusFrame: CGRect
    let warningFrame: CGRect?

    static func badgeEntryFrame(target: CGRect, panelWidth: CGFloat) -> CGRect {
        CGRect(x: max(0, panelWidth - 10 - target.width), y: target.minY,
               width: target.width, height: target.height)
    }

    static func calculate(
        statusTextWidth: CGFloat,
        warningTextWidth: CGFloat?,
        availableScreenWidth: CGFloat,
        horizontalScreenMargin: CGFloat = 16.0
    ) -> RecordingHUDLayout {
        let leadingX: CGFloat = 46.0
        let trailingPadding: CGFloat = 10.0
        let badgeSpacing: CGFloat = 8.0
        let minimumStatusWidth: CGFloat = 24.0
        let basePanelWidth = max(152.0, statusTextWidth + 64.0)
        let desiredWidth = basePanelWidth + (warningTextWidth.map { $0 + badgeSpacing } ?? 0)
        let maximumWidth = max(1.0, availableScreenWidth - horizontalScreenMargin * 2.0)
        let panelWidth = min(desiredWidth, maximumWidth)
        let contentWidth = max(0, panelWidth - leadingX - trailingPadding)
        let statusY: CGFloat = 8.5

        guard let requestedBadgeWidth = warningTextWidth else {
            return RecordingHUDLayout(
                panelWidth: panelWidth,
                statusFrame: CGRect(x: leadingX, y: statusY, width: contentWidth, height: 16),
                warningFrame: nil
            )
        }

        let badgeWidth = min(requestedBadgeWidth, max(0, contentWidth - minimumStatusWidth - badgeSpacing))
        let spacing = badgeWidth > 0 ? badgeSpacing : 0
        let statusWidth = max(0, contentWidth - badgeWidth - spacing)
        let badgeX = leadingX + statusWidth + spacing
        return RecordingHUDLayout(
            panelWidth: panelWidth,
            statusFrame: CGRect(x: leadingX, y: statusY, width: statusWidth, height: 16),
            warningFrame: CGRect(x: badgeX, y: 5.0, width: badgeWidth, height: 24.0)
        )
    }
}

public enum MicrophoneFeedbackState: Equatable {
    case hidden
    case waitingForVoice
    case lowLevel
}

struct MicrophoneFeedbackTracker {
    static let waitingText = "Henüz ses algılanmadı"
    static let waitingAnnouncementText = "Henüz ses algılanmadı. Konuşmaya başlayın veya mikrofonu kontrol edin."
    static let lowLevelText = "Mikrofon sesi düşük"
    static let lowLevelAnnouncementText = "Mikrofon sesi düşük. Mikrofona yaklaşın veya giriş ses düzeyini artırın."

    let gracePeriod: TimeInterval
    let waitingDwell: TimeInterval
    let lowLevelDwell: TimeInterval
    let silenceThreshold: Float
    let lowLevelThreshold: Float
    let recoveryThreshold: Float
    let recoveryDwell: TimeInterval

    private(set) var state: MicrophoneFeedbackState = .hidden
    private(set) var hasRecognizedSpeech = false
    private var recordingStartedAt: TimeInterval = 0
    private var candidateState: MicrophoneFeedbackState?
    private var candidateStartedAt: TimeInterval?
    private var recoveryStartedAt: TimeInterval?

    init(
        gracePeriod: TimeInterval = 0.75,
        waitingDwell: TimeInterval = 0.65,
        lowLevelDwell: TimeInterval = 0.65,
        silenceThreshold: Float = -72.0,
        lowLevelThreshold: Float = -52.0,
        recoveryThreshold: Float = -44.0,
        recoveryDwell: TimeInterval = 0.35
    ) {
        self.gracePeriod = gracePeriod
        self.waitingDwell = waitingDwell
        self.lowLevelDwell = lowLevelDwell
        self.silenceThreshold = silenceThreshold
        self.lowLevelThreshold = lowLevelThreshold
        self.recoveryThreshold = recoveryThreshold
        self.recoveryDwell = recoveryDwell
    }

    mutating func reset(at time: TimeInterval) {
        state = .hidden
        hasRecognizedSpeech = false
        recordingStartedAt = time
        candidateState = nil
        candidateStartedAt = nil
        recoveryStartedAt = nil
    }

    mutating func markRecognizedSpeech() {
        hasRecognizedSpeech = true
        state = .hidden
        candidateState = nil
        candidateStartedAt = nil
        recoveryStartedAt = nil
    }

    @discardableResult
    mutating func update(power: Float, at time: TimeInterval) -> MicrophoneFeedbackState {
        let now = max(time, recordingStartedAt)
        guard now - recordingStartedAt >= gracePeriod else {
            clearCandidate()
            return state
        }

        if power >= recoveryThreshold {
            clearCandidate()
            if state != .hidden {
                if recoveryStartedAt == nil { recoveryStartedAt = now }
                if now - (recoveryStartedAt ?? now) >= recoveryDwell {
                    state = .hidden
                    recoveryStartedAt = nil
                }
            }
            return state
        }

        recoveryStartedAt = nil
        if power <= silenceThreshold {
            if hasRecognizedSpeech {
                state = .hidden
                clearCandidate()
            } else {
                advanceCandidate(.waitingForVoice, at: now, dwell: waitingDwell)
            }
        } else if power <= lowLevelThreshold {
            advanceCandidate(.lowLevel, at: now, dwell: lowLevelDwell)
        } else {
            clearCandidate()
        }

        return state
    }

    private mutating func advanceCandidate(
        _ candidate: MicrophoneFeedbackState,
        at time: TimeInterval,
        dwell: TimeInterval
    ) {
        if state == candidate {
            clearCandidate()
            return
        }
        if candidateState != candidate {
            candidateState = candidate
            candidateStartedAt = time
            return
        }
        if time - (candidateStartedAt ?? time) >= dwell {
            state = candidate
            clearCandidate()
        }
    }

    private mutating func clearCandidate() {
        candidateState = nil
        candidateStartedAt = nil
    }
}

typealias LowInputWarningTracker = MicrophoneFeedbackTracker

/// Özel NSPanel: Asla ana pencere (main) veya klavye odağı (key) almaz.
/// Kullanıcının aktif metin alanından odağı kesinlikle çalmaz.
public final class FloatingHUDPanel: NSPanel {
    override public var canBecomeKey: Bool { return false }
    override public var canBecomeMain: Bool { return false }
}

/// Apple Dynamic Island / Siri Pill tarzı ultra minimal,
/// zarif oran-orantılı, buzlu cam (frosted glass) kapsül sesli yazma göstergesi.
public class RecordingHUD: NSObject {
    public static let shared = RecordingHUD()

    public private(set) var currentState: HUDState = .idle
    private(set) var presentationCount: UInt64 = 0
    public var isVisible: Bool {
        if currentState == .idle {
            return panel.isVisible && panel.alphaValue > 0.05
        }
        return true
    }
    public var currentStatusText: String {
        return statusLabel?.stringValue ?? ""
    }
    public private(set) var microphoneFeedbackState: MicrophoneFeedbackState = .hidden
    public private(set) var isLowInputWarningVisible = false
    public var currentLowInputWarningText: String {
        switch microphoneFeedbackState {
        case .hidden: return ""
        case .waitingForVoice: return MicrophoneFeedbackTracker.waitingText
        case .lowLevel: return MicrophoneFeedbackTracker.lowLevelText
        }
    }
    public var isMeteringActive: Bool { meterTimer?.isValid == true }
    public var currentPanelWidth: CGFloat { panel?.frame.width ?? 0 }
    public var isPulseAnimationActive: Bool {
        pulsingDot?.layer?.animation(forKey: "pulse") != nil
    }
    public var isMicrophoneFeedbackAnimationActive: Bool {
        microphoneFeedbackBadge?.layer?.animation(forKey: "microphoneFeedback") != nil
    }

    /// HUD'ın kök görünümü (salt okunur).
    ///
    /// Görünüm ağacının gerçekten kurulduğunu doğrulamak için açıktır:
    /// çentik formu gibi görsel katmanların canlı hiyerarşiye bağlanıp
    /// bağlanmadığı ancak buradan kontrol edilebilir.
    public var rootContentView: NSView? { panel?.contentView }

    /// Panelin arka plan rengi (salt okunur) — çentik modunda saydam olmalı.
    public var panelBackgroundColor: NSColor { panel?.backgroundColor ?? .clear }

    private var panel: FloatingHUDPanel!
    private var visualEffectView: NSVisualEffectView!
    private var darkTintView: NSBox!
    private var statusLabel: NSTextField!
    private var elapsedTimerLabel: NSTextField!
    private var microphoneFeedbackBadge: NSView!
    private var microphoneFeedbackImageView: NSImageView!

    // Göstergeler (Ultra Minimal & Orantılı)
    private var indicatorArea: NSView!
    private var pulsingDot: NSView!
    private var waveformContainer: NSView!
    private var waveformBars: [NSView] = []
    /// Hex GPU/CoreGraphics Dot Scope görselleştiricisi (pill + compact modları).
    private var dotScopeView: DotScopeView!
    /// Çentik moduna özel ekolayzır (alt kapsülünkinden bağımsız).
    private var notchMeterContainer: NSView!
    private var notchWave: NotchWaveView!
    /// Çentik sağ kanat göstergesi (sade durum etiketi / süre + durum noktası LED'i).
    private var notchWingDot: NSView!
    private var notchWingStatusLabel: NSTextField!
    private var notchStatusFadeMask: CAGradientLayer?
    /// Çentik moduna özel arka plan (gerçek çentik formu: konkav üst + konveks alt).
    private var notchShapeView: NotchShapeView!
    private var spinner: NSProgressIndicator!
    private var checkmarkLabel: NSTextField!
    private var errorIconLabel: NSTextField!
    private var noticeIconLabel: NSTextField!

    // Zamanlayıcılar & Animasyonlar
    private let frameTransition = HUDTransition()
    private let visibilityTransition = HUDTransition()
    private var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    private var meterTimer: Timer?
    private var hudAnimationTimer: Timer?
    private var dismissTimer: Timer?
    private var recordingSessionStartedAt: TimeInterval = 0
    private var isDemoPreviewActive = false
    private var demoPreviewStartedAt: TimeInterval = 0
    private var demoPreviewGeneration: UInt64 = 0
    private var currentAccentMode: DotScopeAccentMode = .normal
    private var smoothedAudioLevel: CGFloat = 0.0
    /// Çentik ekolayzırı için ayrı, zaman-tabanlı yumuşatılmış seviye.
    /// Referansın `AudioLevelMeter` davranışını birebir uygular; kapsülün
    /// seviyesinden bağımsızdır ki alt kapsülün hissi değişmesin.
    private var notchSmoothedLevel: CGFloat = 0.0
    private var notchLastTick: TimeInterval?
    private var isAudioReactiveSpeaking = false
    private var microphoneFeedbackTracker = MicrophoneFeedbackTracker()
    private(set) var currentRecordingLayout: RecordingHUDLayout?
    private var currentNotchAnchor: NotchAnchor?
    var lowInputAnnouncementHandler: (String) -> Void = { _ in }

    // Orantılı Minimal Kapsül Ölçüleri
    private let hudWidth: CGFloat = 152.0
    private let hudHeight: CGFloat = 34.0
    private let compactPanelSize = CGSize(width: 132.0, height: 38.0)

    /// Gösterge yerleşimi. Config'ten okunur; varsayılan mevcut kapsül.
    private var placement: HUDPlacement {
        HUDPlacement.resolve(ConfigManager.shared.config.hud_style)
    }

    private var activeProcessingStyle: DotScopeProcessingStyle {
        DotScopeProcessingStyle.resolve(ConfigManager.shared.config.hud_processing_effect)
    }

    private static func pillBadgeTuning(processingStyle: DotScopeProcessingStyle = .flow) -> DotScopeTuning {
        DotScopeTuning(
            columns: 15,
            rows: 7,
            spacing: 2.1,
            recordingWidth: 34.0,
            processingWidth: 34.0,
            height: 22.0,
            historySpeed: 95.0,
            processingStyle: processingStyle
        )
    }

    private static func compactTuning(processingStyle: DotScopeProcessingStyle = .flow) -> DotScopeTuning {
        var tuning = DotScopeTuning.compactDefault
        tuning.processingStyle = processingStyle
        return tuning
    }

    /// Çentik modunda yazı boyutu TAMAMEN OTOMATİKTİR (bkz. NotchTypography):
    /// sabit ada genişliğine sığana kadar küçülür, okunabilirlik tabanında durur.
    /// Kullanıcı ayarı yoktur; config'den okunmaz.

    private override init() {
        super.init()
        buildHUD()
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(accessibilityDisplayChanged),
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil
        )
        // Gösterge stili dışarıdan değiştirilirse hemen uygula: aksi halde
        // ayar değişikliği bir sonraki gösterime kadar (ya da uygulama
        // yeniden başlatılana kadar) etkisiz kalırdı.
        NotificationCenter.default.addObserver(
            self, selector: #selector(handleConfigReload),
            name: .configDidReload, object: nil
        )
        lowInputAnnouncementHandler = { [weak self] message in
            guard let panel = self?.panel else { return }
            NSAccessibility.post(
                element: panel,
                notification: .announcementRequested,
                userInfo: [
                    .announcement: message,
                    .priority: NSAccessibilityPriorityLevel.high.rawValue
                ]
            )
        }
    }

    private func buildHUD() {
        panel = FloatingHUDPanel(
            contentRect: NSRect(x: 0, y: 0, width: hudWidth, height: hudHeight),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        panel.isFloatingPanel = true
        // Zed, etkin düzenleyici penceresini floating seviyesinde tutabildiğinden
        // normal `.floating` HUD onun arkasında kalabilir. Status-bar seviyesi,
        // paneli tam ekranda da görünür tutarken `.nonactivatingPanel` sayesinde
        // yazı odağını hedef uygulamadan almaz.
        panel.level = .statusBar
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.alphaValue = 0.0
        panel.orderOut(nil)

        let contentView = NSView(frame: NSRect(x: 0, y: 0, width: hudWidth, height: hudHeight))
        contentView.wantsLayer = true
        panel.contentView = contentView

        let cornerRadius = hudHeight / 2.0

        // 1. Buzlu Cam (Frosted Glass Blur) Kapsül Arka Plan
        visualEffectView = NSVisualEffectView(frame: contentView.bounds)
        visualEffectView.autoresizingMask = [.width, .height]
        visualEffectView.material = .hudWindow
        visualEffectView.blendingMode = .behindWindow
        visualEffectView.state = .active
        visualEffectView.wantsLayer = true
        visualEffectView.layer?.cornerRadius = cornerRadius
        visualEffectView.layer?.masksToBounds = true
        visualEffectView.layer?.borderWidth = 0.6
        visualEffectView.layer?.borderColor = NSColor.white.withAlphaComponent(0.18).cgColor
        contentView.addSubview(visualEffectView)

        // 2. Yarı saydam koyu obsidyen katman (Hex renk uyumu & yüksek kontrast)
        darkTintView = NSBox(frame: contentView.bounds)
        darkTintView.autoresizingMask = [.width, .height]
        darkTintView.boxType = .custom
        darkTintView.borderWidth = 0
        darkTintView.cornerRadius = cornerRadius
        darkTintView.fillColor = NSColor(calibratedRed: 17.0 / 255.0, green: 17.0 / 255.0, blue: 20.0 / 255.0, alpha: 0.84)
        contentView.addSubview(darkTintView)

        // 3. Sol Gösterge Alanı (uyumluluk katmanı + katman animasyonu)
        indicatorArea = NSView(frame: NSRect(x: 12, y: (hudHeight - 14) / 2.0, width: 31, height: 14))
        indicatorArea.wantsLayer = true
        indicatorArea.alphaValue = 0.0
        contentView.addSubview(indicatorArea)

        // 3a. Yanıp Sönen Kırmızı Kayıt Noktası (Pulsing Red Dot - 6px)
        pulsingDot = NSView(frame: NSRect(x: 0, y: 4, width: 6, height: 6))
        pulsingDot.wantsLayer = true
        pulsingDot.layer?.cornerRadius = 3.0
        pulsingDot.layer?.backgroundColor = NSColor(red: 1.0, green: 0.23, blue: 0.20, alpha: 1.0).cgColor
        indicatorArea.addSubview(pulsingDot)

        // 3b. Dinamik 4'lü Ses Dalga Çubukları
        waveformContainer = NSView(frame: NSRect(x: 16, y: 0, width: 14, height: 14))
        waveformContainer.wantsLayer = true
        indicatorArea.addSubview(waveformContainer)

        let barWidth: CGFloat = 2.0
        let spacing: CGFloat = 1.8
        let initialHeights: [CGFloat] = [3.5, 7.5, 10.5, 5.0]
        let maxBarHeight: CGFloat = 13.0
        for i in 0..<4 {
            let bar = NSView()
            bar.wantsLayer = true
            bar.layer?.cornerRadius = barWidth / 2.0
            // Çok hafif grimsi beyaz (Soft Grayish-White / Silver)
            bar.layer?.backgroundColor = NSColor.white.cgColor
            let initialH = initialHeights[i]
            // Frame sabit kalır; konuşurken yalnızca layer transform'u değişir.
            // Bu, her 50ms'de AppKit view geometry/layout maliyeti oluşturmaz.
            bar.frame = NSRect(
                x: CGFloat(i) * (barWidth + spacing),
                y: (14.0 - maxBarHeight) / 2.0,
                width: barWidth,
                height: maxBarHeight
            )
            bar.layer?.transform = CATransform3DMakeScale(1.0, initialH / maxBarHeight, 1.0)
            waveformContainer.addSubview(bar)
            waveformBars.append(bar)
        }

        // 3c. Çentik (Notch) modu için ayrı ses göstergesi.
        // Kapsülün 31pt'lik indicatorArea görünümünü kullanmak, çentik
        // koordinatlarını kırpıyordu; dalga doğrudan içerik görünümündedir.
        notchMeterContainer = NSView(frame: NSRect(origin: .zero, size: NotchWaveView.size))
        notchMeterContainer.wantsLayer = true
        notchMeterContainer.isHidden = true
        contentView.addSubview(notchMeterContainer)

        // 3d. Çentik moduna özel arka plan: gerçek çentik formu.
        // Panel arka planı saydam kalır; siyah dolgu bu görünüm tarafından
        // konkav üst + konveks alt köşelerle çizilir. Böylece ada, çentikten
        // dışa doğru genişliyormuş gibi görünür (Apple Dynamic Island efekti).
        notchShapeView = NotchShapeView(frame: contentView.bounds)
        notchShapeView.autoresizingMask = [.width, .height]
        notchShapeView.isHidden = true
        contentView.addSubview(notchShapeView, positioned: .below, relativeTo: notchMeterContainer)

        // Çentik ses göstergesi: çubuklar yerine akışkan dalga çizgisi.
        notchWave = NotchWaveView(frame: NSRect(origin: .zero, size: NotchWaveView.size))
        notchMeterContainer.addSubview(notchWave)

        // 3e. Hex Dot Scope Metal/CoreGraphics Görselleştiricisi (kapsül & kompakt mod)
        dotScopeView = DotScopeView(
            frame: NSRect(x: 8, y: (hudHeight - 22.0) / 2.0, width: 34.0, height: 22.0),
            tuning: Self.pillBadgeTuning(),
            dotsOnly: true
        )
        contentView.addSubview(dotScopeView)

        // 4. Spinner (Deşifre Ediliyor Durumu - 14x14)
        spinner = NSProgressIndicator(frame: NSRect(x: 14, y: (hudHeight - 14) / 2.0, width: 14, height: 14))
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        spinner.appearance = NSAppearance(named: .darkAqua)
        contentView.addSubview(spinner)

        // 5a. Başarı Onay İşareti (✓)
        checkmarkLabel = NSTextField(labelWithString: "✓")
        checkmarkLabel.frame = NSRect(x: 14, y: (hudHeight - 16) / 2.0 - 1.0, width: 16, height: 16)
        checkmarkLabel.font = NSFont.systemFont(ofSize: 13, weight: .bold)
        checkmarkLabel.textColor = .systemGreen
        checkmarkLabel.alignment = .center
        checkmarkLabel.isHidden = true
        contentView.addSubview(checkmarkLabel)

        // 5b. Hata İşareti (✕)
        errorIconLabel = NSTextField(labelWithString: "✕")
        errorIconLabel.frame = NSRect(x: 14, y: (hudHeight - 16) / 2.0 - 1.0, width: 16, height: 16)
        errorIconLabel.font = NSFont.systemFont(ofSize: 13, weight: .bold)
        errorIconLabel.textColor = .systemOrange
        errorIconLabel.alignment = .center
        errorIconLabel.isHidden = true
        contentView.addSubview(errorIconLabel)

        // 5c. Bilgilendirme İşareti (ⓘ)
        noticeIconLabel = NSTextField(labelWithString: "ⓘ")
        noticeIconLabel.frame = NSRect(x: 14, y: (hudHeight - 16) / 2.0 - 1.0, width: 16, height: 16)
        noticeIconLabel.font = NSFont.systemFont(ofSize: 13, weight: .bold)
        noticeIconLabel.textColor = .systemYellow
        noticeIconLabel.alignment = .center
        noticeIconLabel.isHidden = true
        contentView.addSubview(noticeIconLabel)

        // 6. Durum Metni (Status Label - SF Pro 12pt Medium, dikey ortalı)
        statusLabel = NSTextField(labelWithString: "Dinliyor...")
        statusLabel.frame = NSRect(x: 46, y: (hudHeight - 16) / 2.0 - 0.5, width: 95, height: 16)
        statusLabel.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        statusLabel.textColor = .white
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.alignment = .left
        contentView.addSubview(statusLabel)

        // 6b. Uzun kayıtlarda geçen süre sayacı (5 sn sonrası belirir)
        elapsedTimerLabel = NSTextField(labelWithString: "")
        elapsedTimerLabel.frame = NSRect(x: hudWidth - 44, y: (hudHeight - 14) / 2.0, width: 34, height: 14)
        elapsedTimerLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 10.5, weight: .medium)
        elapsedTimerLabel.textColor = NSColor(white: 0.72, alpha: 1.0)
        elapsedTimerLabel.alignment = .right
        elapsedTimerLabel.isHidden = true
        contentView.addSubview(elapsedTimerLabel)

        // 6c. Çentik sağ kanat bileşenleri (notchShapeView üzerinde eklenir)
        notchWingDot = NSView(frame: NSRect(x: 0, y: 0, width: 6, height: 6))
        notchWingDot.wantsLayer = true
        notchWingDot.layer?.cornerRadius = 3.0
        notchWingDot.isHidden = true
        contentView.addSubview(notchWingDot)

        notchWingStatusLabel = NSTextField(labelWithString: "")
        notchWingStatusLabel.font = NSFont.systemFont(ofSize: 11.5, weight: .medium)
        notchWingStatusLabel.textColor = NSColor(calibratedWhite: 0.88, alpha: 1.0)
        notchWingStatusLabel.alignment = .right
        notchWingStatusLabel.lineBreakMode = .byTruncatingTail
        notchWingStatusLabel.maximumNumberOfLines = 1
        notchWingStatusLabel.usesSingleLineMode = true
        notchWingStatusLabel.isHidden = true
        contentView.addSubview(notchWingStatusLabel)

        microphoneFeedbackBadge = NSView(frame: NSRect(x: 0, y: 5, width: 24, height: 24))
        microphoneFeedbackBadge.wantsLayer = true
        microphoneFeedbackBadge.layer?.cornerRadius = 12
        microphoneFeedbackBadge.layer?.backgroundColor = NSColor.systemOrange.withAlphaComponent(0.16).cgColor
        microphoneFeedbackBadge.layer?.borderWidth = 0.5
        microphoneFeedbackBadge.layer?.borderColor = NSColor.systemOrange.withAlphaComponent(0.38).cgColor
        microphoneFeedbackBadge.layer?.shadowColor = NSColor.systemOrange.cgColor
        microphoneFeedbackBadge.layer?.shadowRadius = 5
        microphoneFeedbackBadge.layer?.shadowOpacity = 0.18
        microphoneFeedbackBadge.layer?.shadowOffset = .zero
        microphoneFeedbackBadge.isHidden = true
        microphoneFeedbackBadge.setAccessibilityElement(true)
        microphoneFeedbackBadge.setAccessibilityRole(.image)

        microphoneFeedbackImageView = NSImageView(frame: NSRect(x: 5, y: 5, width: 14, height: 14))
        microphoneFeedbackImageView.imageScaling = .scaleProportionallyUpOrDown
        microphoneFeedbackImageView.contentTintColor = .systemOrange
        microphoneFeedbackBadge.addSubview(microphoneFeedbackImageView)
        contentView.addSubview(microphoneFeedbackBadge)
    }

    /// Renders only this app's views with fixed demo text. The panel is never
    /// ordered onscreen, and within-window blending cannot sample the desktop.
    static func demoPreviewPNG() -> Data? {
        precondition(Thread.isMainThread)
        let hud = RecordingHUD()
        hud.visualEffectView.blendingMode = .withinWindow
        hud.panel.appearance = NSAppearance(named: .darkAqua)
        hud.panel.contentView?.layer?.backgroundColor = NSColor(white: 0.10, alpha: 1).cgColor
        hud.statusLabel.stringValue = "Bugün toplantı saat üçte."
        hud.currentState = .recording
        hud.microphoneFeedbackState = .lowLevel
        hud.configureMicrophoneFeedbackBadge(for: .lowLevel)
        hud.updateRecordingLayout(animated: false)
        guard let view = hud.panel.contentView,
              let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        return bitmap.representation(using: .png, properties: [:])
    }

    // MARK: - Ekran Konumlandırma

    private func targetScreen() -> NSScreen? {
        // Çentik modunda: harici monitör birincil olsa bile çentikli ekranı seç.
        // Ada yalnızca kameranın olduğu ekranda anlamlıdır.
        if placement == .notch, let notched = Self.notchedScreen() {
            return notched
        }
        let mouseLoc = NSEvent.mouseLocation
        if let screen = NSScreen.screens.first(where: { NSPointInRect(mouseLoc, $0.frame) }) {
            return screen
        }
        return NSScreen.main ?? NSScreen.screens.first
    }

    /// `safeAreaInsets.top > 0` olan (yani çentiği bulunan) ilk ekran.
    static func notchedScreen() -> NSScreen? {
        NSScreen.screens.first { screen in
            if #available(macOS 12.0, *) {
                return screen.safeAreaInsets.top > 0
            }
            return false
        }
    }

    /// Gerçek bir `NSScreen`'den çentik ölçümü çıkarır.
    ///
    /// `auxiliaryTopLeftArea` / `auxiliaryTopRightArea` yalnızca macOS 12+
    /// ve çentikli donanımda anlamlıdır; yoksa güvenli biçimde nil geçilir ve
    /// `NotchAnchor` ihtiyatlı genişliğe düşer.
    static func anchor(for screen: NSScreen) -> NotchAnchor {
        var safeTop: CGFloat = 0
        if #available(macOS 12.0, *) {
            safeTop = screen.safeAreaInsets.top
        }
        var leftEdgeX: CGFloat?
        var rightEdgeX: CGFloat?
        if #available(macOS 12.0, *) {
            let left = screen.auxiliaryTopLeftArea
            let right = screen.auxiliaryTopRightArea
            if let left, let right, left.width > 0, right.width > 0 {
                leftEdgeX = left.origin.x + left.width
                rightEdgeX = right.origin.x
            }
        }
        return NotchAnchor.make(
            safeTopInset: safeTop,
            screenFrame: screen.frame,
            auxiliaryLeftEdgeX: leftEdgeX,
            auxiliaryRightEdgeX: rightEdgeX,
            backingScale: screen.backingScaleFactor
        )
    }

    public func setTranslationMode(_ enabled: Bool) {
        executeOnMainThread { [weak self] in
            guard let self else { return }
            self.currentAccentMode = enabled ? .translation : .normal
            self.syncDotScopeStyling()
        }
    }

    /// Ayarlardan veya komutla canlı Hex Dot Scope animasyon önizlemesini çalıştırır.
    public func runDemoPreview() {
        executeOnMainThread { [weak self] in
            guard let self else { return }
            self.demoPreviewGeneration &+= 1
            let gen = self.demoPreviewGeneration
            self.isDemoPreviewActive = true
            self.demoPreviewStartedAt = ProcessInfo.processInfo.systemUptime
            self.startRecordingHUD(cancelDemo: false)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.85) { [weak self] in
                guard let self, self.isDemoPreviewActive, self.demoPreviewGeneration == gen else { return }
                self.startTranscribingHUD(cancelDemo: false)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.05) { [weak self] in
                guard let self, self.isDemoPreviewActive, self.demoPreviewGeneration == gen else { return }
                self.showSuccess(text: "Önizleme tamamlandı", autoDismissDelay: 0.7) { [weak self] in
                    guard let self, self.demoPreviewGeneration == gen else { return }
                    self.isDemoPreviewActive = false
                }
            }
        }
    }

    private func cancelDemoPreviewIfNeeded() {
        guard isDemoPreviewActive else { return }
        isDemoPreviewActive = false
        demoPreviewGeneration &+= 1
    }

    private var isCompactMessageState: Bool {
        switch currentState {
        case .notice, .error:
            return true
        case .idle, .preparing, .recording, .transcribing, .success:
            return false
        }
    }

    private func dotScopeStageForCurrentState() -> DotScopeStage {
        switch currentState {
        case .preparing:
            return .preparing
        case .recording, .idle:
            return .recording
        case .transcribing:
            return .processing
        case .success:
            return .done
        case .notice:
            return .notice
        case .error:
            return .failed
        }
    }

    private func syncDotScopeStyling() {
        let usesFullHexPill = placement == .compact && !isCompactMessageState
        let tuning = usesFullHexPill
            ? Self.compactTuning(processingStyle: activeProcessingStyle)
            : Self.pillBadgeTuning(processingStyle: activeProcessingStyle)
        dotScopeView.configure(
            tuning: tuning,
            processingStyle: activeProcessingStyle,
            accentMode: currentAccentMode,
            dotsOnly: !usesFullHexPill
        )
        dotScopeView.setStage(dotScopeStageForCurrentState())
        notchWave.configure(processingStyle: activeProcessingStyle, accentMode: currentAccentMode)
    }

    private func updateReactivePillBorder() {
        let baseAlpha: CGFloat
        let borderColor: NSColor
        switch currentState {
        case .recording:
            let levelGlow = min(1.0, max(0.0, notchSmoothedLevel))
            baseAlpha = 0.16 + levelGlow * 0.24
            borderColor = currentAccentMode == .translation
                ? NSColor(calibratedRed: 0.45, green: 0.78, blue: 1.0, alpha: baseAlpha)
                : NSColor(calibratedRed: 0.96, green: 0.86, blue: 0.65, alpha: baseAlpha)
        case .transcribing:
            borderColor = currentAccentMode == .translation
                ? NSColor(calibratedRed: 0.56, green: 0.68, blue: 1.0, alpha: 0.34)
                : NSColor(calibratedRed: 0.36, green: 0.70, blue: 1.0, alpha: 0.34)
        case .success:
            borderColor = NSColor.systemGreen.withAlphaComponent(0.38)
        case .error:
            borderColor = NSColor.systemOrange.withAlphaComponent(0.42)
        case .notice:
            borderColor = NSColor.systemYellow.withAlphaComponent(0.36)
        case .preparing, .idle:
            borderColor = NSColor.white.withAlphaComponent(0.18)
        }
        visualEffectView.layer?.borderColor = borderColor.cgColor
    }

    private func updateCompactPosition(screen: NSScreen, animated: Bool) {
        let screenFrame = screen.visibleFrame
        let targetW = compactPanelSize.width
        let targetH = compactPanelSize.height
        let x = round(screenFrame.midX - (targetW / 2.0))
        let y = round(screenFrame.minY + 64.0)
        let target = NSRect(x: x, y: y, width: targetW, height: targetH)

        visualEffectView.isHidden = true
        darkTintView.isHidden = true
        indicatorArea.isHidden = true
        notchMeterContainer.isHidden = true
        notchShapeView.isHidden = true
        notchWingDot.isHidden = true
        notchWingStatusLabel.isHidden = true
        statusLabel.isHidden = true
        statusLabel.layer?.mask = nil
        elapsedTimerLabel.isHidden = true
        microphoneFeedbackBadge.isHidden = true
        spinner.isHidden = true
        checkmarkLabel.isHidden = true
        errorIconLabel.isHidden = true
        noticeIconLabel.isHidden = true

        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.contentView?.wantsLayer = true
        panel.contentView?.layer?.cornerRadius = targetH / 2.0
        panel.contentView?.layer?.masksToBounds = false

        frameTransition.cancel()
        panel.setFrame(target, display: true)
        dotScopeView.isHidden = false
        dotScopeView.frame = NSRect(origin: .zero, size: target.size)
        syncDotScopeStyling()
        dotScopeView.renderNow()
        _ = animated
    }

    private func startHudAnimationTimer() {
        hudAnimationTimer?.invalidate()
        let interval: TimeInterval = reduceMotion ? (1.0 / 15.0) : (1.0 / 60.0)
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            self?.tickHudVisuals()
        }
        RunLoop.main.add(timer, forMode: .common)
        hudAnimationTimer = timer
        tickHudVisuals()
    }

    private func stopHudAnimationTimer() {
        hudAnimationTimer?.invalidate()
        hudAnimationTimer = nil
    }

    private func tickHudVisuals() {
        if isDemoPreviewActive {
            let elapsed = Float(max(0.0, ProcessInfo.processInfo.systemUptime - demoPreviewStartedAt))
            let demoDB = DotScopeSimulation.demoLoudness(at: elapsed)
            dotScopeView.pushAudioLevel(dBFS: demoDB)
            let demoNorm = max(0, min(1, CGFloat((demoDB + 52.0) / 36.0)))
            notchSmoothedLevel = demoNorm
            let mode: NotchWaveView.Mode = currentState == .transcribing ? .processing : .listening
            if placement == .notch {
                notchWave.render(level: demoNorm, mode: mode, animated: !reduceMotion)
                notchShapeView.rimGlowColor = currentState == .transcribing
                    ? NSColor(calibratedRed: 0.36, green: 0.70, blue: 1.0, alpha: 1.0)
                    : NSColor(calibratedRed: 0.96, green: 0.86, blue: 0.65, alpha: 1.0)
                notchShapeView.rimGlowIntensity = 0.20 + 0.75 * demoNorm
            }
        }
        if placement == .notch && currentState == .preparing {
            notchWave.render(level: 0, mode: .preparing, animated: !reduceMotion)
        }
        updateElapsedTimerDisplay()
        updateReactivePillBorder()
        if !dotScopeView.isHidden {
            dotScopeView.step(dt: nil, visible: panel.isVisible || isDemoPreviewActive, reduceMotion: reduceMotion)
        }
    }

    private func updateElapsedTimerDisplay() {
        guard currentState == .recording,
              recordingSessionStartedAt > 0,
              !(placement == .compact && !isCompactMessageState) else {
            if !elapsedTimerLabel.isHidden {
                elapsedTimerLabel.isHidden = true
            }
            return
        }
        let elapsed = max(0, ProcessInfo.processInfo.systemUptime - recordingSessionStartedAt)
        guard elapsed >= 5.0 else {
            if !elapsedTimerLabel.isHidden {
                elapsedTimerLabel.isHidden = true
            }
            return
        }
        let totalSeconds = Int(elapsed)
        let formatted = String(format: "%d:%02d", totalSeconds / 60, totalSeconds % 60)
        if elapsedTimerLabel.stringValue != formatted {
            elapsedTimerLabel.stringValue = formatted
        }
        if placement == .notch {
            if let anchor = currentNotchAnchor ?? targetScreen().map(Self.anchor(for:)), anchor.hasNotch {
                if !elapsedTimerLabel.isHidden { elapsedTimerLabel.isHidden = true }
                notchWingStatusLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 11.5, weight: .medium)
                notchWingStatusLabel.stringValue = formatted
            } else if elapsedTimerLabel.isHidden {
                elapsedTimerLabel.isHidden = false
                if let screen = targetScreen() {
                    let anchor = Self.anchor(for: screen)
                    layoutNotchContent(for: notchIslandFrame(anchor: anchor).size, anchor: anchor)
                }
            }
            return
        }
        if elapsedTimerLabel.isHidden {
            elapsedTimerLabel.isHidden = false
            if placement == .pill {
                let frame = panel.frame
                elapsedTimerLabel.frame = NSRect(x: max(50, frame.width - 42), y: (hudHeight - 14) / 2.0, width: 32, height: 14)
            }
        }
    }

    private func updatePosition(width: CGFloat? = nil, layout: RecordingHUDLayout? = nil, animated: Bool = true) {
        precondition(Thread.isMainThread)
        guard let screen = targetScreen() else { return }

        if placement == .notch {
            updateNotchPosition(screen: screen, animated: animated)
            return
        }

        if placement == .compact && !isCompactMessageState {
            updateCompactPosition(screen: screen, animated: animated)
            return
        }

        self.visualEffectView.isHidden = false
        self.darkTintView.isHidden = false
        self.indicatorArea.isHidden = false
        self.statusLabel.isHidden = false
        self.statusLabel.layer?.mask = nil
        self.panel.backgroundColor = .clear
        self.panel.hasShadow = true
        // Kapsül modunda çentiğe özel ekolayzır, kanat ve ada formu gizlenir.
        self.notchMeterContainer.isHidden = true
        self.notchShapeView.isHidden = true
        self.notchWingDot.isHidden = true
        self.notchWingStatusLabel.isHidden = true

        let showDotScopeBadge: Bool
        switch currentState {
        case .preparing, .recording, .transcribing:
            showDotScopeBadge = true
        case .idle, .success, .notice, .error:
            showDotScopeBadge = false
        }
        self.dotScopeView.isHidden = !showDotScopeBadge
        if showDotScopeBadge {
            self.dotScopeView.frame = NSRect(x: 8, y: (hudHeight - 22.0) / 2.0, width: 34.0, height: 22.0)
            self.syncDotScopeStyling()
        }
        self.updateReactivePillBorder()

        // Çentik modu paylaşılan statusLabel'ı 28pt yapar. Burada geri
        // alınmazsa kapsülün yazısı mod değiştirdikten sonra kocaman kalır
        // (kullanıcı bildirimi: "alt kapsül bozuldu, yazı çok büyük oldu").
        self.statusLabel.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        self.statusLabel.alignment = .left
        // Çentik modu paylaşılan etiketi kelime sarmaya alır; kapsülde tek
        // satırlık kırpma davranışına dönülmezse kapsül metni de sarardı.
        self.statusLabel.maximumNumberOfLines = 1
        self.statusLabel.cell?.wraps = false
        self.statusLabel.cell?.isScrollable = false
        self.statusLabel.usesSingleLineMode = true
        self.statusLabel.lineBreakMode = .byTruncatingTail
        // Çentik modu contentView'a alt köşe yuvarlaması uygular; kapsülde
        // tam kapsül yarıçapına dönülmezse köşeler kırpık kalırdı.
        self.panel.contentView?.wantsLayer = true
        self.panel.contentView?.layer?.cornerRadius = self.hudHeight / 2.0
        self.panel.contentView?.layer?.masksToBounds = true

        let screenFrame = screen.visibleFrame
        let maximumWidth = max(1.0, screenFrame.width - 32.0)
        let currentW = min(width ?? hudWidth, maximumWidth)
        let unclampedX = round(screenFrame.midX - (currentW / 2.0))
        let x = min(max(unclampedX, screenFrame.minX + 16.0), screenFrame.maxX - 16.0 - currentW)
        let y = round(screenFrame.minY + 64.0)
        let target = NSRect(x: x, y: y, width: currentW, height: hudHeight)
        let start = panel.frame
        let startStatus = statusLabel.frame
        let targetStatus = layout?.statusFrame ?? NSRect(x: 46, y: 8.5, width: max(0, currentW - 56), height: 16)
        let startBadgeAlpha = microphoneFeedbackBadge.alphaValue
        let targetBadge = layout?.warningFrame ?? microphoneFeedbackBadge.frame
        // A hidden badge has no meaningful previous position. Enter at the
        // trailing edge, not from its original x=0 placeholder over the meter.
        let startBadge = startBadgeAlpha == 0
            ? RecordingHUDLayout.badgeEntryFrame(target: targetBadge, panelWidth: start.width)
            : microphoneFeedbackBadge.frame
        let duration = animated && panel.isVisible && !reduceMotion ? 0.20 : 0
        frameTransition.start(duration: duration) { [weak self] progress in
            guard let self else { return }
            let p = CGFloat(progress)
            func interpolate(_ a: CGRect, _ b: CGRect) -> CGRect {
                CGRect(x: a.minX + (b.minX - a.minX) * p,
                       y: a.minY + (b.minY - a.minY) * p,
                       width: a.width + (b.width - a.width) * p,
                       height: a.height + (b.height - a.height) * p)
            }
            // Explicit interpolation really changes the window frame each display tick.
            // All content geometry shares that clock, including during interrupted resizes.
            let frame = interpolate(start, target)
            self.panel.setFrame(frame, display: true)
            var status = interpolate(startStatus, targetStatus)
            var badge = interpolate(startBadge, targetBadge)
            badge.origin.x = min(badge.minX, max(0, frame.width - 10 - badge.width))
            if layout?.warningFrame != nil {
                status.size.width = min(status.width, max(0, badge.minX - 8 - status.minX))
            }
            if !self.elapsedTimerLabel.isHidden {
                let timerX = max(50, frame.width - 42)
                self.elapsedTimerLabel.frame = NSRect(x: timerX, y: (self.hudHeight - 14) / 2.0, width: 32, height: 14)
                status.size.width = min(status.width, max(0, timerX - 6 - status.minX))
            } else {
                status.size.width = min(status.width, max(0, frame.width - 10 - status.minX))
            }
            self.statusLabel.frame = status
            self.microphoneFeedbackBadge.frame = badge
            self.microphoneFeedbackBadge.isHidden = self.microphoneFeedbackState == .hidden || badge.width < 24
            self.microphoneFeedbackBadge.alphaValue = layout?.warningFrame == nil ? 0 : startBadgeAlpha + (1 - startBadgeAlpha) * p
            // Kapsül modu kendi ekolayzırını kullanır. Çentik modu bunu
            // gizlediği için burada geri açılmazsa VU metre kalıcı olarak
            // kaybolurdu (mod değiştirdikten sonra geri dönüş yoktu).
            self.waveformContainer.isHidden = self.currentState != .recording
        }
    }

    // MARK: - Çentik (Dynamic Island) düzeni
    //
    // ┌──── kamera ────┐        Ada, kameradan biraz geniş kompakt bir formdur;
    // │ [▮▮▮] metin…   │        boş kanat bırakılmaz. Alt satırda simge yuvası
    // └────────────────┘        (ekolayzır / spinner / ✓ / ! ) ve tek satır metin
    //                           yan yana durur. Boyut tüm durumlarda sabittir:
    //                           metin geldikçe ada zıplamaz, yalnızca açılırken
    //                           çentikten büyür ve kapanırken çentiğe geri çekilir.

    private enum NotchMetrics {
        static let earInset: CGFloat = NotchShapePath.topCornerRadius
        static let wingInnerPadding: CGFloat = 12
        static let trayHorizontalInset: CGFloat = 30
        static let wingSlotWidth: CGFloat = 88
        static let compactMinHeight: CGFloat = 38
        static let trayHeight: CGFloat = 38
        static let nonNotchHeight: CGFloat = 44
        static let rowHeight: CGFloat = 24
        static let bottomInset: CGFloat = 10
        static let fontSize: CGFloat = 13.5
        static let openDuration: TimeInterval = 0.28
        static let morphDuration: TimeInterval = 0.24
        static let closeDuration: TimeInterval = 0.20
    }

    private var isNotchClosing = false

    private var hasNotchLiveInterimText: Bool {
        guard currentState == .recording || currentState == .transcribing else { return false }
        let trimmed = statusLabel.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        return trimmed != "Dinliyor..." && trimmed != "Yazılıyor..." && trimmed != "Hazırlanıyor…"
    }

    /// Çentik adası yalnızca gerektiğinde (canlı ara metin, düşük mikrofon uyarısı, hata veya bilgi)
    /// kameranın altına doğru 2. katmana büyür; aksi halde kanatlarda kompakt kalır.
    private var notchNeedsExpandedTray: Bool {
        switch currentState {
        case .error, .notice:
            return true
        case .recording:
            return microphoneFeedbackState != .hidden || hasNotchLiveInterimText
        case .transcribing:
            return hasNotchLiveInterimText
        case .idle, .preparing, .success:
            return false
        }
    }

    private func notchIslandFrame(anchor: NotchAnchor) -> CGRect {
        let maxAllowedWidth = max(300, anchor.screenWidth - 48)
        let width: CGFloat
        let height: CGFloat

        if anchor.hasNotch {
            let topBarHeight = max(anchor.headerHeight, NotchMetrics.compactMinHeight)
            if notchNeedsExpandedTray {
                width = min(maxAllowedWidth, min(460, max(380, anchor.cameraWidth + 208)))
                height = topBarHeight + NotchMetrics.trayHeight
            } else {
                let wingWidth = anchor.cameraWidth + 2 * (NotchMetrics.earInset + NotchMetrics.wingSlotWidth)
                width = min(maxAllowedWidth, min(440, max(356, wingWidth)))
                height = topBarHeight
            }
        } else {
            width = min(maxAllowedWidth, notchNeedsExpandedTray ? 400 : 320)
            height = NotchMetrics.nonNotchHeight
        }

        return CGRect(
            x: round(anchor.centerX - width / 2),
            y: anchor.top - height,
            width: width,
            height: height
        )
    }

    /// Adanın kapalı hali: tam kamera çentiği kadar siyah alan. Siyah çentikle
    /// birleştiği için açılış/kapanış kesintisiz görünür.
    private func notchCollapsedFrame(anchor: NotchAnchor, island: CGRect) -> CGRect {
        let width = anchor.cameraWidth > 0 ? anchor.cameraWidth : max(140, island.width * 0.45)
        let collapsedHeight = anchor.hasNotch ? anchor.headerHeight : 28
        return CGRect(
            x: round(anchor.centerX - width / 2),
            y: anchor.top - collapsedHeight,
            width: width,
            height: collapsedHeight
        )
    }

    private func updateNotchPosition(screen: NSScreen, animated: Bool) {
        let anchor = Self.anchor(for: screen)
        currentNotchAnchor = anchor
        let island = notchIslandFrame(anchor: anchor)

        // Form `notchShapeView` tarafından çizilir. Pencere gölgesi kapalı:
        // saydam pencerede gölge siyah formun çevresine gri bir kontur çizer.
        visualEffectView.isHidden = true
        darkTintView.isHidden = true
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        notchShapeView.isHidden = false
        notchShapeView.fillColor = NSColor(calibratedWhite: 0.0, alpha: 1.0)
        panel.contentView?.wantsLayer = true
        panel.contentView?.layer?.cornerRadius = 0
        panel.contentView?.layer?.masksToBounds = false

        // Panel henüz görünür değilken tam boyutla `display: true` çizmemek 1 karelik siyah flaşı önler.
        if !panel.isVisible {
            frameTransition.cancel()
            isNotchClosing = false
            if reduceMotion {
                panel.setFrame(island, display: false)
                layoutNotchContent(for: island.size, anchor: anchor)
                setNotchContentAlpha(1)
            } else {
                let collapsed = notchCollapsedFrame(anchor: anchor, island: island)
                panel.setFrame(collapsed, display: false)
                layoutNotchContent(for: collapsed.size, anchor: anchor)
                setNotchContentAlpha(0)
            }
            return
        }

        let isOpening = frameTransition.isActive && !isNotchClosing
        if isOpening {
            layoutNotchContent(for: panel.frame.size, anchor: anchor)
            return
        }

        if panel.frame != island {
            isNotchClosing = false
            if animated && !reduceMotion {
                let startFrame = panel.frame
                frameTransition.start(duration: NotchMetrics.morphDuration, update: { [weak self] progress in
                    guard let self else { return }
                    let p = CGFloat(IslandTween.easeOut(progress))
                    let next = Self.interpolate(startFrame, island, p)
                    self.panel.setFrame(next, display: true)
                    self.layoutNotchContent(for: next.size, anchor: anchor)
                    self.setNotchContentAlpha(1)
                }, completion: { [weak self] in
                    guard let self else { return }
                    self.panel.setFrame(island, display: true)
                    self.layoutNotchContent(for: island.size, anchor: anchor)
                    self.setNotchContentAlpha(1)
                })
                return
            } else {
                frameTransition.cancel()
                panel.setFrame(island, display: true)
            }
        }

        layoutNotchContent(for: island.size, anchor: anchor)
        setNotchContentAlpha(1)
    }

    private func layoutNotchContent(for island: CGSize, anchor: NotchAnchor) {
        // Pill ve Compact moduna ait öğeler çentikte hiç görünmez.
        pulsingDot.isHidden = true
        microphoneFeedbackBadge.isHidden = true
        waveformContainer.isHidden = true
        dotScopeView.isHidden = true
        spinner.stopAnimation(nil)
        spinner.isHidden = true
        elapsedTimerLabel.isHidden = true
        syncDotScopeStyling()

        let isPreparing = currentState == .preparing
        let isRecording = currentState == .recording
        let isTranscribing = currentState == .transcribing
        let showWave = isPreparing || isRecording || isTranscribing

        notchMeterContainer.isHidden = !showWave
        if isTranscribing {
            startProcessingAnimation()
        } else {
            stopProcessingAnimation()
        }

        if case .success = currentState { checkmarkLabel.isHidden = false } else { checkmarkLabel.isHidden = true }
        if case .error = currentState { errorIconLabel.isHidden = false } else { errorIconLabel.isHidden = true }
        if case .notice = currentState { noticeIconLabel.isHidden = false } else { noticeIconLabel.isHidden = true }

        // Kenar ışığı rengi ve yoğunluğu duruma göre ayarlanır.
        if isTranscribing {
            notchShapeView.rimGlowColor = currentAccentMode == .translation
                ? NSColor(calibratedRed: 0.56, green: 0.68, blue: 1.0, alpha: 1.0)
                : NSColor(calibratedRed: 0.36, green: 0.70, blue: 1.0, alpha: 1.0)
            notchShapeView.rimGlowIntensity = 0.42
        } else if case .success = currentState {
            notchShapeView.rimGlowColor = .systemGreen
            notchShapeView.rimGlowIntensity = 0.55
        } else if case .error = currentState {
            notchShapeView.rimGlowColor = .systemOrange
            notchShapeView.rimGlowIntensity = 0.58
        } else if case .notice = currentState {
            notchShapeView.rimGlowColor = .systemYellow
            notchShapeView.rimGlowIntensity = 0.42
        } else if isPreparing || currentState == .idle {
            notchShapeView.rimGlowIntensity = 0.0
        }

        guard anchor.hasNotch else {
            layoutNonNotchedIsland(size: island, showWave: showWave)
            return
        }

        let topBarHeight = max(anchor.headerHeight, NotchMetrics.compactMinHeight)
        let topRowMidY = island.height - topBarHeight / 2.0
        let cameraHalf = anchor.cameraWidth / 2.0

        // Sol kanat: üst kulak kavisinin (12pt + 12pt pay = 24pt) içinden kamera soluna kadar
        let leftWingMinX = NotchMetrics.earInset + NotchMetrics.wingInnerPadding
        let leftWingMaxX = max(leftWingMinX + NotchWaveView.size.width, island.width / 2.0 - cameraHalf - 6.0)
        let leftWingWidth = max(NotchWaveView.size.width, leftWingMaxX - leftWingMinX)
        let waveOriginX = round(leftWingMinX + (leftWingWidth - NotchWaveView.size.width) / 2.0)
        let waveOriginY = round(topRowMidY - NotchWaveView.size.height / 2.0)
        notchMeterContainer.setFrameOrigin(NSPoint(x: waveOriginX, y: waveOriginY))

        let iconWidth: CGFloat = 20
        let iconOriginX = round(leftWingMinX + (leftWingWidth - iconWidth) / 2.0)
        let iconOriginY = round(topRowMidY - 9)
        for icon in [checkmarkLabel, errorIconLabel, noticeIconLabel] {
            icon?.frame = NSRect(x: iconOriginX, y: iconOriginY, width: iconWidth, height: 18)
        }

        // Sağ kanat: kameranın sağından sağ kulak iç boşluğuna kadar
        let rightWingMinX = min(island.width - leftWingMinX - 40, island.width / 2.0 + cameraHalf + 6.0)
        let rightWingMaxX = island.width - NotchMetrics.earInset - NotchMetrics.wingInnerPadding
        configureNotchRightWing(
            minX: rightWingMinX,
            maxX: rightWingMaxX,
            midY: topRowMidY
        )

        // Alt tepsi: yalnızca ihtiyaç halinde açılır
        let trayVisible = notchNeedsExpandedTray && island.height >= topBarHeight + 18.0
        guard trayVisible else {
            statusLabel.isHidden = true
            statusLabel.layer?.mask = nil
            return
        }

        statusLabel.isHidden = false
        let trayFont = NSFont.systemFont(ofSize: NotchMetrics.fontSize, weight: .medium)
        let textHeight = ceil(trayFont.ascender - trayFont.descender + trayFont.leading)
        let trayInset = NotchMetrics.trayHorizontalInset
        let trayWidth = max(0, island.width - trayInset * 2.0)
        let trayY = round(NotchMetrics.bottomInset + (NotchMetrics.trayHeight - NotchMetrics.bottomInset - textHeight) / 2.0)

        let displayText: String
        let textColor: NSColor
        let lineBreak: NSLineBreakMode
        let wantsLeftFadeMask: Bool

        if isRecording && !hasNotchLiveInterimText && microphoneFeedbackState != .hidden {
            displayText = microphoneFeedbackState == .waitingForVoice
                ? "Konuşmaya başlayın..."
                : "Ses düşük · mikrofona biraz yaklaşın"
            textColor = NSColor(calibratedRed: 1.0, green: 0.78, blue: 0.36, alpha: 0.96)
            lineBreak = .byTruncatingTail
            wantsLeftFadeMask = false
        } else if case let .error(msg) = currentState {
            displayText = msg
            textColor = .systemOrange
            lineBreak = .byTruncatingTail
            wantsLeftFadeMask = false
        } else if case let .notice(msg) = currentState {
            displayText = msg
            textColor = NSColor(calibratedWhite: 0.95, alpha: 1.0)
            lineBreak = .byTruncatingTail
            wantsLeftFadeMask = false
        } else {
            displayText = statusLabel.stringValue
            textColor = NSColor(calibratedWhite: 0.97, alpha: 1.0)
            lineBreak = .byTruncatingHead
            let measuredWidth = ceil((displayText as NSString).size(withAttributes: [.font: trayFont]).width)
            wantsLeftFadeMask = measuredWidth > trayWidth
        }

        if statusLabel.stringValue != displayText {
            statusLabel.stringValue = displayText
        }
        statusLabel.font = trayFont
        statusLabel.textColor = textColor
        statusLabel.maximumNumberOfLines = 1
        statusLabel.cell?.wraps = false
        statusLabel.cell?.isScrollable = false
        statusLabel.usesSingleLineMode = true
        statusLabel.lineBreakMode = lineBreak
        statusLabel.alignment = wantsLeftFadeMask ? .left : .center
        statusLabel.frame = NSRect(x: trayInset, y: trayY, width: trayWidth, height: textHeight)
        updateNotchStatusFadeMask(enabled: wantsLeftFadeMask, width: trayWidth, height: textHeight)
    }

    private func layoutNonNotchedIsland(size: CGSize, showWave: Bool) {
        let horizontalInset = NotchMetrics.trayHorizontalInset
        let midY = size.height / 2.0
        notchMeterContainer.setFrameOrigin(NSPoint(x: horizontalInset, y: round(midY - NotchWaveView.size.height / 2.0)))

        let iconRect = NSRect(x: horizontalInset + 14, y: round(midY - 9), width: 20, height: 18)
        for icon in [checkmarkLabel, errorIconLabel, noticeIconLabel] {
            icon?.frame = iconRect
        }

        notchWingDot.isHidden = true
        let showTimer = currentState == .recording && recordingSessionStartedAt > 0 &&
            (ProcessInfo.processInfo.systemUptime - recordingSessionStartedAt) >= 5.0
        if showTimer {
            notchWingStatusLabel.isHidden = false
            notchWingStatusLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 11.5, weight: .medium)
            notchWingStatusLabel.textColor = NSColor(calibratedWhite: 0.72, alpha: 1.0)
            notchWingStatusLabel.alignment = .right
            notchWingStatusLabel.frame = NSRect(x: size.width - horizontalInset - 36, y: round(midY - 8), width: 36, height: 16)
        } else {
            notchWingStatusLabel.isHidden = true
        }

        let leadingX = horizontalInset + (showWave ? NotchWaveView.size.width + 12.0 : 32.0)
        let trailingReserve: CGFloat = showTimer ? 44.0 : 0.0
        let labelWidth = max(0, size.width - leadingX - horizontalInset - trailingReserve)
        let font = NSFont.systemFont(ofSize: NotchMetrics.fontSize, weight: .medium)
        let textHeight = ceil(font.ascender - font.descender + font.leading)

        statusLabel.isHidden = false
        statusLabel.maximumNumberOfLines = 1
        statusLabel.cell?.wraps = false
        statusLabel.cell?.isScrollable = false
        statusLabel.usesSingleLineMode = true
        statusLabel.font = font
        statusLabel.alignment = .left
        statusLabel.lineBreakMode = hasNotchLiveInterimText ? .byTruncatingHead : .byTruncatingTail
        if currentState == .recording && !hasNotchLiveInterimText && microphoneFeedbackState != .hidden {
            statusLabel.textColor = NSColor(calibratedRed: 1.0, green: 0.78, blue: 0.36, alpha: 0.96)
        } else if case .error = currentState {
            statusLabel.textColor = .systemOrange
        } else {
            statusLabel.textColor = NSColor(calibratedWhite: 0.96, alpha: 1.0)
        }
        statusLabel.frame = NSRect(x: leadingX, y: round(midY - textHeight / 2.0), width: labelWidth, height: textHeight)
        let measured = ceil((statusLabel.stringValue as NSString).size(withAttributes: [.font: font]).width)
        updateNotchStatusFadeMask(enabled: hasNotchLiveInterimText && measured > labelWidth, width: labelWidth, height: textHeight)
    }

    private func configureNotchRightWing(minX: CGFloat, maxX: CGFloat, midY: CGFloat) {
        let wingWidth = max(0, maxX - minX)
        guard wingWidth >= 32 else {
            notchWingDot.isHidden = true
            notchWingStatusLabel.isHidden = true
            return
        }

        let dotSize: CGFloat = 6
        let dotColor: NSColor
        let labelText: String
        let labelColor: NSColor
        var useMonospace = false

        switch currentState {
        case .preparing:
            dotColor = NSColor(calibratedWhite: 0.85, alpha: 0.65)
            labelText = "Hazır"
            labelColor = NSColor(calibratedWhite: 0.74, alpha: 1.0)
        case .recording:
            let elapsed = recordingSessionStartedAt > 0
                ? max(0, ProcessInfo.processInfo.systemUptime - recordingSessionStartedAt)
                : 0
            if currentAccentMode == .translation {
                dotColor = NSColor(calibratedRed: 0.45, green: 0.78, blue: 1.0, alpha: 1.0)
            } else if microphoneFeedbackState != .hidden && !hasNotchLiveInterimText {
                dotColor = NSColor.systemOrange
            } else {
                dotColor = NSColor(calibratedRed: 0.98, green: 0.80, blue: 0.42, alpha: 1.0)
            }
            if elapsed >= 5.0 {
                let sec = Int(elapsed)
                labelText = String(format: "%d:%02d", sec / 60, sec % 60)
                labelColor = NSColor(calibratedWhite: 0.90, alpha: 1.0)
                useMonospace = true
            } else if hasNotchLiveInterimText {
                labelText = "Canlı"
                labelColor = NSColor(calibratedRed: 0.98, green: 0.88, blue: 0.66, alpha: 0.95)
            } else if microphoneFeedbackState != .hidden {
                labelText = "Sessiz"
                labelColor = NSColor(calibratedRed: 1.0, green: 0.78, blue: 0.36, alpha: 0.95)
            } else {
                labelText = currentAccentMode == .translation ? "Çeviri" : "Dinliyor"
                labelColor = NSColor(calibratedWhite: 0.86, alpha: 1.0)
            }
        case .transcribing:
            dotColor = currentAccentMode == .translation
                ? NSColor(calibratedRed: 0.56, green: 0.68, blue: 1.0, alpha: 1.0)
                : NSColor(calibratedRed: 0.36, green: 0.70, blue: 1.0, alpha: 1.0)
            labelText = "Yazılıyor"
            labelColor = NSColor(calibratedRed: 0.74, green: 0.89, blue: 1.0, alpha: 1.0)
        case .success:
            dotColor = .systemGreen
            labelText = "Tamam"
            labelColor = .systemGreen
        case .notice:
            dotColor = .systemYellow
            labelText = "Bilgi"
            labelColor = .systemYellow
        case .error:
            dotColor = .systemOrange
            labelText = "Hata"
            labelColor = .systemOrange
        case .idle:
            dotColor = .clear
            labelText = ""
            labelColor = .clear
        }

        notchWingDot.isHidden = labelText.isEmpty
        notchWingStatusLabel.isHidden = labelText.isEmpty
        guard !labelText.isEmpty else { return }

        notchWingDot.layer?.backgroundColor = dotColor.cgColor
        notchWingDot.frame = NSRect(x: round(maxX - dotSize), y: round(midY - dotSize / 2.0), width: dotSize, height: dotSize)

        let labelFont = useMonospace
            ? NSFont.monospacedDigitSystemFont(ofSize: 11.5, weight: .medium)
            : NSFont.systemFont(ofSize: 11.5, weight: .medium)
        notchWingStatusLabel.font = labelFont
        notchWingStatusLabel.textColor = labelColor
        if notchWingStatusLabel.stringValue != labelText {
            notchWingStatusLabel.stringValue = labelText
        }
        let labelMaxW = max(0, maxX - dotSize - 6.0 - minX)
        notchWingStatusLabel.frame = NSRect(
            x: round(minX),
            y: round(midY - 8.0),
            width: round(labelMaxW),
            height: 16
        )
    }

    private func updateNotchStatusFadeMask(enabled: Bool, width: CGFloat, height: CGFloat) {
        statusLabel.wantsLayer = true
        guard enabled, width > 40, height > 0 else {
            statusLabel.layer?.mask = nil
            return
        }
        let mask = notchStatusFadeMask ?? {
            let gradient = CAGradientLayer()
            gradient.colors = [
                NSColor.clear.cgColor,
                NSColor.black.cgColor,
                NSColor.black.cgColor
            ]
            gradient.locations = [0.0, 0.12, 1.0]
            gradient.startPoint = CGPoint(x: 0.0, y: 0.5)
            gradient.endPoint = CGPoint(x: 1.0, y: 0.5)
            self.notchStatusFadeMask = gradient
            return gradient
        }()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        mask.frame = CGRect(x: 0, y: 0, width: width, height: height)
        CATransaction.commit()
        statusLabel.layer?.mask = mask
    }

    // MARK: - Yazılıyor animasyonu (çentik)

    private var processingTimer: Timer?
    private var processingStartedAt: TimeInterval = 0

    /// Konuşma bitince çubuklar soldan sağa akan yumuşak bir dalgaya dönüşür.
    private func startProcessingAnimation() {
        guard processingTimer == nil else { return }
        processingStartedAt = ProcessInfo.processInfo.systemUptime
        animateProcessingBars()
        guard !reduceMotion else { return }
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            self?.animateProcessingBars()
        }
        RunLoop.main.add(timer, forMode: .common)
        processingTimer = timer
    }

    private func stopProcessingAnimation() {
        processingTimer?.invalidate()
        processingTimer = nil
    }

    private func animateProcessingBars() {
        notchWave.render(level: 0, mode: .processing, animated: !reduceMotion)
    }

    private func setNotchContentAlpha(_ alpha: CGFloat) {
        for view in [statusLabel, elapsedTimerLabel, notchMeterContainer, notchWingDot, notchWingStatusLabel, spinner, checkmarkLabel, errorIconLabel, noticeIconLabel] as [NSView?] {
            view?.alphaValue = alpha
        }
    }

    /// Ada kapalı çentik boyutundan tam boyuta büyür; içerik sonda belirir.
    private func animateNotchOpen() {
        guard let screen = targetScreen() else { return }
        let anchor = Self.anchor(for: screen)
        currentNotchAnchor = anchor
        let island = notchIslandFrame(anchor: anchor)
        let collapsed = notchCollapsedFrame(anchor: anchor, island: island)
        panel.alphaValue = 1
        guard !reduceMotion else {
            panel.setFrame(island, display: true)
            layoutNotchContent(for: island.size, anchor: anchor)
            setNotchContentAlpha(1)
            panel.orderFrontRegardless()
            return
        }
        panel.setFrame(collapsed, display: false)
        layoutNotchContent(for: collapsed.size, anchor: anchor)
        setNotchContentAlpha(0)
        panel.orderFrontRegardless()
        isNotchClosing = false
        frameTransition.start(duration: NotchMetrics.openDuration, update: { [weak self] progress in
            guard let self else { return }
            let p = CGFloat(Self.springOut(progress))
            let next = Self.interpolate(collapsed, island, p)
            self.panel.setFrame(next, display: true)
            self.layoutNotchContent(for: next.size, anchor: anchor)
            self.setNotchContentAlpha(max(0, min(1, (CGFloat(progress) - 0.38) / 0.45)))
        }, completion: { [weak self] in
            guard let self else { return }
            self.panel.setFrame(island, display: true)
            self.layoutNotchContent(for: island.size, anchor: anchor)
            self.setNotchContentAlpha(1)
        })
    }

    private func animateNotchClose(animated: Bool, completion: (() -> Void)?) {
        guard animated, let screen = targetScreen(), !reduceMotion, panel.isVisible else {
            frameTransition.cancel()
            isNotchClosing = false
            notchWingDot.isHidden = true
            notchWingStatusLabel.isHidden = true
            statusLabel.layer?.mask = nil
            panel.orderOut(nil)
            completion?()
            return
        }
        let anchor = Self.anchor(for: screen)
        let start = panel.frame
        let collapsed = notchCollapsedFrame(anchor: anchor, island: notchIslandFrame(anchor: anchor))
        isNotchClosing = true
        frameTransition.start(duration: NotchMetrics.closeDuration, update: { [weak self] progress in
            guard let self else { return }
            let p = CGFloat(IslandTween.easeOut(progress))
            self.setNotchContentAlpha(max(0, 1 - CGFloat(progress) * 2.8))
            let next = Self.interpolate(start, collapsed, p)
            self.panel.setFrame(next, display: true)
        }, completion: { [weak self] in
            guard let self else { return }
            self.isNotchClosing = false
            self.notchWingDot.isHidden = true
            self.notchWingStatusLabel.isHidden = true
            self.statusLabel.layer?.mask = nil
            self.panel.orderOut(nil)
            completion?()
        })
    }

    /// Yumuşak aşmalı Dynamic Island yay eğrisi (~%3.5 nazik oturma).
    private static func springOut(_ t: Double) -> Double {
        let c1 = 0.45, c3 = c1 + 1
        let x = t - 1
        return 1 + c3 * x * x * x + c1 * x * x
    }

    private static func interpolate(_ a: CGRect, _ b: CGRect, _ p: CGFloat) -> CGRect {
        CGRect(x: round(a.minX + (b.minX - a.minX) * p),
               y: round(a.minY + (b.minY - a.minY) * p),
               width: round(a.width + (b.width - a.width) * p),
               height: round(a.height + (b.height - a.height) * p))
    }

    /// Durum mesajları normal kısa HUD metninden uzun olabilir. Sabit genişlikte
    /// kesmek yerine kapsülü okunabilir metin kadar büyütür; çok uzun canlı
    /// önizlemeleri yine makul bir üst sınırda tutar.
    private func widthForStatusText(_ text: String, maxWidth: CGFloat = 360.0) -> CGFloat {
        let font = statusLabel.font ?? NSFont.systemFont(ofSize: 12, weight: .medium)
        let textWidth = ceil((text as NSString).size(withAttributes: [.font: font]).width)
        return min(max(hudWidth, textWidth + 64.0), maxWidth)
    }

    private func updateRecordingLayout(animated: Bool) {
        precondition(Thread.isMainThread)
        let statusFont = statusLabel.font ?? NSFont.systemFont(ofSize: 12, weight: .medium)
        let statusTextWidth = ceil((statusLabel.stringValue as NSString).size(withAttributes: [.font: statusFont]).width)
        let warningTextWidth: CGFloat? = microphoneFeedbackState == .hidden ? nil : 24.0
        let availableWidth = targetScreen()?.visibleFrame.width ?? 800.0
        let layout = RecordingHUDLayout.calculate(
            statusTextWidth: min(statusTextWidth, 456.0),
            warningTextWidth: warningTextWidth,
            availableScreenWidth: availableWidth
        )
        guard layout != currentRecordingLayout else { return }
        currentRecordingLayout = layout
        updatePosition(width: layout.panelWidth, layout: layout, animated: animated)
    }

    public func warm() {
        precondition(Thread.isMainThread)
        panel.contentView?.layoutSubtreeIfNeeded()
        panel.contentView?.displayIfNeeded()
    }

    private func executeOnMainThread(_ block: @escaping () -> Void) {
        if Thread.isMainThread {
            block()
        } else {
            DispatchQueue.main.async(execute: block)
        }
    }

    /// HUD'yi uygulamanın etkinlik durumundan bağımsız olarak görünür yapar.
    /// Hata veya başarı doğrudan ilk durum olarak gelirse panel başlangıçta
    /// `orderOut` ve saydam olduğundan bu çağrı olmadan kullanıcıya görünmez.
    private func reveal(flushImmediately: Bool = false) {
        let wasVisible = panel.isVisible
        if placement == .notch {
            visibilityTransition.cancel()
            if !wasVisible {
                presentationCount &+= 1
                animateNotchOpen()
            } else {
                panel.alphaValue = 1
                if let screen = targetScreen() {
                    updateNotchPosition(screen: screen, animated: true)
                }
            }
            return
        }

        let timing = HUDRevealTiming.resolve(
            isAlreadyVisible: wasVisible,
            currentAlpha: Double(panel.alphaValue),
            reduceMotion: reduceMotion
        )
        if !wasVisible {
            presentationCount &+= 1
            panel.alphaValue = CGFloat(timing.initialAlpha)
        }
        panel.orderFrontRegardless()
        panel.contentView?.displayIfNeeded()
        panel.displayIfNeeded()
        if flushImmediately {
            CATransaction.flush()
        }

        let startAlpha = panel.alphaValue
        visibilityTransition.start(duration: timing.duration) { [weak self] progress in
            self?.panel.alphaValue = startAlpha + (1 - startAlpha) * progress
        }
    }

    // MARK: - Hazırlanıyor

    public func showPreparing() {
        executeOnMainThread { [weak self] in
            guard let self else { return }
            self.cancelDemoPreviewIfNeeded()
            self.cancelDismissTimer()
            self.stopMeterTimer()
            self.stopPulseAnimation()
            self.endLowInputWarningSession()
            self.recordingSessionStartedAt = 0
            self.elapsedTimerLabel.isHidden = true
            self.currentState = .preparing
            self.currentRecordingLayout = nil

            self.pulsingDot.isHidden = true
            self.waveformContainer.isHidden = true
            self.checkmarkLabel.isHidden = true
            self.errorIconLabel.isHidden = true
            self.noticeIconLabel.isHidden = true
            self.notchWave.reset()
            self.notchWave.render(level: 0, mode: .preparing, animated: !self.reduceMotion)
            self.dotScopeView.reset(reduceMotion: self.reduceMotion)
            self.syncDotScopeStyling()
            self.spinner.stopAnimation(nil)
            self.spinner.isHidden = true
            self.statusLabel.stringValue = "Hazırlanıyor…"
            self.statusLabel.lineBreakMode = .byTruncatingTail
            self.statusLabel.textColor = NSColor(white: 0.92, alpha: 1)
            self.updatePosition(width: self.hudWidth, animated: false)
            self.startHudAnimationTimer()
            self.reveal(flushImmediately: true)
        }
    }

    // MARK: - Durum 1: Dinliyor (Recording)

    public func showRecording() {
        startRecordingHUD(cancelDemo: true)
    }

    private func startRecordingHUD(cancelDemo: Bool) {
        executeOnMainThread { [weak self] in
            guard let self else { return }
            if cancelDemo {
                self.cancelDemoPreviewIfNeeded()
            }
            self.cancelDismissTimer()
            self.currentState = .recording
            self.recordingSessionStartedAt = ProcessInfo.processInfo.systemUptime
            self.elapsedTimerLabel.isHidden = true

            self.currentRecordingLayout = nil

            // Görünürlükleri ayarla
            self.pulsingDot.isHidden = false
            self.waveformContainer.isHidden = false
            self.isAudioReactiveSpeaking = false
            // Yeni oturum: çentik ekolayzırı sessizlikten başlar, aksi halde
            // önceki dikteden kalan seviyeyle açılırdı.
            self.notchSmoothedLevel = 0.0
            self.notchLastTick = nil
            self.notchWave.reset()
            self.dotScopeView.reset(reduceMotion: self.reduceMotion)
            self.syncDotScopeStyling()
            self.resetSpeakingIndicatorLayer()
            self.spinner.stopAnimation(nil)
            self.spinner.isHidden = true
            self.checkmarkLabel.isHidden = true
            self.errorIconLabel.isHidden = true
            self.noticeIconLabel.isHidden = true

            self.statusLabel.stringValue = "Dinliyor..."
            self.statusLabel.lineBreakMode = .byTruncatingTail
            self.statusLabel.textColor = .white
            self.beginLowInputWarningSession(at: ProcessInfo.processInfo.systemUptime)
            self.updateRecordingLayout(animated: true)

            self.startPulseAnimation()
            self.startMeterTimer()
            self.startHudAnimationTimer()

            self.reveal()
        }
    }

    /// Canlı ses akışı sırasında (örn: Gemini Live) tanınan kelimeleri
    /// kullanıcı daha konuşurken anlık olarak gösterge kapsülünde gösterir.
    public func updateInterimText(_ text: String) {
        executeOnMainThread { [weak self] in
            guard let self = self else { return }
            guard self.currentState == .recording || self.currentState == .transcribing else { return }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }

            self.statusLabel.stringValue = trimmed
            self.statusLabel.textColor = .white
            self.statusLabel.lineBreakMode = .byTruncatingHead

            self.microphoneFeedbackTracker.markRecognizedSpeech()
            self.applyMicrophoneFeedbackState(.hidden, animated: true, announce: false)

            if self.placement == .notch {
                self.updatePosition(animated: true)
            } else {
                self.updateRecordingLayout(animated: true)
            }
        }
    }

    // MARK: - Durum 2: Deşifre Ediliyor (Transcribing)

    public func showTranscribing() {
        startTranscribingHUD(cancelDemo: true)
    }

    private func startTranscribingHUD(cancelDemo: Bool) {
        executeOnMainThread { [weak self] in
            guard let self = self else { return }
            if cancelDemo {
                self.cancelDemoPreviewIfNeeded()
            }
            self.cancelDismissTimer()
            self.stopMeterTimer()
            self.stopPulseAnimation()
            self.recordingSessionStartedAt = 0
            self.elapsedTimerLabel.isHidden = true
            self.currentState = .transcribing
            self.endLowInputWarningSession()

            self.pulsingDot.isHidden = true
            self.waveformContainer.isHidden = true
            self.checkmarkLabel.isHidden = true
            self.errorIconLabel.isHidden = true
            self.noticeIconLabel.isHidden = true

            self.spinner.stopAnimation(nil)
            self.spinner.isHidden = true
            self.syncDotScopeStyling()

            if self.statusLabel.stringValue == "Dinliyor..." || self.statusLabel.stringValue.isEmpty {
                self.statusLabel.stringValue = "Yazılıyor..."
                self.statusLabel.lineBreakMode = .byTruncatingTail
                self.statusLabel.textColor = NSColor(white: 0.95, alpha: 1.0)
                self.updatePosition(width: self.hudWidth)
            } else {
                // Eğer canlı ara metin ekrandaysa metni koru, fakat kayıt uyarısı
                // için genişleyen alanı status-only genişliğine geri döndür.
                self.statusLabel.textColor = NSColor(white: 0.95, alpha: 1.0)
                self.updatePosition(width: self.widthForStatusText(self.statusLabel.stringValue, maxWidth: 520.0))
            }

            self.startHudAnimationTimer()
            self.reveal()
        }
    }

    // MARK: - Durum 3: Başarı / Yapıştırıldı (Success)

    public func showSuccess(text: String = "Yapıştırıldı", autoDismissDelay: TimeInterval = 0.35, completion: (() -> Void)? = nil) {
        executeOnMainThread { [weak self] in
            guard let self = self else { return }
            self.cancelDismissTimer()
            self.stopMeterTimer()
            self.stopPulseAnimation()
            self.recordingSessionStartedAt = 0
            self.elapsedTimerLabel.isHidden = true
            self.currentState = .success
            self.endLowInputWarningSession()

            self.statusLabel.lineBreakMode = .byTruncatingTail
            self.statusLabel.stringValue = text
            self.syncDotScopeStyling()
            self.updatePosition(width: self.widthForStatusText(text))

            self.pulsingDot.isHidden = true
            self.waveformContainer.isHidden = true
            self.spinner.stopAnimation(nil)
            self.spinner.isHidden = true
            self.errorIconLabel.isHidden = true
            self.noticeIconLabel.isHidden = true

            self.checkmarkLabel.isHidden = self.placement == .compact
            self.statusLabel.textColor = .systemGreen
            self.startHudAnimationTimer()
            self.reveal()

            let timer = Timer(timeInterval: autoDismissDelay, repeats: false) { [weak self] _ in
                self?.dismiss(animated: true, completion: completion)
            }
            RunLoop.main.add(timer, forMode: .common)
            self.dismissTimer = timer
        }
    }

    // MARK: - Bilgilendirme Durumu (Notice)

    public func showNotice(message: String = "Ses algılanmadı", autoDismissDelay: TimeInterval = 1.6) {
        executeOnMainThread { [weak self] in
            guard let self = self else { return }
            self.cancelDemoPreviewIfNeeded()
            self.cancelDismissTimer()
            self.stopMeterTimer()
            self.stopPulseAnimation()
            self.spinner.stopAnimation(nil)
            self.recordingSessionStartedAt = 0
            self.elapsedTimerLabel.isHidden = true
            self.currentState = .notice(message)
            self.endLowInputWarningSession()

            self.pulsingDot.isHidden = true
            self.waveformContainer.isHidden = true
            self.spinner.isHidden = true
            self.checkmarkLabel.isHidden = true
            self.errorIconLabel.isHidden = true
            self.noticeIconLabel.isHidden = false

            self.statusLabel.lineBreakMode = .byTruncatingTail
            self.statusLabel.stringValue = message
            // Bilgilendirme metni beyaz kalır; sarı yalnızca simgede kullanılır.
            self.statusLabel.textColor = NSColor(white: 0.95, alpha: 1.0)
            self.syncDotScopeStyling()
            self.updatePosition(width: self.widthForStatusText(message))
            self.stopHudAnimationTimer()
            self.reveal()

            let timer = Timer(timeInterval: autoDismissDelay, repeats: false) { [weak self] _ in
                self?.dismiss(animated: true)
            }
            RunLoop.main.add(timer, forMode: .common)
            self.dismissTimer = timer
        }
    }

    // MARK: - Hata Durumu (Error)

    public func showError(message: String = "Hata!", autoDismissDelay: TimeInterval = 1.0) {
        executeOnMainThread { [weak self] in
            guard let self = self else { return }
            self.cancelDemoPreviewIfNeeded()
            self.cancelDismissTimer()
            self.stopMeterTimer()
            self.stopPulseAnimation()
            self.recordingSessionStartedAt = 0
            self.elapsedTimerLabel.isHidden = true
            self.currentState = .error(message)
            self.endLowInputWarningSession()

            self.statusLabel.lineBreakMode = .byTruncatingTail
            self.statusLabel.stringValue = message
            self.statusLabel.textColor = .systemOrange
            self.syncDotScopeStyling()
            self.updatePosition(width: self.widthForStatusText(message))

            self.pulsingDot.isHidden = true
            self.waveformContainer.isHidden = true
            self.spinner.stopAnimation(nil)
            self.spinner.isHidden = true
            self.checkmarkLabel.isHidden = true
            self.noticeIconLabel.isHidden = true

            self.errorIconLabel.isHidden = false
            self.stopHudAnimationTimer()
            self.reveal()

            let timer = Timer(timeInterval: autoDismissDelay, repeats: false) { [weak self] _ in
                self?.dismiss(animated: true)
            }
            RunLoop.main.add(timer, forMode: .common)
            self.dismissTimer = timer
        }
    }

    // MARK: - Kapatma (Dismiss)

    public func dismiss(animated: Bool = true, completion: (() -> Void)? = nil) {
        executeOnMainThread { [weak self] in
            guard let self = self else { return }
            self.cancelDemoPreviewIfNeeded()
            self.cancelDismissTimer()
            self.stopMeterTimer()
            self.stopHudAnimationTimer()
            self.stopPulseAnimation()
            self.spinner.stopAnimation(nil)
            self.recordingSessionStartedAt = 0
            self.elapsedTimerLabel.isHidden = true
            self.currentState = .idle
            self.notchShapeView.rimGlowIntensity = 0.0
            self.endLowInputWarningSession()

            self.stopProcessingAnimation()
            if self.placement == .notch {
                self.visibilityTransition.cancel()
                self.animateNotchClose(animated: animated, completion: completion)
                return
            }
            self.frameTransition.cancel()
            let startAlpha = self.panel.alphaValue
            self.visibilityTransition.start(
                duration: animated && self.panel.isVisible && !self.reduceMotion ? 0.18 : 0,
                update: { [weak self] progress in
                    self?.panel.alphaValue = startAlpha * (1 - progress)
                }, completion: { [weak self] in
                    self?.panel.orderOut(nil)
                    completion?()
                }
            )
        }
    }

    private func cancelDismissTimer() {
        dismissTimer?.invalidate()
        dismissTimer = nil
    }

    // MARK: - Animasyon ve Ses Seviyesi (Metering)

    func finishPresentationTransitions() {
        frameTransition.finish()
        visibilityTransition.finish()
    }

    /// Ayar dosyası dışarıdan değiştiğinde çağrılır.
    ///
    /// Gösterge görünürse yerleşimi hemen yeniden uygular, böylece stil
    /// değişikliği (kapsül ↔ çentik) anında görünür. Görünmüyorsa bir
    /// sonraki gösterim zaten yeni ayarı okuyacaktır.
    @objc private func handleConfigReload() {
        executeOnMainThread { [weak self] in
            guard let self, self.panel?.isVisible == true else { return }
            self.updatePosition(animated: true)
        }
    }

    @objc private func accessibilityDisplayChanged() {
        if reduceMotion {
            finishPresentationTransitions()
            stopPulseAnimation()
            microphoneFeedbackBadge.layer?.removeAnimation(forKey: "microphoneFeedback")
        } else if currentState == .recording {
            startPulseAnimation()
            if microphoneFeedbackState != .hidden {
                startMicrophoneFeedbackAnimation(for: microphoneFeedbackState)
            }
        }
    }

    private func startPulseAnimation() {
        guard !reduceMotion, !isAudioReactiveSpeaking else { return }
        pulsingDot.layer?.removeAnimation(forKey: "pulse")

        // Opacity'i sertçe açıp kapatmak yerine küçük bir nefes/scale hareketi.
        // Bu, daha premium görünür ve komşu metnin dikkatini bölmez.
        let scale = CABasicAnimation(keyPath: "transform.scale")
        scale.fromValue = 1.0
        scale.toValue = 1.10
        scale.duration = 1.05

        let opacity = CABasicAnimation(keyPath: "opacity")
        opacity.fromValue = 0.82
        opacity.toValue = 1.0
        opacity.duration = 1.05

        let pulse = CAAnimationGroup()
        pulse.animations = [scale, opacity]
        pulse.duration = 1.05
        pulse.autoreverses = true
        pulse.repeatCount = .infinity
        pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        pulsingDot.layer?.add(pulse, forKey: "pulse")
    }

    private func stopPulseAnimation() {
        pulsingDot.layer?.removeAnimation(forKey: "pulse")
        resetSpeakingIndicatorLayer()
    }

    private func resetSpeakingIndicatorLayer() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        pulsingDot.layer?.opacity = 1.0
        pulsingDot.layer?.setAffineTransform(.identity)
        CATransaction.commit()
    }

    /// Kırmızı nokta sessizlikte düşük maliyetli nefes animasyonu yapar; gerçek
    /// ses geldiğinde animasyonu bırakıp ses seviyesine göre yalnızca layer'ı
    /// ölçekler. Böylece kullanıcı, ilk interim metni gelmeden de konuştuğunu
    /// görsel olarak hemen anlar.
    private func updateSpeakingIndicator(power: Float) {
        if reduceMotion {
            isAudioReactiveSpeaking = false
            pulsingDot.layer?.removeAnimation(forKey: "pulse")
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            pulsingDot.layer?.setAffineTransform(.identity)
            pulsingDot.layer?.opacity = Self.reducedMotionAudioOpacity(level: smoothedAudioLevel)
            CATransaction.commit()
            return
        }
        let speakingLevel = max(0.0, min(1.0, CGFloat((power + 60.0) / 45.0)))
        let isSpeaking = speakingLevel >= 0.08

        if isSpeaking {
            if !isAudioReactiveSpeaking {
                isAudioReactiveSpeaking = true
                pulsingDot.layer?.removeAnimation(forKey: "pulse")
            }

            let scale = 1.0 + min(0.16, speakingLevel * 0.16)
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            pulsingDot.layer?.opacity = Float(0.84 + speakingLevel * 0.16)
            pulsingDot.layer?.setAffineTransform(CGAffineTransform(scaleX: scale, y: scale))
            CATransaction.commit()
        } else if isAudioReactiveSpeaking {
            isAudioReactiveSpeaking = false
            resetSpeakingIndicatorLayer()
            startPulseAnimation()
        }
    }

    private func startMeterTimer() {
        meterTimer?.invalidate()
        // 60 FPS: dalga sese gecikmesiz tepki versin (yumuşatma zamana bağlı).
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            self?.updateWaveform()
        }
        RunLoop.main.add(timer, forMode: .common)
        meterTimer = timer
    }

    private func stopMeterTimer() {
        meterTimer?.invalidate()
        meterTimer = nil
        smoothedAudioLevel = 0.0
    }

    /// Kayıt oturumu, uyarı zaman çizelgesinin tek sahibidir. Timer yönetimi
    /// tracker'ı sıfırlamaz; yeniden tetikleme dwell süresini buradan başlatır.
    func beginLowInputWarningSession(at time: TimeInterval) {
        precondition(Thread.isMainThread)
        microphoneFeedbackTracker.reset(at: time)
        applyMicrophoneFeedbackState(.hidden, animated: false, announce: false)
    }

    private func endLowInputWarningSession() {
        precondition(Thread.isMainThread)
        applyMicrophoneFeedbackState(.hidden, animated: false, announce: false)
        currentRecordingLayout = nil
    }

    func updateLowInputWarning(power: Float, at time: TimeInterval) {
        precondition(Thread.isMainThread)
        guard currentState == .recording else { return }

        let nextState = microphoneFeedbackTracker.update(power: power, at: time)
        applyMicrophoneFeedbackState(nextState, animated: true, announce: true)
    }

    private func applyMicrophoneFeedbackState(
        _ state: MicrophoneFeedbackState,
        animated: Bool,
        announce: Bool
    ) {
        let previousState = microphoneFeedbackState
        guard previousState != state else { return }
        microphoneFeedbackState = state
        isLowInputWarningVisible = state != .hidden
        microphoneFeedbackBadge.isHidden = state == .hidden

        if state == .hidden {
            microphoneFeedbackBadge.alphaValue = 0
            microphoneFeedbackBadge.layer?.removeAnimation(forKey: "microphoneFeedback")
        } else {
            configureMicrophoneFeedbackBadge(for: state)
            if previousState != state || microphoneFeedbackBadge.layer?.animation(forKey: "microphoneFeedback") == nil {
                startMicrophoneFeedbackAnimation(for: state)
            }
        }

        if currentState == .recording {
            if placement == .notch {
                updatePosition(animated: animated)
            } else {
                updateRecordingLayout(animated: animated)
            }
        }
        guard announce else { return }
        switch state {
        case .hidden:
            break
        case .waitingForVoice:
            lowInputAnnouncementHandler(MicrophoneFeedbackTracker.waitingAnnouncementText)
        case .lowLevel:
            lowInputAnnouncementHandler(MicrophoneFeedbackTracker.lowLevelAnnouncementText)
        }
    }

    private func configureMicrophoneFeedbackBadge(for state: MicrophoneFeedbackState) {
        let symbolName: String
        let fallbackSymbolName: String
        let accessibilityLabel: String
        let accessibilityHelp: String
        let accentColor: NSColor
        switch state {
        case .hidden:
            return
        case .waitingForVoice:
            symbolName = "mic.fill"
            fallbackSymbolName = "mic"
            accessibilityLabel = MicrophoneFeedbackTracker.waitingText
            accessibilityHelp = "Konuşmaya başlayın veya mikrofonu kontrol edin."
            accentColor = .systemTeal
        case .lowLevel:
            symbolName = "waveform.badge.exclamationmark"
            fallbackSymbolName = "exclamationmark.triangle.fill"
            accessibilityLabel = MicrophoneFeedbackTracker.lowLevelText
            accessibilityHelp = "Mikrofona yaklaşın veya giriş ses düzeyini artırın."
            accentColor = .systemOrange
        }

        let configuration = NSImage.SymbolConfiguration(pointSize: 12, weight: .semibold)
        let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: accessibilityLabel)
            ?? NSImage(systemSymbolName: fallbackSymbolName, accessibilityDescription: accessibilityLabel)
            ?? NSImage(named: NSImage.cautionName)
        microphoneFeedbackImageView.image = image?.withSymbolConfiguration(configuration)
        microphoneFeedbackImageView.contentTintColor = accentColor
        microphoneFeedbackBadge.layer?.backgroundColor = accentColor.withAlphaComponent(0.16).cgColor
        microphoneFeedbackBadge.layer?.borderColor = accentColor.withAlphaComponent(0.42).cgColor
        microphoneFeedbackBadge.layer?.shadowColor = accentColor.cgColor
        microphoneFeedbackBadge.layer?.shadowOpacity = state == .waitingForVoice ? 0.14 : 0.22
        microphoneFeedbackBadge.setAccessibilityLabel(accessibilityLabel)
        microphoneFeedbackBadge.setAccessibilityHelp(accessibilityHelp)
    }

    private func startMicrophoneFeedbackAnimation(for state: MicrophoneFeedbackState) {
        microphoneFeedbackBadge.layer?.removeAnimation(forKey: "microphoneFeedback")
        guard !reduceMotion else { return }

        let opacity = CABasicAnimation(keyPath: "opacity")
        opacity.fromValue = state == .waitingForVoice ? 0.72 : 0.68
        opacity.toValue = 1.0


        let animation = CAAnimationGroup()
        animation.animations = [opacity]
        animation.duration = state == .waitingForVoice ? 1.25 : 0.82
        animation.autoreverses = true
        animation.repeatCount = .infinity
        animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        microphoneFeedbackBadge.layer?.add(animation, forKey: "microphoneFeedback")
    }

    // Reduced Motion suppresses spatial animation, not meaningful audio feedback.
    static func reducedMotionAudioOpacity(level: CGFloat) -> Float {
        Float(0.45 + 0.55 * max(0, min(1, level)))
    }

    static func waveformLevel(power: Float) -> CGFloat {
        guard power.isFinite else { return 0 }
        // Quiet speech should remain visible without amplifying the recorded audio.
        return max(0, min(1, CGFloat((power + 60) / 42)))
    }

    private func updateWaveform() {
        guard currentState == .recording else { return }
        if isDemoPreviewActive { return }

        let power = AudioRecorder.shared.averagePower()
        dotScopeView.pushAudioLevel(dBFS: power)
        // Çift eşikli kapı, tek bir dB eşiğinden daha güvenilir bir "konuşma
        // var mı" sinyali verir: hysteresis sayesinde kısık sesle başlayan
        // konuşma da segmenti açık tutar ve "ses algılanmadı" uyarısı
        // yanlışlıkla gösterilmez.
        let gateState = AudioRecorder.shared.speechGateState()
        if gateState != .silent {
            microphoneFeedbackTracker.markRecognizedSpeech()
            applyMicrophoneFeedbackState(.hidden, animated: true, announce: false)
        }
        updateLowInputWarning(power: power, at: ProcessInfo.processInfo.systemUptime)
        let rawNormalized = Self.waveformLevel(power: power)

        // Üstel yumuşatma (EMA): Ses yükselirken hızlı reaksiyon, düşerken yumuşak iniş
        if rawNormalized > smoothedAudioLevel {
            smoothedAudioLevel = smoothedAudioLevel * 0.40 + rawNormalized * 0.60
        } else {
            smoothedAudioLevel = smoothedAudioLevel * 0.82 + rawNormalized * 0.18
        }

        // This is a live measurement, not a decorative looping animation.
        let level = smoothedAudioLevel < 0.03 ? 0.0 : smoothedAudioLevel
        updateSpeakingIndicator(power: power)

        let maxHeight: CGFloat = 13.0
        let minHeight: CGFloat = 2.5

        // A balanced silhouette of the same RMS level, not separate frequency bands.
        let multipliers: [CGFloat] = [0.65, 1.10, 1.10, 0.65]

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (i, bar) in waveformBars.enumerated() {
            let mult = multipliers[i % multipliers.count]
            var h = minHeight + (maxHeight - minHeight) * level * mult
            h = max(minHeight, min(maxHeight, h))
            bar.layer?.setAffineTransform(CGAffineTransform(scaleX: 1.0, y: h / maxHeight))
            bar.layer?.opacity = reduceMotion
                ? Self.reducedMotionAudioOpacity(level: smoothedAudioLevel * mult)
                : 1.0
        }

        // Çentik dalgası aynı ses seviyesini zaman tabanlı yumuşatmayla izler.
        let now = ProcessInfo.processInfo.systemUptime
        let dt = notchLastTick.map { max(0.0, now - $0) } ?? (1.0 / 30.0)
        notchLastTick = now
        notchSmoothedLevel = NotchAudioMeter.smooth(
            level: notchSmoothedLevel,
            target: smoothedAudioLevel,
            dt: dt
        )
        let notchLevel = notchSmoothedLevel

        notchWave.render(level: notchLevel, mode: .listening, animated: !reduceMotion)
        if placement == .notch {
            notchShapeView.rimGlowColor = currentAccentMode == .translation
                ? NSColor(calibratedRed: 0.45, green: 0.78, blue: 1.0, alpha: 1.0)
                : NSColor(calibratedRed: 0.96, green: 0.86, blue: 0.65, alpha: 1.0)
            notchShapeView.rimGlowIntensity = 0.14 + 0.72 * notchLevel
            if !notchWingDot.isHidden && !reduceMotion {
                let scale = 1.0 + min(0.28, notchLevel * 0.28)
                notchWingDot.layer?.setAffineTransform(CGAffineTransform(scaleX: scale, y: scale))
                notchWingDot.layer?.opacity = Float(0.76 + min(0.24, notchLevel * 0.24))
            }
        }
        CATransaction.commit()
    }
}
