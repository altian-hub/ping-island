import Foundation

/// Opt-in runtime instrumentation to verify the "SwiftUI coalesces `instances`
/// snapshots during a subagent swarm" claim (see ClaudeSubagentSwarmSoundTests).
///
/// Enable by launching the app with `PING_ISLAND_SWARM_DIAG=1` in the environment.
/// Writes newline-delimited records to `~/.ping-island-debug/swarm-diag.log`.
///
/// Two stages are logged so they can be compared:
///   - `PUBLISH`  — every state the publisher emits to the UI (lossless, one per
///                  SessionStore event), from `SessionMonitor.refreshVisibleSessions`.
///   - `ONCHANGE` — what `NotchView.onChange(of: instances)` actually receives
///                  (SwiftUI-coalesced), plus the attention-sound outcome.
///
/// If `PUBLISH` shows `waitingForApproval` for a session that `ONCHANGE` never
/// (or rarely) sees, coalescing is dropping the prompt before it can be surfaced.
enum SwarmDiagnostics {
    static let isEnabled: Bool =
        Foundation.ProcessInfo.processInfo.environment["PING_ISLAND_SWARM_DIAG"] == "1"

    private static let queue = DispatchQueue(label: "com.wudanwu.pingisland.swarm-diag")
    private static let timestamp = ISO8601DateFormatter()

    nonisolated static var logFileURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".ping-island-debug", isDirectory: true)
            .appendingPathComponent("swarm-diag.log")
    }

    /// Record a stage line. The message autoclosure is not evaluated when disabled.
    static func log(_ stage: String, _ message: @autoclosure () -> String) {
        guard isEnabled else { return }
        let line = "[\(timestamp.string(from: Date()))] [\(stage)] \(message())\n"
        queue.async {
            let url = logFileURL
            let fm = FileManager.default
            do {
                try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                if !fm.fileExists(atPath: url.path) {
                    try Data(line.utf8).write(to: url, options: .atomic)
                    return
                }
                let handle = try FileHandle(forWritingTo: url)
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: Data(line.utf8))
            } catch {
                // Never let diagnostics writes affect the main path.
            }
        }
    }

    /// Compact phase summary for a snapshot, listing only attention/processing
    /// sessions (the ones that matter for the coalescing question).
    static func summarize(_ sessions: [SessionState]) -> String {
        var parts: [String] = []
        for session in sessions {
            let isInteresting = session.needsApprovalResponse
                || session.phase == .processing
                || session.phase == .waitingForInput
            guard isInteresting else { continue }
            let id = String(session.sessionId.prefix(8))
            let phase = session.phase.description
            let mark = session.needsApprovalResponse ? "!" : ""
            parts.append(id + "=" + phase + mark)
        }
        return parts.isEmpty ? "(none)" : parts.joined(separator: " ")
    }
}
