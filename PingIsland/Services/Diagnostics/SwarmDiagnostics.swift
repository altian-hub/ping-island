import Foundation
import os.log

/// Opt-in runtime instrumentation for diagnosing missed permission prompts and
/// attention-surfacing failures. See ClaudeSubagentSwarmSoundTests for the
/// coalescing claim that originally motivated this tooling.
///
/// PING_ISLAND_SWARM_DIAG=1  — standard stages (written always when enabled)
/// PING_ISLAND_SWARM_DIAG=2  — verbose stages (superset of =1, much noisier)
///
/// Writes newline-delimited timestamped records to ~/.ping-island-debug/swarm-diag.log.
///
/// Standard stages (=1):
///   PUBLISH      — every visible-session snapshot published to the UI, with attn count.
///   BUDDY-SNAP   — every instances snapshot received by FloatingPetView (may coalesce).
///   BUDDY-ATTN   — every attentionCount change in FloatingPetView.
///   BUDDY-SOUND  — sound outcome from the evaluator (notch mode counterpart is ONCHANGE).
///   ONCHANGE     — NotchView.onChange(of: instances) result + sound outcome.
///   PERM-RECV    — PermissionRequest hook event queued in HookSocketServer.
///   PERM-RESP    — Permission response sent back to Claude Code.
///   FILTER-WARN  — [always emitted] attention-needing session was dropped by the
///                  visibility filter (should never happen; indicates a surfacing bug).
///
/// Verbose-only stages (=2):
///   FILTER       — every session dropped by filteredVisibleSessions with reasons.
///   BUDDY-NAV    — content-type navigation decisions inside attentionCount onChange.
enum SwarmDiagnostics {
    /// Set `PING_ISLAND_SWARM_DIAG=1` to enable standard logging (PUBLISH, BUDDY-SNAP, etc.).
    /// Set `PING_ISLAND_SWARM_DIAG=2` to also enable verbose stages (FILTER, BUDDY-NAV, PERM).
    /// All logging is compiled out in Release builds — no overhead in production.
    static let isEnabled: Bool = {
        #if DEBUG
        let val = Foundation.ProcessInfo.processInfo.environment["PING_ISLAND_SWARM_DIAG"]
        return val == "1" || val == "2"
        #else
        return false
        #endif
    }()

    static let isVerbose: Bool = {
        #if DEBUG
        return Foundation.ProcessInfo.processInfo.environment["PING_ISLAND_SWARM_DIAG"] == "2"
        #else
        return false
        #endif
    }()

    private static let queue = DispatchQueue(label: "com.wudanwu.pingisland.swarm-diag")
    private static let timestamp = ISO8601DateFormatter()
    private static let logger = Logger(subsystem: "com.wudanwu.pingisland", category: "SwarmDiag")

    nonisolated static var logFileURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".ping-island-debug", isDirectory: true)
            .appendingPathComponent("swarm-diag.log")
    }

    /// Always-on warning path: logs to os_log at .warning AND to the debug file
    /// when diagnostics are enabled. Use for conditions that should never happen
    /// in production (e.g. an attention session silently filtered from the UI).
    static func logFilterWarning(_ message: @autoclosure () -> String) {
        let msg = message()
        logger.warning("[FILTER-WARN] \(msg, privacy: .public)")
        guard isEnabled else { return }
        writeToFile(stage: "FILTER-WARN", message: msg)
    }

    /// Record a stage line. The message autoclosure is not evaluated when disabled.
    static func log(_ stage: String, _ message: @autoclosure () -> String) {
        guard isEnabled else { return }
        let msg = message()
        writeToFile(stage: stage, message: msg)
    }

    private static func writeToFile(stage: String, message: String) {
        let line = "[\(timestamp.string(from: Date()))] [\(stage)] \(message)\n"
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
            let isInteresting = session.needsManualAttention
                || session.phase == .processing
                || session.phase == .compacting
                || session.phase == .waitingForInput
            guard isInteresting else { continue }
            let id = String(session.sessionId.prefix(8))
            let phase = session.phase.description
            // "!" = needs approval response, "?" = needs manual attention but not approval
            let mark: String
            if session.needsApprovalResponse { mark = "!" }
            else if session.needsManualAttention { mark = "?" }
            else { mark = "" }
            parts.append(id + "=" + phase + mark)
        }
        return parts.isEmpty ? "(none)" : parts.joined(separator: " ")
    }

    /// One-line summary of why a session was filtered, for FILTER-WARN and FILTER stages.
    static func describeHide(_ session: SessionState, visibilityMode: SubagentVisibilityMode) -> String {
        var reasons: [String] = []
        if session.shouldAutoArchiveFromPrimaryUI { reasons.append("auto-archive") }
        if session.isLikelyEmptyCodexPlaceholderForUI { reasons.append("codex-phantom") }
        if session.isLikelyClaudeAuxiliaryTitleGenForUI { reasons.append("title-gen") }
        if session.isLikelyEmptyClaudePlaceholderForUI { reasons.append("claude-phantom") }
        if !session.shouldDisplaySubagent(in: visibilityMode) { reasons.append("subagent-hidden") }
        let attn = session.needsManualAttention ? " ATTN=\(session.phase.description)" : ""
        return "\(session.sessionId.prefix(8))\(attn) [\(reasons.joined(separator: ","))]"
    }
}
