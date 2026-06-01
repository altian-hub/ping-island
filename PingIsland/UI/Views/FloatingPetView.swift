//
//  FloatingPetView.swift
//  PingIsland
//
//  SwiftUI surface for the floating Buddy. Renders the mascot, accepts drag
//  gestures via AppKit window dragging, and surfaces the session content via
//  a popover when clicked.
//

import AppKit
import Combine
import SwiftUI

struct FloatingPetView: View {
    @ObservedObject var viewModel: NotchViewModel
    @StateObject private var sessionMonitorState: SessionMonitorObserver
    @ObservedObject private var settings = AppSettings.shared
    let onPositionChanged: (NSPoint) -> Void
    let onRedock: () -> Void

    @State private var isHovering = false
    @State private var isExpanded = false
    @State private var isPopoverHovered = false
    @State private var autoHideTask: Task<Void, Never>?
    @State private var isInDockZone = false
    @State private var dragWindow: NSWindow?
    @State private var dragStartOrigin: NSPoint = .zero
    @State private var dragStartMouse: NSPoint = .zero
    @State private var isDragging = false
    @State private var lastBubbleToggleAt: Date = .distantPast
    @State private var soundController = SessionSoundController()

    /// Minimum time between bubble taps. Without this a double-click on the
    /// companion would open then immediately close the panel before the user
    /// can see what they opened.
    private static let bubbleToggleDebounce: TimeInterval = 1.0

    private let popoverAutoHideDelay: TimeInterval = 5.0

    init(
        viewModel: NotchViewModel,
        sessionMonitor: SessionMonitor,
        onPositionChanged: @escaping (NSPoint) -> Void,
        onRedock: @escaping () -> Void
    ) {
        self.viewModel = viewModel
        _sessionMonitorState = StateObject(
            wrappedValue: SessionMonitorObserver(monitor: sessionMonitor)
        )
        self.onPositionChanged = onPositionChanged
        self.onRedock = onRedock
    }

