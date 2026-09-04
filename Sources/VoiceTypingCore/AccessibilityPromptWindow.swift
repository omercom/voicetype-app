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

    private init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 255),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Voice Typing - Kurulum & İzin"
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
        let iconView = NSImageView(frame: NSRect(x: 28, y: 155, width: 64, height: 64))
        if let appIcon = NSImage(named: NSImage.applicationIconName) {
            iconView.image = appIcon
        } else if #available(macOS 11.0, *), let symbol = NSImage(systemSymbolName: "hand.raised.fill", accessibilityDescription: nil) {
            iconView.image = symbol
            iconView.contentTintColor = .systemBlue
        }
        iconView.imageScaling = .scaleProportionallyUpOrDown
        contentView.addSubview(iconView)

        // 2. Başlık
        let titleLabel = NSTextField(labelWithString: "Erişilebilirlik İzni Gerekli")
        titleLabel.frame = NSRect(x: 108, y: 190, width: 345, height: 24)
        titleLabel.font = NSFont.systemFont(ofSize: 16, weight: .bold)
        titleLabel.textColor = .labelColor
        contentView.addSubview(titleLabel)

        // 3. Açıklama
        let descLabel = NSTextField(wrappingLabelWithString: "Voice Typing'in klavye kısayolunu (Sağ ⌘) dinleyebilmesi ve konuşmanızı doğrudan aktif metin alanına yazabilmesi için macOS Erişilebilirlik iznine ihtiyacı vardır.\n\nLütfen Sistem Ayarları'nda VoiceTyping yanındaki anahtarı açın.")
        descLabel.frame = NSRect(x: 108, y: 110, width: 345, height: 75)
        descLabel.font = NSFont.systemFont(ofSize: 12, weight: .regular)
        descLabel.textColor = .secondaryLabelColor
        contentView.addSubview(descLabel)

        // 4. Durum Kutusu / Canlı Bilgi
        statusLabel = NSTextField(labelWithString: "Sistem Ayarları'nı açmak için aşağıdaki butona tıklayın.")
        statusLabel.frame = NSRect(x: 108, y: 78, width: 315, height: 20)
        statusLabel.font = NSFont.systemFont(ofSize: 11, weight: .medium)
        statusLabel.textColor = .systemOrange
        contentView.addSubview(statusLabel)

        progressIndicator = NSProgressIndicator(frame: NSRect(x: 82, y: 77, width: 18, height: 18))
        progressIndicator.style = .spinning
        progressIndicator.controlSize = .small
        progressIndicator.isDisplayedWhenStopped = false
        contentView.addSubview(progressIndicator)

        // 5. Ayırıcı Çizgi
        let separator = NSBox(frame: NSRect(x: 20, y: 64, width: 440, height: 1))
        separator.boxType = .separator
        contentView.addSubview(separator)

        // 6. Butonlar
        let cancelButton = NSButton(title: "Daha Sonra", target: self, action: #selector(cancelAction))
        cancelButton.frame = NSRect(x: 235, y: 16, width: 110, height: 32)
        cancelButton.bezelStyle = .rounded
        cancelButton.keyEquivalent = "\u{1b}" // Escape
        contentView.addSubview(cancelButton)

        actionButton = NSButton(title: "Sistem Ayarlarını Aç", target: self, action: #selector(openSettingsAction))
        actionButton.frame = NSRect(x: 350, y: 16, width: 115, height: 32)
        actionButton.bezelStyle = .rounded
        actionButton.keyEquivalent = "\r" // Enter
        contentView.addSubview(actionButton)
    }

    public func showPrompt(onGranted: (() -> Void)? = nil) {
        self.onGranted = onGranted

        // Zaten izin verilmişse pencere açmaya gerek yok
        if AXIsProcessTrusted() {
            onGranted?()
            return
        }

        // Dinamik Dock: Kurulum penceresi açıldığında Dock'ta görün
        if !ConfigManager.shared.config.show_dock_icon {
            NSApp.setActivationPolicy(.regular)
        }

        guard let window = window else { return }
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        startPolling()
    }

    @objc private func openSettingsAction() {
        actionButton.isEnabled = false
        actionButton.title = "Bekleniyor..."
        statusLabel.stringValue = "Sistem Ayarları açıldı. 'VoiceTyping' anahtarını açın..."
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

    public func windowWillClose(_ notification: Notification) {
        stopPolling()
        // Dinamik Dock: Başka pencere yoksa Dock ikonunu kaldır
        if !ConfigManager.shared.config.show_dock_icon && !(SettingsWindowController.shared.window?.isVisible ?? false) {
            DispatchQueue.main.async {
                NSApp.setActivationPolicy(.accessory)
            }
        }
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

        // Sistem Ayarları'nı otomatik kapat
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
