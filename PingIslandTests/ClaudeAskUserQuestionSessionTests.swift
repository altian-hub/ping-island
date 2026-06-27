import XCTest
@testable import Ping_Island

final class ClaudeAskUserQuestionSessionTests: XCTestCase {
    func testToolResultContainingClearMarkerDoesNotWipeTranscriptState() async throws {
        // A tool_result whose content merely *contains* the literal
        // "<command-name>/clear</command-name>" marker (e.g. displaying this
        // parser's own source) must NOT be treated as a /clear and wipe the
        // session's parsed history + completedToolIds.
        let sessionId = "clearfp-\(UUID().uuidString)"
        let path = NSTemporaryDirectory() + "ping-island-\(sessionId).jsonl"
        defer { try? FileManager.default.removeItem(atPath: path) }

        let askLine = "{\"type\":\"assistant\",\"uuid\":\"a1\",\"message\":{\"role\":\"assistant\",\"content\":[{\"type\":\"tool_use\",\"id\":\"toolu_\(sessionId)\",\"name\":\"AskUserQuestion\",\"input\":{\"questions\":[]}}]}}\n"
        let answerLine = "{\"type\":\"user\",\"uuid\":\"u1\",\"message\":{\"role\":\"user\",\"content\":[{\"type\":\"tool_result\",\"tool_use_id\":\"toolu_\(sessionId)\",\"content\":\"answered\"}]}}\n"
        // tool_result whose content embeds the /clear marker (JSON-escaped).
        let markerContent = "if line.contains(\\\"<command-name>/clear</command-name>\\\") { wipe }"
        let codeDumpLine = "{\"type\":\"user\",\"uuid\":\"u2\",\"message\":{\"role\":\"user\",\"content\":[{\"type\":\"tool_result\",\"tool_use_id\":\"toolu_other\",\"content\":\"\(markerContent)\"}]}}\n"
        try (askLine + answerLine + codeDumpLine).write(toFile: path, atomically: true, encoding: .utf8)

        let result = await ConversationParser.shared.parseIncremental(sessionId: sessionId, cwd: "/tmp", explicitFilePath: path)
        XCTAssertFalse(result.clearDetected, "a tool_result containing the /clear marker must not be detected as a clear")
        XCTAssertTrue(result.completedToolIds.contains("toolu_\(sessionId)"), "the answered tool must survive — state must not be wiped")

        await ConversationParser.shared.resetState(for: sessionId)
    }

    func testGenuineClearCommandStillWipesTranscriptState() async throws {
        let sessionId = "clearreal-\(UUID().uuidString)"
        let path = NSTemporaryDirectory() + "ping-island-\(sessionId).jsonl"
        defer { try? FileManager.default.removeItem(atPath: path) }

        let askLine = "{\"type\":\"assistant\",\"uuid\":\"a1\",\"message\":{\"role\":\"assistant\",\"content\":[{\"type\":\"tool_use\",\"id\":\"toolu_\(sessionId)\",\"name\":\"AskUserQuestion\",\"input\":{\"questions\":[]}}]}}\n"
        let answerLine = "{\"type\":\"user\",\"uuid\":\"u1\",\"message\":{\"role\":\"user\",\"content\":[{\"type\":\"tool_result\",\"tool_use_id\":\"toolu_\(sessionId)\",\"content\":\"answered\"}]}}\n"
        try (askLine + answerLine).write(toFile: path, atomically: true, encoding: .utf8)
        _ = await ConversationParser.shared.parseIncremental(sessionId: sessionId, cwd: "/tmp", explicitFilePath: path)

        // A real /clear: a user message whose content is a STRING command.
        let clearLine = "{\"type\":\"user\",\"uuid\":\"u2\",\"message\":{\"role\":\"user\",\"content\":\"<command-name>/clear</command-name>\"}}\n"
        let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
        try handle.seekToEnd(); try handle.write(contentsOf: Data(clearLine.utf8)); try handle.close()

        let result = await ConversationParser.shared.parseIncremental(sessionId: sessionId, cwd: "/tmp", explicitFilePath: path)
        XCTAssertTrue(result.clearDetected, "a genuine /clear command must still be detected")
        XCTAssertTrue(result.completedToolIds.isEmpty, "a genuine /clear must wipe prior state")

        await ConversationParser.shared.resetState(for: sessionId)
    }

