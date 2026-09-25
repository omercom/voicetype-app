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

    /// AX API'sinden gelen genel CF değerini yalnızca gerçekten AXUIElement
    /// olduğunda dönüştürür. Bozuk/eksik AX yanıtları uygulamayı düşürmemeli.
    private func axElement(from value: CFTypeRef?) -> AXUIElement? {
        guard let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return unsafeBitCast(value, to: AXUIElement.self)
    }

    /// AX ağacındaki bir öğenin kendisinde veya üst öğelerinde metin girişi sinyali arar.
    /// Bazı editörler (özellikle özel/native render motorları) odağı bir AXGroup'a verir,
    /// ancak düzenlenebilirlik bilgisini üstteki öğede yayınlar.
    private func textInputCapability(in element: AXUIElement) -> String? {
        var roleRef: CFTypeRef?
        _ = AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleRef)
        let role = (roleRef as? String) ?? ""

        var subroleRef: CFTypeRef?
        _ = AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &subroleRef)
        let subrole = (subroleRef as? String) ?? ""

        if role == kAXTextFieldRole || role == kAXTextAreaRole || role == kAXComboBoxRole || role == "AXSearchField" {
            return role
        }
        if subrole == "AXSearchField" || subrole == "AXStandardTextField" || subrole == "AXSecureTextField" {
            return subrole
        }

        var rangeRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &rangeRef) == .success,
           rangeRef != nil {
            return "AXTextRange"
        }

        var markerRangeRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, "AXSelectedTextMarkerRange" as CFString, &markerRangeRef) == .success,
           markerRangeRef != nil {
            return "AXTextMarkerRange"
        }

        // AXEditable, macOS'un tüm SDK sürümlerinde sabit olarak dışa aktarılmadığı
        // için öznitelik adıyla okunur.
        var editableRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, "AXEditable" as CFString, &editableRef) == .success,
           (editableRef as? NSNumber)?.boolValue == true {
            return "AXEditable"
        }

        var isValueSettable: DarwinBoolean = false
        if AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &isValueSettable) == .success,
           isValueSettable.boolValue {
            return "AXSettableValue"
        }

        var isSelectionSettable: DarwinBoolean = false
        if AXUIElementIsAttributeSettable(element, kAXSelectedTextAttribute as CFString, &isSelectionSettable) == .success,
           isSelectionSettable.boolValue {
            return "AXSettableSelection"
        }

        return nil
    }

    private func textInputCapabilityInHierarchy(from element: AXUIElement, maxDepth: Int = 6) -> String? {
        var current: AXUIElement? = element

        for _ in 0..<maxDepth {
            guard let element = current else { break }
            if let capability = textInputCapability(in: element) {
                return capability
            }

            var parentRef: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, kAXParentAttribute as CFString, &parentRef) == .success,
                  let parent = axElement(from: parentRef) else {
                break
            }
            guard !CFEqual(element, parent) else { break }
            current = parent
        }

        return nil
    }

    /// Verilen bir UI öğesinin düzenlenebilir bir metin alanı veya girdi kabul eden bir pencere olup olmadığını doğrular.
    public func isTextInputElement(
        _ element: AXUIElement,
        pid: pid_t,
        bundleID: String,
        appName: String? = nil
    ) -> (isTextInput: Bool, role: String) {
        var roleRef: CFTypeRef?
        _ = AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleRef)
        let role = (roleRef as? String) ?? ""

        // 1. Kesin olarak yazı alanı olmayan denetimler (butonlar, menüler, sürgüler vb.)
        let nonInputRoles: Set<String> = [
            "AXButton", "AXCheckBox", "AXRadioButton", "AXSlider", "AXTabGroup",
            "AXMenu", "AXMenuBar", "AXMenuItem", "AXImage", "AXColorWell", "AXPopUpButton",
            "AXProgressIndicator"
        ]
        if nonInputRoles.contains(role) {
            return (false, role)
        }

        // Özel render motorlu terminal/editörlerde sonuç zaten merkezi uygulama
        // profiliyle kabul ediliyordu. Bu kesin sonucu pahalı üst-öğe taramasından
        // önce kullanmak Zed/Electron hot path'inde onlarca senkron AX IPC'sini önler.
        let category = AppProfileFormatter.shared.detectCategory(
            bundleIdentifier: bundleID,
            appName: appName
        )
        if category == .terminal {
            return (true, "AXTerminal")
        }
        if category == .codeEditor {
            return (true, "AXCodeEditor")
        }

        // 2. Uygulamadan bağımsız AX metin sinyalleri. Üst öğe taraması,
        // özel render motoru kullanan bilinmeyen uygulamalarda statik listeye
        // ihtiyaç duymadan düzenlenebilirliği doğrular.
        if let capability = textInputCapabilityInHierarchy(from: element) {
            return (true, capability)
        }

        // 3. Web Tarayıcısı / web tabanlı uygulama alanları
        if role == "AXWebArea" || role == "AXGroup" || role == "AXScrollArea" {
            if browserBundleIDs.contains(bundleID) || chatAndNoteBundleIDs.contains(bundleID) {
                return (true, "AXWebArea")
            }
        }

        // 5. İletişim ve not uygulamaları
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
            candidateElement = axElement(from: focusedElementRef)
        }

        // İlgili pencereyi (Window) bul
        var targetWindow: AXUIElement?
        var windowRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(appRef, kAXFocusedWindowAttribute as CFString, &windowRef) == .success {
            targetWindow = axElement(from: windowRef)
        }

        // Eğer doğrudan odaklı öğe yoksa, pencere içindeki odaklı öğeyi dene
        if candidateElement == nil, let win = targetWindow {
            var winFocusedRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(win, kAXFocusedUIElementAttribute as CFString, &winFocusedRef) == .success {
                candidateElement = axElement(from: winFocusedRef)
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
        let (isInput, detectedRole) = isTextInputElement(
            elemToInspect,
            pid: targetPID,
            bundleID: bundleID,
            appName: appName
        )
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
    /// Klavye odağına sahip uygulamanın PID'i, doğrudan AX üzerinden canlı sorgulanır.
    /// `NSWorkspace.frontmostApplication` ana run loop'ta bildirimle güncellenir; ana
    /// thread bir bekleme döngüsünde bloke iken hiç değişmez ve döngü hep zaman aşımına düşer.
    private func focusedApplicationPID() -> pid_t? {
        let systemWide = AXUIElementCreateSystemWide()
        var appRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(systemWide, kAXFocusedApplicationAttribute as CFString, &appRef) == .success,
              let app = axElement(from: appRef) else {
            return nil
        }
        var pid: pid_t = 0
        guard AXUIElementGetPid(app, &pid) == .success else { return nil }
        return pid
    }

    private func waitUntilFocused(pid: pid_t, timeout: CFAbsoluteTime) -> Bool {
        let deadline = CFAbsoluteTimeGetCurrent() + timeout
        while focusedApplicationPID() != pid {
            if CFAbsoluteTimeGetCurrent() > deadline { return false }
            usleep(10_000)
        }
        return true
    }

    @discardableResult
    public func restoreTargetFocus(to target: TargetContext) -> Bool {
        // 1. Cocoa seviyesinde aktive et ve hedef pencereyi öne kaldır.
        let app = target.runningApp ?? NSRunningApplication(processIdentifier: target.pid)
        app?.activate(options: [.activateAllWindows])
        if let window = target.window {
            AXUIElementPerformAction(window, kAXRaiseAction as CFString)
        }

        // 2. Odağın gerçekten geçtiğini canlı AX sorgusuyla doğrula. Cocoa yolu
        // yetmezse (bazı Electron/Java uygulamaları) System Events yedeğine geç;
        // AppleScript yavaştır ve Otomasyon izni ister, bu yüzden yalnızca yedektir.
        var focused = waitUntilFocused(pid: target.pid, timeout: 0.25)
        if !focused {
            let script = "tell application \"System Events\" to set frontmost of (first process whose unix id is \(target.pid)) to true"
            var scriptError: NSDictionary?
            NSAppleScript(source: script)?.executeAndReturnError(&scriptError)
            focused = waitUntilFocused(pid: target.pid, timeout: 0.25)
        }

        // 3. Hedef UI öğesine odak ver ve pencerenin/imlecin oturması için kısa bekle.
        let appRef = AXUIElementCreateApplication(target.pid)
        AXUIElementSetAttributeValue(appRef, kAXFocusedUIElementAttribute as CFString, target.element)
        usleep(40_000)

        return focused
    }
}
