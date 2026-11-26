import Foundation

/// Owns one dictation's speculative and final translation requests.
/// All methods and state transitions run on the main thread.
final class LiveTranslationCoordinator {
    typealias CancelRequest = () -> Void
    typealias Request = (String, @escaping (TranslationResult) -> Void) -> CancelRequest?

    private struct PendingInterim {
        let id: Int
        let rawPrefix: String
        let sourcePrefix: String
        let separator: String
        var cancel: CancelRequest?
    }

    struct Segment: Equatable {
        let separator: String
        let text: String
    }

    private let polish: (String) -> String
    private let request: Request
    private let livePreviewRequest: Request?
    private let livePreviewDebounceInterval: TimeInterval
    private let onLivePreview: ((String) -> Void)?
    private let maxChunkLength: Int
    private let maxEarlyRequests: Int
    private let maxConcurrentFinalRequests: Int
    private var previousInterim = ""
    private var latestInterim = ""
    private var cachedRawPrefix = ""
    private var cachedSourcePrefix = ""
    private var cachedTranslation = ""
    private var pendingInterim: PendingInterim?
    private var previewTimer: DispatchWorkItem?
    private var previewCancel: CancelRequest?
    private var previewGeneration = 0
    private var lastPreviewSourceRaw = ""
    private var lastPreviewSourcePolished = ""
    private var lastPreviewTranslated = ""
    private var earlyRequestCount = 0
    private var earlyDisabled = false
    private var nextID = 0
    private var cancelled = false
    private var finishing = false
    private var finalText = ""
    private var finalPrefix = ""
    private var finalTrailingWhitespace = ""
    private var finalSegments: [Segment] = []
    private var finalResults: [Int: String] = [:]
    private var finalRequests: [Int: CancelRequest] = [:]
    private var nextFinalIndex = 0
    private var finalCompletion: ((TranslationResult) -> Void)?

    init(
        maxChunkLength: Int = 600,
        maxEarlyRequests: Int = 20,
        maxConcurrentFinalRequests: Int = 3,
        livePreviewDebounceInterval: TimeInterval = 0.14,
        polish: @escaping (String) -> String,
        request: @escaping Request,
        livePreviewRequest: Request? = nil,
        onLivePreview: ((String) -> Void)? = nil
    ) {
        self.maxChunkLength = max(1, maxChunkLength)
        self.maxEarlyRequests = max(0, maxEarlyRequests)
        self.maxConcurrentFinalRequests = max(1, maxConcurrentFinalRequests)
        self.livePreviewDebounceInterval = max(0.02, livePreviewDebounceInterval)
        self.polish = polish
        self.request = request
        self.livePreviewRequest = livePreviewRequest
        self.onLivePreview = onLivePreview
    }

    func observe(_ text: String) {
        guard !cancelled, !finishing else { return }
        previousInterim = latestInterim
        latestInterim = text.trimmingCharacters(in: .whitespacesAndNewlines)

        if !cachedRawPrefix.isEmpty && !Self.isWholePrefix(cachedRawPrefix, of: latestInterim) {
            clearInterimCache()
        }
        if let pending = pendingInterim, !Self.isWholePrefix(pending.rawPrefix, of: latestInterim) {
            pending.cancel?()
            pendingInterim = nil
        }
        if !lastPreviewSourceRaw.isEmpty && !Self.isWholePrefix(lastPreviewSourceRaw, of: latestInterim) && latestInterim != lastPreviewSourceRaw {
            clearPreviewState()
        }
        scheduleInterimIfPossible()
        if livePreviewRequest != nil {
            scheduleLivePreview()
        } else if !cachedTranslation.isEmpty {
            emitCommittedPreviewWithTail()
        }
    }

    /// The original provider failed or was replaced; none of its partials may be reused.
    func invalidateInterims() {
        guard !finishing, !cancelled else { return }
        pendingInterim?.cancel?()
        pendingInterim = nil
        clearPreviewState()
        clearInterimCache()
        earlyDisabled = true
    }

