import Foundation
import simd

public enum DotScopeProcessingStyle: String, Codable, CaseIterable, Sendable {
    case flow
    case pulse
    case sweep

    public static func resolve(_ raw: String) -> DotScopeProcessingStyle {
        DotScopeProcessingStyle(rawValue: raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()) ?? .flow
    }
}

public enum DotScopeStage: Equatable, Sendable {
    case preparing
    case recording
    case processing
    case done
    case notice
    case failed
}

public enum DotScopeAccentMode: Equatable, Sendable {
    case normal
    case translation
}

public struct DotScopeTuning: Equatable, Sendable {
    public static let maxColumns = 64
    public static let maxRows = 15
    public static let maxDots = 1024
    public static let plateHeight: Float = 26.0

    public var columns: Int
    public var rows: Int
    public var spacing: Float
    public var recordingWidth: Float
    public var processingWidth: Float
    public var height: Float
    public var braidSpeed: Float
    public var helixCycles: Float
    public var gain: Float
    public var responseHz: Float
    public var releaseSec: Float
    public var historySpeed: Float
    public var phosphorSec: Float
    public var glow: Float
    public var saturation: Float
    public var shimmerPassSec: Float
    public var shimmer: Float
    public var transitionSec: Float
    public var bounce: Float
    public var autoLevel: Bool
    public var autoReleaseSec: Float
    public var noiseFloorDB: Float
    public var processingStyle: DotScopeProcessingStyle

    public init(
        columns: Int = 43,
        rows: Int = 9,
        spacing: Float = 2.6,
        recordingWidth: Float = 112.0,
        processingWidth: Float = 76.0,
        height: Float = DotScopeTuning.plateHeight,
        braidSpeed: Float = 1.0,
        helixCycles: Float = 1.6,
        gain: Float = 1.0,
        responseHz: Float = 6.5,
        releaseSec: Float = 0.15,
        historySpeed: Float = 150.0,
        phosphorSec: Float = 0.6,
        glow: Float = 1.0,
        saturation: Float = 1.0,
        shimmerPassSec: Float = 0.55,
        shimmer: Float = 1.0,
        transitionSec: Float = 0.30,
        bounce: Float = 0.15,
        autoLevel: Bool = true,
        autoReleaseSec: Float = 3.0,
        noiseFloorDB: Float = -62.0,
        processingStyle: DotScopeProcessingStyle = .flow
    ) {
        self.columns = max(7, min(Self.maxColumns, columns))
        let maxAllowedRows = max(3, min(Self.maxRows, Self.maxDots / self.columns))
        self.rows = max(3, min(maxAllowedRows, rows))
        self.spacing = max(1.6, min(4.0, spacing))
        self.recordingWidth = max(24.0, min(280.0, recordingWidth))
        self.processingWidth = max(24.0, min(280.0, processingWidth))
        self.height = max(14.0, min(40.0, height))
        self.braidSpeed = braidSpeed
        self.helixCycles = helixCycles
        self.gain = gain
        self.responseHz = responseHz
        self.releaseSec = releaseSec
        self.historySpeed = historySpeed
        self.phosphorSec = phosphorSec
        self.glow = glow
        self.saturation = saturation
        self.shimmerPassSec = shimmerPassSec
        self.shimmer = shimmer
        self.transitionSec = transitionSec
        self.bounce = bounce
        self.autoLevel = autoLevel
        self.autoReleaseSec = autoReleaseSec
        self.noiseFloorDB = noiseFloorDB
        self.processingStyle = processingStyle
    }

    public static let compactDefault = DotScopeTuning()
    public static let pillBadge = DotScopeTuning(
        columns: 27,
        rows: 7,
        spacing: 2.35,
        recordingWidth: 68.0,
        processingWidth: 58.0,
        height: 22.0,
        historySpeed: 120.0
    )
    public static let notchSlot = DotScopeTuning(
        columns: 21,
        rows: 7,
        spacing: 2.2,
        recordingWidth: 50.0,
        processingWidth: 50.0,
        height: 18.0,
        historySpeed: 105.0
    )
}

public struct DotScopePalette: Equatable, Sendable {
    public var base: SIMD3<Float>
    public var core: SIMD3<Float>
    public var plate: SIMD4<Float>
    public var rim: SIMD4<Float>
    public var shadow: SIMD4<Float>
}

public struct DotScopePose: Equatable, Sendable {
    public var width: Float
    public var height: Float
    public var opacity: Float
    public var scale: Float
    public var softness: Float
    public var cool: Float
    public var fail: Float
    public var done: Float
    public var notice: Float
    public var live: Float
    public var glow: Float
    public var grid: Float
    public var level: Float
    public var clock: Float
    public var ripplePhase: Float
    public var rippleIntensity: Float
    public var rimShimmerPhase: Float
    public var harmonicHeat: Float
    public var palette: DotScopePalette
}

/// 240 Hz sabit adımlı Hex Dot Scope simülasyonu ve geliştirilmiş fosfor/hale efektleri.
public final class DotScopeSimulation {
    public static let fixedStep: Float = 1.0 / 240.0
    private static let historyLength = 512
    private static let samplesPerColumn = 3
    private static let componentSpeeds: [Float] = [0.8, 1.25, 1.85, 2.6]
    private static let componentBase: [Float] = [0.55, 0.42, 0.30, 0.20]
    private static let componentSpatial: [Float] = [1.4, 2.4, 3.8, 5.6]
    private static let startWidth: Float = 30.0
    private static let enterDuration: Float = 0.42
    private static let wipeDuration: Float = 0.30
    private static let passInset: Float = 9.0
    private static let phosphorHeadSec: Float = 0.15
    private static let breathPeriodSec: Float = 5.5
    private static let hiddenScale: Double = 0.90
    private static let hiddenSoftness: Double = 3.0
    private static let workHelixScale: Float = 2.6
    private static let flowSpacingRatio: Float = 0.7
    private static let carrierRestHz: Float = 0.14
    private static let ringBirthSec: Float = 0.15

