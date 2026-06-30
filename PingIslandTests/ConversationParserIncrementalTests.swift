import Foundation
import XCTest
@testable import Ping_Island

/// `ConversationParser.parse` was re-reading and re-parsing the entire transcript
/// (tens of MB for long sessions) on every append, which pinned the CPU when many
/// large sessions were active. It now folds only the newly written tail bytes into
/// a running accumulator. These tests pin the core correctness property of that
/// change: the incremental (tail) path must produce byte-identical `ConversationInfo`
/// to a cold full parse, including across a partially written trailing line.
final class ConversationParserIncrementalTests: XCTestCase {

    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ConversationParserIncrementalTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    // MARK: - Fixture

    /// A representative claude-like transcript: a summary line, the first user
    /// message (title fallback), an assistant reply, a tool_use, its tool_result,
    /// a meta line that must be ignored, a later user message (drives the sort
    /// date), and a final assistant message (the lastMessage).
    private func fixtureLines() -> [String] {
        [
            jsonLine(["type": "summary", "summary": "Fix the clock bug"]),
            userText("Help me fix the clock", timestamp: "2026-06-12T10:00:01.000Z"),
            assistantText("Sure, let me look", timestamp: "2026-06-12T10:00:02.000Z"),
            assistantToolUse(id: "t1", name: "Read", input: ["file_path": "/a/b/Clock.swift"],
                             timestamp: "2026-06-12T10:00:03.000Z"),
            userToolResult(id: "t1", content: "file contents", timestamp: "2026-06-12T10:00:04.000Z"),
            metaUser("<meta noise>"),
            userText("And also the date", timestamp: "2026-06-12T10:00:05.000Z"),
            assistantText("All done", timestamp: "2026-06-12T10:00:06.000Z"),
        ]
    }

    // MARK: - Tests

    func testColdParseExtractsExpectedFields() async throws {
        let path = try writeFile(name: "cold.jsonl", lines: fixtureLines(), mtime: 1_000)
        let info = await ConversationParser.shared.parse(sessionId: "s", cwd: "/tmp", explicitFilePath: path)

        XCTAssertEqual(info.summary, "Fix the clock bug")
        XCTAssertEqual(info.firstUserMessage, "Help me fix the clock")
        XCTAssertEqual(info.lastMessage, "All done")
        XCTAssertEqual(info.lastMessageRole, "assistant")
        XCTAssertNil(info.lastToolName)
        XCTAssertEqual(info.lastUserMessageDate, isoDate("2026-06-12T10:00:05.000Z"))
        XCTAssertFalse(info.isTitleGenerationPrompt)
    }

    func testIncrementalTailMatchesColdFullParse() async throws {
        let lines = fixtureLines()

        // Cold parse of the complete file (distinct path → independent state).
        let fullPath = try writeFile(name: "full.jsonl", lines: lines, mtime: 1_000)
        let expected = await ConversationParser.shared.parse(sessionId: "full", cwd: "/tmp", explicitFilePath: fullPath)

        // Same bytes, but written in two appends so the second parse goes through
        // the tail-incremental path. The split lands on a line boundary mid-tool-call,
        // so the first parse's lastMessage (a tool_use) must be overwritten by the tail.
        let incPath = try writeFile(name: "inc.jsonl", lines: Array(lines[0..<4]), mtime: 1_000)
        let firstPass = await ConversationParser.shared.parse(sessionId: "inc", cwd: "/tmp", explicitFilePath: incPath)
        XCTAssertEqual(firstPass.lastMessageRole, "tool", "precondition: first chunk ends on a tool_use")
        XCTAssertEqual(firstPass.lastToolName, "Read")

        try append(to: incPath, lines: Array(lines[4...]), mtime: 2_000)
        let incremental = await ConversationParser.shared.parse(sessionId: "inc", cwd: "/tmp", explicitFilePath: incPath)

        XCTAssertEqual(incremental, expected)
    }