    func finish(text: String, completion: @escaping (TranslationResult) -> Void) {
        guard !cancelled, !finishing else { return }
        finishing = true
        pendingInterim?.cancel?()
        pendingInterim = nil
        previewTimer?.cancel()
        previewTimer = nil
        previewCancel?()
        previewCancel = nil
        finalText = text
        finalCompletion = completion

        let trailingWS = String(text.reversed().prefix { $0.isWhitespace }.reversed())
        let leadingWS = String(text.prefix { $0.isWhitespace })
        let trimmedFinal = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !lastPreviewTranslated.isEmpty &&
            lastPreviewSourcePolished.trimmingCharacters(in: .whitespacesAndNewlines) == trimmedFinal &&
            !trimmedFinal.isEmpty {
            let exactHit = leadingWS + lastPreviewTranslated + trailingWS
            clearPreviewState()
            clearInterimCache()
            previousInterim = ""
            latestInterim = ""
            completeFinal(TranslationResult(text: exactHit, wasFallback: false))
            return
        }
        clearPreviewState()

        let remainder: String
        if !cachedSourcePrefix.isEmpty && Self.isWholePrefix(cachedSourcePrefix, of: text) {
            finalPrefix = cachedTranslation
            remainder = String(text.dropFirst(cachedSourcePrefix.count))
        } else {
            finalPrefix = ""
            remainder = text
        }
        clearInterimCache()
        previousInterim = ""
        latestInterim = ""
        finalTrailingWhitespace = String(remainder.reversed().prefix { $0.isWhitespace }.reversed())
        let body = String(remainder.dropLast(finalTrailingWhitespace.count))
        finalSegments = Self.splitFinalText(body, maxLength: maxChunkLength)
        if finalSegments.isEmpty {
            completeFinal(TranslationResult(text: finalPrefix + finalTrailingWhitespace, wasFallback: false))
        } else {
            scheduleFinalRequests()
        }
    }

    func cancel() {
        guard !cancelled else { return }
        cancelled = true
        pendingInterim?.cancel?()
        pendingInterim = nil
        clearPreviewState()
        let cancellations = Array(finalRequests.values)
        finalRequests.removeAll()
        cancellations.forEach { $0() }
        finalCompletion = nil
        clearInterimCache()
        previousInterim = ""
        latestInterim = ""
        finalText = ""
        finalPrefix = ""
        finalTrailingWhitespace = ""
        finalSegments.removeAll()
        finalResults.removeAll()
    }

    private func clearInterimCache() {
        cachedRawPrefix = ""
        cachedSourcePrefix = ""
        cachedTranslation = ""
    }

    private func clearPreviewState() {
        previewGeneration += 1
        previewTimer?.cancel()
        previewTimer = nil
        previewCancel?()
        previewCancel = nil
        lastPreviewSourceRaw = ""
        lastPreviewSourcePolished = ""
        lastPreviewTranslated = ""
    }

