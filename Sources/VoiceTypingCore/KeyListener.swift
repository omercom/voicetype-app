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
        let eventMask = (1 << CGEventType.flagsChanged.rawValue) | (1 << CGEventType.keyDown.rawValue)

        let observer = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())

        let callback: CGEventTapCallBack = { proxy, type, event, refcon in
            guard let refcon = refcon else { return Unmanaged.passRetained(event) }
            let listener = Unmanaged<KeyListener>.fromOpaque(refcon).takeUnretainedValue()
            return listener.handleEvent(proxy: proxy, type: type, event: event)
        }

        while isRunning {
            guard AXIsProcessTrusted() else {
                Thread.sleep(forTimeInterval: 1.0)
                continue
            }

            guard let tap = CGEvent.tapCreate(
                tap: .cghidEventTap,
                place: .headInsertEventTap,
                options: .defaultTap,
                eventsOfInterest: CGEventMask(eventMask),
                callback: callback,
                userInfo: observer
            ) else {
                Thread.sleep(forTimeInterval: 1.0)
                continue
            }

            self.eventTap = tap
            let runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
            self.runLoopSource = runLoopSource
            CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)

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
            }
            return Unmanaged.passRetained(event)
        }

        // 2. Tetikleyici Tuş Kontrolü (Sağ Command tuşu = 54)
        if keyCode == targetKeyCode && (type == .flagsChanged || type == .keyDown) {
            let flags = event.flags
            let hasDeviceRCommand = (flags.rawValue & 0x00000010) != 0
            let hasCmdFlag = flags.contains(.maskCommand)
            let isPressedNow = hasDeviceRCommand || (hasCmdFlag && !isKeyDown)

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

        return Unmanaged.passRetained(event)
    }

    private func handleKeyDown() {
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
