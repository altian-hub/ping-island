//
//  ConversationParser.swift
//  PingIsland
//
//  Parses Claude JSONL conversation files to extract summary and last message
//  Optimized for incremental parsing - only reads new lines since last sync
//

import Foundation
import os.log

struct ConversationInfo: Equatable, Sendable {
    let summary: String?
    let lastMessage: String?
    let lastMessageRole: String?  // "user", "assistant", or "tool"
    let lastToolName: String?  // Tool name if lastMessageRole is "tool"
    let firstUserMessage: String?  // Fallback title when no summary
    let lastUserMessageDate: Date?  // Timestamp of last user message (for stable sorting)
    /// True when the first user message is Claude Code's internal session-title
    /// generation prompt ("In 4-6 words … write a session title that captures: …").
    /// Those helper sessions get their own session_id and a small real transcript,
    /// so the zero-byte phantom heuristic misses them; this flag lets the UI hide them.
    /// Defaulted so existing (Codex) initializers compile unchanged.
    var isTitleGenerationPrompt: Bool = false
}

actor ConversationParser {
    static let shared = ConversationParser()

    struct QoderSubagentPresentation: Equatable, Sendable {
        let displayTitle: String
    }

    /// Logger for conversation parser (nonisolated static for cross-context access)
    nonisolated static let logger = Logger(subsystem: "com.wudanwu.pingisland", category: "Parser")

    /// Cache of parsed conversation info, keyed by session file path.
    /// Used for the openClaw format, which is re-parsed in full on change.
    private var cache: [String: CachedInfo] = [:]

    private var incrementalState: [String: IncrementalParseState] = [:]

    /// Tail-incremental conversation-info state for claude-like transcripts,
    /// keyed by session file path. Avoids re-reading the whole (potentially
    /// tens-of-MB) file on every append: we fold only the newly written bytes
    /// into a running accumulator.
    private var infoState: [String: IncrementalInfoState] = [:]

    private struct CachedInfo {
        let modificationDate: Date
        let info: ConversationInfo
    }

    private struct IncrementalInfoState {
        var lastOffset: UInt64
        var modificationDate: Date
        var accumulator: ConversationInfoAccumulator
    }

    /// Running, append-only view of the fields that make up `ConversationInfo`.
    /// Folding lines in file order yields the same result as the original
    /// forward(firstUserMessage)+backward(lastMessage/summary/date) scan:
    /// `firstUserMessage` sticks to the first match, every other field keeps
    /// the most recently seen value (i.e. the last occurrence in the file).
    private struct ConversationInfoAccumulator {
        var summary: String?
        var lastMessage: String?
        var lastMessageRole: String?
        var lastToolName: String?
        var firstUserMessage: String?
        var lastUserMessageDate: Date?
        var isTitleGenerationPrompt = false

        var info: ConversationInfo {
            ConversationInfo(
                summary: summary,
                lastMessage: ConversationParser.truncateMessage(lastMessage, maxLength: 80),
                lastMessageRole: lastMessageRole,
                lastToolName: lastToolName,
                firstUserMessage: firstUserMessage,
                lastUserMessageDate: lastUserMessageDate,
                isTitleGenerationPrompt: isTitleGenerationPrompt
            )
        }
    }

    /// State for incremental JSONL parsing
    private struct IncrementalParseState {
        var lastFileOffset: UInt64 = 0
        var messages: [ChatMessage] = []
        var seenToolIds: Set<String> = []
        var toolIdToName: [String: String] = [:]  // Map tool_use_id to tool name
        var completedToolIds: Set<String> = []  // Tools that have received results
        var toolResults: [String: ToolResult] = [:]  // Tool results keyed by tool_use_id
        var structuredResults: [String: ToolResultData] = [:]  // Structured results keyed by tool_use_id
        var lastClearOffset: UInt64 = 0  // Offset of last /clear command (0 = none or at start)
        var clearPending: Bool = false  // True if a /clear was just detected
    }

    private enum TranscriptFormat {
        case claudeLike
        case openClaw
    }

    /// Parsed tool result data
    struct ToolResult {
        let content: String?
        let stdout: String?
        let stderr: String?
        let isError: Bool
        let isInterrupted: Bool

        init(content: String?, stdout: String?, stderr: String?, isError: Bool) {
            self.content = content
            self.stdout = stdout
            self.stderr = stderr
            self.isError = isError
            // Detect if this was an interrupt or rejection (various formats)
            self.isInterrupted = isError && (
                content?.contains("Interrupted by user") == true ||
                content?.contains("interrupted by user") == true ||
                content?.contains("user doesn't want to proceed") == true
            )
        }
    }

    /// Parse a JSONL file to extract conversation info
    /// Uses caching based on file modification time
    func parse(sessionId: String, cwd: String, explicitFilePath: String? = nil) -> ConversationInfo {
        let sessionFile = Self.sessionFilePath(sessionId: sessionId, cwd: cwd, explicitFilePath: explicitFilePath)
        let transcriptFormat = Self.transcriptFormat(for: sessionFile)

        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: sessionFile),
              let attrs = try? fileManager.attributesOfItem(atPath: sessionFile),
              let modDate = attrs[.modificationDate] as? Date,
              let fileSize = (attrs[.size] as? NSNumber)?.uint64Value else {
            return ConversationInfo(summary: nil, lastMessage: nil, lastMessageRole: nil, lastToolName: nil, firstUserMessage: nil, lastUserMessageDate: nil)
        }

        // openClaw transcripts have no append-only offset semantics here; keep
        // the simple "re-read whole file when modDate changes" cache for them.
        if transcriptFormat == .openClaw {
            if let cached = cache[sessionFile], cached.modificationDate == modDate {
                return cached.info
            }
            guard let data = fileManager.contents(atPath: sessionFile),
                  let content = String(data: data, encoding: .utf8) else {
                return ConversationInfo(summary: nil, lastMessage: nil, lastMessageRole: nil, lastToolName: nil, firstUserMessage: nil, lastUserMessageDate: nil)
            }
            let info = parseOpenClawContent(content)
            cache[sessionFile] = CachedInfo(modificationDate: modDate, info: info)
            return info
        }

        return parseClaudeLikeIncrementally(sessionFile: sessionFile, modDate: modDate, fileSize: fileSize)
    }

    /// Maintain a running `ConversationInfo` for a claude-like transcript by
    /// folding in only the bytes appended since the last call, instead of
    /// re-reading and re-parsing the entire file on every change.
    private func parseClaudeLikeIncrementally(sessionFile: String, modDate: Date, fileSize: UInt64) -> ConversationInfo {
        if var state = infoState[sessionFile] {
            // Unchanged file: serve the cached running view.
            if state.modificationDate == modDate {
                return state.accumulator.info
            }

            // Truncated/rotated (e.g. a brand-new session reusing the path):
            // drop the stale state and fall through to a cold full parse.
            if fileSize >= state.lastOffset {
                if fileSize > state.lastOffset,
                   let newData = Self.readData(at: sessionFile, from: state.lastOffset),
                   let boundary = Self.lastNewlineIndex(in: newData) {
                    // Only consume up to the last complete line; a partially
                    // written trailing line is picked up on the next call.
                    let completeData = newData[..<boundary]
                    if let chunk = String(data: completeData, encoding: .utf8) {
                        let formatter = Self.makeISO8601Formatter()
                        for line in chunk.components(separatedBy: "\n") where !line.isEmpty {
                            Self.accumulate(line: line, into: &state.accumulator, formatter: formatter)
                        }
                    }
                    state.lastOffset += UInt64(completeData.count)
                }
                state.modificationDate = modDate
                infoState[sessionFile] = state
                return state.accumulator.info
            }
        }

        // Cold start (or post-truncation): full parse, recording the offset so
        // subsequent calls only read the tail.
        guard let data = FileManager.default.contents(atPath: sessionFile),
              let content = String(data: data, encoding: .utf8) else {
            return ConversationInfo(summary: nil, lastMessage: nil, lastMessageRole: nil, lastToolName: nil, firstUserMessage: nil, lastUserMessageDate: nil)
        }

        var accumulator = ConversationInfoAccumulator()
        let formatter = Self.makeISO8601Formatter()
        for line in content.components(separatedBy: "\n") where !line.isEmpty {
            Self.accumulate(line: line, into: &accumulator, formatter: formatter)
        }
        infoState[sessionFile] = IncrementalInfoState(
            lastOffset: fileSize,
            modificationDate: modDate,
            accumulator: accumulator
        )
        return accumulator.info
    }

    /// Read from `offset` to end of file as raw bytes (nil on any failure).
    private static func readData(at path: String, from offset: UInt64) -> Data? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        do {
            try handle.seek(toOffset: offset)
            return try handle.readToEnd()
        } catch {
            return nil
        }
    }

    /// Index one past the last newline (0x0A) — i.e. the exclusive upper bound
    /// of the complete-line prefix. Nil when `data` holds no newline yet.
    private static func lastNewlineIndex(in data: Data) -> Int? {
        guard let last = data.lastIndex(of: 0x0A) else { return nil }
        return data.distance(from: data.startIndex, to: last) + 1
    }

    private static func makeISO8601Formatter() -> ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }

    /// Fold one JSONL line into the running conversation-info accumulator.
    ///
    /// Applied in file order, this reproduces the original two-pass scan
    /// (forward for `firstUserMessage`, backward for everything else):
    /// `firstUserMessage`/`isTitleGenerationPrompt` stick to the first
    /// displayable user message, while `summary`, `lastMessage`/role/tool and
    /// `lastUserMessageDate` always reflect the most recent matching line —
    /// which is exactly what "last write wins" yields on a forward pass.
    private static func accumulate(
        line: String,
        into acc: inout ConversationInfoAccumulator,
        formatter: ISO8601DateFormatter
    ) {
        guard let lineData = line.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] else {
            return
        }

        let type = json["type"] as? String

        if type == "summary", let summaryText = json["summary"] as? String {
            acc.summary = summaryText
            return
        }

        guard type == "user" || type == "assistant" else { return }
        let isMeta = json["isMeta"] as? Bool ?? false
        guard !isMeta, let message = json["message"] as? [String: Any] else { return }

        // First displayable user message: title fallback + title-gen detection.
        // Detect on the full, untruncated text — the title-gen markers sit past
        // the 50-char cut applied to firstUserMessage.
        if type == "user", acc.firstUserMessage == nil,
           let msgContent = firstDisplayText(in: message) {
            acc.isTitleGenerationPrompt = isClaudeTitleGenerationPrompt(msgContent)
            acc.firstUserMessage = truncateMessage(msgContent, maxLength: 50)
        }

        // The last displayable block of this message becomes lastMessage.
        for block in contentBlocks(in: message).reversed() {
            let blockType = block["type"] as? String
            if blockType == "tool_use" {
                let toolName = block["name"] as? String ?? "Tool"
                acc.lastMessage = formatToolInput(block["input"] as? [String: Any], toolName: toolName)
                acc.lastMessageRole = "tool"
                acc.lastToolName = toolName
                break
            } else if blockType == "text",
                      let text = block["text"] as? String,
                      let sanitizedText = SessionTextSanitizer.sanitizedDisplayText(text),
                      isDisplayableText(sanitizedText),
                      !sanitizedText.hasPrefix("[Request interrupted by user") {
                acc.lastMessage = sanitizedText
                acc.lastMessageRole = type
                acc.lastToolName = nil
                break
            }
        }

        // Most recent user message with displayable text drives the sort date.
        if type == "user", firstDisplayText(in: message) != nil {
            acc.lastUserMessageDate = (json["timestamp"] as? String).flatMap { formatter.date(from: $0) }
        }
    }

    /// Claude Code spawns a throwaway helper session to title each conversation. Its only
    /// user message is a title-generation prompt of the form:
    /// "In 4-6 words, plain text only with no quotes or punctuation, write a session title
    ///  that captures: '…'". These helpers get their own session_id and a small but
    /// non-empty transcript, so the zero-byte phantom heuristic does not catch them.
    /// Match two stable, distinctive fragments (mirroring `CodexAuxiliaryHookFilter`'s
    /// multi-marker style) so a changed word count ("5-10 words") or trailing path can't
    /// slip a ghost row through, while staying specific enough to avoid real prompts.
    static func isClaudeTitleGenerationPrompt(_ text: String?) -> Bool {
        guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else {
            return false
        }
        return text.contains("write a session title that captures")
            && text.contains("plain text only with no quotes or punctuation")
    }

    /// Looser, truncation-tolerant probe for the same title-gen prompt. The strict
    /// two-marker match above needs the untruncated text, but by the time a row is
    /// displayed the prompt may only survive as a truncated `firstUserMessage` (50 chars)
    /// or `lastMessage` (80 chars), or arrive via a hook preview before the transcript is
    /// parsed. This fragment sits near the start of the prompt ("In N words, plain text
    /// only with no quotes …") so it survives those truncations, and is distinctive enough
    /// that real prompts effectively never contain it.
    static func containsClaudeTitleGenerationFragment(_ text: String?) -> Bool {
        guard let text, !text.isEmpty else { return false }
        return text.contains("plain text only with no quotes")
    }

    private static func contentBlocks(in message: [String: Any]) -> [[String: Any]] {
        if let text = message["content"] as? String {
            return [["type": "text", "text": text]]
        }

        if let contentArray = message["content"] as? [[String: Any]] {
            return contentArray
        }

        return []
    }

    private static func firstDisplayText(in message: [String: Any]) -> String? {
        for block in contentBlocks(in: message) {
            guard block["type"] as? String == "text",
                  let text = block["text"] as? String,
                  let sanitizedText = SessionTextSanitizer.sanitizedDisplayText(text),
                  isDisplayableText(sanitizedText) else {
                continue
            }
            return sanitizedText
        }

        return nil
    }

    private static func isDisplayableText(_ text: String) -> Bool {
        !text.hasPrefix("<command-name>")
            && !text.hasPrefix("<local-command")
            && !text.hasPrefix("Caveat:")
    }

    /// Format tool input for display in instance list
    private static func formatToolInput(_ input: [String: Any]?, toolName: String) -> String {
        guard let input = input else { return "" }

        switch toolName {
        case "Read", "Write", "Edit":
            if let filePath = input["file_path"] as? String {
                return (filePath as NSString).lastPathComponent
            }
        case "Bash":
            if let command = input["command"] as? String {
                return command
            }
        case "Grep":
            if let pattern = input["pattern"] as? String {
                return pattern
            }
        case "Glob":
            if let pattern = input["pattern"] as? String {
                return pattern
            }
        case "Task":
            if let description = input["description"] as? String {
                return description
            }
        case "WebFetch":
            if let url = input["url"] as? String {
                return url
            }
        case "WebSearch":
            if let query = input["query"] as? String {
                return query
            }
        default:
            for (_, value) in input {
                if let str = value as? String, !str.isEmpty {
                    return str
                }
            }
        }
        return ""
    }

    /// Truncate message for display
    private static func truncateMessage(_ message: String?, maxLength: Int = 80) -> String? {
        guard let msg = message else { return nil }
        let cleaned = msg.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\n", with: " ")
        if cleaned.count > maxLength {
            return String(cleaned.prefix(maxLength - 3)) + "..."
        }
        return cleaned
    }

    // MARK: - Full Conversation Parsing

    /// Parse full conversation history for chat view (returns ALL messages - use sparingly)
    func parseFullConversation(sessionId: String, cwd: String, explicitFilePath: String? = nil) -> [ChatMessage] {
        let sessionFile = Self.sessionFilePath(sessionId: sessionId, cwd: cwd, explicitFilePath: explicitFilePath)
        let transcriptFormat = Self.transcriptFormat(for: sessionFile)

        guard FileManager.default.fileExists(atPath: sessionFile) else {
            return []
        }

        var state = incrementalState[sessionId] ?? IncrementalParseState()
        _ = parseNewLines(filePath: sessionFile, state: &state, transcriptFormat: transcriptFormat)
        incrementalState[sessionId] = state

        return state.messages
    }

    /// Result of incremental parsing
    struct IncrementalParseResult {
        let newMessages: [ChatMessage]
        let allMessages: [ChatMessage]
        let completedToolIds: Set<String>
        let toolResults: [String: ToolResult]
        let structuredResults: [String: ToolResultData]
        let clearDetected: Bool
    }

    /// Parse only NEW messages since last call (efficient incremental updates)
    func parseIncremental(sessionId: String, cwd: String, explicitFilePath: String? = nil) -> IncrementalParseResult {
        let sessionFile = Self.sessionFilePath(sessionId: sessionId, cwd: cwd, explicitFilePath: explicitFilePath)
        let transcriptFormat = Self.transcriptFormat(for: sessionFile)

        guard FileManager.default.fileExists(atPath: sessionFile) else {
            return IncrementalParseResult(
                newMessages: [],
                allMessages: [],
                completedToolIds: [],
                toolResults: [:],
                structuredResults: [:],
                clearDetected: false
            )
        }

        var state = incrementalState[sessionId] ?? IncrementalParseState()
        let newMessages = parseNewLines(filePath: sessionFile, state: &state, transcriptFormat: transcriptFormat)
        let clearDetected = state.clearPending
        if clearDetected {
            state.clearPending = false
        }
        incrementalState[sessionId] = state

        return IncrementalParseResult(
            newMessages: newMessages,
            allMessages: state.messages,
            completedToolIds: state.completedToolIds,
            toolResults: state.toolResults,
            structuredResults: state.structuredResults,
            clearDetected: clearDetected
        )
    }

    /// Parse only new lines since last read (incremental)
    private func parseNewLines(
        filePath: String,
        state: inout IncrementalParseState,
        transcriptFormat: TranscriptFormat
    ) -> [ChatMessage] {
        guard let fileHandle = FileHandle(forReadingAtPath: filePath) else {
            return []
        }
        defer { try? fileHandle.close() }

        let fileSize: UInt64
        do {
            fileSize = try fileHandle.seekToEnd()
        } catch {
            return []
        }

        if fileSize < state.lastFileOffset {
            state = IncrementalParseState()
        }

        if fileSize == state.lastFileOffset {
            return state.messages
        }

        do {
            try fileHandle.seek(toOffset: state.lastFileOffset)
        } catch {
            return state.messages
        }

        guard let newData = try? fileHandle.readToEnd(),
              let newContent = String(data: newData, encoding: .utf8) else {
            return state.messages
        }

        state.clearPending = false
        let isIncrementalRead = state.lastFileOffset > 0
        let lines = newContent.components(separatedBy: "\n")
        var newMessages: [ChatMessage] = []

        if transcriptFormat == .openClaw {
            for line in lines where !line.isEmpty {
                guard let lineData = line.data(using: .utf8),
                      let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                      let message = parseOpenClawMessageLine(json) else {
                    continue
                }
                newMessages.append(message)
                state.messages.append(message)
            }

            state.lastFileOffset = fileSize
            return newMessages
        }

        for line in lines where !line.isEmpty {
            if line.contains("<command-name>/clear</command-name>") {
                state.messages = []
                state.seenToolIds = []
                state.toolIdToName = [:]
                state.completedToolIds = []
                state.toolResults = [:]
                state.structuredResults = [:]

                if isIncrementalRead {
                    state.clearPending = true
                    state.lastClearOffset = state.lastFileOffset
                    Self.logger.debug("/clear detected (new), will notify UI")
                }
                continue
            }

            if line.contains("\"tool_result\"") {
                if let lineData = line.data(using: .utf8),
                   let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                   let messageDict = json["message"] as? [String: Any],
                   let contentArray = messageDict["content"] as? [[String: Any]] {
                    let toolUseResult = json["toolUseResult"] as? [String: Any]
                    let topLevelToolName = json["toolName"] as? String
                    let stdout = toolUseResult?["stdout"] as? String
                    let stderr = toolUseResult?["stderr"] as? String

                    for block in contentArray {
                        if block["type"] as? String == "tool_result",
                           let toolUseId = block["tool_use_id"] as? String {
                            state.completedToolIds.insert(toolUseId)

                            let content = block["content"] as? String
                            let isError = block["is_error"] as? Bool ?? false
                            state.toolResults[toolUseId] = ToolResult(
                                content: content,
                                stdout: stdout,
                                stderr: stderr,
                                isError: isError
                            )

                            let toolName = topLevelToolName ?? state.toolIdToName[toolUseId]

                            if let toolUseResult = toolUseResult,
                               let name = toolName {
                                let structured = Self.parseStructuredResult(
                                    toolName: name,
                                    toolUseResult: toolUseResult,
                                    isError: isError
                                )
                                state.structuredResults[toolUseId] = structured
                            }
                        }
                    }
                }
            } else if line.contains("\"type\":\"user\"") || line.contains("\"type\":\"assistant\"") {
                if let lineData = line.data(using: .utf8),
                   let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                   let message = parseMessageLine(json, seenToolIds: &state.seenToolIds, toolIdToName: &state.toolIdToName) {
                    newMessages.append(message)
                    state.messages.append(message)
                }
            }
        }

        state.lastFileOffset = fileSize
        return newMessages
    }

    /// Get set of completed tool IDs for a session
    func completedToolIds(for sessionId: String) -> Set<String> {
        return incrementalState[sessionId]?.completedToolIds ?? []
    }

    /// Get tool results for a session
    func toolResults(for sessionId: String) -> [String: ToolResult] {
        return incrementalState[sessionId]?.toolResults ?? [:]
    }

    /// Get structured tool results for a session
    func structuredResults(for sessionId: String) -> [String: ToolResultData] {
        return incrementalState[sessionId]?.structuredResults ?? [:]
    }

    /// Reset incremental state for a session (call when reloading)
    func resetState(for sessionId: String) {
        incrementalState.removeValue(forKey: sessionId)
    }

    /// Check if a /clear command was detected during the last parse
    /// Returns true once and consumes the pending flag
    func checkAndConsumeClearDetected(for sessionId: String) -> Bool {
        guard var state = incrementalState[sessionId], state.clearPending else {
            return false
        }
        state.clearPending = false
        incrementalState[sessionId] = state
        return true
    }

    /// Build session file path
    private static func sessionFilePath(sessionId: String, cwd: String, explicitFilePath: String? = nil) -> String {
        if let explicitFilePath, !explicitFilePath.isEmpty {
            if FileManager.default.fileExists(atPath: explicitFilePath) {
                return explicitFilePath
            }

            if let fallbackOpenClawPath = latestOpenClawSessionFilePath(preferredPath: explicitFilePath) {
                return fallbackOpenClawPath
            }

            return explicitFilePath
        }

        let projectDir = cwd.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ".", with: "-")
        let qoderPath = NSHomeDirectory() + "/.qoder/projects/" + projectDir + "/transcript/" + sessionId + ".jsonl"
        if FileManager.default.fileExists(atPath: qoderPath) {
            return qoderPath
        }

        let qoderWorkPath = NSHomeDirectory() + "/.qoderwork/projects/" + projectDir + "/" + sessionId + ".jsonl"
        if FileManager.default.fileExists(atPath: qoderWorkPath) {
            return qoderWorkPath
        }

        let claudePath = NSHomeDirectory() + "/.claude/projects/" + projectDir + "/" + sessionId + ".jsonl"
        if FileManager.default.fileExists(atPath: claudePath) {
            return claudePath
        }

        if let fallbackOpenClawPath = latestOpenClawSessionFilePath(preferredPath: nil) {
            return fallbackOpenClawPath
        }

        return claudePath
    }

    private static func latestOpenClawSessionFilePath(preferredPath: String?) -> String? {
        let fileManager = FileManager.default
        let sessionsDirectory: URL = {
            if let preferredPath {
                return URL(fileURLWithPath: preferredPath).deletingLastPathComponent()
            }
            return fileManager.homeDirectoryForCurrentUser
                .appendingPathComponent(".openclaw/agents/main/sessions", isDirectory: true)
        }()

        guard let enumerator = fileManager.enumerator(
            at: sessionsDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }

        var newestURL: URL?
        var newestDate = Date.distantPast

        for case let fileURL as URL in enumerator {
            guard fileURL.pathExtension == "jsonl" else { continue }
            let values = try? fileURL.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey])
            guard values?.isRegularFile == true else { continue }
            let modifiedAt = values?.contentModificationDate ?? Date.distantPast
            if newestURL == nil || modifiedAt > newestDate {
                newestURL = fileURL
                newestDate = modifiedAt
            }
        }

        return newestURL?.path
    }

    private static func transcriptFormat(for filePath: String) -> TranscriptFormat {
        filePath.contains("/.openclaw/agents/") ? .openClaw : .claudeLike
    }

    private func parseOpenClawContent(_ content: String) -> ConversationInfo {
        let lines = content.components(separatedBy: "\n").filter { !$0.isEmpty }

        var firstUserMessage: String?
        var lastMessage: String?
        var lastMessageRole: String?
        var lastUserMessageDate: Date?

        for line in lines {
            guard let lineData = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                  let message = parseOpenClawMessageLine(json) else {
                continue
            }

            if firstUserMessage == nil, message.role == .user {
                firstUserMessage = Self.truncateMessage(message.textContent, maxLength: 50)
            }

            let text = message.textContent
            guard !text.isEmpty else { continue }
            lastMessage = text
            lastMessageRole = message.role.rawValue
            if message.role == .user {
                lastUserMessageDate = message.timestamp
            }
        }

        return ConversationInfo(
            summary: nil,
            lastMessage: Self.truncateMessage(lastMessage, maxLength: 80),
            lastMessageRole: lastMessageRole,
            lastToolName: nil,
            firstUserMessage: firstUserMessage,
            lastUserMessageDate: lastUserMessageDate
        )
    }

    func qoderFallbackIntervention(sessionId: String) -> SessionIntervention? {
        guard let historyPath = Self.qoderConversationHistoryPath(sessionId: sessionId),
              let content = try? String(contentsOfFile: historyPath, encoding: .utf8) else {
            return nil
        }

        return Self.parseQoderConversationHistory(content)
    }

    func qoderFallbackSubagentPresentation(
        sessionId: String,
        cwd: String,
        explicitFilePath: String? = nil
    ) -> QoderSubagentPresentation? {
        let sessionFile = Self.sessionFilePath(sessionId: sessionId, cwd: cwd, explicitFilePath: explicitFilePath)
        guard Self.transcriptFormat(for: sessionFile) == .claudeLike,
              let content = try? String(contentsOfFile: sessionFile, encoding: .utf8) else {
            return nil
        }

        return Self.parseQoderSubagentPresentation(content)
    }

    private static func qoderConversationHistoryPath(sessionId: String) -> String? {
        let shortSessionId = String(sessionId.prefix(8))
        let rootURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".qoder/cache/projects", isDirectory: true)

        guard let enumerator = FileManager.default.enumerator(
            at: rootURL,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }

        var newestMatch: URL?
        var newestDate = Date.distantPast

        for case let fileURL as URL in enumerator {
            guard fileURL.lastPathComponent == "\(shortSessionId).txt",
                  fileURL.path.contains("/conversation-history/") else {
                continue
            }

            let modifiedAt = (try? fileURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
                ?? Date.distantPast
            if newestMatch == nil || modifiedAt > newestDate {
                newestMatch = fileURL
                newestDate = modifiedAt
            }
        }

        return newestMatch?.path
    }

    private static func parseQoderConversationHistory(_ content: String) -> SessionIntervention? {
        struct RequestSection {
            let requestId: String
            let lines: [String]
        }

        let allLines = content.components(separatedBy: .newlines)
        var sections: [RequestSection] = []
        var currentRequestId: String?
        var currentLines: [String] = []

        for line in allLines {
            if line.hasPrefix("--- Request: "), line.hasSuffix(" ---") {
                if let currentRequestId {
                    sections.append(RequestSection(requestId: currentRequestId, lines: currentLines))
                }

                let requestId = line
                    .replacingOccurrences(of: "--- Request: ", with: "")
                    .replacingOccurrences(of: " ---", with: "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                currentRequestId = requestId
                currentLines = []
                continue
            }

            if currentRequestId != nil {
                currentLines.append(line)
            }
        }

        if let currentRequestId {
            sections.append(RequestSection(requestId: currentRequestId, lines: currentLines))
        }

        guard let latestSection = sections.last else {
            return nil
        }

        let trimmedLines = latestSection.lines.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard let lastAskIndex = trimmedLines.lastIndex(of: "[Tool call] ask_user_question") else {
            return nil
        }

        let trailingLines = Array(trimmedLines.dropFirst(lastAskIndex + 1))
        let hasResolvedAskUserQuestion = trailingLines.contains("[Tool result] ask_user_question")
        guard !hasResolvedAskUserQuestion else {
            return nil
        }

        let questionCount = trailingLines
            .compactMap { line -> Int? in
                guard line.hasPrefix("questions: ["),
                      let start = line.firstIndex(of: "["),
                      let end = line[start...].firstIndex(of: " ") else {
                    return nil
                }
                return Int(line[line.index(after: start)..<end])
            }
            .first ?? 1

        let title = questionCount == 1
            ? "Qoder 的提问"
            : "Qoder 的提问（\(questionCount) 个问题）"

        return SessionIntervention(
            id: "qoder-question-\(latestSection.requestId)",
            kind: .question,
            title: title,
            message: "Qoder 已在 IDE 内弹出问题，请回到 Qoder 完成回答。Island 会继续保留提醒，直到会话继续推进。",
            options: [],
            questions: [],
            supportsSessionScope: false,
            metadata: [
                "responseMode": "external_only",
                "source": "qoderConversationHistory",
                "requestId": latestSection.requestId
            ]
        )
    }

    private static func parseQoderSubagentPresentation(_ content: String) -> QoderSubagentPresentation? {
        enum FirstMeaningfulContent {
            case displayableText
            case toolUse(name: String, input: [String: Any]?)
        }

        let lines = content.components(separatedBy: "\n").filter { !$0.isEmpty }
        var sawSessionMeta = false
        var sawDisplayableConversationText = false
        var firstMeaningfulContent: FirstMeaningfulContent?

        for line in lines {
            guard let lineData = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] else {
                continue
            }

            let type = json["type"] as? String
            if type == "session_meta" {
                sawSessionMeta = true
                break
            }

            guard let message = json["message"] as? [String: Any] else { continue }
            for block in contentBlocks(in: message) {
                let blockType = block["type"] as? String

                if blockType == "tool_use" {
                    let toolName = block["name"] as? String ?? "Tool"
                    let toolInput = block["input"] as? [String: Any]
                    if firstMeaningfulContent == nil {
                        firstMeaningfulContent = .toolUse(name: toolName, input: toolInput)
                    }
                    continue
                }

                guard blockType == "text",
                      let text = block["text"] as? String,
                      let sanitizedText = SessionTextSanitizer.sanitizedDisplayText(text),
                      isDisplayableText(sanitizedText) else {
                    continue
                }

                sawDisplayableConversationText = true
                if firstMeaningfulContent == nil {
                    firstMeaningfulContent = .displayableText
                }
            }
        }

        guard !sawSessionMeta, !sawDisplayableConversationText else { return nil }
        guard case .toolUse(let toolName, let toolInput)? = firstMeaningfulContent else { return nil }
        guard toolName.caseInsensitiveCompare("Agent") != .orderedSame else { return nil }
        guard let title = qoderFallbackSubagentTitle(toolName: toolName, input: toolInput) else { return nil }

        return QoderSubagentPresentation(displayTitle: title)
    }

    private static func qoderFallbackSubagentTitle(toolName: String, input: [String: Any]?) -> String? {
        let normalizedToolName = toolName
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedToolName.isEmpty else { return nil }

        let inputSummary = formattedToolSummaryInput(input)
        if let inputSummary, !inputSummary.isEmpty {
            return "Agent · \(humanizedToolName(normalizedToolName)) \(inputSummary)"
        }

        return "Agent · \(humanizedToolName(normalizedToolName))"
    }

    private static func humanizedToolName(_ toolName: String) -> String {
        toolName
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .split(separator: " ")
            .map { word in
                guard let first = word.first else { return "" }
                return first.uppercased() + word.dropFirst().lowercased()
            }
            .joined(separator: " ")
    }

    private static func formattedToolSummaryInput(_ input: [String: Any]?) -> String? {
        guard let input else { return nil }

        let preferredPathKeys = [
            "file_path",
            "path",
            "target_file",
            "relative_workspace_path",
            "relative_path"
        ]
        for key in preferredPathKeys {
            if let path = input[key] as? String, !path.isEmpty {
                return URL(fileURLWithPath: path).lastPathComponent
            }
        }

        let preferredStringKeys = [
            "description",
            "command",
            "pattern",
            "query",
            "url",
            "prompt"
        ]
        for key in preferredStringKeys {
            if let value = input[key] as? String,
               let sanitizedValue = SessionTextSanitizer.sanitizedDisplayText(value),
               !sanitizedValue.isEmpty {
                return truncateMessage(sanitizedValue, maxLength: 48)
            }
        }

        for (_, value) in input {
            if let value = value as? String,
               let sanitizedValue = SessionTextSanitizer.sanitizedDisplayText(value),
               !sanitizedValue.isEmpty {
                return truncateMessage(sanitizedValue, maxLength: 48)
            }
        }

        return nil
    }

    private func parseMessageLine(_ json: [String: Any], seenToolIds: inout Set<String>, toolIdToName: inout [String: String]) -> ChatMessage? {
        guard let type = json["type"] as? String,
              let uuid = json["uuid"] as? String else {
            return nil
        }

        guard type == "user" || type == "assistant" else {
            return nil
        }

        if json["isMeta"] as? Bool == true {
            return nil
        }

        guard let messageDict = json["message"] as? [String: Any] else {
            return nil
        }

        let timestamp: Date
        if let timestampStr = json["timestamp"] as? String {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            timestamp = formatter.date(from: timestampStr) ?? Date()
        } else {
            timestamp = Date()
        }

        var blocks: [MessageBlock] = []

        if let content = messageDict["content"] as? String {
            let sanitizedContent = SessionTextSanitizer.sanitizedDisplayText(content)
            if content.hasPrefix("<command-name>") || content.hasPrefix("<local-command") || content.hasPrefix("Caveat:") {
                return nil
            }
            guard let sanitizedContent else { return nil }
            if sanitizedContent.hasPrefix("[Request interrupted by user") {
                blocks.append(.interrupted)
            } else {
                blocks.append(.text(sanitizedContent))
            }
        } else if let contentArray = messageDict["content"] as? [[String: Any]] {
            for block in contentArray {
                if let blockType = block["type"] as? String {
                    switch blockType {
                    case "text":
                        if let text = block["text"] as? String,
                           let sanitizedText = SessionTextSanitizer.sanitizedDisplayText(text) {
                            if sanitizedText.hasPrefix("[Request interrupted by user") {
                                blocks.append(.interrupted)
                            } else {
                                blocks.append(.text(sanitizedText))
                            }
                        }
                    case "tool_use":
                        if let toolId = block["id"] as? String {
                            if seenToolIds.contains(toolId) {
                                continue
                            }
                            seenToolIds.insert(toolId)
                            if let toolName = block["name"] as? String {
                                toolIdToName[toolId] = toolName
                            }
                        }
                        if let toolBlock = parseToolUse(block) {
                            blocks.append(.toolUse(toolBlock))
                        }
                    case "thinking":
                        if let thinking = block["thinking"] as? String,
                           let sanitizedThinking = SessionTextSanitizer.sanitizedDisplayText(thinking) {
                            blocks.append(.thinking(sanitizedThinking))
                        }
                    default:
                        break
                    }
                }
            }
        }

        guard !blocks.isEmpty else { return nil }

        let role: ChatRole = type == "user" ? .user : .assistant

        return ChatMessage(
            id: uuid,
            role: role,
            timestamp: timestamp,
            content: blocks
        )
    }

    private func parseOpenClawMessageLine(_ json: [String: Any]) -> ChatMessage? {
        guard json["type"] as? String == "message",
              let id = json["id"] as? String,
              let messageDict = json["message"] as? [String: Any],
              let roleString = messageDict["role"] as? String else {
            return nil
        }

        let role: ChatRole
        switch roleString {
        case "user":
            role = .user
        case "assistant":
            role = .assistant
        default:
            role = .system
        }

        let timestamp: Date = {
            guard let timestampStr = json["timestamp"] as? String else { return Date() }
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return formatter.date(from: timestampStr) ?? Date()
        }()

        var blocks: [MessageBlock] = []
        if let contentArray = messageDict["content"] as? [[String: Any]] {
            for block in contentArray {
                guard let blockType = block["type"] as? String else { continue }
                switch blockType {
                case "text":
                    if let text = block["text"] as? String,
                       let sanitizedText = SessionTextSanitizer.sanitizedDisplayText(text) {
                        blocks.append(.text(sanitizedText))
                    }
                case "thinking":
                    if let thinking = block["thinking"] as? String,
                       let sanitizedThinking = SessionTextSanitizer.sanitizedDisplayText(thinking) {
                        blocks.append(.thinking(sanitizedThinking))
                    }
                default:
                    continue
                }
            }
        }

        guard !blocks.isEmpty else { return nil }
        return ChatMessage(id: id, role: role, timestamp: timestamp, content: blocks)
    }

    private func parseToolUse(_ block: [String: Any]) -> ToolUseBlock? {
        guard let id = block["id"] as? String,
              let name = block["name"] as? String else {
            return nil
        }

        var input: [String: String] = [:]
        if let inputDict = block["input"] as? [String: Any] {
            for (key, value) in inputDict {
                if let strValue = value as? String {
                    input[key] = strValue
                } else if let intValue = value as? Int {
                    input[key] = String(intValue)
                } else if let boolValue = value as? Bool {
                    input[key] = boolValue ? "true" : "false"
                } else if JSONSerialization.isValidJSONObject(value),
                          let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
                          let json = String(data: data, encoding: .utf8) {
                    input[key] = json
                }
            }
        }

        return ToolUseBlock(id: id, name: name, input: input)
    }

    // MARK: - Structured Result Parsing

    /// Parse tool result JSON into structured ToolResultData
    private static func parseStructuredResult(
        toolName: String,
        toolUseResult: [String: Any],
        isError: Bool
    ) -> ToolResultData {
        if toolName.hasPrefix("mcp__") {
            let parts = toolName.dropFirst(5).split(separator: "_", maxSplits: 2)
            let serverName = parts.count > 0 ? String(parts[0]) : "unknown"
            let mcpToolName = parts.count > 1 ? String(parts[1].dropFirst()) : toolName
            return .mcp(MCPResult(
                serverName: serverName,
                toolName: mcpToolName,
                rawResult: toolUseResult
            ))
        }

        switch toolName {
        case "Read":
            return parseReadResult(toolUseResult)
        case "Edit":
            return parseEditResult(toolUseResult)
        case "Write":
            return parseWriteResult(toolUseResult)
        case "Bash":
            return parseBashResult(toolUseResult)
        case "Grep":
            return parseGrepResult(toolUseResult)
        case "Glob":
            return parseGlobResult(toolUseResult)
        case "TodoWrite":
            return parseTodoWriteResult(toolUseResult)
        case "Task":
            return parseTaskResult(toolUseResult)
        case "WebFetch":
            return parseWebFetchResult(toolUseResult)
        case "WebSearch":
            return parseWebSearchResult(toolUseResult)
        case "AskUserQuestion":
            return parseAskUserQuestionResult(toolUseResult)
        case "BashOutput":
            return parseBashOutputResult(toolUseResult)
        case "KillShell":
            return parseKillShellResult(toolUseResult)
        case "ExitPlanMode":
            return parseExitPlanModeResult(toolUseResult)
        default:
            let content = toolUseResult["content"] as? String ??
                          toolUseResult["stdout"] as? String ??
                          toolUseResult["result"] as? String
            return .generic(GenericResult(rawContent: content, rawData: toolUseResult))
        }
    }

    // MARK: - Individual Tool Result Parsers

    private static func parseReadResult(_ data: [String: Any]) -> ToolResultData {
        if let fileData = data["file"] as? [String: Any] {
            return .read(ReadResult(
                filePath: fileData["filePath"] as? String ?? "",
                content: fileData["content"] as? String ?? "",
                numLines: fileData["numLines"] as? Int ?? 0,
                startLine: fileData["startLine"] as? Int ?? 1,
                totalLines: fileData["totalLines"] as? Int ?? 0
            ))
        }
        return .read(ReadResult(
            filePath: data["filePath"] as? String ?? "",
            content: data["content"] as? String ?? "",
            numLines: data["numLines"] as? Int ?? 0,
            startLine: data["startLine"] as? Int ?? 1,
            totalLines: data["totalLines"] as? Int ?? 0
        ))
    }

    private static func parseEditResult(_ data: [String: Any]) -> ToolResultData {
        var patches: [PatchHunk]? = nil
        if let patchArray = data["structuredPatch"] as? [[String: Any]] {
            patches = patchArray.compactMap { patch -> PatchHunk? in
                guard let oldStart = patch["oldStart"] as? Int,
                      let oldLines = patch["oldLines"] as? Int,
                      let newStart = patch["newStart"] as? Int,
                      let newLines = patch["newLines"] as? Int,
                      let lines = patch["lines"] as? [String] else {
                    return nil
                }
                return PatchHunk(
                    oldStart: oldStart,
                    oldLines: oldLines,
                    newStart: newStart,
                    newLines: newLines,
                    lines: lines
                )
            }
        }

        return .edit(EditResult(
            filePath: data["filePath"] as? String ?? "",
            oldString: data["oldString"] as? String ?? "",
            newString: data["newString"] as? String ?? "",
            replaceAll: data["replaceAll"] as? Bool ?? false,
            userModified: data["userModified"] as? Bool ?? false,
            structuredPatch: patches
        ))
    }

    private static func parseWriteResult(_ data: [String: Any]) -> ToolResultData {
        let typeStr = data["type"] as? String ?? "create"
        let writeType: WriteResult.WriteType = typeStr == "overwrite" ? .overwrite : .create

        var patches: [PatchHunk]? = nil
        if let patchArray = data["structuredPatch"] as? [[String: Any]] {
            patches = patchArray.compactMap { patch -> PatchHunk? in
                guard let oldStart = patch["oldStart"] as? Int,
                      let oldLines = patch["oldLines"] as? Int,
                      let newStart = patch["newStart"] as? Int,
                      let newLines = patch["newLines"] as? Int,
                      let lines = patch["lines"] as? [String] else {
                    return nil
                }
                return PatchHunk(
                    oldStart: oldStart,
                    oldLines: oldLines,
                    newStart: newStart,
                    newLines: newLines,
                    lines: lines
                )
            }
        }

        return .write(WriteResult(
            type: writeType,
            filePath: data["filePath"] as? String ?? "",
            content: data["content"] as? String ?? "",
            structuredPatch: patches
        ))
    }

    private static func parseBashResult(_ data: [String: Any]) -> ToolResultData {
        return .bash(BashResult(
            stdout: data["stdout"] as? String ?? "",
            stderr: data["stderr"] as? String ?? "",
            interrupted: data["interrupted"] as? Bool ?? false,
            isImage: data["isImage"] as? Bool ?? false,
            returnCodeInterpretation: data["returnCodeInterpretation"] as? String,
            backgroundTaskId: data["backgroundTaskId"] as? String
        ))
    }

    private static func parseGrepResult(_ data: [String: Any]) -> ToolResultData {
        let modeStr = data["mode"] as? String ?? "files_with_matches"
        let mode: GrepResult.Mode
        switch modeStr {
        case "content": mode = .content
        case "count": mode = .count
        default: mode = .filesWithMatches
        }

        return .grep(GrepResult(
            mode: mode,
            filenames: data["filenames"] as? [String] ?? [],
            numFiles: data["numFiles"] as? Int ?? 0,
            content: data["content"] as? String,
            numLines: data["numLines"] as? Int,
            appliedLimit: data["appliedLimit"] as? Int
        ))
    }

    private static func parseGlobResult(_ data: [String: Any]) -> ToolResultData {
        return .glob(GlobResult(
            filenames: data["filenames"] as? [String] ?? [],
            durationMs: data["durationMs"] as? Int ?? 0,
            numFiles: data["numFiles"] as? Int ?? 0,
            truncated: data["truncated"] as? Bool ?? false
        ))
    }

    private static func parseTodoWriteResult(_ data: [String: Any]) -> ToolResultData {
        func parseTodos(_ array: [[String: Any]]?) -> [TodoItem] {
            guard let array = array else { return [] }
            return array.compactMap { item -> TodoItem? in
                guard let content = item["content"] as? String,
                      let status = item["status"] as? String else {
                    return nil
                }
                return TodoItem(
                    content: content,
                    status: status,
                    activeForm: item["activeForm"] as? String
                )
            }
        }

        return .todoWrite(TodoWriteResult(
            oldTodos: parseTodos(data["oldTodos"] as? [[String: Any]]),
            newTodos: parseTodos(data["newTodos"] as? [[String: Any]])
        ))
    }

    private static func parseTaskResult(_ data: [String: Any]) -> ToolResultData {
        return .task(TaskResult(
            agentId: data["agentId"] as? String ?? "",
            status: data["status"] as? String ?? "unknown",
            content: data["content"] as? String ?? "",
            prompt: data["prompt"] as? String,
            totalDurationMs: data["totalDurationMs"] as? Int,
            totalTokens: data["totalTokens"] as? Int,
            totalToolUseCount: data["totalToolUseCount"] as? Int
        ))
    }

    private static func parseWebFetchResult(_ data: [String: Any]) -> ToolResultData {
        return .webFetch(WebFetchResult(
            url: data["url"] as? String ?? "",
            code: data["code"] as? Int ?? 0,
            codeText: data["codeText"] as? String ?? "",
            bytes: data["bytes"] as? Int ?? 0,
            durationMs: data["durationMs"] as? Int ?? 0,
            result: data["result"] as? String ?? ""
        ))
    }

    private static func parseWebSearchResult(_ data: [String: Any]) -> ToolResultData {
        var results: [SearchResultItem] = []
        if let resultsArray = data["results"] as? [[String: Any]] {
            results = resultsArray.compactMap { item -> SearchResultItem? in
                guard let title = item["title"] as? String,
                      let url = item["url"] as? String else {
                    return nil
                }
                return SearchResultItem(
                    title: title,
                    url: url,
                    snippet: item["snippet"] as? String ?? ""
                )
            }
        }

        return .webSearch(WebSearchResult(
            query: data["query"] as? String ?? "",
            durationSeconds: data["durationSeconds"] as? Double ?? 0,
            results: results
        ))
    }

    private static func parseAskUserQuestionResult(_ data: [String: Any]) -> ToolResultData {
        var questions: [QuestionItem] = []
        if let questionsArray = data["questions"] as? [[String: Any]] {
            questions = questionsArray.compactMap { q -> QuestionItem? in
                guard let question = q["question"] as? String else { return nil }
                var options: [QuestionOption] = []
                if let optionsArray = q["options"] as? [[String: Any]] {
                    options = optionsArray.compactMap { opt -> QuestionOption? in
                        guard let label = opt["label"] as? String else { return nil }
                        return QuestionOption(
                            label: label,
                            description: opt["description"] as? String
                        )
                    }
                }
                return QuestionItem(
                    question: question,
                    header: q["header"] as? String,
                    options: options
                )
            }
        }

        var answers: [String: String] = [:]
        if let answersDict = data["answers"] as? [String: String] {
            answers = answersDict
        }

        return .askUserQuestion(AskUserQuestionResult(
            questions: questions,
            answers: answers
        ))
    }

    private static func parseBashOutputResult(_ data: [String: Any]) -> ToolResultData {
        return .bashOutput(BashOutputResult(
            shellId: data["shellId"] as? String ?? "",
            status: data["status"] as? String ?? "",
            stdout: data["stdout"] as? String ?? "",
            stderr: data["stderr"] as? String ?? "",
            stdoutLines: data["stdoutLines"] as? Int ?? 0,
            stderrLines: data["stderrLines"] as? Int ?? 0,
            exitCode: data["exitCode"] as? Int,
            command: data["command"] as? String,
            timestamp: data["timestamp"] as? String
        ))
    }

    private static func parseKillShellResult(_ data: [String: Any]) -> ToolResultData {
        return .killShell(KillShellResult(
            shellId: data["shell_id"] as? String ?? data["shellId"] as? String ?? "",
            message: data["message"] as? String ?? ""
        ))
    }

    private static func parseExitPlanModeResult(_ data: [String: Any]) -> ToolResultData {
        return .exitPlanMode(ExitPlanModeResult(
            filePath: data["filePath"] as? String,
            plan: data["plan"] as? String,
            isAgent: data["isAgent"] as? Bool ?? false
        ))
    }

    // MARK: - Subagent Tools Parsing

    /// Parse subagent tools from an agent JSONL file
    func parseSubagentTools(agentId: String, cwd: String) -> [SubagentToolInfo] {
        guard !agentId.isEmpty else { return [] }

        let projectDir = cwd.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ".", with: "-")
        let agentFile = NSHomeDirectory() + "/.claude/projects/" + projectDir + "/agent-" + agentId + ".jsonl"

        guard FileManager.default.fileExists(atPath: agentFile),
              let content = try? String(contentsOfFile: agentFile, encoding: .utf8) else {
            return []
        }

        var tools: [SubagentToolInfo] = []
        var seenToolIds: Set<String> = []
        var completedToolIds: Set<String> = []

        for line in content.components(separatedBy: "\n") where !line.isEmpty {
            if line.contains("\"tool_result\""),
               let lineData = line.data(using: .utf8),
               let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
               let messageDict = json["message"] as? [String: Any],
               let contentArray = messageDict["content"] as? [[String: Any]] {
                for block in contentArray {
                    if block["type"] as? String == "tool_result",
                       let toolUseId = block["tool_use_id"] as? String {
                        completedToolIds.insert(toolUseId)
                    }
                }
            }
        }

        for line in content.components(separatedBy: "\n") where !line.isEmpty {
            guard line.contains("\"tool_use\""),
                  let lineData = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                  let messageDict = json["message"] as? [String: Any],
                  let contentArray = messageDict["content"] as? [[String: Any]] else {
                continue
            }

            for block in contentArray {
                guard block["type"] as? String == "tool_use",
                      let toolId = block["id"] as? String,
                      let toolName = block["name"] as? String,
                      !seenToolIds.contains(toolId) else {
                    continue
                }

                seenToolIds.insert(toolId)

                var input: [String: String] = [:]
        if let inputDict = block["input"] as? [String: Any] {
            for (key, value) in inputDict {
                if let strValue = value as? String {
                    input[key] = strValue
                } else if let intValue = value as? Int {
                    input[key] = String(intValue)
                } else if let boolValue = value as? Bool {
                    input[key] = boolValue ? "true" : "false"
                } else if JSONSerialization.isValidJSONObject(value),
                          let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
                          let json = String(data: data, encoding: .utf8) {
                    input[key] = json
                }
            }
        }

                let isCompleted = completedToolIds.contains(toolId)
                let timestamp = json["timestamp"] as? String

                tools.append(SubagentToolInfo(
                    id: toolId,
                    name: toolName,
                    input: input,
                    isCompleted: isCompleted,
                    timestamp: timestamp
                ))
            }
        }

        return tools
    }
}

