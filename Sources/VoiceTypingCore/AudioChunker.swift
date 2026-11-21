import Foundation

/// Uzun WAV kayıtlarını sessizlik / nefes duraklamalarından bölen ve dinamik
/// zaman aşımı hesaplayan yardımcı katman.
enum AudioChunker {
    static let standardSampleRate: Double = 16_000.0
    static let standardBytesPerSample = 2
    static let standardBytesPerSecond = Int(standardSampleRate) * standardBytesPerSample
    static let wavHeaderSize = 44

    /// 16 kHz mono 16-bit PCM WAV kaydının süresini saniye cinsinden döner.
    static func pcmDurationSeconds(wavData: Data) -> Double {
        guard wavData.count > wavHeaderSize else { return 0.0 }
        return Double(wavData.count - wavHeaderSize) / Double(standardBytesPerSecond)
    }

    /// Dinamik HTTP/deşifre zaman aşımı: uzun kayıtların yükleme ve model işleme
    /// süresine yetecek şekilde ölçeklenir.
    static func dynamicRequestTimeout(
        audioSeconds: Double,
        minSeconds: Double = 30.0,
        maxSeconds: Double = 180.0
    ) -> TimeInterval {
        let clampedAudio = audioSeconds.isFinite ? max(0.0, audioSeconds) : 0.0
        return min(maxSeconds, max(minSeconds, 20.0 + clampedAudio * 0.85))
    }

    /// Uzun 16 kHz mono PCM16 WAV kayıtlarını `maxChunkSeconds` sınırını aşmayacak
    /// biçimde en sessiz duraklama anlarından böler; sınır kelimelerinin kaybolmaması
    /// için `overlapSeconds` kadar örtüşme bırakır.
    static func splitWAV(
        _ wavData: Data,
        maxChunkSeconds: Double,
        overlapSeconds: Double = 0.5
    ) -> [Data] {
        guard maxChunkSeconds > 2.0,
              wavData.count > wavHeaderSize,
              String(data: wavData.prefix(4), encoding: .ascii) == "RIFF",
              isStandardMono16kWAV(wavData) else {
            return [wavData]
        }

        let pcm = wavData.subdata(in: wavHeaderSize..<wavData.count)
        let alignedTotalBytes = (pcm.count / standardBytesPerSample) * standardBytesPerSample
        let maxChunkBytes = alignBytes(Int(maxChunkSeconds * Double(standardBytesPerSecond)))
        guard alignedTotalBytes > maxChunkBytes, maxChunkBytes > standardBytesPerSecond else {
            return [wavData]
        }

        let overlapBytes = min(
            maxChunkBytes / 4,
            max(0, alignBytes(Int(overlapSeconds * Double(standardBytesPerSecond))))
        )
        let searchWindowSeconds = min(6.0, maxChunkSeconds * 0.2)
        let searchWindowBytes = alignBytes(Int(searchWindowSeconds * Double(standardBytesPerSecond)))
        let frameBytes = alignBytes(Int(0.04 * Double(standardBytesPerSecond))) // 40ms

        var chunks: [Data] = []
        var startByte = 0

        while startByte < alignedTotalBytes {
            let remaining = alignedTotalBytes - startByte
            if remaining <= maxChunkBytes {
                let slice = pcm.subdata(in: startByte..<alignedTotalBytes)
                chunks.append(AudioRecorder.createWavData(pcmData: slice))
                break
            }

            let targetEnd = startByte + maxChunkBytes
            let windowStart = max(startByte + maxChunkBytes / 2, targetEnd - searchWindowBytes)
            let splitByte = quietestSplitByte(
                in: pcm,
                windowStart: windowStart,
                windowEnd: targetEnd,
                frameBytes: frameBytes
            )

            let safeEnd = max(startByte + standardBytesPerSecond, min(alignedTotalBytes, splitByte))
            let slice = pcm.subdata(in: startByte..<safeEnd)
            chunks.append(AudioRecorder.createWavData(pcmData: slice))

            if safeEnd >= alignedTotalBytes {
                break
            }

            let nextStart = alignBytes(max(startByte + standardBytesPerSecond, safeEnd - overlapBytes))
            if nextStart <= startByte {
                startByte = safeEnd
            } else {
                startByte = nextStart
            }
        }

        return chunks.isEmpty ? [wavData] : chunks
    }

