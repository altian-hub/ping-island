import Foundation
import XCTest
@testable import Ping_Island

final class AutoApprovalLogTests: XCTestCase {
    func testBashLogsTheCommand() {
        let summary = AutoApprovalLog.summarizeInput(
            tool: "Bash",
            input: ["command": AnyCodable("git push origin main"), "description": AnyCodable("Push")]
        )
        XCTAssertEqual(summary, "git push origin main")
    }

    func testFileToolsLogThePath() {
        let summary = AutoApprovalLog.summarizeInput(
            tool: "Write",
            input: ["file_path": AnyCodable("/repo/a.swift"), "content": AnyCodable("let x = 1")]
        )
        XCTAssertEqual(summary, "/repo/a.swift")
    }

    func testOtherToolsLogCompactJSON() {
        let summary = AutoApprovalLog.summarizeInput(
            tool: "WebFetch",
            input: ["url": AnyCodable("https://example.com")]
        )
        XCTAssertTrue(summary.contains("https:"))
        XCTAssertTrue(summary.contains("example.com"))
    }

    func testLongInputIsTruncated() {
        let long = String(repeating: "x", count: AutoApprovalLog.maxInputLength + 50)
        let summary = AutoApprovalLog.summarizeInput(tool: "Bash", input: ["command": AnyCodable(long)])
        XCTAssertEqual(summary.count, AutoApprovalLog.maxInputLength + 1)
        XCTAssertTrue(summary.hasSuffix("…"))
    }

    func testMissingInputLogsEmpty() {
        XCTAssertEqual(AutoApprovalLog.summarizeInput(tool: "Bash", input: nil), "")
    }
}