    public struct AutoLevel: Equatable, Sendable {
        public private(set) var peak: Float = -30.0
        public private(set) var room: Float = -55.0

        private static let minSpan: Float = 16.0
        private static let range: Float = 24.0
        private static let roomMargin: Float = 5.0
        private static let attackSec: Float = 0.04
        private static let roomFallSec: Float = 0.30
        private static let roomRiseSec: Float = 6.0

        public mutating func step(loudnessDB: Float, dt: Float, releaseSec: Float, noiseFloorDB: Float) -> Float {
            let db = max(-120.0, loudnessDB.isFinite ? loudnessDB : -120.0)
            let roomTime = db < room ? Self.roomFallSec : Self.roomRiseSec
            room += (db - room) * (1.0 - exp(-dt / max(1e-3, roomTime)))
            let lowest = max(room, noiseFloorDB) + Self.minSpan
            if db > peak {
                peak += (db - peak) * (1.0 - exp(-dt / Self.attackSec))
            } else {
                peak += (lowest - peak) * (1.0 - exp(-dt / max(1e-3, releaseSec)))
            }
            peak = max(peak, lowest)
            return level(for: db, noiseFloorDB: noiseFloorDB)
        }

        public func level(for loudnessDB: Float, noiseFloorDB: Float) -> Float {
            let low = max(max(room, noiseFloorDB) + Self.roomMargin, peak - Self.range)
            return Self.clamp((loudnessDB - low) / max(1.0, peak - low), 0.0, 1.0)
        }

        private static func clamp(_ v: Float, _ lo: Float, _ hi: Float) -> Float {
            min(hi, max(lo, v))
        }
    }

    private struct Voice {
        var level: Float = 0.0
        var reservoir: Float = 0.0
        var energy: Float = 0.0
        var kick: Float = 0.0
        var kickVelocity: Float = 0.0
        var band: Float = 0.0

        mutating func step(raw: Float, dt: Float) {
            let previous = level
            let time: Float = raw > level ? 0.035 : 0.095
            level += (raw - level) * (1.0 - exp(-dt / time))
            let rise = max(0.0, (level - previous) / dt)
            reservoir += (1.75 * level * level - reservoir / 1.8) * dt
            energy = 1.0 - exp(-reservoir * 1.45)
            let w = Float.pi * 2.0 * 1.3
            let z: Float = 0.22
            kickVelocity += (-w * w * kick - 2.0 * z * w * kickVelocity + 15.0 * rise + 2.2 * level) * dt
            kick += kickVelocity * dt
            let bandTime: Float = raw > band ? 0.025 : 0.14
            band += (raw - band) * (1.0 - exp(-dt / bandTime))
        }
    }

    private struct Trace {
        var envelope: Float = 0.0
        var amplitude: Float = 0.0
        var amplitudeVelocity: Float = 0.0
        var glowFast: Float = 0.0
        var glowSpring: Float = 0.0
        var glowSpringVelocity: Float = 0.0
        var glowSlow: Float = 0.0
        var glow: Float = 0.0
        var phases: [Float]
        var history: [Float]
        var head: Int = 0

        init(phases: [Float]) {
            self.phases = phases
            self.history = [Float](repeating: 0.0, count: DotScopeSimulation.historyLength * 5)
        }

        mutating func tick(voice: Voice, live: Float, speed: Float, tuning: DotScopeTuning, dt: Float) {
            let tau = Float.pi * 2.0
            func follow(_ value: inout Float, target: Float, rise: Float, fall: Float) {
                let t = target > value ? rise : fall
                value += (target - value) * (1.0 - exp(-dt / max(1e-3, t)))
            }
            follow(&envelope, target: voice.level, rise: 0.022, fall: tuning.releaseSec)
            let w = tau * tuning.responseHz
            let z: Float = 0.52
            amplitudeVelocity += (-w * w * (amplitude - envelope) - 2.0 * z * w * amplitudeVelocity) * dt
            amplitude += amplitudeVelocity * dt

            follow(&glowFast, target: voice.level, rise: 0.045, fall: 0.13)
            let gw = tau * 3.6
            let gz: Float = 0.5
            glowSpringVelocity += (-gw * gw * (glowSpring - glowFast) - 2.0 * gz * gw * glowSpringVelocity) * dt
            glowSpring += glowSpringVelocity * dt

            follow(&glowSlow, target: voice.level, rise: 0.15, fall: 0.70)
            let swell = 0.8 * max(0.0, glowSpring - 0.25) + 0.04 * max(-0.5, voice.kick)
            glow = min(1.15, max(0.0, swell) + 0.42 * glowSlow + 0.20 * voice.energy) * live

            let go = 0.6 + 1.1 * min(1.0, envelope * 1.6)
            for idx in 0..<4 {
                phases[idx] = (phases[idx] + dt * tau * componentSpeeds[idx] * go * speed)
                    .truncatingRemainder(dividingBy: tau)
            }

            let emphasis = 0.35 + 0.65 * min(2.0, voice.band / (voice.band + 0.06))
            let offset = head * 5
            let amp = max(0.0, amplitude) * live
            history[offset] = amp
            for c in 0..<4 {
                history[offset + 1 + c] = amp * componentBase[c] * emphasis
            }
            head = (head + 1) % historyLength
        }

