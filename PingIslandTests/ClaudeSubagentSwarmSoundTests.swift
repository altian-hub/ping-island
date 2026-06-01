import XCTest
@testable import Ping_Island

/// Probe for suspect #1 in the subagent-swarm "missing prompt" investigation:
/// the notification/sound delta layer.
///
/// The state machine is correct (see ClaudeSubagentSwarmApprovalTests). The
/// surfacing, however, is computed in `NotchView` via
/// `.onChange(of: sessionMonitor.instances)` -> `SessionSoundTransitionEvaluator`,
/// i.e. off the `@Published instances` snapshots. SwiftUI COALESCES rapid
/// `@Published` mutations: when many updates land in one run-loop tick, only the
/// LAST value is delivered to `.onChange`. During a subagent swarm the parent
/// session's phase flips between `.processing` and `.waitingForApproval` many
/// times per tick, so the transient `.waitingForApproval` snapshot is frequently
/// dropped before the evaluator ever sees it.
///
/// These tests show the evaluator behaves correctly for the snapshots it is given,
/// and that the masking is a property of WHICH snapshots reach it.
final class ClaudeSubagentSwarmSoundTests: XCTestCase {

    /// Control: when a `.waitingForApproval` snapshot is actually delivered, the
    /// evaluator emits the attention sound exactly once.
    func testAttentionSoundFiresWhenWaitingSnapshotDelivered() {
        var evaluator = SessionSoundTransitionEvaluator()

        XCTAssertNil(evaluator.evaluate([session("s1", .processing)]),
                     "First snapshot only primes the baseline")

        let outcome = evaluator.evaluate([session("s1", waitingForApproval())])
        XCTAssertEqual(outcome?.event, .attentionRequired)
        XCTAssertEqual(outcome?.sessionIds, ["s1"])
    }

    /// Masking: these are the snapshots `NotchView.onChange` actually receives
    /// during a swarm once SwiftUI coalesces the high-frequency `instances`
    /// updates. The underlying session is genuinely waiting for approval the whole
    /// time, but every DELIVERED snapshot samples it as `.processing` (a sibling
    /// subagent's tool event was the latest mutation in that run-loop tick).
    /// Result: the attention sound never fires — the prompt is silently missed.
    func testAttentionSoundLostWhenCoalescingDropsWaitingSnapshot() {
        var evaluator = SessionSoundTransitionEvaluator()
        // Coalesced delivery: the waiting windows existed in SessionStore but were
        // never the last value in a tick, so onChange only ever saw processing.
        let coalescedSnapshots: [[SessionState]] = [
            [session("swarm", .processing)],  // prime
            [session("swarm", .processing)],
            [session("swarm", .processing)],
            [session("swarm", .processing)],
        ]

        var firedAttention = false
        for snapshot in coalescedSnapshots {
            if evaluator.evaluate(snapshot)?.event == .attentionRequired {
                firedAttention = true
            }
        }

        XCTAssertFalse(firedAttention,
                       "If coalescing never delivers a waitingForApproval snapshot, no attention sound fires")
    }

    /// Priming edge: if the session is ALREADY waiting for approval when the
    /// evaluator first sees it (e.g. the swarm prompt was pending before the view's
    /// first onChange), priming records it in the baseline and the attention sound
    /// never fires for that episode.
    func testAlreadyPendingApprovalAtPrimingNeverFires() {
        var evaluator = SessionSoundTransitionEvaluator()

        XCTAssertNil(evaluator.evaluate([session("swarm", waitingForApproval())]),
                     "Priming snapshot emits no sound")

        // Subsequent identical waiting snapshots: still pending, but already in the
        // baseline, so no NEW attention is detected.
        XCTAssertNil(evaluator.evaluate([session("swarm", waitingForApproval())]))
        XCTAssertNil(evaluator.evaluate([session("swarm", waitingForApproval())]))
    }

    /// Sanity contrast: a delivered processing->waiting->processing->waiting
    /// sequence DOES re-fire attention each time the waiting snapshot is delivered,
    /// confirming the evaluator itself is not the defect — only snapshot delivery is.
    func testDeliveredOscillationReFiresAttention() {
        var evaluator = SessionSoundTransitionEvaluator()
        _ = evaluator.evaluate([session("swarm", .processing)])  // prime

        XCTAssertEqual(evaluator.evaluate([session("swarm", waitingForApproval())])?.event, .attentionRequired)
        // Back to processing: not an attention event, and it clears the attention baseline.
        XCTAssertNotEqual(evaluator.evaluate([session("swarm", .processing)])?.event, .attentionRequired)
        // The next delivered waiting snapshot fires attention again.
        XCTAssertEqual(evaluator.evaluate([session("swarm", waitingForApproval())])?.event, .attentionRequired)
    }

    // MARK: - Helpers

    private func waitingForApproval() -> SessionPhase {
        .waitingForApproval(PermissionContext(
            toolUseId: "read-C",
            toolName: "Read",
            toolInput: nil,
            receivedAt: Date()
        ))
    }

    private func session(_ id: String, _ phase: SessionPhase) -> SessionState {
        SessionState(sessionId: id, cwd: "/repo", phase: phase)
    }
}
