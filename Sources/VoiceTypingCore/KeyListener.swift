import Foundation
import CoreGraphics
import AppKit

public class KeyListener {
    public static let shared = KeyListener()

    public var onStart: ((TimeInterval) -> Void)?
    var onShortcutStart: ((TimeInterval, DictationShortcutKind) -> Void)?
    public var onStop: ((Double) -> Void)?
    public var onCancel: (() -> Void)?
    public var onRepasteLast: (() -> Void)?
    public var isBusy: (() -> Bool)?

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var thread: Thread?
    private var isRunning: Bool = false

    private var shortcutState = DictationShortcutState()

    private let lock = NSLock()
    private var cachedVKeyCode: Int64?
    private var targetKeyCode: Int64 {
        return Int64(ConfigManager.shared.config.trigger_key)
    }
    private let escKeyCode: Int64 = 53     // Escape tuşu
    private let capsLockKeyCode: Int64 = 57
    private var capsLockDictationActive = false
    private var capsLockStartedAt: TimeInterval = 0
    private var lastCapsLockAlphaShift: Bool?
    private var runLoop: CFRunLoop?

    private init() {}

    static func mappedMouseVirtualKeyCode(buttonNumber: Int64, configuredButton: Int) -> Int64? {
        guard configuredButton >= 2, buttonNumber == Int64(configuredButton) else { return nil }
        return 10_000 + buttonNumber
    }

    public func resetState() {
        lock.lock()
        shortcutState = DictationShortcutState()
        capsLockDictationActive = false
        lastCapsLockAlphaShift = nil
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
        let eventMask = (1 << CGEventType.flagsChanged.rawValue)
            | (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.keyUp.rawValue)
            | (1 << CGEventType.otherMouseDown.rawValue)
            | (1 << CGEventType.otherMouseUp.rawValue)

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

    private func resolveVKeyCode() -> Int64 {
        lock.lock()
        let cached = cachedVKeyCode
        lock.unlock()
        if let cached { return cached }
        let resolved: Int64 = Thread.isMainThread
            ? Int64(TextInjector.keyCodeForCharacter("v", fallback: 0x09))
            : Int64(DispatchQueue.main.sync { TextInjector.keyCodeForCharacter("v", fallback: 0x09) })
        lock.lock()
        cachedVKeyCode = resolved
        lock.unlock()
        return resolved
    }

    private func handleEvent(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = eventTap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            let hidFlags = CGEventSource.flagsState(.hidSystemState)
            let timestamp = ProcessInfo.processInfo.systemUptime
            lock.lock()
            let stuckKey = shortcutState.pressedKeyCode
            let recoveryAction: DictationShortcutAction?
            if let stuckKey,
               Self.isModifier(keyCode: stuckKey),
               !Self.isModifierPressed(keyCode: stuckKey, flags: hidFlags, currentKeyDown: true) {
                recoveryAction = shortcutState.release(keyCode: stuckKey, time: timestamp)
            } else {
                recoveryAction = nil
            }
            lock.unlock()
            if let recoveryAction {
                dispatchAction(recoveryAction, triggeredAt: timestamp)
            }
            return nil
        }

        // Uygulamanın kendi sentetik yapıştırma / Enter olaylarını asla dikte veya
        // kısayol iptali olarak işleme alma.
        if event.getIntegerValueField(.eventSourceUserData) == TextInjector.syntheticEventUserData {
            return Unmanaged.passRetained(event)
        }

        let config = ConfigManager.shared.config
        let timestamp = ProcessInfo.processInfo.systemUptime

        // Ek fare yan tuşları (Mouse 4 / Mouse 5 — sol/sağ tık asla yutulmaz)
        if type == .otherMouseDown || type == .otherMouseUp {
            let buttonNumber = event.getIntegerValueField(.mouseEventButtonNumber)
            guard let virtualMouseKey = Self.mappedMouseVirtualKeyCode(
                buttonNumber: buttonNumber,
                configuredButton: config.mouse_trigger_button
            ) else {
                return Unmanaged.passRetained(event)
            }
            let mouseEvent: DictationShortcutEvent = (type == .otherMouseDown)
                ? .keyDown(isRepeat: false)
                : .keyUp
            lock.lock()
            let result = shortcutState.handle(
                keyCode: virtualMouseKey,
                event: mouseEvent,
                primaryKeyCode: virtualMouseKey,
                translationEnabled: false,
                triggerMode: config.trigger_mode,
                time: timestamp
            )
            lock.unlock()
            if let action = result.action { dispatchAction(action, triggeredAt: timestamp) }
            return result.consume ? nil : Unmanaged.passRetained(event)
        }

        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)

        // Caps Lock eller-serbest dikte aç/kapat
        if type == .flagsChanged && keyCode == capsLockKeyCode && config.enable_caps_lock_dictation {
            let alphaNow = event.flags.contains(.maskAlphaShift)
            lock.lock()
            let isBusyShortcut = shortcutState.activeKeyCode != nil || shortcutState.pressedKeyCode != nil
            let previousAlpha = lastCapsLockAlphaShift
            lastCapsLockAlphaShift = alphaNow
            guard !isBusyShortcut, previousAlpha != alphaNow else {
                lock.unlock()
                return Unmanaged.passRetained(event)
            }
            let action: DictationShortcutAction
            if capsLockDictationActive {
                capsLockDictationActive = false
                let duration = max(0, timestamp - capsLockStartedAt)
                action = .stop(duration)
            } else {
                capsLockDictationActive = true
                capsLockStartedAt = timestamp
                action = .start(.normal)
            }
            lock.unlock()
            dispatchAction(action, triggeredAt: timestamp)
            return nil
        }

        // 0. Option + Shift + V: Son dikteyi yeniden yapıştır (Hex ⌥⇧V akışı)
        if type == .keyDown,
           event.getIntegerValueField(.keyboardEventAutorepeat) == 0,
           config.enable_repaste_shortcut,
           !(isBusy?() ?? false) {
            let flags = event.flags
            let hasOptionShift = flags.contains(.maskAlternate) && flags.contains(.maskShift)
            let hasCmdOrCtrl = flags.contains(.maskCommand) || flags.contains(.maskControl)
            if hasOptionShift && !hasCmdOrCtrl && keyCode == resolveVKeyCode() {
                DispatchQueue.main.async { [weak self] in
                    self?.onRepasteLast?()
                }
                return nil
            }
        }

        // 1. Esc ile İptal (Escape tuşu = 53)
        if type == .keyDown && keyCode == escKeyCode {
            let busy = isBusy?() ?? false
            lock.lock()
            let wasCapsActive = capsLockDictationActive
            capsLockDictationActive = false
            let action = shortcutState.cancel()
            lock.unlock()

            if action != nil || wasCapsActive || busy {
                dispatchAction(.cancel, triggeredAt: timestamp)
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
