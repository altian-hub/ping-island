//
//  MiniPromptPresenter.swift
//  PingIsland
//
//  Pure selection logic for the mini (battery saver) surface: given the visible
//  session snapshot, decide which sessions are actually blocking on a human
//  decision and which one to put in front of the user first.
//
//  Kept free of SwiftUI/AppKit so it can be unit tested (see MiniModeTests).
//

import Foundation

enum MiniPromptPresenter {
    /// Whether this session is blocking on a decision the user must make right now.
    ///
    /// Mini mode deliberately ignores "processing", "completed" and every other
    /// informational phase — the whole point of the surface is that it stays dark
    /// until there is a Allow / Always / Deny (or a question) to answer.
    static func isPrompting(_ session: SessionState) -> Bool {
        if let intervention = session.intervention, intervention.kind == .question {
            // An answered question that is waiting on the client to pick the thread
            // back up is no longer the user's move.
            return !intervention.awaitsExternalContinuation
        }

        guard session.needsApprovalResponse else { return false }

        // Auto-approve sessions resolve their own permission prompts within
        // milliseconds; surfacing them would flash a panel the user can't use.
        return !session.autoApprovePermissions
    }

    /// Sessions blocking on a decision, longest-waiting first.
    ///
    /// Oldest-first is deliberate: every one of these agents is stalled on the hook
    /// socket until answered, so serving the freshest prompt first would leave the
    /// agent that has been blocked longest blocked the longest of all.
    static func promptSessions(from instances: [SessionState]) -> [SessionState] {
        instances
            .filter(isPrompting)
            .sorted { lhs, rhs in
                let lhsAt = lhs.attentionRequestedAt ?? lhs.lastActivity
                let rhsAt = rhs.attentionRequestedAt ?? rhs.lastActivity
                if lhsAt == rhsAt {
                    return lhs.stableId < rhs.stableId
                }
                return lhsAt < rhsAt
            }
    }

    /// Identity of a single pending *decision*, not of the session holding it.
    ///
    /// This distinction matters: one session commonly queues several tool calls in
    /// a turn, and `SessionStore.processPermissionApproved` hands straight from
    /// `waitingForApproval(P1)` to `waitingForApproval(P2)` without ever publishing
    /// a non-prompting state. Keying dismissal on the session id therefore hid P2
    /// (and every later tool) for good, leaving the agent blocked with mini dark.
    static func promptIdentity(_ session: SessionState) -> String {
        let decisionId = session.activePermission?.toolUseId
            ?? session.intervention?.id
            ?? ""
        return "\(session.stableId)|\(decisionId)"
    }

    /// The prompts to show, with just-answered ones removed.
    ///
    /// `dismissed` holds decisions the user has already made but that the store has
    /// not caught up with yet. It is a set of `promptIdentity` values: answering two
    /// queued prompts in quick succession would otherwise let the first flash back.
    /// Entries that are no longer live are pruned so the set can't grow unbounded.
    static func visiblePrompts(
        from instances: [SessionState],
        dismissing dismissed: Set<String>
    ) -> (prompts: [SessionState], stillDismissed: Set<String>) {
        let prompts = promptSessions(from: instances)
        let liveIdentities = Set(prompts.map(promptIdentity))
        let stillDismissed = dismissed.intersection(liveIdentities)
        return (
            prompts.filter { !stillDismissed.contains(promptIdentity($0)) },
            stillDismissed
        )
    }

    /// Identity of what the mini card renders.
    ///
    /// The controller rebuilds the panel only when this changes. Rebuilding on every
    /// session-state publish re-assigns the SwiftUI root view and re-sets the window
    /// frame, which cancels an in-flight press gesture — so unrelated publishes
    /// (a Codex poll, another session's progress) would silently eat button clicks.
    /// Anything not listed here must NOT trigger a rebuild.
    static func contentSignature(session: SessionState, queuedCount: Int) -> String {
        [
            session.stableId,
            session.activePermission?.toolUseId ?? "",
            session.activePermission?.toolName ?? "",
            session.intervention?.id ?? "",
            session.intervention.map { $0.awaitsExternalContinuation ? "awaiting" : "open" } ?? "",
            String(queuedCount)
        ].joined(separator: "|")
    }

    /// The prompt to render, preferring whichever the user is already looking at so
    /// the panel doesn't swap out from under a half-filled question form.
    static func activePrompt(
        from instances: [SessionState],
        preferring pinnedStableId: String?
    ) -> SessionState? {
        let prompts = promptSessions(from: instances)
        if let pinnedStableId,
           let pinned = prompts.first(where: { $0.stableId == pinnedStableId }) {
            return pinned
        }
        return prompts.first
    }
}
