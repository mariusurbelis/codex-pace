import Foundation

public enum RefreshSchedule {
    /// Schedules reads independently from UI redraws. After a successful read,
    /// refresh every five minutes or shortly after the next known reset.
    /// Failed reads use bounded exponential backoff; reset timing must not
    /// bypass that backoff and repeatedly hit a failing service.
    public static func nextRefresh(
        after now: Date,
        snapshot: UsageSnapshot?,
        consecutiveFailures: Int,
        jitterFraction: Double = 0
    ) -> Date {
        if consecutiveFailures > 0 {
            let exponent = min(consecutiveFailures - 1, 4)
            let baseDelay = min(3_600, 300 * pow(2, Double(exponent)))
            let jitter = jitterFraction.isNaN ? 0 : min(0.05, max(0, jitterFraction))
            let delay = min(3_600, baseDelay * (1 + jitter))
            return now.addingTimeInterval(delay)
        }

        let nextReset = snapshot?.windows.compactMap { window -> TimeInterval? in
            guard let reset = window.resetsAt else { return nil }
            let interval = reset.timeIntervalSince(now)
            return interval.isFinite && interval > 0 ? interval : nil
        }.min()

        let delay = nextReset.map { min(300, max(15, $0 + 3)) } ?? 300
        return now.addingTimeInterval(delay)
    }
}
