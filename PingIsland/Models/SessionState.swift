//
//  SessionState.swift
//  PingIsland
//
//  Unified state model for a tracked session.
//  Consolidates all state that was previously spread across multiple components.
//

import Foundation

enum SessionScopedApprovalAction: Equatable, Sendable {
    case allowSession
    case autoApprove

    nonisolated var buttonTitleKey: String {
        switch self {
        case .allowSession:
            return "Allow Session"
        case .autoApprove:
            return "Always Allow"
        }
    }

    nonisolated var compactButtonTitleKey: String {
        switch self {
        case .allowSession:
            return "Session"
        case .autoApprove:
            return "Always"
        }
    }
}

/// Complete state for a single tracked session
/// This is the single source of truth - all state reads and writes go through SessionStore
struct SessionState: Equatable, Identifiable, Sendable {
    private nonisolated static let minimalCompactDelay: TimeInterval = 10 * 60
    private nonisolated static let autoArchiveDelay: TimeInterval = 30 * 60
    private nonisolated static let endedArchiveActionDelay: TimeInterval = 10 * 60
    private nonisolated static let codexContinuationPlaceholderHideWindow: TimeInterval = 10 * 60
    private nonisolated static let openCodeChildSessionHideWindow: TimeInterval = 120

    // MARK: - Identity

    let sessionId: String
    var cwd: String
    var projectName: String
    var provider: SessionProvider
    var clientInfo: SessionClientInfo
    var ingress: SessionIngress
    var sessionName: String?
    var previewText: String?
    var latestHookMessage: String?
    var intervention: SessionIntervention?
    var codexParentThreadId: String?
    var codexSubagentDepth: Int?
    var codexSubagentNickname: String?
    var codexSubagentRole: String?
    var linkedParentSessionId: String?
    var linkedSubagentDisplayTitle: String?
    var heuristicSubagentDisplayTitle: String?

    // MARK: - Instance Metadata

    var pid: Int?
    var tty: String?
    var isInTmux: Bool
    var autoApprovePermissions: Bool

    // MARK: - State Machine

    /// Current phase in the session lifecycle
    var phase: SessionPhase

    // MARK: - Chat History

    /// All chat items for this session (replaces ChatHistoryManager.histories)
    var chatItems: [ChatHistoryItem]

    // MARK: - Tool Tracking

    /// Unified tool tracker (replaces 6+ dictionaries in ChatHistoryManager)
    var toolTracker: ToolTracker

    /// Tool IDs that completed with an actual execution error.
    /// Used for event-specific notifications such as CESP `task.error`.
    var completedErrorToolIDs: Set<String>

    // MARK: - Subagent State

    /// State for Task tools and their nested subagent tools
    var subagentState: SubagentState

    // MARK: - Conversation Info (from JSONL parsing)

    var conversationInfo: ConversationInfo

    // MARK: - Clear Reconciliation

    /// When true, the next file update should reconcile chatItems with parser state
    /// This removes pre-/clear items that no longer exist in the JSONL
    var needsClearReconciliation: Bool

    // MARK: - Timestamps

    var lastActivity: Date
    var createdAt: Date

    // MARK: - Identifiable

    var id: String { sessionId }

    // MARK: - Initialization

    nonisolated init(
        sessionId: String,
        cwd: String,
        projectName: String? = nil,
        provider: SessionProvider = .claude,
        clientInfo: SessionClientInfo? = nil,
        ingress: SessionIngress = .hookBridge,
        sessionName: String? = nil,
        previewText: String? = nil,
        latestHookMessage: String? = nil,
        intervention: SessionIntervention? = nil,
        codexParentThreadId: String? = nil,
        codexSubagentDepth: Int? = nil,
        codexSubagentNickname: String? = nil,
        codexSubagentRole: String? = nil,
        linkedParentSessionId: String? = nil,
        linkedSubagentDisplayTitle: String? = nil,
        heuristicSubagentDisplayTitle: String? = nil,
        pid: Int? = nil,
        tty: String? = nil,
        isInTmux: Bool = false,
        autoApprovePermissions: Bool = false,
        phase: SessionPhase = .idle,
        chatItems: [ChatHistoryItem] = [],
        toolTracker: ToolTracker = ToolTracker(),
        completedErrorToolIDs: Set<String> = [],
        subagentState: SubagentState = SubagentState(),
        conversationInfo: ConversationInfo = ConversationInfo(
            summary: nil, lastMessage: nil, lastMessageRole: nil,
            lastToolName: nil, firstUserMessage: nil, lastUserMessageDate: nil
        ),
        needsClearReconciliation: Bool = false,
        lastActivity: Date = Date(),
        createdAt: Date = Date()
    ) {
        self.sessionId = sessionId
        self.cwd = cwd
        self.projectName = projectName ?? URL(fileURLWithPath: cwd).lastPathComponent
        self.provider = provider
        self.clientInfo = clientInfo ?? SessionClientInfo.default(for: provider)
        self.ingress = ingress
        self.sessionName = sessionName
        self.previewText = previewText
        self.latestHookMessage = latestHookMessage
        self.intervention = intervention
        self.codexParentThreadId = codexParentThreadId
        self.codexSubagentDepth = codexSubagentDepth
        self.codexSubagentNickname = codexSubagentNickname
        self.codexSubagentRole = codexSubagentRole
        self.linkedParentSessionId = linkedParentSessionId
        self.linkedSubagentDisplayTitle = linkedSubagentDisplayTitle
        self.heuristicSubagentDisplayTitle = heuristicSubagentDisplayTitle
        self.pid = pid
        self.tty = tty
        self.isInTmux = isInTmux
        self.autoApprovePermissions = autoApprovePermissions
        self.phase = phase
        self.chatItems = chatItems
        self.toolTracker = toolTracker
        self.completedErrorToolIDs = completedErrorToolIDs
        self.subagentState = subagentState
        self.conversationInfo = conversationInfo
        self.needsClearReconciliation = needsClearReconciliation
        self.lastActivity = lastActivity
        self.createdAt = createdAt
    }

