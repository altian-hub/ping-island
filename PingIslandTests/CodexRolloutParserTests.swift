import Foundation
import XCTest
@testable import Ping_Island

final class CodexRolloutParserTests: XCTestCase {
    func testRolloutParserPreservesTerminalHostedCodexCLIContext() async throws {
        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        let threadId = "019d77a9-b7e4-76d3-996a-adadefcf7a56"
        let rolloutURL = tempDirectory.appendingPathComponent("rollout-\(threadId).jsonl")
        let rollout = """
        {"timestamp":"2026-04-10T13:51:51Z","type":"session_meta","payload":{"id":"\(threadId)","cwd":"/Users/ping-island/github/claude-island","originator":"codex-tui","source":"cli"}}
        {"timestamp":"2026-04-10T13:51:52Z","type":"event_msg","payload":{"type":"user_message","message":"hi"}}
        {"timestamp":"2026-04-10T13:51:57Z","type":"event_msg","payload":{"type":"agent_message","phase":"final","message":"Hi. What do you need help with in this repo?"}}
        """
        try rollout.write(to: rolloutURL, atomically: true, encoding: .utf8)

        let snapshot = await CodexRolloutParser.shared.parseThread(
            threadId: threadId,
            fallbackCwd: "/Users/ping-island/github/claude-island",
            clientInfo: SessionClientInfo(
                kind: .codexCLI,
                profileID: "codex-cli",
                name: "Codex",
                origin: "cli",
                threadSource: "cli",
                sessionFilePath: rolloutURL.path,
                terminalBundleIdentifier: "com.googlecode.iterm2",
                terminalProgram: "iTerm.app",
                terminalSessionIdentifier: "w0t0p0:82B6B83C-9817-47EB-B42B-EDC2AAB96556",
                iTermSessionIdentifier: "w0t0p0:82B6B83C-9817-47EB-B42B-EDC2AAB96556",
                processName: "/Users/ping-island/.nvm/versions/node/v22.21.1/lib/node_modules/@openai/codex/node_modules/@openai/codex-darwin-arm64/vendor/aarch64-apple-darwin/codex/codex"
            )
        )

        let clientInfo = try XCTUnwrap(snapshot?.clientInfo)
        XCTAssertEqual(clientInfo.kind, .codexCLI)
        XCTAssertEqual(clientInfo.origin, "cli")
        XCTAssertEqual(clientInfo.threadSource, "cli")
        XCTAssertEqual(clientInfo.terminalBundleIdentifier, "com.googlecode.iterm2")
        XCTAssertEqual(clientInfo.iTermSessionIdentifier, "w0t0p0:82B6B83C-9817-47EB-B42B-EDC2AAB96556")
        XCTAssertNil(clientInfo.bundleIdentifier)
        XCTAssertNil(clientInfo.launchURL)
    }

    func testRolloutParserInfersPendingMCPApprovalFromUnresolvedToolCall() async throws {
        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        let threadId = "019d7874-9b7a-7533-a757-3fb452609c4d"
        let rolloutURL = tempDirectory.appendingPathComponent("rollout-\(threadId).jsonl")
        let rollout = """
        {"timestamp":"2026-04-10T17:41:27.371Z","type":"session_meta","payload":{"id":"\(threadId)","cwd":"/Users/ping-island/github/CodeIsland","originator":"codex-tui","source":"cli"}}
        {"timestamp":"2026-04-10T17:41:27.371Z","type":"event_msg","payload":{"type":"user_message","message":"删除一下 README 文件"}}
        {"timestamp":"2026-04-10T17:41:40.139Z","type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"仓库根目录里有 `README.md` 和 `README.zh-CN.md` 两个文件；按你的单数表述，我先删除主 README，也就是根目录的 `README.md`。先核对当前状态，再直接改。"}],"phase":"commentary"}}
        {"timestamp":"2026-04-10T17:41:40.151Z","type":"response_item","payload":{"type":"function_call","name":"mcp__omx_state__state_get_status","arguments":"{\\"workingDirectory\\":\\"/Users/ping-island/github/CodeIsland\\"}","call_id":"call_IvTKO1mWarOvCiIBwppVMmyt"}}
        """
        try rollout.write(to: rolloutURL, atomically: true, encoding: .utf8)

        let snapshot = await CodexRolloutParser.shared.parseThread(
            threadId: threadId,
            fallbackCwd: "/Users/ping-island/github/CodeIsland",
            clientInfo: SessionClientInfo(
                kind: .codexCLI,
                profileID: "codex-cli",
                name: "Codex",
                sessionFilePath: rolloutURL.path
            )
        )

        XCTAssertEqual(snapshot?.phase, .waitingForInput)
        XCTAssertEqual(snapshot?.intervention?.title, "MCP Tool Approval Needed")
        XCTAssertEqual(snapshot?.intervention?.metadata["server"], "omx_state")
        XCTAssertEqual(snapshot?.intervention?.metadata["toolName"], "state_get_status")
    }

