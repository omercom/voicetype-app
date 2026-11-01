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
    /// Tarayıcı/Electron web alanının adresi. Kayıt sırasında sekme veya sohbet
    /// kanalı değişirse yapıştırmadan önce bununla fark edilir.
    public let pageURL: String?

    public init(
        pid: pid_t,
        bundleIdentifier: String,
        appName: String,
        runningApp: NSRunningApplication?,
        element: AXUIElement,
        window: AXUIElement?,
        role: String,
        pageURL: String? = nil
    ) {
        self.pid = pid
        self.bundleIdentifier = bundleIdentifier
        self.appName = appName
        self.runningApp = runningApp
        self.element = element
        self.window = window
        self.role = role
        self.pageURL = pageURL
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

        // Hedef alan bilinmiyorsa yalnızca uygulamayı veya pencereyi kilitlemek
        // yeterli değildir: aynı uygulamadaki başka bir alana yazılabilir.
        guard let elemToInspect = candidateElement else { return nil }

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
            element: elemToInspect,
            window: targetWindow,
            role: detectedRole,
            pageURL: candidateElement.flatMap { pageURL(near: $0) }
        )
    }

    // MARK: - Hedef doğrulama (yapıştırmadan önce)

    public enum TargetCheck: Equatable {
        case same
        case changed(reason: String)
    }

    /// Sistem genelinde klavye odağındaki öğe (canlı AX sorgusu).
    public func focusedElement() -> AXUIElement? {
        let systemWide = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(systemWide, 0.25)
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(systemWide, kAXFocusedUIElementAttribute as CFString, &ref) == .success else {
            return nil
        }
        return axElement(from: ref)
    }

    /// Öğenin içinde bulunduğu web alanının adresi. Sorgu ve `#` bölümleri de
    /// korunur; bazı uygulamalar konuşma ve kanalları bu bölümlerde ayırır.
    public func pageURL(near element: AXUIElement, maxDepth: Int = 20) -> String? {
        var current: AXUIElement? = element
        for _ in 0..<maxDepth {
            guard let node = current else { break }
            AXUIElementSetMessagingTimeout(node, 0.25)
            var roleRef: CFTypeRef?
            _ = AXUIElementCopyAttributeValue(node, kAXRoleAttribute as CFString, &roleRef)
            if (roleRef as? String) == "AXWebArea" {
                var urlRef: CFTypeRef?
                guard AXUIElementCopyAttributeValue(node, kAXURLAttribute as CFString, &urlRef) == .success else { return nil }
                let raw = (urlRef as? URL)?.absoluteString ?? (urlRef as? String)
                return raw.flatMap(Self.normalizedPageURL)
            }
            var parentRef: CFTypeRef?
            guard AXUIElementCopyAttributeValue(node, kAXParentAttribute as CFString, &parentRef) == .success,
                  let parent = axElement(from: parentRef), !CFEqual(parent, node) else { break }
            current = parent
        }
        return nil
    }

    static func normalizedPageURL(_ raw: String) -> String? {
        guard var components = URLComponents(string: raw),
              let scheme = components.scheme, let host = components.host else { return nil }
        components.scheme = scheme.lowercased()
        components.host = host.lowercased()
        components.user = nil
        components.password = nil
        if components.path.hasSuffix("/") { components.path.removeLast() }
        return components.string
    }

    /// Teslimattan önce uygulamayı, pencereyi ve kayıt başındaki alanı doğrular.
    /// Odak okunamıyorsa başka bir alana yazma riskine karşı teslimat durdurulur.
    public func verify(_ target: TargetContext) -> TargetCheck {
        guard target.role != "AXFallbackApp", target.runningApp?.isTerminated != true else {
            return .changed(reason: "Hedef alan kullanılamıyor")
        }
        guard let appPID = focusedApplicationPID() else {
            return .changed(reason: "Odak doğrulanamadı")
        }
        guard appPID == target.pid else { return .changed(reason: "Başka uygulama odakta") }
        guard let focused = focusedElement() else { return .changed(reason: "Odak doğrulanamadı") }
        var elementPID: pid_t = 0
        guard AXUIElementGetPid(focused, &elementPID) == .success else {
            return .changed(reason: "Hedef alan doğrulanamadı")
        }

        var sameWindow: Bool?
        if let expectedWindow = target.window {
            let app = AXUIElementCreateApplication(target.pid)
            AXUIElementSetMessagingTimeout(app, 0.25)
            var windowRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &windowRef) == .success,
               let currentWindow = axElement(from: windowRef) {
                sameWindow = CFEqual(expectedWindow, currentWindow)
            } else {
                sameWindow = false
            }
        }

        return Self.assessTarget(
            expectedPID: target.pid, focusedPID: elementPID,
            sameElement: CFEqual(focused, target.element), sameWindow: sameWindow,
            expectedPageURL: target.pageURL,
            currentPageURL: target.pageURL == nil ? nil : pageURL(near: focused)
        )
    }

    static func assessTarget(
        expectedPID: pid_t, focusedPID: pid_t?, sameElement: Bool,
        sameWindow: Bool?, expectedPageURL: String?, currentPageURL: String?
    ) -> TargetCheck {
        guard let focusedPID else { return .changed(reason: "Odak doğrulanamadı") }
        guard focusedPID == expectedPID else { return .changed(reason: "Başka uygulama odakta") }
        guard sameWindow != false else { return .changed(reason: "Pencere değişti") }
        if let expectedPageURL, currentPageURL != expectedPageURL {
            return .changed(reason: "Sekme doğrulanamadı veya değişti")
        }
        guard sameElement else { return .changed(reason: "Yazı alanı değişti") }
        return .same
    }

    /// Klavye odağına sahip uygulamanın PID'i doğrudan AX üzerinden canlı sorgulanır.
    /// `NSWorkspace.frontmostApplication` ana run loop'ta bildirimle güncellenir.
    private func focusedApplicationPID() -> pid_t? {
        let systemWide = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(systemWide, 0.25)
        var appRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(systemWide, kAXFocusedApplicationAttribute as CFString, &appRef) == .success,
              let app = axElement(from: appRef) else {
            return nil
        }
        var pid: pid_t = 0
        guard AXUIElementGetPid(app, &pid) == .success else { return nil }
        return pid
    }

    private func isOriginalProcess(_ target: TargetContext) -> Bool {
        guard target.role != "AXFallbackApp", let original = target.runningApp,
              !original.isTerminated,
              let running = NSRunningApplication(processIdentifier: target.pid) else { return false }
        return original == running
    }

    private func isOriginalElementAvailable(_ target: TargetContext) -> Bool {
        guard isOriginalProcess(target) else { return false }
        AXUIElementSetMessagingTimeout(target.element, 0.25)
        var pid: pid_t = 0
        guard AXUIElementGetPid(target.element, &pid) == .success, pid == target.pid else { return false }
        var role: CFTypeRef?
        guard AXUIElementCopyAttributeValue(target.element, kAXRoleAttribute as CFString, &role) == .success,
              role as? String != nil else { return false }
        if let expectedURL = target.pageURL, pageURL(near: target.element) != expectedURL { return false }
        return true
    }

    private func isOriginalWindowFocused(_ target: TargetContext) -> Bool {
        guard let expected = target.window else { return true }
        let app = AXUIElementCreateApplication(target.pid)
        AXUIElementSetMessagingTimeout(app, 0.25)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &value) == .success,
              let current = axElement(from: value) else { return false }
        return CFEqual(expected, current)
    }

    private func focusOriginalElement(_ target: TargetContext) -> Bool {
        guard isOriginalElementAvailable(target) else { return false }
        if AXUIElementSetAttributeValue(target.element, kAXFocusedAttribute as CFString, kCFBooleanTrue) == .success {
            return true
        }
        // Some apps expose focus on the application rather than the field.
        let app = AXUIElementCreateApplication(target.pid)
        AXUIElementSetMessagingTimeout(app, 0.25)
        var settable: DarwinBoolean = false
        guard AXUIElementIsAttributeSettable(app, kAXFocusedUIElementAttribute as CFString, &settable) == .success,
              settable.boolValue else { return false }
        return AXUIElementSetAttributeValue(app, kAXFocusedUIElementAttribute as CFString, target.element) == .success
    }

    /// Yalnızca kayıt sırasında yakalanan süreci, pencereyi ve alanı geri odaklar.
    /// Bu yöntem bekleme yaptığı için ana thread dışında çağrılmalıdır.
    @discardableResult
    public func restoreTargetFocus(to target: TargetContext, isCancelled: @escaping () -> Bool = { false }) -> Bool {
        guard !Thread.isMainThread else { return verify(target) == .same }
        let environment = TargetFocusRecovery.Environment(
            processIsValid: { [self] in isOriginalProcess(target) },
            targetIsAvailable: { [self] in isOriginalElementAvailable(target) },
            targetIsFocused: { [self] in verify(target) == .same },
            applicationIsFocused: { [self] in focusedApplicationPID() == target.pid },
            activateApplication: {
                DispatchQueue.main.sync {
                    guard !isCancelled(), let app = target.runningApp, !app.isTerminated else { return false }
                    return app.isActive || app.activate(options: [])
                }
            },
            windowIsFocused: { [self] in isOriginalWindowFocused(target) },
            raiseWindow: { [self] in
                guard !isCancelled(), isOriginalProcess(target), let window = target.window else { return }
                AXUIElementSetMessagingTimeout(window, 0.25)
                var pid: pid_t = 0
                guard AXUIElementGetPid(window, &pid) == .success, pid == target.pid else { return }
                _ = AXUIElementPerformAction(window, kAXRaiseAction as CFString)
            },
            focusField: { [self] in !isCancelled() && focusOriginalElement(target) },
            isCancelled: isCancelled
        )
        return TargetFocusRecovery.run(environment) == .ready
    }
}