    // MARK: - Derived Properties

    /// Whether this session needs user attention
    nonisolated var needsAttention: Bool {
        phase.needsAttention || intervention != nil
    }

    /// Whether this session should be surfaced before active/background work.
    nonisolated var needsManualAttention: Bool {
        needsAttention
    }

    /// The active permission context, if any
    nonisolated var activePermission: PermissionContext? {
        if case .waitingForApproval(let ctx) = phase {
            return ctx
        }
        return nil
    }

    // MARK: - UI Convenience Properties

    /// Stable identity for SwiftUI (combines PID and sessionId for animation stability)
    nonisolated var stableId: String {
        if let pid = pid {
            return "\(pid)-\(sessionId)"
        }
        return sessionId
    }

    /// Display title: summary > first user message > project name
    nonisolated var displayTitle: String {
        sessionName
            ?? SessionTextSanitizer.sanitizedDisplayText(conversationInfo.summary)
            ?? SessionTextSanitizer.sanitizedDisplayText(conversationInfo.firstUserMessage)
            ?? projectName
    }

    /// Codex subagent threads report depth starting at 1 for the first spawned child.
    /// We surface every spawned child as a subagent in the primary UI.
    nonisolated var codexSubagentLevel: Int? {
        guard provider == .codex else { return nil }

        if let depth = codexSubagentDepth {
            return max(depth, 1)
        }

        if codexParentThreadId?.isEmpty == false
            || codexSubagentNickname?.isEmpty == false
            || codexSubagentRole?.isEmpty == false {
            return 1
        }

        return nil
    }

    nonisolated var isCodexSubagent: Bool {
        codexSubagentLevel != nil
    }

    nonisolated var isLinkedSubagentSession: Bool {
        sanitizedSubagentDisplayText(linkedParentSessionId) != nil
    }

    nonisolated var isHeuristicSubagentSession: Bool {
        sanitizedSubagentDisplayText(heuristicSubagentDisplayTitle) != nil
    }

    nonisolated var isQoderAgentPrefixedSubagent: Bool {
        guard clientInfo.brand == .qoder else { return false }
        return qoderAgentPrefixedSubagentDisplayTitle != nil
    }

    nonisolated var usesTitleOnlySubagentPresentation: Bool {
        isCodexSubagent
            || isLinkedSubagentSession
            || isHeuristicSubagentSession
            || isQoderAgentPrefixedSubagent
    }

    /// Primary-list visibility treats linked child sessions like first-level
    /// subagents so settings can hide or show all child sessions consistently.
    nonisolated var primarySubagentVisibilityLevel: Int? {
        if isLinkedSubagentSession {
            return 1
        }

        if isHeuristicSubagentSession {
            return 1
        }

        if isQoderAgentPrefixedSubagent {
            return 1
        }

        guard let subagentLevel = codexSubagentLevel else { return nil }
        guard subagentLevel > 1 else { return nil }
        return subagentLevel - 1
    }

    nonisolated func shouldDisplaySubagent(in mode: SubagentVisibilityMode) -> Bool {
        guard primarySubagentVisibilityLevel != nil else { return true }

        switch mode {
        case .hidden:
            return false
        case .visible:
            return true
        }
    }

    nonisolated var codexSubagentBadgeText: String? {
        (isCodexSubagent || isQoderAgentPrefixedSubagent) ? "SUBAGENT" : nil
    }

    nonisolated var subagentClientTypeBadgeText: String? {
        guard usesTitleOnlySubagentPresentation else { return nil }
        return sanitizedSubagentDisplayText(clientInfo.subagentClientTypeLabel(for: provider))
    }

    nonisolated var shouldUseCodexSubagentCompactPresentation: Bool {
        isCodexSubagent || isQoderAgentPrefixedSubagent
    }

    nonisolated var codexSubagentLabel: String? {
        guard isCodexSubagent else { return nil }

        var parts = ["Subagent"]
        if let role = sanitizedCodexSubagentText(codexSubagentRole) {
            parts.append(role)
        }
        if let nickname = sanitizedCodexSubagentText(codexSubagentNickname) {
            parts.append(nickname)
        } else if let level = codexSubagentLevel {
            parts.append("Depth \(level)")
        }

        return parts.joined(separator: " · ")
    }

    nonisolated var codexSubagentListTitle: String {
        codexSubagentLabel ?? displayTitle
    }

    nonisolated var titleOnlySubagentDisplayTitle: String {
        if isCodexSubagent {
            return codexSubagentListTitle
        }

        return sanitizedSubagentDisplayText(linkedSubagentDisplayTitle)
            ?? sanitizedSubagentDisplayText(heuristicSubagentDisplayTitle)
            ?? qoderAgentPrefixedSubagentDisplayTitle
            ?? displayTitle
    }

