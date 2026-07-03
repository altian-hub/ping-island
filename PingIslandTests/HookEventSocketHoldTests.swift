import XCTest
@testable import Ping_Island

/// Covers `HookEvent.shouldHoldHookSocket` — the gate that decides whether the
/// hook socket is held awaiting a decision (bridge's blocking read() hangs the
/// calling CLI hook while held) or closed notify-only so the client's own UI
/// (e.g. native Claude Code's AskUserQuestion picker) can render.
final class HookEventSocketHoldTests: XCTestCase {
    // MARK: - shouldHoldHookSocket

    func testPermissionRequestQuestionTrustsBridgeNotifyOnly() {
        // Auto/acceptEdits mode: the question arrives via the PermissionRequest
        // phase. The bridge says notify-only (false); holding the socket here
        // hangs the CLI hook forever, since auto-approve exempts questions and
        // nobody else answers. Regression test for 990a6e5.
        let event = makeEvent(
            event: "PermissionRequest",
            status: "waiting_for_approval",
            tool: "AskUserQuestion"
        )
        XCTAssertFalse(event.shouldHoldHookSocket(bridgeExpectsResponse: false))
    }

    func testPreToolUseQuestionTrustsBridgeNotifyOnly() {
        // Default mode: native Claude renders its own picker; the bridge says
        // false and the heuristic's PreToolUse question clause must not override.
        let event = makeEvent(
            event: "PreToolUse",
            status: "waiting_for_input",
            tool: "AskUserQuestion"
        )
        XCTAssertFalse(event.shouldHoldHookSocket(bridgeExpectsResponse: false))
    }

    func testQuestionClaimedByBridgeIsStillHeld() {
        // Wrapper clients without a native picker (e.g. qoderwork) have the
        // bridge claim the answer: expectsResponse=true keeps the socket held.
        let event = makeEvent(
            event: "PermissionRequest",
            status: "waiting_for_input",
            tool: "AskUserQuestion"
        )
        XCTAssertTrue(event.shouldHoldHookSocket(bridgeExpectsResponse: true))
    }

    func testFollowupQuestionMatchesTheSamePredicate() {
        // ask_followup_question is in questionToolNames — same notify-only
        // treatment, in any phase.
        let event = makeEvent(
            event: "PermissionRequest",
            status: "waiting_for_approval",
            tool: "ask_followup_question"
        )
        XCTAssertFalse(event.shouldHoldHookSocket(bridgeExpectsResponse: false))
    }

    func testRealPermissionStillHeldByHeuristicFallback() {
        // Non-question PermissionRequest: the heuristic OR stays load-bearing
        // for envelopes whose bridge didn't claim a response.
        let event = makeEvent(
            event: "PermissionRequest",
            status: "waiting_for_approval",
            tool: "Bash",
            toolInput: ["command": AnyCodable("ls")]
        )
        XCTAssertTrue(event.shouldHoldHookSocket(bridgeExpectsResponse: false))
    }

    func testOrdinaryPreToolUseIsNotHeld() {
        let event = makeEvent(
            event: "PreToolUse",
            status: "running_tool",
            tool: "Bash",
            toolInput: ["command": AnyCodable("ls")]
        )
        XCTAssertFalse(event.shouldHoldHookSocket(bridgeExpectsResponse: false))
    }

    // MARK: - questionToolNames parity (app vs bridge)

    func testQuestionToolNameSetsMatchBetweenAppAndBridge() throws {
        // The app set (SessionEvent.swift, via targetsQuestionTool) gates whether
        // HookSocketServer TRUSTS the bridge's expectsResponse; the bridge computes
        // that value against its own duplicate set (HookPayloadMapper.swift). The
        // app target does not link IslandShared, so this source-level tripwire is
        // what keeps the two in sync: a question tool name present on one side
        // only re-creates the auto-mode CLI socket-hang.
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // PingIslandTests/
            .deletingLastPathComponent() // repo root
        let appSet = try questionToolNames(
            inSourceAt: repoRoot.appendingPathComponent("PingIsland/Models/SessionEvent.swift")
        )
        let bridgeSet = try questionToolNames(
            inSourceAt: repoRoot.appendingPathComponent("Prototype/Sources/IslandShared/HookPayloadMapper.swift")
        )
        XCTAssertFalse(appSet.isEmpty, "parsed an empty questionToolNames set — parser or declaration moved")
        XCTAssertEqual(
            appSet,
            bridgeSet,
            "app and bridge questionToolNames diverged — a name missing on the app side re-creates the PermissionRequest socket-hang (see HookEvent.shouldHoldHookSocket)"
        )
    }

    private func questionToolNames(inSourceAt url: URL) throws -> Set<String> {
        let source = try String(contentsOf: url, encoding: .utf8)
        guard let declRange = source.range(of: "questionToolNames: Set<String> = ["),
              let closeRange = source.range(of: "]", range: declRange.upperBound..<source.endIndex) else {
            XCTFail("could not locate the questionToolNames declaration in \(url.lastPathComponent) — update this parser alongside the declaration")
            return []
        }
        let body = source[declRange.upperBound..<closeRange.lowerBound]
        let names = body
            .components(separatedBy: "\"")
            .enumerated()
            .filter { $0.offset % 2 == 1 } // odd segments sit inside quotes
            .map(\.element)
        return Set(names)
    }

    private func makeEvent(
        event: String,
        status: String,
        tool: String?,
        toolInput: [String: AnyCodable]? = nil
    ) -> HookEvent {
        HookEvent(
            sessionId: "socket-hold-test",
            cwd: "/tmp/project",
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
            tool: tool,
            toolInput: toolInput ?? [
                "questions": AnyCodable([
                    [
                        "id": "q",
                        "question": "which?",
                        "options": [["label": "A"], ["label": "B"]]
                    ]
                ])
            ],
            toolUseId: "toolu_socket-hold-test",
            notificationType: nil,
            message: nil
        )
    }
}
