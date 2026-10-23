import Foundation

/// The app's clock, rebuilt when the cadence changes.
///
/// A closed panel does not need a tick every second. The timer is rebuilt rather
/// than gated, because the wakeup itself is the cost: a timer that fires and does
/// nothing still keeps the CPU from resting.
@MainActor
final class TickClock {
    private var timer: Timer?
    private var interval: TimeInterval = 0
    private let fire: () -> Void

    init(fire: @escaping () -> Void) {
        self.fire = fire
    }

    /// How often to tick, from what is on screen.
    ///
    /// A screen that cannot show anything needs only a slow liveness pass, even with
    /// the panel open behind a lock. The ages are read once a second while they are
    /// visible. A closed panel needs the icon step at its own interval, and with
    /// nothing working, little is left to refresh.
    nonisolated static func cadence(panelOpen: Bool, screenAwake: Bool,
                                    busy: Bool) -> TimeInterval {
        if !screenAwake { return 5 }
        if panelOpen { return 1 }
        return busy ? TimeInterval(StatusIcon.Stepper.secondsPerStep) : 5
    }

    /// Run the block on an interval, rebuilding only when the interval changes.
    func schedule(every seconds: TimeInterval) {
        guard seconds != interval else { return }
        interval = seconds
        timer?.invalidate()
        let timer = Timer(timeInterval: seconds, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.fire() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        Log.write("clock: \(Int(seconds))s")
    }
}