    nonisolated func codexSubagentSummaryText(for text: String?) -> String? {
        let sanitizedText = sanitizedCodexSubagentText(text)
        guard let label = codexSubagentLabel else {
            return sanitizedText
        }
        guard let sanitizedText, !sanitizedText.isEmpty else {
            return label
        }

        if sanitizedText.localizedCaseInsensitiveContains(label) {
            return sanitizedText
        }
        return "\(label) · \(sanitizedText)"
    }

    private nonisolated func sanitizedCodexSubagentText(_ text: String?) -> String? {
        sanitizedSubagentDisplayText(text)
    }

    private nonisolated func sanitizedSubagentDisplayText(_ text: String?) -> String? {
        guard let text else { return nil }
        let collapsed = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return collapsed.isEmpty ? nil : collapsed
    }

    private nonisolated var qoderAgentPrefixedSubagentDisplayTitle: String? {
        let candidates = [
            sanitizedSubagentDisplayText(linkedSubagentDisplayTitle),
            sanitizedSubagentDisplayText(heuristicSubagentDisplayTitle),
            sanitizedSubagentDisplayText(displayTitle)
        ].compactMap { $0 }

        return candidates.first(where: { candidate in
            candidate.range(
                of: #"^agent\s*·"#,
                options: [.regularExpression, .caseInsensitive]
            ) != nil
        })
    }

    /// Safety net for ghost Codex sessions that have no rollout, no history, and no visible content.
    nonisolated var shouldHideFromPrimaryUI: Bool {
        if shouldAutoArchiveFromPrimaryUI {
            return true
        }

        if isLikelyEmptyCodexPlaceholderForUI {
            return true
        }

        if isLikelyClaudeAuxiliaryTitleGenForUI {
            return true
        }

        return isLikelyEmptyClaudePlaceholderForUI
    }

    /// UI-level safety net for Claude's title-gen helper sessions. `SessionStore`
    /// now drops them at intake (`dropClaudeTitleGenHookEventIfNeeded`), but this
    /// still hides any that slip through in the brief window before the purge fires
    /// — e.g. a SessionStart row created before the title-gen prompt is detected.
    nonisolated var isLikelyClaudeAuxiliaryTitleGenForUI: Bool {
        guard provider == .claude else { return false }
        if conversationInfo.isTitleGenerationPrompt {
            return true
        }
        // Defensive fallback: the parse-time flag only catches the prompt when it is the
        // first user message of a freshly parsed transcript. During a swarm burst the
        // prompt can also reach the row as the last message, as a hook-delivered preview
        // before the transcript is parsed, or truncated in firstUserMessage. Probe every
        // text the row can actually display for the title-gen fragment.
        for text in [
            conversationInfo.firstUserMessage,
            conversationInfo.lastMessage,
            conversationInfo.summary,
            previewText,
            latestHookMessage
        ] where ConversationParser.containsClaudeTitleGenerationFragment(text) {
            return true
        }
        return false
    }

    /// Claude Code 2.1.x fires multiple SessionStart hooks per `claude` invocation —
    /// the main session plus a handful of helper sessions that advertise a
    /// transcript path but never get written to. They show up as ghost rows with
    /// no content. Detect by: claude provider, no chat/intervention/conversation
    /// content, transcript_path present in clientInfo.sessionFilePath, and the
    /// file on disk is missing or zero bytes.
    nonisolated var isLikelyEmptyClaudePlaceholderForUI: Bool {
        guard provider == .claude else { return false }
        // The Claude Code 2.1.x prewarm/swarm fires SessionStart + PreToolUse hooks for
        // helper session_ids that never persist a rollout file. PI populates chatItems,
        // intervention, and conversationInfo from those hooks, so any in-memory field
        // is unreliable as a "real session" signal. The only ground-truth indicator is
        // the rollout file on disk: real claude sessions always write mode and
        // permission-mode entries within milliseconds of starting. Treat any claude
        // session whose advertised transcript_path is missing or has a zero-byte
        // rollout file as a phantom.
        guard let path = clientInfo.sessionFilePath, !path.isEmpty else {
            return true
        }
        let attrs = try? FileManager.default.attributesOfItem(atPath: path)
        let size = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
        return size == 0
    }

    /// Codex placeholder sessions can be created before a richer thread record is available.
    /// We treat sessions with no rollout path, no visible content, and no live interaction state
    /// as empty placeholders so they can be hidden or deduplicated in UI-facing collections.
    nonisolated var isLikelyEmptyCodexPlaceholderForUI: Bool {
        guard provider == .codex else { return false }
        guard chatItems.isEmpty else { return false }
        guard case .none = intervention else { return false }
        guard clientInfo.sessionFilePath?.isEmpty != false else { return false }
        if hasOnlyTransientCodexProgressContent {
            return true
        }
        guard compactHookMessage == nil else { return false }
        return !hasMeaningfulCodexDisplayContent
    }

    nonisolated var hasMeaningfulCodexDisplayContent: Bool {
        !chatItems.isEmpty
            || intervention != nil
            || (compactHookMessage != nil && !hasOnlyTransientCodexProgressContent)
            || (clientInfo.sessionFilePath?.isEmpty == false)
            || (sessionName?.isEmpty == false)
            || (SessionTextSanitizer.sanitizedDisplayText(previewText) != nil && !hasOnlyTransientCodexProgressContent)
            || (conversationInfo.summary?.isEmpty == false)
            || (conversationInfo.firstUserMessage?.isEmpty == false)
            || (conversationInfo.lastMessage?.isEmpty == false)
    }

