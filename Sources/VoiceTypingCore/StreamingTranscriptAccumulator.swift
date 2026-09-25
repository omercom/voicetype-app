import Foundation

struct TimedTranscriptSegment: Equatable, Sendable {
    let startTime: TimeInterval
    let duration: TimeInterval
    let text: String

    var endTime: TimeInterval { startTime + duration }
}

struct StreamingTranscriptAccumulator: Equatable, Sendable {
    static let pauseResetThreshold: TimeInterval = 0.5

    private(set) var committedText = ""
    private(set) var activeText = ""
    private var activeStartTime: TimeInterval?
    private var activeEndTime: TimeInterval?
    private var lastMeaningfulUpdateAt: TimeInterval?

    var text: String {
        StreamingTranscriptReconciler.mergeCommitted(existing: committedText, incoming: activeText)
    }

    mutating func receivePartial(
        _ text: String,
        segments: [TimedTranscriptSegment] = [],
        receivedAt: TimeInterval = ProcessInfo.processInfo.systemUptime
    ) {
        let formattedText = StreamingTranscriptReconciler.clean(text)
        let segmentText = segments.map(\.text).joined(separator: " ")
        let incoming = formattedText.isEmpty ? StreamingTranscriptReconciler.clean(segmentText) : formattedText
        guard !incoming.isEmpty else { return }

        let incomingStart = segments.map(\.startTime).min()
        let incomingEnd = segments.map(\.endTime).max()

        guard !activeText.isEmpty else {
            activeText = StreamingTranscriptReconciler.uncommittedSuffix(
                committed: committedText,
                candidate: incoming
            ) ?? incoming
            updateActiveTimeline(start: incomingStart, end: incomingEnd)
            lastMeaningfulUpdateAt = receivedAt
            return
        }

        let relationship = StreamingTranscriptReconciler.relationship(existing: activeText, incoming: incoming)
        switch relationship {
        case .same, .shorterOrSubset:
            // Repeated/stale hypotheses neither erase text nor move the pause clock.
            return
        case .cumulativeExtension, .correction:
            activeText = incoming
        case .overlap:
            activeText = StreamingTranscriptReconciler.merge(existing: activeText, incoming: incoming)
        case .unrelated:
            let meaningfulGap = receivedAt - (lastMeaningfulUpdateAt ?? receivedAt)
            if timelinesOverlap(incomingStart: incomingStart, incomingEnd: incomingEnd),
               meaningfulGap < Self.pauseResetThreshold {
                // Immediate same-timeline root changes are recognizer corrections.
                activeText = incoming
                activeStartTime = incomingStart ?? activeStartTime
                activeEndTime = incomingEnd ?? activeEndTime
                lastMeaningfulUpdateAt = receivedAt
                return
            }

            // Apple can restart segment timestamps after a real pause. Gemini can
            // emit unrelated text-only deltas. Both are continuations, not deletion.
            committedText = StreamingTranscriptReconciler.mergeCommitted(existing: committedText, incoming: activeText)
            activeText = StreamingTranscriptReconciler.uncommittedSuffix(
                committed: committedText,
                candidate: incoming
            ) ?? incoming
            activeStartTime = incomingStart
            activeEndTime = incomingEnd
            lastMeaningfulUpdateAt = receivedAt
            return
        }

        updateActiveTimeline(start: incomingStart, end: incomingEnd)
        lastMeaningfulUpdateAt = receivedAt
    }

    mutating func receiveFinal(_ text: String) {
        let incoming = StreamingTranscriptReconciler.clean(text)
        guard !incoming.isEmpty else { return }

        let reconciliation = StreamingTranscriptReconciler.reconcileFinal(active: activeText, final: incoming)
        committedText = StreamingTranscriptReconciler.mergeCommitted(
            existing: committedText,
            incoming: reconciliation.committed
        )
        activeText = StreamingTranscriptReconciler.uncommittedSuffix(
            committed: committedText,
            candidate: reconciliation.pending
        ) ?? reconciliation.pending
        activeStartTime = nil
        activeEndTime = nil
        lastMeaningfulUpdateAt = nil
    }

    mutating func reset() {
        self = StreamingTranscriptAccumulator()
    }

    private mutating func updateActiveTimeline(start: TimeInterval?, end: TimeInterval?) {
        if let start {
            activeStartTime = min(activeStartTime ?? start, start)
        }
        if let end {
            activeEndTime = max(activeEndTime ?? end, end)
        }
    }

