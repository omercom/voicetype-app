import Foundation

/// Hedef macOS uygulamasına göre metni akıllıca biçimlendiren profil yöneticisi.
/// Terminal/IDE için küçük harf ve noktasız komut satırı stili,
/// Mesajlaşma için samimi sohbet stili,
/// E-posta ve Dökümanlar için tam kurumsal dilbilgisi stili uygular.
public final class AppProfileFormatter {
    public static let shared = AppProfileFormatter()

    public enum AppCategory: String, CaseIterable {
        case terminal
        case codeEditor
        case messaging
        case document
        case generic
    }

    private let terminalBundleIDs: Set<String> = [
        "com.apple.Terminal",
        "com.googlecode.iterm2",
        "dev.warp.Warp",
        "dev.warp.Warp-Stable",
        "dev.warp.Warp-Preview",
        "dev.warp.WarpPreview",
        "com.mitchellh.ghostty",
        "com.github.wez.wezterm",
        "net.kovidgoyal.kitty",
        "io.alacritty",
        "co.zeit.hyper"
    ]

    private let codeEditorBundleIDs: Set<String> = [
        "com.microsoft.VSCode",
        "com.todesktop.230313mzl4w4u92", // Cursor
        "com.apple.dt.Xcode",
        "dev.zed.Zed",
        "com.sublimetext.4",
        "com.sublimetext.3",
        "com.jetbrains.intellij",
        "com.jetbrains.pycharm",
        "com.jetbrains.webstorm",
        "com.jetbrains.clion",
        "com.jetbrains.rider",
        "com.jetbrains.goland"
    ]

    private let messagingBundleIDs: Set<String> = [
        "com.tinyspeck.slackmacgap", // Slack
        "ru.keepcoder.Telegram",
        "com.facebook.archon", // WhatsApp
        "com.apple.MobileSMS", // iMessage
        "com.hnc.Discord"
    ]

    private let documentBundleIDs: Set<String> = [
        "com.apple.mail",
        "com.microsoft.Outlook",
        "com.apple.iWork.Pages",
        "com.microsoft.Word",
        "com.apple.Notes",
        "com.apple.TextEdit"
    ]

    private let cliKeywords: Set<String> = [
        "git", "npm", "npx", "yarn", "pnpm", "bun", "cargo", "rustc",
        "docker", "docker-compose", "kubectl", "helm", "terraform",
        "cd", "ls", "pwd", "mkdir", "rm", "cp", "mv", "touch", "cat",
        "grep", "find", "chmod", "chown", "curl", "wget", "ssh", "scp",
        "brew", "python", "python3", "pip", "node", "swift", "go",
        "make", "cmake", "tar", "zip", "unzip", "sudo", "kill", "ps"
    ]

    private let codeKeywords: Set<String> = [
        "let", "var", "const", "val", "def", "function", "func", "fn",
        "class", "struct", "enum", "interface", "type", "import", "export",
        "return", "if", "else", "for", "while", "switch", "case", "async", "await"
    ]

    private init() {}

    public func detectCategory(bundleIdentifier: String?, appName: String?) -> AppCategory {
        let bundle = bundleIdentifier?.lowercased() ?? ""
        let name = appName?.lowercased() ?? ""

        if terminalBundleIDs.contains(where: { $0.caseInsensitiveCompare(bundle) == .orderedSame }) ||
           name.contains("terminal") || name.contains("iterm") || name.contains("warp") || name.contains("ghostty") {
            return .terminal
        }

        if codeEditorBundleIDs.contains(where: { $0.caseInsensitiveCompare(bundle) == .orderedSame }) ||
           name.contains("code") || name.contains("cursor") || name.contains("xcode") || name.contains("intellij") {
            return .codeEditor
        }

        if messagingBundleIDs.contains(where: { $0.caseInsensitiveCompare(bundle) == .orderedSame }) ||
           name.contains("slack") || name.contains("telegram") || name.contains("whatsapp") || name.contains("discord") {
            return .messaging
        }

        if documentBundleIDs.contains(where: { $0.caseInsensitiveCompare(bundle) == .orderedSame }) ||
           name.contains("mail") || name.contains("outlook") || name.contains("pages") || name.contains("word") {
            return .document
        }

        return .generic
    }