    private func emitCommittedPreviewWithTail() {
        guard !cancelled, !finishing, !cachedTranslation.isEmpty else { return }
        let tail: String
        if !cachedRawPrefix.isEmpty && Self.isWholePrefix(cachedRawPrefix, of: latestInterim) {
            tail = String(latestInterim.dropFirst(cachedRawPrefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            tail = ""
        }
        if tail.isEmpty {
            onLivePreview?(cachedTranslation)
        } else {
            onLivePreview?(cachedTranslation + " · " + tail)
        }
    }

    private func scheduleLivePreview() {
        guard !cancelled, !finishing, let livePreviewRequest else { return }
        let rawSnapshot = latestInterim
        guard !rawSnapshot.isEmpty else { return }

        previewTimer?.cancel()
        previewTimer = nil
        previewGeneration += 1
        let gen = previewGeneration

        if rawSnapshot == lastPreviewSourceRaw, !lastPreviewTranslated.isEmpty {
            previewCancel?()
            previewCancel = nil
            return
        }

        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.cancelled, !self.finishing, self.previewGeneration == gen else { return }
            guard self.latestInterim == rawSnapshot else { return }

            let polishedFull = self.polish(rawSnapshot)
            let cachedRaw = self.cachedRawPrefix
            let cachedSource = self.cachedSourcePrefix
            let cachedTranslated = self.cachedTranslation
            let chunk: String
            let baseTranslation: String
            let separator: String

            if !cachedRaw.isEmpty &&
                Self.isWholePrefix(cachedRaw, of: rawSnapshot) &&
                Self.isWholePrefix(cachedSource, of: polishedFull) {
                let delta = String(polishedFull.dropFirst(cachedSource.count))
                let split = Self.separateLeadingWhitespace(delta)
                separator = split.0.isEmpty && !cachedTranslated.isEmpty ? " " : split.0
                chunk = split.1
                baseTranslation = cachedTranslated
            } else {
                separator = ""
                chunk = polishedFull.trimmingCharacters(in: .whitespacesAndNewlines)
                baseTranslation = ""
            }

            if chunk.isEmpty {
                if !baseTranslation.isEmpty {
                    self.lastPreviewSourceRaw = rawSnapshot
                    self.lastPreviewSourcePolished = polishedFull
                    self.lastPreviewTranslated = baseTranslation
                    self.onLivePreview?(baseTranslation)
                }
                return
            }

            guard chunk.count <= self.maxChunkLength else { return }

            self.previewCancel?()
            let cancel = livePreviewRequest(chunk) { [weak self] result in
                DispatchQueue.main.async { [weak self] in
                    guard let self, !self.cancelled, !self.finishing else { return }
                    guard self.previewGeneration == gen else { return }
                    self.previewCancel = nil
                    guard !result.wasFallback else { return }
                    let translatedPart = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !translatedPart.isEmpty else { return }
                    let combined = baseTranslation.isEmpty
                        ? translatedPart
                        : (baseTranslation + separator + translatedPart)
                    self.lastPreviewSourceRaw = rawSnapshot
                    self.lastPreviewSourcePolished = polishedFull
                    self.lastPreviewTranslated = combined
                    self.onLivePreview?(combined)
                }
            }
            if self.previewGeneration == gen {
                self.previewCancel = cancel
            } else {
                cancel?()
            }
        }
        previewTimer = work
        DispatchQueue.main.asyncAfter(deadline: .now() + livePreviewDebounceInterval, execute: work)
    }

    private func scheduleInterimIfPossible() {
        guard !earlyDisabled, pendingInterim == nil,
              earlyRequestCount < maxEarlyRequests,
              !previousInterim.isEmpty, !latestInterim.isEmpty else { return }

        // A boundary must exist in two consecutive recognizer results. The full
        // polished prefix is checked again against the final transcript at delivery.
        let common = Array(zip(previousInterim, latestInterim).prefix { $0 == $1 }.map { $0.0 })
        let cachedLength = cachedRawPrefix.count
        let boundaries = Self.completedSentenceEnds(in: common, after: cachedLength, maxLength: maxChunkLength)
        for end in boundaries.reversed() {
            let rawPrefix = String(common[..<end])
            guard Self.isWholePrefix(cachedRawPrefix, of: rawPrefix),
                  Self.isWholePrefix(rawPrefix, of: previousInterim),
                  Self.isWholePrefix(rawPrefix, of: latestInterim) else { continue }

            let sourcePrefix = polish(rawPrefix)
            guard Self.isWholePrefix(cachedSourcePrefix, of: sourcePrefix) else { continue }
            let delta = String(sourcePrefix.dropFirst(cachedSourcePrefix.count))
            let (separator, chunk) = Self.separateLeadingWhitespace(delta)
            guard !chunk.isEmpty, chunk.count <= maxChunkLength else { continue }

            nextID += 1
            let id = nextID
            pendingInterim = PendingInterim(id: id, rawPrefix: rawPrefix, sourcePrefix: sourcePrefix,
                                            separator: separator, cancel: nil)
            earlyRequestCount += 1
            let cancellation = request(chunk) { [weak self] result in
                DispatchQueue.main.async { [weak self] in self?.receiveInterim(result, id: id) }
            }
            if pendingInterim?.id == id { pendingInterim?.cancel = cancellation }
            return
        }
    }

    private func receiveInterim(_ result: TranslationResult, id: Int) {
        guard !cancelled, !finishing, let pending = pendingInterim, pending.id == id else { return }
        pendingInterim = nil
        guard Self.isWholePrefix(pending.rawPrefix, of: latestInterim) else { return }
        guard !result.wasFallback, !result.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            clearInterimCache()
            earlyDisabled = true
            return
        }
        cachedRawPrefix = pending.rawPrefix
        cachedSourcePrefix = pending.sourcePrefix
        cachedTranslation += pending.separator + result.text
        if livePreviewRequest != nil {
            lastPreviewSourceRaw = pending.rawPrefix
            lastPreviewSourcePolished = pending.sourcePrefix
            lastPreviewTranslated = cachedTranslation
            emitCommittedPreviewWithTail()
            scheduleLivePreview()
        } else {
            emitCommittedPreviewWithTail()
        }
        scheduleInterimIfPossible()
    }

