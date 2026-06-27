//
//  SessionSoundTransitionEvaluator.swift
//  PingIsland
//
//  Pure, testable extraction of the notification-sound transition logic that
//  used to live inline in `NotchView.handleSessionSoundTransitions`.
//
//  IMPORTANT (see ClaudeSubagentSwarmSoundTests): this evaluator is delta-based.
//  It only reports `.attentionRequired` when a session id appears in the
//  attention set that was NOT present on the previous call. It is driven from
//  `NotchView` via `.onChange(of: sessionMonitor.instances)`, i.e. off the
//  `@Published instances` snapshots — which SwiftUI COALESCES under rapid update
//  bursts. During a subagent "swarm", the parent session's phase oscillates
//  between `.processing` and `.waitingForApproval` faster than the run loop
//  delivers snapshots, so a transient `waitingForApproval` snapshot can be
//  dropped before it is ever evaluated, and the attention sound never fires.
//

import Foundation

/// Evaluates session-list snapshots and decides which (if any) notification sound
/// should play, using the same priority + delta rules as the original inline logic.
struct SessionSoundTransitionEvaluator {
    /// The sound that should play plus the sessions that triggered it.
    struct Outcome: Equatable {
        let event: NotificationEvent
        let sessionIds: [String]
    }

    private var hasPrimed = false
    private var previousProcessingIds: Set<String> = []
    private var previousAttentionSoundIds: Set<String> = []
    private var previousCompletionSoundIds: Set<String> = []
    private var previousTaskErrorIds: Set<String> = []
    private var previousResourceLimitIds: Set<String> = []

    private static func isProcessing(_ session: SessionState) -> Bool {
        session.phase == .processing || session.phase == .compacting
    }

    private static func isAttention(_ session: SessionState) -> Bool {
        // A question (AskUserQuestion / `request_user_input`) is never auto-resolved —
        // auto-approve only answers permission prompts — so it must ring even for
        // auto-approve sessions, else the session silently stalls on the question.
        // Use the explicit question signal rather than gating on `.waitingForInput`:
        // Codex can surface a question while the app-server snapshot still reports
        // `.processing`, so a phase-gated check would miss the attention cue.
        if session.needsQuestionResponse { return true }
        // Auto-approve sessions resolve their own approval prompts; don't ring for those.
        guard !session.autoApprovePermissions else { return false }
        return session.needsApprovalResponse
    }

    private static func errorToolKeys(_ session: SessionState) -> [String] {
        session.completedErrorToolIDs.map { "\(session.sessionId):\($0)" }
    }

    /// Feed the latest visible-session snapshot. Returns the sound to play, or nil.
    /// The first call after construction primes the baseline and never emits a sound,
    /// mirroring the original `hasPrimedSoundTransitions` behavior.
    mutating func evaluate(_ instances: [SessionState]) -> Outcome? {
        let processingSessions = instances.filter { Self.isProcessing($0) }
        let attentionSessions = instances.filter { Self.isAttention($0) }
        let completedSessions = instances.filter { SessionCompletionStateEvaluator.isCompletedReadySession($0) }
        let resourceLimitedSessions = instances.filter { $0.phase == .compacting }

        let newProcessingIds = Set(processingSessions.map(\.stableId))
        let newAttentionIds = Set(attentionSessions.map(\.stableId))
        let newCompletedIds = Set(completedSessions.map(\.stableId))
        let newTaskErrorIds = Set(instances.flatMap { Self.errorToolKeys($0) })
        let newResourceLimitIds = Set(resourceLimitedSessions.map(\.stableId))

        guard hasPrimed else {
            previousProcessingIds = newProcessingIds
            previousAttentionSoundIds = newAttentionIds
            // Preserve the original priming definition of "completion", which differs
            // from the steady-state `isCompletedReadySession` check used below.
            // Also fold in the steady-state check so already-completed Codex idle
            // sessions present at launch don't fire a spurious startup sound.
            previousCompletionSoundIds = Set(
                instances
                    .filter {
                        ($0.phase == .waitingForInput && $0.intervention == nil)
                            || SessionCompletionStateEvaluator.isCompletedReadySession($0)
                    }
                    .map(\.stableId)
            )
            previousTaskErrorIds = newTaskErrorIds
            previousResourceLimitIds = newResourceLimitIds
            hasPrimed = true
            return nil
        }

        let errorDeltaIds = newTaskErrorIds.subtracting(previousTaskErrorIds)
        let errorSessions = instances.filter { session in
            session.completedErrorToolIDs.contains { errorDeltaIds.contains("\(session.sessionId):\($0)") }
        }
        let completionDeltaIds = newCompletedIds.subtracting(previousCompletionSoundIds)
        let newlyCompletedSessions = completedSessions.filter { completionDeltaIds.contains($0.stableId) }

        let isNewAttention = !newAttentionIds.subtracting(previousAttentionSoundIds).isEmpty
        let isNewCompletion = !completionDeltaIds.isEmpty
        let isNewTaskError = !errorDeltaIds.isEmpty
        let isNewResourceLimit = !newResourceLimitIds.subtracting(previousResourceLimitIds).isEmpty
        let isNewProcessing = !newProcessingIds.subtracting(previousProcessingIds).isEmpty

        let outcome: Outcome?
        if isNewTaskError {
            outcome = Outcome(event: .taskError, sessionIds: errorSessions.map(\.stableId))
        } else if isNewResourceLimit {
            outcome = Outcome(event: .resourceLimit, sessionIds: resourceLimitedSessions.map(\.stableId))
        } else if isNewAttention {
            outcome = Outcome(event: .attentionRequired, sessionIds: attentionSessions.map(\.stableId))
        } else if isNewCompletion {
            outcome = Outcome(event: .taskCompleted, sessionIds: newlyCompletedSessions.map(\.stableId))
        } else if isNewProcessing {
            outcome = Outcome(event: .processingStarted, sessionIds: processingSessions.map(\.stableId))
        } else {
            outcome = nil
        }

        previousProcessingIds = newProcessingIds
        previousAttentionSoundIds = newAttentionIds
        // Keep sessions that already fired their completion sound "claimed" while they
        // stay quiescent (`.idle`/`.ended`, i.e. haven't started a new turn). Otherwise
        // a Codex idle session that ages out of the 60s completion-freshness window and
        // is later re-reported with a fresh `lastActivity` (same finished turn, via a
        // `thread/list` re-poll) would re-enter the completed set and replay the sound.
        // A genuinely new turn passes through `.processing`, dropping the claim so its
        // next completion fires normally. Intersect with present sessions so departed
        // ids don't accumulate.
        let stillQuiescentClaimedIds = previousCompletionSoundIds.intersection(
            Set(instances.filter { $0.phase == .idle || $0.phase == .ended }.map(\.stableId))
        )
        previousCompletionSoundIds = newCompletedIds.union(stillQuiescentClaimedIds)
        previousTaskErrorIds = newTaskErrorIds
        previousResourceLimitIds = newResourceLimitIds

        return outcome
    }
}
