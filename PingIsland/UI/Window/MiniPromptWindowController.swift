//
//  MiniPromptWindowController.swift
//  PingIsland
//
//  Mini (battery saver) surface. Two pieces:
//
//  1. A borderless panel that is ordered OUT whenever nothing needs a decision.
//     While hidden its SwiftUI hosting view is torn down, so there is no view
//     tree, no timer and nothing for the WindowServer to composite — the app
//     idles at effectively zero CPU waiting on the hook socket.
//  2. A menu-bar status item, because mini mode hides the notch and the app runs
//     as an `.accessory` with no Dock icon — without it there would be no way
//     back to Settings or to the full island.
//

import AppKit
import Combine
import SwiftUI
import os.log

private let miniLogger = Logger(subsystem: "com.wudanwu.pingisland", category: "Mini")

/// Non-activating panel so answering a prompt never steals focus from the editor.
final class MiniPromptPanel: NSPanel {
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
        hasShadow = true
        level = .statusBar
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        isReleasedWhenClosed = false
    }
}

@MainActor
final class MiniPromptWindowController: NSWindowController {
    private let sessionMonitor: SessionMonitor
    private let onLeaveMiniMode: () -> Void
    private var cancellables = Set<AnyCancellable>()
    private var statusItem: NSStatusItem?
    private var soundController = SessionSoundController(allowedEvents: [.attentionRequired])

    /// Keeps the panel pinned to the prompt the user is currently answering, so a
    /// newer prompt from another session can't swap the card mid-interaction.
    private var pinnedStableId: String?
    private var isShowingPrompt = false

    /// Identity of the content currently rendered in the panel. Re-assigning
    /// `rootView` and re-setting the window frame on every state publish cancels
    /// the in-flight SwiftUI press gesture, which silently eats clicks; only
    /// touch the panel when what it should display actually changed.
    private var shownSignature: String?

    /// Prompts the user has just answered. The decisions are already committed, so
    /// hide them immediately rather than waiting for the store round-trip to come
    /// back through Combine — otherwise the card sits there looking unclicked.
    private var optimisticallyDismissedIds: Set<String> = []

    /// Prompt count currently reflected in the menu bar, so repeated publishes
    /// don't reallocate the image and menu on every hook event.
    private var shownPromptCount: Int?

    init(sessionMonitor: SessionMonitor, onLeaveMiniMode: @escaping () -> Void) {
        self.sessionMonitor = sessionMonitor
        self.onLeaveMiniMode = onLeaveMiniMode

        let panel = MiniPromptPanel(
            contentRect: NSRect(x: 0, y: 0, width: MiniPromptMetrics.width, height: 120)
        )
        super.init(window: panel)

        installStatusItem()

        sessionMonitor.$instances
            .receive(on: DispatchQueue.main)
            .sink { [weak self] instances in
                self?.apply(instances)
            }
            .store(in: &cancellables)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Tear the surface down for good. Everything here is synchronous on purpose:
    /// the caller (`WindowManager.dismissMiniPrompt`) drops its reference the moment
    /// this returns, so anything deferred with `[weak self]` would simply never run —
    /// leaving an orphaned NSHostingView in a live panel, which then loops on
    /// constraint invalidation until AppKit throws.
    func dismiss() {
        cancellables.removeAll()

        if let statusItem {
            NSStatusBar.system.removeStatusItem(statusItem)
        }
        statusItem = nil

        isShowingPrompt = false
        shownSignature = nil
        window?.orderOut(nil)
        window?.contentViewController = nil
        window?.close()
    }

    // MARK: - Prompt Presentation

    private func apply(_ instances: [SessionState]) {
        soundController.handle(instances)

        let (prompts, stillDismissed) = MiniPromptPresenter.visiblePrompts(
            from: instances,
            dismissing: optimisticallyDismissedIds
        )
        optimisticallyDismissedIds = stillDismissed

        miniLogger.debug(
            "apply instances=\(instances.count, privacy: .public) prompts=\(prompts.count, privacy: .public)"
        )

        guard let active = prompts.first(where: { $0.stableId == pinnedStableId }) ?? prompts.first else {
            pinnedStableId = nil
            updateStatusItem(promptCount: 0)
            hidePanel()
            return
        }

        pinnedStableId = active.stableId
        updateStatusItem(promptCount: prompts.count)
        showPanel(for: active, queuedCount: max(0, prompts.count - 1))
    }

    private func showPanel(for session: SessionState, queuedCount: Int) {
        guard let panel = window as? MiniPromptPanel else { return }

        let signature = MiniPromptPresenter.contentSignature(session: session, queuedCount: queuedCount)
        guard signature != shownSignature || !isShowingPrompt else {
            // Same card, already on screen: leave the view tree and frame alone so
            // an in-progress click survives unrelated session-state publishes.
            return
        }
        shownSignature = signature

        let root = MiniPromptView(
            session: session,
            queuedCount: queuedCount,
            sessionMonitor: sessionMonitor,
            onDecision: { [weak self] in
                self?.handleDecision(for: MiniPromptPresenter.promptIdentity(session))
            }
        )

        if let hosting = panel.contentViewController as? NSHostingController<MiniPromptView> {
            hosting.rootView = root
        } else {
            let hosting = NSHostingController(rootView: root)
            hosting.view.layer?.backgroundColor = NSColor.clear.cgColor
            panel.contentViewController = hosting
        }

        panel.layoutIfNeeded()
        let fittingHeight = panel.contentViewController?.view.fittingSize.height ?? 120
        positionPanel(panel, height: max(80, fittingHeight))

        if !isShowingPrompt {
            panel.orderFrontRegardless()
            isShowingPrompt = true
        }

        miniLogger.debug(
            "showPanel session=\(session.sessionId.prefix(8), privacy: .public) frame=\(NSStringFromRect(panel.frame), privacy: .public)"
        )
    }

    private func handleDecision(for promptIdentity: String) {
        optimisticallyDismissedIds.insert(promptIdentity)
        pinnedStableId = nil
        shownSignature = nil
        hidePanel()
    }

    private func hidePanel() {
        guard isShowingPrompt || window?.isVisible == true else { return }
        window?.orderOut(nil)
        isShowingPrompt = false
        shownSignature = nil
        // Drop the SwiftUI tree so nothing is retained or re-evaluated while idle,
        // but only once the button action that triggered this has left the stack —
        // the buddy surface defers teardown for the same reason.
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.isShowingPrompt else { return }
            self.window?.contentViewController = nil
        }
    }

