import SwiftUI

private struct SessionCompletionContentHeightPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

struct SessionCompletionNotification: Equatable, Identifiable {
    enum Kind: String, Equatable {
        case completed
        case ended

        var statusLabel: String {
            switch self {
            case .completed:
                return "完成"
            case .ended:
                return "结束"
            }
        }
    }

    let id: UUID
    var session: SessionState
    let kind: Kind
    let queuedAt: Date

    init(
        id: UUID = UUID(),
        session: SessionState,
        kind: Kind,
        queuedAt: Date = Date()
    ) {
        self.id = id
        self.session = session
        self.kind = kind
        self.queuedAt = queuedAt
    }
}

enum SessionCompletionPreviewBuilder {
    static func latestUserText(for session: SessionState) -> String? {
        for item in session.chatItems.reversed() {
            if case .user(let text) = item.type {
                return sanitized(text)
            }
        }
        return sanitized(session.firstUserMessage)
    }

    static func latestAssistantText(for session: SessionState) -> String? {
        for item in session.chatItems.reversed() {
            switch item.type {
            case .assistant(let text):
                return sanitized(text)
            case .thinking(let text):
                return sanitized(text)
            case .toolCall(let tool):
                let preview = sanitized(tool.inputPreview)
                let label = MCPToolFormatter.formatToolName(tool.name)
                return preview.map { "\(label) \($0)" } ?? label
            case .interrupted:
                return "已中断"
            case .user:
                continue
            }
        }

        if let intervention = session.intervention {
            return sanitized(intervention.summaryText)
        }

        return sanitized(session.previewText) ?? sanitized(session.lastMessage)
    }

    static func sanitized(_ text: String?) -> String? {
        guard let text else { return nil }
        let collapsed = text
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return collapsed.isEmpty ? nil : collapsed
    }
}

enum SessionCompletionStateEvaluator {
    /// How recently a Codex `.idle` session must have been active to count as a
    /// just-finished turn. Codex app-server polls `thread/list` and re-imports
    /// already-finished historical threads, whose `.idle` + assistant-tail shape is
    /// indistinguishable from a fresh completion except by recency. Mirrors
    /// upstream's 60s untracked-session notification window.
    static let codexIdleCompletionFreshnessWindow: TimeInterval = 60

    static func isCompletedReadySession(_ session: SessionState, now: Date = Date()) -> Bool {
        guard session.intervention == nil else { return false }
        // Completed Codex turns often settle as `.idle` rather than transitioning
        // through `.waitingForInput`, so treat a Codex idle assistant-tail snapshot
        // as completed-ready too (restores the Codex completion checkmark + sound) —
        // but only while recently active, so re-imported historical threads don't
        // fire spurious completion popups + sounds.
        guard session.phase == .waitingForInput || isCompletedCodexIdleSession(session, now: now) else {
            return false
        }
        return hasCompletedAssistantReply(for: session)
    }

    private static func isCompletedCodexIdleSession(_ session: SessionState, now: Date = Date()) -> Bool {
        guard session.provider == .codex, session.phase == .idle else { return false }
        return now.timeIntervalSince(session.lastActivity) <= codexIdleCompletionFreshnessWindow
    }

    /// Treat tool-only or commentary-only updates as in-progress. A completion notification
    /// should only fire once the session has an actual assistant reply ready for the user.
    static func hasCompletedAssistantReply(for session: SessionState) -> Bool {
        for item in session.chatItems.reversed() {
            switch item.type {
            case .assistant:
                return true
            case .user, .thinking, .toolCall, .interrupted:
                return false
            }
        }

        return session.lastMessageRole == "assistant"
    }
}

/// Decides whether a session transition should surface a completion/ended popup.
/// Kept separate from `SessionCompletionStateEvaluator` (pure state) so the recency
/// policy is unit-testable with an injected `now`.
enum SessionCompletionNotificationPolicy {
    /// A previously-tracked session can re-enter a completed/ended phase long after it
    /// actually finished — a stale app-server snapshot, or a re-imported historical
    /// thread. Only surface a notification when the session was active within this
    /// window, so stale transitions can't requeue alerts. Mirrors upstream's 60s window.
    static let notificationRecencyWindow: TimeInterval = 60