    func testClearDetectedDropsPendingClaudeQuestion() async {
        let sessionId = "clearq-\(UUID().uuidString)"
        let store = SessionStore.shared
        await loadSynthesizedClaudeQuestion(store: store, sessionId: sessionId)
        let pending = await store.session(for: sessionId)
        XCTAssertEqual(pending?.intervention?.kind, .question)

        await store.process(.clearDetected(sessionId: sessionId))

        let session = await store.session(for: sessionId)
        XCTAssertNil(session?.intervention)
        XCTAssertNotEqual(session?.phase, .waitingForInput)

        await store.process(.sessionArchived(sessionId: sessionId))
    }

    func testPreToolUseQuestionImmediatelyEntersWaitingForInput() async {
        let sessionId = "claude-question-\(UUID().uuidString)"
        let store = SessionStore.shared

        await store.process(.hookReceived(makeClaudeQuestionEvent(sessionId: sessionId)))

        let session = await store.session(for: sessionId)
        XCTAssertEqual(session?.phase, .waitingForInput)
        XCTAssertEqual(session?.intervention?.kind, .question)
        XCTAssertEqual(session?.intervention?.resolvedQuestions.first?.options.map(\.title), ["会话层", "UI 层"])
        XCTAssertTrue(session?.intervention?.resolvedQuestions.first?.allowsOther ?? false)
        // Claude questions surface in the island (kind == .question, blue) but are
        // answered in the CLI — no inline option selection inside the island.
        XCTAssertEqual(session?.intervention?.metadata["responseMode"], "external_only")
        XCTAssertFalse(session?.intervention?.supportsInlineResponse ?? true)

        await store.process(.sessionArchived(sessionId: sessionId))
    }

    func testDuplicatePermissionRequestKeepsClaudeQuestionInWaitingForInput() async {
        let sessionId = "claude-ask-\(UUID().uuidString)"
        let store = SessionStore.shared

        await store.process(.hookReceived(makeClaudeQuestionEvent(sessionId: sessionId)))
        await store.process(.hookReceived(makeClaudePermissionRequest(sessionId: sessionId)))

        let session = await store.session(for: sessionId)
        XCTAssertEqual(session?.phase, .waitingForInput)
        XCTAssertEqual(session?.intervention?.kind, .question)
        XCTAssertNil(session?.activePermission)
        XCTAssertFalse(session?.needsApprovalResponse ?? true)

        await store.process(.sessionArchived(sessionId: sessionId))
    }

    func testDuplicatePermissionRequestDoesNotRestoreApprovalAfterAnswer() async {
        let sessionId = "claude-answer-\(UUID().uuidString)"
        let store = SessionStore.shared

        await store.process(.hookReceived(makeClaudeQuestionEvent(sessionId: sessionId)))
        await store.process(
            .interventionResolved(
                sessionId: sessionId,
                nextPhase: .processing,
                submittedAnswers: ["project": ["会话层"]]
            )
        )
        await store.process(.hookReceived(makeClaudePermissionRequest(sessionId: sessionId)))

        let session = await store.session(for: sessionId)
        XCTAssertEqual(session?.phase, .processing)
        XCTAssertNil(session?.intervention)
        XCTAssertNil(session?.activePermission)

        await store.process(.sessionArchived(sessionId: sessionId))
    }

    func testQoderWorkPermissionRequestIsNotIgnoredAsClaudeDuplicate() async {
        let sessionId = "qoderwork-permission-\(UUID().uuidString)"
        let store = SessionStore.shared

        await store.process(.hookReceived(makeQoderWorkPermissionRequest(sessionId: sessionId)))

        let session = await store.session(for: sessionId)
        XCTAssertEqual(session?.intervention?.kind, .question)
        XCTAssertEqual(session?.phase, .waitingForInput)
        XCTAssertFalse(session?.needsApprovalResponse ?? true)

        await store.process(.sessionArchived(sessionId: sessionId))
    }

