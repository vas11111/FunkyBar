import Foundation

/// One timer for every interval provider on the bar.
///
/// This is the single most important piece of the efficiency budget. Upstream
/// gives each item its own `update_freq` and additionally runs a 1 Hz clock in
/// the bar manager, so a typical config wakes the CPU roughly 25 times a minute
/// at unpredictable moments. On Apple Silicon that defeats timer coalescing and
/// keeps the SoC out of its deep idle states.
///
/// Here every provider registers on one `DispatchSourceTimer` that:
///
/// - ticks at the greatest common divisor of the registered intervals, so a
///   5s and a 60s provider share one timer rather than owning two
/// - carries generous leeway, letting the kernel slide the wakeup to coincide
///   with work that was going to happen anyway
/// - aligns to the wall-clock second, so a clock showing HH:mm updates on the
///   minute rather than drifting across it
/// - suspends entirely when the screens sleep
@MainActor
public final class TimerWheel {

    private struct Entry {
        let id: String
        let interval: Double
        var nextDue: Double
        let fire: @MainActor () -> Void
    }

    /// Fraction of the tick interval allowed as slack. 20% of a 5s tick is a
    /// full second of coalescing room, which is invisible on a status bar.
    private nonisolated static let leewayFraction = 0.2
    /// Never tick faster than this, whatever a config asks for.
    private nonisolated static let minimumTick: Double = 1.0

    private var entries: [Entry] = []
    private var timer: DispatchSourceTimer?
    private var tickInterval: Double = 0
    private(set) public var isSuspended = false

    private let now: @MainActor () -> Double
    private var lastTick: Double?

    public init(now: @escaping @MainActor () -> Double = { Date().timeIntervalSince1970 }) {
        self.now = now
    }

    public var registeredCount: Int { entries.count }
    public var currentTickInterval: Double { tickInterval }

    public func register(id: String, interval: Double, fire: @escaping @MainActor () -> Void) {
        let clamped = Self.normalized(interval)
        entries.removeAll { $0.id == id }
        entries.append(Entry(id: id, interval: clamped,
                             nextDue: Self.nextBoundary(after: now(), interval: clamped), fire: fire))
        rebuild()
    }

    public func unregister(id: String) {
        entries.removeAll { $0.id == id }
        rebuild()
    }

    public func removeAll() {
        entries.removeAll()
        rebuild()
    }

    // MARK: - Suspension

    /// Called on display or system sleep. Nothing polls while nothing is visible.
    public func suspend() {
        guard !isSuspended else { return }
        isSuspended = true
        timer?.cancel()
        timer = nil
    }

    /// Called on wake. Everything is due immediately, so the bar is correct
    /// the moment the screen lights up rather than up to one interval later.
    public func resume() {
        guard isSuspended else { return }
        isSuspended = false
        let current = now()
        for index in entries.indices { entries[index].nextDue = current }
        tick()
        rebuild()
    }

    // MARK: - Timer

    private func rebuild() {
        timer?.cancel()
        timer = nil

        guard !entries.isEmpty, !isSuspended else {
            tickInterval = 0
            return
        }

        tickInterval = Self.tickInterval(for: entries.map(\.interval))

        let source = DispatchSource.makeTimerSource(queue: .main)
        let delay = Self.nextBoundary(after: now(), interval: tickInterval) - now()
        source.schedule(
            wallDeadline: .now() + max(0, delay),
            repeating: tickInterval,
            leeway: .milliseconds(Int(tickInterval * Self.leewayFraction * 1000))
        )
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.tick() }
        }
        source.resume()
        timer = source
    }

    /// The coarsest tick that can still serve every registered interval.
    public nonisolated static func tickInterval(for intervals: [Double]) -> Double {
        guard !intervals.isEmpty else { return minimumTick }
        // Work in whole seconds; sub-second polling has no place on a bar.
        let seconds = intervals.map { Int(normalized($0)) }
        let divisor = seconds.reduce(seconds[0]) { gcd($0, $1) }
        return max(minimumTick, Double(divisor))
    }

    private nonisolated static func normalized(_ interval: Double) -> Double {
        // Keep conversions to Int and Dispatch's nanoseconds representable,
        // including when a provider is constructed directly rather than from
        // a validated config.
        guard interval.isFinite else { return minimumTick }
        return min(Double(Int32.max), max(minimumTick, interval.rounded(.up)))
    }

    private nonisolated static func nextBoundary(after time: Double, interval: Double) -> Double {
        (floor(time / interval) + 1) * interval
    }

    private nonisolated static func gcd(_ a: Int, _ b: Int) -> Int {
        var a = abs(a), b = abs(b)
        while b != 0 { (a, b) = (b, a % b) }
        return a
    }

    private func tick() {
        let current = now()
        let clockMovedBack = lastTick.map { current < $0 } ?? false
        lastTick = current
        var callbacks: [@MainActor () -> Void] = []
        for index in entries.indices where clockMovedBack || entries[index].nextDue <= current + 0.001 {
            entries[index].nextDue = Self.nextBoundary(after: current, interval: entries[index].interval)
            callbacks.append(entries[index].fire)
        }
        // Callbacks may register or remove entries; finish walking the array
        // before invoking any of them.
        for callback in callbacks { callback() }
    }

    /// Drives one tick synchronously. Tests only.
    public func tickNow() {
        tick()
    }
}
