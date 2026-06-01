import XCTest
@testable import Ping_Island

/// Reproduction for the "subagent swarm permission storm" bug.
///
/// Real-world symptom (see ~/.ping-island-debug/claude-hooks/20260601.jsonl):
/// a Claude session (`b0f78f98…`, cwd .../efi/gpu9) spawned ~7 parallel
/// `general-purpose` subagents via the Agent/Task tool. Claude Code 2.1.x reports
/// every subagent's tool events under the SAME parent `session_id`, tagged with
/// `agent_id`/`agent_type`. PingIsland's `HookEvent` has no field for that tag, so
/// all subagents collapse onto one `SessionState`. A subagent's `PermissionRequest`
/// (e.g. Read of dp_mst_edid.cpp) sets `.waitingForApproval`, but the other
/// subagents' fire-and-forget `PreToolUse`/`PostToolUse` traffic flips the single
/// scalar phase back to processing — so the blocking prompt never latches in the UI.
///
/// These tests replay that interleaving against the shipping `SessionStore` and
/// assert the session stays surfaced as "needs approval". A failure pins the exact
/// point where sibling-subagent traffic masks a genuinely pending approval.
final class ClaudeSubagentSwarmApprovalTests: XCTestCase {

    /// Faithful to the recorded trace (16:29:22 → 16:30:34): the storm ends on the
    /// blocking `PermissionRequest`, after which the whole session blocks (the ~17s
    /// gap before 16:30:52). The session must end in `.waitingForApproval`.
    func testSwarmPermissionRequestsLatchDespiteSiblingTraffic() async {
        let sessionId = "claude-swarm-\(UUID().uuidString)"
        let store = SessionStore.shared
        defer { Task { await store.process(.sessionArchived(sessionId: sessionId)) } }

        // Parent kicks off the swarm.
        await store.process(.hookReceived(toolEvent(sessionId, "UserPromptSubmit", "processing", "", nil)))
        await store.process(.hookReceived(toolEvent(sessionId, "PreToolUse", "running_tool", "Agent", "agent-1")))

        // Subagent A starts a Read that needs permission -> pending "read-A".
        await store.process(.hookReceived(readEvent(sessionId, "PreToolUse", "running_tool", "read-A", "/repo/src/dp_mst_edid.cpp")))
        await store.process(.hookReceived(readEvent(sessionId, "PermissionRequest", "waiting_for_approval", "read-A", "/repo/src/dp_mst_edid.cpp")))

        // Siblings (other subagents) churn through fast, auto-approved tools.
        await store.process(.hookReceived(toolEvent(sessionId, "PreToolUse", "running_tool", "Bash", "bash-x")))
        await store.process(.hookReceived(toolEvent(sessionId, "PostToolUse", "processing", "Bash", "bash-x")))
        await store.process(.hookReceived(readEvent(sessionId, "PreToolUse", "running_tool", "read-x", "/repo/README.md")))
        await store.process(.hookReceived(readEvent(sessionId, "PostToolUse", "processing", "read-x", "/repo/README.md")))

        // Subagent B hits its own permission prompt -> pending "read-B" (A still pending).
        await store.process(.hookReceived(readEvent(sessionId, "PreToolUse", "running_tool", "read-B", "/repo/src/dp_mst_topology.cpp")))
        await store.process(.hookReceived(readEvent(sessionId, "PermissionRequest", "waiting_for_approval", "read-B", "/repo/src/dp_mst_topology.cpp")))

        // More sibling churn.
        await store.process(.hookReceived(toolEvent(sessionId, "PreToolUse", "running_tool", "Bash", "bash-y")))
        await store.process(.hookReceived(toolEvent(sessionId, "PostToolUse", "processing", "Bash", "bash-y")))

        // Subagent C: the prompt shown in the screenshot. This is the last event before
        // the session blocks on the user.
        await store.process(.hookReceived(readEvent(sessionId, "PreToolUse", "running_tool", "read-C", "/repo/src/dp_mst_edid.cpp")))
        await store.process(.hookReceived(readEvent(sessionId, "PermissionRequest", "waiting_for_approval", "read-C", "/repo/src/dp_mst_edid.cpp")))

        let session = await store.session(for: sessionId)
        XCTAssertEqual(session?.phase.isWaitingForApproval, true,
                       "Session should surface as waiting-for-approval while a subagent prompt is blocking")
        XCTAssertEqual(session?.needsApprovalResponse, true)
        XCTAssertEqual(session?.needsAttention, true)
        XCTAssertNotNil(session?.activePermission)
    }

