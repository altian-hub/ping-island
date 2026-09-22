import Foundation
import XCTest
@testable import Ping_Island

/// Covers the mini (battery saver) surface: which sessions it puts in front of the
/// user, and the low-power gates that keep it quiet and cheap otherwise.
final class MiniModeTests: XCTestCase {

    // MARK: - Prompt selection

    func testApprovalSessionIsAPrompt() {
        XCTAssertTrue(MiniPromptPresenter.isPrompting(session("a", phase: waitingForApproval())))
    }

    func testProcessingAndCompletedSessionsAreNotPrompts() {
        XCTAssertFalse(MiniPromptPresenter.isPrompting(session("a", phase: .processing)))
        XCTAssertFalse(MiniPromptPresenter.isPrompting(session("b", phase: .waitingForInput)))
        XCTAssertFalse(MiniPromptPresenter.isPrompting(session("c", phase: .idle)))
        XCTAssertFalse(MiniPromptPresenter.isPrompting(session("d", phase: .ended)))
    }

    func testAutoApproveSessionDoesNotPrompt() {
        var state = session("auto", phase: waitingForApproval())
        state.autoApprovePermissions = true
        XCTAssertFalse(MiniPromptPresenter.isPrompting(state))
    }

    func testQuestionPromptsEvenWhenAutoApproveIsOn() {
        // Auto-approve only answers permission requests; a question would stall the
        // session forever if mini mode stayed dark for it.
        var state = session("q", phase: .waitingForInput, intervention: question())
        state.autoApprovePermissions = true
        XCTAssertTrue(MiniPromptPresenter.isPrompting(state))
    }

    func testAnsweredQuestionAwaitingClientIsNoLongerAPrompt() {
        let answered = question(metadata: ["continuationState": "awaiting_client_followup"])
        let state = session("q", phase: .waitingForInput, intervention: answered)
        XCTAssertFalse(MiniPromptPresenter.isPrompting(state))
    }

    func testPromptSessionsAreOrderedLongestWaitingFirst() {
        let older = session("older", phase: waitingForApproval(at: Date(timeIntervalSince1970: 100)))
        let newer = session("newer", phase: waitingForApproval(at: Date(timeIntervalSince1970: 500)))

        let ordered = MiniPromptPresenter.promptSessions(from: [newer, older])
        XCTAssertEqual(ordered.map(\.stableId), [older.stableId, newer.stableId])
    }

    func testActivePromptStaysPinnedWhileTheUserIsAnsweringIt() {
        let older = session("older", phase: waitingForApproval(at: Date(timeIntervalSince1970: 100)))
        let newer = session("newer", phase: waitingForApproval(at: Date(timeIntervalSince1970: 500)))

        let active = MiniPromptPresenter.activePrompt(
            from: [older, newer],
            preferring: older.stableId
        )
        XCTAssertEqual(active?.stableId, older.stableId)
    }

    func testActivePromptMovesOnOnceThePinnedOneIsResolved() {
        let newer = session("newer", phase: waitingForApproval(at: Date(timeIntervalSince1970: 500)))
        let resolved = session("older", phase: .processing)

        let active = MiniPromptPresenter.activePrompt(
            from: [resolved, newer],
            preferring: resolved.stableId
        )
        XCTAssertEqual(active?.stableId, newer.stableId)
    }

    func testNoPromptWhenNothingNeedsADecision() {
        XCTAssertNil(
            MiniPromptPresenter.activePrompt(
                from: [session("a", phase: .processing), session("b", phase: .idle)],
                preferring: nil
            )
        )
    }

    // MARK: - Multiple concurrent prompts

    func testQueuedPromptsServeTheLongestWaitingAgentFirst() {
        let older = session("a", phase: waitingForApproval(at: Date(timeIntervalSince1970: 100)))
        let newer = session("b", phase: waitingForApproval(at: Date(timeIntervalSince1970: 200)))
        let newest = session("c", phase: waitingForApproval(at: Date(timeIntervalSince1970: 300)))

        let (prompts, _) = MiniPromptPresenter.visiblePrompts(
            from: [older, newest, newer],
            dismissing: [:]
        )
        XCTAssertEqual(prompts.map(\.stableId), [older.stableId, newer.stableId, newest.stableId])
    }

