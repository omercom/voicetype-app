import Foundation
import CoreGraphics
import AppKit

public class KeyListener {
    public static let shared = KeyListener()

    public var onStart: ((TimeInterval) -> Void)?
    var onShortcutStart: ((TimeInterval, DictationShortcutKind) -> Void)?
    public var onStop: ((Double) -> Void)?
    public var onCancel: (() -> Void)?
    public var isBusy: (() -> Bool)?

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var thread: Thread?
    private var isRunning: Bool = false

    private var shortcutState = DictationShortcutState()

    private let lock = NSLock()
    private var targetKeyCode: Int64 {
        return Int64(ConfigManager.shared.config.trigger_key)
    }
    private let escKeyCode: Int64 = 53     // Escape tuşu
    private var runLoop: CFRunLoop?

    private init() {}

    public func resetState() {
        lock.lock()
        shortcutState = DictationShortcutState()
        lock.unlock()
    }

    public static func isModifier(keyCode: Int64) -> Bool {
        switch keyCode {
        case 54, 55, 56, 57, 58, 59, 60, 61, 62, 63:
            return true
        default:
            return false
        }
    }

    static func isModifierPressed(keyCode: Int64, flags: CGEventFlags, currentKeyDown: Bool) -> Bool {
        switch keyCode {
        case 54: // Right Command
            return (flags.rawValue & 0x00000010) != 0 || (flags.contains(.maskCommand) && !currentKeyDown)
        case 55: // Left Command
            return (flags.rawValue & 0x00000008) != 0 || (flags.contains(.maskCommand) && !currentKeyDown)
        case 58: // Left Option
            return (flags.rawValue & 0x00000020) != 0 || (flags.contains(.maskAlternate) && !currentKeyDown)
        case 61: // Right Option
            return (flags.rawValue & 0x00000040) != 0 || (flags.contains(.maskAlternate) && !currentKeyDown)
        case 59: // Left Control
            return (flags.rawValue & 0x00000001) != 0 || (flags.contains(.maskControl) && !currentKeyDown)
        case 62: // Right Control
            return (flags.rawValue & 0x00002000) != 0 || (flags.contains(.maskControl) && !currentKeyDown)
        case 63: // Fn / Globe
            return flags.contains(.maskSecondaryFn) || (flags.rawValue & 0x00800000) != 0
        case 56: // Left Shift
            return (flags.rawValue & 0x00000002) != 0 || (flags.contains(.maskShift) && !currentKeyDown)
        case 60: // Right Shift
            return (flags.rawValue & 0x00000004) != 0 || (flags.contains(.maskShift) && !currentKeyDown)
        case 57: // Caps Lock
            return flags.contains(.maskAlphaShift) || (flags.rawValue & 0x00000080) != 0
        default:
            return !flags.isEmpty
        }
    }

    public func updateTriggerKeyConfiguration() {
        GlobeKeySuppressor.shared.suppressIfNeeded(triggerKey: Int(targetKeyCode))
    }

    public func start() {
        lock.lock()
        defer { lock.unlock() }

        guard !isRunning else { return }
        isRunning = true

        GlobeKeySuppressor.shared.suppressIfNeeded(triggerKey: Int(targetKeyCode))

        thread = Thread { [weak self] in
            self?.runEventTapLoop()
        }
        thread?.name = "com.voicetyping.keylistener"
        thread?.qualityOfService = .userInteractive
        thread?.start()
    }

