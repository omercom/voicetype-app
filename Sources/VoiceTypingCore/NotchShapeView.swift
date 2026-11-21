import AppKit

/// Çentik adasının arka planını gerçek çentik formunda çizen görünüm.
///
/// Form `NotchShapePath`'ten gelir: üst köşeler konkav ("kulak"), alt köşeler
/// **squircle** (sürekli eğrilikli) oval. Squircle, düz kenar ile kavis
/// arasında eğriliği kademeli değiştirdiği için "yumuşak" görünür; basit
/// `cornerRadius` ise eğrilik sıçraması yapar ve sert durur.
///
/// `NSView.draw(_:)` içinde `NSBezierPath` ile çizilir; katman tabanlı
/// `cornerRadius` ne konkav kulağı ne de squircle eğrisini ifade edebilir.
final class NotchShapeView: NSView {

    /// Arka plan rengi (tam opak siyah).
    var fillColor: NSColor = NSColor(calibratedWhite: 0.0, alpha: 1.0) {
        didSet { needsDisplay = true }
    }

    /// Ada alt kenarı için ince reaktif vurgu ışığı (varsayılan 0 = saf siyah).
    var rimGlowColor: NSColor = NSColor(calibratedRed: 0.96, green: 0.86, blue: 0.65, alpha: 1.0) {
        didSet { needsDisplay = true }
    }
    var rimGlowIntensity: CGFloat = 0.0 {
        didSet {
            if abs(oldValue - rimGlowIntensity) > 0.005 {
                needsDisplay = true
            }
        }
    }

    /// Hata ayıklama için ince çerçeve çizer mi?
    var showsOutline: Bool = false {
        didSet { needsDisplay = true }
    }

    override var isFlipped: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        let path = Self.makePath(in: bounds)
        fillColor.setFill()
        path.fill()

        let clampedGlow = min(1.0, max(0.0, rimGlowIntensity))
        if clampedGlow > 0.01 && fillColor.alphaComponent > 0.1 {
            NSGraphicsContext.saveGraphicsState()
            path.addClip()

            // Alt kenara doğru yumuşak ortam ışığı: üst kulaklara ve ekran üst çerçevesine sızmaz.
            let bottomGlowHeight = min(bounds.height * 0.42, 16.0)
            if bottomGlowHeight > 2.0,
               let gradient = NSGradient(colors: [
                   rimGlowColor.withAlphaComponent(0.11 * clampedGlow),
                   rimGlowColor.withAlphaComponent(0.0)
               ]) {
                gradient.draw(
                    in: NSRect(x: 0, y: 0, width: bounds.width, height: bottomGlowHeight),
                    angle: 90
                )
            }

            // İnce kenar ışığı yalnızca üst kulakların altındaki gövde ve alt ovallerde çizilir.
            let clipTop = max(0, bounds.height - NotchShapePath.topCornerRadius - 4.0)
            if clipTop > 2.0 {
                NSBezierPath(rect: NSRect(x: 0, y: 0, width: bounds.width, height: clipTop)).addClip()
                rimGlowColor.withAlphaComponent(0.24 * clampedGlow).setStroke()
                path.lineWidth = 1.0
                path.stroke()
            }
            NSGraphicsContext.restoreGraphicsState()
        }

        if showsOutline {
            NSColor.systemRed.setStroke()
            path.lineWidth = 1
            path.stroke()
        }
    }

    /// Formu `NSBezierPath`'e dönüştürür (çizimden bağımsız, test edilebilir).
    static func makePath(in bounds: NSRect) -> NSBezierPath {
        let path = NSBezierPath()
        for segment in NotchShapePath.segments(in: bounds) {
            switch segment {
            case let .move(p):
                path.move(to: p)
            case let .line(p):
                path.line(to: p)
            case let .quad(end, control):
                path.curve(to: end, controlPoint1: control, controlPoint2: control)
            case let .cubic(end, c1, c2):
                path.curve(to: end, controlPoint1: c1, controlPoint2: c2)
            }
        }
        path.close()
        return path
    }
}