    func testHistoryLoadedQuestionToolSynthesizesClaudeIntervention() async {
        let sessionId = "claude-history-\(UUID().uuidString)"
        let store = SessionStore.shared

        await store.process(.hookReceived(makeClaudePromptSubmitEvent(sessionId: sessionId)))
        await store.process(
            .historyLoaded(
                sessionId: sessionId,
                messages: [
                    ChatMessage(
                        id: "assistant-tool-message",
                        role: .assistant,
                        timestamp: Date(),
                        content: [
                            .toolUse(
                                ToolUseBlock(
                                    id: "toolu_\(sessionId)",
                                    name: "AskUserQuestion",
                                    input: [
                                        "questions": """
                                        [
                                          {
                                            "id":"project",
                                            "header":"方向",
                                            "question":"你想先处理哪个模块？",
                                            "options":[
                                              {"label":"会话层"},
                                              {"label":"UI 层"}
                                            ]
                                          }
                                        ]
                                        """
                                    ]
                                )
                            )
                        ]
                    )
                ],
                completedTools: [],
                toolResults: [:],
                structuredResults: [:],
                conversationInfo: ConversationInfo(
                    summary: nil,
                    lastMessage: nil,
                    lastMessageRole: nil,
                    lastToolName: nil,
                    firstUserMessage: "使用工具问我一个问题",
                    lastUserMessageDate: Date()
                )
            )
        )

        let session = await store.session(for: sessionId)
        XCTAssertEqual(session?.phase, .waitingForInput)
        XCTAssertEqual(session?.intervention?.kind, .question)
        XCTAssertEqual(session?.intervention?.resolvedQuestions.first?.prompt, "你想先处理哪个模块？")
        XCTAssertEqual(session?.intervention?.resolvedQuestions.first?.options.map(\.title), ["会话层", "UI 层"])
        XCTAssertTrue(session?.intervention?.resolvedQuestions.first?.allowsOther ?? false)
        // Transcript-synthesized Claude questions are likewise CLI-answered only.
        XCTAssertEqual(session?.intervention?.metadata["responseMode"], "external_only")
        XCTAssertFalse(session?.intervention?.supportsInlineResponse ?? true)

        await store.process(.sessionArchived(sessionId: sessionId))
    }

    func testRemoteBridgeHistoryLoadedQuestionToolDoesNotSynthesizesClaudeTranscriptIntervention() async {
        let sessionId = "claude-remote-history-\(UUID().uuidString)"
        let store = SessionStore.shared

        await store.process(.hookReceived(makeRemoteClaudePromptSubmitEvent(sessionId: sessionId)))
        await store.process(
            .historyLoaded(
                sessionId: sessionId,
                messages: [
                    ChatMessage(
                        id: "assistant-tool-message",
                        role: .assistant,
                        timestamp: Date(),
                        content: [
                            .toolUse(
                                ToolUseBlock(
                                    id: "toolu_\(sessionId)",
                                    name: "AskUserQuestion",
                                    input: [
                                        "questions": """
                                        [
                                          {
                                            "id":"project",
                                            "header":"方向",
                                            "question":"你想先处理哪个模块？",
                                            "options":[
                                              {"label":"会话层"},
                                              {"label":"UI 层"}
                                            ]
                                          }
                                        ]
                                        """
                                    ]
                                )
                            )
                        ]
                    )
                ],
                completedTools: [],
                toolResults: [:],
                structuredResults: [:],
                conversationInfo: ConversationInfo(
                    summary: nil,
                    lastMessage: nil,
                    lastMessageRole: nil,
                    lastToolName: nil,
                    firstUserMessage: "使用工具问我一个问题",
                    lastUserMessageDate: Date()
                )
            )
        )

        let session = await store.session(for: sessionId)
        XCTAssertNil(session?.intervention)
        XCTAssertNotEqual(session?.phase, .waitingForInput)

        await store.process(.sessionArchived(sessionId: sessionId))
    }

