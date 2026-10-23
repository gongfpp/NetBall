import Foundation

/// Heavy connection scans have a CPU budget, independent of cheap interface refreshes.
/// This limits actual work, not the displayed CPU percentage or its core normalization.
struct SamplingBudget {
    static let minimumInterval: TimeInterval = 2
    static let maximumInterval: TimeInterval = 30
    static let cpuFraction = 0.05

    private(set) var interval = minimumInterval
    private(set) var next = Date.distantPast

    func isDue(at now: Date) -> Bool { now >= next }

    mutating func completed(cpuSeconds: Double, started: Date, finished: Date) {
        let cost = cpuSeconds.isFinite ? max(0, cpuSeconds) : 0
        let wanted = min(Self.maximumInterval, max(Self.minimumInterval, ceil(cost / Self.cpuFraction)))
        // React immediately to increased work; reduce the interval slowly to avoid oscillation.
        interval = wanted >= interval ? wanted : max(wanted, interval * 0.8)
        // Always leave a real pause after an overrun instead of running scans back-to-back.
        next = max(started.addingTimeInterval(interval), finished.addingTimeInterval(1))
    }

    mutating func requestRefresh() { next = .distantPast }
}

/// Both CPU figures use the same recent window and the same 100% = one core basis.
struct CPUUsageWindow {
    struct Usage {
        let own: Double
        let helpers: Double
        let seconds: TimeInterval
        var total: Double { own + helpers }
    }
    private struct Point {
        let at: Date
        let own: Double
        let helpers: Double
    }
    private var points: [Point] = []
    let seconds: TimeInterval

    init(seconds: TimeInterval = 30) { self.seconds = max(1, seconds) }

    mutating func record(at now: Date, own: Double, helpers: Double) -> Usage {
        let current = Point(at: now, own: own, helpers: helpers)
        if let last = points.last, now <= last.at || own < last.own || helpers < last.helpers {
            points.removeAll(keepingCapacity: true)
        }
        points.append(current)
        let cutoff = now.addingTimeInterval(-seconds)
        while points.count > 2, points[1].at <= cutoff { points.removeFirst() }
        guard let first = points.first, now > first.at else { return Usage(own: 0, helpers: 0, seconds: 0) }
        let elapsed = now.timeIntervalSince(first.at)
        return Usage(own: max(0, own - first.own) / elapsed * 100,
                     helpers: max(0, helpers - first.helpers) / elapsed * 100, seconds: elapsed)
    }
}

enum SamplingPerformanceTests {
    static func run() {
        let t = Date(timeIntervalSince1970: 1_800_000_000)
        var budget = SamplingBudget()
        precondition(budget.isDue(at: t))
        budget.completed(cpuSeconds: 0.35, started: t, finished: t.addingTimeInterval(0.8))
        precondition(budget.interval == 7)
        precondition(!budget.isDue(at: t.addingTimeInterval(6.9)))
        precondition(budget.isDue(at: t.addingTimeInterval(7)))
        budget.completed(cpuSeconds: 0.1, started: t, finished: t.addingTimeInterval(20))
        precondition(budget.next >= t.addingTimeInterval(21)) // no catch-up busy loop
        budget.completed(cpuSeconds: 9, started: t, finished: t)
        precondition(budget.interval == SamplingBudget.maximumInterval)
        budget.requestRefresh()
        precondition(budget.isDue(at: t))

        var window = CPUUsageWindow(seconds: 30)
        _ = window.record(at: t, own: 100, helpers: 200)
        let first = window.record(at: t.addingTimeInterval(10), own: 100.2, helpers: 200.6)
        precondition(abs(first.own - 2) < 0.0001 && abs(first.helpers - 6) < 0.0001)
        precondition(abs(first.total - 8) < 0.0001)
        _ = window.record(at: t.addingTimeInterval(30), own: 100.6, helpers: 201.8)
        let recent = window.record(at: t.addingTimeInterval(40), own: 100.8, helpers: 202.4)
        precondition(abs(recent.seconds - 30) < 0.0001 && abs(recent.total - 8) < 0.0001)
        let reset = window.record(at: t.addingTimeInterval(42), own: 0, helpers: 0)
        precondition(reset.seconds == 0 && reset.total == 0)
        print("SamplingPerformanceTests: passed")
    }
}
