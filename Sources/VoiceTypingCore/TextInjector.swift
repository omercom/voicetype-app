import Foundation
import AppKit
import CoreGraphics

public class TextInjector {
    public static let shared = TextInjector()

    private var restoreTimer: DispatchSourceTimer?
    private let queue = DispatchQueue(label: "com.voicetyping.textinjector", qos: .userInteractive)

    private init() {}

    public func getClipboard() -> String {
        return NSPasteboard.general.string(forType: .string) ?? ""
    }

    public func setClipboard(_ text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }

    public func simulateCmdV() {
        let vKeyCode: CGKeyCode = 9 // Virtual keycode for 'v'

        guard let eventDown = CGEvent(keyboardEventSource: nil, virtualKey: vKeyCode, keyDown: true),
              let eventUp = CGEvent(keyboardEventSource: nil, virtualKey: vKeyCode, keyDown: false) else {
            // Yedek AppleScript yöntemi
            let script = "tell application \"System Events\" to keystroke \"v\" using command down"
            if let appleScript = NSAppleScript(source: script) {
                var error: NSDictionary?
                appleScript.executeAndReturnError(&error)
            }
            return
        }

        eventDown.flags = .maskCommand
        let tapLocation: CGEventTapLocation = AXIsProcessTrusted() ? .cghidEventTap : .cgSessionEventTap
        eventDown.post(tap: tapLocation)

        Thread.sleep(forTimeInterval: 0.020)

        eventUp.flags = []
        eventUp.post(tap: tapLocation)
    }

    @discardableResult
    public func paste(
        text: String,
        restoreClipboard: Bool = false,
        pasteDelayMs: Int = 20
    ) -> Bool {
        guard !text.isEmpty else { return false }

        let oldClipboard = restoreClipboard ? getClipboard() : ""

        setClipboard(text)

        queue.async { [weak self] in
            if pasteDelayMs > 0 {
                Thread.sleep(forTimeInterval: Double(pasteDelayMs) / 1000.0)
            }
            self?.simulateCmdV()

            if restoreClipboard && !oldClipboard.isEmpty {
                Thread.sleep(forTimeInterval: 0.40)
                DispatchQueue.main.async {
                    self?.setClipboard(oldClipboard)
                }
            }
        }

        return true
    }
}
