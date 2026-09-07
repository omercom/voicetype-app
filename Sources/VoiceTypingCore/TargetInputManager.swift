import Foundation
import AppKit
import ApplicationServices

/// Ses kaydı başlatıldığında kullanıcının odaklandığı metin alanının ve uygulamanın anlık dondurulmuş bağlamı.
public struct TargetContext: Equatable {
    public let pid: pid_t
    public let bundleIdentifier: String
    public let appName: String
    public let runningApp: NSRunningApplication?
    public let element: AXUIElement
    public let window: AXUIElement?
    public let role: String

    public init(
        pid: pid_t,
        bundleIdentifier: String,
        appName: String,
        runningApp: NSRunningApplication?,
        element: AXUIElement,
        window: AXUIElement?,
        role: String
    ) {
        self.pid = pid
        self.bundleIdentifier = bundleIdentifier
        self.appName = appName
        self.runningApp = runningApp
        self.element = element
        self.window = window
        self.role = role
    }

    public static func == (lhs: TargetContext, rhs: TargetContext) -> Bool {
        return lhs.pid == rhs.pid &&
               lhs.bundleIdentifier == rhs.bundleIdentifier &&
               CFEqual(lhs.element, rhs.element)
    }
}

/// macOS Accessibility API ve WindowServer seviyesinde metin alanı tespiti,
/// hedef kilitleme (Target-Lock) ve arka plandaki pencereyi geri getirme yöneticisi.
public class TargetInputManager {
    public static let shared = TargetInputManager()

    private let terminalBundleIDs: Set<String> = [
        "com.apple.Terminal",
        "com.googlecode.iterm2",
        "dev.warp.Warp-Stable",
        "net.kovidgoyal.kitty",
        "io.alacritty",
        "com.github.wez.wezterm",
        "co.zeit.hyper"
    ]

    private let codeEditorBundleIDs: Set<String> = [
        "com.microsoft.VSCode",
        "com.todesktop.230313mzl4w4u92", // Cursor
        "com.apple.dt.Xcode",
        "com.sublimetext.4",
        "com.sublimetext.3",
        "com.trae.app",
        "com.panic.Nova"
    ]

    private let browserBundleIDs: Set<String> = [
        "com.google.Chrome",
        "com.apple.Safari",
        "company.thebrowser.Browser", // Arc
        "com.brave.Browser",
        "org.mozilla.firefox",
        "com.microsoft.edgemac",
        "com.operasoftware.Opera"
    ]

    private let chatAndNoteBundleIDs: Set<String> = [
        "com.apple.Notes",
        "net.whatsapp.WhatsApp",
        "com.tinyspeck.slackmacgap",
        "com.hnc.Discord",
        "ru.keepcoder.Telegram",
        "com.apple.MobileSMS",
        "com.apple.mail",
        "notion.id"
    ]

    private init() {}

    /// Verilen bir UI öğesinin düzenlenebilir bir metin alanı veya girdi kabul eden bir pencere olup olmadığını doğrular.
    public func isTextInputElement(_ element: AXUIElement, pid: pid_t, bundleID: String) -> (isTextInput: Bool, role: String) {
        var roleRef: CFTypeRef?
        _ = AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleRef)
        let role = (roleRef as? String) ?? ""