    /// Some Codex App continuation updates briefly appear as a new thread ID with only a shallow
    /// status preview (for example "working..."), but without any rollout path or durable history.
    /// We treat those as continuation placeholders so they can be rebound onto the richer thread.
    nonisolated var isLikelyTransientCodexContinuationPlaceholder: Bool {
        guard provider == .codex else { return false }
        guard chatItems.isEmpty else { return false }
        guard intervention == nil else { return false }
        guard clientInfo.sessionFilePath?.isEmpty != false else { return false }
        guard sessionName?.isEmpty != false else { return false }
        guard conversationInfo.summary?.isEmpty != false else { return false }
        guard conversationInfo.firstUserMessage?.isEmpty != false else { return false }
        guard conversationInfo.lastMessage?.isEmpty != false else { return false }
        if let compactHookMessage, !Self.isLikelyGenericCodexProgressText(compactHookMessage) {
            return false
        }
        return hasOnlyTransientCodexProgressContent || isLikelyEmptyCodexPlaceholderForUI
    }

    nonisolated var hasDurableCodexThreadIdentity: Bool {
        !chatItems.isEmpty
            || intervention != nil
            || compactHookMessage != nil
            || (clientInfo.sessionFilePath?.isEmpty == false)
            || (sessionName?.isEmpty == false)
            || (conversationInfo.summary?.isEmpty == false)
            || (conversationInfo.firstUserMessage?.isEmpty == false)
            || (conversationInfo.lastMessage?.isEmpty == false)
    }

    /// OpenCode subagents currently surface as extra shallow sessions on the same
    /// terminal surface. Hide them once the richer parent session is visible.
    nonisolated var isLikelyOpenCodeChildSessionPlaceholderForUI: Bool {
        guard clientInfo.brand == .opencode else { return false }
        guard chatItems.isEmpty else { return false }
        guard intervention == nil else { return false }
        guard sessionName?.isEmpty != false else { return false }
        guard conversationInfo.summary?.isEmpty != false else { return false }
        guard conversationInfo.firstUserMessage?.isEmpty != false else { return false }
        guard conversationInfo.lastMessage?.isEmpty != false else { return false }

        let visibleTexts = [
            SessionTextSanitizer.sanitizedDisplayText(previewText),
            compactHookMessage
        ].compactMap { $0 }

        guard !visibleTexts.isEmpty else { return false }
        return visibleTexts.allSatisfy(Self.isLikelyGenericHookProgressText(_:))
    }

    nonisolated var hasDurableOpenCodeDisplayIdentity: Bool {
        guard clientInfo.brand == .opencode else { return false }

        let visibleTexts = [
            SessionTextSanitizer.sanitizedDisplayText(previewText),
            compactHookMessage,
            SessionTextSanitizer.sanitizedDisplayText(conversationInfo.summary),
            SessionTextSanitizer.sanitizedDisplayText(conversationInfo.firstUserMessage),
            SessionTextSanitizer.sanitizedDisplayText(conversationInfo.lastMessage)
        ].compactMap { $0 }

        return !chatItems.isEmpty
            || intervention != nil
            || (sessionName?.isEmpty == false)
            || visibleTexts.contains(where: { !Self.isLikelyGenericHookProgressText($0) })
    }

    nonisolated func shouldRebindToExistingCodexThread(
        comparedTo other: SessionState,
        maximumRecencyGap: TimeInterval
    ) -> Bool {
        guard sessionId != other.sessionId else { return false }
        guard isLikelyTransientCodexContinuationPlaceholder else { return false }
        guard other.provider == .codex else { return false }
        guard other.hasDurableCodexThreadIdentity else { return false }
        guard normalizedWorkspacePath == other.normalizedWorkspacePath else { return false }

        let recencyGap = abs(lastActivity.timeIntervalSince(other.lastActivity))
        guard recencyGap <= maximumRecencyGap else { return false }
        return true
    }

    nonisolated func shouldHideAsDuplicateCodexPlaceholder(comparedTo other: SessionState) -> Bool {
        guard sessionId != other.sessionId else { return false }
        guard isLikelyEmptyCodexPlaceholderForUI || isLikelyTransientCodexContinuationPlaceholder else { return false }
        guard other.provider == .codex else { return false }
        guard other.hasDurableCodexThreadIdentity else { return false }
        guard normalizedWorkspacePath == other.normalizedWorkspacePath else { return false }

        let sharedIdentity = !codexSurfaceIdentityTokens.isDisjoint(with: other.codexSurfaceIdentityTokens)
        if sharedIdentity {
            return true
        }

        let recencyGap = abs(lastActivity.timeIntervalSince(other.lastActivity))
        if isLikelyTransientCodexContinuationPlaceholder {
            return recencyGap <= Self.codexContinuationPlaceholderHideWindow
        }

        guard other.clientInfo.sessionFilePath?.isEmpty == false else { return false }
        return recencyGap <= 120
    }

