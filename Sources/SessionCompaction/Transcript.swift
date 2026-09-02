import Foundation

/// What a single entry in an agent session transcript is.
///
/// The kind is load-bearing: every compaction stage decides what it may touch
/// by asking what kind an entry is, never by inspecting its text.
public enum EntryKind: String, Sendable, Codable, CaseIterable {
    case systemInstruction
    case userTurn
    case assistantTurn
    case toolCall
    case toolResult
    case summary
}

/// Deterministic, offline token estimate.
///
/// This is deliberately not a real tokenizer. A production pipeline swaps this
/// for the model's own tokenizer; the point of the architecture is that the
/// estimator is a single seam, not that this approximation is accurate.
public enum TokenEstimator {
    /// Roughly four characters per token, with every non-empty entry costing at least one.
    public static func estimate(_ text: String) -> Int {
        if text.isEmpty { return 0 }
        return max(1, (text.count + 3) / 4)
    }
}

/// One turn, tool call, tool result or summary in a session.
public struct TranscriptEntry: Identifiable, Sendable, Equatable, Codable {
    public let id: UUID
    public let sequence: Int
    public let kind: EntryKind
    public let text: String
    public let toolName: String?
    /// Pinned entries survive every stage except the declared hard floor.
    public let isPinned: Bool
    public let tokenCost: Int

    public init(
        id: UUID = UUID(),
        sequence: Int,
        kind: EntryKind,
        text: String,
        toolName: String? = nil,
        isPinned: Bool = false
    ) {
        self.id = id
        self.sequence = sequence
        self.kind = kind
        self.text = text
        self.toolName = toolName
        self.isPinned = isPinned
        self.tokenCost = TokenEstimator.estimate(text)
    }

    /// Returns a copy carrying rewritten text, preserving identity and ordering.
    public func rewritten(text newText: String, kind newKind: EntryKind? = nil) -> TranscriptEntry {
        TranscriptEntry(
            id: id,
            sequence: sequence,
            kind: newKind ?? kind,
            text: newText,
            toolName: toolName,
            isPinned: isPinned
        )
    }
}

/// An ordered session transcript. Ordering is by `sequence`, not by array index,
/// so a stage can rewrite or drop entries without renumbering anything.
public struct Transcript: Sendable, Equatable, Codable {
    public private(set) var entries: [TranscriptEntry]

    public init(entries: [TranscriptEntry] = []) {
        self.entries = entries.sorted { $0.sequence < $1.sequence }
    }

    public var tokenCount: Int {
        entries.reduce(0) { $0 + $1.tokenCost }
    }

    public var count: Int { entries.count }
    public var isEmpty: Bool { entries.isEmpty }

    public mutating func append(_ entry: TranscriptEntry) {
        entries.append(entry)
        entries.sort { $0.sequence < $1.sequence }
    }

    /// Next sequence number, so callers never have to track one themselves.
    public var nextSequence: Int {
        (entries.map(\.sequence).max() ?? -1) + 1
    }

    public func replacing(_ newEntries: [TranscriptEntry]) -> Transcript {
        Transcript(entries: newEntries)
    }

    public var mostRecentUserTurn: TranscriptEntry? {
        entries.last { $0.kind == .userTurn }
    }
}
