import Foundation
import AVFoundation
import CoreAudio
import AppKit
import Accelerate

public class AudioRecorder: NSObject {
    public static let shared = AudioRecorder()

    private var audioEngine: AVAudioEngine?
    private var audioConverter: AVAudioConverter?
    private var conversionBuffer: AVAudioPCMBuffer?
    private var preparedHardwareFormat: AVAudioFormat?
    private let targetFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: true)!

    private var startTime: CFAbsoluteTime = 0
    private let lock = NSLock()
    private let converterLock = NSLock()
    private let chunkDeliveryQueue = DispatchQueue(
        label: "com.voicetyping.audio-recorder.chunks",
        qos: .userInteractive
    )
    private let chunkDeliveryQueueKey = DispatchSpecificKey<Void>()
    private let warmupQueue = DispatchQueue(
        label: "com.voicetyping.audio-recorder.warmup",
        qos: .userInitiated
    )

    private var recordingState = false
    private var isStopping = false
    private var inputTapInstalled = false
    private var activeTapCallbacks = DispatchGroup()
    private var deliveryGeneration: UInt64 = 0
    private var cancelledDeliveryGeneration: UInt64?

    private var chunkCallback: ((Data) -> Void)?
    private var firstAudioBufferCallback: (() -> Void)?
    private var accumulatedPCM: Data = Data()
    private var accumulatedPCMOffset = 0
    private var bufferedPCMData: Data = Data()
    private var currentPower: Float = -160.0
    private var processingModeForRecording: RecordingAudioProcessingMode = .none
    private var hasDeliveredInitialStreamingChunk = false
    private var warmupGeneration: UInt64 = 0

    /// Çift eşikli konuşma kapısı. `currentPower` zaten her tamponda
    /// hesaplandığı için kapıyı beslemek ek analiz maliyeti getirmez.
    private var speechGate = SpeechGate()

    // İlk 40 ms'yi hemen sağlayıcıya gönder; devamında 100 ms paketler ağ ve
    // allocation maliyetini düşük tutar. Böylece sürekli paket sayısını artırmadan
    // ilk tanıma için yaklaşık 60-100 ms kazanılır.
    static let initialStreamingChunkByteCount = 1280 // 40ms @ 16kHz, mono, Int16
    static let streamingChunkByteCount = 3200 // 100ms @ 16kHz, mono, Int16

    /// Bu özellik eski public API ile aynı okunabilir yüzeyi korur; değeri
    /// lock üzerinden okunduğu için AVAudioEngine callback'i ile stop yarışmaz.
    public var isRecording: Bool {
        lock.lock()
        defer { lock.unlock() }
        return recordingState
    }

    /// Menüden başlatılan kayıtlarda da minimum süre kontrolünün klavye
    /// tetikleyicisiyle aynı çalışması için anlık kayıt süresini döner.
    public func currentRecordingDuration() -> Double {
        lock.lock()
        defer { lock.unlock() }
        guard recordingState else { return 0.0 }
        return max(0.0, CFAbsoluteTimeGetCurrent() - startTime)
    }

    // MARK: - Donanım Dinleyicisi (Default Input Device & Sleep)

    private var defaultInputDevicePropertyAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultInputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    private var deviceListenerBlock: AudioObjectPropertyListenerBlock?

    override private init() {
        super.init()
        chunkDeliveryQueue.setSpecific(key: chunkDeliveryQueueKey, value: ())
        setupHardwareListeners()
    }

    private func unconsumedAccumulatedPCM() -> Data {
        guard accumulatedPCMOffset < accumulatedPCM.count else { return Data() }
        return accumulatedPCM.subdata(in: accumulatedPCMOffset..<accumulatedPCM.count)
    }

    /// Tüketilmiş streaming verisini yalnızca seyrek aralıklarla öne alır.
    /// Böylece her 100ms blokta O(n) removeFirst maliyeti oluşmaz.
    private func compactAccumulatedPCMIfNeeded() {
        guard accumulatedPCMOffset > 0 else { return }

        if accumulatedPCMOffset == accumulatedPCM.count {
            accumulatedPCM.removeAll(keepingCapacity: true)
            accumulatedPCMOffset = 0
        } else if accumulatedPCMOffset >= 64 * 1024 && accumulatedPCMOffset * 2 >= accumulatedPCM.count {
            accumulatedPCM.removeSubrange(0..<accumulatedPCMOffset)
            accumulatedPCMOffset = 0
        }
    }

    private func enqueueReadyChunks(
        _ chunks: [Data],
        callback: @escaping (Data) -> Void,
        generation: UInt64
    ) {
        for chunk in chunks {
            chunkDeliveryQueue.async { [weak self] in
                guard let self = self else { return }
                self.lock.lock()
                let shouldDeliver = self.deliveryGeneration == generation &&
                    self.cancelledDeliveryGeneration != generation
                self.lock.unlock()

                if shouldDeliver {
                    callback(chunk)
                }
            }
        }
    }

    private func flushChunkDeliveryQueue() {
        // Bir chunk callback'i içinden stop/cancel çağrılırsa aynı seri kuyruğa
        // sync yapmak deadlock yaratır. Bu durumda mevcut callback tamamlandıktan
        // sonra kuyruğun doğal FIFO sırası devam eder.
        guard DispatchQueue.getSpecific(key: chunkDeliveryQueueKey) == nil else { return }
        chunkDeliveryQueue.sync {}
    }

    private func deliverRemainingChunk(
        _ chunk: Data,
        callback: @escaping (Data) -> Void,
        generation: UInt64
    ) {
        guard !chunk.isEmpty else { return }

        let delivery = { [weak self] in
            guard let self = self else { return }
            self.lock.lock()
            let shouldDeliver = self.deliveryGeneration == generation &&
                self.cancelledDeliveryGeneration != generation
            self.lock.unlock()

            if shouldDeliver {
                callback(chunk)
            }
        }

        if DispatchQueue.getSpecific(key: chunkDeliveryQueueKey) != nil {
            // stop() bir callback içinden çağrıldıysa mevcut callback'in önüne
            // geçmemesi için kalan parçayı kuyruğun sonuna bırak.
            chunkDeliveryQueue.async(execute: delivery)
        } else {
            chunkDeliveryQueue.sync(execute: delivery)
        }
    }

    private func stopEngine(_ engine: AVAudioEngine?, removeTap: Bool) {
        guard let engine = engine else { return }
        if removeTap {
            // Önce tap'i kaldırmak, stop ile aynı anda yeni callback başlamasını
            // engeller; aktif callback'ler ayrıca DispatchGroup ile beklenir.
            engine.inputNode.removeTap(onBus: 0)
        }
        engine.stop()
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
        let recording = recordingState
        lock.unlock()

        if !recording {
            // Boşta veya ılık moddaysa motoru kapat, bir sonraki kayıtta yeni mikrofona anında bağlanacak
            cleanTeardown()
        } else {
            print("[AudioRecorder] ⚠️ Aktif kayıt esnasında mikrofon değişti, kayıt korunuyor.")
        }
    }

    // MARK: - Kayıt Başlatma & Sıfır Gecikmeli Uyanma (Instant Warm Start)

    /// CoreAudio graph'ını mikrofonu çalıştırmadan hazırlar. `engine.start()`
    /// çağrılmadığı için boşta mikrofon kullanılmaz; yalnız allocation, format,
    /// converter ve tap kurulumu kayıt hot path'inden çıkarılır.
    public func warm() {
        lock.lock()
        let generation = warmupGeneration
        lock.unlock()

        warmupQueue.async { [weak self] in
            guard let self else { return }
            self.lock.lock()
            guard self.warmupGeneration == generation,
                  !self.recordingState,
                  !self.isStopping else {
                self.lock.unlock()
                return
            }
            _ = self.preparePipelineLocked()
            self.lock.unlock()
        }
    }

    public var isWarm: Bool {
        lock.lock()
        defer { lock.unlock() }
        return audioEngine != nil && audioConverter != nil && conversionBuffer != nil && inputTapInstalled
    }

    private func formatsMatch(_ lhs: AVAudioFormat, _ rhs: AVAudioFormat) -> Bool {
        lhs.sampleRate == rhs.sampleRate &&
        lhs.channelCount == rhs.channelCount &&
        lhs.commonFormat == rhs.commonFormat &&
        lhs.isInterleaved == rhs.isInterleaved
    }

    /// Çağıran `lock` sahibi olmalıdır.
    private func preparePipelineLocked() -> Bool {
        if let engine = audioEngine,
           let preparedFormat = preparedHardwareFormat,
           audioConverter != nil,
           conversionBuffer != nil,
           inputTapInstalled {
            let currentFormat = engine.inputNode.outputFormat(forBus: 0)
            if currentFormat.sampleRate > 0,
               currentFormat.channelCount > 0,
               formatsMatch(currentFormat, preparedFormat) {
                engine.prepare()
                return true
            }
        }

        if inputTapInstalled, let oldEngine = audioEngine {
            oldEngine.inputNode.removeTap(onBus: 0)
        }
        audioEngine?.stop()
        inputTapInstalled = false
        audioEngine = nil
        audioConverter = nil
        conversionBuffer = nil
        preparedHardwareFormat = nil

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

        let outputFrameCapacity = AVAudioFrameCount(
            max(4096, Int(ceil(2048.0 * targetFormat.sampleRate / hwFormat.sampleRate)) + 512)
        )
        guard let outputBuffer = AVAudioPCMBuffer(
            pcmFormat: targetFormat,
            frameCapacity: outputFrameCapacity
        ) else {
            print("[Hata] Ses dönüşüm tamponu oluşturulamadı.")
            return false
        }

        audioEngine = engine
        audioConverter = converter
        conversionBuffer = outputBuffer
        preparedHardwareFormat = hwFormat

        inputNode.installTap(onBus: 0, bufferSize: 2048, format: hwFormat) { [weak self] buffer, _ in
            self?.processInputBuffer(buffer)
        }
        inputTapInstalled = true
        engine.prepare()
        return true
    }

    private func processInputBuffer(_ buffer: AVAudioPCMBuffer) {
        // Stop ile callback'in başlangıcı arasında yarış olursa yalnız callback'e
        // girmiş oturum DispatchGroup'a katılır; warm graph boşta veriyi işlemez.
        lock.lock()
        guard recordingState else {
            lock.unlock()
            return
        }
        let generation = deliveryGeneration
        let callbackGroup = activeTapCallbacks
        let boostEnabled = processingModeForRecording == .realtimeBoost
        let firstAudioCallback = firstAudioBufferCallback
        firstAudioBufferCallback = nil
        callbackGroup.enter()
        lock.unlock()
        firstAudioCallback?()
        defer { callbackGroup.leave() }

        // Converter ve yeniden kullanılan buffer tek sahipli kalır. Provider
        // callback'leri bu kritik bölümün dışında ayrı seri kuyruğa teslim edilir.
        converterLock.lock()
        guard let converter = audioConverter, let outputBuffer = conversionBuffer else {
            converterLock.unlock()
            return
        }

        let calculatedPower = calculatePower(buffer: buffer)
        outputBuffer.frameLength = 0
        var error: NSError?
        var haveData = true
        let inputBlock: AVAudioConverterInputBlock = { _, outStatus in
            if haveData {
                haveData = false
                outStatus.pointee = .haveData
                return buffer
            }
            outStatus.pointee = .noDataNow
            return nil
        }

        let status = converter.convert(to: outputBuffer, error: &error, withInputFrom: inputBlock)
        let frameLength = outputBuffer.frameLength
        let rawChunk: Data?
        if (status == .haveData || status == .inputRanDry),
           frameLength > 0,
           let channelData = outputBuffer.int16ChannelData {
            rawChunk = Data(
                bytes: channelData[0],
                count: Int(frameLength) * MemoryLayout<Int16>.size
            )
        } else {
            rawChunk = nil
        }

        var readyChunks: [Data]? = nil
        var localCallback: ((Data) -> Void)? = nil
        if let rawChunk {
            let chunk = boostEnabled
                ? MicrophoneBoostProcessor.shared.processPCM16Data(rawChunk, enabled: true)
                : rawChunk

            lock.lock()
            let cancelled = cancelledDeliveryGeneration == generation
            if !cancelled {
                currentPower = calculatedPower
                // Kapıyı aynı güç değeriyle besle: ek analiz yok, tek kaynak.
                speechGate.update(
                    powerDB: calculatedPower,
                    now: ProcessInfo.processInfo.systemUptime,
                    isRecording: recordingState
                )
                bufferedPCMData.append(chunk)
                if let callback = chunkCallback {
                    accumulatedPCM.append(chunk)
                    while true {
                        let requiredBytes = hasDeliveredInitialStreamingChunk
                            ? Self.streamingChunkByteCount
                            : Self.initialStreamingChunkByteCount
                        guard accumulatedPCM.count - accumulatedPCMOffset >= requiredBytes else { break }
                        let start = accumulatedPCMOffset
                        let end = start + requiredBytes
                        if readyChunks == nil { readyChunks = [] }
                        readyChunks?.append(accumulatedPCM.subdata(in: start..<end))
                        accumulatedPCMOffset = end
                        hasDeliveredInitialStreamingChunk = true
                    }
                    compactAccumulatedPCMIfNeeded()
                    localCallback = callback
                }
            }
            lock.unlock()
        }
        converterLock.unlock()

        if let callback = localCallback, let readyChunks, !readyChunks.isEmpty {
            enqueueReadyChunks(readyChunks, callback: callback, generation: generation)
        }
    }

    public func start(
        onAudioChunk: ((Data) -> Void)? = nil,
        onFirstAudioBuffer: (() -> Void)? = nil,
        processingMode: RecordingAudioProcessingMode? = nil
    ) -> Bool {
        lock.lock()
        defer { lock.unlock() }

        guard !recordingState, !isStopping else { return false }
        let reusedWarmPipeline = audioEngine != nil && inputTapInstalled
        guard preparePipelineLocked(),
              let engine = audioEngine,
              let hwFormat = preparedHardwareFormat else {
            return false
        }

        // İşleme planı kayıt başına snapshot alınır; realtime callback içinde
        // ConfigManager veya dosya/ayar erişimi yapılmaz. Batch ve canlı yollar
        // birbirini dışlar, böylece aynı PCM iki kez AGC'den geçmez.
        if let processingMode {
            processingModeForRecording = processingMode
        } else if onAudioChunk != nil {
            // Callback'li kullanım canlı akış sözleşmesidir; çağıran config'te
            // batch sağlayıcı seçili olsa bile final WAV ile stream aynı işlenmiş
            // PCM'i görmelidir.
            processingModeForRecording = ConfigManager.shared.config.enable_microphone_boost
                ? .realtimeBoost
                : .none
        } else {
            processingModeForRecording = RecordingAudioProcessingMode.resolve(
                config: ConfigManager.shared.config
            )
        }
        chunkCallback = onAudioChunk
        firstAudioBufferCallback = onFirstAudioBuffer
        accumulatedPCM = Data()
        accumulatedPCM.reserveCapacity(64 * 1024)
        accumulatedPCMOffset = 0
        bufferedPCMData = Data()
        bufferedPCMData.reserveCapacity(320 * 1024)
        currentPower = -160.0
        hasDeliveredInitialStreamingChunk = false
        startTime = CFAbsoluteTimeGetCurrent()
        activeTapCallbacks = DispatchGroup()
        deliveryGeneration &+= 1
        cancelledDeliveryGeneration = nil
        MicrophoneBoostProcessor.shared.reset()

        converterLock.lock()
        audioConverter?.reset()
        converterLock.unlock()

        // İlk donanım callback'i engine.start() dönmeden gelebilir. Durumu önce
        // etkinleştirip lock'u start boyunca tuttuğumuzda callback doğru oturuma
        // bağlanır ve dönüşten hemen sonra ilerler; ilk tampon boşa atılmaz.
        recordingState = true
        do {
            try engine.start()
            let mode = reusedWarmPipeline ? "warm" : "cold"
            print("[AudioRecorder] ✅ Mikrofon başarıyla aktif edildi [\(mode)] (Örnekleme: \(hwFormat.sampleRate)Hz, Kanal: \(hwFormat.channelCount)).")
            return true
        } catch {
            recordingState = false
            chunkCallback = nil
            firstAudioBufferCallback = nil
            accumulatedPCM = Data()
            accumulatedPCMOffset = 0
            bufferedPCMData = Data()
            currentPower = -160.0
            processingModeForRecording = .none
            print("[AudioRecorder] ❌ Mikrofon motoru başlatılamadı: \(error.localizedDescription)")
            return false
        }
    }

    /// Anlık mikrofon ses seviyesini (dB cinsinden) döner.
    public func averagePower() -> Float {
        lock.lock()
        defer { lock.unlock() }
        guard recordingState else { return -160.0 }
        return currentPower
    }

    /// Çift eşikli konuşma kapısının anlık durumu.
    ///
    /// HUD'nin "Henüz ses algılanmadı" / "Dinliyor" ayrımı buradan beslenir;
    /// tek bir dB eşiği yerine gerçek konuşma segmenti durumu kullanılır.
    public func speechGateState() -> SpeechGateState {
        lock.lock()
        defer { lock.unlock() }
        guard recordingState else { return .silent }
        return speechGate.state
    }

    /// Adaptif gürültü tabanı (dBFS). Ayarlar ekranında tanılama için.
    public func noiseFloorDB() -> Float {
        lock.lock()
        defer { lock.unlock() }
        return speechGate.noiseFloorDB
    }

    /// Konuşma kapısını yeni bir kayıt oturumu için sıfırlar.
    /// Gürültü tabanı korunur (oda gürültüsü oturumlar arası değişmez).
    public func resetSpeechGate() {
        lock.lock()
        defer { lock.unlock() }
        speechGate.reset()
    }

    // MARK: - Kayıt Durdurma ve Donanımı Anında Serbest Bırakma

    public func stop() -> (data: Data?, duration: Double) {
        lock.lock()
        guard recordingState, !isStopping else {
            lock.unlock()
            return (nil, 0.0)
        }

        let duration = CFAbsoluteTimeGetCurrent() - startTime
        recordingState = false
        isStopping = true
        let engine = audioEngine
        let callbackGroup = activeTapCallbacks
        let generation = deliveryGeneration
        lock.unlock()

        // Motor durur ve mikrofon donanımı serbest kalır; hazırlanmış graph/tap
        // bir sonraki kayıt için korunur. Aktif callback'ler yine eksiksiz beklenir.
        stopEngine(engine, removeTap: false)
        callbackGroup.wait()
        flushChunkDeliveryQueue()

        lock.lock()
        let remainingCallback = chunkCallback
        let remainingChunk = unconsumedAccumulatedPCM()
        let fullPCM = bufferedPCMData
        let processingMode = processingModeForRecording

        chunkCallback = nil
        firstAudioBufferCallback = nil
        accumulatedPCM = Data()
        accumulatedPCMOffset = 0
        bufferedPCMData = Data()
        currentPower = -160.0
        processingModeForRecording = .none
        hasDeliveredInitialStreamingChunk = false
        activeTapCallbacks = DispatchGroup()
        isStopping = false
        cancelledDeliveryGeneration = nil
        lock.unlock()

        // Hazır bloklar flush edildikten sonra kalan son parçayı ilet.
        if let cb = remainingCallback {
            deliverRemainingChunk(remainingChunk, callback: cb, generation: generation)
        }

        // Stop graph'ı uninitialize eder; sonraki tuş basışından önce arka planda
        // yeniden prepare ederek warm-start durumunu geri kur.
        warm()

        let preparation = Self.prepareRecordingPCM(
            fullPCM,
            processingMode: processingMode
        )
        let finalizedPCM = preparation.data
        if let report = preparation.report {
            print(
                "[AudioClarity] RMPN quality=\(report.quality.rawValue) " +
                "decision=\(report.decision.rawValue) " +
                "snr=\(String(format: "%.1f", report.estimatedSNRDB))dB " +
                "speechRMS=\(String(format: "%.5f", report.robustSpeechRMS)) " +
                "gain=\(String(format: "%.2f", report.appliedGain))x " +
                "clip=\(String(format: "%.3f", report.outputClippingRatio * 100))%"
            )
        }

        // Tamamlanmış kayıt, sessiz olsa bile geçerli bir WAV sonucudur.
        // Gönderim/sessizlik kararı kullanıcı akışını yöneten AppDelegate'e aittir.
        return (Self.finalizeRecordingPCM(finalizedPCM), duration)
    }

    public func cancel() {
        lock.lock()
        guard recordingState, !isStopping else {
            lock.unlock()
            return
        }

        recordingState = false
        isStopping = true
        cancelledDeliveryGeneration = deliveryGeneration
        let engine = audioEngine
        let callbackGroup = activeTapCallbacks
        lock.unlock()

        stopEngine(engine, removeTap: false)
        callbackGroup.wait()
        // Cancel edilen oturumun daha önce kuyruğa alınmış blokları teslim
        // edilmez; kuyruk yine de boşaltılarak yeni oturuma sarkmaları engellenir.
        flushChunkDeliveryQueue()

        lock.lock()
        chunkCallback = nil
        firstAudioBufferCallback = nil
        accumulatedPCM = Data()
        accumulatedPCMOffset = 0
        bufferedPCMData = Data()
        currentPower = -160.0
        processingModeForRecording = .none
        hasDeliveredInitialStreamingChunk = false
        activeTapCallbacks = DispatchGroup()
        isStopping = false
        cancelledDeliveryGeneration = nil
        lock.unlock()
        warm()
    }

    /// Ses motorunu tamamen kapatır, donanım tap'ini söker ve kaynakları serbest bırakır.
    public func cleanTeardown() {
        lock.lock()
        warmupGeneration &+= 1
        guard !isStopping else {
            lock.unlock()
            return
        }

        let engine = audioEngine
        let hasResources = recordingState || engine != nil
        guard hasResources else {
            audioConverter = nil
            conversionBuffer = nil
            preparedHardwareFormat = nil
            inputTapInstalled = false
            chunkCallback = nil
            firstAudioBufferCallback = nil
            accumulatedPCM = Data()
            accumulatedPCMOffset = 0
            bufferedPCMData = Data()
            currentPower = -160.0
            processingModeForRecording = .none
            hasDeliveredInitialStreamingChunk = false
            lock.unlock()
            return
        }

        recordingState = false
        isStopping = true
        cancelledDeliveryGeneration = deliveryGeneration
        let callbackGroup = activeTapCallbacks
        let removeTap = inputTapInstalled
        inputTapInstalled = false
        lock.unlock()

        stopEngine(engine, removeTap: removeTap)
        callbackGroup.wait()
        flushChunkDeliveryQueue()

        lock.lock()
        audioEngine = nil
        audioConverter = nil
        conversionBuffer = nil
        preparedHardwareFormat = nil
        chunkCallback = nil
        firstAudioBufferCallback = nil
        accumulatedPCM = Data()
        accumulatedPCMOffset = 0
        bufferedPCMData = Data()
        currentPower = -160.0
        processingModeForRecording = .none
        hasDeliveredInitialStreamingChunk = false
        activeTapCallbacks = DispatchGroup()
        isStopping = false
        cancelledDeliveryGeneration = nil
        lock.unlock()

        if engine != nil {
            print("[AudioRecorder] 💤 Ses motoru ve donanım serbest bırakıldı.")
        }
    }

    private func calculatePower(buffer: AVAudioPCMBuffer) -> Float {
        guard let floatData = buffer.floatChannelData else { return -160.0 }
        let frameCount = Int(buffer.frameLength)
        guard frameCount > 0 else { return -160.0 }

        var rms: Float = 0
        vDSP_rmsqv(floatData[0], 1, &rms, vDSP_Length(frameCount))
        let db = 20.0 * log10(max(rms, 0.00001))
        return max(-160.0, min(0.0, db))
    }

    // MARK: - WAV ve Ses Yardımcıları

    /// Başlıksız 16-bit PCM bloğunun tepe genliğini kontrol eder. Yerel kayıt
    /// korunurken yalnızca gerçek zamanlı sağlayıcı sınırında dijital sessizliği
    /// göndermemek için de kullanılır.
    public static func isPCM16Silent(data: Data, minAmplitude: Int16 = 24) -> Bool {
        isPCM16Silent(data: data, byteOffset: 0, minAmplitude: minAmplitude)
    }

    /// 16kHz 16-bit PCM WAV verisindeki örneklerin tepe genliğini kontrol eder.
    public static func isAudioSilent(data: Data, minAmplitude: Int16 = 24) -> Bool {
        guard data.count > 44 else { return true }
        return isPCM16Silent(data: data, byteOffset: 44, minAmplitude: minAmplitude)
    }

    private static func isPCM16Silent(data: Data, byteOffset: Int, minAmplitude: Int16) -> Bool {
        guard data.count > byteOffset else { return true }
        return data.withUnsafeBytes { (rawBuffer: UnsafeRawBufferPointer) -> Bool in
            let sampleCount = (data.count - byteOffset) / MemoryLayout<Int16>.size
            let threshold = Int32(minAmplitude)

            for index in 0..<sampleCount {
                let rawSample = rawBuffer.loadUnaligned(
                    fromByteOffset: byteOffset + index * MemoryLayout<Int16>.size,
                    as: Int16.self
                )
                // Int16.min için abs(Int16) taşabilir; önce Int32'e genişlet.
                if abs(Int32(Int16(littleEndian: rawSample))) >= threshold {
                    return false
                }
            }
            return true
        }
    }

    /// Offline netlik yalnız ham kayıt zaten gönderim eşiğini geçiyorsa uygulanır.
    /// Böylece hiçbir gain/VAD formülü dijital sessizliği sağlayıcıya gönderilecek
    /// bir kayda dönüştüremez.
    static func prepareRecordingPCM(
        _ pcmData: Data,
        processingMode: RecordingAudioProcessingMode
    ) -> (data: Data, report: ClarityReport?) {
        guard processingMode == .utteranceClarity,
              !isPCM16Silent(data: pcmData) else {
            return (pcmData, nil)
        }
        let result = UtteranceClarityEnhancer().enhancePCM16(pcmData)
        return (result.data, result.report)
    }

    /// stop() finalizasyonuyla aynı saf dönüşümü test ve çağrı noktaları için sunar.
    static func finalizeRecordingPCM(_ pcmData: Data) -> Data {
        createWavData(pcmData: pcmData, sampleRate: 16000, channels: 1, bitDepth: 16)
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
