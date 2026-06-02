import Foundation
import XCTest
@testable import Ping_Island

/// Claude Code spawns a throwaway helper session to title each conversation. Those helpers
/// write a small but non-empty transcript, so the zero-byte phantom heuristic misses them
/// and they leak into the panel as ghost rows. These tests pin the content-based detection
/// that hides them. See memory: claude-title-gen-ghost-sessions.
final class ClaudeTitleGenerationGhostTests: XCTestCase {

    private static let realTitleGenPrompt =
        "In 4-6 words, plain text only with no quotes or punctuation, write a session title "
        + "that captures: '/Users/altian/Downloads/Receive_20260602140330_OCDY07NEW.txt'\n"
        + "check this and see if DumpDisplayClock matches"

    func testMatcherDetectsRealTitleGenerationPrompt() {
        XCTAssertTrue(ConversationParser.isClaudeTitleGenerationPrompt(Self.realTitleGenPrompt))
    }

    func testMatcherToleratesDifferentWordCount() {
        let variant =
            "In 5-10 words, plain text only with no quotes or punctuation, "
            + "write a session title that captures: 'something'"
        XCTAssertTrue(ConversationParser.isClaudeTitleGenerationPrompt(variant))
    }

    func testMatcherIgnoresOrdinaryPrompts() {
        XCTAssertFalse(ConversationParser.isClaudeTitleGenerationPrompt(nil))
        XCTAssertFalse(ConversationParser.isClaudeTitleGenerationPrompt(""))
        XCTAssertFalse(ConversationParser.isClaudeTitleGenerationPrompt(
            "Write a session title for my README"))
        XCTAssertFalse(ConversationParser.isClaudeTitleGenerationPrompt(
            "Fix the menu bar bug and check the clock"))
    }

    func testClaudeTitleGenSessionIsHiddenFromPrimaryUI() {
        let session = SessionState(
            sessionId: "claude-title-helper",
            cwd: "/tmp/project",
            provider: .claude,
            conversationInfo: titleGenInfo(isTitleGenerationPrompt: true)
        )
        XCTAssertTrue(session.isLikelyClaudeAuxiliaryTitleGenForUI)
        XCTAssertTrue(session.shouldHideFromPrimaryUI)
    }

    func testOrdinaryClaudeSessionIsNotFlaggedAsTitleGen() {
        let session = SessionState(
            sessionId: "claude-real",
            cwd: "/tmp/project",
            provider: .claude,
            conversationInfo: titleGenInfo(isTitleGenerationPrompt: false)
        )
        XCTAssertFalse(session.isLikelyClaudeAuxiliaryTitleGenForUI)
    }

    func testTitleGenFlagOnNonClaudeProviderDoesNotTriggerClaudePath() {
        let session = SessionState(
            sessionId: "codex-title-helper",
            cwd: "/tmp/project",
            provider: .codex,
            conversationInfo: titleGenInfo(isTitleGenerationPrompt: true)
        )
        XCTAssertFalse(session.isLikelyClaudeAuxiliaryTitleGenForUI)
    }

    private func titleGenInfo(isTitleGenerationPrompt: Bool) -> ConversationInfo {
        ConversationInfo(
            summary: nil,
            lastMessage: nil,
            lastMessageRole: nil,
            lastToolName: nil,
            firstUserMessage: "In 4-6 words, plain text only with no quotes or pu",
            lastUserMessageDate: nil,
            isTitleGenerationPrompt: isTitleGenerationPrompt
        )
    }
}
