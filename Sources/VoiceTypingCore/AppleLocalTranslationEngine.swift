import AppKit
import Foundation
import NaturalLanguage

#if canImport(Translation)
@preconcurrency import Translation
#endif
#if canImport(SwiftUI)
import SwiftUI
#endif

public enum AppleTranslationPairStatus: String, Equatable, Sendable {
    case installed
    case supported
    case unsupported
    case unavailable
}

public struct AppleTranslationDiagnostics: Sendable {
    public let osSupported: Bool
    public let headlessSupported: Bool
    public let lowLatencySupported: Bool
    public let sourceCode: String
    public let targetCode: String
    public let pairStatus: AppleTranslationPairStatus
    public let supportedLanguageCount: Int
    public let summaryLine: String

    public init(
        osSupported: Bool,
        headlessSupported: Bool,
        lowLatencySupported: Bool,
        sourceCode: String,
        targetCode: String,
        pairStatus: AppleTranslationPairStatus,
        supportedLanguageCount: Int,
        summaryLine: String
    ) {
        self.osSupported = osSupported
        self.headlessSupported = headlessSupported
        self.lowLatencySupported = lowLatencySupported
        self.sourceCode = sourceCode
        self.targetCode = targetCode
        self.pairStatus = pairStatus
        self.supportedLanguageCount = supportedLanguageCount
        self.summaryLine = summaryLine
    }
}

public enum AppleLocalTranslationError: LocalizedError, Equatable {
    case unavailableOS
    case unsupportedPair(source: String, target: String)
    case languagePackNotInstalled(source: String, target: String)
    case emptyResult

    public var errorDescription: String? {
        switch self {
        case .unavailableOS:
            return "Apple yerel çeviri için macOS 26.0+ gereklidir."
        case .unsupportedPair(let source, let target):
            return "Apple Çeviri \(source.uppercased()) → \(target.uppercased()) dil çiftini desteklemiyor."
        case .languagePackNotInstalled(let source, let target):
            return "Apple Çeviri paketi kurulu değil (\(source.uppercased()) → \(target.uppercased())) — Ayarlar → Genel'den indirin."
        case .emptyResult:
            return "Apple yerel çeviri boş yanıt döndürdü."
        }
    }
}

/// On-device Apple ANE NMT engine backed by `Translation.framework` (`macOS 26.0+` headless
/// `TranslationSession(installedSource:target:)` and `macOS 26.4+` `.lowLatency` / `.highFidelity`).
public final class AppleLocalTranslationEngine: @unchecked Sendable {
    public static let shared = AppleLocalTranslationEngine()