    private func scheduleFinalRequests() {
        while !cancelled, finalCompletion != nil,
              finalRequests.count < maxConcurrentFinalRequests,
              nextFinalIndex < finalSegments.count {
            let index = nextFinalIndex
            nextFinalIndex += 1
            // Install the entry before calling a request that may complete synchronously.
            finalRequests[index] = {}
            let cancellation = request(finalSegments[index].text) { [weak self] result in
                DispatchQueue.main.async { [weak self] in self?.receiveFinal(result, index: index) }
            }
            if finalRequests[index] != nil { finalRequests[index] = cancellation ?? {} }
        }
    }

    private func receiveFinal(_ result: TranslationResult, index: Int) {
        guard !cancelled, finalCompletion != nil, finalRequests.removeValue(forKey: index) != nil else { return }
        guard !result.wasFallback, !result.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            let cancellations = Array(finalRequests.values)
            finalRequests.removeAll()
            cancellations.forEach { $0() }
            completeFinal(TranslationResult(text: finalText, wasFallback: true,
                                            errorMessage: result.errorMessage ?? "Çeviri parçası boş döndü"))
            return
        }
        finalResults[index] = result.text
        if finalResults.count == finalSegments.count {
            let translated = finalSegments.enumerated().map { index, segment in
                segment.separator + (finalResults[index] ?? "")
            }.joined()
            completeFinal(TranslationResult(text: finalPrefix + translated + finalTrailingWhitespace, wasFallback: false))
        } else {
            scheduleFinalRequests()
        }
    }

    private func completeFinal(_ result: TranslationResult) {
        let completion = finalCompletion
        finalCompletion = nil
        finalRequests.removeAll()
        completion?(result)
    }

    private static func isWholePrefix(_ prefix: String, of text: String) -> Bool {
        guard text.hasPrefix(prefix) else { return false }
        if prefix.isEmpty || prefix.count == text.count { return true }
        return text.dropFirst(prefix.count).first?.isWhitespace == true
    }

    private static func separateLeadingWhitespace(_ text: String) -> (String, String) {
        let whitespace = text.prefix { $0.isWhitespace }
        return (String(whitespace), String(text.dropFirst(whitespace.count)))
    }

    private static func completedSentenceEnds(in characters: [Character], after start: Int, maxLength: Int) -> [Int] {
        let abbreviations: Set<String> = ["dr.", "mr.", "mrs.", "ms.", "prof.", "ör.", "vb.", "vs."]
        let upper = min(characters.count, start + maxLength)
        guard start < upper else { return [] }
        var ends: [Int] = []
        for index in start..<upper where ".!?".contains(characters[index]) {
            var end = index + 1
            while end < upper && "\"'”’»)]}".contains(characters[end]) { end += 1 }
            guard end == characters.count || (end < characters.count && characters[end].isWhitespace) else { continue }
            if characters[index] == "." {
                var wordStart = index
                while wordStart > 0 && !characters[wordStart - 1].isWhitespace { wordStart -= 1 }
                let word = String(characters[wordStart...index]).lowercased()
                if abbreviations.contains(word) || word.dropLast().allSatisfy({ $0.isNumber }) { continue }
            }
            ends.append(end)
        }
        return ends
    }

    /// Preserve every separator. Prefer sentence boundaries, then word boundaries.
    /// A single long token is kept intact rather than silently split or discarded.
    static func splitFinalText(_ text: String, maxLength: Int) -> [Segment] {
        let chars = Array(text)
        let limit = max(1, maxLength)
        var segments: [Segment] = []
        var position = 0
        while position < chars.count {
            let separatorStart = position
            while position < chars.count && chars[position].isWhitespace { position += 1 }
            let separator = String(chars[separatorStart..<position])
            guard position < chars.count else {
                if !separator.isEmpty, !segments.isEmpty {
                    let last = segments.removeLast()
                    segments.append(Segment(separator: last.separator, text: last.text + separator))
                }
                break
            }
            let start = position
            let tentative = min(start + limit, chars.count)
            var end = tentative
            if tentative < chars.count && !chars[tentative].isWhitespace {
                if let space = (start..<tentative).last(where: { chars[$0].isWhitespace }) {
                    end = space
                } else {
                    while end < chars.count && !chars[end].isWhitespace { end += 1 }
                }
            }
            if end < chars.count, let sentenceEnd = (start..<end).last(where: { index in
                ".!?".contains(chars[index]) && index + 1 < chars.count && chars[index + 1].isWhitespace
            }), sentenceEnd + 1 - start >= limit / 3 {
                end = sentenceEnd + 1
            }
            segments.append(Segment(separator: separator, text: String(chars[start..<end])))
            position = end
        }
        return segments
    }
}