    var body: some View {
        ZStack {
            mascotBubble
                .contentShape(Circle())
                .onHover { isHovering = $0 }
                .background(WindowReader { dragWindow = $0 })
                .gesture(dragGesture)
                .onTapGesture {
                    let now = Date()
                    guard now.timeIntervalSince(lastBubbleToggleAt) >= Self.bubbleToggleDebounce else { return }
                    lastBubbleToggleAt = now
                    isExpanded.toggle()
                }
                .popover(isPresented: $isExpanded, arrowEdge: .leading) {
                    FloatingPetContent(
                        viewModel: viewModel,
                        sessionMonitor: sessionMonitorState.monitor,
                        onRedock: {
                            isExpanded = false
                            // Defer the actual redock until the popover finishes
                            // animating closed; otherwise AppKit tries to update
                            // constraints on a view that's being torn down.
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                                onRedock()
                            }
                        }
                    )
                    .frame(width: 460)
                    .fixedSize(horizontal: false, vertical: true)
                    .onHover { hovering in
                        isPopoverHovered = hovering
                        scheduleAutoHide()
                    }
                }
        }
        .padding(4)
        .onChange(of: sessionMonitorState.monitor.instances) { _, instances in
            // Play notification sounds in buddy mode too (NotchView is not mounted
            // here, so without this the buddy would be silent on attention/completion).
            soundController.handle(instances)
            if SwarmDiagnostics.isEnabled {
                SwarmDiagnostics.log("BUDDY-SNAP", "attn=\(attentionCount) expanded=\(isExpanded) | \(SwarmDiagnostics.summarize(instances))")
            }
        }
        .onChange(of: attentionCount) { oldValue, newValue in
            if SwarmDiagnostics.isEnabled {
                SwarmDiagnostics.log("BUDDY-ATTN", "count \(oldValue)->\(newValue) expanded=\(isExpanded) willAutoExpand=\(newValue > 0 && !isExpanded)")
            }
            // Auto-expand when a session newly needs attention (permission
            // request, AskUserQuestion, etc.) so the user doesn't have to
            // click the bubble to see what changed.
            if newValue > 0, !isExpanded {
                isExpanded = true
            } else if newValue == 0 {
                // Attention cleared: start the auto-hide timer that was suppressed
                // while a prompt was pending.
                scheduleAutoHide()
            }
        }
        .onChange(of: isExpanded) { _, opened in
            if opened {
                scheduleAutoHide()
            } else {
                cancelAutoHide()
                isPopoverHovered = false
            }
        }
        .onDisappear { cancelAutoHide() }
    }

    private func scheduleAutoHide() {
        autoHideTask?.cancel()
        guard isExpanded else { return }
        // Don't auto-close while the cursor is inside the panel, while a child view
        // holds an interaction lock (e.g. AskUserQuestion form, focused chat input),
        // or while a session still needs manual attention (a pending permission /
        // question must stay visible until it's resolved).
        if isPopoverHovered || viewModel.hasInteractionLock || hasPendingManualAttention { return }
        let delay = popoverAutoHideDelay
        autoHideTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            if !isExpanded { return }
            // Re-check at fire time; if still engaged, try again later instead
            // of closing in the middle of an interaction or pending prompt.
            if isPopoverHovered || viewModel.hasInteractionLock || hasPendingManualAttention {
                scheduleAutoHide()
                return
            }
            isExpanded = false
        }
    }

    /// Whether any tracked session is currently waiting on the user (permission
    /// request, AskUserQuestion, etc.). Mirrors `attentionCount > 0`.
    private var hasPendingManualAttention: Bool {
        sessionMonitorState.monitor.instances.contains { $0.needsManualAttention }
    }

    private func cancelAutoHide() {
        autoHideTask?.cancel()
        autoHideTask = nil
    }

    /// Snap-zone radius around the top-center of the active screen. Releasing the
    /// drag inside it converts the floating Buddy back into the docked notch pill.
    private static let redockHorizontalSlop: CGFloat = 96
    private static let redockVerticalSlop: CGFloat = 56

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 4, coordinateSpace: .global)
            .onChanged { _ in
                guard let window = dragWindow else { return }
                if !isDragging {
                    isDragging = true
                    dragStartOrigin = window.frame.origin
                    dragStartMouse = NSEvent.mouseLocation
                }
                let current = NSEvent.mouseLocation
                let dx = current.x - dragStartMouse.x
                let dy = current.y - dragStartMouse.y
                let newOrigin = NSPoint(x: dragStartOrigin.x + dx, y: dragStartOrigin.y + dy)
                window.setFrameOrigin(newOrigin)
                onPositionChanged(newOrigin)
                let next = isFrameInDockZone(window.frame)
                if next != isInDockZone {
                    isInDockZone = next
                }
            }
            .onEnded { _ in
                defer {
                    isDragging = false
                    isInDockZone = false
                }
                guard let window = dragWindow, isDragging else { return }
                handleDragEnded(window.frame)
            }
    }

    private func handleDragEnded(_ frame: NSRect) {
        guard isFrameInDockZone(frame) else { return }

        isExpanded = false
        cancelAutoHide()
        // Defer to next runloop so the drag's mouseUp finishes settling the
        // window before the controller tears it down.
        DispatchQueue.main.async {
            onRedock()
        }
    }

    private func isFrameInDockZone(_ frame: NSRect) -> Bool {
        let screen = NSScreen.screens.first(where: { $0.frame.intersects(frame) })
            ?? NSScreen.main
        guard let screen else { return false }
        let horizontalDistance = abs(frame.midX - screen.frame.midX)
        let verticalDistance = screen.frame.maxY - frame.maxY
        return horizontalDistance <= Self.redockHorizontalSlop
            && verticalDistance <= Self.redockVerticalSlop
    }

    private var attentionCount: Int {
        sessionMonitorState.monitor.instances.filter { $0.needsManualAttention }.count
    }

    private var mascotBubble: some View {
        let client = closedMascotClient
        let kind = settings.mascotKind(for: client)
        let status: MascotStatus = closedMascotStatus

        return ZStack {
            if isInDockZone {
                Circle()
                    .fill(Color.white.opacity(0.18))
                    .overlay(
                        Circle()
                            .strokeBorder(Color.white.opacity(0.7), lineWidth: 1.5)
                    )
                    .frame(width: 60, height: 60)
                    .transition(.opacity)
            }

            MascotView(kind: kind, status: status, size: 44)
                .shadow(color: .black.opacity(0.45), radius: 6, y: 2)

            if sessionMonitorState.monitor.instances.count(where: { $0.needsManualAttention }) > 0 {
                Circle()
                    .fill(TerminalColors.amber)
                    .frame(width: 12, height: 12)
                    .overlay(Circle().stroke(Color.black, lineWidth: 1.5))
                    .offset(x: 22, y: -22)
            }
        }
        .frame(width: 64, height: 64)
        .scaleEffect(isInDockZone ? 1.12 : (isHovering ? 1.04 : 1.0))
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isHovering)
        .animation(.spring(response: 0.25, dampingFraction: 0.75), value: isInDockZone)
    }

    private var closedMascotClient: MascotClient {
        if let session = latestActiveSession() {
            return session.mascotClient
        }
        return .claude
    }

    private var closedMascotStatus: MascotStatus {
        let instances = sessionMonitorState.monitor.instances
        let hasAttention = instances.contains { $0.needsManualAttention }
        let isProcessing = instances.contains { $0.phase == .processing || $0.phase == .compacting }
        return MascotStatus.closedNotchStatus(
            representativePhase: isProcessing ? .processing : .idle,
            hasPendingPermission: hasAttention,
            hasHumanIntervention: hasAttention
        )
    }

    private func latestActiveSession() -> SessionState? {
        sessionMonitorState.monitor.instances
            .filter { $0.presentsActiveInUI }
            .sorted { $0.lastActivity > $1.lastActivity }
            .first
    }
}

