import Foundation
import CoreGraphics
import AppKit

public class KeyListener {
    public static let shared = KeyListener()

    public var onStart: (() -> Void)?
    public var onStop: ((Double) -> Void)?
    public var onCancel: (() -> Void)?
    public var isBusy: (() -> Bool)?

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var thread: Thread?
    private var isRunning: Bool = false

    private var isKeyDown: Bool = false
    private var isRecording: Bool = false
    private var pressStartTime: CFAbsoluteTime = 0
    private var recordingStartTime: CFAbsoluteTime = 0
    private var inToggleMode: Bool = false

    private let lock = NSLock()
    private var targetKeyCode: Int64 {
        return Int64(ConfigManager.shared.config.trigger_key)
    }
    private let escKeyCode: Int64 = 53     // Escape tuşu
    private var runLoop: CFRunLoop?

    private init() {}

    public func resetState() {
        lock.lock()
        isKeyDown = false
        isRecording = false
        inToggleMode = false
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

    private func isModifierPressed(keyCode: Int64, flags: CGEventFlags, currentKeyDown: Bool) -> Bool {
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

    public func start() {
        lock.lock()
        defer { lock.unlock() }

        guard !isRunning else { return }
        isRunning = true

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

        while isRunning {
            guard AXIsProcessTrusted() else {
                print("[KeyListener] ⚠️ Erişilebilirlik (Accessibility) izni bekleniyor... (Sistem Ayarları > Gizlilik ve Güvenlik > Erişilebilirlik)")
                let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
                _ = AXIsProcessTrustedWithOptions(options)
                Thread.sleep(forTimeInterval: 2.0)
                continue
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
            print("[KeyListener] ✅ Klavye dinleyicisi kuruldu. Aktif tetikleyici tuş: \(keyName) (KeyCode: \(targetKeyCode))")
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
            lock.lock()
            let shouldCancel = isRecording || (isBusy?() ?? false)
            isRecording = false
            isKeyDown = false
            inToggleMode = false
            lock.unlock()

            if shouldCancel {
                DispatchQueue.main.async { [weak self] in
                    self?.onCancel?()
                }
                // Esc kaydı iptal ettiğinde aktif penceredeki açık diyaloğu veya tam ekranı kapatmasın
                return nil
            }
            return Unmanaged.passRetained(event)
        }

        // 2. Modifier tuş basılıyken başka tuşa basıldıysa (örn: Cmd+C, Cmd+V, Cmd+Tab)
        // Bu durum bir sesle yazma değil, normal klavye kısayoludur; kaydı hemen iptal et
        if isKeyDown && KeyListener.isModifier(keyCode: targetKeyCode) && type == .keyDown && keyCode != targetKeyCode {
            lock.lock()
            let wasActive = isRecording
            isRecording = false
            isKeyDown = false
            inToggleMode = false
            lock.unlock()

            if wasActive {
                DispatchQueue.main.async { [weak self] in
                    self?.onCancel?()
                }
            }
            return Unmanaged.passRetained(event)
        }

        // 3. Tetikleyici Tuş Kontrolü
        if keyCode == targetKeyCode {
            if KeyListener.isModifier(keyCode: targetKeyCode) {
                if type == .flagsChanged {
                    let isPressedNow = isModifierPressed(keyCode: targetKeyCode, flags: event.flags, currentKeyDown: isKeyDown)
                    if isPressedNow && !isKeyDown {
                        // TUŞA BASILDI
                        isKeyDown = true
                        handleKeyDown()
                    } else if !isPressedNow && isKeyDown {
                        // TUŞ BIRAKILDI
                        isKeyDown = false
                        handleKeyUp()
                    }
                }
            } else {
                // Normal tuş (F-tuşları, Space vb.)
                if type == .keyDown {
                    let isAutorepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
                    if !isAutorepeat && !isKeyDown {
                        isKeyDown = true
                        handleKeyDown()
                    }
                    // Normal tetikleyici tuş basıldığında aktif uygulamaya karakter göndermesin (yutulsun)
                    return nil
                } else if type == .keyUp {
                    if isKeyDown {
                        isKeyDown = false
                        handleKeyUp()
                    }
                    return nil
                }
            }
        }

        return Unmanaged.passRetained(event)
    }

    private func handleKeyDown() {
        print("[KeyListener] 🎙️ Tetikleyici tuşa basıldı! (Kayıt tetikleniyor)")
        lock.lock()
        let config = ConfigManager.shared.config
        let mode = config.trigger_mode.lowercased()
        pressStartTime = CFAbsoluteTimeGetCurrent()

        if mode == "toggle" {
            if isRecording {
                let duration = CFAbsoluteTimeGetCurrent() - recordingStartTime
                isRecording = false
                lock.unlock()
                DispatchQueue.main.async { [weak self] in
                    self?.onStop?(duration)
                }
                return
            } else {
                isRecording = true
                recordingStartTime = CFAbsoluteTimeGetCurrent()
                lock.unlock()
                DispatchQueue.main.async { [weak self] in
                    self?.onStart?()
                }
                return
            }
        } else if mode == "smart" {
            if inToggleMode {
                inToggleMode = false
                isRecording = false
                let duration = CFAbsoluteTimeGetCurrent() - recordingStartTime
                lock.unlock()
                DispatchQueue.main.async { [weak self] in
                    self?.onStop?(duration)
                }
                return
            }
            isRecording = true
            recordingStartTime = CFAbsoluteTimeGetCurrent()
            lock.unlock()
            DispatchQueue.main.async { [weak self] in
                self?.onStart?()
            }
        } else {
            // "hold" (Push-to-Talk)
            if !isRecording {
                isRecording = true
                recordingStartTime = CFAbsoluteTimeGetCurrent()
                lock.unlock()
                DispatchQueue.main.async { [weak self] in
                    self?.onStart?()
                }
            } else {
                lock.unlock()
            }
        }
    }

    private func handleKeyUp() {
        print("[KeyListener] ⏹️ Tetikleyici tuş bırakıldı!")
        lock.lock()
        let config = ConfigManager.shared.config
        let mode = config.trigger_mode.lowercased()
        let holdDuration = CFAbsoluteTimeGetCurrent() - pressStartTime

        if mode == "toggle" {
            lock.unlock()
            return
        }

        if mode == "smart" {
            if holdDuration < 0.25 {
                // Kısa tıklama -> toggle moduna geç, kayda devam et
                inToggleMode = true
                lock.unlock()
                return
            }
            inToggleMode = false
        }

        guard isRecording else {
            lock.unlock()
            return
        }

        isRecording = false
        let totalDuration = CFAbsoluteTimeGetCurrent() - recordingStartTime
        lock.unlock()

        DispatchQueue.main.async { [weak self] in
            self?.onStop?(totalDuration)
        }
    }
}
