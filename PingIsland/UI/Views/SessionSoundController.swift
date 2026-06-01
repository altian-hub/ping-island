//
//  SessionSoundController.swift
//  PingIsland
//
//  Shared notification-sound driver used by BOTH the notch (`NotchView`) and the
//  floating buddy (`FloatingPetView`). Previously the sound logic lived only in
//  `NotchView`, so in floatingPet surface mode no notification sounds played at
//  all (NotchView isn't mounted). Centralizing it here lets either surface alert
//  the user audibly when a session needs attention / completes / errors.
//
//  Only one surface is mounted at a time (notch OR buddy), and each holds its own
//  controller instance, so there is no double-play.
//

import Foundation

@MainActor
final class SessionSoundController {
    private var evaluator = SessionSoundTransitionEvaluator()

    /// Evaluate the latest visible-session snapshot, play a notification sound if a
    /// new sound-worthy transition occurred, and return the acted-on outcome (for
    /// diagnostics/logging at the call site).
    @discardableResult
    func handle(_ instances: [SessionState]) -> SessionSoundTransitionEvaluator.Outcome? {
        guard let outcome = evaluator.evaluate(instances) else { return nil }
        let triggered = instances.filter { outcome.sessionIds.contains($0.stableId) }
        playEventSoundIfNeeded(outcome.event, sessions: triggered)
        return outcome
    }

    private func playEventSoundIfNeeded(_ event: NotificationEvent, sessions: [SessionState]) {
        guard AppSettings.soundEnabled else { return }
        Task {
            let shouldPlay = await Self.shouldPlayNotificationSound(for: sessions)
            if shouldPlay {
                await MainActor.run {
                    AppSettings.playSound(for: event)
                }
            }
        }
    }

    /// Returns true if any triggering session is not the currently focused terminal
    /// (so we don't chime for the window the user is already looking at).
    private static func shouldPlayNotificationSound(for sessions: [SessionState]) async -> Bool {
        for session in sessions {
            guard let pid = session.pid else {
                // No PID means we can't check focus; assume not focused.
                return true
            }
            let isFocused = await TerminalVisibilityDetector.isSessionFocused(sessionPid: pid)
            if !isFocused {
                return true
            }
        }
        return false
    }
}
