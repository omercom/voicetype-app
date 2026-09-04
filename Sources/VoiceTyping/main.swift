import Foundation
import AppKit
import Darwin
import VoiceTypingCore

// stdout ve stderr için tamponlamayı kaldır, loglar anında app.log'a düşsün
setbuf(__stdoutp, nil)
setbuf(__stderrp, nil)

// Tekil süreç kontrolü (Single Instance Guard):
// Aynı anda iki VoiceTyping süreci çalışıp menü çubuğunda çift ikon oluşturmasın
let configDir = NSString(string: "~/.voice_typing").expandingTildeInPath
try? FileManager.default.createDirectory(atPath: configDir, withIntermediateDirectories: true)
let lockPath = (configDir as NSString).appendingPathComponent("app.lock")
let lockFd = open(lockPath, O_CREAT | O_RDWR, mode_t(0o644))
if lockFd != -1 {
    if flock(lockFd, LOCK_EX | LOCK_NB) != 0 {
        print("⚠️ VoiceTyping zaten arka planda çalışıyor. İkinci kopya sonlandırılıyor.")
        let bundleId = Bundle.main.bundleIdentifier ?? "com.antigravity.VoiceTyping"
        for otherApp in NSRunningApplication.runningApplications(withBundleIdentifier: bundleId) {
            if otherApp.processIdentifier != ProcessInfo.processInfo.processIdentifier {
                otherApp.activate(options: .activateIgnoringOtherApps)
            }
        }
        exit(0)
    }
    // Kilidi aldık: Kendi PID'mizi dosyaya yaz
    ftruncate(lockFd, 0)
    let pidStr = "\(ProcessInfo.processInfo.processIdentifier)\n"
    _ = pidStr.withCString { write(lockFd, $0, strlen($0)) }
}

print("============================================================")
print("macOS Voice Typing Başlatıldı (PID: \(ProcessInfo.processInfo.processIdentifier))")
print("============================================================")

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

let delegate = AppDelegate()
app.delegate = delegate

app.run()