        func past(delay: Float, channel: Int) -> Float {
            let d = min(Float(historyLength - 2), max(0.0, delay / DotScopeSimulation.fixedStep))
            let i = Int(floor(d))
            let k = d - Float(i)
            let a = (head + 2 * historyLength - 1 - i) % historyLength
            let b = (a + historyLength - 1) % historyLength
            return history[a * 5 + channel] * (1.0 - k) + history[b * 5 + channel] * k
        }
    }

    private enum Working {
        case flow(offset: Float, spacing: Float)
        case pulse(time: Float, period: Float, speed: Float)

        func light(at x: Float, halfWidth: Float) -> Float {
            switch self {
            case let .flow(offset, spacing):
                let shifted = x - offset + spacing * 0.5
                let rem = shifted - spacing * floor(shifted / spacing)
                let d = rem - spacing * 0.5
                return DotScopeSimulation.bump(d, width: 7.0)
            case let .pulse(time, period, speed):
                let d = abs(x)
                var light: Float = 0.0
                var age = time - period * floor(time / max(1e-3, period))
                while age * speed < halfWidth + 12.0 && age <= time + 1e-4 {
                    let radius = age * speed
                    let fade = DotScopeSimulation.smoothstep(0.0, DotScopeSimulation.ringBirthSec, age)
                        * (1.0 - 0.6 * DotScopeSimulation.smoothstep(0.3 * halfWidth, halfWidth, radius))
                    light += DotScopeSimulation.bump(d - radius, width: 6.0) * fade
                    age += period
                }
                return min(1.0, light)
            }
        }
    }

    private enum Envelope {
        case enter(reach: Float, head: Float, unfold: Float)
        case process(iron: Float, front: Float, head: Float)
        case work(working: Working, head: Float, swell: Float, halfWidth: Float)
        case clear(front: Float, head: Float, beam: Float, beamAt: Float, field: Float,
                   working: Working, glow: Float, swell: Float, halfWidth: Float)

        func at(_ x: Float) -> (amplitude: Float, brightness: Float, swell: Float) {
            switch self {
            case let .enter(reach, head, unfold):
                let d = abs(x)
                let drawn = unfold * (1.0 - DotScopeSimulation.smoothstep(max(0.0, reach - 14.0), max(0.001, reach), d))
                let amplitude = drawn * (1.0 - DotScopeSimulation.smoothstep(max(0.0, reach - 22.0), max(0.001, reach - 3.0), d))
                let beam = head * DotScopeSimulation.bump(d - reach, width: 6.0)
                let swell = 1.8 * unfold * (head / 2.8) * DotScopeSimulation.bump(d - max(0.0, reach - 14.0), width: 14.0)
                return (amplitude, amplitude + beam, swell)
            case let .process(iron, front, head):
                return (iron, iron + head * DotScopeSimulation.bump(x - front, width: 5.0), 0.0)
            case let .work(working, head, swell, halfWidth):
                let light = working.light(at: x, halfWidth: halfWidth)
                return (1.0, 1.0 + head * light, swell * light)
            case let .clear(front, head, beam, beamAt, field, working, glow, swell, halfWidth):
                let d = abs(x)
                let keep = field * DotScopeSimulation.smoothstep(front - 12.0, front - 2.0, d)
                let light = working.light(at: x, halfWidth: halfWidth)
                let b = keep * (1.0 + glow * light)
                    + head * DotScopeSimulation.bump(d - front, width: 6.0)
                    + beam * DotScopeSimulation.bump(x - beamAt, width: 5.0)
                return (keep, b, keep * swell * light)
            }
        }
    }

    private struct Scan {
        var helix: Float
        var decay: Float
        var tail: Float
        var grid: Float
        var envelope: Envelope
    }

    public private(set) var tuning: DotScopeTuning
    public private(set) var stage: DotScopeStage = .recording
    public var accentMode: DotScopeAccentMode = .normal
    public private(set) var dots: [SIMD2<Float>] = []
    public private(set) var currentLevel: Float = 0.0

    private var elapsed: Float = 0.0
    private var speedAtDone: Float = 0.0
    private var doneFrom: Float = 0.0
    private var flowOffset: Float = 0.0
    private var flowTurn: Float = 0.0
    private var auto = AutoLevel()
    private var voices = [Voice(), Voice()]
    private var traces = [
        Trace(phases: [0.1, 1.7, 3.3, 4.6]),
        Trace(phases: [2.4, 0.6, 5.1, 1.9])
    ]
    private var live: Float = 0.0
    private var carrier: Float = 0.0
    private var time: Float = 0.0
    private var steps: UInt64 = 0
    private var pending: Float = 0.0
    private var reduceMotion = false

    private var headBuffer: [[Float]] = [[], []]
    private var tailBuffer: [[Float]] = [[], []]
    private var ysBuffer: [[Float]] = [[], []]
    private var brightnessBuffer: [[Float]] = [[], []]
    private var grid: Float = 0.0

    private var widthSpring: HUDSpring
    private var opacitySpring = HUDSpring(at: 0.0)
    private var scaleSpring = HUDSpring(at: DotScopeSimulation.hiddenScale)
    private var softnessSpring = HUDSpring(at: DotScopeSimulation.hiddenSoftness)
    private var coolSpring = HUDSpring(at: 0.0)
    private var failSpring = HUDSpring(at: 0.0)
    private var doneSpring = HUDSpring(at: 0.0)
    private var noticeSpring = HUDSpring(at: 0.0)

    // Geliştirilmiş efekt durumları (vokal dalga halkası + cam kenar parıltısı + harmonik ısı)
    private var ripplePhase: Float = 1.0
    private var rippleIntensity: Float = 0.0
    private var rimShimmerPhase: Float = 0.0
    private var harmonicHeat: Float = 0.0
    private var wasSpeakingForRipple = false

