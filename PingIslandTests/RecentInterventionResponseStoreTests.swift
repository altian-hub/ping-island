import Foundation
import XCTest
@testable import Ping_Island

final class RecentInterventionResponseStoreTests: XCTestCase {
    func testQoderWorkAnswerCanBeReplayedForDuplicatePermissionRequest() {
        var store = RecentInterventionResponseStore(ttl: 30)

        let preToolEvent = HookEvent(
            sessionId: "qoderwork-session",
            cwd: "/tmp/project",
            event: "PreToolUse",
            status: "waiting_for_input",
            provider: .claude,
            clientInfo: SessionClientInfo(
                kind: .qoder,
                profileID: "qoderwork",
                name: "QoderWork",
                bundleIdentifier: "com.qoder.work"
            ),
            pid: nil,
            tty: nil,
            tool: "AskUserQuestion",
            toolInput: [
                "questions": AnyCodable([
                    [
                        "id": "drink",
                        "header": "偏好",
                        "question": "你更喜欢喝什么？",
                        "options": [
                            ["label": "绿茶"],
                            ["label": "咖啡"]
                        ]
                    ]
                ])
            ],
            toolUseId: "call_123",
            notificationType: nil,
            message: nil
        )

        let permissionEvent = HookEvent(
            sessionId: "qoderwork-session",
            cwd: "/tmp/project",
            event: "PermissionRequest",
            status: "waiting_for_input",
            provider: .claude,
            clientInfo: SessionClientInfo(
                kind: .qoder,
                profileID: "qoderwork",
                name: "QoderWork",
                bundleIdentifier: "com.qoder.work"
            ),
            pid: nil,
            tty: nil,
            tool: "AskUserQuestion",
            toolInput: [
                "questions": AnyCodable([
                    [
                        "id": "drink",
                        "header": "偏好",
                        "question": "你更喜欢喝什么？",
                        "multiSelect": false,
                        "options": [
                            ["label": "绿茶"],
                            ["label": "咖啡"]
                        ]
                    ]
                ])
            ],
            toolUseId: nil,
            notificationType: nil,
            message: nil
        )

        store.record(
            event: preToolEvent,
            decision: "answer",
            reason: nil,
            updatedInput: [
                "answers": AnyCodable(["drink": "绿茶"])
            ],
            now: Date(timeIntervalSince1970: 100)
        )

        let replay = store.response(
            for: permissionEvent,
            now: Date(timeIntervalSince1970: 105)
        )

        XCTAssertEqual(replay?.decision, "answer")
        XCTAssertEqual(replay?.updatedInput?["answers"]?.value as? [String: String], ["drink": "绿茶"])
    }

    func testRecordedAnswerExpiresAfterTTL() {
        var store = RecentInterventionResponseStore(ttl: 5)

        let event = HookEvent(
            sessionId: "qoderwork-session",
            cwd: "/tmp/project",
            event: "PreToolUse",
            status: "waiting_for_input",
            provider: .claude,
            clientInfo: SessionClientInfo(
                kind: .qoder,
                profileID: "qoderwork",
                name: "QoderWork",
                bundleIdentifier: "com.qoder.work"
            ),
            pid: nil,
            tty: nil,
            tool: "AskUserQuestion",
            toolInput: [
                "questions": AnyCodable([
                    [
                        "id": "drink",
                        "header": "偏好",
                        "question": "你更喜欢喝什么？"
                    ]
                ])
            ],
            toolUseId: "call_123",
            notificationType: nil,
            message: nil
        )

        store.record(
            event: event,
            decision: "answer",
            reason: nil,
            updatedInput: ["answers": AnyCodable(["drink": "绿茶"])],
            now: Date(timeIntervalSince1970: 100)
        )

        XCTAssertNil(store.response(for: event, now: Date(timeIntervalSince1970: 106)))
    }

    func testPlainClaudeQuestionAnswersAreNeitherRecordedNorReplayed() {
        // Plain-Claude question sockets are never held (notify-only so the native
        // CLI picker renders — see HookEvent.shouldHoldHookSocket), so recording or
        // replaying answers for them is dead weight; replaying onto a duplicate
        // PermissionRequest would re-suppress the native picker. Only qoderwork's
        // held-and-answered question flow uses the store.
        var store = RecentInterventionResponseStore(ttl: 30)

        let questionEvent = HookEvent(
            sessionId: "claude-session",
            cwd: "/tmp/project",
            event: "PreToolUse",
            status: "waiting_for_input",
            provider: .claude,
            clientInfo: SessionClientInfo(
                kind: .claudeCode,
                profileID: "claude_code",
                name: "Claude Code",
                bundleIdentifier: "com.anthropic.claudecode"
            ),
            pid: nil,
            tty: nil,
            tool: "AskUserQuestion",
            toolInput: [
                "questions": AnyCodable([
                    [
                        "id": "project",
                        "header": "方向",
                        "question": "你想先处理哪个模块？",
                        "options": [
                            ["label": "会话层"],
                            ["label": "UI 层"]
                        ]
                    ]
                ])
            ],
            toolUseId: "toolu_123",
            notificationType: nil,
            message: nil
        )

        let duplicatePermissionEvent = HookEvent(
            sessionId: "claude-session",
            cwd: "/tmp/project",
            event: "PermissionRequest",
            status: "waiting_for_approval",
            provider: .claude,
            clientInfo: SessionClientInfo(
                kind: .claudeCode,
                profileID: "claude_code",
                name: "Claude Code",
                bundleIdentifier: "com.anthropic.claudecode"
            ),
            pid: nil,
            tty: nil,
            tool: "AskUserQuestion",
            toolInput: [
                "questions": AnyCodable([
                    [
                        "id": "project",
                        "header": "方向",
                        "question": "你想先处理哪个模块？",
                        "options": [
                            ["label": "会话层"],
                            ["label": "UI 层"]
                        ]
                    ]
                ])
            ],
            toolUseId: "toolu_123",
            notificationType: nil,
            message: nil
        )

        store.record(
            event: questionEvent,
            decision: "answer",
            reason: nil,
            updatedInput: [
                "answers": AnyCodable(["project": "会话层"])
            ],
            now: Date(timeIntervalSince1970: 100)
        )

        let replay = store.response(
            for: duplicatePermissionEvent,
            now: Date(timeIntervalSince1970: 101)
        )

        XCTAssertNil(replay, "plain-Claude question answers must not be recorded or replayed — a replayed answer onto a PermissionRequest suppresses the native CLI picker")
        XCTAssertNil(RecentInterventionResponseStore.cacheKey(for: questionEvent))
    }
}
