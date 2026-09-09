import Foundation
import AVFoundation
import CoreAudio
import AppKit

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

    // MARK: - Donanım Dinleyicisi (Default Input Device & Sleep)

    private var defaultInputDevicePropertyAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultInputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    private var deviceListenerBlock: AudioObjectPropertyListenerBlock?

    override private init() {
        super.init()
        setupHardwareListeners()
    }

    deinit {
        removeHardwareListeners()
        cleanTeardown()
    }

    // MARK: - Donanım Değişimi & Uyku Dinleyicileri (Active Mic Recovery)

    private func setupHardwareListeners() {
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.handleDefaultDeviceChanged()
        }
        self.deviceListenerBlock = block

        let status = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &defaultInputDevicePropertyAddress,
            DispatchQueue.main,
            block
        )
        if status != noErr {
            print("[AudioRecorder] ⚠️ CoreAudio default input device dinleyicisi eklenemedi: \(status)")
        }

        // Sistem uykuya geçerken donanımı temizle
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            print("[AudioRecorder] 💤 Sistem uykuya geçiyor, ses motoru kapatılıyor.")
            self?.cleanTeardown()
        }
    }

    private func removeHardwareListeners() {
        if let block = deviceListenerBlock {
            AudioObjectRemovePropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject),
                &defaultInputDevicePropertyAddress,
                DispatchQueue.main,
                block
            )
            deviceListenerBlock = nil
        }
    }

    private func handleDefaultDeviceChanged() {
        print("[AudioRecorder] 🔄 Sistem varsayılan mikrofonu değişti (AirPods/Bluetooth/Dahili).")
        lock.lock()
        let recording = isRecording
        lock.unlock()

        if !recording {
            // Boşta veya ılık moddaysa motoru kapat, bir sonraki kayıtta yeni mikrofona anında bağlanacak
            cleanTeardown()
        } else {
            print("[AudioRecorder] ⚠️ Aktif kayıt esnasında mikrofon değişti, kayıt korunuyor.")
        }
    }

    // MARK: - Kayıt Başlatma & Sıfır Gecikmeli Uyanma (Instant Warm Start)

    public func start(onAudioChunk: ((Data) -> Void)? = nil) -> Bool {
        lock.lock()
        defer { lock.unlock() }

        if isRecording {
            return false
        }

        // 0. CLAMSHELL KONTROLÜ (MacBook Kapağı Kapalı mı?)
        if IOKitClamshellStateProvider.shared.isLidClosed() {
            print("[AudioRecorder] ⚠️ MacBook kapağı kapalı (Clamshell modu). Harici mikrofon yoksa Apple Silicon/T2 donanımı dahili mikrofonu susturmuş olabilir.")
        }

        // Ses motorunu sıfırdan temiz başlat
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
        MicrophoneBoostProcessor.shared.reset()

        inputNode.installTap(onBus: 0, bufferSize: 2048, format: hwFormat) { [weak self] buffer, time in
            guard let self = self, self.isRecording else { return }

            // Canlı güç seviyesini hesapla
            let calculatedPower = self.calculatePower(buffer: buffer)

            let outBuffer = AVAudioPCMBuffer(pcmFormat: self.targetFormat, frameCapacity: 4096)!
            var error: NSError?
            var haveData = true

            let inputBlock: AVAudioConverterInputBlock = { inNumPackets, outStatus in
                if haveData {
                    haveData = false
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
                let rawChunk = Data(bytes: channelData[0], count: byteCount)

                // Mikrofon Akıllı Kazanç ve Yumuşak Sınırlayıcı (AGC Boost Processor)
                let boostEnabled = ConfigManager.shared.config.enable_microphone_boost
                let chunk = boostEnabled ? MicrophoneBoostProcessor.shared.processPCM16Data(rawChunk, enabled: true) : rawChunk

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

    // MARK: - Kayıt Durdurma ve Donanımı Anında Serbest Bırakma

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

        // Mikrofonu ve ses motorunu hemen kapat (macOS turuncu gizlilik ikonu anında söner)
        self.audioEngine = nil
        self.audioConverter = nil
        lock.unlock()

        engine.stop()
        engine.inputNode.removeTap(onBus: 0)

        // Varsa kalan son PCM parçasını da callback'e ilet
        if let cb = remainingCallback, !remainingChunk.isEmpty {
            cb(remainingChunk)
        }

        let wavData = AudioRecorder.createWavData(pcmData: fullPCM, sampleRate: 16000, channels: 1, bitDepth: 16)

        // Akıllı sessizlik ve mikrofonsuzluk kontrolü (PCM 16-bit tepe genlik)
        if AudioRecorder.isAudioSilent(data: wavData) {
            return (nil, duration)
        }

        return (wavData, duration)
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
        self.audioEngine = nil
        self.audioConverter = nil
        lock.unlock()

        if let eng = engine {
            eng.stop()
            eng.inputNode.removeTap(onBus: 0)
        }
    }

    /// Ses motorunu tamamen kapatır, donanım tap'ini söker ve kaynakları serbest bırakır.
    public func cleanTeardown() {
        lock.lock()
        isRecording = false
        let engine = audioEngine
        audioEngine = nil
        audioConverter = nil
        chunkCallback = nil
        accumulatedPCM = Data()
        bufferedPCMData = Data()
        currentPower = -160.0
        lock.unlock()

        if let eng = engine {
            eng.stop()
            eng.inputNode.removeTap(onBus: 0)
            print("[AudioRecorder] 💤 Ses motoru ve donanım serbest bırakıldı.")
        }
    }

    private func calculatePower(buffer: AVAudioPCMBuffer) -> Float {
        guard let floatData = buffer.floatChannelData else { return -160.0 }
        let frameCount = Int(buffer.frameLength)
        guard frameCount > 0 else { return -160.0 }

        var sum: Float = 0.0
        let channel = floatData[0]
        for i in 0..<frameCount {
            let sample = channel[i]
            sum += sample * sample
        }
        let rms = sqrt(sum / Float(frameCount))
        let db = 20.0 * log10(max(rms, 0.00001))
        return max(-160.0, min(0.0, db))
    }

    // MARK: - WAV ve Ses Yardımcıları

    /// 16kHz 16-bit PCM WAV verisindeki örneklerin tepe genliğini kontrol eder.
    /// Tüm ses boyunca en yüksek genlik minAmplitude'tan düşükse dijital sessizliktir.
    public static func isAudioSilent(data: Data, minAmplitude: Int16 = 35) -> Bool {
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
}
