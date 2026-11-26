import Foundation
import AVFoundation
import CoreMedia
import Speech

// MARK: - Apple Silicon ANE Konuşma Motoru Desteği (macOS 26+ SpeechAnalyzer)

public struct AppleANEDiagnostics: Sendable {
    public let isAvailable: Bool
    public let activeLocale: String
    public let activeEngine: String
    public let activeLocaleInstalled: Bool
    public let installedLocales: [String]
    public let reservedLocales: [String]
    public let maxReservedLocales: Int
    public let supportedCount: Int
    public let speechInstalled: Set<String>
    public let dictationInstalled: Set<String>
    public let speechSupported: Set<String>
    public let dictationSupported: Set<String>
    public let osVersionString: String
}

public enum AppleSpeechAnalyzerSupport {
    public static var isAvailableOnCurrentOS: Bool {
        if #available(macOS 26.0, *) {
            return true
        }
        return false
    }

    private static func currentOSVersionString() -> String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return "macOS \(v.majorVersion).\(v.minorVersion)"
    }

    /// Desteklenen/kurulu yerel dilleri döner (macOS 26+ ANE; eski sistemde boş).
    public static func fetchInstalledLocales(completion: @escaping ([String]) -> Void) {
        guard #available(macOS 26.0, *) else {
            completion([])
            return
        }
        Task {
            let speechLocs = await SpeechTranscriber.installedLocales.map(normalizedLocaleId)
            let dictLocs = await DictationTranscriber.installedLocales.map(normalizedLocaleId)
            let combined = Array(Set(speechLocs + dictLocs)).sorted()
            completion(combined)
        }
    }

    /// Aktif dil, motor, kurulu paketler ve UAF slotları dahil tam ANE tanılama bilgisini döner.
    public static func fetchDiagnostics(
        for language: String,
        completion: @escaping (AppleANEDiagnostics) -> Void
    ) {
        guard #available(macOS 26.0, *) else {
            completion(AppleANEDiagnostics(
                isAvailable: false,
                activeLocale: appleSpeechLocaleIdentifier(for: language),
                activeEngine: "SFSpeechRecognizer",
                activeLocaleInstalled: false,
                installedLocales: [],
                reservedLocales: [],
                maxReservedLocales: 0,
                supportedCount: 0,
                speechInstalled: [],
                dictationInstalled: [],
                speechSupported: [],
                dictationSupported: [],
                osVersionString: currentOSVersionString()
            ))
            return
        }

        Task {
            let speechInstRaw = await SpeechTranscriber.installedLocales.map(normalizedLocaleId)
            let dictInstRaw = await DictationTranscriber.installedLocales.map(normalizedLocaleId)
            let speechSupRaw = await SpeechTranscriber.supportedLocales.map(normalizedLocaleId)
            let dictSupRaw = await DictationTranscriber.supportedLocales.map(normalizedLocaleId)
            let reserved = await AssetInventory.reservedLocales.map(normalizedLocaleId).sorted()
            let maxReserved = AssetInventory.maximumReservedLocales

            let speechInst = Set(speechInstRaw.map { $0.lowercased() })
            let dictInst = Set(dictInstRaw.map { $0.lowercased() })
            let speechSup = Set(speechSupRaw.map { $0.lowercased() })
            let dictSup = Set(dictSupRaw.map { $0.lowercased() })

            let resolved = await resolveANEModule(for: language, progressive: true)
            let activeLoc = resolved.map { normalizedLocaleId($0.locale) }
                ?? appleSpeechLocaleIdentifier(for: language).replacingOccurrences(of: "_", with: "-")
            let activeEng = resolved?.kind.rawValue ?? "SpeechAnalyzer"
            let activeInstalled: Bool
            if let mod = resolved?.module {
                activeInstalled = await AssetInventory.status(forModules: [mod]) == .installed
            } else {
                activeInstalled = false
            }

            // Kullanıcının kullandığı temel dilleri listenin en başına al (`de-AT` altında kaybolmasın)
            let priorityOrder = ["tr-tr", "nl-nl", "en-us", "en-gb", "de-de", "fr-fr", "es-es"]
            let reservedSet = Set(reserved.map { $0.lowercased() })
            let allInstalled = Array(Set(speechInstRaw + dictInstRaw)).sorted { a, b in
                let al = a.lowercased(), bl = b.lowercased()
                let aActive = al == activeLoc.lowercased()
                let bActive = bl == activeLoc.lowercased()
                if aActive != bActive { return aActive }

                let aRes = reservedSet.contains(al), bRes = reservedSet.contains(bl)
                if aRes != bRes { return aRes }

                let aIdx = priorityOrder.firstIndex(of: al) ?? Int.max
                let bIdx = priorityOrder.firstIndex(of: bl) ?? Int.max
                if aIdx != bIdx { return aIdx < bIdx }
                return a < b
            }

            let supportedTotal = Set(speechSupRaw + dictSupRaw).count
            completion(AppleANEDiagnostics(
                isAvailable: true,
                activeLocale: activeLoc,
                activeEngine: activeEng,
                activeLocaleInstalled: activeInstalled,
                installedLocales: allInstalled,
                reservedLocales: reserved,
                maxReservedLocales: maxReserved,
                supportedCount: supportedTotal,
                speechInstalled: speechInst,
                dictationInstalled: dictInst,
                speechSupported: speechSup,
                dictationSupported: dictSup,
                osVersionString: currentOSVersionString()
            ))
        }
    }

    /// Dil modelini arka planda hazırlar; kurulu değilse Apple UAF üzerinden canlı ilerleme ile indirip etkinleştirir.
    public static func prewarmAndEnsureLocale(
        _ language: String,
        onProgress: ((Double, String) -> Void)? = nil,
        completion: ((Bool, String) -> Void)? = nil
    ) {
        guard #available(macOS 26.0, *) else {
            completion?(false, "SpeechAnalyzer için macOS 26+ gerekir.")
            return
        }
        Task {
            let result = await ensureLocaleAsset(language: language, onProgress: onProgress)
            completion?(result.ok, result.message)
        }
    }

    /// WAV ses verisini Apple Silicon ANE (`SpeechAnalyzer`) ile çevrimdışı çözer.
    public static func transcribeWAV(
        _ audioData: Data,
        language: String,
        completion: @escaping (TranscriptionResult) -> Void
    ) {
        guard #available(macOS 26.0, *) else {
            completion(TranscriptionResult(
                success: false,
                text: "",
                latency: 0,
                error: "SpeechAnalyzer yalnızca macOS 26+ üzerinde desteklenir.",
                provider: "apple",
                model: "SFSpeechRecognizer"
            ))
            return
        }

        Task {
            let result = await performWAVTranscription(audioData: audioData, language: language)
            completion(result)
        }
    }
}