    func testUnchangedModificationDateServesCachedView() async throws {
        let lines = fixtureLines()
        let path = try writeFile(name: "cached.jsonl", lines: lines, mtime: 5_000)
        let first = await ConversationParser.shared.parse(sessionId: "c", cwd: "/tmp", explicitFilePath: path)

        // Append new content but keep the modification date identical. The parser
        // keys its fast path on modDate (unchanged behavior), so it should return
        // the prior view without reading the appended bytes.
        try append(to: path, lines: [assistantText("late addition", timestamp: "2026-06-12T11:00:00.000Z")], mtime: 5_000)
        let second = await ConversationParser.shared.parse(sessionId: "c", cwd: "/tmp", explicitFilePath: path)

        XCTAssertEqual(second, first)
    }

    func testPartialTrailingLineConsumedOnlyWhenComplete() async throws {
        let lines = fixtureLines()

        // Reference: cold parse of the first five complete lines.
        let refPath = try writeFile(name: "ref.jsonl", lines: Array(lines[0..<5]), mtime: 1_000)
        let reference = await ConversationParser.shared.parse(sessionId: "ref", cwd: "/tmp", explicitFilePath: refPath)

        // Build the same content incrementally, but write the fifth line in two
        // halves (the first half has no trailing newline).
        let path = try writeFile(name: "partial.jsonl", lines: Array(lines[0..<4]), mtime: 1_000)
        let afterFour = await ConversationParser.shared.parse(sessionId: "p", cwd: "/tmp", explicitFilePath: path)

        let fifth = lines[4] + "\n"
        let splitAt = fifth.index(fifth.startIndex, offsetBy: fifth.count / 2)
        try appendRaw(to: path, string: String(fifth[..<splitAt]), mtime: 2_000)
        let afterPartial = await ConversationParser.shared.parse(sessionId: "p", cwd: "/tmp", explicitFilePath: path)
        XCTAssertEqual(afterPartial, afterFour, "a partially written line must not be consumed")

        try appendRaw(to: path, string: String(fifth[splitAt...]), mtime: 3_000)
        let afterComplete = await ConversationParser.shared.parse(sessionId: "p", cwd: "/tmp", explicitFilePath: path)
        XCTAssertEqual(afterComplete, reference, "the completed line must be folded in")
    }

    func testTruncationResetsToFullReparse() async throws {
        let lines = fixtureLines()
        let path = try writeFile(name: "rotate.jsonl", lines: lines, mtime: 1_000)
        _ = await ConversationParser.shared.parse(sessionId: "r", cwd: "/tmp", explicitFilePath: path)

        // Simulate a brand-new session reusing the path (file shrinks): the parser
        // must discard stale offset/accumulator state and parse the new file fresh.
        let fresh = [
            jsonLine(["type": "summary", "summary": "Brand new topic"]),
            userText("Totally different question", timestamp: "2026-06-12T12:00:00.000Z"),
        ]
        try writeRaw(to: path, string: fresh.joined(separator: "\n") + "\n", mtime: 2_000)
        let info = await ConversationParser.shared.parse(sessionId: "r", cwd: "/tmp", explicitFilePath: path)

        XCTAssertEqual(info.summary, "Brand new topic")
        XCTAssertEqual(info.firstUserMessage, "Totally different question")
        XCTAssertEqual(info.lastMessage, "Totally different question")
    }

    // MARK: - Permission mode

    func testColdParseCapturesLatestPermissionMode() async throws {
        let lines = [
            permissionMode("default"),
            userText("Help me fix the clock", timestamp: "2026-06-12T10:00:01.000Z"),
            permissionMode("acceptEdits"),
            assistantText("On it", timestamp: "2026-06-12T10:00:02.000Z"),
            permissionMode("auto"),
        ]
        let path = try writeFile(name: "mode-cold.jsonl", lines: lines, mtime: 1_000)
        let info = await ConversationParser.shared.parse(sessionId: "m", cwd: "/tmp", explicitFilePath: path)

        XCTAssertEqual(info.permissionMode, "auto", "the most recent permission-mode line must win")
    }

