import Foundation
import QuotaCore

/// Local fixtures for inspecting the popover without reading account data.
enum PreviewScenario: String, CaseIterable {
    case ahead, behind, balanced, missing, expired, stale, failure, empty, disconnected, multiple, zero, full

    func snapshot(at now: Date) -> UsageSnapshot? {
        if self == .disconnected { return nil }
        if self == .empty { return UsageSnapshot(fetchedAt: now, windows: []) }
        let remaining: Double = switch self {
        case .behind: 18
        case .balanced: 32.6
        case .zero: 0
        case .full: 100
        default: 64
        }
        let weekly = QuotaWindow(
            bucketID: "codex", kind: "primary", usedPercent: 100 - remaining,
            windowDurationMins: self == .missing ? nil : 10_080,
            resetsAt: self == .missing ? nil : now.addingTimeInterval(self == .expired ? -60 : 7 * 86_400 * 0.326)
        )
        var windows = [weekly]
        if self == .multiple {
            windows.append(QuotaWindow(
                bucketID: "codex", kind: "secondary", usedPercent: 20,
                windowDurationMins: 300, resetsAt: now.addingTimeInterval(3 * 3_600)
            ))
        }
        return UsageSnapshot(fetchedAt: now.addingTimeInterval(self == .stale ? -3_600 : 0), windows: windows)
    }

    var errorMessage: String? {
        switch self {
        case .failure: "Usage could not be refreshed. Try again."
        case .disconnected: "Codex could not be found. Choose your installed Codex CLI to continue."
        default: nil
        }
    }

    func changes(at now: Date) -> [QuotaChange] {
        guard self == .ahead else { return [] }
        return [
            QuotaChange(windowID: "codex.primary", observedAt: now.addingTimeInterval(-600), message: "Weekly quota restored"),
            QuotaChange(windowID: "codex.primary", observedAt: now.addingTimeInterval(-3_600), message: "Weekly reset schedule updated"),
        ]
    }
}