    /// Hedef uygulamaya göre metni formatlar
    public func format(text: String, targetContext: TargetContext?) -> String {
        guard !text.isEmpty else { return text }
        let category = detectCategory(bundleIdentifier: targetContext?.bundleIdentifier, appName: targetContext?.appName)
        return format(text: text, category: category)
    }

    public func format(text: String, category: AppCategory) -> String {
        var processed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !processed.isEmpty else { return "" }

        switch category {
        case .terminal:
            // 1. Sonundaki tek noktayı kaldır (örn: "git status." -> "git status")
            if processed.hasSuffix(".") && !processed.hasSuffix("..") {
                processed.removeLast()
                processed = processed.trimmingCharacters(in: .whitespaces)
            }

            // 2. Türkçe "tire tire" veya "tire" bayraklarını dönüştür ("tire tire help" -> "--help", "tire v" -> "-v")
            processed = convertSpokenFlags(processed)

            // 3. İlk kelime bilinen bir CLI komutuysa veya küçük harfle başlamalıysa ilk harfi küçült
            let firstWord = processed.components(separatedBy: " ").first?.lowercased() ?? ""
            if cliKeywords.contains(firstWord) || isLikelyCommand(processed) {
                if let firstChar = processed.first {
                    processed = String(firstChar).lowercased() + String(processed.dropFirst())
                }
            }

        case .codeEditor:
            // Kod editöründe kod anahtar kelimeleriyle başlıyorsa baş harfi küçük yap ve sonundaki noktayı kaldır
            let firstWord = processed.components(separatedBy: " ").first?.lowercased() ?? ""
            if codeKeywords.contains(firstWord) {
                if processed.hasSuffix(".") && !processed.hasSuffix("..") {
                    processed.removeLast()
                    processed = processed.trimmingCharacters(in: .whitespaces)
                }
                if let firstChar = processed.first {
                    processed = String(firstChar).lowercased() + String(processed.dropFirst())
                }
            }

        case .messaging:
            // Çok kısa mesajlarda (örneğin 1-4 kelimelik tek yanıt) son noktayı kaldırarak daha doğal sohbet havası ver
            let words = processed.components(separatedBy: " ").filter { !$0.isEmpty }
            if words.count <= 4 && processed.hasSuffix(".") && !processed.hasSuffix("...") && !processed.contains("\n") {
                processed.removeLast()
                processed = processed.trimmingCharacters(in: .whitespaces)
            }

        case .document:
            // Tam kurumsal resmi imla: ilk harf büyük olmalı
            if let firstChar = processed.first, firstChar.isLetter {
                processed = String(firstChar).uppercased(with: Locale(identifier: "tr_TR")) + String(processed.dropFirst())
            }
            // Soru veya ünlem yoksa sonuna nokta ekle
            if let last = processed.last, !".?!;:\n".contains(last) {
                processed.append(".")
            }

        case .generic:
            break
        }

        return processed
    }

    private func isLikelyCommand(_ text: String) -> Bool {
        // İçinde tireli parametreler (-a, --help) veya slash (/) veya pipe (|) varsa komuttur
        return text.contains(" -") || text.contains("--") || text.contains("/") || text.contains("|")
    }

    private func convertSpokenFlags(_ input: String) -> String {
        var text = input
        let flagReplacements: [(pattern: String, template: String)] = [
            (#"(?i)\s+tire\s+tire\s+([a-zA-Z0-9\-_]+)"#, " --$1"),
            (#"(?i)^tire\s+tire\s+([a-zA-Z0-9\-_]+)"#, "--$1"),
            (#"(?i)\s+tire\s+([a-zA-Z0-9])\b"#, " -$1"),
            (#"(?i)^tire\s+([a-zA-Z0-9])\b"#, "-$1")
        ]

        for (pattern, template) in flagReplacements {
            if let regex = try? NSRegularExpression(pattern: pattern) {
                let range = NSRange(location: 0, length: (text as NSString).length)
                text = regex.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: template)
            }
        }
        return text
    }
}
