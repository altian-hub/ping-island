import Foundation

/// Why Island answered a permission prompt without the user.
enum AutoApprovalSource: String, Sendable {
    /// The "Auto-allow all Claude Code permissions" setting.
    case global
    /// "Always Allow" clicked for this one session.
    case session
}

/// Append-only JSONL record of every permission prompt Island auto-approved.
///
/// Claude Code's transcripts already log a `hook_permission_decision` attachment,
/// but only with the tool-use id, split across one file per session, and without
/// saying whether a person or the auto-approve path made the call. This is the one
/// place to answer "what did Island let through on my behalf?".
actor AutoApprovalLog {
    static let shared = AutoApprovalLog()

    nonisolated static var fileURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/PingIsland", isDirectory: true)
            .appendingPathComponent("auto-approvals.jsonl")
    }

    /// Long tool inputs (heredocs, whole-file writes) are cut so the log stays
    /// skimmable and small.
    nonisolated static let maxInputLength = 300

    private let fileManager = FileManager.default
    private let timestampFormatter = ISO8601DateFormatter()

    private init() {}

    func record(event: HookEvent, toolUseId: String, source: AutoApprovalSource) {
        let entry: [String: String] = [
            "time": timestampFormatter.string(from: Date()),
            "source": source.rawValue,
            "sessionId": event.sessionId,
            "cwd": event.cwd,
            "tool": event.tool ?? "",
            "toolUseId": toolUseId,
            "input": Self.summarizeInput(tool: event.tool, input: event.toolInput),
        ]

        guard var line = try? JSONSerialization.data(withJSONObject: entry, options: [.sortedKeys, .withoutEscapingSlashes]) else {
            return
        }
        line.append(0x0A)

        let url = Self.fileURL
        do {
            try fileManager.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )

            if !fileManager.fileExists(atPath: url.path) {
                try line.write(to: url, options: .atomic)
                return
            }

            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: line)
        } catch {
            // The approval has already been sent; a failed log write must not affect it.
        }
    }

    /// The part of the input a person would check: the command for Bash, the path
    /// for file tools, otherwise the whole input as compact JSON.
    nonisolated static func summarizeInput(tool: String?, input: [String: AnyCodable]?) -> String {
        guard let input, !input.isEmpty else { return "" }

        let summary: String
        if tool == "Bash", let command = input["command"]?.value as? String {
            summary = command
        } else if let path = (input["file_path"] ?? input["notebook_path"])?.value as? String {
            summary = path
        } else {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            summary = (try? encoder.encode(input)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
        }

        guard summary.count > maxInputLength else { return summary }
        return String(summary.prefix(maxInputLength)) + "…"
    }
}
