import Foundation
import CoreAudio
import AudioToolbox

public struct AudioOutputVolumeSnapshot: Equatable, Sendable {
    public let deviceID: AudioDeviceID
    public let deviceName: String?
    public let volume: Float

    public init(deviceID: AudioDeviceID, deviceName: String?, volume: Float) {
        self.deviceID = deviceID
        self.deviceName = deviceName
        self.volume = volume
    }
}

/// Dikte sırasında macOS CoreAudio'nun yerel `AudioDeviceDuck` mekanizmasını kullanarak
/// diğer uygulamaların sesini yumuşakça kısan (sistem ses seviyesine dokunmadan) ve
/// dikte bitince geri yükleyen servis. `AudioDeviceDuck` kullanılamazsa manuel
/// VirtualMainVolume yedeğine düşer.
public final class AudioDuckingService: @unchecked Sendable {
    public static let shared = AudioDuckingService()

    private typealias AudioDeviceDuckFn = @convention(c) (
        AudioDeviceID,
        Float32,
        UnsafePointer<AudioTimeStamp>?,
        Float32
    ) -> OSStatus

    private static let nativeAudioDeviceDuck: AudioDeviceDuckFn? = {
        let path = "/System/Library/Frameworks/CoreAudio.framework/CoreAudio"
        guard let handle = dlopen(path, RTLD_LAZY),
              let sym = dlsym(handle, "AudioDeviceDuck") else {
            return nil
        }
        return unsafeBitCast(sym, to: AudioDeviceDuckFn.self)
    }()

    private let lock = NSLock()
    private var savedSnapshot: AudioOutputVolumeSnapshot?
    private var usedNativeCoreAudioDuck: Bool = false
    private var duckedDeviceID: AudioDeviceID?
    private var duckedDeviceName: String?
    public private(set) var isDucked: Bool = false

    public init() {}

    /// Diğer uygulamaların sesini algısal desibel azaltımıyla (varsayılan `-13.5 dB`, Apple Siri/FaceTime seviyesi)
    /// yumuşakça arka plana alır; çıkış sesini tamamen kesmez.
    @discardableResult
    public func duckAudio(attenuationDB: Float = -13.5) -> Bool {
        let clampedDB = max(-24.0, min(-3.0, attenuationDB))
        lock.lock()
        defer { lock.unlock() }

        guard !isDucked else { return true }

        guard let deviceID = getDefaultOutputDevice() else {
            print("[AudioDucking] ⚠️ Varsayılan çıkış ses cihazı bulunamadı.")
            return false
        }

        let deviceName = getDeviceName(for: deviceID)
        let nativeDuckScalar = resolvedNativeDuckScalar(attenuationDB: clampedDB, for: deviceID)

        return performDuckLocked(
            deviceID: deviceID,
            deviceName: deviceName,
            nativeScalar: nativeDuckScalar,
            attenuationDB: clampedDB
        )
    }

    /// Eski çağrılarla uyumluluk için scalar/faktör tabanlı giriş.
    @discardableResult
    public func duckAudio(to factor: Float) -> Bool {
        let clampedFactor = max(0.05, min(0.95, factor))
        let equivalentDB = max(-24.0, min(-3.0, 20.0 * log10(clampedFactor)))
        return duckAudio(attenuationDB: equivalentDB)
    }

    private func resolvedNativeDuckScalar(attenuationDB: Float, for deviceID: AudioDeviceID) -> Float {
        if let mapped = decibelsToScalar(attenuationDB, for: deviceID) {
            return max(0.45, min(0.85, mapped))
        }
        let perceptualFallback = pow(Float(10.0), attenuationDB / Float(60.0))
        return max(0.45, min(0.85, perceptualFallback))
    }

    private func performDuckLocked(
        deviceID: AudioDeviceID,
        deviceName: String?,
        nativeScalar: Float,
        attenuationDB: Float
    ) -> Bool {
        if let nativeDuck = Self.nativeAudioDeviceDuck {
            let status = nativeDuck(deviceID, nativeScalar, nil, 0.20)
            if status == noErr {
                usedNativeCoreAudioDuck = true
                duckedDeviceID = deviceID
                duckedDeviceName = deviceName
                savedSnapshot = nil
                isDucked = true
                print("[AudioDucking] 🔉 Apple CoreAudio yerel ducking aktif (\(String(format: "%.1f", attenuationDB)) dB · scalar=\(String(format: "%.2f", nativeScalar)), 0.20s ramp · \(deviceName ?? "Çıkış"))")
                return true
            }
            print("[AudioDucking] ⚠️ CoreAudio AudioDeviceDuck hata döndürdü (\(status)), manuel ses kısma yedeğine geçiliyor.")
        }

        guard let volume = getOutputVolume(for: deviceID) else {
            print("[AudioDucking] ⚠️ Çıkış cihazı ses seviyesi okunamadı.")
            return false
        }
        let snapshot = AudioOutputVolumeSnapshot(deviceID: deviceID, deviceName: deviceName, volume: volume)
        savedSnapshot = snapshot

        let targetVolume: Float
        if let currentDB = scalarToDecibels(snapshot.volume, for: deviceID),
           let steppedScalar = decibelsToScalar(currentDB + attenuationDB, for: deviceID) {
            targetVolume = max(0.0, min(1.0, steppedScalar))
        } else {
            targetVolume = max(0.0, min(1.0, snapshot.volume * 0.62))
        }

        if setOutputVolume(targetVolume, for: snapshot.deviceID) {
            usedNativeCoreAudioDuck = false
            duckedDeviceID = snapshot.deviceID
            duckedDeviceName = snapshot.deviceName
            isDucked = true
            print("[AudioDucking] 🔉 Sistem sesi kısıldı [yedek]: %\(Int(snapshot.volume * 100)) -> %\(Int(targetVolume * 100)) (\(snapshot.deviceName ?? "Çıkış"))")
            return true
        } else {
            savedSnapshot = nil
            print("[AudioDucking] ❌ Sistem sesi kısılamadı.")
            return false
        }
    }