    public static var isAvailableOnCurrentOS: Bool {
        #if canImport(Translation)
        if #available(macOS 15.0, *) {
            return true
        }
        #endif
        return false
    }

    public static var isHeadlessAvailableOnCurrentOS: Bool {
        #if canImport(Translation)
        if #available(macOS 26.0, *) {
            return true
        }
        #endif
        return false
    }

    public static var isLowLatencyAvailableOnCurrentOS: Bool {
        #if canImport(Translation) && compiler(>=6.3)
        if #available(macOS 26.4, *) {
            return true
        }
        #endif
        return false
    }

    public static func normalizedLanguageCode(_ raw: String, fallback: String = "tr") -> String {
        let cleaned = raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "_", with: "-")
        if cleaned.isEmpty || cleaned == "auto" {
            return fallback
        }
        if cleaned == "zh-cn" || cleaned == "zh-hans" { return "zh" }
        if cleaned == "zh-tw" || cleaned == "zh-hant" { return "zh-TW" }
        if cleaned == "zh-hk" { return "zh-HK" }
        if cleaned == "pt-br" { return "pt" }
        if let base = cleaned.split(separator: "-").first, !base.isEmpty {
            return String(base)
        }
        return fallback
    }

    public static func detectSourceLanguageCode(for text: String, configuredSource: String) -> String {
        let cleaned = configuredSource.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if !cleaned.isEmpty && cleaned != "auto" {
            return normalizedLanguageCode(cleaned, fallback: "tr")
        }
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        if let dominant = recognizer.dominantLanguage, !dominant.rawValue.isEmpty {
            return normalizedLanguageCode(dominant.rawValue, fallback: "tr")
        }
        return "tr"
    }

    private let cacheLock = NSLock()
    private var installedStatusCache: [String: AppleTranslationPairStatus] = [:]

    #if canImport(Translation)
    @available(macOS 26.0, *)
    private actor SessionStore {
        private var sessions: [String: TranslationSession] = [:]

        private func cacheKey(src: String, tgt: String, lowLatency: Bool) -> String {
            "\(src)->\(tgt)|\(lowLatency ? "fast" : "hq")"
        }

        private func getOrCreateSession(src: String, tgt: String, lowLatency: Bool) -> TranslationSession {
            let key = cacheKey(src: src, tgt: tgt, lowLatency: lowLatency)
            if let existing = sessions[key] {
                return existing
            }
            let sourceLang = Locale.Language(identifier: src)
            let targetLang = Locale.Language(identifier: tgt)
            let session: TranslationSession
            #if compiler(>=6.3)
            if #available(macOS 26.4, *) {
                let strategy: TranslationSession.Strategy = lowLatency ? .lowLatency : .highFidelity
                session = TranslationSession(
                    installedSource: sourceLang,
                    target: targetLang,
                    preferredStrategy: strategy
                )
            } else {
                session = TranslationSession(installedSource: sourceLang, target: targetLang)
            }
            #else
            session = TranslationSession(installedSource: sourceLang, target: targetLang)
            #endif
            sessions[key] = session
            return session
        }

        func translate(text: String, src: String, tgt: String, lowLatency: Bool) async throws -> String {
            let key = cacheKey(src: src, tgt: tgt, lowLatency: lowLatency)
            let session = getOrCreateSession(src: src, tgt: tgt, lowLatency: lowLatency)
            do {
                let response = try await session.translate(text)
                return response.targetText
            } catch {
                sessions.removeValue(forKey: key)
                throw error
            }
        }

        func warm(src: String, tgt: String) async {
            _ = try? await translate(text: "ok", src: src, tgt: tgt, lowLatency: true)
            _ = try? await translate(text: "ok", src: src, tgt: tgt, lowLatency: false)
        }

        func invalidateAll() {
            sessions.removeAll()
        }
    }

    private var _sessionStore: AnyObject?
    private let storeLock = NSLock()

    @available(macOS 26.0, *)
    private var sessionStore: SessionStore {
        storeLock.lock()
        defer { storeLock.unlock() }
        if let existing = _sessionStore as? SessionStore {
            return existing
        }
        let created = SessionStore()
        _sessionStore = created
        return created
    }
    #endif

    private init() {}

    public func cachedStatus(from sourceCode: String, to targetCode: String) -> AppleTranslationPairStatus? {
        let src = Self.normalizedLanguageCode(sourceCode)
        let tgt = Self.normalizedLanguageCode(targetCode, fallback: "en")
        cacheLock.lock()
        defer { cacheLock.unlock() }
        return installedStatusCache["\(src)->\(tgt)"]
    }

    public func isPairKnownInstalled(from sourceCode: String, to targetCode: String) -> Bool {
        let src = Self.normalizedLanguageCode(sourceCode)
        let tgt = Self.normalizedLanguageCode(targetCode, fallback: "en")
        if src == tgt { return true }
        return cachedStatus(from: src, to: tgt) == .installed
    }

    private func setCachedStatus(_ status: AppleTranslationPairStatus, from src: String, to tgt: String) {
        cacheLock.lock()
        installedStatusCache["\(src)->\(tgt)"] = status
        cacheLock.unlock()
    }

    public func status(from sourceCode: String, to targetCode: String) async -> AppleTranslationPairStatus {
        let src = Self.normalizedLanguageCode(sourceCode)
        let tgt = Self.normalizedLanguageCode(targetCode, fallback: "en")
        if src == tgt {
            setCachedStatus(.installed, from: src, to: tgt)
            return .installed
        }
        #if canImport(Translation)
        if #available(macOS 15.0, *) {
            let availability: LanguageAvailability
            #if compiler(>=6.3)
            if #available(macOS 26.4, *) {
                availability = LanguageAvailability(preferredStrategy: .highFidelity)
            } else {
                availability = LanguageAvailability()
            }
            #else
            availability = LanguageAvailability()
            #endif
            let st = await availability.status(
                from: Locale.Language(identifier: src),
                to: Locale.Language(identifier: tgt)
            )
            let mapped: AppleTranslationPairStatus
            switch st {
            case .installed: mapped = .installed
            case .supported: mapped = .supported
            case .unsupported: mapped = .unsupported
            @unknown default: mapped = .unavailable
            }
            setCachedStatus(mapped, from: src, to: tgt)
            return mapped
        }
        #endif
        return .unavailable
    }

    public func diagnostics(from sourceCode: String, to targetCode: String) async -> AppleTranslationDiagnostics {
        let src = Self.normalizedLanguageCode(sourceCode)
        let tgt = Self.normalizedLanguageCode(targetCode, fallback: "en")
        let pairStatus = await status(from: src, to: tgt)
        var count = 0
        #if canImport(Translation)
        if #available(macOS 15.0, *) {
            count = await LanguageAvailability().supportedLanguages.count
        }
        #endif

        let osOK = Self.isAvailableOnCurrentOS
        let headlessOK = Self.isHeadlessAvailableOnCurrentOS
        let lowLatOK = Self.isLowLatencyAvailableOnCurrentOS
        let pairLabel = "\(src.uppercased()) → \(tgt.uppercased())"
        let strategyTag = lowLatOK ? "lowLatency + highFidelity" : (headlessOK ? "TranslationSession" : "Yetersiz OS")

        let summary: String
        switch pairStatus {
        case .installed:
            summary = "✅ Apple ANE Çeviri Kurulu (\(pairLabel)) · \(strategyTag) · 0 TL / Çevrimdışı"
        case .supported:
            summary = "⬇️ Apple ANE Çeviri Destekli (\(pairLabel)) · Dil paketi henüz indirilmedi (\(count) dil)"
        case .unsupported:
            summary = "⚠️ Apple Çeviri \(pairLabel) çiftini desteklemiyor (\(count) dil)"
        case .unavailable:
            summary = "⚠️ Apple yerel çeviri bu macOS sürümünde kullanılamıyor (macOS 26+ gerekir)"
        }

        return AppleTranslationDiagnostics(
            osSupported: osOK,
            headlessSupported: headlessOK,
            lowLatencySupported: lowLatOK,
            sourceCode: src,
            targetCode: tgt,
            pairStatus: pairStatus,
            supportedLanguageCount: count,
            summaryLine: summary
        )
    }

    public func warmSession(from sourceCode: String, to targetCode: String) async {
        #if canImport(Translation)
        guard #available(macOS 26.0, *) else { return }
        let src = Self.normalizedLanguageCode(sourceCode)
        let tgt = Self.normalizedLanguageCode(targetCode, fallback: "en")
        guard src != tgt else { return }
        let st = await status(from: src, to: tgt)
        guard st == .installed else { return }
        await sessionStore.warm(src: src, tgt: tgt)
        #endif
    }

    public func translate(
        text: String,
        from sourceCode: String,
        to targetCode: String,
        lowLatency: Bool = false
    ) async throws -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return text }

        #if canImport(Translation)
        guard #available(macOS 26.0, *) else {
            throw AppleLocalTranslationError.unavailableOS
        }
        let src = Self.detectSourceLanguageCode(for: trimmed, configuredSource: sourceCode)
        let tgt = Self.normalizedLanguageCode(targetCode, fallback: "en")
        if src == tgt {
            return text
        }

        let currentStatus: AppleTranslationPairStatus
        if cachedStatus(from: src, to: tgt) == .installed {
            currentStatus = .installed
        } else {
            currentStatus = await status(from: src, to: tgt)
        }

        switch currentStatus {
        case .installed:
            break
        case .supported:
            throw AppleLocalTranslationError.languagePackNotInstalled(source: src, target: tgt)
        case .unsupported, .unavailable:
            throw AppleLocalTranslationError.unsupportedPair(source: src, target: tgt)
        }

        do {
            let output = try await sessionStore.translate(text: trimmed, src: src, tgt: tgt, lowLatency: lowLatency)
            let cleaned = output.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleaned.isEmpty else {
                throw AppleLocalTranslationError.emptyResult
            }
            return cleaned
        } catch let localErr as AppleLocalTranslationError {
            throw localErr
        } catch {
            let refreshed = await status(from: src, to: tgt)
            if refreshed == .supported {
                throw AppleLocalTranslationError.languagePackNotInstalled(source: src, target: tgt)
            } else if refreshed == .unsupported || refreshed == .unavailable {
                throw AppleLocalTranslationError.unsupportedPair(source: src, target: tgt)
            }
            throw error
        }
        #else
        throw AppleLocalTranslationError.unavailableOS
        #endif
    }

    public func invalidateCache() {
        cacheLock.lock()
        installedStatusCache.removeAll()
        cacheLock.unlock()
        #if canImport(Translation)
        if #available(macOS 26.0, *) {
            Task {
                await sessionStore.invalidateAll()
            }
        }
        #endif
    }
}

