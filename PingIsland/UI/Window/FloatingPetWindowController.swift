//
//  FloatingPetWindowController.swift
//  PingIsland
//
//  A draggable Buddy that lives outside the docked notch. Reuses the existing
//  NotchViewModel / SessionMonitor so session state stays consistent.
//

import AppKit
import Combine
import SwiftUI

/// Non-activating, borderless panel for the floating Buddy.
final class FloatingPetPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .statusBar
        isMovableByWindowBackground = false
        ignoresMouseEvents = false
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        isReleasedWhenClosed = false
    }
}

@MainActor
final class FloatingPetWindowController: NSWindowController {
    private let viewModel: NotchViewModel
    private let sessionMonitor: SessionMonitor
    private let onRedock: () -> Void

    private static let petSize = CGSize(width: 80, height: 80)
    private static let expandedSize = CGSize(width: 360, height: 420)

    init(
        viewModel: NotchViewModel,
        sessionMonitor: SessionMonitor,
        onRedock: @escaping () -> Void
    ) {
        self.viewModel = viewModel
        self.sessionMonitor = sessionMonitor
        self.onRedock = onRedock

        let panel = FloatingPetPanel(
            contentRect: NSRect(origin: .zero, size: Self.petSize)
        )
        super.init(window: panel)

        let hostingController = NSHostingController(
            rootView: FloatingPetView(
                viewModel: viewModel,
                sessionMonitor: sessionMonitor,
                onPositionChanged: { [weak self] anchor in
                    self?.persist(anchor: anchor)
                },
                onRedock: { [weak self] in
                    self?.onRedock()
                }
            )
        )
        hostingController.view.layer?.backgroundColor = NSColor.clear.cgColor
        panel.contentViewController = hostingController
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Present the panel at the saved anchor position (or default to bottom-right).
    func present(on screen: NSScreen) {
        guard let panel = window as? FloatingPetPanel else { return }
        let visible = screen.visibleFrame
        let origin = resolvedOrigin(in: visible, size: Self.petSize)
        panel.setFrame(NSRect(origin: origin, size: Self.petSize), display: true)
        panel.orderFrontRegardless()
    }

    func dismiss() {
        window?.orderOut(nil)
    }

    private func resolvedOrigin(in visible: NSRect, size: CGSize) -> CGPoint {
        if let anchor = AppSettings.floatingPetAnchor {
            // anchor.xRatio / yRatio is the center position as a fraction of visibleFrame.
            let centerX = visible.minX + CGFloat(anchor.xRatio) * visible.width
            let centerY = visible.minY + CGFloat(anchor.yRatio) * visible.height
            let originX = clamp(centerX - size.width / 2,
                                low: visible.minX,
                                high: visible.maxX - size.width)
            let originY = clamp(centerY - size.height / 2,
                                low: visible.minY,
                                high: visible.maxY - size.height)
            return CGPoint(x: originX, y: originY)
        }
        // Default: bottom-right corner with padding.
        return CGPoint(
            x: visible.maxX - size.width - 32,
            y: visible.minY + 48
        )
    }

    private func clamp(_ value: CGFloat, low: CGFloat, high: CGFloat) -> CGFloat {
        max(low, min(high, value))
    }

    private func persist(anchor: NSPoint) {
        guard let screen = window?.screen ?? NSScreen.main else { return }
        let visible = screen.visibleFrame
        guard visible.width > 0, visible.height > 0 else { return }
        let center = CGPoint(
            x: anchor.x + Self.petSize.width / 2,
            y: anchor.y + Self.petSize.height / 2
        )
        let xRatio = Double((center.x - visible.minX) / visible.width)
        let yRatio = Double((center.y - visible.minY) / visible.height)
        AppSettings.floatingPetAnchor = FloatingPetAnchor(
            xRatio: max(0, min(1, xRatio)),
            yRatio: max(0, min(1, yRatio))
        )
    }
}
