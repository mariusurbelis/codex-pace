import Foundation
import Testing
@testable import QuotaCore

private let referenceReset = Date(timeIntervalSince1970: 1_800_000_000)

private func window(
    bucket: String = "codex",
    kind: String = "primary",
    used: Double = 40,
    duration: Int? = 10_080,
    reset: Date? = referenceReset
) -> QuotaWindow {
    QuotaWindow(bucketID: bucket, kind: kind, usedPercent: used, windowDurationMins: duration, resetsAt: reset)
}

@Suite("QuotaCore")
struct QuotaCoreTests {
    @Test func dayOneShowsOverspendingInPercentagePoints() throws {
        let result = PaceMetrics(window: window(), at: referenceReset.addingTimeInterval(-6 * 86_400))
        #expect(abs(try #require(result.targetRemainingPercent) - 85.714285714) < 0.00001)
        #expect(abs(try #require(result.gapPercentagePoints) + 25.714285714) < 0.00001)
        #expect(result.daysRemaining == 6)
        #expect(result.dailyAllowancePercent == 10)
        #expect(!result.isExpired)
    }

    @Test func midpointWithHalfRemainingIsOnPace() {
        let result = PaceMetrics(window: window(used: 50), at: referenceReset.addingTimeInterval(-3.5 * 86_400))
        #expect(result.targetRemainingPercent == 50)
        #expect(result.gapPercentagePoints == 0)
    }

    @Test func overdueResetKeepsActualQuotaWithoutInventingNewWindow() {
        let quota = window(used: 65)
        let metrics = PaceMetrics(window: quota, at: referenceReset.addingTimeInterval(60))
        #expect(quota.remainingPercent == 35)
        #expect(metrics.isExpired)
        #expect(metrics.daysRemaining == 0)
        #expect(metrics.targetRemainingPercent == nil)
        #expect(metrics.dailyAllowancePercent == nil)
    }

    @Test func missingMetadataKeepsQuotaAndSuppressesPace() {
        let noMetadata = PaceMetrics(window: window(duration: nil, reset: nil), at: referenceReset)
        #expect(noMetadata.targetRemainingPercent == nil)
        #expect(noMetadata.daysRemaining == nil)
        #expect(!noMetadata.isExpired)
        let noDuration = PaceMetrics(window: window(duration: nil), at: referenceReset.addingTimeInterval(-86_400))
        #expect(noDuration.daysRemaining == 1)
        #expect(noDuration.targetRemainingPercent == nil)
    }

    @Test func displayClampsOveragesAndClockSkew() {
        #expect(window(used: 140).remainingPercent == 0)
        #expect(window(used: -10).remainingPercent == 100)
        let result = PaceMetrics(window: window(), at: referenceReset.addingTimeInterval(-10 * 86_400))
        #expect(result.targetRemainingPercent == 100)
        let nearReset = PaceMetrics(window: window(), at: referenceReset.addingTimeInterval(-1))
        #expect(nearReset.dailyAllowancePercent == nil)
    }