/// Lets us @ObservedObject the session monitor without forcing the parent struct
/// to be re-init'd every time the monitor changes.
@MainActor
final class SessionMonitorObserver: ObservableObject {
    let monitor: SessionMonitor
    private var cancellables = Set<AnyCancellable>()

    init(monitor: SessionMonitor) {
        self.monitor = monitor
        monitor.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
            .store(in: &cancellables)
    }
}

/// Bubbles the hosting NSWindow up into SwiftUI state so a DragGesture can
/// drive `window.setFrameOrigin` directly.
private struct WindowReader: NSViewRepresentable {
    let onResolved: (NSWindow?) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.async { [weak view] in
            onResolved(view?.window)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { [weak nsView] in
            onResolved(nsView?.window)
        }
    }
}

/// Content displayed when the user clicks the Buddy.
struct FloatingPetContent: View {
    @ObservedObject var viewModel: NotchViewModel
    @ObservedObject var sessionMonitor: SessionMonitor
    @ObservedObject private var settings = AppSettings.shared
    let onRedock: () -> Void

    private var areReminderNotificationsSuppressed: Bool {
        settings.areNotificationsMutedTemporarily
    }

    private func toggleTemporaryMute() {
        if areReminderNotificationsSuppressed {
            AppSettings.clearReminderNotificationMute()
        } else {
            AppSettings.muteReminderNotificationsIndefinitely()
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Only show our own header when we're on the session list. ChatView /
            // CodexSessionView render their own back-arrow header, so we hide ours
            // there to avoid stacking two of them.
            if !isInChat {
                HStack(spacing: 8) {
                    Text("Buddy")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.white.opacity(0.92))
                        .lineLimit(1)

                    Spacer()

                    Button(action: toggleTemporaryMute) {
                        Image(systemName: areReminderNotificationsSuppressed ? "speaker.slash.fill" : "speaker.wave.2.fill")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(.white.opacity(areReminderNotificationsSuppressed ? 0.6 : 0.78))
                            .frame(width: 26, height: 26)
                            .background(
                                RoundedRectangle(cornerRadius: 7, style: .continuous)
                                    .fill(Color.white.opacity(areReminderNotificationsSuppressed ? 0.06 : 0.1))
                            )
                    }
                    .buttonStyle(.plain)
                    .help(areReminderNotificationsSuppressed
                          ? "Notifications and sounds are muted. Click to restore."
                          : "Mute notifications and sounds")
                    .accessibilityLabel(areReminderNotificationsSuppressed ? "Unmute notifications" : "Mute notifications")

                    Button(action: { sessionMonitor.cleanDeadSessions() }) {
                        Image(systemName: "trash.fill")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(.white.opacity(0.78))
                            .frame(width: 26, height: 26)
                            .background(
                                RoundedRectangle(cornerRadius: 7, style: .continuous)
                                    .fill(Color.white.opacity(0.1))
                            )
                    }
                    .buttonStyle(.plain)
                    .help("Clean dead sessions (no rollout on disk)")
                    .accessibilityLabel("Clean dead sessions")

                    Button(action: onRedock) {
                        Image(systemName: "rectangle.dock")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(.white.opacity(0.78))
                            .frame(width: 26, height: 26)
                            .background(
                                RoundedRectangle(cornerRadius: 7, style: .continuous)
                                    .fill(Color.white.opacity(0.1))
                            )
                    }
                    .buttonStyle(.plain)
                    .help("Redock to top island")
                }
                .padding(.horizontal, 12)
                .padding(.top, 8)
                .padding(.bottom, 6)
            }

            content
                .frame(maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity, alignment: .top)
        .background(Color.black)
        .preferredColorScheme(.dark)
    }

    private var isInChat: Bool {
        if case .chat = viewModel.contentType { return true }
        return false
    }

    @ViewBuilder
    private var content: some View {
        switch viewModel.contentType {
        case .instances:
            SessionListView(
                sessionMonitor: sessionMonitor,
                viewModel: viewModel
            )
        case .chat(let session):
            let liveSession = sessionMonitor.instances.first(where: { $0.sessionId == session.sessionId }) ?? session
            if liveSession.provider == .claude {
                ChatView(
                    sessionId: liveSession.sessionId,
                    initialSession: liveSession,
                    sessionMonitor: sessionMonitor,
                    viewModel: viewModel
                )
                .frame(minHeight: 320)
            } else {
                CodexSessionView(
                    session: liveSession,
                    sessionMonitor: sessionMonitor,
                    viewModel: viewModel
                )
                .frame(minHeight: 320)
            }
        }
    }
}