    private func timelinesOverlap(incomingStart: TimeInterval?, incomingEnd: TimeInterval?) -> Bool {
        guard let incomingStart,
              let incomingEnd,
              let activeStartTime,
              let activeEndTime else {
            return false
        }
        let tolerance = 0.15
        return incomingStart <= activeEndTime + tolerance && activeStartTime <= incomingEnd + tolerance
    }
}

enum StreamingTranscriptRelationship: Equatable {
    case same
    case shorterOrSubset
    case cumulativeExtension
    case correction
    case overlap
    case unrelated
}

enum StreamingTranscriptReconciler {
    struct FinalReconciliation: Equatable {
        let committed: String
        let pending: String
    }

    static func clean(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = trimmed.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]().,"))
        let noiseTags = ["blank_audio", "sessizlik", "ses yok", "boşluk", "gürültü", "music", "müzik"]
        return noiseTags.contains(lower) ? "" : trimmed
    }

    static func normalizedTokens(_ text: String) -> [String] {
        let lowercased = text.lowercased(with: Locale(identifier: "tr_TR"))
        var normalized = ""
        normalized.reserveCapacity(lowercased.count)
        for character in lowercased {
            normalized.append(character.isLetter || character.isNumber ? character : " ")
        }
        return normalized.split(separator: " ").map { String($0) }
    }

    static func relationship(existing: String, incoming: String) -> StreamingTranscriptRelationship {
        let current = normalizedTokens(clean(existing))
        let next = normalizedTokens(clean(incoming))
        guard !current.isEmpty, !next.isEmpty else { return .unrelated }
        if current == next { return .same }
        if contains(current, next) { return .shorterOrSubset }
        if next.starts(with: current) || contains(next, current) { return .cumulativeExtension }

        let prefix = commonPrefixCount(current, next)
        let suffix = commonSuffixCount(current, next)
        let shorterCount = min(current.count, next.count)
        let sharedTokenCount = Set(current).intersection(Set(next)).count
        let lexicalSimilarity = Double(sharedTokenCount) / Double(max(current.count, next.count))
        let comparableLength = abs(current.count - next.count) <= max(2, shorterCount / 2)
        let unstableEdgeCorrection = prefix > 0 && (prefix >= shorterCount - 2 || prefix * 2 >= shorterCount)
        let suffixCorrection = suffix > 0 && suffix * 2 >= shorterCount && comparableLength
        let lexicalCorrection = lexicalSimilarity >= 0.5 && comparableLength
        if (unstableEdgeCorrection && next.count >= current.count) || suffixCorrection || lexicalCorrection {
            return .correction
        }
        if suffixPrefixOverlap(current, next) > 0 { return .overlap }
        return .unrelated
    }

    static func merge(existing: String, incoming: String) -> String {
        let currentText = clean(existing)
        let incomingText = clean(incoming)
        if currentText.isEmpty { return incomingText }
        if incomingText.isEmpty { return currentText }

        let current = normalizedTokens(currentText)
        let next = normalizedTokens(incomingText)
        if current.isEmpty { return incomingText }
        if next.isEmpty { return currentText }

        switch relationship(existing: currentText, incoming: incomingText) {
        case .same:
            return currentText.count >= incomingText.count ? currentText : incomingText
        case .shorterOrSubset:
            return currentText
        case .cumulativeExtension, .correction:
            return incomingText
        case .overlap:
            let overlap = suffixPrefixOverlap(current, next)
            let words = words(incomingText)
            guard overlap < words.count else { return currentText }
            return join(currentText, words.dropFirst(overlap).joined(separator: " "))
        case .unrelated:
            return join(currentText, incomingText)
        }
    }

    static func mergeCommitted(existing: String, incoming: String) -> String {
        let currentText = clean(existing)
        let incomingText = clean(incoming)
        if currentText.isEmpty { return incomingText }
        if incomingText.isEmpty { return currentText }

        let current = normalizedTokens(currentText)
        let next = normalizedTokens(incomingText)
        if current == next || contains(current, next) { return currentText }
        if next.starts(with: current) || contains(next, current) { return incomingText }
        let overlap = suffixPrefixOverlap(current, next)
        if overlap > 0 {
            return join(currentText, words(incomingText).dropFirst(overlap).joined(separator: " "))
        }
        return join(currentText, incomingText)
    }

    static func reconcileFinal(active: String, final: String) -> FinalReconciliation {
        let activeText = clean(active)
        let finalText = clean(final)
        guard !activeText.isEmpty else { return FinalReconciliation(committed: finalText, pending: "") }
        guard !finalText.isEmpty else { return FinalReconciliation(committed: "", pending: activeText) }

        let activeTokens = normalizedTokens(activeText)
        let finalTokens = normalizedTokens(finalText)
        if let range = firstRange(of: finalTokens, in: activeTokens) {
            if range.lowerBound == 0 && range.upperBound < activeTokens.count {
                let activeWords = words(activeText)
                return FinalReconciliation(
                    committed: finalText,
                    pending: activeWords.dropFirst(range.upperBound).joined(separator: " ")
                )
            }
            // A provider delta that finalizes only the active tail must not drop
            // the richer active prefix observed before the pause.
            return FinalReconciliation(committed: activeText, pending: "")
        }

        switch relationship(existing: activeText, incoming: finalText) {
        case .same, .shorterOrSubset:
            return FinalReconciliation(committed: activeText, pending: "")
        case .cumulativeExtension, .correction:
            return FinalReconciliation(committed: finalText, pending: "")
        case .overlap, .unrelated:
            return FinalReconciliation(committed: merge(existing: activeText, incoming: finalText), pending: "")
        }
    }

    static func uncommittedSuffix(committed: String, candidate: String) -> String? {
        let committedTokens = normalizedTokens(clean(committed))
        let candidateText = clean(candidate)
        let candidateTokens = normalizedTokens(candidateText)
        guard !candidateTokens.isEmpty else { return "" }
        guard !committedTokens.isEmpty else { return candidateText }
        if contains(committedTokens, candidateTokens) { return "" }

        let overlap = suffixPrefixOverlap(committedTokens, candidateTokens)
        if overlap > 0 {
            return words(candidateText).dropFirst(overlap).joined(separator: " ")
        }
        if candidateTokens.starts(with: committedTokens) {
            return words(candidateText).dropFirst(committedTokens.count).joined(separator: " ")
        }
        return nil
    }

    private static func words(_ text: String) -> [String] {
        text.split(whereSeparator: { $0.isWhitespace }).map(String.init)
    }

    private static func contains(_ haystack: [String], _ needle: [String]) -> Bool {
        firstRange(of: needle, in: haystack) != nil
    }

    private static func firstRange(of needle: [String], in haystack: [String]) -> Range<Int>? {
        guard !needle.isEmpty, needle.count <= haystack.count else { return nil }
        for start in 0...(haystack.count - needle.count) {
            let end = start + needle.count
            if haystack[start..<end].elementsEqual(needle) { return start..<end }
        }
        return nil
    }

    private static func commonPrefixCount(_ left: [String], _ right: [String]) -> Int {
        var count = 0
        for index in 0..<min(left.count, right.count) {
            guard left[index] == right[index] else { break }
            count += 1
        }
        return count
    }

    private static func commonSuffixCount(_ left: [String], _ right: [String]) -> Int {
        var count = 0
        while count < min(left.count, right.count), left[left.count - 1 - count] == right[right.count - 1 - count] {
            count += 1
        }
        return count
    }

    private static func suffixPrefixOverlap(_ left: [String], _ right: [String]) -> Int {
        let maximum = min(left.count, right.count)
        guard maximum > 0 else { return 0 }
        for count in stride(from: maximum, through: 1, by: -1) {
            if left.suffix(count).elementsEqual(right.prefix(count)) { return count }
        }
        return 0
    }

    private static func join(_ first: String, _ second: String) -> String {
        if first.isEmpty { return second }
        if second.isEmpty { return first }
        return "\(first) \(second)"
    }
}

struct AppleSpeechTranscriptProcessor {
    static func apply(
        accumulator: inout StreamingTranscriptAccumulator,
        text: String,
        segments: [TimedTranscriptSegment],
        isFinal: Bool,
        receivedAt: TimeInterval
    ) -> String {
        accumulator.receivePartial(text, segments: segments, receivedAt: receivedAt)
        if isFinal {
            accumulator.receiveFinal(text)
        }
        return accumulator.text
    }
}

struct GeminiTranscriptProcessor {
    static func applyPartial(
        accumulator: inout StreamingTranscriptAccumulator,
        text: String,
        receivedAt: TimeInterval
    ) -> String {
        accumulator.receivePartial(text, receivedAt: receivedAt)
        return accumulator.text
    }

    static func applyFinal(accumulator: inout StreamingTranscriptAccumulator, text: String) -> String {
        accumulator.receiveFinal(text)
        return accumulator.text
    }
}