    /// The race: a sibling subagent's fire-and-forget tool event is delivered just
    /// AFTER the blocking `PermissionRequest` (socket ordering). This is the case
    /// most likely to mask the prompt — the pending Read is not anchored in the
    /// parent's chatItems the way a main-session permission is, so a trailing
    /// `processing` event can flip the single phase scalar and never recover.
    func testTrailingSiblingToolEventDoesNotMaskSwarmApproval() async {
        let sessionId = "claude-swarm-race-\(UUID().uuidString)"
        let store = SessionStore.shared
        defer { Task { await store.process(.sessionArchived(sessionId: sessionId)) } }

        await store.process(.hookReceived(toolEvent(sessionId, "PreToolUse", "running_tool", "Agent", "agent-1")))

        // Blocking subagent permission prompt.
        await store.process(.hookReceived(readEvent(sessionId, "PreToolUse", "running_tool", "read-C", "/repo/src/dp_mst_edid.cpp")))
        await store.process(.hookReceived(readEvent(sessionId, "PermissionRequest", "waiting_for_approval", "read-C", "/repo/src/dp_mst_edid.cpp")))

        // A different subagent's Read completes and arrives after the prompt.
        await store.process(.hookReceived(readEvent(sessionId, "PreToolUse", "running_tool", "read-z", "/repo/docs/notes.md")))
        await store.process(.hookReceived(readEvent(sessionId, "PostToolUse", "processing", "read-z", "/repo/docs/notes.md")))
        await store.process(.hookReceived(toolEvent(sessionId, "PostToolUse", "processing", "Bash", "bash-z")))

        let session = await store.session(for: sessionId)
        XCTAssertEqual(session?.phase.isWaitingForApproval, true,
                       "A pending subagent approval must not be masked by a sibling subagent's trailing tool event")
        XCTAssertEqual(session?.needsApprovalResponse, true)
        XCTAssertEqual(session?.activePermission?.toolUseId, "read-C")
    }

    // MARK: - Helpers

    private func toolEvent(
        _ sessionId: String,
        _ event: String,
        _ status: String,
        _ tool: String,
        _ toolUseId: String?
    ) -> HookEvent {
        HookEvent(
            sessionId: sessionId,
            cwd: "/repo",
            event: event,
            status: status,
            provider: .claude,
            clientInfo: SessionClientInfo(
                kind: .claudeCode,
                profileID: "claude_code",
                name: "Claude Code",
                bundleIdentifier: "com.anthropic.claudecode"
            ),
            pid: nil,
            tty: nil,
            tool: tool.isEmpty ? nil : tool,
            toolInput: tool == "Bash" ? ["command": AnyCodable("echo hi")] : nil,
            // NOTE: the real payload carries agent_id / agent_type identifying the
            // subagent, but HookEvent has no field for it — which is exactly why all
            // subagents collapse onto one session here.
            toolUseId: toolUseId,
            notificationType: nil,
            message: nil
        )
    }

    private func readEvent(
        _ sessionId: String,
        _ event: String,
        _ status: String,
        _ toolUseId: String,
        _ filePath: String
    ) -> HookEvent {
        HookEvent(
            sessionId: sessionId,
            cwd: "/repo",
            event: event,
            status: status,
            provider: .claude,
            clientInfo: SessionClientInfo(
                kind: .claudeCode,
                profileID: "claude_code",
                name: "Claude Code",
                bundleIdentifier: "com.anthropic.claudecode"
            ),
            pid: nil,
            tty: nil,
            tool: "Read",
            toolInput: ["file_path": AnyCodable(filePath)],
            toolUseId: toolUseId,
            notificationType: nil,
            message: nil
        )
    }
}