    nonisolated func shouldHideAsDuplicateOpenCodeChildSession(comparedTo other: SessionState) -> Bool {
        guard sessionId != other.sessionId else { return false }
        guard isLikelyOpenCodeChildSessionPlaceholderForUI else { return false }
        guard other.clientInfo.brand == .opencode else { return false }
        guard other.hasDurableOpenCodeDisplayIdentity else { return false }
        guard other.phase != .ended else { return false }
        guard normalizedWorkspacePath == other.normalizedWorkspacePath else { return false }
        guard createdAt >= other.createdAt else { return false }

        let sharedIdentity = !hookSurfaceIdentityTokens.isDisjoint(with: other.hookSurfaceIdentityTokens)
        guard sharedIdentity else { return false }

        let recencyGap = abs(lastActivity.timeIntervalSince(other.lastActivity))
        return recencyGap <= Self.openCodeChildSessionHideWindow
    }

    private nonisolated var hasOnlyTransientCodexProgressContent: Bool {
        guard provider == .codex else { return false }
        guard chatItems.isEmpty else { return false }
        guard intervention == nil else { return false }
        guard clientInfo.sessionFilePath?.isEmpty != false else { return false }
        guard sessionName?.isEmpty != false else { return false }
        guard conversationInfo.summary?.isEmpty != false else { return false }
        guard conversationInfo.firstUserMessage?.isEmpty != false else { return false }
        guard conversationInfo.lastMessage?.isEmpty != false else { return false }

        let visibleTexts = [
            SessionTextSanitizer.sanitizedDisplayText(previewText),
            compactHookMessage
        ].compactMap { $0 }

        guard !visibleTexts.isEmpty else { return false }
        return visibleTexts.allSatisfy(Self.isLikelyGenericCodexProgressText(_:))
    }

    private nonisolated static func isLikelyGenericCodexProgressText(_ text: String) -> Bool {
        let normalized = text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: #"^codex\s*:\s*"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"[….]+"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)

        guard !normalized.isEmpty else { return false }

        let exactMatches: Set<String> = [
            "working",
            "working on it",
            "processing",
            "thinking",
            "loading",
            "starting",
            "running",
            "busy",
            "work in progress",
            "codex is still working",
            "工作中",
            "处理中",
            "正在处理",
            "思考中",
            "加载中",
            "准备中",
            "运行中",
            "正在压缩上下文"
        ]
        if exactMatches.contains(normalized) {
            return true
        }

        let containsMatches = [
            "still working",
            "working",
            "processing",
            "thinking",
            "loading",
            "compacting context",
            "工作中",
            "处理中",
            "正在处理",
            "思考中",
            "压缩上下文"
        ]
        return containsMatches.contains { normalized.contains($0) }
    }

    private nonisolated static func isLikelyGenericHookProgressText(_ text: String) -> Bool {
        let normalized = text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: #"[….]+"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)

        guard !normalized.isEmpty else { return false }
        guard normalized.count <= 32 else { return false }

        let exactMatches: Set<String> = [
            "working",
            "working on it",
            "processing",
            "thinking",
            "loading",
            "starting",
            "running",
            "busy",
            "work in progress",
            "idle",
            "ready",
            "工作中",
            "处理中",
            "正在处理",
            "思考中",
            "加载中",
            "准备中",
            "运行中"
        ]
        if exactMatches.contains(normalized) {
            return true
        }

        let containsMatches = [
            "still working",
            "working",
            "processing",
            "thinking",
            "loading",
            "running",
            "waiting",
            "工作中",
            "处理中",
            "正在处理",
            "思考中"
        ]
        return containsMatches.contains { normalized.contains($0) }
    }

    /// Provider label for message prefixes and generic copy.
    nonisolated var providerDisplayName: String {
        clientInfo.assistantLabel(for: provider)
    }

    /// Client label for badges and source-aware copy.
    nonisolated var clientDisplayName: String {
        clientInfo.badgeLabel(for: provider)
    }

    /// Message surfaces keep Codex App branding compact to avoid showing both
    /// "Codex App" and "Codex" inside the same preview block.
    nonisolated var messageBadgeDisplayName: String {
        if provider == .codex, clientInfo.kind == .codexApp {
            return providerDisplayName
        }
        return clientDisplayName
    }

    /// Human-facing actor for questions/approvals. Prefer the IDE host when present.
    nonisolated var interactionDisplayName: String {
        clientInfo.interactionLabel(for: provider)
    }

    /// Optional IDE-host badge when the terminal is hosted inside an editor.
    nonisolated var ideHostBadgeLabel: String? {
        deduplicatedSecondaryBadgeLabel(clientInfo.ideHostBadgeLabel(for: provider))
    }

    /// Optional terminal-source badge for terminal-hosted sessions such as Ghostty or iTerm2.
    nonisolated var terminalSourceBadgeLabel: String? {
        deduplicatedSecondaryBadgeLabel(clientInfo.terminalSourceDisplayName)
    }

    /// Optional permission-mode badge ("Auto" / "Edit" / "Plan") derived from the
    /// Claude Code transcript's current `permissionMode`. The default mode shows no
    /// pill. Only Claude-format transcripts carry this value, so other providers
    /// naturally return nil.
    nonisolated var permissionModeBadgeLabel: String? {
        switch conversationInfo.permissionMode {
        case "auto":
            return "Auto"
        case "acceptEdits":
            return "Edit"
        case "plan":
            return "Plan"
        default:
            return nil
        }
    }

    /// Remote sessions come from the dedicated remote bridge or carry SSH/remote context.
    nonisolated var isRemoteSession: Bool {
        if ingress == .remoteBridge {
            return true
        }

        if clientInfo.remoteHost?.isEmpty == false {
            return true
        }

        guard let transport = clientInfo.transport?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !transport.isEmpty else {
            return false
        }

        return transport.contains("ssh") || transport.contains("remote")
    }