    func testAnsweredQuestionToolCompletionClearsClaudeQuestionIntervention() async {
        let sessionId = "claude-answered-\(UUID().uuidString)"
        let store = SessionStore.shared
        await loadSynthesizedClaudeQuestion(store: store, sessionId: sessionId)

        // Precondition: the question is surfaced and the session is waiting.
        var session = await store.session(for: sessionId)
        XCTAssertEqual(session?.intervention?.kind, .question)
        XCTAssertEqual(session?.phase, .waitingForInput)

        // The user answered in the CLI, so the AskUserQuestion tool now has a
        // result. That completion must clear the now-stale question intervention.
        await store.process(
            .toolCompleted(
                sessionId: sessionId,
                toolUseId: "toolu_\(sessionId)",
                result: ToolCompletionResult(status: .success, result: nil, structuredResult: nil)
            )
        )

        session = await store.session(for: sessionId)
        XCTAssertNil(session?.intervention)
        XCTAssertNotEqual(session?.phase, .waitingForInput)

        await store.process(.sessionArchived(sessionId: sessionId))
    }

    func testFileUpdateWithOnlyCompletedToolClearsClaudeQuestionIntervention() async {
        let sessionId = "claude-fileupdate-\(UUID().uuidString)"
        let store = SessionStore.shared
        await loadSynthesizedClaudeQuestion(store: store, sessionId: sessionId)

        let pending = await store.session(for: sessionId)
        XCTAssertEqual(pending?.intervention?.kind, .question)

        // A tail append can carry only the AskUserQuestion's tool_result: no new
        // chat messages, just a newly-completed tool id. The intervention must
        // still clear instead of lingering as a phantom "answer in the CLI" prompt.
        await store.process(
            .fileUpdated(
                FileUpdatePayload(
                    sessionId: sessionId,
                    cwd: "/tmp/project",
                    messages: [],
                    isIncremental: true,
                    completedToolIds: ["toolu_\(sessionId)"],
                    toolResults: [:],
                    structuredResults: [:]
                )
            )
        )

        let session = await store.session(for: sessionId)
        XCTAssertNil(session?.intervention)
        XCTAssertNotEqual(session?.phase, .waitingForInput)

        await store.process(.sessionArchived(sessionId: sessionId))
    }

    func testToolResultOnlyAppendSurfacesNewlyCompletedToolIds() async throws {
        let sessionId = "parser-\(UUID().uuidString)"
        let path = NSTemporaryDirectory() + "ping-island-\(sessionId).jsonl"
        defer { try? FileManager.default.removeItem(atPath: path) }

        let toolUseLine = "{\"type\":\"assistant\",\"uuid\":\"a1\",\"message\":{\"role\":\"assistant\",\"content\":[{\"type\":\"tool_use\",\"id\":\"toolu_\(sessionId)\",\"name\":\"AskUserQuestion\",\"input\":{\"questions\":[]}}]}}\n"
        try toolUseLine.write(toFile: path, atomically: true, encoding: .utf8)

        let first = await ConversationParser.shared.parseIncremental(
            sessionId: sessionId,
            cwd: "/tmp",
            explicitFilePath: path
        )
        XCTAssertTrue(first.newlyCompletedToolIds.isEmpty)

        // Append only the tool_result line (the user answered in the CLI).
        let toolResultLine = "{\"type\":\"user\",\"uuid\":\"u1\",\"message\":{\"role\":\"user\",\"content\":[{\"type\":\"tool_result\",\"tool_use_id\":\"toolu_\(sessionId)\",\"content\":\"answered\"}]}}\n"
        let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(toolResultLine.utf8))
        try handle.close()

        let second = await ConversationParser.shared.parseIncremental(
            sessionId: sessionId,
            cwd: "/tmp",
            explicitFilePath: path
        )
        // A tool_result line never becomes a chat message, so without the
        // newlyCompletedToolIds signal the file-sync guard would drop this update.
        XCTAssertTrue(second.newMessages.isEmpty)
        XCTAssertTrue(second.newlyCompletedToolIds.contains("toolu_\(sessionId)"))

