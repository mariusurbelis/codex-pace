import Foundation

public enum MenuBarDisplayMode: String, CaseIterable, Sendable {
    case remaining
    case paceBalance

    public init(preference: String?) {
        self = preference.flatMap(Self.init(rawValue:)) ?? .remaining
    }

    public var title: String {
        switch self {
        case .remaining: "Remaining allowance"
        case .paceBalance: "Above / below pace"
        }
    }
}

/// Display-only calculations; advancing the clock never restores actual quota.
public struct MenuBarPresentation: Sendable {
    public let title: String
    public let summary: String
    public let isPaceUnavailable: Bool

    public init(
        mode: MenuBarDisplayMode,
        window: QuotaWindow?,
        isStale: Bool,
        at now: Date,
        locale: Locale = .current
    ) {
        guard let window else {
            title = mode == .paceBalance ? "— pts" : "—"
            summary = "Codex Pace. Allowance unavailable. Pace unavailable."
            isPaceUnavailable = true
            return
        }

        let metrics = PaceMetrics(window: window, at: now)
        let gap = metrics.roundedGapPercentagePoints
        let hasUsage = window.usedPercent.isFinite
        isPaceUnavailable = isStale || gap == nil

        let remaining = hasUsage ? "\(Int(window.remainingPercent.rounded()))%" : nil
        var descriptions = ["Codex Pace. \(window.displayName)."]
        if let remaining {
            descriptions.append("\(remaining) remaining\(isStale ? " from a cached reading" : "").")
        } else {
            descriptions.append("Remaining allowance unavailable\(isStale ? "; cached reading" : "").")
        }

        if !isPaceUnavailable, let gap {
            let magnitude = abs(gap).formatted(.number.precision(.fractionLength(1)).grouping(.never).locale(locale))
            if gap > 0 {
                descriptions.append("\(magnitude) percentage points above even-use pace.")
            } else if gap < 0 {
                descriptions.append("\(magnitude) percentage points below even-use pace.")
            } else {
                descriptions.append("\(magnitude) percentage points from even-use pace.")
            }
            descriptions.append("Percentage points measure the whole allowance.")
            title = mode == .remaining
                ? (remaining ?? "—")
                : "\(gap > 0 ? "+" : gap < 0 ? "−" : "")\(magnitude) pts"
        } else {
            title = mode == .paceBalance ? "— pts" : (remaining ?? "—")
            if metrics.isExpired {
                descriptions.append("Pace unavailable. Reset due; waiting for a fresh reading.")
            } else if isStale {
                descriptions.append("Pace unavailable until a fresh reading arrives.")
            } else {
                descriptions.append("Pace unavailable because usage, reset time, or window length is missing or invalid.")
            }
        }
        summary = descriptions.joined(separator: " ")
    }
}
