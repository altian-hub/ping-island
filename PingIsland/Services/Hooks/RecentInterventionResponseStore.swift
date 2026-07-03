//
//  RecentInterventionResponseStore.swift
//  PingIsland
//
//  Caches very recent inline answers so duplicate hook retries can be auto-resolved.
//

import Foundation

struct RecentInterventionResponse: Sendable {
    let decision: String
    let reason: String?
    let updatedInput: [String: AnyCodable]?
    let cachedAt: Date
}

struct RecentInterventionResponseStore {
    private let ttl: TimeInterval
    private var responses: [String: RecentInterventionResponse] = [:]

    init(ttl: TimeInterval = 30) {
        self.ttl = ttl
    }

    mutating func record(
        event: HookEvent,
        decision: String,
        reason: String?,
        updatedInput: [String: AnyCodable]?,
        now: Date = Date()
    ) {
        guard decision == "answer", Self.shouldStoreAnswerReplay(for: event) else {
            return
        }

        prune(now: now)
        guard let key = Self.cacheKey(for: event) else { return }
        responses[key] = RecentInterventionResponse(
            decision: decision,
            reason: reason,
            updatedInput: updatedInput,
            cachedAt: now
        )
    }

    mutating func response(for event: HookEvent, now: Date = Date()) -> RecentInterventionResponse? {
        prune(now: now)
        guard Self.shouldReplayAnswer(for: event) else { return nil }
        guard let key = Self.cacheKey(for: event) else { return nil }
        return responses[key]
    }

    mutating func prune(now: Date = Date()) {
        responses = responses.filter { _, response in
            now.timeIntervalSince(response.cachedAt) <= ttl
        }
    }

    static func cacheKey(for event: HookEvent) -> String? {
        guard shouldStoreAnswerReplay(for: event) else {
            return nil
        }

        guard let normalizedTool = HookEvent.normalizedToolName(event.tool),
              HookEvent.questionToolNames.contains(normalizedTool) else { return nil }
        guard let signature = questionSignature(from: event.toolInput), !signature.isEmpty else { return nil }

        return ([event.sessionId, normalizedTool] + signature).joined(separator: "||")
    }

    // Only qoderwork question flows are held-and-answered through Island in a way
    // that re-fires duplicate hooks; native/plain-Claude question sockets are never
    // held (notify-only so the CLI's own picker renders — see
    // HookEvent.shouldHoldHookSocket), so the former plain-Claude record/replay
    // branches were unreachable dead weight: entries were written but a duplicate
    // question PermissionRequest is closed with no decision by design.
    private static func shouldStoreAnswerReplay(for event: HookEvent) -> Bool {
        event.clientInfo.profileID == "qoderwork" || event.clientInfo.bundleIdentifier == "com.qoder.work"
    }

    private static func shouldReplayAnswer(for event: HookEvent) -> Bool {
        shouldStoreAnswerReplay(for: event)
    }

    static func questionSignature(from toolInput: [String: AnyCodable]?) -> [String]? {
        guard let rawQuestions = toolInput?["questions"]?.value as? [Any], !rawQuestions.isEmpty else {
            return nil
        }

        let questions = rawQuestions.compactMap { entry -> [String: Any]? in
            entry as? [String: Any]
        }
        guard !questions.isEmpty else { return nil }

        return questions.map { question in
            let prompt = SessionTextSanitizer.sanitizedDisplayText(
                (question["question"] as? String) ?? (question["prompt"] as? String)
            ) ?? ""
            let header = SessionTextSanitizer.sanitizedDisplayText(question["header"] as? String) ?? ""
            let identifier = SessionTextSanitizer.sanitizedDisplayText(question["id"] as? String) ?? ""
            return [identifier, header, prompt]
                .joined(separator: "|")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }
}
