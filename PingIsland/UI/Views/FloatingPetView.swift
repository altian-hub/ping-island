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
                .onTapGesture { isExpanded.toggle() }
                .background(WindowDragHandle(onMoved: onPositionChanged))
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
                }
        }
        .padding(4)
        .onChange(of: attentionCount) { _, newValue in
            // Auto-expand when a session newly needs attention (permission
            // request, AskUserQuestion, etc.) so the user doesn't have to
            // click the bubble to see what changed.
            if newValue > 0, !isExpanded {
                isExpanded = true
            }
        }
    }

    private var attentionCount: Int {
        sessionMonitorState.monitor.instances.filter { $0.needsManualAttention }.count
    }

    private var mascotBubble: some View {
        let client = closedMascotClient
        let kind = settings.mascotKind(for: client)
        let status: MascotStatus = closedMascotStatus

        return ZStack {
            Circle()
                .fill(Color.black.opacity(isHovering ? 0.82 : 0.72))
                .overlay(
                    Circle()
                        .strokeBorder(Color.white.opacity(isHovering ? 0.32 : 0.18), lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.55), radius: 8, y: 3)

            MascotView(kind: kind, status: status, size: 44)

            if sessionMonitorState.monitor.instances.count(where: { $0.needsManualAttention }) > 0 {
                Circle()
                    .fill(TerminalColors.amber)
                    .frame(width: 12, height: 12)
                    .overlay(Circle().stroke(Color.black, lineWidth: 1.5))
                    .offset(x: 22, y: -22)
            }
        }
        .frame(width: 64, height: 64)
        .scaleEffect(isHovering ? 1.04 : 1.0)
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isHovering)
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

/// Bridges to AppKit window dragging without intercepting SwiftUI tap gestures.
private struct WindowDragHandle: NSViewRepresentable {
    let onMoved: (NSPoint) -> Void

    func makeNSView(context: Context) -> DragRelayView {
        let view = DragRelayView()
        view.onMoved = onMoved
        return view
    }

    func updateNSView(_ nsView: DragRelayView, context: Context) {
        nsView.onMoved = onMoved
    }
}

final class DragRelayView: NSView {
    var onMoved: ((NSPoint) -> Void)?
    private var initialOrigin: NSPoint?
    private var initialMouse: NSPoint?

    override var acceptsFirstResponder: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        // Don't intercept clicks meant for SwiftUI buttons - only handle drags.
        // The mascot bubble's onTapGesture will fire on quick clicks because
        // mouseDown -> mouseUp without enough movement won't fire onMoved.
        nil
    }

    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        initialOrigin = window.frame.origin
        initialMouse = NSEvent.mouseLocation
    }

    override func mouseDragged(with event: NSEvent) {
        guard let window,
              let initialOrigin,
              let initialMouse else { return }
        let current = NSEvent.mouseLocation
        let dx = current.x - initialMouse.x
        let dy = current.y - initialMouse.y
        let newOrigin = NSPoint(x: initialOrigin.x + dx, y: initialOrigin.y + dy)
        window.setFrameOrigin(newOrigin)
        onMoved?(newOrigin)
    }
}

/// Content displayed when the user clicks the Buddy.
struct FloatingPetContent: View {
    @ObservedObject var viewModel: NotchViewModel
    @ObservedObject var sessionMonitor: SessionMonitor
    let onRedock: () -> Void

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