    /// Best hint for matching window title
    nonisolated var windowHint: String {
        conversationInfo.summary ?? projectName
    }

    private nonisolated func deduplicatedSecondaryBadgeLabel(_ label: String?) -> String? {
        guard let trimmedLabel = label?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmedLabel.isEmpty else {
            return nil
        }

        let reservedLabels = [
            messageBadgeDisplayName,
            providerDisplayName,
            clientDisplayName
        ]
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
        .filter { !$0.isEmpty }

        guard !reservedLabels.contains(trimmedLabel.lowercased()) else {
            return nil
        }

        return trimmedLabel
    }

    /// Pending tool name if waiting for approval
    nonisolated var pendingToolName: String? {
        activePermission?.toolName ?? intervention?.title
    }

    /// Pending tool use ID
    nonisolated var pendingToolId: String? {
        activePermission?.toolUseId
    }

    /// Formatted pending tool input for display
    nonisolated var pendingToolInput: String? {
        activePermission?.formattedInput
    }

    /// Last message content
    nonisolated var lastMessage: String? {
        SessionTextSanitizer.sanitizedDisplayText(conversationInfo.lastMessage)
            ?? (clientInfo.isOpenClawGatewayClient ? compactHookMessage : nil)
            ?? SessionTextSanitizer.sanitizedDisplayText(previewText)
            ?? (!clientInfo.isOpenClawGatewayClient ? compactHookMessage : nil)
            ?? SessionTextSanitizer.sanitizedDisplayText(intervention?.summaryText)
    }

    nonisolated var shouldHideProjectContextInUI: Bool {
        clientInfo.isOpenClawGatewayClient
    }

    /// Latest hook bridge message formatted for compact notch display.
    nonisolated var compactHookMessage: String? {
        guard let latestHookMessage else { return nil }
        let normalized = latestHookMessage
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if normalized.caseInsensitiveCompare("Stop") == .orderedSame {
            return nil
        }
        return normalized.isEmpty ? nil : normalized
    }

    /// Last message role
    nonisolated var lastMessageRole: String? {
        conversationInfo.lastMessageRole
    }

    /// Last tool name
    nonisolated var lastToolName: String? {
        conversationInfo.lastToolName
    }

    /// Summary
    nonisolated var summary: String? {
        conversationInfo.summary
    }

    /// First user message
    nonisolated var firstUserMessage: String? {
        conversationInfo.firstUserMessage
    }

    /// Last user message date
    nonisolated var lastUserMessageDate: Date? {
        conversationInfo.lastUserMessageDate
    }

    /// Whether the session can be interacted with
    nonisolated var canInteract: Bool {
        phase.needsAttention || intervention != nil
    }

    /// Whether the session is waiting on a question-like intervention
    nonisolated var needsQuestionResponse: Bool {
        intervention?.kind == .question
    }

    /// Whether the session is waiting on an approval-like decision.
    nonisolated var needsApprovalResponse: Bool {
        phase.isWaitingForApproval || intervention?.kind == .approval
    }

    nonisolated var scopedApprovalAction: SessionScopedApprovalAction? {
        guard needsApprovalResponse else { return nil }

        if ingress == .codexAppServer || intervention?.supportsSessionScope == true {
            return .allowSession
        }

        if provider == .claude, clientInfo.kind == .claudeCode {
            return .autoApprove
        }

        return nil
    }

    nonisolated var supportsSessionScopedApproval: Bool {
        scopedApprovalAction != nil
    }

    /// The primary UI keeps recently-active conversations "warm" for a short grace
    /// window so a fresh follow-up does not immediately look dormant once the provider
    /// sends an idle heartbeat.
    nonisolated var presentsActiveInUI: Bool {
        if phase.isActive {
            return true
        }
        if needsManualAttention {
            return false
        }
        guard hasDurableConversationContentForUI else {
            return false
        }
        return Date().timeIntervalSince(lastActivity) < Self.minimalCompactDelay
    }

    /// Timestamp used when sorting sessions that need manual attention.
    nonisolated var attentionRequestedAt: Date? {
        if let permission = activePermission {
            return permission.receivedAt
        }
        if needsAttention {
            return lastActivity
        }
        return nil
    }

    /// Timestamp used for recency ordering once attention-demanding sessions are handled.
    /// Keep actively-running sessions anchored to their live activity time so a
    /// backfilled transcript timestamp from the first parsed user message cannot
    /// make the row jump backward during an in-flight update.
    nonisolated var queueSortActivityDate: Date {
        if presentsActiveInUI {
            return lastActivity
        }
        return lastUserMessageDate ?? lastActivity
    }

    /// Sessions with no new activity for long enough should disappear from the primary list
    /// until a new event or message refreshes `lastActivity`.
    nonisolated var shouldAutoArchiveFromPrimaryUI: Bool {
        if needsManualAttention {
            return false
        }
        return Date().timeIntervalSince(lastActivity) >= Self.autoArchiveDelay
    }

    /// Whether this session recently completed and should still appear in hover previews.
    nonisolated var isRecentlyCompleted: Bool {
        // `.ended` is a real completion for any provider; `.idle` only counts as
        // "completed" for Codex (whose finished turns settle as `.idle` rather than
        // `.waitingForInput`), matching `SessionCompletionStateEvaluator`'s Codex
        // idle-completion rule. Other providers' `.idle` is not a completion.
        let isCompletionPhase = phase == .ended || (phase == .idle && provider == .codex)
        guard isCompletionPhase else { return false }
        return Date().timeIntervalSince(lastActivity) < Self.minimalCompactDelay
    }