        await ConversationParser.shared.resetState(for: sessionId)
    }

    func testHistoryLoadedAnsweredQuestionDoesNotSurfaceStaleIntervention() async {
        // Reproduces the app launching mid-session (or relaunching) when an
        // AskUserQuestion was already answered in the CLI before the app started
        // observing it: the completed tool is in completedTools, so no stale
        // "answer in the CLI" question may be reconstructed from history.
        let sessionId = "claude-history-answered-\(UUID().uuidString)"
        let store = SessionStore.shared
        await loadSynthesizedClaudeQuestion(
            store: store,
            sessionId: sessionId,
            completedTools: ["toolu_\(sessionId)"]
        )

        let session = await store.session(for: sessionId)
        XCTAssertNil(session?.intervention)
        XCTAssertNotEqual(session?.phase, .waitingForInput)

        await store.process(.sessionArchived(sessionId: sessionId))
    }

    private func loadSynthesizedClaudeQuestion(
        store: SessionStore,
        sessionId: String,
        completedTools: Set<String> = []
    ) async {
        await store.process(.hookReceived(makeClaudePromptSubmitEvent(sessionId: sessionId)))
        await store.process(
            .historyLoaded(
                sessionId: sessionId,
                messages: [
                    ChatMessage(
                        id: "assistant-tool-message",
                        role: .assistant,
                        timestamp: Date(),
                        content: [
                            .toolUse(
                                ToolUseBlock(
                                    id: "toolu_\(sessionId)",
                                    name: "AskUserQuestion",
                                    input: [
                                        "questions": """
                                        [
                                          {
                                            "id":"project",
                                            "header":"方向",
                                            "question":"你想先处理哪个模块？",
                                            "options":[
                                              {"label":"会话层"},
                                              {"label":"UI 层"}
                                            ]
                                          }
                                        ]
                                        """
                                    ]
                                )
                            )
                        ]
                    )
                ],
                completedTools: completedTools,
                toolResults: [:],
                structuredResults: [:],
                conversationInfo: ConversationInfo(
                    summary: nil,
                    lastMessage: nil,
                    lastMessageRole: nil,
                    lastToolName: nil,
                    firstUserMessage: "使用工具问我一个问题",
                    lastUserMessageDate: Date()
                )
            )
        )
    }

    private func makeClaudeQuestionEvent(sessionId: String) -> HookEvent {
        HookEvent(
            sessionId: sessionId,
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
            toolUseId: "toolu_\(sessionId)",
            notificationType: nil,
            message: nil
        )
    }

    private func makeClaudePermissionRequest(sessionId: String) -> HookEvent {
        HookEvent(
            sessionId: sessionId,
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
            toolUseId: "toolu_\(sessionId)",
            notificationType: nil,
            message: nil
        )
    }

    private func makeQoderWorkPermissionRequest(sessionId: String) -> HookEvent {
        HookEvent(
            sessionId: sessionId,
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
                        "id": "topic",
                        "header": "主题",
                        "question": "先选一个主题",
                        "options": [
                            ["label": "A 方案"],
                            ["label": "B 方案"]
                        ]
                    ]
                ])
            ],
            toolUseId: nil,
            notificationType: nil,
            message: nil
        )
    }

    private func makeClaudePromptSubmitEvent(sessionId: String) -> HookEvent {
        HookEvent(
            sessionId: sessionId,
            cwd: "/tmp/project",
            event: "UserPromptSubmit",
            status: "processing",
            provider: .claude,
            clientInfo: SessionClientInfo(
                kind: .claudeCode,
                profileID: "claude_code",
                name: "Claude Code",
                bundleIdentifier: "com.anthropic.claudecode",
                sessionFilePath: "/tmp/\(sessionId).jsonl"
            ),
            pid: nil,
            tty: nil,
            tool: nil,
            toolInput: nil,
            toolUseId: nil,
            notificationType: nil,
            message: "使用工具问我一个问题"
        )
    }

    private func makeRemoteClaudePromptSubmitEvent(sessionId: String) -> HookEvent {
        HookEvent(
            sessionId: sessionId,
            cwd: "/tmp/project",
            event: "UserPromptSubmit",
            status: "processing",
            provider: .claude,
            clientInfo: SessionClientInfo(
                kind: .claudeCode,
                profileID: "claude_code",
                name: "Claude Code",
                bundleIdentifier: "com.anthropic.claudecode",
                remoteHost: "remote.example",
                sessionFilePath: "/tmp/\(sessionId).jsonl"
            ),
            pid: nil,
            tty: nil,
            tool: nil,
            toolInput: nil,
            toolUseId: nil,
            notificationType: nil,
            message: "使用工具问我一个问题",
            ingress: .remoteBridge
        )
    }
}