    private static func isStandardMono16kWAV(_ data: Data) -> Bool {
        guard data.count >= wavHeaderSize else { return false }
        let channels = readUInt16LE(data, at: 22)
        let sampleRate = readUInt32LE(data, at: 24)
        let bitsPerSample = readUInt16LE(data, at: 34)
        return channels == 1 && sampleRate == 16_000 && bitsPerSample == 16
    }

    private static func readUInt16LE(_ data: Data, at offset: Int) -> UInt16 {
        UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
    }

    private static func readUInt32LE(_ data: Data, at offset: Int) -> UInt32 {
        UInt32(data[offset])
            | (UInt32(data[offset + 1]) << 8)
            | (UInt32(data[offset + 2]) << 16)
            | (UInt32(data[offset + 3]) << 24)
    }

    private static func alignBytes(_ value: Int) -> Int {
        value - (value % standardBytesPerSample)
    }

    private static func quietestSplitByte(
        in pcm: Data,
        windowStart: Int,
        windowEnd: Int,
        frameBytes: Int
    ) -> Int {
        let start = alignBytes(max(0, windowStart))
        let end = alignBytes(min(pcm.count, windowEnd))
        guard end - start >= frameBytes else { return end }

        var bestOffset = end
        var lowestMeanSquare = Double.greatestFiniteMagnitude

        pcm.withUnsafeBytes { raw in
            var cursor = start
            while cursor + frameBytes <= end {
                var sumSquares = 0.0
                let sampleCount = frameBytes / standardBytesPerSample
                for i in 0..<sampleCount {
                    let rawSample = raw.loadUnaligned(
                        fromByteOffset: cursor + i * standardBytesPerSample,
                        as: Int16.self
                    )
                    let sample = Double(Int16(littleEndian: rawSample))
                    sumSquares += sample * sample
                }
                let meanSquare = sumSquares / Double(max(1, sampleCount))
                if meanSquare < lowestMeanSquare {
                    lowestMeanSquare = meanSquare
                    bestOffset = cursor + frameBytes / 2
                }
                cursor += frameBytes
            }
        }

        return alignBytes(bestOffset)
    }

    /// Örtüşmeli parça deşifrelerini birleştirirken sınırda tekrarlanan kelimeleri temizler.
    static func mergeChunkTranscripts(_ chunks: [String]) -> String {
        let nonEmpty = chunks
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !nonEmpty.isEmpty else { return "" }

        let trimSet = CharacterSet.punctuationCharacters.union(.symbols)
        func normalize(_ token: Substring) -> String {
            token.trimmingCharacters(in: trimSet).lowercased()
        }

        var mergedWords = nonEmpty[0].split(whereSeparator: \.isWhitespace)
        for next in nonEmpty.dropFirst() {
            let nextWords = next.split(whereSeparator: \.isWhitespace)
            guard !nextWords.isEmpty else { continue }
            guard !mergedWords.isEmpty else {
                mergedWords = nextWords
                continue
            }

            let prevNorm = mergedWords.map(normalize)
            let nextNorm = nextWords.map(normalize)
            let maxOverlap = min(8, prevNorm.count, nextNorm.count)
            var matchedOverlap = 0
            if maxOverlap >= 1 {
                for overlap in stride(from: maxOverlap, through: 1, by: -1) {
                    let tail = prevNorm.suffix(overlap)
                    let head = nextNorm.prefix(overlap)
                    if !tail.contains(where: \.isEmpty), Array(tail) == Array(head) {
                        matchedOverlap = overlap
                        break
                    }
                }
            }
            mergedWords.append(contentsOf: nextWords.dropFirst(matchedOverlap))
        }
        return mergedWords.joined(separator: " ")
    }
}