    /// Kısılan arka plan sesini orijinal seviyesine yumuşakça geri yükler
    @discardableResult
    public func restoreAudio() -> Bool {
        lock.lock()
        defer { lock.unlock() }

        guard isDucked else {
            return false
        }

        if usedNativeCoreAudioDuck {
            let primaryDevice = duckedDeviceID ?? getDefaultOutputDevice()
            var status: OSStatus = -1
            if let nativeDuck = Self.nativeAudioDeviceDuck, let devID = primaryDevice {
                status = nativeDuck(devID, 1.0, nil, 0.35)
                if let currentDefault = getDefaultOutputDevice(), currentDefault != devID {
                    _ = nativeDuck(currentDefault, 1.0, nil, 0.35)
                }
            }
            let success = status == noErr
            if success {
                print("[AudioDucking] 🔊 Apple CoreAudio yerel ducking kaldırıldı (0.35s ramp · \(duckedDeviceName ?? "Çıkış"))")
            } else {
                print("[AudioDucking] ⚠️ Apple CoreAudio ducking kaldırılırken hata oluştu (\(status)).")
            }
            usedNativeCoreAudioDuck = false
            duckedDeviceID = nil
            duckedDeviceName = nil
            savedSnapshot = nil
            isDucked = false
            return success
        }

        guard let snapshot = savedSnapshot else {
            isDucked = false
            return false
        }

        let targetDeviceID = getDefaultOutputDevice() ?? snapshot.deviceID
        let success = setOutputVolume(snapshot.volume, for: targetDeviceID)

        if success {
            print("[AudioDucking] 🔊 Sistem sesi orijinal seviyesine geri yüklendi: %\(Int(snapshot.volume * 100))")
        } else {
            print("[AudioDucking] ⚠️ Sistem sesi geri yüklenirken hata oluştu.")
        }

        self.savedSnapshot = nil
        self.duckedDeviceID = nil
        self.duckedDeviceName = nil
        self.isDucked = false
        return success
    }

    // MARK: - CoreAudio HAL Yardımcıları

    public func getCurrentOutputSnapshot() -> AudioOutputVolumeSnapshot? {
        guard let deviceID = getDefaultOutputDevice(),
              let volume = getOutputVolume(for: deviceID) else {
            return nil
        }
        let name = getDeviceName(for: deviceID)
        return AudioOutputVolumeSnapshot(deviceID: deviceID, deviceName: name, volume: volume)
    }

    public func getDefaultOutputDevice() -> AudioDeviceID? {
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0, nil,
            &size,
            &deviceID
        )

        guard status == noErr, deviceID != 0 else { return nil }
        return deviceID
    }

    public func getOutputVolume(for deviceID: AudioDeviceID) -> Float? {
        var volume: Float = 0
        var size = UInt32(MemoryLayout<Float>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )

        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &volume)
        return status == noErr ? volume : nil
    }

    public func setOutputVolume(_ volume: Float, for deviceID: AudioDeviceID) -> Bool {
        var volume = max(0.0, min(1.0, volume))
        let size = UInt32(MemoryLayout<Float>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )

        let status = AudioObjectSetPropertyData(deviceID, &address, 0, nil, size, &volume)
        return status == noErr
    }

    public func decibelsToScalar(_ decibels: Float, for deviceID: AudioDeviceID) -> Float? {
        var value = decibels
        var size = UInt32(MemoryLayout<Float>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeDecibelsToScalar,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &value)
        return status == noErr ? value : nil
    }

    public func scalarToDecibels(_ scalar: Float, for deviceID: AudioDeviceID) -> Float? {
        var value = max(0.0, min(1.0, scalar))
        var size = UInt32(MemoryLayout<Float>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalarToDecibels,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &value)
        return status == noErr ? value : nil
    }

    private func getDeviceName(for deviceID: AudioDeviceID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceNameCFString,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &value)
        guard status == noErr, let cf = value else { return nil }
        return cf.takeUnretainedValue() as String
    }
}
