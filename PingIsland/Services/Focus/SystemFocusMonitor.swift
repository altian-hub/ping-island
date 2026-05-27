//
//  SystemFocusMonitor.swift
//  PingIsland
//
//  Read-only bridge from macOS system Focus / Do Not Disturb into the app so
//  existing mute gates (sound playback, attention reminders) respect what the
//  user has set in Control Center. Toggling Focus is done by the user in macOS.
//

import Combine
import Foundation
import Intents

@MainActor
final class SystemFocusMonitor: ObservableObject {
    static let shared = SystemFocusMonitor()

    /// True whenever any system Focus mode (including the default Do Not Disturb) is on.
    @Published private(set) var isFocusActive: Bool = false

    private var focusObservation: NSKeyValueObservation?

    private init() {
        refreshFromSystem()

        // INFocusStatusCenter.focusStatus is KVO-compliant on macOS 12+.
        focusObservation = INFocusStatusCenter.default.observe(
            \.focusStatus,
            options: [.new]
        ) { [weak self] _, _ in
            Task { @MainActor in
                self?.refreshFromSystem()
            }
        }

        requestAuthorizationIfNeeded()
    }

    /// Trigger the one-time Focus-status permission prompt. Safe to call repeatedly;
    /// the system only surfaces the prompt while authorization is `.notDetermined`.
    func requestAuthorizationIfNeeded() {
        let status = INFocusStatusCenter.default.authorizationStatus
        guard status == .notDetermined else { return }
        INFocusStatusCenter.default.requestAuthorization { [weak self] _ in
            Task { @MainActor in
                self?.refreshFromSystem()
            }
        }
    }

    private func refreshFromSystem() {
        // `isFocused` is optional: nil when authorization hasn't been granted yet.
        // Treat unknown as "not active" so we don't accidentally silence the app
        // before the user has had a chance to grant permission.
        let next = INFocusStatusCenter.default.focusStatus.isFocused ?? false
        guard next != isFocusActive else { return }
        isFocusActive = next
    }
}
