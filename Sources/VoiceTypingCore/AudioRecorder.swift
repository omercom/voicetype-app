import Foundation
import AVFoundation

public class AudioRecorder: NSObject, AVAudioRecorderDelegate {
    public static let shared = AudioRecorder()

    private var recorder: AVAudioRecorder?
    private var tempFileURL: URL
    private var startTime: CFAbsoluteTime = 0
    private let lock = NSLock()

    public private(set) var isRecording: Bool = false

    override private init() {
        let tempDir = FileManager.default.temporaryDirectory
        self.tempFileURL = tempDir.appendingPathComponent("voice_typing_\(ProcessInfo.processInfo.processIdentifier).wav")
        super.init()
    }

    public func start() -> Bool {
        lock.lock()
        defer { lock.unlock() }

        if isRecording {
            return false
        }

        try? FileManager.default.removeItem(at: tempFileURL)

        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatLinearPCM),
            AVSampleRateKey: 16000.0,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsFloatKey: false
        ]

        do {
            recorder = try AVAudioRecorder(url: tempFileURL, settings: settings)
            recorder?.delegate = self
            recorder?.isMeteringEnabled = true

            guard let rec = recorder, rec.prepareToRecord(), rec.record() else {
                recorder = nil
                return false
            }

            isRecording = true
            startTime = CFAbsoluteTimeGetCurrent()
            return true
        } catch {
            print("[Hata] Mikrofon başlatılamadı: \(error.localizedDescription)")
            recorder = nil
            isRecording = false
            return false
        }
    }

    /// Anlık mikrofon ses seviyesini (dB cinsinden) döner.
    public func averagePower() -> Float {
        lock.lock()
        defer { lock.unlock() }
        guard let rec = recorder, isRecording else { return -160.0 }
        rec.updateMeters()
        return rec.averagePower(forChannel: 0)
    }

    public func stop() -> (data: Data?, duration: Double) {
        lock.lock()
        defer { lock.unlock() }

        guard isRecording, let rec = recorder else {
            return (nil, 0.0)
        }

        let duration = CFAbsoluteTimeGetCurrent() - startTime
        rec.stop()
        recorder = nil
        isRecording = false

        guard FileManager.default.fileExists(atPath: tempFileURL.path) else {
            return (nil, duration)
        }

        do {
            let data = try Data(contentsOf: tempFileURL)
            try? FileManager.default.removeItem(at: tempFileURL)

            // Akıllı sessizlik ve mikrofonsuzluk kontrolü (PCM 16-bit tepe genlik)
            if AudioRecorder.isAudioSilent(data: data) {
                return (nil, duration)
            }

            return (data, duration)
        } catch {
            print("[Hata] Kaydedilen ses verisi okunamadı: \(error.localizedDescription)")
            return (nil, duration)
        }
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

    public func cancel() {
        lock.lock()
        defer { lock.unlock() }

        if isRecording {
            recorder?.stop()
            recorder = nil
            isRecording = false
            try? FileManager.default.removeItem(at: tempFileURL)
        }
    }
}
