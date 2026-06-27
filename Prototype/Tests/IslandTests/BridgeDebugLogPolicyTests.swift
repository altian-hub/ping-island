import Foundation
import IslandShared
import Testing

@Test
func debugLogPrunerRemovesFilesOutsideRetentionWindow() async throws {
    try await withTemporaryDirectory { directory in
        let logsDirectory = directory.appending(path: ".ping-island-debug", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: logsDirectory, withIntermediateDirectories: true)
        let oldLog = logsDirectory.appending(path: "20260501.jsonl")
        let freshLog = logsDirectory.appending(path: "20260611.jsonl")
        let ignoredFile = logsDirectory.appending(path: "notes.txt")
        let now = Date(timeIntervalSince1970: 1_781_136_000)

        try writeDebugLog(oldLog, size: 8, modifiedAt: now.addingTimeInterval(-9 * 86_400))
        try writeDebugLog(freshLog, size: 8, modifiedAt: now.addingTimeInterval(-2 * 86_400))
        try "keep".write(to: ignoredFile, atomically: true, encoding: .utf8)

        try BridgeDebugLogPruner.prune(
            directory: logsDirectory,
            policy: BridgeDebugLogPolicy(retentionDays: 7, maxDirectoryMegabytes: 16),
            now: now
        )

        #expect(!FileManager.default.fileExists(atPath: oldLog.path))
        #expect(FileManager.default.fileExists(atPath: freshLog.path))
        #expect(FileManager.default.fileExists(atPath: ignoredFile.path))
    }
}

@Test
func debugLogPrunerRemovesOldestFilesUntilUnderSizeLimit() async throws {
    try await withTemporaryDirectory { directory in
        let logsDirectory = directory.appending(path: ".ping-island-debug", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: logsDirectory, withIntermediateDirectories: true)
        let oldestLog = logsDirectory.appending(path: "20260609.jsonl")
        let middleLog = logsDirectory.appending(path: "20260610.jsonl")
        let newestLog = logsDirectory.appending(path: "20260611.jsonl")
        let now = Date(timeIntervalSince1970: 1_781_136_000)

        try writeDebugLog(oldestLog, size: 9 * 1024 * 1024, modifiedAt: now.addingTimeInterval(-3 * 86_400))
        try writeDebugLog(middleLog, size: 8 * 1024 * 1024, modifiedAt: now.addingTimeInterval(-2 * 86_400))
        try writeDebugLog(newestLog, size: 8 * 1024 * 1024, modifiedAt: now.addingTimeInterval(-86_400))

        try BridgeDebugLogPruner.prune(
            directory: logsDirectory,
            policy: BridgeDebugLogPolicy(retentionDays: 7, maxDirectoryMegabytes: 16),
            now: now
        )

        #expect(!FileManager.default.fileExists(atPath: oldestLog.path))
        #expect(FileManager.default.fileExists(atPath: middleLog.path))
        #expect(FileManager.default.fileExists(atPath: newestLog.path))
    }
}

@Test
func debugLogPrunerCountsExcludedActiveFileTowardSizeCapButNeverDeletesIt() async throws {
    try await withTemporaryDirectory { directory in
        let logsDirectory = directory.appending(path: ".ping-island-debug", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: logsDirectory, withIntermediateDirectories: true)
        let activeLog = logsDirectory.appending(path: "20260611.jsonl")  // today's file, excluded from deletion
        let oldLog = logsDirectory.appending(path: "20260610.jsonl")
        let now = Date(timeIntervalSince1970: 1_781_136_000)

        // The active file alone exceeds the 16MB cap; the older file is within retention.
        try writeDebugLog(activeLog, size: 20 * 1024 * 1024, modifiedAt: now)
        try writeDebugLog(oldLog, size: 8 * 1024 * 1024, modifiedAt: now.addingTimeInterval(-86_400))

        try BridgeDebugLogPruner.prune(
            directory: logsDirectory,
            policy: BridgeDebugLogPolicy(retentionDays: 7, maxDirectoryMegabytes: 16),
            now: now,
            excludingFileNames: ["20260611.jsonl"]
        )

        // The active file counts toward the cap (20MB > 16MB), so the old file is evicted
        // to reclaim space — but the protected active file itself is never deleted.
        #expect(!FileManager.default.fileExists(atPath: oldLog.path))
        #expect(FileManager.default.fileExists(atPath: activeLog.path))
    }
}

@Test
func debugLogPrunerDeletesLogsWhenPolicyDisabled() async throws {
    try await withTemporaryDirectory { directory in
        let logsDirectory = directory.appending(path: ".ping-island-debug", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: logsDirectory, withIntermediateDirectories: true)
        let log = logsDirectory.appending(path: "receiver.log")
        let ignoredFile = logsDirectory.appending(path: "notes.txt")
        let now = Date(timeIntervalSince1970: 1_781_136_000)

        try writeDebugLog(log, size: 8, modifiedAt: now)
        try "keep".write(to: ignoredFile, atomically: true, encoding: .utf8)

        try BridgeDebugLogPruner.prune(
            directory: logsDirectory,
            policy: BridgeDebugLogPolicy(isEnabled: false),
            now: now
        )

        #expect(!FileManager.default.fileExists(atPath: log.path))
        #expect(FileManager.default.fileExists(atPath: ignoredFile.path))
    }
}

private func writeDebugLog(_ url: URL, size: Int, modifiedAt: Date) throws {
    try Data(repeating: 0x61, count: size).write(to: url)
    try FileManager.default.setAttributes(
        [.modificationDate: modifiedAt],
        ofItemAtPath: url.path
    )
}