/// Info about a subagent tool call parsed from JSONL
struct SubagentToolInfo: Sendable {
    let id: String
    let name: String
    let input: [String: String]
    let isCompleted: Bool
    let timestamp: String?
}

// MARK: - Static Subagent Tools Parsing

extension ConversationParser {
    /// Parse subagent tools from an agent JSONL file (static, synchronous version)
    nonisolated static func parseSubagentToolsSync(agentId: String, cwd: String) -> [SubagentToolInfo] {
        guard !agentId.isEmpty else { return [] }

        let projectDir = cwd.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ".", with: "-")
        let agentFile = NSHomeDirectory() + "/.claude/projects/" + projectDir + "/agent-" + agentId + ".jsonl"

        guard FileManager.default.fileExists(atPath: agentFile),
              let content = try? String(contentsOfFile: agentFile, encoding: .utf8) else {
            return []
        }

        var tools: [SubagentToolInfo] = []
        var seenToolIds: Set<String> = []
        var completedToolIds: Set<String> = []

        for line in content.components(separatedBy: "\n") where !line.isEmpty {
            if line.contains("\"tool_result\""),
               let lineData = line.data(using: .utf8),
               let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
               let messageDict = json["message"] as? [String: Any],
               let contentArray = messageDict["content"] as? [[String: Any]] {
                for block in contentArray {
                    if block["type"] as? String == "tool_result",
                       let toolUseId = block["tool_use_id"] as? String {
                        completedToolIds.insert(toolUseId)
                    }
                }
            }
        }

        for line in content.components(separatedBy: "\n") where !line.isEmpty {
            guard line.contains("\"tool_use\""),
                  let lineData = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                  let messageDict = json["message"] as? [String: Any],
                  let contentArray = messageDict["content"] as? [[String: Any]] else {
                continue
            }

            for block in contentArray {
                guard block["type"] as? String == "tool_use",
                      let toolId = block["id"] as? String,
                      let toolName = block["name"] as? String,
                      !seenToolIds.contains(toolId) else {
                    continue
                }

                seenToolIds.insert(toolId)

                var input: [String: String] = [:]
                if let inputDict = block["input"] as? [String: Any] {
                    for (key, value) in inputDict {
                        if let strValue = value as? String {
                            input[key] = strValue
                        } else if let intValue = value as? Int {
                            input[key] = String(intValue)
                        } else if let boolValue = value as? Bool {
                            input[key] = boolValue ? "true" : "false"
                        }
                    }
                }

                let isCompleted = completedToolIds.contains(toolId)
                let timestamp = json["timestamp"] as? String

                tools.append(SubagentToolInfo(
                    id: toolId,
                    name: toolName,
                    input: input,
                    isCompleted: isCompleted,
                    timestamp: timestamp
                ))
            }
        }

        return tools
    }
}
