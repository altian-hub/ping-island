import CoreGraphics
import XCTest
@testable import Ping_Island

final class NotchViewModelTests: XCTestCase {
    func testPresentNotificationChatOpensClosedNotchAndShowsTargetSession() async {
        await MainActor.run {
            let viewModel = makeViewModel()
            let session = makeSession(id: "approval-session")

            viewModel.presentNotificationChat(for: session)

            XCTAssertEqual(viewModel.status, .opened)
            XCTAssertEqual(viewModel.openReason, .notification)
            XCTAssertEqual(viewModel.contentType, .chat(session))
        }
    }

    func testPresentNotificationChatKeepsOpenedNotchExpandedWhileSwitchingSessions() async {
        await MainActor.run {
            let viewModel = makeViewModel()
            let originalSession = makeSession(id: "original-session")
            let refreshedSession = makeSession(id: "refreshed-session")

            viewModel.notchOpen(reason: .notification)
            viewModel.showChat(for: originalSession)

            viewModel.presentNotificationChat(for: refreshedSession)

            XCTAssertEqual(viewModel.status, .opened)
            XCTAssertEqual(viewModel.openReason, .notification)
            XCTAssertEqual(viewModel.contentType, .chat(refreshedSession))
        }
    }

    func testDeferredHoverOpenDoesNotOverrideActiveNotificationPresentation() async {
        await MainActor.run {
            let viewModel = makeViewModel()

            viewModel.isHovering = true
            viewModel.notchOpen(reason: .notification)
            viewModel.performDeferredHoverOpenIfNeeded()

            XCTAssertEqual(viewModel.status, .opened)
            XCTAssertEqual(viewModel.openReason, .notification)
            XCTAssertEqual(viewModel.contentType, .instances)
        }
    }

    func testClosedHeightUsesDetectedSystemNotchHeight() async {
        await MainActor.run {
            let viewModel = NotchViewModel(
                deviceNotchRect: CGRect(x: 0, y: 0, width: 220, height: 38),
                screenRect: CGRect(x: 0, y: 0, width: 1512, height: 982),
                windowHeight: 320,
                hasPhysicalNotch: true,
                enableEventMonitoring: false,
                observeSystemEnvironment: false,
                fullscreenActivityProvider: { _ in false }
            )

            XCTAssertEqual(viewModel.closedHeight, 38)
            XCTAssertEqual(viewModel.closedSize, CGSize(width: 266, height: 38))
        }
    }

    func testClosedWidthExpandsToCoverWiderDetectedSystemNotch() async {
        await MainActor.run {
            let viewModel = NotchViewModel(
                deviceNotchRect: CGRect(x: 0, y: 0, width: 312, height: 38),
                screenRect: CGRect(x: 0, y: 0, width: 1728, height: 1117),
                windowHeight: 320,
                hasPhysicalNotch: true,
                enableEventMonitoring: false,
                observeSystemEnvironment: false,
                fullscreenActivityProvider: { _ in false }
            )

            XCTAssertEqual(viewModel.closedWidth, 312)
            XCTAssertEqual(viewModel.closedSize, CGSize(width: 312, height: 38))
        }
    }


    @MainActor
    private func makeViewModel() -> NotchViewModel {
        NotchViewModel(
            deviceNotchRect: .zero,
            screenRect: CGRect(x: 0, y: 0, width: 1440, height: 900),
            windowHeight: 320,
            hasPhysicalNotch: false,
            enableEventMonitoring: false,
            observeSystemEnvironment: false,
            fullscreenActivityProvider: { _ in false }
        )
    }

    private func makeSession(id: String) -> SessionState {
        SessionState(
            sessionId: id,
            cwd: "/tmp/\(id)"
        )
    }
}