    /// Older background sessions collapse to a header-only presentation in compact surfaces.
    nonisolated var shouldUseMinimalCompactPresentation: Bool {
        if shouldAutoArchiveFromPrimaryUI {
            return false
        }
        if phase == .ended, shouldShowArchiveActionInPrimaryUI {
            return false
        }
        if presentsActiveInUI || needsManualAttention {
            return false
        }
        return Date().timeIntervalSince(lastActivity) >= Self.minimalCompactDelay
    }

    /// Whether the session list should offer a manual archive action for this row.
    nonisolated var shouldShowArchiveActionInPrimaryUI: Bool {
        switch phase {
        case .idle:
            return true
        case .waitingForInput:
            return intervention == nil
        case .ended:
            return Date().timeIntervalSince(lastActivity) >= Self.endedArchiveActionDelay
        case .processing, .compacting, .waitingForApproval:
            return false
        }
    }

    nonisolated func shouldSortBeforeInQueue(_ other: SessionState) -> Bool {
        if presentsActiveInUI != other.presentsActiveInUI {
            return presentsActiveInUI
        }

        if needsManualAttention != other.needsManualAttention {
            return needsManualAttention
        }

        if needsManualAttention, other.needsManualAttention {
            let dateA = attentionRequestedAt ?? createdAt
            let dateB = other.attentionRequestedAt ?? other.createdAt
            if dateA != dateB {
                return dateA < dateB
            }
        }

        let priorityA = queuePhasePriority
        let priorityB = other.queuePhasePriority
        if priorityA != priorityB {
            return priorityA < priorityB
        }

        let dateA = queueSortActivityDate
        let dateB = other.queueSortActivityDate
        if dateA != dateB {
            return dateA > dateB
        }

        return stableId < other.stableId
    }

    private nonisolated var queuePhasePriority: Int {
        if needsManualAttention {
            return 0
        }

        switch phase {
        case .processing, .compacting:
            return 1
        case .idle:
            return presentsActiveInUI ? 1 : 2
        case .ended:
            return presentsActiveInUI ? 1 : 3
        case .waitingForInput, .waitingForApproval:
            return 0
        }
    }

    private nonisolated var hasDurableConversationContentForUI: Bool {
        !chatItems.isEmpty
            || lastUserMessageDate != nil
            || SessionTextSanitizer.sanitizedDisplayText(conversationInfo.lastMessage) != nil
            || SessionTextSanitizer.sanitizedDisplayText(conversationInfo.summary) != nil
            || SessionTextSanitizer.sanitizedDisplayText(conversationInfo.firstUserMessage) != nil
    }

    private nonisolated var normalizedWorkspacePath: String? {
        let trimmed = cwd.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != "/" else { return nil }
        return URL(fileURLWithPath: trimmed).standardizedFileURL.path.lowercased()
    }

    private nonisolated var codexSurfaceIdentityTokens: Set<String> {
        func normalized(_ value: String?) -> String? {
            let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let trimmed, !trimmed.isEmpty else { return nil }
            return trimmed.lowercased()
        }

        func normalizedClientName(_ value: String?) -> String? {
            guard let normalized = normalized(value) else { return nil }
            switch normalized {
            case "codex", "codex app", "codex cli":
                return nil
            default:
                return normalized
            }
        }

        return Set([
            normalizedClientName(clientInfo.name).map { "name:\($0)" },
            normalizedClientName(clientInfo.originator).map { "originator:\($0)" },
            normalized(clientInfo.threadSource).map { "threadSource:\($0)" },
            normalized(clientInfo.terminalBundleIdentifier).map { "terminalBundle:\($0)" },
            normalized(clientInfo.terminalProgram).map { "terminalProgram:\($0)" },
            normalized(clientInfo.transport).map { "transport:\($0)" },
            normalized(clientInfo.remoteHost).map { "remoteHost:\($0)" },
            normalized(clientInfo.terminalSessionIdentifier).map { "terminalSession:\($0)" },
            normalized(clientInfo.iTermSessionIdentifier).map { "itermSession:\($0)" },
            normalized(clientInfo.tmuxSessionIdentifier).map { "tmuxSession:\($0)" },
            normalized(clientInfo.tmuxPaneIdentifier).map { "tmuxPane:\($0)" },
            normalized(clientInfo.processName).map { "process:\($0)" }
        ].compactMap { $0 })
    }

    private nonisolated var hookSurfaceIdentityTokens: Set<String> {
        func normalized(_ value: String?) -> String? {
            let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let trimmed, !trimmed.isEmpty else { return nil }
            return trimmed.lowercased()
        }

        return Set([
            normalized(tty).map { "tty:\($0)" },
            normalized(clientInfo.terminalBundleIdentifier).map { "terminalBundle:\($0)" },
            normalized(clientInfo.terminalProgram).map { "terminalProgram:\($0)" },
            normalized(clientInfo.transport).map { "transport:\($0)" },
            normalized(clientInfo.remoteHost).map { "remoteHost:\($0)" },
            normalized(clientInfo.terminalSessionIdentifier).map { "terminalSession:\($0)" },
            normalized(clientInfo.iTermSessionIdentifier).map { "itermSession:\($0)" },
            normalized(clientInfo.tmuxSessionIdentifier).map { "tmuxSession:\($0)" },
            normalized(clientInfo.tmuxPaneIdentifier).map { "tmuxPane:\($0)" }
        ].compactMap { $0 })
    }
}