    public init(tuning: DotScopeTuning = .compactDefault) {
        self.tuning = tuning
        self.widthSpring = HUDSpring(at: Double(Self.startWidth))
        resizeBuffers()
    }

    public func updateTuning(_ newTuning: DotScopeTuning) {
        let sizeChanged = newTuning.columns != tuning.columns || newTuning.rows != tuning.rows
        tuning = newTuning
        if sizeChanged {
            resizeBuffers()
        }
    }

    public func restart(reduceMotion: Bool) {
        let preservedAuto = auto
        let preservedTuning = tuning
        let preservedAccent = accentMode
        self.tuning = preservedTuning
        self.accentMode = preservedAccent
        self.auto = preservedAuto
        self.stage = .recording
        self.elapsed = 0.0
        self.speedAtDone = 0.0
        self.doneFrom = 0.0
        self.flowOffset = 0.0
        self.flowTurn = 0.0
        self.currentLevel = 0.0
        self.voices = [Voice(), Voice()]
        self.traces = [
            Trace(phases: [0.1, 1.7, 3.3, 4.6]),
            Trace(phases: [2.4, 0.6, 5.1, 1.9])
        ]
        self.live = 0.0
        self.carrier = 0.0
        self.time = 0.0
        self.steps = 0
        self.pending = 0.0
        self.reduceMotion = reduceMotion
        self.grid = 0.0
        self.ripplePhase = 1.0
        self.rippleIntensity = 0.0
        self.rimShimmerPhase = 0.0
        self.harmonicHeat = 0.0
        self.wasSpeakingForRipple = false

        let total = tuning.columns * tuning.rows
        headBuffer = [[Float](repeating: 0.0, count: total), [Float](repeating: 0.0, count: total)]
        tailBuffer = [[Float](repeating: 0.0, count: total), [Float](repeating: 0.0, count: total)]
        dots = [SIMD2<Float>](repeating: .zero, count: total)

        widthSpring = HUDSpring(at: Double(Self.startWidth))
        opacitySpring = HUDSpring(at: 0.0)
        scaleSpring = HUDSpring(at: Self.hiddenScale)
        softnessSpring = HUDSpring(at: Self.hiddenSoftness)
        coolSpring = HUDSpring(at: 0.0)
        failSpring = HUDSpring(at: 0.0)
        doneSpring = HUDSpring(at: 0.0)
        noticeSpring = HUDSpring(at: 0.0)

        if reduceMotion {
            scaleSpring.jump(to: 1.0)
            softnessSpring.jump(to: 0.0)
            widthSpring.jump(to: Double(tuning.recordingWidth))
            opacitySpring.jump(to: 1.0)
        }
    }

    public func triggerRipple(strength: Float = 1.0) {
        ripplePhase = 0.0
        rippleIntensity = max(rippleIntensity, min(1.35, strength))
    }

    public func advance(
        dt: Float,
        stage nextStage: DotScopeStage,
        visible: Bool = true,
        loudnessDB: Float = -120.0,
        reduceMotion: Bool = false
    ) {
        if nextStage != stage {
            if nextStage == .done {
                armDone()
                triggerRipple(strength: 1.15)
            } else if nextStage == .processing {
                flowOffset = -Float(widthSpring.x) * 0.5 - 4.0
            } else if nextStage == .recording {
                wasSpeakingForRipple = false
            }
            stage = nextStage
            elapsed = 0.0
        }

        self.reduceMotion = reduceMotion
        pending += min(0.25, max(0.0, dt.isFinite ? dt : 0.0))
        while pending >= Self.fixedStep {
            pending -= Self.fixedStep
            step(visible: visible, loudnessDB: loudnessDB, reduceMotion: reduceMotion)
        }
    }

    public func pose() -> DotScopePose {
        let width = max(Float(widthSpring.x), tuning.height)
        let opacity = Self.clamp(Float(opacitySpring.x), 0.0, 1.0)
        let scale = max(0.01, Float(scaleSpring.x))
        let softness = Self.clamp(Float(softnessSpring.x), 0.0, Float(Self.hiddenSoftness))
        let cool = Self.clamp(Float(coolSpring.x), 0.0, 1.0)
        let fail = Self.clamp(Float(failSpring.x), 0.0, 1.0)
        let done = Self.clamp(Float(doneSpring.x), 0.0, 1.0)
        let notice = Self.clamp(Float(noticeSpring.x), 0.0, 1.0)
        let avgGlow = (traces[0].glow + traces[1].glow) * 0.5 * tuning.glow

        let pal = Self.computePalette(
            accent: accentMode,
            cool: cool,
            fail: fail,
            done: done,
            notice: notice,
            harmonicHeat: harmonicHeat,
            saturation: tuning.saturation
        )

        return DotScopePose(
            width: width,
            height: tuning.height,
            opacity: opacity,
            scale: scale,
            softness: softness,
            cool: cool,
            fail: fail,
            done: done,
            notice: notice,
            live: live,
            glow: avgGlow,
            grid: grid,
            level: Self.clamp(voices[0].level, 0.0, 1.0),
            clock: reduceMotion ? 0.0 : elapsed,
            ripplePhase: ripplePhase,
            rippleIntensity: rippleIntensity,
            rimShimmerPhase: rimShimmerPhase,
            harmonicHeat: harmonicHeat,
            palette: pal
        )
    }

