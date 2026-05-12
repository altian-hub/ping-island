import Foundation

struct ClaudeUsageWindow: Equatable, Codable, Sendable {
    let usedPercentage: Double
    let resetsAt: Date?

    var roundedUsedPercentage: Int {
        Int(usedPercentage.rounded())
    }
}

struct ClaudeUsageSnapshot: Equatable, Codable, Sendable {
    let fiveHour: ClaudeUsageWindow?
    let sevenDay: ClaudeUsageWindow?
    let cachedAt: Date?

    nonisolated
    var isEmpty: Bool {
        let hasFiveHour: Bool = if case .some = fiveHour { true } else { false }
        let hasSevenDay: Bool = if case .some = sevenDay { true } else { false }
        return !hasFiveHour && !hasSevenDay
    }
}

enum ClaudeUsageLoader {
    nonisolated static let defaultCacheURL = URL(fileURLWithPath: "/tmp/island-rate-limits.json")

    nonisolated static func load(from url: URL = defaultCacheURL) throws -> ClaudeUsageSnapshot? {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return nil
        }

        let data = try Data(contentsOf: url)
        let object = try JSONSerialization.jsonObject(with: data)
        guard let payload = object as? [String: Any] else {
            return nil
        }

        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        let cachedAt = attributes?[.modificationDate] as? Date
        let snapshot = ClaudeUsageSnapshot(
            fiveHour: usageWindow(for: "five_hour", in: payload),
            sevenDay: usageWindow(for: "seven_day", in: payload),
            cachedAt: cachedAt
        )

        return snapshot.isEmpty ? nil : snapshot
    }

    private nonisolated static func usageWindow(for key: String, in payload: [String: Any]) -> ClaudeUsageWindow? {
        guard let window = payload[key] as? [String: Any],
              let rawPercentage = number(from: window["used_percentage"])
                ?? number(from: window["utilization"]) else {
            return nil
        }

        return ClaudeUsageWindow(
            usedPercentage: rawPercentage,
            resetsAt: date(from: window["resets_at"])
        )
    }

    private nonisolated static func number(from value: Any?) -> Double? {
        switch value {
        case let value as NSNumber:
            return value.doubleValue
        case let value as String:
            return Double(value)
        default:
            return nil
        }
    }

    private nonisolated static func date(from value: Any?) -> Date? {
        switch value {
        case let value as NSNumber:
            return Date(timeIntervalSince1970: value.doubleValue)
        case let value as String:
            if let seconds = Double(value) {
                return Date(timeIntervalSince1970: seconds)
            }

            let formatterWithFractionalSeconds = ISO8601DateFormatter()
            formatterWithFractionalSeconds.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = formatterWithFractionalSeconds.date(from: value) {
                return date
            }

            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime]
            return formatter.date(from: value)
        default:
            return nil
        }
    }
}
