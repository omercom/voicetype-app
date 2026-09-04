import Foundation
import AVFoundation

public class AudioRecorder: NSObject {
    public static let shared = AudioRecorder()

    private var audioEngine: AVAudioEngine?
    private var audioConverter: AVAudioConverter?
    private let targetFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: true)!

    private var startTime: CFAbsoluteTime = 0
    private let lock = NSLock()

    private var chunkCallback: ((Data) -> Void)?
    private var accumulatedPCM: Data = Data()
    private var bufferedPCMData: Data = Data()
    private var currentPower: Float = -160.0

    public private(set) var isRecording: Bool = false

    override private init() {
        super.init()
    }

    public func start(onAudioChunk: ((Data) -> Void)? = nil) -> Bool {
        lock.lock()
        defer { lock.unlock() }

        if isRecording {
            return false
        }

        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        let hwFormat = inputNode.outputFormat(forBus: 0)

        guard hwFormat.sampleRate > 0 && hwFormat.channelCount > 0 else {
            print("[Hata] Geçersiz mikrofon ses formatı: \(hwFormat)")
            return false
        }

        guard let converter = AVAudioConverter(from: hwFormat, to: targetFormat) else {
            print("[Hata] Ses dönüştürücü oluşturulamadı: \(hwFormat) -> \(targetFormat)")
            return false
        }

        self.audioEngine = engine
        self.audioConverter = converter
        self.chunkCallback = onAudioChunk
        self.accumulatedPCM = Data()
        self.bufferedPCMData = Data()
        self.currentPower = -160.0
        self.startTime = CFAbsoluteTimeGetCurrent()

        let dstFmt = self.targetFormat

        inputNode.installTap(onBus: 0, bufferSize: 2048, format: hwFormat) { [weak self] buffer, time in
            guard let self = self else { return }

            // 1. Ses seviyesi (metering) hesabı (dB)
            var calculatedPower: Float = -160.0
            if let floatData = buffer.floatChannelData {
                let frameCount = Int(buffer.frameLength)
                if frameCount > 0 {
                    var sum: Float = 0.0
                    let channel = floatData[0]
                    for i in 0..<frameCount {
                        let sample = channel[i]
                        sum += sample * sample
                    }
                    let rms = sqrt(sum / Float(frameCount))
                    let db = 20.0 * log10(max(rms, 0.00001))
                    calculatedPower = max(-160.0, min(0.0, db))
                }
            }

            // 2. 16kHz 16-bit PCM dönüşümü
            let ratio = dstFmt.sampleRate / buffer.format.sampleRate
            let targetCapacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio + 512)
            guard let outBuffer = AVAudioPCMBuffer(pcmFormat: dstFmt, frameCapacity: targetCapacity) else { return }

            var error: NSError? = nil
            var hasSupplied = false
            let inputBlock: AVAudioConverterInputBlock = { inNumPackets, outStatus in
                if !hasSupplied {
                    hasSupplied = true
                    outStatus.pointee = .haveData
                    return buffer
                } else {
                    outStatus.pointee = .noDataNow
                    return nil
                }
            }

            let status = converter.convert(to: outBuffer, error: &error, withInputFrom: inputBlock)
            if (status == .haveData || status == .inputRanDry) && outBuffer.frameLength > 0,
               let channelData = outBuffer.int16ChannelData {
                let byteCount = Int(outBuffer.frameLength) * MemoryLayout<Int16>.size
                let chunk = Data(bytes: channelData[0], count: byteCount)

                var readyChunks: [Data] = []
                var localCallback: ((Data) -> Void)? = nil

                self.lock.lock()
                self.currentPower = calculatedPower
                self.bufferedPCMData.append(chunk)
                if self.chunkCallback != nil {
                    self.accumulatedPCM.append(chunk)
                    // ~100ms bloklar (1600 örnek = 3200 bayt)
                    while self.accumulatedPCM.count >= 3200 {
                        let block = self.accumulatedPCM.prefix(3200)
                        readyChunks.append(Data(block))
                        self.accumulatedPCM.removeFirst(3200)
                    }
                    localCallback = self.chunkCallback
                }
                self.lock.unlock()

                if let cb = localCallback {
                    for readyChunk in readyChunks {
                        cb(readyChunk)
                    }
                }
            }
        }

        do {
            try engine.start()
            isRecording = true
            print("[AudioRecorder] ✅ Mikrofon başarıyla aktif edildi (Örnekleme: \(hwFormat.sampleRate)Hz, Kanal: \(hwFormat.channelCount)).")
            return true
        } catch {
            print("[AudioRecorder] ❌ Mikrofon motoru başlatılamadı: \(error.localizedDescription)")
            inputNode.removeTap(onBus: 0)
            self.audioEngine = nil
            self.audioConverter = nil
            isRecording = false
            return false
        }
    }

    /// Anlık mikrofon ses seviyesini (dB cinsinden) döner.
    public func averagePower() -> Float {
        lock.lock()
        defer { lock.unlock() }
        guard isRecording else { return -160.0 }
        return currentPower
    }

    public func stop() -> (data: Data?, duration: Double) {
        lock.lock()
        guard isRecording, let engine = audioEngine else {
            lock.unlock()
            return (nil, 0.0)
        }

        let duration = CFAbsoluteTimeGetCurrent() - startTime
        isRecording = false
        let remainingCallback = chunkCallback
        let remainingChunk = accumulatedPCM
        let fullPCM = bufferedPCMData

        chunkCallback = nil
        accumulatedPCM = Data()
        bufferedPCMData = Data()
        currentPower = -160.0
        lock.unlock()

        // Varsa kalan son PCM parçasını da callback'e ilet
        if let cb = remainingCallback, !remainingChunk.isEmpty {
            cb(remainingChunk)
        }

        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        self.audioEngine = nil
        self.audioConverter = nil

        let wavData = AudioRecorder.createWavData(pcmData: fullPCM, sampleRate: 16000, channels: 1, bitDepth: 16)

        // Akıllı sessizlik ve mikrofonsuzluk kontrolü (PCM 16-bit tepe genlik)
        if AudioRecorder.isAudioSilent(data: wavData) {
            return (nil, duration)
        }

        return (wavData, duration)
    }

    /// 16kHz 16-bit PCM WAV verisindeki örneklerin tepe genliğini kontrol eder.
    /// Tüm ses boyunca en yüksek genlik minAmplitude'tan düşükse dijital sessizliktir.
    public static func isAudioSilent(data: Data, minAmplitude: Int16 = 35) -> Bool {
        // En az WAV başlığı (44 bayt) ve birkaç örnek içermelidir
        guard data.count > 44 else { return true }
        return data.withUnsafeBytes { rawBuffer -> Bool in
            guard let base = rawBuffer.baseAddress else { return true }
            let pcmOffset = 44
            guard data.count > pcmOffset else { return true }
            let samplesPtr = base.advanced(by: pcmOffset).assumingMemoryBound(to: Int16.self)
            let sampleCount = (data.count - pcmOffset) / MemoryLayout<Int16>.size
            var maxAmp: Int16 = 0

            for i in 0..<sampleCount {
                let amp = abs(samplesPtr[i])
                if amp > maxAmp {
                    maxAmp = amp
                    if maxAmp >= minAmplitude {
                        return false // Konuşma veya ses bulundu!
                    }
                }
            }
            return true // Saf dijital sessizlik
        }
    }

    /// Ham PCM verisini standart 44 baytlık RIFF/WAVE kapsayıcısına sarar.
    public static func createWavData(pcmData: Data, sampleRate: Int = 16000, channels: Int = 1, bitDepth: Int = 16) -> Data {
        var data = Data()
        let totalDataLen = Int32(pcmData.count)
        let totalAudioLen = totalDataLen + 36
        let byteRate = Int32(sampleRate * channels * (bitDepth / 8))
        let blockAlign = Int16(channels * (bitDepth / 8))

        data.append("RIFF".data(using: .ascii)!)
        var totalAudioLenLE = totalAudioLen.littleEndian
        data.append(Data(bytes: &totalAudioLenLE, count: 4))
        data.append("WAVE".data(using: .ascii)!)
        data.append("fmt ".data(using: .ascii)!)
        var subchunk1Size = Int32(16).littleEndian
        data.append(Data(bytes: &subchunk1Size, count: 4))
        var audioFormat = Int16(1).littleEndian
        data.append(Data(bytes: &audioFormat, count: 2))
        var numChannels = Int16(channels).littleEndian
        data.append(Data(bytes: &numChannels, count: 2))
        var sampleRateLE = Int32(sampleRate).littleEndian
        data.append(Data(bytes: &sampleRateLE, count: 4))
        var byteRateLE = byteRate.littleEndian
        data.append(Data(bytes: &byteRateLE, count: 4))
        var blockAlignLE = blockAlign.littleEndian
        data.append(Data(bytes: &blockAlignLE, count: 2))
        var bitsPerSample = Int16(bitDepth).littleEndian
        data.append(Data(bytes: &bitsPerSample, count: 2))
        data.append("data".data(using: .ascii)!)
        var totalDataLenLE = totalDataLen.littleEndian
        data.append(Data(bytes: &totalDataLenLE, count: 4))
        data.append(pcmData)
        return data
    }

    public func cancel() {
        lock.lock()
        guard isRecording else {
            lock.unlock()
            return
        }

        isRecording = false
        chunkCallback = nil
        accumulatedPCM = Data()
        bufferedPCMData = Data()
        currentPower = -160.0
        let engine = audioEngine
        lock.unlock()

        engine?.stop()
        engine?.inputNode.removeTap(onBus: 0)
        self.audioEngine = nil
        self.audioConverter = nil
    }
}