    /// Hex HUD Lab sentetik konuşma seviyesi (Önizleme için).
    public static func demoLoudness(at time: Float) -> Float {
        let phraseDur: Float = 2.4
        let spokenDur: Float = 1.7
        let phrase = floor(time / phraseDur)
        let t = time - phrase * phraseDur
        if t > spokenDur { return -57.0 }
        let shape = pow(sin(Float.pi * t / spokenDur), 0.4)
        let tau = Float.pi * 2.0
        let rate = tau * (4.3 + 0.6 * sin(phrase * 1.7))
        let syllable = 0.5 + 0.5 * sin(rate * t + phrase)
        let stress = 0.75 + 0.25 * sin(tau * 1.1 * t + 2.0 * phrase)
        let lvl = Self.clamp(0.08 + 0.82 * shape * pow(syllable, 1.6) * stress, 0.0, 1.0)
        return -58.0 + 28.0 * lvl
    }

    // MARK: - Private Physics

    private func resizeBuffers() {
        let total = tuning.columns * tuning.rows
        headBuffer = [[Float](repeating: 0.0, count: total), [Float](repeating: 0.0, count: total)]
        tailBuffer = [[Float](repeating: 0.0, count: total), [Float](repeating: 0.0, count: total)]
        dots = [SIMD2<Float>](repeating: .zero, count: total)
        let samples = (tuning.columns - 1) * Self.samplesPerColumn + 1
        ysBuffer = [[Float](repeating: 0.0, count: samples), [Float](repeating: 0.0, count: samples)]
        brightnessBuffer = [[Float](repeating: 0.0, count: samples), [Float](repeating: 0.0, count: samples)]
    }

    private func step(visible: Bool, loudnessDB: Float, reduceMotion: Bool) {
        let h = Self.fixedStep
        let tau = Float.pi * 2.0
        let isRecording = (stage == .recording) && visible

        let rawLevel: Float
        if isRecording {
            if tuning.autoLevel {
                currentLevel = auto.step(
                    loudnessDB: loudnessDB,
                    dt: h,
                    releaseSec: tuning.autoReleaseSec,
                    noiseFloorDB: tuning.noiseFloorDB
                )
            } else {
                currentLevel = Self.clamp((loudnessDB + 40.0) / 30.0, 0.0, 1.0)
            }
            rawLevel = Self.clamp(currentLevel * tuning.gain, 0.0, 1.0)
        } else if stage == .preparing && visible {
            currentLevel = 0.0
            rawLevel = 0.14
        } else {
            currentLevel = 0.0
            rawLevel = 0.0
        }

        // İlk ses başlangıcında (sessizlik -> konuşma) zarif bir akustik dalga halkası tetikle.
        if isRecording {
            if !wasSpeakingForRipple && rawLevel > 0.22 {
                wasSpeakingForRipple = true
                if !reduceMotion { triggerRipple(strength: 0.85) }
            } else if rawLevel < 0.06 {
                wasSpeakingForRipple = false
            }
        }

        voices[0].step(raw: rawLevel, dt: h)
        voices[1].step(raw: rawLevel * 0.85, dt: h)

        let liveTarget: Float = (isRecording || stage == .preparing) ? 1.0 : 0.0
        live += (liveTarget - live) * (1.0 - exp(-h / 0.55))

        let speed: Float = reduceMotion ? 0.0 : tuning.braidSpeed
        for idx in 0..<2 {
            traces[idx].tick(voice: voices[idx], live: live, speed: speed, tuning: tuning, dt: h)
        }

        let energy = max(voices[0].energy, voices[1].energy)
        let heatTarget = isRecording ? min(1.0, energy * 0.9 + voices[0].level * 0.45) : 0.0
        harmonicHeat += (heatTarget - harmonicHeat) * (1.0 - exp(-h / 0.14))

        if !reduceMotion {
            let rimRate: Float = (stage == .processing || stage == .preparing) ? 1.35 : 0.45
            rimShimmerPhase = (rimShimmerPhase + h * tau * rimRate).truncatingRemainder(dividingBy: tau)
            if rippleIntensity > 0.001 {
                ripplePhase = min(1.5, ripplePhase + h * 1.95)
                rippleIntensity *= exp(-h / 0.34)
            } else {
                rippleIntensity = 0.0
            }
        }

        let working = (stage == .processing || stage == .done || stage == .preparing)
        let flowing = working && tuning.processingStyle == .flow
        flowTurn += ((flowing ? 1.0 : 0.0) - flowTurn) * (1.0 - exp(-h / 0.25))
        if working {
            flowOffset += flowSpeed() * h
        }
        let rest = Self.carrierRestHz + 0.22 * energy
        let turn = rest + (flowTurnHz() - rest) * flowTurn
        carrier = (carrier + h * tau * turn * speed).truncatingRemainder(dividingBy: tau)

        let targetWidth: Double
        switch stage {
        case .recording:
            targetWidth = Double(tuning.recordingWidth)
        case .preparing, .processing, .done:
            targetWidth = Double(tuning.processingWidth)
        case .notice, .failed:
            targetWidth = widthSpring.target
        }

        let coolTarget: Double = (stage == .processing || stage == .done || stage == .preparing) ? 1.0 : 0.0
        let failTarget: Double = (stage == .failed) ? 1.0 : 0.0
        let doneTarget: Double = (stage == .done) ? 1.0 : 0.0
        let noticeTarget: Double = (stage == .notice) ? 1.0 : 0.0
        let shownTarget: Double = visible ? 1.0 : 0.0

        let fadeSpec = HUDSpringSpec(duration: Double(tuning.transitionSec), bounce: 0.0)
        let morphSpec = HUDSpringSpec(duration: Double(tuning.transitionSec), bounce: Double(tuning.bounce))
        let hDouble = Double(h)

        if reduceMotion {
            widthSpring.jump(to: targetWidth)
            scaleSpring.jump(to: 1.0)
            softnessSpring.jump(to: 0.0)
            opacitySpring.stepTo(shownTarget, spec: .reducedFade, dt: hDouble)
            coolSpring.stepTo(coolTarget, spec: .reducedFade, dt: hDouble)
            failSpring.stepTo(failTarget, spec: .reducedFade, dt: hDouble)
            doneSpring.stepTo(doneTarget, spec: .reducedFade, dt: hDouble)
            noticeSpring.stepTo(noticeTarget, spec: .reducedFade, dt: hDouble)
        } else {
            widthSpring.stepTo(targetWidth, spec: morphSpec, dt: hDouble)
            opacitySpring.stepTo(shownTarget, spec: fadeSpec, dt: hDouble)
            scaleSpring.stepTo(visible ? 1.0 : Self.hiddenScale, spec: morphSpec, dt: hDouble)
            softnessSpring.stepTo(visible ? 0.0 : Self.hiddenSoftness, spec: fadeSpec, dt: hDouble)
            coolSpring.stepTo(coolTarget, spec: fadeSpec, dt: hDouble)
            failSpring.stepTo(failTarget, spec: fadeSpec, dt: hDouble)
            doneSpring.stepTo(doneTarget, spec: fadeSpec, dt: hDouble)
            noticeSpring.stepTo(noticeTarget, spec: fadeSpec, dt: hDouble)
        }

        elapsed += h
        time += h
        steps &+= 1
        if steps.isMultiple(of: 2) {
            renderBeam(dt: 2.0 * h)
        }
    }

