//
//  AnalysisUsage.swift
//  Greenroom
//
//  What an analysis run cost in tokens, as the user's own agent CLI reported
//  it. Pure: no UI, no I/O. Pinned by Tests/AnalysisUsageTests.
//
//  Only the agent step spends tokens, and only when the command streams JSON
//  (Claude Code `--output-format stream-json`, Codex `--json`). A custom
//  command that prints plain text reports nothing, so there is no usage to
//  show; Apple's on-device model and the counted-from-notes pass use no cloud
//  tokens at all.
//
import Foundation

struct AnalysisUsage: Codable, Hashable {
    /// "Claude Code", "Codex": the words the report prints.
    var tool: String
    /// Fresh input tokens. Cache writes are counted separately.
    var input = 0
    var output = 0
    var cacheRead = 0
    var cacheWrite = 0
    /// Dollars, only when the tool said so (Claude Code does, Codex does not).
    var costUSD: Double?

    var total: Int { input + output + cacheRead + cacheWrite }
    var isEmpty: Bool { total == 0 && costUSD == nil }

    // MARK: Words

    /// "12.4k", "812", "1.2M". One decimal at most, never "12.0k".
    static func compact(_ n: Int) -> String {
        let value = Double(max(n, 0))
        func trim(_ x: Double, _ suffix: String) -> String {
            let s = String(format: "%.1f", x)
            return (s.hasSuffix(".0") ? String(s.dropLast(2)) : s) + suffix
        }
        if value >= 999_950 { return trim(value / 1_000_000, "M") }
        if value >= 1_000 {
            // 999.96k would round up to "1000k"; call that a million.
            let k = value / 1_000
            return k >= 999.95 ? "1M" : trim(k, "k")
        }
        return String(Int(value))
    }

    /// "$0.04", or "<$0.01" for a real but tiny cost.
    static func money(_ dollars: Double) -> String {
        if dollars > 0, dollars < 0.005 { return "<$0.01" }
        return String(format: "$%.2f", dollars)
    }

    /// The popover's line: "12.4k in · 1.8k out · 9.1k cached · $0.04".
    /// Cached is omitted when there was none, the cost when unknown.
    var liveLine: String {
        var parts = ["\(Self.compact(input + cacheWrite)) in", "\(Self.compact(output)) out"]
        if cacheRead > 0 { parts.append("\(Self.compact(cacheRead)) cached") }
        if let costUSD { parts.append(Self.money(costUSD)) }
        return parts.joined(separator: " \u{00B7} ")
    }

    /// The report footer: "Written by Claude Code · 21.3k tokens · $0.04".
    var reportLine: String {
        var parts = ["Written by \(tool)"]
        if total > 0 { parts.append("\(Self.compact(total)) tokens") }
        if let costUSD { parts.append(Self.money(costUSD)) }
        return parts.joined(separator: " \u{00B7} ")
    }

    static let onDeviceLine = "On this Mac, no tokens"
}

/// Folds a CLI's JSON event lines into an `AnalysisUsage`.
///
/// Claude Code: every `assistant` event carries `message.usage` for its turn
/// (the same message id can repeat, once per content block, so the latest copy
/// per id is kept, not summed twice). The closing `result` event carries the
/// run's own total and `total_cost_usd`; once it arrives it wins.
///
/// Codex: `turn.completed` carries `usage` for the turn, summed across turns.
/// `input_tokens` there includes the cached part, so cached is taken out of
/// input. A `token_count` event (bare, or inside an `event_msg` payload) holds
/// a running total, which replaces rather than adds.
///
/// Anything that is not a JSON object, or has no usage, is ignored.
struct AnalysisUsageReader {
    let tool: String

    private var claudeTurns: [String: AnalysisUsage] = [:]
    private var claudeAnonymous: [AnalysisUsage] = []
    private var claudeFinal: AnalysisUsage?
    private var codexTurns = AnalysisUsage(tool: "")
    private var codexRunning: AnalysisUsage?
    private var sawCodexTurn = false

