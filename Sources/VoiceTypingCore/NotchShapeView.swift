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

    /// Hata ayıklama için ince çerçeve çizer mi?
    var showsOutline: Bool = false {
        didSet { needsDisplay = true }
    }

    override var isFlipped: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        let path = Self.makePath(in: bounds)
        fillColor.setFill()
        path.fill()

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