    func testAnsweringOnePromptAdvancesToTheNext() {
        let first = session("a", phase: waitingForApproval(at: Date(timeIntervalSince1970: 100)))
        let second = session("b", phase: waitingForApproval(at: Date(timeIntervalSince1970: 200)))

        // User answers the displayed (longest-waiting) prompt; store hasn't caught up.
        let (prompts, stillDismissed) = MiniPromptPresenter.visiblePrompts(
            from: [first, second],
            dismissing: [MiniPromptPresenter.promptIdentity(first): Date()]
        )
        XCTAssertEqual(prompts.map(\.stableId), [second.stableId])
        XCTAssertEqual(
            Set(stillDismissed.keys),
            [MiniPromptPresenter.promptIdentity(first)]
        )
    }

    func testAnsweringTwoPromptsQuicklyDoesNotResurrectTheFirst() {
        // Regression: a single stored id meant the second decision overwrote the
        // first, letting the already-answered card flash back on screen.
        let first = session("a", phase: waitingForApproval(at: Date(timeIntervalSince1970: 100)))
        let second = session("b", phase: waitingForApproval(at: Date(timeIntervalSince1970: 200)))

        let (prompts, _) = MiniPromptPresenter.visiblePrompts(
            from: [first, second],
            dismissing: [
                MiniPromptPresenter.promptIdentity(first): Date(),
                MiniPromptPresenter.promptIdentity(second): Date()
            ]
        )
        XCTAssertTrue(prompts.isEmpty, "both answered prompts must stay hidden")
    }

    func testDismissedIdsArePrunedOnceTheStoreCatchesUp() {
        let resolved = session("a", phase: .processing)

        let (prompts, stillDismissed) = MiniPromptPresenter.visiblePrompts(
            from: [resolved],
            dismissing: [MiniPromptPresenter.promptIdentity(resolved): Date()]
        )
        XCTAssertTrue(prompts.isEmpty)
        XCTAssertTrue(stillDismissed.isEmpty, "stale ids must not accumulate")
    }

    func testAnsweringOneToolDoesNotSwallowTheSameSessionsNextPrompt() {
        // Regression: Claude routinely queues several tool calls in one turn, and
        // SessionStore transitions straight from waitingForApproval(P1) to
        // waitingForApproval(P2) with no non-prompting publish in between. Keying
        // the dismissal on the session hid P2 forever and hung the agent.
        let p1 = session("a", phase: .waitingForApproval(PermissionContext(
            toolUseId: "tool-1", toolName: "Bash", toolInput: nil, receivedAt: Date()
        )))
        let p2 = session("a", phase: .waitingForApproval(PermissionContext(
            toolUseId: "tool-2", toolName: "Write", toolInput: nil, receivedAt: Date()
        )))

        let dismissed = [MiniPromptPresenter.promptIdentity(p1): Date()]
        let (prompts, _) = MiniPromptPresenter.visiblePrompts(from: [p2], dismissing: dismissed)

        XCTAssertEqual(
            prompts.map(\.stableId),
            [p2.stableId],
            "the session's next queued tool must still prompt"
        )
    }

    func testPromptIdentityDistinguishesToolsWithinOneSession() {
        let p1 = session("a", phase: .waitingForApproval(PermissionContext(
            toolUseId: "tool-1", toolName: "Bash", toolInput: nil, receivedAt: Date()
        )))
        let p2 = session("a", phase: .waitingForApproval(PermissionContext(
            toolUseId: "tool-2", toolName: "Bash", toolInput: nil, receivedAt: Date()
        )))
        XCTAssertNotEqual(
            MiniPromptPresenter.promptIdentity(p1),
            MiniPromptPresenter.promptIdentity(p2)
        )
    }

