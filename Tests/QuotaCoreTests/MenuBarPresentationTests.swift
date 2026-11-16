import Foundation
import Testing
@testable import QuotaCore

@Suite("Menu bar presentation")
struct MenuBarPresentationTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let locale = Locale(identifier: "en_US")

    private func window(remaining: Double = 64, duration: Int? = 1_000, seconds: Double? = 30_960) -> QuotaWindow {
        QuotaWindow(
            bucketID: "codex", kind: "primary", usedPercent: 100 - remaining,
            windowDurationMins: duration, resetsAt: seconds.map { now.addingTimeInterval($0) }
        )
    }

    private func present(_ window: QuotaWindow?, mode: MenuBarDisplayMode = .paceBalance, stale: Bool = false, at date: Date? = nil) -> MenuBarPresentation {
        MenuBarPresentation(mode: mode, window: window, isStale: stale, at: date ?? now, locale: locale)
    }

    @Test func preferenceFallbackAndLabels() {
        #expect(MenuBarDisplayMode(preference: nil) == .remaining)
        #expect(MenuBarDisplayMode(preference: "invalid") == .remaining)
        #expect(MenuBarDisplayMode(preference: "paceBalance") == .paceBalance)
        #expect(MenuBarDisplayMode.remaining.title == "Remaining allowance")
        #expect(MenuBarDisplayMode.paceBalance.title == "Above / below pace")
    }

    @Test func signedBalancesKeepRemainingInSummary() {
        let ahead = present(window())
        #expect(ahead.title == "+12.4 pts")
        #expect(ahead.summary.contains("64% remaining"))
        #expect(ahead.summary.contains("12.4 percentage points above even-use pace"))
        #expect(!ahead.isPaceUnavailable)

        let behind = present(window(remaining: 48.4))
        #expect(behind.title == "−3.2 pts")
        #expect(behind.summary.contains("3.2 percentage points below even-use pace"))
        #expect(present(window(remaining: 51.6)).title == "0.0 pts")
        #expect(present(window(), mode: .remaining).title == "64%")
    }

    @Test func smallGapsHaveNoToleranceAndNegativeZeroIsNormalized() throws {
        #expect(present(window(remaining: 51.7)).title == "+0.1 pts")
        #expect(present(window(remaining: 51.5)).title == "−0.1 pts")
        #expect(present(window(remaining: 51.59)).title == "0.0 pts")
        let gap = try #require(PaceMetrics(window: window(remaining: 51.59), at: now).roundedGapPercentagePoints)
        #expect(gap == 0)
        #expect(gap.sign == .plus)
    }

    @Test func unknownAndInvalidMetadataAreUnavailable() {
        for quota in [nil, window(duration: nil), window(duration: 0), window(seconds: nil), window(remaining: .nan), window(remaining: .infinity)] {
            let presentation = present(quota)
            #expect(presentation.title == "— pts")
            #expect(presentation.isPaceUnavailable)
        }
        #expect(present(nil, mode: .remaining).title == "—")
        #expect(present(window(remaining: .nan), mode: .remaining).title == "—")
        #expect(present(window(duration: nil)).summary.contains("64% remaining"))
    }

    @Test func expiredAndStaleReadingsNeverAdvertisePace() {
        for seconds in [0.0, -1.0] {
            let expired = present(window(seconds: seconds))
            #expect(expired.title == "— pts")
            #expect(expired.isPaceUnavailable)
            #expect(expired.summary.contains("Reset due"))
            #expect(expired.summary.contains("64% remaining"))
        }
        let stale = present(window(), stale: true)
        #expect(stale.title == "— pts")
        #expect(stale.summary.contains("cached reading"))
        #expect(stale.isPaceUnavailable)
        #expect(present(window(), mode: .remaining, stale: true).title == "64%")
    }

    @Test func advancingClockChangesBalanceWithoutChangingRemaining() {
        let quota = window()
        #expect(present(quota).title == "+12.4 pts")
        #expect(present(quota, at: now.addingTimeInterval(600)).title == "+13.4 pts")
        #expect(present(quota, mode: .remaining, at: now.addingTimeInterval(600)).title == "64%")
        #expect(present(quota, at: now.addingTimeInterval(30_960)).isPaceUnavailable)
    }

    @Test func endpointsAndLocaleFormatting() {
        #expect(present(window(remaining: 0)).title == "−51.6 pts")
        #expect(present(window(remaining: 100)).title == "+48.4 pts")
        let localized = MenuBarPresentation(mode: .paceBalance, window: window(), isStale: false, at: now, locale: Locale(identifier: "de_DE"))
        #expect(localized.title == "+12,4 pts")
    }
}
