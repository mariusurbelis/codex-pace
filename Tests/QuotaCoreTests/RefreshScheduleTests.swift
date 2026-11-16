import Foundation
import Testing
@testable import QuotaCore

@Suite("Refresh scheduling")
struct RefreshScheduleTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func snapshot(resetOffsets: [TimeInterval]) -> UsageSnapshot {
        UsageSnapshot(
            fetchedAt: now,
            windows: resetOffsets.enumerated().map { index, offset in
                QuotaWindow(
                    bucketID: "bucket_\(index)",
                    kind: "primary",
                    usedPercent: 40,
                    windowDurationMins: 10_080,
                    resetsAt: now.addingTimeInterval(offset)
                )
            }
        )
    }

    private func delay(
        snapshot: UsageSnapshot? = nil,
        failures: Int = 0,
        jitter: Double = 0
    ) -> TimeInterval {
        RefreshSchedule.nextRefresh(
            after: now,
            snapshot: snapshot,
            consecutiveFailures: failures,
            jitterFraction: jitter
        ).timeIntervalSince(now)
    }

    @Test func successfulReadsUseFiveMinutesWithoutResetData() {
        #expect(delay() == 300)
        #expect(delay(snapshot: snapshot(resetOffsets: [])) == 300)
        #expect(delay(failures: -1) == 300)
        #expect(delay(jitter: 0.05) == 300)
    }

    @Test func imminentResetsWaitAtLeastFifteenSeconds() {
        #expect(delay(snapshot: snapshot(resetOffsets: [3])) == 15)
        #expect(delay(snapshot: snapshot(resetOffsets: [0.001])) == 15)
        #expect(delay(snapshot: snapshot(resetOffsets: [12])) == 15)
    }

    @Test func futureResetGetsThreeSecondsForServerPropagation() {
        #expect(delay(snapshot: snapshot(resetOffsets: [100])) == 103)
        #expect(delay(snapshot: snapshot(resetOffsets: [297])) == 300)
        #expect(delay(snapshot: snapshot(resetOffsets: [299])) == 300)
        #expect(delay(snapshot: snapshot(resetOffsets: [10_000])) == 300)
    }

    @Test func earliestFutureResetWinsAcrossBuckets() {
        #expect(delay(snapshot: snapshot(resetOffsets: [1_000, -100, 100, 200])) == 103)
    }

    @Test func expiredResetDoesNotCauseARefreshLoop() {
        let expired = snapshot(resetOffsets: [-1, 0])
        for elapsed in [0.0, 15.0, 300.0, 3_600.0] {
            let later = now.addingTimeInterval(elapsed)
            let next = RefreshSchedule.nextRefresh(after: later, snapshot: expired, consecutiveFailures: 0)
            #expect(next.timeIntervalSince(later) == 300)
        }
    }

    @Test func failuresBackOffToOneHourAndOverrideResetTiming() {
        let expected = [300.0, 600, 1_200, 2_400, 3_600, 3_600]
        for (index, seconds) in expected.enumerated() {
            #expect(delay(snapshot: snapshot(resetOffsets: [3]), failures: index + 1) == seconds)
        }
        #expect(delay(failures: Int.max) == 3_600)
    }

    @Test func retryJitterIsDeterministicBoundedAndCapped() {
        #expect(delay(failures: 1, jitter: 0.025) == 307.5)
        #expect(delay(failures: 2, jitter: 0.05) == 630)
        #expect(delay(failures: 1, jitter: 1) == 315)
        #expect(delay(failures: 1, jitter: -1) == 300)
        #expect(delay(failures: 1, jitter: .nan) == 300)
        #expect(delay(failures: 1, jitter: .infinity) == 315)
        #expect(delay(failures: 5, jitter: 0.05) == 3_600)
    }
}
