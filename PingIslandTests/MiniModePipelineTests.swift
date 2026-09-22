import Foundation
import XCTest
@testable import Ping_Island

/// End-to-end-ish check that a Claude PermissionRequest arriving over the hook
/// socket actually reaches the mini surface: it must survive `SessionStore`
/// ingestion, the primary-UI visibility filter, and `MiniPromptPresenter`.
final class MiniModePipelineTests: XCTestCase {

    private var transcriptURL: URL!

    override func setUpWithError() throws {
        transcriptURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("mini-pipeline-\(UUID().uuidString).jsonl")
        try #"{"type":"user","message":{"role":"user","content":"hi"}}"#
            .write(to: transcriptURL, atomically: true, encoding: .utf8)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: transcriptURL)
    }

    func testClaudePermissionRequestBecomesAMiniPrompt() async throws {
        let sessionId = "mini-pipeline-\(UUID().uuidString)"
        let event = permissionRequest(sessionId: sessionId)

        await SessionStore.shared.process(.hookReceived(event))

        let session = await SessionStore.shared.session(for: sessionId)
        let resolved = try XCTUnwrap(session, "hook event did not create a session")

        XCTAssertTrue(
            resolved.phase.isWaitingForApproval,
            "expected waitingForApproval, got \(resolved.phase)"
        )
        XCTAssertFalse(
            resolved.shouldHideFromPrimaryUI,
            "session was hidden from the primary UI, so no surface can render it"
        )
        XCTAssertTrue(
            MiniPromptPresenter.isPrompting(resolved),
            "session reached the UI but the mini presenter did not treat it as a prompt"
        )

        await SessionStore.shared.process(.sessionArchived(sessionId: sessionId))
    }

    // MARK: - Helpers

    private func permissionRequest(sessionId: String) -> HookEvent {
        HookEvent(
            sessionId: sessionId,
            cwd: "/Users/altian/ping-island",
            event: "PermissionRequest",
            status: "waiting_for_approval",
            provider: .claude,
            clientInfo: SessionClientInfo(
                kind: .claudeCode,
                profileID: "claude",
                name: "Claude",
                sessionFilePath: transcriptURL.path
            ),
            pid: nil,
            tty: nil,
            tool: "Bash",
            toolInput: ["command": AnyCodable("echo 'mini mode works'")],
            toolUseId: "toolu_mini_pipeline",
            notificationType: nil,
            message: "Mini mode smoke test",
            ingress: .hookBridge
        )
    }
}