    static func shouldQueueCompletedNotification(
        for session: SessionState,
        previousPhase: SessionPhase?,
        now: Date = Date()
    ) -> Bool {
        guard SessionCompletionStateEvaluator.isCompletedReadySession(session, now: now) else { return false }
        guard previousPhase != .waitingForInput else { return false }
        return isRecentlyActive(session, now: now)
    }

    static func shouldQueueEndedNotification(
        for session: SessionState,
        previousPhase: SessionPhase?,
        now: Date = Date()
    ) -> Bool {
        guard session.phase == .ended else { return false }
        guard previousPhase != .ended else { return false }
        guard previousPhase != .waitingForInput else { return false }
        return isRecentlyActive(session, now: now)
    }

    private static func isRecentlyActive(_ session: SessionState, now: Date) -> Bool {
        now.timeIntervalSince(session.lastActivity) <= notificationRecencyWindow
    }
}

struct SessionCompletionNotificationView: View {
    static let minimumContentHeight: CGFloat = 172
    static let maximumAssistantContentHeight: CGFloat = 300

    let notification: SessionCompletionNotification
    let onHoverChanged: (Bool) -> Void
    let onDismiss: () -> Void

    @ObservedObject private var settings = AppSettings.shared
    @State private var measuredAssistantContentHeight: CGFloat = 0

    private var session: SessionState { notification.session }

    private var assistantLabel: String {
        session.providerDisplayName
    }

    private var providerTint: Color {
        session.clientTintColor
    }

    private var assistantPrefixColor: Color {
        providerTint.opacity(session.presentsActiveInUI ? 0.96 : 0.9)
    }

    private var assistantTextColor: Color {
        .white.opacity(0.82)
    }

    private var bodyFontSize: CGFloat {
        max(12, CGFloat(settings.contentFontSize))
    }

    private var userText: String? {
        SessionCompletionPreviewBuilder.latestUserText(for: session)
    }

    private var assistantText: String? {
        SessionCompletionPreviewBuilder.latestAssistantText(for: session)
    }

    private var assistantContentHeight: CGFloat? {
        guard measuredAssistantContentHeight > 0 else { return nil }
        return min(measuredAssistantContentHeight, Self.maximumAssistantContentHeight)
    }

    private var assistantLabelText: String {
        assistantLabel + "："
    }

    @ViewBuilder
    private var assistantContent: some View {
        if let assistantText {
            MarkdownText(
                assistantText,
                color: assistantTextColor,
                fontSize: bodyFontSize
            )
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
        } else {
            Text("会话已完成，点击查看完整结果。")
                .font(.system(size: bodyFontSize, weight: .medium))
                .foregroundColor(.white.opacity(0.7))
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var assistantScrollView: some View {
        ScrollView(.vertical, showsIndicators: true) {
            assistantContent
                .background(
                    GeometryReader { proxy in
                        Color.clear.preference(
                            key: SessionCompletionContentHeightPreferenceKey.self,
                            value: proxy.size.height
                        )
                    }
                )
        }
        .frame(height: assistantContentHeight, alignment: .topLeading)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var assistantSection: some View {
        HStack(alignment: .top, spacing: 10) {
            Text(assistantLabelText)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(assistantPrefixColor)

            assistantScrollView
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text("你：")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.white.opacity(0.48))

                    Text(userText ?? session.titleOnlySubagentDisplayTitle)
                        .font(.system(size: bodyFontSize, weight: .semibold))
                        .foregroundColor(.white.opacity(0.88))
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    Text(notification.kind.statusLabel)
                        .font(.system(size: 13, weight: .bold))
                        .foregroundColor(.white.opacity(0.5))
                        .fixedSize()
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)

                Rectangle()
                    .fill(Color.white.opacity(0.05))
                    .frame(height: 1)

                assistantSection
            }
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color.white.opacity(0.055))
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.06), lineWidth: 1)
                    )
            )

        }
        .padding(.horizontal, 14)
        .padding(.top, 8)
        .padding(.bottom, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .onPreferenceChange(SessionCompletionContentHeightPreferenceKey.self) { height in
            guard height > 0 else { return }
            measuredAssistantContentHeight = height
        }
        .onHover { hovering in
            onHoverChanged(hovering)
        }
        .onDisappear {
            onHoverChanged(false)
        }
        .onTapGesture {
            onDismiss()
        }
    }
}
