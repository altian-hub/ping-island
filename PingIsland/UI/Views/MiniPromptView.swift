//
//  MiniPromptView.swift
//  PingIsland
//
//  The entire visible surface of mini (battery saver) mode: a single static card
//  asking for one decision. Deliberately animation-free — no TimelineView, no
//  spinner timers, no repeatForever, no mascot — so the window costs nothing to
//  composite while it is up, and nothing at all while it is ordered out.
//

import SwiftUI

struct MiniPromptView: View {
    let session: SessionState
    /// How many other sessions are queued behind this one.
    let queuedCount: Int
    let sessionMonitor: SessionMonitor
    /// Called right after a decision is dispatched so the panel can dismiss
    /// immediately instead of waiting for the state round-trip.
    let onDecision: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            if session.needsApprovalResponse, session.intervention?.kind != .question {
                approvalBody
            } else if let intervention = session.intervention {
                questionBody(intervention)
            }
        }
        .padding(16)
        .frame(width: MiniPromptMetrics.width, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.black.opacity(0.92))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
        )
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(session.interactionDisplayName)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.white)

            Text(session.projectName)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.white.opacity(0.55))
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer(minLength: 4)

            if queuedCount > 0 {
                Text(verbatim: "+\(queuedCount)")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(.white.opacity(0.75))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.white.opacity(0.14)))
            }
        }
    }

    // MARK: - Approval

    private var approvalBody: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(toolLabel)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(TerminalColors.amber.opacity(0.95))
                .lineLimit(1)
                .truncationMode(.middle)

            if let input = session.pendingToolInput, !input.isEmpty {
                Text(input)
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundColor(.white.opacity(0.68))
                    .lineLimit(4)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack(spacing: 8) {
                Button("Deny") {
                    sessionMonitor.denyPermission(sessionId: session.sessionId, reason: nil)
                    onDecision()
                }
                .buttonStyle(MiniPromptButtonStyle(background: Color.white.opacity(0.12)))

                if let scopedAction = session.scopedApprovalAction {
                    Button(AppLocalization.string(scopedAction.buttonTitleKey)) {
                        sessionMonitor.approvePermission(sessionId: session.sessionId, forSession: true)
                        onDecision()
                    }
                    .buttonStyle(
                        MiniPromptButtonStyle(
                            background: TerminalColors.blue.opacity(0.3),
                            foreground: .white.opacity(0.95)
                        )
                    )
                }

                Button("Allow") {
                    sessionMonitor.approvePermission(sessionId: session.sessionId)
                    onDecision()
                }
                .buttonStyle(MiniPromptButtonStyle(background: Color.white.opacity(0.92), foreground: .black))
            }
        }
    }

    private var toolLabel: String {
        guard let toolName = session.pendingToolName else {
            return AppLocalization.string("当前操作")
        }
        if session.activePermission != nil {
            return MCPToolFormatter.formatToolName(toolName)
        }
        return toolName
    }

    // MARK: - Question

    @ViewBuilder
    private func questionBody(_ intervention: SessionIntervention) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if !intervention.title.isEmpty {
                Text(intervention.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.white)
            }

            if !intervention.message.isEmpty {
                Text(intervention.message)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.white.opacity(0.7))
                    .fixedSize(horizontal: false, vertical: true)
            }

            if intervention.supportsInlineResponse {
                SessionQuestionForm(
                    intervention: intervention,
                    submitLabel: "提交所有回答",
                    onSubmit: { payload in
                        sessionMonitor.answerIntervention(sessionId: session.sessionId, answers: payload)
                        onDecision()
                    }
                )
            } else {
                // Some clients (Codex CLI, Qoder) can only be answered in their own
                // window; hand the user straight there instead of a dead form.
                Button {
                    Task {
                        _ = await SessionLauncher.shared.activateClientApplication(session)
                    }
                } label: {
                    Text(verbatim: AppLocalization.format("打开 %@ 回答", session.interactionDisplayName))
                }
                .buttonStyle(MiniPromptButtonStyle(background: Color.white.opacity(0.9), foreground: .black))
            }
        }
    }
}

enum MiniPromptMetrics {
    static let width: CGFloat = 380
    /// Gap between the panel and the top edge of the screen's visible frame.
    static let topInset: CGFloat = 12
}

private struct MiniPromptButtonStyle: ButtonStyle {
    var background: Color
    var foreground: Color = .white

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .foregroundColor(foreground)
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(background.opacity(configuration.isPressed ? 0.7 : 1))
            )
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}