    private func positionPanel(_ panel: NSPanel, height: CGFloat) {
        ScreenSelector.shared.refreshScreens()
        let screen = ScreenSelector.shared.selectedScreen ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return }
        let origin = CGPoint(
            x: visible.midX - MiniPromptMetrics.width / 2,
            y: visible.maxY - height - MiniPromptMetrics.topInset
        )
        panel.setFrame(
            NSRect(origin: origin, size: CGSize(width: MiniPromptMetrics.width, height: height)),
            display: true
        )
    }

    // MARK: - Status Item

    private func installStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(
            systemSymbolName: "moon.zzz",
            accessibilityDescription: "Ping Island — mini mode"
        )
        item.button?.image?.isTemplate = true
        item.menu = buildMenu(promptCount: 0)
        statusItem = item
    }

    private func updateStatusItem(promptCount: Int) {
        guard let statusItem else { return }
        // Runs on every session-state publish; only touch the menu bar when the
        // thing it displays actually changed.
        guard promptCount != shownPromptCount else { return }
        shownPromptCount = promptCount
        let symbol = promptCount > 0 ? "exclamationmark.bubble.fill" : "moon.zzz"
        statusItem.button?.image = NSImage(
            systemSymbolName: symbol,
            accessibilityDescription: "Ping Island — mini mode"
        )
        statusItem.button?.image?.isTemplate = true
        statusItem.button?.title = promptCount > 1 ? " \(promptCount)" : ""
        statusItem.menu = buildMenu(promptCount: promptCount)
    }

    private func buildMenu(promptCount: Int) -> NSMenu {
        let menu = NSMenu()

        let status = NSMenuItem(
            title: promptCount == 0
                ? AppLocalization.string("没有待处理的请求")
                : AppLocalization.format("%lld 个请求等待处理", promptCount),
            action: nil,
            keyEquivalent: ""
        )
        status.isEnabled = false
        menu.addItem(status)
        menu.addItem(.separator())

        let leave = NSMenuItem(
            title: AppLocalization.string("退出迷你模式"),
            action: #selector(leaveMiniMode),
            keyEquivalent: ""
        )
        leave.target = self
        menu.addItem(leave)

        let settings = NSMenuItem(
            title: AppLocalization.string("设置"),
            action: #selector(openSettings),
            keyEquivalent: ","
        )
        settings.target = self
        menu.addItem(settings)

        menu.addItem(.separator())

        let quit = NSMenuItem(
            title: AppLocalization.string("退出"),
            action: #selector(quitApp),
            keyEquivalent: "q"
        )
        quit.target = self
        menu.addItem(quit)

        return menu
    }

    @objc private func leaveMiniMode() {
        onLeaveMiniMode()
    }

    @objc private func openSettings() {
        NSApp.activate(ignoringOtherApps: true)
        SettingsWindowController.shared.present()
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }
}
