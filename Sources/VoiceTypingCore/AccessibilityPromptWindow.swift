import Foundation
import AppKit
import ApplicationServices

public class AccessibilityPromptController: NSWindowController, NSWindowDelegate {
    public static let shared = AccessibilityPromptController()

    private var pollTimer: Timer?
    private var onGranted: (() -> Void)?
    private var actionButton: NSButton!
    private var statusLabel: NSTextField!
    private var progressIndicator: NSProgressIndicator!
    private var introLabel: NSTextField!
    private var usageLabel: NSTextField!
    private var privacyLabel: NSTextField!

    private init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 430),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Voice Typing - İzin Açıklaması"
        window.isReleasedWhenClosed = false
        window.level = .floating
        window.hidesOnDeactivate = false
        super.init(window: window)
        window.delegate = self
        setupUI()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupUI() {
        guard let window = window, let contentView = window.contentView else { return }

        // 1. İkon
        let iconView = NSImageView(frame: NSRect(x: 28, y: 329, width: 64, height: 64))
        if let appIcon = NSImage(named: NSImage.applicationIconName) {
            iconView.image = appIcon
        } else if #available(macOS 11.0, *), let symbol = NSImage(systemSymbolName: "hand.raised.fill", accessibilityDescription: nil) {
            iconView.image = symbol
            iconView.contentTintColor = .systemBlue
        }
        iconView.imageScaling = .scaleProportionallyUpOrDown
        contentView.addSubview(iconView)

        // 2. Başlık ve kısa bağlam
        let titleLabel = NSTextField(labelWithString: "Erişilebilirlik izni neden gerekli?")
        titleLabel.frame = NSRect(x: 108, y: 374, width: 420, height: 24)
        titleLabel.font = NSFont.systemFont(ofSize: 16, weight: .bold)
        titleLabel.textColor = .labelColor
        contentView.addSubview(titleLabel)

        introLabel = NSTextField(wrappingLabelWithString: "")
        introLabel.frame = NSRect(x: 108, y: 315, width: 420, height: 48)
        introLabel.font = NSFont.systemFont(ofSize: 12, weight: .regular)
        introLabel.textColor = .secondaryLabelColor
        contentView.addSubview(introLabel)

        let usageHeading = NSTextField(labelWithString: "İzin yoksa kısayol ve otomatik yazma çalışmaz. İzin şunları sağlar:")
        usageHeading.frame = NSRect(x: 32, y: 286, width: 480, height: 20)
        usageHeading.font = NSFont.systemFont(ofSize: 12, weight: .semibold)
        usageHeading.textColor = .labelColor
        contentView.addSubview(usageHeading)

        usageLabel = NSTextField(wrappingLabelWithString: "")
        usageLabel.frame = NSRect(x: 44, y: 145, width: 480, height: 134)
        usageLabel.font = NSFont.systemFont(ofSize: 11.5, weight: .regular)
        usageLabel.textColor = .secondaryLabelColor
        usageLabel.maximumNumberOfLines = 0
        contentView.addSubview(usageLabel)

        privacyLabel = NSTextField(wrappingLabelWithString: "")
        privacyLabel.frame = NSRect(x: 32, y: 82, width: 496, height: 52)
        privacyLabel.font = NSFont.systemFont(ofSize: 10.5, weight: .regular)
        privacyLabel.textColor = .tertiaryLabelColor
        privacyLabel.maximumNumberOfLines = 0
        contentView.addSubview(privacyLabel)

        // 3. Durum ve canlı izin algılama
        progressIndicator = NSProgressIndicator(frame: NSRect(x: 32, y: 56, width: 16, height: 16))
        progressIndicator.style = .spinning
        progressIndicator.controlSize = .small
        progressIndicator.isDisplayedWhenStopped = false
        contentView.addSubview(progressIndicator)

        statusLabel = NSTextField(labelWithString: "")
        statusLabel.frame = NSRect(x: 54, y: 55, width: 470, height: 20)
        statusLabel.font = NSFont.systemFont(ofSize: 11, weight: .medium)
        statusLabel.textColor = .systemOrange
        contentView.addSubview(statusLabel)

        // 4. Ayırıcı çizgi ve butonlar
        let separator = NSBox(frame: NSRect(x: 20, y: 45, width: 520, height: 1))
        separator.boxType = .separator
        contentView.addSubview(separator)

        let cancelButton = NSButton(title: "Daha Sonra", target: self, action: #selector(cancelAction))
        cancelButton.frame = NSRect(x: 320, y: 11, width: 105, height: 32)
        cancelButton.bezelStyle = .rounded
        cancelButton.keyEquivalent = "\u{1b}" // Escape
        contentView.addSubview(cancelButton)

        actionButton = NSButton(title: "Erişilebilirliği Aç", target: self, action: #selector(openSettingsAction))
        actionButton.frame = NSRect(x: 435, y: 11, width: 112, height: 32)
        actionButton.bezelStyle = .rounded
        actionButton.keyEquivalent = "\r" // Enter
        contentView.addSubview(actionButton)

        updateCopy()
    }

    public func showPrompt(onGranted: (() -> Void)? = nil) {
        let wasVisible = window?.isVisible ?? false
        if let onGranted {
            self.onGranted = onGranted
        } else if !wasVisible {
            self.onGranted = nil
        }

        // Zaten izin verilmişse pencere açmaya gerek yok
        if AXIsProcessTrusted() {
            onGranted?()
            return
        }

        guard let window = window else { return }
        updateCopy()
        if !wasVisible {
            resetForPresentation()
        }
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        startPolling()
    }

    @objc private func openSettingsAction() {
        actionButton.isEnabled = false
        actionButton.title = "Bekleniyor..."
        statusLabel.stringValue = "Sistem Ayarları açıldı: VoiceTyping anahtarını açın."
        statusLabel.textColor = .systemBlue
        progressIndicator.startAnimation(nil)

        // Sistem Ayarları penceresinin üstünü örtmemek için bu pencereyi sağ üst köşeye taşı
        if let window = window, let screen = window.screen ?? NSScreen.main {
            let visibleFrame = screen.visibleFrame
            let targetX = visibleFrame.maxX - window.frame.width - 24
            let targetY = visibleFrame.maxY - window.frame.height - 40
            let targetRect = NSRect(x: targetX, y: targetY, width: window.frame.width, height: window.frame.height)
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.35
                window.animator().setFrame(targetRect, display: true)
            }
        }

        // Erişilebilirlik ayarlarını aç
        PermissionManager.shared.openAccessibilitySettings()
    }

    @objc private func cancelAction() {
        stopPolling()
        window?.close()
    }

    private func updateCopy() {
        let triggerKeyName = AccessibilityPermissionInfo.currentTriggerKeyName
        introLabel?.stringValue = "Bu izin, VoiceTyping'in Zed, tarayıcı veya mesajlaşma uygulamasında siz yazarken çalışmasını sağlar. Ses kaydı için Mikrofon izni ayrı olarak kullanılır."
        usageLabel?.stringValue = AccessibilityPermissionInfo.usageDescription(triggerKeyName: triggerKeyName)
        privacyLabel?.stringValue = AccessibilityPermissionInfo.privacyNotice
    }

    private func resetForPresentation() {
        actionButton?.isEnabled = true
        actionButton?.title = "Erişilebilirliği Aç"
        statusLabel?.stringValue = "İzin vermek için Erişilebilirliği Aç'a tıklayın."
        statusLabel?.textColor = .systemOrange
        progressIndicator?.stopAnimation(nil)
    }

    public func windowWillClose(_ notification: Notification) {
        stopPolling()
    }

    private func startPolling() {
        stopPolling()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            if AXIsProcessTrusted() {
                self.handlePermissionGranted()
            }
        }
    }

    private func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
        progressIndicator.stopAnimation(nil)
    }

    private func handlePermissionGranted() {
        stopPolling()
        statusLabel.stringValue = "✅ Yetki verildi! Voice Typing hazır."
        statusLabel.textColor = .systemGreen

        // Sistem Ayarları'nı kapatmak yerine gizle; kullanıcının başka bir
        // ayar penceresindeki çalışması korunur.
        PermissionManager.shared.closeSystemSettings()

        // 0.3 saniye sonra pencereyi kapat ve callback'i çalıştır
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self = self else { return }
            self.window?.close()
            self.onGranted?()
            self.onGranted = nil
        }
    }
}