    private func workPeriod() -> Float {
        2.0 * max(0.05, tuning.shimmerPassSec)
    }

    private func flowSpacing() -> Float {
        Self.flowSpacingRatio * tuning.processingWidth
    }

    private func flowSpeed() -> Float {
        flowSpacing() / workPeriod()
    }

    private func flowTurnHz() -> Float {
        flowSpeed() * tuning.helixCycles / max(1.0, Float(widthSpring.x))
    }

    private func pulseSpeed() -> Float {
        (tuning.processingWidth * 0.5 + 12.0) / (1.4 * workPeriod())
    }

    private func currentWorking(at t: Float) -> Working {
        switch tuning.processingStyle {
        case .pulse:
            return .pulse(time: t, period: workPeriod(), speed: pulseSpeed())
        case .sweep, .flow:
            return .flow(offset: flowOffset, spacing: flowSpacing())
        }
    }

    private func armDone() {
        speedAtDone = 1.5 * pulseSpeed()
        doneFrom = (stage == .processing || stage == .preparing) ? elapsed : 0.0
    }

    private func processHead(at e: Float) -> Float {
        let pass = max(0.05, tuning.shimmerPassSec)
        return (2.2 + abs(sin(Float.pi * (e / pass + 0.5))))
            * Self.smoothstep(0.0, 0.14, e)
            * tuning.shimmer
    }

    private func processFront(at e: Float, width: Float) -> Float {
        let pass = max(0.05, tuning.shimmerPassSec)
        let pos = 0.5 - 0.5 * cos(Float.pi * (e / pass + 0.5))
        return -width * 0.5 + Self.passInset + (width - 2.0 * Self.passInset) * pos
    }

    private func makeScan(width: Float) -> Scan {
        let e = elapsed
        if stage == .failed || stage == .notice {
            return Scan(
                helix: 1.0,
                decay: 1.0,
                tail: 1.0,
                grid: 1.0,
                envelope: .enter(reach: 1e4, head: 0.0, unfold: 1.0)
            )
        }
        if reduceMotion {
            return Scan(
                helix: 1.0,
                decay: 1.0,
                tail: 1.0,
                grid: 1.0,
                envelope: .enter(reach: 1e4, head: 0.0, unfold: 1.0)
            )
        }

        switch stage {
        case .recording:
            let p = Self.clamp(e / Self.enterDuration, 0.0, 1.0)
            let passPos = 0.5 - 0.5 * cos(Float.pi * p)
            return Scan(
                helix: 1.0,
                decay: 1.0,
                tail: 1.0,
                grid: min(1.0, e / 0.30),
                envelope: .enter(
                    reach: (width * 0.5 + 12.0) * passPos,
                    head: 2.8 * (1.0 - Self.smoothstep(0.08, Self.enterDuration, e)),
                    unfold: Self.smoothstep(0.0, 0.10, e)
                )
            )
        case .preparing, .processing:
            if tuning.processingStyle == .sweep {
                let iron = 1.0 - Self.smoothstep(0.0, 0.28, e)
                return Scan(
                    helix: iron,
                    decay: 1.0,
                    tail: 1.0,
                    grid: 1.0,
                    envelope: .process(iron: iron, front: processFront(at: e, width: width), head: processHead(at: e))
                )
            } else {
                let enter = Self.smoothstep(0.0, 0.35, e)
                return Scan(
                    helix: 1.0 + (Self.workHelixScale - 1.0) * enter,
                    decay: 1.0,
                    tail: 1.0,
                    grid: 1.0,
                    envelope: .work(
                        working: currentWorking(at: e),
                        head: 2.5 * Self.smoothstep(0.05, 0.30, e) * tuning.shimmer,
                        swell: 0.9 * enter,
                        halfWidth: width * 0.5
                    )
                )
            }
        case .done:
            let target = width * 0.5 + 8.0
            let front = Self.hermite(start: 0.0, speed: speedAtDone, end: target, t: e / Self.wipeDuration)
            let isSweep = tuning.processingStyle == .sweep
            return Scan(
                helix: isSweep ? 0.0 : Self.workHelixScale,
                decay: 1.0 - 0.6 * Self.smoothstep(0.0, 0.12, e),
                tail: 1.0 - Self.smoothstep(0.0, 0.15, e),
                grid: 1.0 - Self.smoothstep(0.06, Self.wipeDuration, e),
                envelope: .clear(
                    front: front,
                    head: 2.4 * (1.0 - Self.smoothstep(0.18, Self.wipeDuration, e)),
                    beam: isSweep ? processHead(at: doneFrom) * (1.0 - Self.smoothstep(0.0, 0.14, e)) : 0.0,
                    beamAt: processFront(at: doneFrom, width: width),
                    field: isSweep ? 0.0 : 1.0,
                    working: currentWorking(at: doneFrom + e),
                    glow: (isSweep ? 0.0 : 2.5) * tuning.shimmer * (1.0 - Self.smoothstep(0.0, 0.18, e)),
                    swell: 0.9,
                    halfWidth: width * 0.5
                )
            )
        case .notice, .failed:
            return Scan(
                helix: 1.0,
                decay: 1.0,
                tail: 1.0,
                grid: 1.0,
                envelope: .enter(reach: 1e4, head: 0.0, unfold: 1.0)
            )
        }
    }