    @Test func decodesWeeklyPrimaryInLegacyResponse() throws {
        let data = Data(#"{"rateLimits":{"limitId":"codex","primary":{"usedPercent":65,"windowDurationMins":10080,"resetsAt":1800000000},"secondary":null}}"#.utf8)
        let snapshot = try UsageParser.decodeRateLimitsResult(data, fetchedAt: referenceReset)
        let quota = try #require(snapshot.preferredWindow)
        #expect(quota.isWeekly)
        #expect(quota.kind == "primary")
        #expect(quota.resetsAt == referenceReset)
        #expect(quota.remainingPercent == 35)
        #expect(snapshot.fetchedAt == referenceReset)
    }

    @Test func multiBucketResponseWinsAndWeeklySelectionUsesDuration() throws {
        let data = Data(#"{"rateLimits":{"limitId":"legacy","primary":{"usedPercent":99}},"rateLimitsByLimitId":{"other":{"limitName":"Extra","primary":{"usedPercent":1,"windowDurationMins":10080}},"codex":{"primary":{"usedPercent":3.5,"windowDurationMins":300},"secondary":{"usedPercent":55,"windowDurationMins":10080}}},"rateLimitResetCredits":{"availableCount":2,"credits":null}}"#.utf8)
        let snapshot = try UsageParser.decodeRateLimitsResult(data)
        #expect(snapshot.windows.count == 3)
        #expect(snapshot.availableResetCredits == 2)
        #expect(snapshot.preferredWindow?.id == "codex.secondary")
        #expect(snapshot.windows.first { $0.id == "codex.primary" }?.remainingPercent == 96.5)
        #expect(snapshot.windows.first { $0.bucketID == "other" }?.bucketName == "Extra")
    }

    @Test func emptyMapFallsBackAndAbsentWindowsRemainAbsent() throws {
        let fallback = Data(#"{"rateLimitsByLimitId":{},"rateLimits":{"primary":{"usedPercent":25}}}"#.utf8)
        let snapshot = try UsageParser.decodeRateLimitsResult(fallback)
        #expect(snapshot.windows.count == 1)
        #expect(snapshot.preferredWindow?.bucketID == "codex")
        #expect(snapshot.preferredWindow?.resetsAt == nil)
        #expect(snapshot.preferredWindow?.windowDurationMins == nil)
        let noWindows = Data(#"{"rateLimits":null,"rateLimitsByLimitId":null}"#.utf8)
        #expect(try UsageParser.decodeRateLimitsResult(noWindows).preferredWindow == nil)
        let missingUsage = Data(#"{"rateLimits":{"primary":{"windowDurationMins":10080},"secondary":null}}"#.utf8)
        #expect(try UsageParser.decodeRateLimitsResult(missingUsage).windows.isEmpty)
    }

    @Test func validKeyedViewDoesNotDependOnObsoleteCompatibilityView() throws {
        let data = Data(#"{"rateLimits":"obsolete shape","rateLimitsByLimitId":{"codex":{"primary":{"usedPercent":25,"windowDurationMins":10080}}}}"#.utf8)
        #expect(try UsageParser.decodeRateLimitsResult(data).preferredWindow?.remainingPercent == 75)
    }

    @Test func invalidMetadataDoesNotCreateAWeeklyWindow() throws {
        let data = Data(#"{"rateLimits":{"primary":{"usedPercent":20,"windowDurationMins":-1,"resetsAt":0},"secondary":{"usedPercent":30,"windowDurationMins":10080.5}}}"#.utf8)
        let snapshot = try UsageParser.decodeRateLimitsResult(data)
        #expect(snapshot.windows.allSatisfy { $0.windowDurationMins == nil && !$0.isWeekly && $0.resetsAt == nil })
    }

    @Test func malformedResponsesFailInsteadOfClaimingFreshUsage() {
        #expect(throws: (any Error).self) {
            try UsageParser.decodeRateLimitsResult(Data(#"{"rateLimits":{"primary":{"usedPercent":"65"}}}"#.utf8))
        }
        #expect(throws: (any Error).self) {
            try UsageParser.decodeRateLimitsResult(Data(#"{"unrelated":true}"#.utf8))
        }
    }

    @Test func codableCacheRoundTripPreservesQuotaAndResetDate() throws {
        let snapshot = UsageSnapshot(fetchedAt: referenceReset, windows: [window()], availableResetCredits: 1)
        let encoded = try JSONEncoder().encode(snapshot)
        #expect(try JSONDecoder().decode(UsageSnapshot.self, from: encoded) == snapshot)
    }

    @Test func resetDetectionRequiresChangedServerReading() {
        let before = UsageSnapshot(fetchedAt: referenceReset, windows: [window(used: 65)])
        let unchanged = UsageSnapshot(fetchedAt: referenceReset.addingTimeInterval(301), windows: [window(used: 65)])
        #expect(QuotaChangeDetector.changes(from: before, to: unchanged).isEmpty)
        #expect(QuotaChangeDetector.changes(from: nil, to: before).isEmpty)
        let restored = UsageSnapshot(fetchedAt: referenceReset.addingTimeInterval(302), windows: [window(used: 0)])
        #expect(QuotaChangeDetector.changes(from: before, to: restored).first?.message == "Weekly quota restored")
        let moved = UsageSnapshot(fetchedAt: referenceReset.addingTimeInterval(303), windows: [window(used: 65, reset: referenceReset.addingTimeInterval(86_400))])
        #expect(QuotaChangeDetector.changes(from: before, to: moved).first?.message == "Weekly reset schedule updated")
        #expect(QuotaChangeDetector.changes(from: moved, to: before).isEmpty)
    }

    @Test func everyBucketIsComparedIndependently() {
        let before = UsageSnapshot(fetchedAt: referenceReset, windows: [window(used: 65), window(bucket: "other", used: 10)])
        let after = UsageSnapshot(fetchedAt: referenceReset.addingTimeInterval(30), windows: [window(used: 66), window(bucket: "other", used: 0)])
        let changes = QuotaChangeDetector.changes(from: before, to: after)
        #expect(changes.count == 1)
        #expect(changes.first?.windowID == "other.primary")
    }
}