    func testRolloutParserDoesNotInferPendingMCPApprovalForCodexApp() async throws {
        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        let threadId = "019d7874-9b7a-7533-a757-3fb452609c4d"
        let rolloutURL = tempDirectory.appendingPathComponent("rollout-\(threadId).jsonl")
        let rollout = """
        {"timestamp":"2026-04-10T17:41:27.371Z","type":"session_meta","payload":{"id":"\(threadId)","cwd":"/Users/ping-island/github/CodeIsland","originator":"Codex Desktop","source":"desktop"}}
        {"timestamp":"2026-04-10T17:41:27.371Z","type":"event_msg","payload":{"type":"user_message","message":"删除一下 README 文件"}}
        {"timestamp":"2026-04-10T17:41:40.151Z","type":"response_item","payload":{"type":"function_call","name":"mcp__omx_state__state_get_status","arguments":"{\\"workingDirectory\\":\\"/Users/ping-island/github/CodeIsland\\"}","call_id":"call_IvTKO1mWarOvCiIBwppVMmyt"}}
        """
        try rollout.write(to: rolloutURL, atomically: true, encoding: .utf8)

        let snapshot = await CodexRolloutParser.shared.parseThread(
            threadId: threadId,
            fallbackCwd: "/Users/ping-island/github/CodeIsland",
            clientInfo: SessionClientInfo(
                kind: .codexApp,
                profileID: "codex-app",
                name: "Codex App",
                bundleIdentifier: "com.openai.codex",
                sessionFilePath: rolloutURL.path
            )
        )

        XCTAssertNil(snapshot?.intervention)
        XCTAssertEqual(snapshot?.phase, .processing)
    }

    func testRolloutParserExtractsCodexSubagentMetadataFromSessionMeta() async throws {
        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        let parentThreadId = "019da119-db3a-7532-8355-5ba0ecf56640"
        let threadId = "019da11a-353a-79e3-8a52-5f051d2e00a9"
        let rolloutURL = tempDirectory.appendingPathComponent("rollout-\(threadId).jsonl")
        let rollout = """
        {"timestamp":"2026-04-18T14:59:02Z","type":"session_meta","payload":{"id":"\(threadId)","forked_from_id":"\(parentThreadId)","cwd":"/Users/ping-island/Island","originator":"Codex Desktop","source":{"subagent":{"thread_spawn":{"parent_thread_id":"\(parentThreadId)","depth":1,"agent_nickname":"Kierkegaard","agent_role":"explorer"}}},"agent_nickname":"Kierkegaard","agent_role":"explorer"}}
        {"timestamp":"2026-04-18T14:59:03Z","type":"event_msg","payload":{"type":"user_message","message":"inspect the repo"}}
        {"timestamp":"2026-04-18T14:59:05Z","type":"event_msg","payload":{"type":"agent_message","phase":"final","message":"I checked the repo entrypoints."}}
        """
        try rollout.write(to: rolloutURL, atomically: true, encoding: .utf8)

        let snapshot = await CodexRolloutParser.shared.parseThread(
            threadId: threadId,
            fallbackCwd: "/Users/ping-island/Island",
            clientInfo: SessionClientInfo(
                kind: .codexApp,
                profileID: "codex-app",
                name: "Codex App",
                bundleIdentifier: "com.openai.codex",
                sessionFilePath: rolloutURL.path
            )
        )

        XCTAssertEqual(snapshot?.parentThreadId, parentThreadId)
        XCTAssertEqual(snapshot?.subagentDepth, 1)
        XCTAssertEqual(snapshot?.subagentNickname, "Kierkegaard")
        XCTAssertEqual(snapshot?.subagentRole, "explorer")
        XCTAssertEqual(snapshot?.isSubagent, true)
    }
}