    public func stop() {
        lock.lock()
        isRunning = false
        GlobeKeySuppressor.shared.restoreOriginal()
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            eventTap = nil
        }
        if let rl = runLoop {
            CFRunLoopStop(rl)
            runLoop = nil
        }
        lock.unlock()
    }

    private func runEventTapLoop() {
        let eventMask = (1 << CGEventType.flagsChanged.rawValue) | (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue)

        let observer = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())

        let callback: CGEventTapCallBack = { proxy, type, event, refcon in
            guard let refcon = refcon else { return Unmanaged.passRetained(event) }
            let listener = Unmanaged<KeyListener>.fromOpaque(refcon).takeUnretainedValue()
            return listener.handleEvent(proxy: proxy, type: type, event: event)
        }

        var waitTicks = 0
        while isRunning {
            guard AXIsProcessTrusted() else {
                // Erişilebilirlik izni yoksa iznin verilmesini bekle.
                //
                // Sessiz beklemek teşhis edilemez bir durum yaratıyordu:
                // uygulama çalışıyor görünür ama hiçbir tuşu duymaz ve
                // nedenini söylemez. Bu yüzden beklemeyi ARALIKLI olarak
                // bildiriyoruz (her 10 sn'de bir, günlüğü doldurmadan).
                if waitTicks % 20 == 0 {
                    print("[KeyListener] ⏳ Erişilebilirlik izni bekleniyor — kısayol şu an devre dışı. "
                          + "Sistem Ayarları → Gizlilik ve Güvenlik → Erişilebilirlik bölümünden VoiceTyping'i etkinleştirin.")
                }
                waitTicks += 1
                Thread.sleep(forTimeInterval: 0.5)
                continue
            }
            if waitTicks > 0 {
                print("[KeyListener] ✅ Erişilebilirlik izni alındı; dinleyici kuruluyor.")
            }

            // Önce kullanıcı oturumu tap'ini (.cgSessionEventTap - root gerektirmez), ardından HID tap'ini dene
            var tap = CGEvent.tapCreate(
                tap: .cgSessionEventTap,
                place: .headInsertEventTap,
                options: .defaultTap,
                eventsOfInterest: CGEventMask(eventMask),
                callback: callback,
                userInfo: observer
            )

            if tap == nil {
                tap = CGEvent.tapCreate(
                    tap: .cghidEventTap,
                    place: .headInsertEventTap,
                    options: .defaultTap,
                    eventsOfInterest: CGEventMask(eventMask),
                    callback: callback,
                    userInfo: observer
                )
            }

            guard let createdTap = tap else {
                print("[KeyListener] ⚠️ Event tap oluşturulamadı. 1 sn sonra tekrar denenecek...")
                Thread.sleep(forTimeInterval: 1.0)
                continue
            }

            self.eventTap = createdTap
            let keyName = TriggerKeyOption.name(for: Int(targetKeyCode))
            print("[KeyListener] ✅ Klavye dinleyicisi kuruldu. Normal dikte: \(keyName) (KeyCode: \(targetKeyCode))")
            if ConfigManager.shared.config.enable_translation {
                print("[KeyListener] 🌐 Çevirili dikte: Sağ Option (KeyCode: \(DictationShortcutState.translationKeyCode))")
            }
            let runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, createdTap, 0)
            self.runLoopSource = runLoopSource
            CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
            CGEvent.tapEnable(tap: createdTap, enable: true)

            self.runLoop = CFRunLoopGetCurrent()
            CFRunLoopRun()
            break
        }
    }

    private func handleEvent(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = eventTap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            return nil
        }

        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)

        // 1. Esc ile İptal (Escape tuşu = 53)
        if type == .keyDown && keyCode == escKeyCode {
            let busy = isBusy?() ?? false
            lock.lock()
            let action = shortcutState.cancel()
            lock.unlock()

            if action != nil || busy {
                dispatchAction(.cancel, triggeredAt: ProcessInfo.processInfo.systemUptime)
                // Esc kaydı iptal ettiğinde aktif penceredeki açık diyaloğu veya tam ekranı kapatmasın
                return nil
            }
            return Unmanaged.passRetained(event)
        }

        // 2. Modifier ile başka tuş birleşirse (örn: Cmd+C), dikte iptal edilir.
        // 3. Normal ve çevirili dikte için tetikleyici tuş kontrolü.
        let shortcutEvent: DictationShortcutEvent
        switch type {
        case .flagsChanged:
            shortcutEvent = .flagsChanged(event.flags)
        case .keyDown:
            shortcutEvent = .keyDown(isRepeat: event.getIntegerValueField(.keyboardEventAutorepeat) != 0)
        case .keyUp:
            shortcutEvent = .keyUp
        default:
            return Unmanaged.passRetained(event)
        }
        let config = ConfigManager.shared.config
        let timestamp = ProcessInfo.processInfo.systemUptime
        lock.lock()
        let result = shortcutState.handle(keyCode: keyCode, event: shortcutEvent,
                                          primaryKeyCode: Int64(config.trigger_key),
                                          translationEnabled: config.enable_translation,
                                          triggerMode: config.trigger_mode, time: timestamp)
        lock.unlock()
        if let action = result.action { dispatchAction(action, triggeredAt: timestamp) }
        // Normal tetikleyici tuş aktif uygulamaya karakter göndermesin (yutulsun).
        return result.consume ? nil : Unmanaged.passRetained(event)
    }

    private func dispatchAction(_ action: DictationShortcutAction, triggeredAt: TimeInterval) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            switch action {
            case .start(let kind):
                if let onShortcutStart = self.onShortcutStart {
                    onShortcutStart(triggeredAt, kind)
                } else {
                    self.onStart?(triggeredAt)
                }
            case .stop(let duration):
                self.onStop?(duration)
            case .cancel:
                self.onCancel?()
            }
        }
    }
}
