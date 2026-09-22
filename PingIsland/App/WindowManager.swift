//
//  WindowManager.swift
//  PingIsland
//
//  Manages the notch and floating Buddy window lifecycles.
//

import AppKit
import Combine
import os.log

/// Logger for window management
private let logger = Logger(subsystem: "com.wudanwu.pingisland", category: "Window")

@MainActor
class WindowManager {
    private(set) var windowController: NotchWindowController?
    private var floatingPetController: FloatingPetWindowController?
    private var floatingPetSessionMonitor: SessionMonitor?
    private var floatingPetViewModel: NotchViewModel?
    private var miniPromptController: MiniPromptWindowController?
    private var miniPromptSessionMonitor: SessionMonitor?
    private var cancellables = Set<AnyCancellable>()

    init() {
        AppSettings.shared.$surfaceMode
            .dropFirst()
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.applySurfaceMode()
            }
            .store(in: &cancellables)
    }

    /// Set up or recreate the active surface based on the current surface mode.
    @discardableResult
    func setupNotchWindow() -> NotchWindowController? {
        applySurfaceMode()
        return windowController
    }

    private func applySurfaceMode() {
        switch AppSettings.surfaceMode {
        case .notch:
            dismissMiniPrompt()
            dismissFloatingPet { [weak self] in
                self?.ensureDockedNotch()
            }
        case .floatingPet:
            dismissMiniPrompt()
            dismissDockedNotch()
            ensureFloatingPet()
        case .mini:
            dismissDockedNotch()
            dismissFloatingPet { [weak self] in
                self?.ensureMiniPrompt()
            }
        }
    }

    // MARK: - Mini (Battery Saver)

    private func ensureMiniPrompt() {
        // Reached via dismissFloatingPet's 0.2s deferred completion, by which point
        // the user may have switched modes again — don't install mini over whatever
        // surface is now current.
        guard AppSettings.surfaceMode == .mini else { return }
        guard miniPromptController == nil else { return }

        // Transcript watchers started before the switch keep a DispatchSource (and
        // a parse on every append) alive; mini mode has no use for either.
        InterruptWatcherManager.shared.stopAll()

        let sessionMonitor = SessionMonitor()
        sessionMonitor.startMonitoring()
        miniPromptSessionMonitor = sessionMonitor

        miniPromptController = MiniPromptWindowController(
            sessionMonitor: sessionMonitor,
            onLeaveMiniMode: { [weak self] in
                AppSettings.surfaceMode = .notch
                self?.applySurfaceMode()
            }
        )
    }

    private func dismissMiniPrompt() {
        guard miniPromptController != nil else { return }
        miniPromptController?.dismiss()
        miniPromptController = nil
        miniPromptSessionMonitor?.stopMonitoring()
        miniPromptSessionMonitor = nil
    }

    // MARK: - Docked Notch

    private func ensureDockedNotch() {
        let screenSelector = ScreenSelector.shared
        screenSelector.refreshScreens()

        guard let screen = screenSelector.selectedScreen else {
            logger.warning("No screen found")
            return
        }

        if let existingController = windowController {
            existingController.window?.orderOut(nil)
            existingController.window?.close()
            windowController = nil
        }

        windowController = NotchWindowController(screen: screen)
        windowController?.showWindow(nil)
    }

    private func dismissDockedNotch() {
        windowController?.window?.orderOut(nil)
        windowController?.window?.close()
        windowController = nil
    }

    // MARK: - Floating Buddy

    private func ensureFloatingPet() {
        let screenSelector = ScreenSelector.shared
        screenSelector.refreshScreens()

        guard let screen = screenSelector.selectedScreen else {
            logger.warning("No screen found")
            return
        }

        if floatingPetController == nil {
            let sessionMonitor = SessionMonitor()
            sessionMonitor.startMonitoring()
            floatingPetSessionMonitor = sessionMonitor

            let screenFrame = screen.frame
            let notchSize = screen.notchSize
            let deviceNotchRect = CGRect(
                x: (screenFrame.width - notchSize.width) / 2,
                y: 0,
                width: notchSize.width,
                height: notchSize.height
            )
            let viewModel = NotchViewModel(
                deviceNotchRect: deviceNotchRect,
                screenRect: screenFrame,
                windowHeight: 750,
                hasPhysicalNotch: screen.hasPhysicalNotch,
                enableEventMonitoring: false,
                observeSystemEnvironment: false
            )
            floatingPetViewModel = viewModel

            floatingPetController = FloatingPetWindowController(
                viewModel: viewModel,
                sessionMonitor: sessionMonitor,
                onRedock: { [weak self] in
                    AppSettings.surfaceMode = .notch
                    self?.applySurfaceMode()
                }
            )
        }

        floatingPetController?.present(on: screen)
    }

    private func dismissFloatingPet(completion: (() -> Void)? = nil) {
        guard floatingPetController != nil else {
            completion?()
            return
        }
        floatingPetController?.dismiss()
        // Defer teardown so any in-flight popover animations can finish
        // before the hosting view is deallocated.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            self?.floatingPetController = nil
            self?.floatingPetSessionMonitor?.stopMonitoring()
            self?.floatingPetSessionMonitor = nil
            self?.floatingPetViewModel = nil
            completion?()
        }
    }
}
