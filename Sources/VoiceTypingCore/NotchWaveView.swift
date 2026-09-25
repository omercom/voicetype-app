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
    /// Ana dalgayı renklendiren geçiş (dalga şekli maske olarak kullanılır).
    private let primaryColor = CAGradientLayer()
    /// Dalganın arkasında sesle nefes alan yumuşak ışık.
    private let glow = CAGradientLayer()
    private var glowOpacity: CGFloat = 0

    /// Çentiğin siyahıyla bütünleşen tek renkli palet: uçlarda gümüş, ortada
    /// beyaz. Renkli (pembe/mor) tonlar siyah adada yabancı duruyordu.
    static let palette: [NSColor] = [
        NSColor(calibratedWhite: 0.62, alpha: 1),
        NSColor(calibratedWhite: 1.00, alpha: 1),
        NSColor(calibratedWhite: 0.62, alpha: 1),
    ]
    private var phase: CGFloat = 0
    private var lastTick: TimeInterval?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = false

        // Işık dalgadan büyüktür ve metnin altına doğru taşar; kenarları saydamdır.
        glow.type = .radial
        glow.startPoint = CGPoint(x: 0.5, y: 0.5)
        glow.endPoint = CGPoint(x: 1, y: 1)
        glow.colors = [
            NSColor(calibratedWhite: 1, alpha: 0.16).cgColor,
            NSColor(calibratedWhite: 1, alpha: 0.05).cgColor,
            NSColor.clear.cgColor,
        ]
        glow.locations = [0, 0.45, 1]
        glow.frame = CGRect(x: -22, y: -12, width: Self.size.width + 44, height: Self.size.height + 24)
        glow.opacity = 0
        glow.actions = ["opacity": NSNull(), "frame": NSNull()]
        layer?.addSublayer(glow)

        for (shape, alpha, width) in [(echo, 0.32, 1.2), (primary, 1.0, 1.8)] {
            shape.fillColor = nil
            shape.strokeColor = NSColor(calibratedWhite: 1, alpha: alpha).cgColor
            shape.lineWidth = width
            shape.lineCap = .round
            shape.lineJoin = .round
            shape.actions = ["path": NSNull(), "strokeColor": NSNull()]
            if shape !== primary { layer?.addSublayer(shape) }
        }
        // Ana dalga: renk geçişi, dalga çizgisiyle maskelenir.
        primaryColor.startPoint = CGPoint(x: 0, y: 0.5)
        primaryColor.endPoint = CGPoint(x: 1, y: 0.5)
        primaryColor.colors = Self.palette.map(\.cgColor)
        primaryColor.frame = CGRect(origin: .zero, size: Self.size)
        primaryColor.mask = primary
        primaryColor.shadowColor = NSColor.white.cgColor
        primaryColor.shadowOpacity = 0.6
        primaryColor.shadowRadius = 3
        primaryColor.shadowOffset = .zero
        primaryColor.actions = ["colors": NSNull(), "shadowOpacity": NSNull()]
        layer?.addSublayer(primaryColor)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) kullanılmaz") }

    func reset() {
        phase = 0
        lastTick = nil
        glowOpacity = 0
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

        // Işık: sessizlikte görünmez, sesle hızla açılır, yavaşça söner.
        // Yazılırken hafifçe nefes alır.
        let targetGlow: CGFloat
        switch mode {
        case .listening:
            targetGlow = min(1, pow(max(0, level), 0.7) * 1.3)
        case .processing:
            targetGlow = animated ? 0.35 + 0.2 * sin(phase * 0.5) : 0.35
        }
        let tau: CGFloat = targetGlow > glowOpacity ? 0.05 : 0.35
        glowOpacity += (targetGlow - glowOpacity) * (dt > 0 ? min(1, 1 - exp(-dt / tau)) : 1)

        let bounds = CGRect(origin: .zero, size: Self.size)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        glow.opacity = Float(glowOpacity)
        primaryColor.shadowOpacity = Float(0.35 + 0.5 * glowOpacity)
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
