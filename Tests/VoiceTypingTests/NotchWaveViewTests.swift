import XCTest
@testable import VoiceTypingCore

final class NotchWaveViewTests: XCTestCase {
    private func points(_ path: CGPath) -> [CGPoint] {
        var result: [CGPoint] = []
        path.applyWithBlock { element in
            let e = element.pointee
            if e.type == .moveToPoint || e.type == .addLineToPoint { result.append(e.points[0]) }
        }
        return result
    }

    func testEndsAreTaperedToMidline() {
        let size = NotchWaveView.size
        let pts = points(NotchWaveView.wavePath(size: size, amplitude: 9, phase: 1.234))
        XCTAssertEqual(pts.first!.y, size.height / 2, accuracy: 0.01)
        XCTAssertEqual(pts.last!.y, size.height / 2, accuracy: 0.3)
    }

    func testWaveStaysInsideBoundsEvenWithHugeAmplitude() {
        let size = NotchWaveView.size
        for phase in stride(from: 0.0, to: 6.3, by: 0.7) {
            for p in points(NotchWaveView.wavePath(size: size, amplitude: 500, phase: CGFloat(phase))) {
                XCTAssertGreaterThanOrEqual(p.y, 0)
                XCTAssertLessThanOrEqual(p.y, size.height)
            }
        }
    }

    func testLouderMeansTallerWave() {
        let size = NotchWaveView.size
        func height(_ a: CGFloat) -> CGFloat {
            let ys = points(NotchWaveView.wavePath(size: size, amplitude: a, phase: 0.8)).map(\.y)
            return ys.max()! - ys.min()!
        }
        XCTAssertGreaterThan(height(8), height(1) * 3)
    }
}
