import Foundation
import CoreAudio
import AudioToolbox
import AppKit

/// macOS Sistem Genelinde Ana Çıkış Sesini (Master Output Audio)
/// konuşma anında anlık (0ms gecikmeyle) sessize alan ve konuşma bitince eski seviyesine geri getiren yönetici.
/// Bu sayede YouTube, Chrome, Safari, Spotify, oyunlar veya sistem sesleri mikrofona sızmaz (akustik yankı önlenir).
public class SystemAudioManager {
    public static let shared = SystemAudioManager()

    private var wasMutedBefore = false
    private var didMute = false
    private let lock = NSLock()

    private init() {}

    /// Varsayılan ana ses çıkış aygıtı kimliğini döner
    private func getDefaultOutputDevice() -> AudioDeviceID {
        var defaultOutputDeviceID = AudioDeviceID(0)
        var propertySize = UInt32(MemoryLayout<AudioDeviceID>.size)
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            0, nil,
            &propertySize,
            &defaultOutputDeviceID
        )
        return status == noErr ? defaultOutputDeviceID : 0
    }

    /// Çıkış sesinin şu anda sessizde olup olmadığını denetler
    public func isOutputMuted() -> Bool {
        let deviceID = getDefaultOutputDevice()
        guard deviceID != 0 else { return false }

        var isMuted: UInt32 = 0
        var propertySize = UInt32(MemoryLayout<UInt32>.size)
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )

        if AudioObjectHasProperty(deviceID, &propertyAddress) {
            let status = AudioObjectGetPropertyData(deviceID, &propertyAddress, 0, nil, &propertySize, &isMuted)
            if status == noErr {
                return isMuted == 1
            }
        }
        return false
    }

    /// Çıkış sesini CoreAudio donanım katmanında (0ms) sessize alır veya açar
    public func setOutputMuted(_ mute: Bool) {
        let deviceID = getDefaultOutputDevice()
        var success = false

        if deviceID != 0 {
            var muteVal: UInt32 = mute ? 1 : 0
            let propertySize = UInt32(MemoryLayout<UInt32>.size)
            var propertyAddress = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyMute,
                mScope: kAudioDevicePropertyScopeOutput,
                mElement: kAudioObjectPropertyElementMain
            )

            if AudioObjectHasProperty(deviceID, &propertyAddress) {
                var settable: DarwinBoolean = false
                AudioObjectIsPropertySettable(deviceID, &propertyAddress, &settable)
                if settable.boolValue {
                    let status = AudioObjectSetPropertyData(deviceID, &propertyAddress, 0, nil, propertySize, &muteVal)
                    if status == noErr {
                        success = true
                    }
                }
            }
        }

        // Eğer CoreAudio doğrudan yazılamadıysa (örn: harici USB ses kartı), AppleScript ile asenkron sustur
        if !success {
            DispatchQueue.global(qos: .userInteractive).async {
                let script = "set volume output muted \(mute ? "true" : "false")"
                if let appleScript = NSAppleScript(source: script) {
                    appleScript.executeAndReturnError(nil)
                }
            }
        }
    }

    private var pendingMuteWorkItem: DispatchWorkItem?

    /// Konuşma başladığında ana çıkış sesini kapatır.
    /// İsteğe bağlı delay parametresi verilirse (örn: 0.15s), başlangıç ses efektinin (dictation-start)
    /// kullanıcı tarafından net olarak duyulmasına izin verir, ardından ortam sesini/müziği susturur.
    public func muteForDictation(delay: TimeInterval = 0) {
        lock.lock()
        pendingMuteWorkItem?.cancel()
        pendingMuteWorkItem = nil
        lock.unlock()

        if delay > 0 {
            let item = DispatchWorkItem { [weak self] in
                self?.performMute()
            }
            lock.lock()
            pendingMuteWorkItem = item
            lock.unlock()
            DispatchQueue.global(qos: .userInteractive).asyncAfter(deadline: .now() + delay, execute: item)
        } else {
            performMute()
        }
    }

    private func performMute() {
        lock.lock()
        defer { lock.unlock() }

        guard !didMute else { return }

        wasMutedBefore = isOutputMuted()
        if !wasMutedBefore {
            setOutputMuted(true)
            didMute = true
        }
    }

    /// Konuşma bittiğinde, deşifre tamamlandığında veya iptal edildiğinde sesi eski durumuna getirir
    public func restoreAfterDictation() {
        lock.lock()
        pendingMuteWorkItem?.cancel()
        pendingMuteWorkItem = nil
        defer { lock.unlock() }

        if didMute {
            if !wasMutedBefore {
                setOutputMuted(false)
            }
            didMute = false
        }
    }
}
