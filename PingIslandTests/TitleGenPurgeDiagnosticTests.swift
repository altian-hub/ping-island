import XCTest
@testable import Ping_Island

/// Deterministic check that the runtime memory fix actually fires: a Claude
/// title-gen helper session must be PURGED from the store (not merely hidden)
/// once its transcript is parsed, while an ordinary session is retained.
/// This isolates the parse-time purge from the noisy live-RSS measurement.
final class TitleGenPurgeDiagnosticTests: XCTestCase {

    func testTitleGenSessionIsPurgedFromStore() async throws {
        let store = SessionStore.shared
        let sessionId = "tgpurge-\(UUID().uuidString)"
        let path = NSTemporaryDirectory() + "ping-island-tg-\(sessionId).jsonl"
        defer { try? FileManager.default.removeItem(atPath: path) }

        let titleGen = "In 4-6 words, plain text only with no quotes or punctuation, "
            + "write a session title that captures: '/tmp/x.swift'"
        let line = "{\"type\":\"user\",\"uuid\":\"u1\",\"message\":{\"role\":\"user\",\"content\":\"\(titleGen)\"}}\n"
        try line.write(toFile: path, atomically: true, encoding: .utf8)

        // SessionStart does not trigger an async file sync, so the session is
        // created deterministically without a racing parse.
        await store.process(.hookReceived(makeEvent(sessionId: sessionId, path: path, event: "SessionStart")))
        let created = await store.session(for: sessionId)
        XCTAssertNotNil(created, "precondition: session should be created by SessionStart")

        // Drive the file-update path; processFileUpdate parses the (title-gen)
        // transcript and must purge the session.
        await store.process(.fileUpdated(FileUpdatePayload(
            sessionId: sessionId,
            cwd: "/tmp",
            messages: [],
            isIncremental: true,
            completedToolIds: [],
            toolResults: [:],
            structuredResults: [:]
        )))

        let after = await store.session(for: sessionId)
        XCTAssertNil(after, "title-gen helper must be purged from the store, not retained")
    }

    func testOrdinarySessionIsRetained() async throws {
        let store = SessionStore.shared
        let sessionId = "tgkeep-\(UUID().uuidString)"
        let path = NSTemporaryDirectory() + "ping-island-norm-\(sessionId).jsonl"
        defer { try? FileManager.default.removeItem(atPath: path) }

        let line = "{\"type\":\"user\",\"uuid\":\"u1\",\"message\":{\"role\":\"user\",\"content\":\"refactor the display clock module please\"}}\n"
        try line.write(toFile: path, atomically: true, encoding: .utf8)

        await store.process(.hookReceived(makeEvent(sessionId: sessionId, path: path, event: "SessionStart")))
        await store.process(.fileUpdated(FileUpdatePayload(
            sessionId: sessionId,
            cwd: "/tmp",
            messages: [],
            isIncremental: true,
            completedToolIds: [],
            toolResults: [:],
            structuredResults: [:]
        )))

        let after = await store.session(for: sessionId)
        XCTAssertNotNil(after, "ordinary session must NOT be purged")

        await store.process(.sessionArchived(sessionId: sessionId))
    }

    private func makeEvent(sessionId: String, path: String, event: String) -> HookEvent {
        HookEvent(
            sessionId: sessionId,
            cwd: "/tmp",
            event: event,
            status: "waiting_for_input",
            provider: .claude,
            clientInfo: SessionClientInfo(
                kind: .claudeCode,
                profileID: "claude_code",
                name: "Claude Code",
                bundleIdentifier: "com.anthropic.claudecode",
                sessionFilePath: path
            ),
            pid: nil,
            tty: nil,
            tool: nil,
            toolInput: nil,
            toolUseId: nil,
            notificationType: nil,
            message: "hello"
        )
    }
}