// MARK: - macOS 26+ Dahili ANE Yardımcıları

@available(macOS 26.0, *)
private enum SelectedANEModuleKind: String {
    case speech = "SpeechTranscriber"
    case dictation = "DictationTranscriber"
}

@available(macOS 26.0, *)
private func normalizedLocaleId(_ locale: Locale) -> String {
    let bcp = locale.identifier(.bcp47)
    if !bcp.isEmpty { return bcp }
    return locale.identifier.replacingOccurrences(of: "_", with: "-")
}

@available(macOS 26.0, *)
private func resolveANEModule(
    for language: String,
    progressive: Bool
) async -> (kind: SelectedANEModuleKind, locale: Locale, module: any SpeechModule)? {
    let rawId = appleSpeechLocaleIdentifier(for: language).replacingOccurrences(of: "_", with: "-")
    let requested = Locale(identifier: rawId)

    let speechLoc = await SpeechTranscriber.supportedLocale(equivalentTo: requested)
    let dictLoc = await DictationTranscriber.supportedLocale(equivalentTo: requested)

    let speechInstalled = Set(await SpeechTranscriber.installedLocales.map { normalizedLocaleId($0).lowercased() })
    let dictInstalled = Set(await DictationTranscriber.installedLocales.map { normalizedLocaleId($0).lowercased() })

    let speechReady = speechLoc.map { speechInstalled.contains(normalizedLocaleId($0).lowercased()) } ?? false
    let dictReady = dictLoc.map { dictInstalled.contains(normalizedLocaleId($0).lowercased()) } ?? false

    func makeSpeech(_ loc: Locale) -> (SelectedANEModuleKind, Locale, any SpeechModule) {
        let preset: SpeechTranscriber.Preset = progressive
            ? .progressiveTranscription
            : .timeIndexedTranscriptionWithAlternatives
        return (.speech, loc, SpeechTranscriber(locale: loc, preset: preset))
    }

    func makeDictation(_ loc: Locale) -> (SelectedANEModuleKind, Locale, any SpeechModule) {
        let preset: DictationTranscriber.Preset = progressive
            ? .progressiveLongDictation
            : .timeIndexedLongDictation
        return (.dictation, loc, DictationTranscriber(locale: loc, preset: preset))
    }

    if speechReady, let loc = speechLoc {
        return makeSpeech(loc)
    }
    if dictReady, let loc = dictLoc {
        return makeDictation(loc)
    }
    if let loc = speechLoc {
        return makeSpeech(loc)
    }
    if let loc = dictLoc {
        return makeDictation(loc)
    }
    return nil
}