    func testDismissedPromptReappearsOnceTheTTLExpires() {
        // Several dispatch paths can return without ever reaching the store. In
        // mini there is no other surface, so a permanently-hidden prompt means a
        // permanently-blocked agent.
        let state = session("a", phase: waitingForApproval())
        let identity = MiniPromptPresenter.promptIdentity(state)
        let answeredAt = Date()

        let (stillHidden, _) = MiniPromptPresenter.visiblePrompts(
            from: [state],
            dismissing: [identity: answeredAt],
            now: answeredAt.addingTimeInterval(MiniPromptPresenter.dismissalTTL - 1)
        )
        XCTAssertTrue(stillHidden.isEmpty, "should stay hidden inside the TTL")

        let (resurfaced, stillDismissed) = MiniPromptPresenter.visiblePrompts(
            from: [state],
            dismissing: [identity: answeredAt],
            now: answeredAt.addingTimeInterval(MiniPromptPresenter.dismissalTTL + 1)
        )
        XCTAssertEqual(resurfaced.map(\.stableId), [state.stableId])
        XCTAssertTrue(stillDismissed.isEmpty, "expired entries must be pruned")
    }

    func testTTLExpiryOfOnePromptDoesNotResurfaceAnother() {
        let a = session("a", phase: waitingForApproval(at: Date(timeIntervalSince1970: 10)))
        let b = session("b", phase: waitingForApproval(at: Date(timeIntervalSince1970: 20)))
        let now = Date()

        let (prompts, _) = MiniPromptPresenter.visiblePrompts(
            from: [a, b],
            dismissing: [
                MiniPromptPresenter.promptIdentity(a): now.addingTimeInterval(-(MiniPromptPresenter.dismissalTTL + 1)),
                MiniPromptPresenter.promptIdentity(b): now
            ],
            now: now
        )
        XCTAssertEqual(prompts.map(\.stableId), [a.stableId])
    }

    // MARK: - Panel stability (clicks must not be eaten)

    func testSignatureIsStableAcrossUnrelatedSessionChurn() {
        // A Codex poll or another session's progress bumps lastActivity and
        // republishes. If that changed the signature the panel would be rebuilt
        // mid-click and the press gesture cancelled.
        var before = session("a", phase: waitingForApproval(at: Date(timeIntervalSince1970: 10)))
        before.lastActivity = Date(timeIntervalSince1970: 10)
        before.previewText = "running tests"

        var after = before
        after.lastActivity = Date(timeIntervalSince1970: 99)
        after.previewText = "still running tests, now with more output"

        XCTAssertEqual(
            MiniPromptPresenter.contentSignature(session: before, queuedCount: 0),
            MiniPromptPresenter.contentSignature(session: after, queuedCount: 0)
        )
    }

    func testSignatureChangesWhenTheDecisionItselfChanges() {
        let first = session("a", phase: .waitingForApproval(PermissionContext(
            toolUseId: "tool-1", toolName: "Bash", toolInput: nil, receivedAt: Date()
        )))
        let second = session("a", phase: .waitingForApproval(PermissionContext(
            toolUseId: "tool-2", toolName: "Write", toolInput: nil, receivedAt: Date()
        )))

        XCTAssertNotEqual(
            MiniPromptPresenter.contentSignature(session: first, queuedCount: 0),
            MiniPromptPresenter.contentSignature(session: second, queuedCount: 0)
        )
    }

    func testSignatureChangesWhenTheQueueDepthChanges() {
        let state = session("a", phase: waitingForApproval())
        XCTAssertNotEqual(
            MiniPromptPresenter.contentSignature(session: state, queuedCount: 0),
            MiniPromptPresenter.contentSignature(session: state, queuedCount: 2)
        )
    }

    // MARK: - Low-power gates

