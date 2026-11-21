import Foundation

/// Duration + bounce spring specification matching SwiftUI / Hex (`ω = 2π / duration`, `ζ = 1 − bounce`).
public struct HUDSpringSpec: Equatable, Sendable {
    public let duration: Double
    public let bounce: Double

    public init(duration: Double, bounce: Double) {
        self.duration = duration
        self.bounce = bounce
    }

    public var omega: Double {
        (2.0 * Double.pi) / max(duration, 0.01)
    }

    public var zeta: Double {
        if bounce >= 0.0 {
            return max(0.0, 1.0 - bounce)
        } else {
            return 1.0 / max(0.01, 1.0 + bounce)
        }
    }

    public static let morph = HUDSpringSpec(duration: 0.30, bounce: 0.15)
    public static let fade = HUDSpringSpec(duration: 0.30, bounce: 0.0)
    public static let reducedFade = HUDSpringSpec(duration: 0.16, bounce: 0.0)
}

/// Frame-rate independent analytical damped harmonic oscillator state.
public struct HUDSpring: Equatable, Sendable {
    private static let criticalDampingTolerance: Double = 1e-4

    public var x: Double
    public var v: Double
    public var target: Double

    public init(at value: Double) {
        self.x = value
        self.v = 0.0
        self.target = value
    }

    public mutating func jump(to value: Double) {
        x = value
        v = 0.0
        target = value
    }

    public mutating func stepTo(_ newTarget: Double, spec: HUDSpringSpec, dt: Double) {
        target = newTarget
        step(spec: spec, dt: dt)
    }

    public mutating func step(spec: HUDSpringSpec, dt: Double) {
        guard dt > 0.0, dt.isFinite else { return }
        let omega = spec.omega
        let zeta = spec.zeta
        let x0 = x - target
        let v0 = v

        if zeta < 1.0 - Self.criticalDampingTolerance {
            let decay = zeta * omega
            let omegaD = omega * sqrt(1.0 - zeta * zeta)
            let expTerm = exp(-decay * dt)
            let sinTerm = sin(omegaD * dt)
            let cosTerm = cos(omegaD * dt)
            let sinOverD = sinTerm / omegaD
            x = target + expTerm * (x0 * (cosTerm + decay * sinOverD) + v0 * sinOverD)
            v = expTerm * (-x0 * omega * omega * sinOverD + v0 * (cosTerm - decay * sinOverD))
        } else if zeta > 1.0 + Self.criticalDampingTolerance {
            let root = sqrt(zeta * zeta - 1.0)
            let rootSum = zeta + root
            let slowRoot = -omega / rootSum
            let fastRoot = -omega * rootSum
            let denom = slowRoot - fastRoot
            let slowExp = exp(slowRoot * dt)
            let fastExp = exp(fastRoot * dt)
            let p00 = (-fastRoot * slowExp + slowRoot * fastExp) / denom
            let p01 = (slowExp - fastExp) / denom
            let p10 = slowRoot * fastRoot * (fastExp - slowExp) / denom
            let p11 = (slowRoot * slowExp - fastRoot * fastExp) / denom
            x = target + p00 * x0 + p01 * v0
            v = p10 * x0 + p11 * v0
        } else {
            let expTerm = exp(-omega * dt)
            let c = v0 + omega * x0
            x = target + (x0 + c * dt) * expTerm
            v = (v0 - omega * c * dt) * expTerm
        }
    }
}
