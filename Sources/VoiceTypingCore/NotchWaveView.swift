import AppKit
import QuartzCore
import simd

/// Çentik adasındaki canlı ses dalgası — Hex Dot Scope phosphor nokta matrisi.
///
/// İki fazlı örgülü osiloskop izi mikrofon seviyesini 240 Hz simülasyonla izler;
/// sessizlikte orta hatta zarif bir fosfor çizgisi gösterir, konuşmada sıcak
/// altın-inci izler üretir, yazılırken ise safir mavi akışa döner.
final class NotchWaveView: NSView {
    enum Mode { case preparing, listening, processing }

    static let size = CGSize(width: 50, height: 20)

    /// Çentiğin siyahıyla bütünleşen tek renkli palet (uyumluluk için korunur).
    static let palette: [NSColor] = [
        NSColor(calibratedWhite: 0.62, alpha: 1),
        NSColor(calibratedWhite: 1.00, alpha: 1),
        NSColor(calibratedWhite: 0.62, alpha: 1),
    ]

    private let simulation = DotScopeSimulation(tuning: .notchSlot)
    private var lastTick: TimeInterval?
    private var currentMode: Mode = .listening
    private var currentLevel: CGFloat = 0

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = false
        reset()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) kullanılmaz") }

    override var isOpaque: Bool { false }

    func configure(processingStyle: DotScopeProcessingStyle, accentMode: DotScopeAccentMode) {
        var tuning = simulation.tuning
        tuning.processingStyle = processingStyle
        simulation.updateTuning(tuning)
        simulation.accentMode = accentMode
        needsDisplay = true
    }

    func reset() {
        lastTick = nil
        currentMode = .listening
        currentLevel = 0
        simulation.restart(reduceMotion: true)
        simulation.advance(dt: 0.05, stage: .recording, visible: true, loudnessDB: -120.0, reduceMotion: true)
        lastTick = nil
        needsDisplay = true
    }

    /// - Parameters:
    ///   - level: 0...1 yumuşatılmış mikrofon seviyesi (dinlerken).
    ///   - animated: Hareketi azalt açıksa `false`.
    func render(level: CGFloat, mode: Mode, animated: Bool) {
        let now = ProcessInfo.processInfo.systemUptime
        let dt: Float
        if let prev = lastTick {
            dt = Float(min(0.1, max(1.0 / 120.0, now - prev)))
        } else {
            dt = animated ? (1.0 / 60.0) : 0.22
        }
        lastTick = now
        currentMode = mode
        currentLevel = max(0, min(1, level))

        let stage: DotScopeStage
        switch mode {
        case .preparing:
            stage = .preparing
        case .listening:
            stage = .recording
        case .processing:
            stage = .processing
        }
        // 0...1 seviyesini DotScope'un beklediği dBFS aralığına (-90...-16 dB) eşle.
        let loudnessDB: Float = (mode == .listening && currentLevel > 0.01)
            ? (-58.0 + Float(currentLevel) * 42.0)
            : -120.0

        if !animated && mode == .listening && currentLevel > 0.05 {
            // Anlık durağan örneklemeler için simülasyonu deterministik adımlarla ilerlet.
            for _ in 0..<8 {
                simulation.advance(dt: 0.025, stage: stage, visible: true, loudnessDB: loudnessDB, reduceMotion: false)
            }
        } else {
            simulation.advance(dt: dt, stage: stage, visible: true, loudnessDB: loudnessDB, reduceMotion: !animated)
        }
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard bounds.width > 0, bounds.height > 0, let ctx = NSGraphicsContext.current?.cgContext else { return }
        let pose = simulation.pose()
        let tuning = simulation.tuning
        let columns = tuning.columns
        let rows = tuning.rows
        let pitch = CGFloat(tuning.spacing)
        let dots = simulation.dots
        let offsetX = CGFloat(columns - 1) * 0.5
        let offsetY = CGFloat(rows - 1) * 0.5
        let centerRow = rows / 2

        ctx.saveGState()
        for j in 0..<rows {
            for i in 0..<columns {
                let idx = j * columns + i
                guard idx < dots.count else { continue }
                let val = dots[idx]
                let power = max(val.x, 1e-5)
                let fresh = val.y
                let cx = bounds.midX + (CGFloat(i) - offsetX) * pitch
                let cy = bounds.midY - (CGFloat(j) - offsetY) * pitch
                guard bounds.insetBy(dx: 0.5, dy: 0.5).contains(CGPoint(x: cx, y: cy)) else { continue }

                // Çentik içinde saf siyah zemin üzerinde keskin Hex fosfor noktaları:
                // sessiz durumda zarif inci çizgisi; konuşmada sıcak altın/mavi iz.
                let isCenter = (j == centerRow)
                let floorAlpha: Float = isCenter ? 0.58 : 0.04
                let alpha = min(1.0, floorAlpha + (1.0 - floorAlpha) * pow(power, 0.70))
                let dotRadius = CGFloat(0.23 + 0.23 * pow(power, 0.56)) * pitch
                let baseColor = mixColor(pose.palette.base, SIMD3<Float>(0.97, 0.96, 0.95), t: 0.30)
                let rgb = mixColor(baseColor, pose.palette.core, t: min(1.0, power * 0.82 + fresh * 0.18))

                if power > 0.06 {
                    let haloR = dotRadius * 1.9
                    ctx.setFillColor(NSColor(
                        calibratedRed: CGFloat(rgb.x),
                        green: CGFloat(rgb.y),
                        blue: CGFloat(rgb.z),
                        alpha: CGFloat(0.24 * power * power)
                    ).cgColor)
                    ctx.fillEllipse(in: CGRect(x: cx - haloR, y: cy - haloR, width: haloR * 2, height: haloR * 2))
                }

                ctx.setFillColor(NSColor(
                    calibratedRed: CGFloat(rgb.x),
                    green: CGFloat(rgb.y),
                    blue: CGFloat(rgb.z),
                    alpha: CGFloat(alpha)
                ).cgColor)
                ctx.fillEllipse(in: CGRect(x: cx - dotRadius, y: cy - dotRadius, width: dotRadius * 2, height: dotRadius * 2))
            }
        }
        ctx.restoreGState()
    }

    private func mixColor(_ a: SIMD3<Float>, _ b: SIMD3<Float>, t: Float) -> SIMD3<Float> {
        let clamped = min(1.0, max(0.0, t))
        return a + (b - a) * clamped
    }

    /// Uçları sıfıra inen (çentik kenarına yapışmayan) iki frekanslı dalga (test ve geometri uyumu için).
    static func wavePath(size: CGSize, amplitude: CGFloat, phase: CGFloat, step: CGFloat = 0.75) -> CGPath {
        let path = CGMutablePath()
        let midY = size.height / 2
        let maxAmplitude = min(amplitude, midY - 1)
        var x: CGFloat = 0
        var first = true
        while x <= size.width + 0.001 {
            let t = x / size.width
            let envelope = pow(sin(.pi * t), 1.6)
            let wave = 0.65 * sin(t * 2 * .pi * 1.6 + phase) + 0.35 * sin(t * 2 * .pi * 3.1 - phase * 1.3)
            let point = CGPoint(x: x, y: midY + maxAmplitude * envelope * wave)
            if first { path.move(to: point); first = false } else { path.addLine(to: point) }
            x += step
        }
        return path
    }
}