    private func renderBeam(dt: Float) {
        let columns = tuning.columns
        let rows = tuning.rows
        let sub = Self.samplesPerColumn
        let samples = (columns - 1) * sub + 1
        let pitch = tuning.spacing
        let width = max(Float(widthSpring.x), tuning.height)
        let scan = makeScan(width: width)
        grid = scan.grid

        let mid = Float(rows - 1) * 0.5
        let half = max(0.5, mid - 0.55)
        let tau = Float.pi * 2.0
        let breath: Float = reduceMotion ? 0.5 : (0.5 + 0.5 * sin(time * tau / Self.breathPeriodSec))
        let rest = (0.55 + 0.35 * breath) * (0.4 + 0.6 * live) * scan.helix
        let halfWidth = width * 0.5

        for k in 0..<2 {
            let trace = traces[k]
            let sign: Float = k == 0 ? 1.0 : -1.0
            for s in 0..<samples {
                let x = (Float(s) / Float(sub) - Float(columns - 1) * 0.5) * pitch
                if abs(x) > halfWidth {
                    ysBuffer[k][s] = mid
                    brightnessBuffer[k][s] = 0.0
                    continue
                }

                let (amplitude, bright, swell) = scan.envelope.at(x)
                let own = abs(x)
                let xn = (x + halfWidth) / max(1.0, width)
                let ends = min(
                    Self.smoothstep(-halfWidth + 3.0, -halfWidth + 17.0, x),
                    Self.smoothstep(-halfWidth + 3.0, -halfWidth + 17.0, -x)
                )
                let reach = 1.0 - 0.8 * Self.smoothstep(14.0, halfWidth, own)
                let delay = own / tuning.historySpeed
                let a = trace.past(delay: delay, channel: 0)
                var spread: Float = 0.0
                for c in 0..<4 {
                    spread += trace.past(delay: delay, channel: 1 + c)
                        * sin(tau * Self.componentSpatial[c] * xn - trace.phases[c])
                }
                let helix = (rest + swell + half * 0.55 * a * reach)
                    * sin(tau * tuning.helixCycles * xn - carrier)
                let y = half * tanh((helix + half * 0.7 * spread * reach) / half) * ends * amplitude
                ysBuffer[k][s] = mid - sign * y
                let spatial = (0.3 + 0.7 * min(1.0, a * 1.8)) * (0.45 + 0.55 * ends)
                brightnessBuffer[k][s] = spatial * amplitude + 0.36 * max(0.0, bright - amplitude)
            }

            for s in 0..<samples {
                let nextIdx = min(samples - 1, s + 1)
                let prevIdx = max(0, s - 1)
                let slope = (ysBuffer[k][nextIdx] - ysBuffer[k][prevIdx]) * Float(sub) * 0.5
                brightnessBuffer[k][s] *= 0.45 + 0.55 / sqrt(1.0 + 0.22 * slope * slope)
            }
        }

        let headKeep = exp(-dt / (Self.phosphorHeadSec * scan.decay))
        let tailKeep = exp(-dt / (tuning.phosphorSec * scan.decay))
        let dx: Float = 1.0 / Float(sub)
        let invHalfWidth = 1.0 / max(1.0, halfWidth)

        for i in 0..<columns {
            let s0 = max(0, i - 3) * sub
            let s1 = min(samples - 1, (i + 3) * sub)
            let xPt = (Float(i) - Float(columns - 1) * 0.5) * pitch
            let normR = abs(xPt) * invHalfWidth

            // Akustik dalga halkası katkısı (geliştirilmiş fosfor efekt)
            let rippleBoost: Float
            if rippleIntensity > 0.005 {
                let dRing = abs(normR - ripplePhase)
                rippleBoost = rippleIntensity * 0.52 * exp(-(dRing * dRing) / 0.022)
            } else {
                rippleBoost = 0.0
            }

            for j in 0..<rows {
                let n = j * columns + i
                var nowSum: Float = 0.0
                var totalSum: Float = 0.0
                var lit0: Float = 0.0
                var lit1: Float = 0.0

                for k in 0..<2 {
                    var best = Float.greatestFiniteMagnitude
                    var nearest = i * sub
                    for s in s0..<s1 {
                        let ay = ysBuffer[k][s]
                        let dy = ysBuffer[k][s + 1] - ay
                        let px = Float(i) - Float(s) * dx
                        let py = Float(j) - ay
                        let t = Self.clamp((px * dx + py * dy) / (dx * dx + dy * dy), 0.0, 1.0)
                        let ex = px - t * dx
                        let ey = py - t * dy
                        let d2 = ex * ex + ey * ey
                        if d2 < best {
                            best = d2
                            nearest = s
                        }
                    }

                    let bright = brightnessBuffer[k][nearest]
                    let onBeam = exp(-best / 0.25)
                    let instant = min(1.2, onBeam + 0.5 * exp(-sqrt(best) / 0.8)) * bright
                    let core = onBeam * bright
                    headBuffer[k][n] = max(headBuffer[k][n] * headKeep, core)
                    tailBuffer[k][n] = max(tailBuffer[k][n] * tailKeep, core)
                    let light = max(instant, max(headBuffer[k][n], 0.55 * scan.tail * tailBuffer[k][n]))
                    if k == 0 { lit0 = light } else { lit1 = light }
                    nowSum += instant
                    totalSum += light
                }

                var power = 1.0 - (1.0 - min(1.0, lit0)) * (1.0 - min(1.0, lit1))
                if rippleBoost > 0.0 {
                    let rowFactor = 1.0 - 0.35 * abs(Float(j) - mid) / max(1.0, mid)
                    power = min(1.0, power + rippleBoost * rowFactor)
                }
                let fresh = min(1.0, (nowSum + rippleBoost * 0.6) / max(1e-4, totalSum + rippleBoost * 0.6))
                dots[n] = SIMD2<Float>(Self.clamp(power, 0.0, 1.0), fresh)
            }
        }
    }