    init(tool: String) { self.tool = tool }

    /// What has been seen so far, or nil when nothing carried usage.
    var usage: AnalysisUsage? {
        var out: AnalysisUsage
        if let claudeFinal {
            out = claudeFinal
        } else if !claudeTurns.isEmpty || !claudeAnonymous.isEmpty {
            out = AnalysisUsage(tool: tool)
            for turn in Array(claudeTurns.values) + claudeAnonymous { out.add(turn) }
        } else if let codexRunning {
            out = codexRunning
        } else if sawCodexTurn {
            out = codexTurns
        } else {
            return nil
        }
        out.tool = tool
        return out
    }

    /// Returns true when this line changed `usage`.
    @discardableResult
    mutating func consume(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("{"),
              let data = trimmed.data(using: .utf8),
              let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = event["type"] as? String else { return false }

        switch type {
        case "assistant":
            let message = event["message"] as? [String: Any]
            guard let raw = message?["usage"] as? [String: Any],
                  let turn = Self.claude(raw) else { return false }
            if let id = message?["id"] as? String { claudeTurns[id] = turn } else { claudeAnonymous.append(turn) }
            return true
        case "result":
            guard let raw = event["usage"] as? [String: Any], var total = Self.claude(raw) else {
                // A result with a cost but no token block still sets the cost.
                guard let cost = Self.number(event["total_cost_usd"]) else { return false }
                var current = claudeFinal ?? AnalysisUsage(tool: tool)
                current.costUSD = cost
                claudeFinal = current
                return true
            }
            total.costUSD = Self.number(event["total_cost_usd"])
            claudeFinal = total
            return true
        case "turn.completed":
            guard let raw = event["usage"] as? [String: Any], let turn = Self.codex(raw) else { return false }
            codexTurns.add(turn)
            sawCodexTurn = true
            return true
        case "token_count":
            return takeCount(event)
        case "event_msg":
            guard let payload = event["payload"] as? [String: Any],
                  payload["type"] as? String == "token_count" else { return false }
            return takeCount(payload)
        default:
            return false
        }
    }

    private mutating func takeCount(_ container: [String: Any]) -> Bool {
        let info = container["info"] as? [String: Any]
        let raw = (info?["total_token_usage"] as? [String: Any])
            ?? (container["total_token_usage"] as? [String: Any])
            ?? (container["usage"] as? [String: Any])
        guard let raw, let total = Self.codex(raw) else { return false }
        codexRunning = total
        return true
    }

    private static func number(_ value: Any?) -> Double? {
        if let n = value as? NSNumber { return n.doubleValue }
        return nil
    }

    private static func int(_ raw: [String: Any], _ key: String) -> Int? {
        (raw[key] as? NSNumber).map { max($0.intValue, 0) }
    }

    private static func claude(_ raw: [String: Any]) -> AnalysisUsage? {
        let input = int(raw, "input_tokens"), output = int(raw, "output_tokens")
        let read = int(raw, "cache_read_input_tokens"), write = int(raw, "cache_creation_input_tokens")
        guard input != nil || output != nil || read != nil || write != nil else { return nil }
        return AnalysisUsage(tool: "", input: input ?? 0, output: output ?? 0,
                             cacheRead: read ?? 0, cacheWrite: write ?? 0)
    }

    private static func codex(_ raw: [String: Any]) -> AnalysisUsage? {
        let input = int(raw, "input_tokens"), output = int(raw, "output_tokens")
        let cached = int(raw, "cached_input_tokens") ?? int(raw, "cache_read_input_tokens")
        guard input != nil || output != nil || cached != nil else { return nil }
        let read = cached ?? 0
        return AnalysisUsage(tool: "", input: max((input ?? 0) - read, 0), output: output ?? 0,
                             cacheRead: read, cacheWrite: 0)
    }
}

private extension AnalysisUsage {
    mutating func add(_ other: AnalysisUsage) {
        input += other.input
        output += other.output
        cacheRead += other.cacheRead
        cacheWrite += other.cacheWrite
    }
}