@available(macOS 26.0, *)
private func ensureModuleInstalled(
    _ module: any SpeechModule,
    locale: Locale? = nil,
    onProgress: ((Double, String) -> Void)? = nil
) async throws -> Bool {
    let modules: [any SpeechModule] = [module]
    var status = await AssetInventory.status(forModules: modules)
    if status == .installed {
        onProgress?(1.0, "Kurulu")
        return true
    }

    // Apple rezerve dil slotu (genelde 5) dolduysa, hedef dışı bir slotu serbest bırak
    if let locale {
        let targetId = normalizedLocaleId(locale).lowercased()
        let reserved = await AssetInventory.reservedLocales
        let maxSlots = AssetInventory.maximumReservedLocales
        if reserved.count >= maxSlots && !reserved.contains(where: { normalizedLocaleId($0).lowercased() == targetId }) {
            let activeCfgId = appleSpeechLocaleIdentifier(for: ConfigManager.shared.config.language).lowercased()
            if let victim = reserved.first(where: {
                let id = normalizedLocaleId($0).lowercased()
                return id != "tr-tr" && id != activeCfgId
            }) ?? reserved.first {
                _ = await AssetInventory.release(reservedLocale: victim)
            }
        }
    }

    if let request = try await AssetInventory.assetInstallationRequest(supporting: modules) {
        let progress = request.progress
        let pollTask = Task {
            while !Task.isCancelled {
                let frac = max(0.02, min(0.99, progress.fractionCompleted))
                let pct = Int((frac * 100.0).rounded())
                onProgress?(frac, "%\(pct)")
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
        }
        defer { pollTask.cancel() }
        try await request.downloadAndInstall()
    }
    status = await AssetInventory.status(forModules: modules)
    if status == .installed {
        onProgress?(1.0, "%100")
    }
    return status == .installed
}

@available(macOS 26.0, *)
private func ensureLocaleAsset(
    language: String,
    onProgress: ((Double, String) -> Void)? = nil
) async -> (ok: Bool, message: String) {
    guard let resolved = await resolveANEModule(for: language, progressive: true) else {
        return (false, "Dil (\(language)) SpeechAnalyzer tarafından desteklenmiyor.")
    }
    let locId = normalizedLocaleId(resolved.locale)
    do {
        let ok = try await ensureModuleInstalled(resolved.module, locale: resolved.locale, onProgress: onProgress)
        if ok {
            return (true, "🟢 Aktif: \(locId) · SpeechAnalyzer + \(resolved.kind.rawValue) (ANE · Çevrimdışı)")
        }
        return (false, "🟡 \(locId) modeli henüz indirilemedi.")
    } catch {
        return (false, "🔴 \(locId) model indirme hatası: \(error.localizedDescription)")
    }
}

@available(macOS 26.0, *)
private func wavDataWithTrailingSilence(_ wavData: Data, silenceSeconds: Double = 0.28) -> Data {
    // Standart 44 bayt RIFF/WAVE PCM16 16kHz mono başlığına 280 ms sessizlik ekleyerek
    // son hecenin ANE decoder kuyruğunda kesilmesini engeller.
    guard wavData.count > 44,
          String(data: wavData.prefix(4), encoding: .ascii) == "RIFF",
          String(data: wavData.subdata(in: 8..<12), encoding: .ascii) == "WAVE" else {
        return wavData
    }
    let channels = wavData.withUnsafeBytes { raw -> UInt16 in
        raw.load(fromByteOffset: 22, as: UInt16.self).littleEndian
    }
    let sampleRate = wavData.withUnsafeBytes { raw -> UInt32 in
        raw.load(fromByteOffset: 24, as: UInt32.self).littleEndian
    }
    let bitsPerSample = wavData.withUnsafeBytes { raw -> UInt16 in
        raw.load(fromByteOffset: 34, as: UInt16.self).littleEndian
    }
    guard channels > 0, sampleRate > 0, bitsPerSample == 16 else {
        return wavData
    }
    let bytesPerSecond = Int(sampleRate) * Int(channels) * 2
    let extraBytes = max(0, Int(Double(bytesPerSecond) * silenceSeconds) & ~3)
    guard extraBytes > 0 else { return wavData }

    var out = Data(capacity: wavData.count + extraBytes)
    out.append(wavData)
    out.append(Data(repeating: 0, count: extraBytes))

    // RIFF dosya boyutunu (ofset 4) ve data parça boyutunu güncelle (ofset 40 "data" ise)
    if String(data: wavData.subdata(in: 36..<40), encoding: .ascii) == "data" {
        let riffSize = UInt32(out.count - 8).littleEndian
        let dataSize = UInt32(out.count - 44).littleEndian
        out.replaceSubrange(4..<8, with: withUnsafeBytes(of: riffSize) { Data($0) })
        out.replaceSubrange(40..<44, with: withUnsafeBytes(of: dataSize) { Data($0) })
    }
    return out
}

@available(macOS 26.0, *)
private func performWAVTranscription(audioData: Data, language: String) async -> TranscriptionResult {
    let startTime = CFAbsoluteTimeGetCurrent()
    guard let resolved = await resolveANEModule(for: language, progressive: false) else {
        return TranscriptionResult(
            success: false,
            text: "",
            latency: 0,
            error: "SpeechAnalyzer dil eşleşmesi bulunamadı: \(language)",
            provider: "apple",
            model: "SpeechAnalyzer (ANE)"
        )
    }

    let modelLabel = "SpeechAnalyzer-\(resolved.kind.rawValue) (ANE)"
    do {
        let installed = try await ensureModuleInstalled(resolved.module)
        guard installed else {
            return TranscriptionResult(
                success: false,
                text: "",
                latency: CFAbsoluteTimeGetCurrent() - startTime,
                error: "Apple ANE dil modeli kurulamadı.",
                provider: "apple",
                model: modelLabel
            )
        }
    } catch {
        return TranscriptionResult(
            success: false,
            text: "",
            latency: CFAbsoluteTimeGetCurrent() - startTime,
            error: "Apple ANE model indirme hatası: \(error.localizedDescription)",
            provider: "apple",
            model: modelLabel
        )
    }

    let tempURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("voicetyping_ane_\(UUID().uuidString).wav")
    defer { try? FileManager.default.removeItem(at: tempURL) }

    do {
        let padded = wavDataWithTrailingSilence(audioData)
        try padded.write(to: tempURL)
        let audioFile = try AVAudioFile(forReading: tempURL)

        let text: String
        if let speechMod = resolved.module as? SpeechTranscriber {
            let collectTask = Task { () throws -> String in
                var parts: [String] = []
                for try await res in speechMod.results where res.isFinal {
                    let s = String(res.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
                    if !s.isEmpty { parts.append(s) }
                }
                return parts.joined(separator: " ")
            }
            let analyzer = SpeechAnalyzer(modules: [speechMod])
            _ = try await analyzer.analyzeSequence(from: audioFile)
            try await analyzer.finalizeAndFinishThroughEndOfInput()
            text = try await collectTask.value
        } else if let dictMod = resolved.module as? DictationTranscriber {
            let collectTask = Task { () throws -> String in
                var parts: [String] = []
                for try await res in dictMod.results where res.isFinal {
                    let s = String(res.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
                    if !s.isEmpty { parts.append(s) }
                }
                return parts.joined(separator: " ")
            }
            let analyzer = SpeechAnalyzer(modules: [dictMod])
            _ = try await analyzer.analyzeSequence(from: audioFile)
            try await analyzer.finalizeAndFinishThroughEndOfInput()
            text = try await collectTask.value
        } else {
            text = ""
        }

        let latency = CFAbsoluteTimeGetCurrent() - startTime
        return TranscriptionResult(
            success: true,
            text: text.trimmingCharacters(in: .whitespacesAndNewlines),
            latency: latency,
            error: nil,
            provider: "apple",
            model: modelLabel
        )
    } catch {
        return TranscriptionResult(
            success: false,
            text: "",
            latency: CFAbsoluteTimeGetCurrent() - startTime,
            error: "SpeechAnalyzer WAV hatası: \(error.localizedDescription)",
            provider: "apple",
            model: modelLabel
        )
    }
}

// MARK: - Canlı Mikrofon Akış Oturumu (Apple Silicon ANE SpeechAnalyzer)

@available(macOS 26.0, *)
public final class LiveAppleSpeechAnalyzerSession: NSObject, LiveStreamSession, @unchecked Sendable {
    public let language: String
    public let customVocabulary: String

    public var onInterim: ((String) -> Void)?
    public var onCompletion: ((TranscriptionResult) -> Void)?

    private let sourceFormat = AVAudioFormat(
        commonFormat: .pcmFormatInt16,
        sampleRate: 16000,
        channels: 1,
        interleaved: true
    )!

    private let lock = NSLock()
    private var isStarted = false
    private var isAudioFinished = false
    private var isCancelled = false
    private var isCompleted = false
    private var isPipelineReady = false
    private var startTime: CFAbsoluteTime = 0

    private var pendingChunks: [Data] = []
    private var committedParts: [String] = []
    private var activeVolatileText = ""
    private var modelLabel = "SpeechAnalyzer (ANE)"

    private var inputContinuation: AsyncStream<AnalyzerInput>.Continuation?
    private var analyzer: SpeechAnalyzer?
    private var converter: AVAudioConverter?
    private var targetFormat: AVAudioFormat?
    private var sessionTask: Task<Void, Never>?
    private var resultsTask: Task<Void, Never>?

    public init(language: String = "tr", customVocabulary: String = "") {
        self.language = language
        self.customVocabulary = customVocabulary
        super.init()
    }

    public func start() {
        let shouldProceed: Bool = withLock {
            guard !isStarted, !isCancelled, !isCompleted else { return false }
            isStarted = true
            startTime = CFAbsoluteTimeGetCurrent()
            return true
        }
        guard shouldProceed else { return }

        // XCTest ortamında canlı TCC/UAF erişimi açmadan hızlı protokol doğrulaması yap
        if Bundle.main.bundleIdentifier == "com.apple.dt.xctest.tool" ||
           ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil {
            onInterim?("Test Denemesi")
            notifyCompletion(success: true, text: "Test Denemesi", error: nil)
            return
        }

        sessionTask = Task { [weak self] in
            await self?.runSession()
        }
    }

    public func sendAudioChunk(_ chunk: Data) {
        guard !chunk.isEmpty else { return }

        enum Action {
            case ignore
            case queued
            case send(AsyncStream<AnalyzerInput>.Continuation, AVAudioFormat, AVAudioConverter?)
        }

        let action: Action = withLock {
            guard isStarted, !isAudioFinished, !isCancelled, !isCompleted else {
                return .ignore
            }
            if !isPipelineReady {
                pendingChunks.append(chunk)
                return .queued
            }
            guard let cont = inputContinuation, let fmt = targetFormat else {
                return .ignore
            }
            return .send(cont, fmt, converter)
        }

        if case let .send(cont, fmt, conv) = action {
            yieldConvertedPCM(chunk, continuation: cont, targetFormat: fmt, converter: conv)
        }
    }

    public func finishAudio() {
        enum FinishAction {
            case ignore
            case markOnly
            case flush(AsyncStream<AnalyzerInput>.Continuation, AVAudioFormat, AVAudioConverter?)
        }

        let action: FinishAction = withLock {
            guard isStarted, !isAudioFinished, !isCancelled, !isCompleted else { return .ignore }
            isAudioFinished = true
            guard isPipelineReady, let cont = inputContinuation, let fmt = targetFormat else {
                return .markOnly
            }
            return .flush(cont, fmt, converter)
        }

        if case let .flush(cont, fmt, conv) = action {
            // Son hecenin ANE içinde kesilmemesi için 250 ms sessizlik besleyip akışı kapat
            let silenceTail = Data(repeating: 0, count: 8000)
            yieldConvertedPCM(silenceTail, continuation: cont, targetFormat: fmt, converter: conv)
            cont.finish()
        }
    }

    public func cancel() {
        let state = withLock { () -> (AsyncStream<AnalyzerInput>.Continuation?, SpeechAnalyzer?, Task<Void, Never>?, Task<Void, Never>?) in
            isCancelled = true
            isCompleted = true
            let c = inputContinuation
            let a = analyzer
            let r = resultsTask
            let s = sessionTask
            inputContinuation = nil
            analyzer = nil
            resultsTask = nil
            sessionTask = nil
            pendingChunks.removeAll()
            onInterim = nil
            onCompletion = nil
            return (c, a, r, s)
        }

        state.0?.finish()
        state.2?.cancel()
        state.3?.cancel()
        if let analyzerObj = state.1 {
            Task {
                await analyzerObj.cancelAndFinishNow()
            }
        }
    }

    private func runSession() async {
        guard let resolved = await resolveANEModule(for: language, progressive: true) else {
            notifyCompletion(
                success: false,
                text: "",
                error: "Apple ANE dikte modülü dil için bulunamadı (\(language))."
            )
            return
        }

        let label = "SpeechAnalyzer-\(resolved.kind.rawValue) (ANE)"
        withLock { modelLabel = label }

        do {
            let installed = try await ensureModuleInstalled(resolved.module)
            guard installed else {
                notifyCompletion(success: false, text: "", error: "Apple ANE dil modeli kurulumu tamamlanamadı.")
                return
            }
        } catch {
            notifyCompletion(success: false, text: "", error: "Apple ANE model hazırlama hatası: \(error.localizedDescription)")
            return
        }

        if withLock({ isCancelled || isCompleted }) { return }

        let modules: [any SpeechModule] = [resolved.module]
        let chosenFormat = await SpeechAnalyzer.bestAvailableAudioFormat(
            compatibleWith: modules,
            considering: sourceFormat
        ) ?? sourceFormat

        let audioConverter: AVAudioConverter?
        if chosenFormat == sourceFormat {
            audioConverter = nil
        } else {
            audioConverter = AVAudioConverter(from: sourceFormat, to: chosenFormat)
        }

        var streamContinuation: AsyncStream<AnalyzerInput>.Continuation!
        let inputStream = AsyncStream<AnalyzerInput> { continuation in
            streamContinuation = continuation
        }

        let speechAnalyzer = SpeechAnalyzer(modules: modules)

        // Başlangıç sırasında biriken tamponları al ve canlı akışı aç
        let snapshot = withLock { () -> ([Data], Bool, Bool) in
            if isCancelled || isCompleted { return ([], false, true) }
            self.analyzer = speechAnalyzer
            self.targetFormat = chosenFormat
            self.converter = audioConverter
            self.inputContinuation = streamContinuation
            self.isPipelineReady = true
            let queued = self.pendingChunks
            self.pendingChunks.removeAll()
            return (queued, self.isAudioFinished, false)
        }

        if snapshot.2 {
            streamContinuation.finish()
            return
        }

        for chunk in snapshot.0 {
            yieldConvertedPCM(chunk, continuation: streamContinuation, targetFormat: chosenFormat, converter: audioConverter)
        }

        if snapshot.1 {
            let silenceTail = Data(repeating: 0, count: 8000)
            yieldConvertedPCM(silenceTail, continuation: streamContinuation, targetFormat: chosenFormat, converter: audioConverter)
            streamContinuation.finish()
        }

        // Sonuç dinleyicisini başlat
        let rTask = Task { [weak self] in
            guard let self else { return }
            do {
                if let speechMod = resolved.module as? SpeechTranscriber {
                    for try await res in speechMod.results {
                        self.handleModuleResult(text: String(res.text.characters), isFinal: res.isFinal)
                    }
                } else if let dictMod = resolved.module as? DictationTranscriber {
                    for try await res in dictMod.results {
                        self.handleModuleResult(text: String(res.text.characters), isFinal: res.isFinal)
                    }
                }
            } catch {
                if !self.withLock({ self.isCancelled || self.isCompleted }) {
                    print("[AppleANE] Sonuç akışı uyarısı: \(error.localizedDescription)")
                }
            }
        }
        withLock { resultsTask = rTask }

        do {
            try await speechAnalyzer.start(inputSequence: inputStream)
            try await speechAnalyzer.finalizeAndFinishThroughEndOfInput()

            // Sonuç task'ının final segmenti teslim etmesini bekle (en fazla 3.5 sn)
            await waitForTaskWithTimeout(rTask, seconds: 3.5)

            let finalText = currentCombinedTranscript()
            notifyCompletion(success: true, text: finalText, error: nil)
        } catch {
            rTask.cancel()
            let collected = currentCombinedTranscript()
            if !collected.isEmpty {
                notifyCompletion(success: true, text: collected, error: nil)
            } else {
                notifyCompletion(
                    success: false,
                    text: "",
                    error: "SpeechAnalyzer akış hatası: \(error.localizedDescription)"
                )
            }
        }
    }

    private func waitForTaskWithTimeout(_ task: Task<Void, Never>, seconds: Double) async {
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await task.value }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            }
            await group.next()
            group.cancelAll()
        }
    }

    private func handleModuleResult(text: String, isFinal: Bool) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let (preview, callback): (String, ((String) -> Void)?) = withLock {
            guard !isCancelled, !isCompleted else { return ("", nil) }
            if isFinal {
                if !trimmed.isEmpty {
                    // Progressive sonuçlar bazen son segmenti tekrar edebilir; basit tekrar koruması
                    if committedParts.last != trimmed {
                        committedParts.append(trimmed)
                    }
                }
                activeVolatileText = ""
            } else {
                activeVolatileText = trimmed
            }
            let combined = (committedParts + (activeVolatileText.isEmpty ? [] : [activeVolatileText]))
                .joined(separator: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return (combined, onInterim)
        }
        if !preview.isEmpty {
            callback?(preview)
        }
    }

    private func currentCombinedTranscript() -> String {
        withLock {
            (committedParts + (activeVolatileText.isEmpty ? [] : [activeVolatileText]))
                .joined(separator: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    private func yieldConvertedPCM(
        _ chunk: Data,
        continuation: AsyncStream<AnalyzerInput>.Continuation,
        targetFormat: AVAudioFormat,
        converter: AVAudioConverter?
    ) {
        let frameCount = AVAudioFrameCount(chunk.count / MemoryLayout<Int16>.size)
        guard frameCount > 0,
              let inBuffer = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: frameCount) else {
            return
        }
        inBuffer.frameLength = frameCount
        chunk.withUnsafeBytes { rawBuffer in
            if let src = rawBuffer.baseAddress, let dst = inBuffer.int16ChannelData?[0] {
                memcpy(dst, src, chunk.count)
            }
        }

        if let converter {
            let ratio = targetFormat.sampleRate / sourceFormat.sampleRate
            let outCapacity = max(64, AVAudioFrameCount(ceil(Double(frameCount) * ratio)) + 32)
            guard let outBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outCapacity) else {
                return
            }
            var convError: NSError?
            var provided = false
            let status = converter.convert(to: outBuffer, error: &convError) { _, outStatus in
                if provided {
                    outStatus.pointee = .noDataNow
                    return nil
                }
                provided = true
                outStatus.pointee = .haveData
                return inBuffer
            }
            if status != .error && convError == nil && outBuffer.frameLength > 0 {
                continuation.yield(AnalyzerInput(buffer: outBuffer))
            }
        } else {
            continuation.yield(AnalyzerInput(buffer: inBuffer))
        }
    }

    private func notifyCompletion(success: Bool, text: String, error: String?) {
        let (cb, label, latency): (((TranscriptionResult) -> Void)?, String, Double) = withLock {
            guard !isCompleted, !isCancelled else { return (nil, modelLabel, 0) }
            isCompleted = true
            let c = onCompletion
            onCompletion = nil
            onInterim = nil
            let lat = max(0, CFAbsoluteTimeGetCurrent() - startTime)
            return (c, modelLabel, lat)
        }
        guard let cb else { return }
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        cb(TranscriptionResult(
            success: success,
            text: clean,
            latency: latency,
            error: error,
            provider: "apple",
            model: label
        ))
    }

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}