    private static func computePalette(
        accent: DotScopeAccentMode,
        cool: Float,
        fail: Float,
        done: Float,
        notice: Float,
        harmonicHeat: Float,
        saturation: Float
    ) -> DotScopePalette {
        let recBase: SIMD3<Float>
        let recCore: SIMD3<Float>
        let procBase: SIMD3<Float>
        let procCore: SIMD3<Float>

        switch accent {
        case .normal:
            // Sıcak şampanya-altın -> vokal zirvelerde kehribar ısısı
            recBase = mix3(SIMD3<Float>(0.88, 0.84, 0.77), SIMD3<Float>(0.98, 0.78, 0.48), harmonicHeat * 0.55)
            recCore = mix3(SIMD3<Float>(0.99, 0.97, 0.92), SIMD3<Float>(1.00, 0.92, 0.76), harmonicHeat * 0.45)
            // İşlenirken zarif safir mavi
            procBase = SIMD3<Float>(0.68, 0.79, 0.94)
            procCore = SIMD3<Float>(0.92, 0.96, 1.00)
        case .translation:
            // Çeviri modu: canlı zümrüt-turkuaz -> elektrik camgöbeği
            recBase = mix3(SIMD3<Float>(0.36, 0.86, 0.78), SIMD3<Float>(0.55, 0.95, 0.84), harmonicHeat * 0.5)
            recCore = SIMD3<Float>(0.86, 1.00, 0.96)
            procBase = SIMD3<Float>(0.56, 0.76, 0.98)
            procCore = SIMD3<Float>(0.90, 0.96, 1.00)
        }

        let successBase = SIMD3<Float>(0.30, 0.88, 0.52)
        let successCore = SIMD3<Float>(0.84, 1.00, 0.90)
        let noticeBase = SIMD3<Float>(0.98, 0.76, 0.28)
        let noticeCore = SIMD3<Float>(1.00, 0.93, 0.74)
        let coralBase = SIMD3<Float>(1.00, 0.38, 0.31)
        let coralCore = SIMD3<Float>(1.00, 0.68, 0.62)

        var base = mix3(recBase, procBase, cool)
        var core = mix3(recCore, procCore, cool)
        base = mix3(base, successBase, done * 0.78)
        core = mix3(core, successCore, done * 0.78)
        base = mix3(base, noticeBase, notice)
        core = mix3(core, noticeCore, notice)
        base = mix3(base, coralBase, fail)
        core = mix3(core, coralCore, fail)

        return DotScopePalette(
            base: saturate(base, amount: saturation),
            core: saturate(core, amount: saturation),
            plate: SIMD4<Float>(17.0 / 255.0, 17.0 / 255.0, 20.0 / 255.0, 0.94),
            rim: SIMD4<Float>(1.0, 1.0, 1.0, 0.13),
            shadow: SIMD4<Float>(0.0, 0.0, 0.0, 0.45)
        )
    }

    private static func mix3(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ t: Float) -> SIMD3<Float> {
        a + (b - a) * clamp(t, 0.0, 1.0)
    }

    private static func saturate(_ color: SIMD3<Float>, amount: Float) -> SIMD3<Float> {
        let luma = 0.2126 * color.x + 0.7152 * color.y + 0.0722 * color.z
        return simd_clamp(SIMD3<Float>(repeating: luma) + (color - SIMD3<Float>(repeating: luma)) * amount,
                          SIMD3<Float>(repeating: 0.0),
                          SIMD3<Float>(repeating: 1.0))
    }

    private static func smoothstep(_ a: Float, _ b: Float, _ x: Float) -> Float {
        let t = clamp((x - a) / max(1e-5, b - a), 0.0, 1.0)
        return t * t * (3.0 - 2.0 * t)
    }

    private static func bump(_ d: Float, width w: Float) -> Float {
        let r = d / max(1e-4, w)
        return exp(-(r * r))
    }

    private static func hermite(start: Float, speed: Float, end: Float, t: Float) -> Float {
        let c = clamp(t, 0.0, 1.0)
        let t2 = c * c
        let t3 = t2 * c
        return (2.0 * t3 - 3.0 * t2 + 1.0) * start
            + (t3 - 2.0 * t2 + c) * Self.wipeDuration * speed
            + (3.0 * t2 - 2.0 * t3) * end
    }

    private static func clamp(_ v: Float, _ lo: Float, _ hi: Float) -> Float {
        min(hi, max(lo, v))
    }
}