    func testNoPermissionModeLineLeavesModeNil() async throws {
        let path = try writeFile(name: "mode-absent.jsonl", lines: fixtureLines(), mtime: 1_000)
        let info = await ConversationParser.shared.parse(sessionId: "m2", cwd: "/tmp", explicitFilePath: path)

        XCTAssertNil(info.permissionMode)
    }

    func testIncrementalTailPicksUpModeChange() async throws {
        let head = [
            permissionMode("default"),
            userText("Plan this out", timestamp: "2026-06-12T10:00:01.000Z"),
        ]
        let path = try writeFile(name: "mode-inc.jsonl", lines: head, mtime: 1_000)
        let first = await ConversationParser.shared.parse(sessionId: "m3", cwd: "/tmp", explicitFilePath: path)
        XCTAssertEqual(first.permissionMode, "default")

        try append(to: path, lines: [permissionMode("plan")], mtime: 2_000)
        let second = await ConversationParser.shared.parse(sessionId: "m3", cwd: "/tmp", explicitFilePath: path)
        XCTAssertEqual(second.permissionMode, "plan", "a mode toggle appended later must be folded in")
    }

    // MARK: - JSONL builders

    private func permissionMode(_ mode: String) -> String {
        jsonLine(["type": "permission-mode", "permissionMode": mode, "sessionId": "s"])
    }

    private func jsonLine(_ obj: [String: Any]) -> String {
        let data = try! JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])
        return String(data: data, encoding: .utf8)!
    }

    private func userText(_ text: String, timestamp: String) -> String {
        jsonLine([
            "type": "user",
            "timestamp": timestamp,
            "message": ["role": "user", "content": [["type": "text", "text": text]]],
        ])
    }

    private func assistantText(_ text: String, timestamp: String) -> String {
        jsonLine([
            "type": "assistant",
            "timestamp": timestamp,
            "message": ["role": "assistant", "content": [["type": "text", "text": text]]],
        ])
    }

    private func assistantToolUse(id: String, name: String, input: [String: Any], timestamp: String) -> String {
        jsonLine([
            "type": "assistant",
            "timestamp": timestamp,
            "message": ["role": "assistant", "content": [["type": "tool_use", "id": id, "name": name, "input": input]]],
        ])
    }

    private func userToolResult(id: String, content: String, timestamp: String) -> String {
        jsonLine([
            "type": "user",
            "timestamp": timestamp,
            "message": ["role": "user", "content": [["type": "tool_result", "tool_use_id": id, "content": content, "is_error": false]]],
        ])
    }

    private func metaUser(_ text: String) -> String {
        jsonLine([
            "type": "user",
            "isMeta": true,
            "message": ["role": "user", "content": [["type": "text", "text": text]]],
        ])
    }

    // MARK: - File helpers

    private func isoDate(_ string: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: string)
    }

    @discardableResult
    private func writeFile(name: String, lines: [String], mtime: TimeInterval) throws -> String {
        let url = tempDir.appendingPathComponent(name)
        try writeRaw(to: url.path, string: lines.joined(separator: "\n") + "\n", mtime: mtime)
        return url.path
    }

    private func writeRaw(to path: String, string: String, mtime: TimeInterval) throws {
        try string.data(using: .utf8)!.write(to: URL(fileURLWithPath: path))
        try setMtime(path, mtime)
    }

    private func append(to path: String, lines: [String], mtime: TimeInterval) throws {
        try appendRaw(to: path, string: lines.joined(separator: "\n") + "\n", mtime: mtime)
    }

    private func appendRaw(to path: String, string: String, mtime: TimeInterval) throws {
        let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: string.data(using: .utf8)!)
        try setMtime(path, mtime)
    }

    /// Force a deterministic modification date so the parser's modDate fast path
    /// behaves predictably regardless of filesystem timestamp granularity.
    private func setMtime(_ path: String, _ mtime: TimeInterval) throws {
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: mtime)],
            ofItemAtPath: path
        )
    }
}