    func testMiniIsTheOnlyLowPowerSurface() {
        XCTAssertTrue(IslandSurfaceMode.mini.isLowPower)
        XCTAssertFalse(IslandSurfaceMode.notch.isLowPower)
        XCTAssertFalse(IslandSurfaceMode.floatingPet.isLowPower)
    }

    func testPersistedSurfaceModeFallsBackToNotchForUnknownValues() {
        let defaults = UserDefaults.standard
        let original = defaults.string(forKey: IslandSurfaceMode.defaultsKey)
        defer {
            if let original {
                defaults.set(original, forKey: IslandSurfaceMode.defaultsKey)
            } else {
                defaults.removeObject(forKey: IslandSurfaceMode.defaultsKey)
            }
        }

        defaults.set("mini", forKey: IslandSurfaceMode.defaultsKey)
        XCTAssertEqual(IslandSurfaceMode.persisted, .mini)
        XCTAssertTrue(AppSettings.isLowPowerModeEnabled)

        defaults.set("not-a-mode", forKey: IslandSurfaceMode.defaultsKey)
        XCTAssertEqual(IslandSurfaceMode.persisted, .notch)
        XCTAssertFalse(AppSettings.isLowPowerModeEnabled)
    }

    func testTranscriptWatchingIsSuppressedInMiniMode() {
        let event = HookEvent(
            sessionId: "s1",
            cwd: "/repo",
            event: "PreToolUse",
            status: "thinking",
            provider: .claude,
            clientInfo: SessionClientInfo(kind: .claudeCode, profileID: "claude", name: "Claude"),
            pid: nil,
            tty: nil,
            tool: nil,
            toolInput: nil,
            toolUseId: nil,
            notificationType: nil,
            message: nil,
            ingress: .hookBridge
        )

        XCTAssertTrue(
            SessionMonitor.shouldWatchTranscript(for: event, phase: .processing, isLowPowerMode: false)
        )
        XCTAssertFalse(
            SessionMonitor.shouldWatchTranscript(for: event, phase: .processing, isLowPowerMode: true)
        )
    }

    func testMiniModeOnlyChimesForApprovalHookEvents() {
        XCTAssertTrue(SoundManager.shouldPlay(eventName: "PermissionRequest", isLowPowerMode: true))
        XCTAssertFalse(SoundManager.shouldPlay(eventName: "SessionStart", isLowPowerMode: true))
        XCTAssertFalse(SoundManager.shouldPlay(eventName: "Stop", isLowPowerMode: true))
        XCTAssertFalse(SoundManager.shouldPlay(eventName: "UserPromptSubmit", isLowPowerMode: true))

        // Every surface other than mini keeps the full set.
        XCTAssertTrue(SoundManager.shouldPlay(eventName: "Stop", isLowPowerMode: false))
    }

    // MARK: - Helpers

    private func waitingForApproval(at receivedAt: Date = Date()) -> SessionPhase {
        .waitingForApproval(PermissionContext(
            toolUseId: "tool-1",
            toolName: "Bash",
            toolInput: nil,
            receivedAt: receivedAt
        ))
    }

    private func question(metadata: [String: String] = [:]) -> SessionIntervention {
        SessionIntervention(
            id: "intervention-1",
            kind: .question,
            title: "Which approach?",
            message: "Pick one",
            options: [],
            questions: [
                SessionInterventionQuestion(
                    id: "q1",
                    header: "1.",
                    prompt: "Which approach?",
                    detail: nil,
                    options: [
                        SessionInterventionOption(id: "o1", title: "A", detail: nil),
                        SessionInterventionOption(id: "o2", title: "B", detail: nil)
                    ],
                    allowsMultiple: false,
                    allowsOther: false,
                    isSecret: false
                )
            ],
            supportsSessionScope: false,
            metadata: metadata
        )
    }

    private func session(
        _ id: String,
        phase: SessionPhase,
        intervention: SessionIntervention? = nil
    ) -> SessionState {
        var state = SessionState(sessionId: id, cwd: "/repo", phase: phase)
        state.intervention = intervention
        return state
    }
}