        var subroleRef: CFTypeRef?
        _ = AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &subroleRef)
        let subrole = (subroleRef as? String) ?? ""

        // 1. Kesin Olarak Yazı Alanı Olmayan Denetimler (Butonlar, Menüler, Sürgüler, Resimler vb.)
        let nonInputRoles: Set<String> = [
            "AXButton", "AXCheckBox", "AXRadioButton", "AXSlider", "AXTabGroup",
            "AXMenu", "AXMenuBar", "AXMenuItem", "AXImage", "AXColorWell", "AXPopUpButton",
            "AXProgressIndicator"
        ]
        if nonInputRoles.contains(role) {
            return (false, role)
        }

        // 2. Standart Metin Rolleri (Native macOS)
        if role == kAXTextFieldRole || role == kAXTextAreaRole || role == kAXComboBoxRole || role == "AXSearchField" {
            return (true, role)
        }
        if subrole == "AXSearchField" || subrole == "AXStandardTextField" || subrole == "AXSecureTextField" {
            return (true, subrole)
        }

        // 3. Seçim Aralığı / Metin İşaretçisi Kontrolü (Web & Electron editörleri)
        // Chrome, Safari, Slack, Notion, Google Docs vb. imleç bir yazı alanındaysa bu öznitelik mevcuttur
        var rangeRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &rangeRef) == .success, rangeRef != nil {
            return (true, "AXTextRange")
        }

        var markerRangeRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, "AXSelectedTextMarkerRange" as CFString, &markerRangeRef) == .success, markerRangeRef != nil {
            return (true, "AXTextMarkerRange")
        }

        // 4. Değiştirilebilir Metin Değeri Kontrolü (Settable)
        var isValueSettable: DarwinBoolean = false
        if AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &isValueSettable) == .success, isValueSettable.boolValue {
            return (true, "AXSettableValue")
        }

        var isSelectionSettable: DarwinBoolean = false
        if AXUIElementIsAttributeSettable(element, kAXSelectedTextAttribute as CFString, &isSelectionSettable) == .success, isSelectionSettable.boolValue {
            return (true, "AXSettableSelection")
        }

        // 5. Terminal ve Kod Editörleri (Her zaman klavye girdisi kabul eden pencereler)
        if terminalBundleIDs.contains(bundleID) {
            return (true, "AXTerminal")
        }
        if codeEditorBundleIDs.contains(bundleID) || bundleID.contains("jetbrains") {
            return (true, "AXCodeEditor")
        }

        // 6. Web Tarayıcı Alanı (Chrome, Safari, Arc, Firefox vb. web sayfaları)
        if role == "AXWebArea" || role == "AXGroup" || role == "AXScrollArea" {
            if browserBundleIDs.contains(bundleID) || chatAndNoteBundleIDs.contains(bundleID) {
                return (true, "AXWebArea")
            }
        }

        // 7. İletişim ve Not Uygulamaları (Slack, WhatsApp, Discord, Telegram, Notes, Mail, Messages)
        if chatAndNoteBundleIDs.contains(bundleID) {
            return (true, "AXMessagingApp")
        }

        return (false, role)
    }

    /// O an sistemde klavye odağına sahip olan UI öğesini yakalar ve metin alanı olup olmadığını denetler.
    /// Eğer geçerli bir metin alanıysa dondurulmuş bir `TargetContext` nesnesi döner.
    public func captureTargetContext() -> TargetContext? {
        guard let frontApp = NSWorkspace.shared.frontmostApplication else {
            return nil
        }

        let targetPID = frontApp.processIdentifier
        let bundleID = frontApp.bundleIdentifier ?? ""
        let appName = frontApp.localizedName ?? ""

        // 1. Sistem Arayüzü Koruması (Dock, Denetim Merkezi, Bildirimler)
        if bundleID == "com.apple.dock" || bundleID == "com.apple.controlcenter" || bundleID == "com.apple.notificationcenterui" {
            return nil
        }

        let appRef = AXUIElementCreateApplication(targetPID)

        // Odaktaki UI öğesini yakala (Doğrudan uygulamanın Mach portundan sorulur)
        var candidateElement: AXUIElement?
        var focusedElementRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(appRef, kAXFocusedUIElementAttribute as CFString, &focusedElementRef) == .success {
            candidateElement = (focusedElementRef as! AXUIElement?)
        }

        // İlgili pencereyi (Window) bul
        var targetWindow: AXUIElement?
        var windowRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(appRef, kAXFocusedWindowAttribute as CFString, &windowRef) == .success {
            targetWindow = (windowRef as! AXUIElement?)
        }

        // Eğer doğrudan odaklı öğe yoksa, pencere içindeki odaklı öğeyi dene
        if candidateElement == nil, let win = targetWindow {
            var winFocusedRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(win, kAXFocusedUIElementAttribute as CFString, &winFocusedRef) == .success {
                candidateElement = (winFocusedRef as! AXUIElement?)
            }
        }

        // Finder Masaüstü Kontrolü: Açık bir pencere yoksa veya sadece Desktop AXScrollArea seçiliyse yazı alanı değildir
        if bundleID == "com.apple.finder" {
            if targetWindow == nil {
                return nil // Masaüstü boşluğuna tıklandı
            }
            if let elem = candidateElement {
                var roleRef: CFTypeRef?
                AXUIElementCopyAttributeValue(elem, kAXRoleAttribute as CFString, &roleRef)
                let role = (roleRef as? String) ?? ""
                if role == "AXScrollArea" || role == "AXList" {
                    var rangeRef: CFTypeRef?
                    if AXUIElementCopyAttributeValue(elem, kAXSelectedTextRangeAttribute as CFString, &rangeRef) != .success || rangeRef == nil {
                        return nil
                    }
                }
            }
        }

        let elemToInspect = candidateElement ?? targetWindow ?? appRef

        // Metin alanı doğrulaması
        let (isInput, detectedRole) = isTextInputElement(elemToInspect, pid: targetPID, bundleID: bundleID)
        guard isInput else {
            return nil
        }

        return TargetContext(
            pid: targetPID,
            bundleIdentifier: bundleID,
            appName: appName,
            runningApp: frontApp,
            element: candidateElement ?? targetWindow ?? appRef,
            window: targetWindow,
            role: detectedRole
        )
    }

    /// Arka planda kalmış veya odağı kaybolmuş hedef uygulamayı ve pencereyi öne getirir,
    /// odağı ilk konuşulan yazı alanına kilitler.
    @discardableResult
    public func restoreTargetFocus(to target: TargetContext) -> Bool {
        // 1. AppleScript ile System Events üzerinden hedef işlemi %100 kesinlikle öne çek
        // (macOS 14 Sonoma ve macOS 15 Sequoia güvenlik kısıtlarını aşan endüstri standardı yöntem)
        let script = "tell application \"System Events\" to set frontmost of (first process whose unix id is \(target.pid)) to true"
        var scriptError: NSDictionary?
        NSAppleScript(source: script)?.executeAndReturnError(&scriptError)

        // 2. Cocoa seviyesinde de aktive et
        if let app = target.runningApp {
            app.activate(options: [.activateAllWindows])
        } else if let app = NSRunningApplication(processIdentifier: target.pid) {
            app.activate(options: [.activateAllWindows])
        }

        // 3. Hedef pencereyi öne kaldır (kAXRaiseAction)
        if let window = target.window {
            AXUIElementPerformAction(window, kAXRaiseAction as CFString)
        }

        // 4. Doğrulama Döngüsü: macOS WindowServer hedef uygulamayı en öne alana kadar bekle (maksimum 400ms)
        let deadline = CFAbsoluteTimeGetCurrent() + 0.40
        while NSWorkspace.shared.frontmostApplication?.processIdentifier != target.pid {
            if CFAbsoluteTimeGetCurrent() > deadline { break }
            usleep(15_000) // 15ms
        }

        // 5. Hedef pencerenin ve imlecin oturması için mikro bekleme (35ms)
        usleep(35_000)

        // 6. Hedef UI öğesine odak ver
        let appRef = AXUIElementCreateApplication(target.pid)
        AXUIElementSetAttributeValue(appRef, kAXFocusedUIElementAttribute as CFString, target.element)

        return true
    }
}
