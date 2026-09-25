import Foundation

/// A single-owner transition: replacing it discards the old completion and starts
/// from the caller's currently displayed values, never an obsolete target.
final class HUDTransition {
    private var timer: Timer?
    private var startedAt: TimeInterval = 0
    private var duration: TimeInterval = 0
    private var update: ((Double) -> Void)?
    private var completion: (() -> Void)?
    private var generation: UInt = 0
    private let clock: () -> TimeInterval
    private let schedulesTimer: Bool

    var isActive: Bool { update != nil }

    init(schedulesTimer: Bool = true, clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.schedulesTimer = schedulesTimer
        self.clock = clock
    }

    func start(duration: TimeInterval, update: @escaping (Double) -> Void, completion: (() -> Void)? = nil) {
        cancel()
        self.startedAt = clock()
        self.duration = duration
        self.update = update
        self.completion = completion
        guard duration > 0 else { finish(); return }
        update(0)
        guard schedulesTimer else { return }
        let token = generation
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            guard let self, self.generation == token else { return }
            self.advance()
        }
        timer.tolerance = 0.002
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func advance() {
        guard let update else { return }
        let progress = min(1, max(0, (clock() - startedAt) / duration))
        if progress >= 1 { finish(); return }
        update(progress * progress * (3 - 2 * progress))
    }

    func finish() {
        let update = self.update
        let completion = self.completion
        cancel()
        update?(1)
        completion?()
    }

    func cancel() {
        generation &+= 1
        timer?.invalidate()
        timer = nil
        update = nil
        completion = nil
    }

    deinit { timer?.invalidate() }
}
