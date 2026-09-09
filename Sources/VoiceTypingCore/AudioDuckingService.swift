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

/// Dikte sırasında sistem genel çıkış sesini kısan (Audio Ducking) ve dikte bitince
/// önceki ses seviyesini milisaniyeler içinde geri yükleyen CoreAudio HAL servisi.
public final class AudioDuckingService: @unchecked Sendable {
    public static let shared = AudioDuckingService()

    private let lock = NSLock()
    private var savedSnapshot: AudioOutputVolumeSnapshot?
    public private(set) var isDucked: Bool = false

    public init() {}

    /// Sistem çıkış sesini belirtilen orana kısar (örn: 0.20 = %20 seviyesine)
    @discardableResult
    public func duckAudio(to factor: Float = 0.20) -> Bool {
        lock.lock()
        defer { lock.unlock() }

        guard !isDucked else { return true }

        guard let snapshot = getCurrentOutputSnapshot() else {
            print("[AudioDucking] ⚠️ Varsayılan çıkış ses cihazı bulunamadı.")
            return false
        }

        savedSnapshot = snapshot
        let targetVolume = max(0.0, min(1.0, snapshot.volume * factor))

        if setOutputVolume(targetVolume, for: snapshot.deviceID) {
            isDucked = true
            print("[AudioDucking] 🔉 Sistem sesi kısıldı: %\(Int(snapshot.volume * 100)) -> %\(Int(targetVolume * 100)) (\(snapshot.deviceName ?? "Çıkış"))")
            return true
        } else {
            savedSnapshot = nil
            print("[AudioDucking] ❌ Sistem sesi kısılamadı.")
            return false
        }
    }

    /// Kısılan sistem sesini orijinal seviyesine geri yükler
    @discardableResult
    public func restoreAudio() -> Bool {
        lock.lock()
        defer { lock.unlock() }

        guard isDucked, let snapshot = savedSnapshot else {
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
