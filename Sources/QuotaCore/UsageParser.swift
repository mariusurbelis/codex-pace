import Foundation

public enum UsageParsingError: Error, LocalizedError, Sendable {
    case invalidUsage
    case unrecognizedResponse

    public var errorDescription: String? {
        switch self {
        case .invalidUsage:
            "Codex returned an invalid usage percentage."
        case .unrecognizedResponse:
            "Codex returned an unrecognized usage response. Update Codex and try again."
        }
    }
}

public enum UsageParser {
    /// Parses the `result` of account/rateLimits/read, not the RPC envelope.
    /// Missing metadata remains unknown; null windows do not create fake bars.
    /// If a present field has the wrong type, decoding fails rather than
    /// silently presenting an incomplete reading as a complete success.
    public static func decodeRateLimitsResult(_ data: Data, fetchedAt: Date = Date()) throws -> UsageSnapshot {
        let decoder = JSONDecoder()
        let response = try decoder.decode(RawResponse.self, from: data)
        guard response.hasRecognizedKey else { throw UsageParsingError.unrecognizedResponse }

        let buckets: [(String, RawBucket)]
        if let byID = response.rateLimitsByLimitId, !byID.isEmpty {
            buckets = byID.keys.sorted().compactMap { id in byID[id].map { (id, $0) } }
        } else if let single = response.rateLimits {
            buckets = [(single.limitId ?? "codex", single)]
        } else {
            buckets = []
        }

        var windows: [QuotaWindow] = []
        for (id, bucket) in buckets {
            for (kind, raw) in [("primary", bucket.primary), ("secondary", bucket.secondary)] {
                guard let raw, let used = raw.usedPercent else { continue }
                guard used.isFinite else { throw UsageParsingError.invalidUsage }
                let duration: Int?
                if let minutes = raw.windowDurationMins,
                   minutes.isFinite,
                   minutes > 0,
                   minutes < Double(Int.max),
                   minutes.rounded(.towardZero) == minutes {
                    duration = Int(minutes)
                } else {
                    duration = nil
                }
                let reset: Date?
                if let timestamp = raw.resetsAt, timestamp.isFinite, timestamp > 0 {
                    reset = Date(timeIntervalSince1970: timestamp)
                } else {
                    reset = nil
                }
                windows.append(QuotaWindow(
                    bucketID: id,
                    bucketName: bucket.limitName,
                    kind: kind,
                    usedPercent: used,
                    windowDurationMins: duration,
                    resetsAt: reset
                ))
            }
        }
        let credits = response.rateLimitResetCredits?.availableCount.flatMap { $0 >= 0 ? $0 : nil }
        return UsageSnapshot(fetchedAt: fetchedAt, windows: windows, availableResetCredits: credits)
    }
}

private struct RawResponse: Decodable {
    let rateLimits: RawBucket?
    let rateLimitsByLimitId: [String: RawBucket]?
    let rateLimitResetCredits: RawCredits?
    let hasRecognizedKey: Bool

    private enum CodingKeys: String, CodingKey {
        case rateLimits, rateLimitsByLimitId, rateLimitResetCredits
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        hasRecognizedKey = container.contains(.rateLimits) || container.contains(.rateLimitsByLimitId)
        rateLimitsByLimitId = try container.decodeIfPresent([String: RawBucket].self, forKey: .rateLimitsByLimitId)
        if let rateLimitsByLimitId, !rateLimitsByLimitId.isEmpty {
            // The legacy compatibility view is redundant when the keyed view
            // is available; an obsolete legacy shape must not hide valid data.
            rateLimits = nil
        } else {
            rateLimits = try container.decodeIfPresent(RawBucket.self, forKey: .rateLimits)
        }
        rateLimitResetCredits = try container.decodeIfPresent(RawCredits.self, forKey: .rateLimitResetCredits)
    }
}

private struct RawBucket: Decodable {
    let limitId: String?
    let limitName: String?
    let primary: RawWindow?
    let secondary: RawWindow?
}

private struct RawWindow: Decodable {
    let usedPercent: Double?
    let windowDurationMins: Double?
    let resetsAt: Double?
}

private struct RawCredits: Decodable {
    let availableCount: Int?
}