// MARK: - In-App Apple Translation Pack Installer (Inline Sheet Host)

@MainActor
public final class AppleTranslationDownloadWindowController {
    private static weak var activeHostView: NSView?
    private static var activeToken = UUID()

    public static func cleanup() {
        activeToken = UUID()
        activeHostView?.removeFromSuperview()
        activeHostView = nil
    }

    public static func openSystemLocalizationSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Localization-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }

    public static func present(
        sourceCode: String,
        targetCode: String,
        relativeTo parentWindow: NSWindow?,
        onFinished: @escaping (Bool, String) -> Void
    ) {
        let src = AppleLocalTranslationEngine.normalizedLanguageCode(sourceCode)
        let tgt = AppleLocalTranslationEngine.normalizedLanguageCode(targetCode, fallback: "en")
        guard src != tgt else {
            onFinished(true, "Kaynak ve hedef dil aynı (\(src.uppercased())).")
            return
        }

        cleanup()

        #if canImport(SwiftUI) && canImport(Translation)
        if #available(macOS 15.0, *) {
            guard let containerView = parentWindow?.contentView else {
                openSystemLocalizationSettings()
                onFinished(false, "Ayarlar penceresi bulunamadı; Sistem Ayarları açıldı.")
                return
            }

            let token = UUID()
            activeToken = token

            let rootView = AppleTranslationInlineTriggerView(
                id: token,
                sourceCode: src,
                targetCode: tgt,
                onResult: { success, msg in
                    DispatchQueue.main.async {
                        guard activeToken == token else { return }
                        cleanup()
                        onFinished(success, msg)
                    }
                }
            )
            let host = NSHostingView(rootView: rootView)
            host.frame = NSRect(x: 0, y: 0, width: 1, height: 1)
            host.alphaValue = 0.01
            containerView.addSubview(host)
            activeHostView = host

            parentWindow?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        #endif

        onFinished(false, "Apple çeviri paketi indirme arayüzü için macOS 15.0+ gereklidir.")
    }
}

