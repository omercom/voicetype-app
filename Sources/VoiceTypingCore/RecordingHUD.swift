import Foundation
import AppKit

public enum HUDState: Equatable {
    case idle
    case recording
    case transcribing
    case success
    case error(String)
}

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
    public var isVisible: Bool {
        return panel.isVisible && panel.alphaValue > 0.05
    }

    private var panel: FloatingHUDPanel!
    private var visualEffectView: NSVisualEffectView!
    private var darkTintView: NSBox!
    private var statusLabel: NSTextField!

    // Göstergeler (Ultra Minimal & Orantılı)
    private var pulsingDot: NSView!
    private var waveformContainer: NSView!
    private var waveformBars: [NSView] = []
    private var spinner: NSProgressIndicator!
    private var checkmarkLabel: NSTextField!
    private var errorIconLabel: NSTextField!

    // Zamanlayıcılar & Animasyonlar
    private var meterTimer: Timer?
    private var dismissTimer: Timer?

    // Orantılı Minimal Kapsül Ölçüleri
    private let hudWidth: CGFloat = 152.0
    private let hudHeight: CGFloat = 34.0

    private override init() {
        super.init()
        buildHUD()
    }

    private func buildHUD() {
        panel = FloatingHUDPanel(
            contentRect: NSRect(x: 0, y: 0, width: hudWidth, height: hudHeight),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        panel.isFloatingPanel = true
        panel.level = .floating
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
        visualEffectView.layer?.borderWidth = 0.5
        visualEffectView.layer?.borderColor = NSColor.white.withAlphaComponent(0.14).cgColor
        contentView.addSubview(visualEffectView)

        // 2. Yarı saydam koyu katman (Yüksek kontrast & Dynamic Island hissi)
        darkTintView = NSBox(frame: contentView.bounds)
        darkTintView.autoresizingMask = [.width, .height]
        darkTintView.boxType = .custom
        darkTintView.borderWidth = 0
        darkTintView.cornerRadius = cornerRadius
        darkTintView.fillColor = NSColor.black.withAlphaComponent(0.38)
        contentView.addSubview(darkTintView)

        // 3. Sol Gösterge Alanı: Kırmızı Nokta + Dalga Çubukları
        let indicatorArea = NSView(frame: NSRect(x: 13, y: (hudHeight - 14) / 2.0, width: 28, height: 14))
        indicatorArea.wantsLayer = true
        contentView.addSubview(indicatorArea)

        // 3a. Yanıp Sönen Kırmızı Kayıt Noktası (Pulsing Red Dot - 6px)
        pulsingDot = NSView(frame: NSRect(x: 0, y: 4, width: 6, height: 6))
        pulsingDot.wantsLayer = true
        pulsingDot.layer?.cornerRadius = 3.0
        pulsingDot.layer?.backgroundColor = NSColor(red: 1.0, green: 0.23, blue: 0.20, alpha: 1.0).cgColor
        indicatorArea.addSubview(pulsingDot)

        // 3b. Dinamik 3'lü Ses Dalga Çubukları (Micro Waveform Bars - Kırmızı nokta ile arası 8px ferah boşluk)
        waveformContainer = NSView(frame: NSRect(x: 14, y: 0, width: 12, height: 14))
        waveformContainer.wantsLayer = true
        indicatorArea.addSubview(waveformContainer)

        let barWidth: CGFloat = 2.0
        let spacing: CGFloat = 2.0
        for i in 0..<3 {
            let bar = NSView()
            bar.wantsLayer = true
            bar.layer?.cornerRadius = barWidth / 2.0
            // Çok hafif grimsi beyaz (Soft Grayish-White / Silver)
            bar.layer?.backgroundColor = NSColor(white: 0.88, alpha: 0.95).cgColor
            let initialH: CGFloat = CGFloat(4 + (i % 2) * 5)
            bar.frame = NSRect(
                x: CGFloat(i) * (barWidth + spacing),
                y: (14.0 - initialH) / 2.0,
                width: barWidth,
                height: initialH
            )
            waveformContainer.addSubview(bar)
            waveformBars.append(bar)
        }

        // 4. Spinner (Deşifre Ediliyor Durumu - 14x14)
        spinner = NSProgressIndicator(frame: NSRect(x: 14, y: (hudHeight - 14) / 2.0, width: 14, height: 14))
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
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

        // 6. Durum Metni (Status Label - SF Pro 12pt Medium, Kusursuz Dikey Ortalı)
        statusLabel = NSTextField(labelWithString: "Dinliyor...")
        statusLabel.frame = NSRect(x: 48, y: (hudHeight - 16) / 2.0 - 0.5, width: 95, height: 16)
        statusLabel.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        statusLabel.textColor = .white
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.alignment = .left
        contentView.addSubview(statusLabel)
    }

    // MARK: - Ekran Konumlandırma

    private func targetScreen() -> NSScreen? {
        let mouseLoc = NSEvent.mouseLocation
        if let screen = NSScreen.screens.first(where: { NSPointInRect(mouseLoc, $0.frame) }) {
            return screen
        }
        return NSScreen.main ?? NSScreen.screens.first
    }

    private func updatePosition(width: CGFloat? = nil) {
        guard let screen = targetScreen() else { return }
        let currentW = width ?? hudWidth
        let screenFrame = screen.visibleFrame
        let x = round(screenFrame.midX - (currentW / 2.0))
        let y = round(screenFrame.minY + 64.0)
        panel.setFrame(NSRect(x: x, y: y, width: currentW, height: hudHeight), display: true)
        statusLabel.frame = NSRect(x: 48, y: (hudHeight - 16) / 2.0 - 0.5, width: max(50, currentW - 56), height: 16)
    }

    private func executeOnMainThread(_ block: @escaping () -> Void) {
        if Thread.isMainThread {
            block()
        } else {
            DispatchQueue.main.async(execute: block)
        }
    }

    // MARK: - Durum 1: Dinliyor (Recording)

    public func showRecording() {
        executeOnMainThread { [weak self] in
            guard let self = self else { return }
            self.cancelDismissTimer()
            self.currentState = .recording

            self.updatePosition(width: self.hudWidth)

            // Görünürlükleri ayarla
            self.pulsingDot.isHidden = false
            self.waveformContainer.isHidden = false
            self.spinner.stopAnimation(nil)
            self.spinner.isHidden = true
            self.checkmarkLabel.isHidden = true
            self.errorIconLabel.isHidden = true

            self.statusLabel.stringValue = "Dinliyor..."
            self.statusLabel.textColor = .white

            self.startPulseAnimation()
            self.startMeterTimer()

            // Yumuşak fade-in ile göster
            self.panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.14
                self.panel.animator().alphaValue = 1.0
            }
        }
    }

    /// Kullanıcı isteği doğrultusunda gösterge kapsülü sade ve minimal tutulur;
    /// deşifre/çeviri metni indikatörün içerisine yazılmaz, kapsül genişliği ve "Dinliyor..." durumu sabit kalır.
    public func updateInterimText(_ text: String) {
        // İndikatör içerisine çevrilen/deşifre edilen metin yazılmaz, kapsül boyutu ve sade görünüm korunur.
    }

    // MARK: - Durum 2: Deşifre Ediliyor (Transcribing)

    public func showTranscribing() {
        executeOnMainThread { [weak self] in
            guard let self = self else { return }
            self.cancelDismissTimer()
            self.stopMeterTimer()
            self.stopPulseAnimation()
            self.currentState = .transcribing

            self.pulsingDot.isHidden = true
            self.waveformContainer.isHidden = true
            self.checkmarkLabel.isHidden = true
            self.errorIconLabel.isHidden = true

            self.spinner.isHidden = false
            self.spinner.startAnimation(nil)

            self.statusLabel.stringValue = "Yazılıyor..."
            self.statusLabel.textColor = NSColor(white: 0.95, alpha: 1.0)
            self.updatePosition(width: self.hudWidth)

            if !self.panel.isVisible || self.panel.alphaValue < 0.1 {
                self.updatePosition(width: self.hudWidth)
                self.panel.orderFrontRegardless()
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.14
                    self.panel.animator().alphaValue = 1.0
                }
            }
        }
    }

    // MARK: - Durum 3: Başarı / Yapıştırıldı (Success)

    public func showSuccess(text: String = "Yapıştırıldı", autoDismissDelay: TimeInterval = 0.35, completion: (() -> Void)? = nil) {
        executeOnMainThread { [weak self] in
            guard let self = self else { return }
            self.cancelDismissTimer()
            self.stopMeterTimer()
            self.stopPulseAnimation()
            self.currentState = .success

            self.updatePosition(width: self.hudWidth)

            self.pulsingDot.isHidden = true
            self.waveformContainer.isHidden = true
            self.spinner.stopAnimation(nil)
            self.spinner.isHidden = true
            self.errorIconLabel.isHidden = true

            self.checkmarkLabel.isHidden = false
            self.statusLabel.stringValue = text
            self.statusLabel.textColor = .systemGreen

            let timer = Timer(timeInterval: autoDismissDelay, repeats: false) { [weak self] _ in
                self?.dismiss(animated: true, completion: completion)
            }
            RunLoop.main.add(timer, forMode: .common)
            self.dismissTimer = timer
        }
    }

    // MARK: - Hata Durumu (Error)

    public func showError(message: String = "Hata!", autoDismissDelay: TimeInterval = 1.0) {
        executeOnMainThread { [weak self] in
            guard let self = self else { return }
            self.cancelDismissTimer()
            self.stopMeterTimer()
            self.stopPulseAnimation()
            self.currentState = .error(message)

            self.updatePosition(width: self.hudWidth)

            self.pulsingDot.isHidden = true
            self.waveformContainer.isHidden = true
            self.spinner.stopAnimation(nil)
            self.spinner.isHidden = true
            self.checkmarkLabel.isHidden = true

            self.errorIconLabel.isHidden = false
            self.statusLabel.stringValue = message
            self.statusLabel.textColor = .systemOrange

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
            self.cancelDismissTimer()
            self.stopMeterTimer()
            self.stopPulseAnimation()
            self.spinner.stopAnimation(nil)
            self.currentState = .idle

            if animated && self.panel.isVisible {
                NSAnimationContext.runAnimationGroup({ context in
                    context.duration = 0.18
                    self.panel.animator().alphaValue = 0.0
                }, completionHandler: { [weak self] in
                    guard let self = self else { return }
                    if self.currentState == .idle {
                        self.panel.orderOut(nil)
                        completion?()
                    }
                })
            } else {
                self.panel.alphaValue = 0.0
                self.panel.orderOut(nil)
                completion?()
            }
        }
    }

    private func cancelDismissTimer() {
        dismissTimer?.invalidate()
        dismissTimer = nil
    }

    // MARK: - Animasyon ve Ses Seviyesi (Metering)

    private func startPulseAnimation() {
        let pulse = CABasicAnimation(keyPath: "opacity")
        pulse.fromValue = 1.0
        pulse.toValue = 0.35
        pulse.duration = 0.65
        pulse.autoreverses = true
        pulse.repeatCount = .infinity
        pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        pulsingDot.layer?.add(pulse, forKey: "pulse")
    }

    private func stopPulseAnimation() {
        pulsingDot.layer?.removeAnimation(forKey: "pulse")
    }

    private func startMeterTimer() {
        stopMeterTimer()
        let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
            self?.updateWaveform()
        }
        RunLoop.main.add(timer, forMode: .common)
        meterTimer = timer
    }

    private func stopMeterTimer() {
        meterTimer?.invalidate()
        meterTimer = nil
    }

    private func updateWaveform() {
        guard currentState == .recording else { return }

        let power = AudioRecorder.shared.averagePower()
        let normalized = max(0.0, min(1.0, CGFloat((power + 50.0) / 45.0)))

        let barWidth: CGFloat = 2.0
        let spacing: CGFloat = 2.0
        let maxHeight: CGFloat = 13.0
        let minHeight: CGFloat = 3.5

        let multipliers: [CGFloat] = [0.85, 1.35, 1.05]
        let baseFluctuations: [CGFloat] = [1.5, 3.0, 1.5]

        for (i, bar) in waveformBars.enumerated() {
            let mult = multipliers[i % multipliers.count]
            let fluc = baseFluctuations[i % baseFluctuations.count]
            var h = minHeight + (maxHeight - minHeight) * normalized * mult + (normalized < 0.1 ? fluc : 0.0)
            h = max(minHeight, min(maxHeight, h))

            let y = (14.0 - h) / 2.0
            bar.frame = NSRect(
                x: CGFloat(i) * (barWidth + spacing),
                y: y,
                width: barWidth,
                height: h
            )
        }
    }
}
