import AppKit
import QuartzCore

/// Çentik adasındaki canlı ses dalgası (Siri / Sesli Notlar hissi).
///
/// Çubuklar yerine iki katmanlı, uçları incelen tek bir çizgi: önde parlak ana
/// dalga, arkada ters fazlı soluk bir yankı. Genlik mikrofon seviyesini anında
/// izler; sessizlikte ince bir kıpırtıya iner. Yazılırken sabit genlikli, yavaş
/// akan bir dalgaya döner. Tüm geometri `wavePath` ile saf ve test edilebilirdir.
final class NotchWaveView: NSView {
    enum Mode { case listening, processing }

    static let size = CGSize(width: 36, height: 20)

    private let primary = CAShapeLayer()
    private let echo = CAShapeLayer()
    private var phase: CGFloat = 0
    private var lastTick: TimeInterval?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = false
        for (shape, alpha, width) in [(echo, 0.32, 1.2), (primary, 0.95, 1.7)] {
            shape.fillColor = nil
            shape.strokeColor = NSColor(calibratedWhite: 1, alpha: alpha).cgColor
            shape.lineWidth = width
            shape.lineCap = .round
            shape.lineJoin = .round
            shape.actions = ["path": NSNull(), "strokeColor": NSNull()]
            layer?.addSublayer(shape)
        }
        primary.shadowColor = NSColor.white.cgColor
        primary.shadowOpacity = 0.35
        primary.shadowRadius = 2.5
        primary.shadowOffset = .zero
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) kullanılmaz") }

    func reset() {
        phase = 0
        lastTick = nil
    }

    /// - Parameters:
    ///   - level: 0...1 yumuşatılmış mikrofon seviyesi (dinlerken).
    ///   - animated: Hareketi azalt açıksa `false`; dalga durağan çizilir.
    func render(level: CGFloat, mode: Mode, animated: Bool) {
        let now = ProcessInfo.processInfo.systemUptime
        let dt = lastTick.map { CGFloat(min(0.1, now - $0)) } ?? 0
        lastTick = now

        let amplitude: CGFloat
        let speed: CGFloat
        switch mode {
        case .listening:
            // Sessizlikte ince kıpırtı, konuşunca yüksekliğin neredeyse tamamı.
            amplitude = 0.6 + 8.4 * min(1, max(0, level)).squareRoot()
            speed = 7 + 10 * level
        case .processing:
            amplitude = 3.2
            speed = 5
        }
        if animated { phase += speed * dt }

        let bounds = CGRect(origin: .zero, size: Self.size)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        primary.frame = bounds
        echo.frame = bounds
        primary.path = Self.wavePath(size: Self.size, amplitude: amplitude, phase: phase)
        echo.path = Self.wavePath(size: Self.size, amplitude: amplitude * 0.6, phase: -phase * 0.8 + 1.7)
        CATransaction.commit()
    }

    /// Uçları sıfıra inen (çentik kenarına yapışmayan) iki frekanslı dalga.
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