#if canImport(SwiftUI) && canImport(Translation)
@available(macOS 15.0, *)
private struct AppleTranslationInlineTriggerView: View {
    let id: UUID
    let sourceCode: String
    let targetCode: String
    let onResult: (Bool, String) -> Void

    var body: some View {
        Color.clear
            .frame(width: 1, height: 1)
            .id(id)
            .translationTask(
                source: Locale.Language(identifier: sourceCode),
                target: Locale.Language(identifier: targetCode)
            ) { session in
                do {
                    try await session.prepareTranslation()
                    AppleLocalTranslationEngine.shared.invalidateCache()
                    let st = await AppleLocalTranslationEngine.shared.status(from: sourceCode, to: targetCode)
                    if st == .installed {
                        await AppleLocalTranslationEngine.shared.warmSession(from: sourceCode, to: targetCode)
                        onResult(true, "✅ \(sourceCode.uppercased()) → \(targetCode.uppercased()) Apple ANE paketi kuruldu ve hazır.")
                    } else {
                        onResult(false, "⬇️ İndirme arka planda devam ediyor (\(sourceCode.uppercased()) → \(targetCode.uppercased())).")
                    }
                } catch {
                    onResult(false, "⬇️ İndirme penceresi kapatıldı veya arka planda devam ediyor.")
                }
            }
    }
}
#endif