// MARK: - Tool Tracker

/// Unified tool tracking - replaces multiple dictionaries in ChatHistoryManager
struct ToolTracker: Equatable, Sendable {
    /// Tools currently in progress, keyed by tool_use_id
    var inProgress: [String: ToolInProgress]

    /// All tool IDs we've seen (for deduplication)
    var seenIds: Set<String>

    /// Last JSONL file offset for incremental parsing
    var lastSyncOffset: UInt64

    /// Last sync timestamp
    var lastSyncTime: Date?

    nonisolated init(
        inProgress: [String: ToolInProgress] = [:],
        seenIds: Set<String> = [],
        lastSyncOffset: UInt64 = 0,
        lastSyncTime: Date? = nil
    ) {
        self.inProgress = inProgress
        self.seenIds = seenIds
        self.lastSyncOffset = lastSyncOffset
        self.lastSyncTime = lastSyncTime
    }

    /// Mark a tool ID as seen, returns true if it was new
    nonisolated mutating func markSeen(_ id: String) -> Bool {
        seenIds.insert(id).inserted
    }

    /// Check if a tool ID has been seen
    nonisolated func hasSeen(_ id: String) -> Bool {
        seenIds.contains(id)
    }

    /// Start tracking a tool
    nonisolated mutating func startTool(id: String, name: String) {
        guard markSeen(id) else { return }
        inProgress[id] = ToolInProgress(
            id: id,
            name: name,
            startTime: Date(),
            phase: .running
        )
    }

    /// Complete a tool
    nonisolated mutating func completeTool(id: String, success: Bool) {
        inProgress.removeValue(forKey: id)
    }
}

/// A tool currently in progress
struct ToolInProgress: Equatable, Sendable {
    let id: String
    let name: String
    let startTime: Date
    var phase: ToolInProgressPhase
}

/// Phase of a tool in progress
enum ToolInProgressPhase: Equatable, Sendable {
    case starting
    case running
    case pendingApproval
}

// MARK: - Subagent State

/// State for Task (subagent) tools
struct SubagentState: Equatable, Sendable {
    /// Active Task tools, keyed by task tool_use_id
    var activeTasks: [String: TaskContext]

    /// Ordered stack of active task IDs (most recent last) - used for proper tool assignment
    /// When multiple Tasks run in parallel, we use insertion order rather than timestamps
    var taskStack: [String]

    /// Mapping of agentId to Task description (for AgentOutputTool display)
    var agentDescriptions: [String: String]

    nonisolated init(activeTasks: [String: TaskContext] = [:], taskStack: [String] = [], agentDescriptions: [String: String] = [:]) {
        self.activeTasks = activeTasks
        self.taskStack = taskStack
        self.agentDescriptions = agentDescriptions
    }

    /// Whether there's an active subagent
    nonisolated var hasActiveSubagent: Bool {
        !activeTasks.isEmpty
    }

    /// Start tracking a Task tool
    nonisolated mutating func startTask(taskToolId: String, description: String? = nil) {
        activeTasks[taskToolId] = TaskContext(
            taskToolId: taskToolId,
            startTime: Date(),
            agentId: nil,
            description: description,
            subagentTools: []
        )
    }

    /// Stop tracking a Task tool
    nonisolated mutating func stopTask(taskToolId: String) {
        activeTasks.removeValue(forKey: taskToolId)
    }

    /// Set the agentId for a Task (called when agent file is discovered)
    nonisolated mutating func setAgentId(_ agentId: String, for taskToolId: String) {
        activeTasks[taskToolId]?.agentId = agentId
        if let description = activeTasks[taskToolId]?.description {
            agentDescriptions[agentId] = description
        }
    }

    /// Add a subagent tool to a specific Task by ID
    nonisolated mutating func addSubagentToolToTask(_ tool: SubagentToolCall, taskId: String) {
        activeTasks[taskId]?.subagentTools.append(tool)
    }

    /// Set all subagent tools for a specific Task (used when updating from agent file)
    nonisolated mutating func setSubagentTools(_ tools: [SubagentToolCall], for taskId: String) {
        activeTasks[taskId]?.subagentTools = tools
    }

    /// Add a subagent tool to the most recent active Task
    nonisolated mutating func addSubagentTool(_ tool: SubagentToolCall) {
        // Find most recent active task (for parallel Task support)
        guard let mostRecentTaskId = activeTasks.keys.max(by: {
            (activeTasks[$0]?.startTime ?? .distantPast) < (activeTasks[$1]?.startTime ?? .distantPast)
        }) else { return }

        activeTasks[mostRecentTaskId]?.subagentTools.append(tool)
    }

    /// Update the status of a subagent tool across all active Tasks
    nonisolated mutating func updateSubagentToolStatus(toolId: String, status: ToolStatus) {
        for taskId in activeTasks.keys {
            if let index = activeTasks[taskId]?.subagentTools.firstIndex(where: { $0.id == toolId }) {
                activeTasks[taskId]?.subagentTools[index].status = status
                return
            }
        }
    }
}

/// Context for an active Task tool
struct TaskContext: Equatable, Sendable {
    let taskToolId: String
    let startTime: Date
    var agentId: String?
    var description: String?
    var subagentTools: [SubagentToolCall]
}
