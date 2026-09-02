import Foundation

// MARK: - Rung 1: redundancy

/// Collapses repeated identical tool results to a single full copy plus pointers.
///
/// Agents re-read the same file constantly. This is the cheapest real win in a
/// long session and it is very close to lossless: the newest copy stays intact
/// and every earlier one becomes a one-line reference to it.
public struct DuplicateToolResultElision: CompactionStage {
    public let name = "Duplicate elision"
    public let lossClass = LossClass.redundancy

    public init() {}

    public func apply(to transcript: Transcript, budget: ContextBudget) -> StageOutcome {
        let before = transcript.tokenCount
        var lastIndexByKey: [String: Int] = [:]

        for (index, entry) in transcript.entries.enumerated()
        where entry.kind == .toolResult && !entry.isPinned {
            lastIndexByKey[Self.key(for: entry)] = index
        }

        var rewritten = 0
        var notes: [String] = []
        var output: [TranscriptEntry] = []
        output.reserveCapacity(transcript.count)

        for (index, entry) in transcript.entries.enumerated() {
            guard entry.kind == .toolResult, !entry.isPinned,
                  let newest = lastIndexByKey[Self.key(for: entry)], newest != index
            else {
                output.append(entry)
                continue
            }
            let pointer = "[identical to later \(entry.toolName ?? "tool") result at #\(transcript.entries[newest].sequence)]"
            output.append(entry.rewritten(text: pointer))
            rewritten += 1
            notes.append("#\(entry.sequence) -> pointer to #\(transcript.entries[newest].sequence)")
        }

        let result = transcript.replacing(output)
        return StageOutcome(
            transcript: result,
            receipt: StageReceipt(
                stageName: name,
                lossClass: lossClass,
                tokensBefore: before,
                tokensAfter: result.tokenCount,
                entriesRemoved: 0,
                entriesRewritten: rewritten,
                notes: Array(notes.prefix(4))
            )
        )
    }

    private static func key(for entry: TranscriptEntry) -> String {
        "\(entry.toolName ?? "-")\u{1F}\(entry.text)"
    }
}

// MARK: - Rung 2: verbosity

/// Trims the middle out of oversized tool results, keeping a head and a tail.
///
/// Head and tail are both kept on purpose: the head carries the schema or the
/// first rows, the tail carries the error or the total. Keeping only one end is
/// the single most common way a truncation policy destroys the useful part.
public struct ToolResultTruncation: CompactionStage {
    public let name = "Tool result truncation"
    public let lossClass = LossClass.verbosity

    public let headCharacters: Int
    public let tailCharacters: Int
    public let threshold: Int

    public init(headCharacters: Int = 240, tailCharacters: Int = 120, threshold: Int = 480) {
        self.headCharacters = max(0, headCharacters)
        self.tailCharacters = max(0, tailCharacters)
        self.threshold = max(1, threshold)
    }

    public func apply(to transcript: Transcript, budget: ContextBudget) -> StageOutcome {
        let before = transcript.tokenCount
        var rewritten = 0
        var notes: [String] = []

        let output = transcript.entries.map { entry -> TranscriptEntry in
            guard entry.kind == .toolResult, !entry.isPinned, entry.text.count > threshold else {
                return entry
            }
            let head = String(entry.text.prefix(headCharacters))
            let tail = String(entry.text.suffix(tailCharacters))
            let dropped = max(0, entry.text.count - head.count - tail.count)
            guard dropped > 0 else { return entry }
            rewritten += 1
            notes.append("#\(entry.sequence) trimmed \(dropped) chars")
            return entry.rewritten(text: "\(head)\n… \(dropped) characters elided …\n\(tail)")
        }

        let result = transcript.replacing(output)
        return StageOutcome(
            transcript: result,
            receipt: StageReceipt(
                stageName: name,
                lossClass: lossClass,
                tokensBefore: before,
                tokensAfter: result.tokenCount,
                entriesRemoved: 0,
                entriesRewritten: rewritten,
                notes: Array(notes.prefix(4))
            )
        )
    }
}

// MARK: - Rung 3: detail

/// Replaces the oldest part of the middle span with one structural summary entry,
/// collapsing only as far as the budget actually requires.
///
/// The stopping rule is the whole point. A stage that collapses everything it is
/// allowed to collapse routinely overshoots by an order of magnitude — the first
/// version of this one took a 3,853-token transcript to 318 against a 3,328
/// target, throwing away 135 entries to save 525 it needed. Each rung does the
/// least damage that clears the bar, not the most damage it is permitted.
///
/// The summary here is produced locally and deterministically. In production this
/// is where a model summarizer goes; what matters architecturally is that the seam
/// exists and that the result is an ordinary transcript entry, so the rungs below
/// can evict a summary exactly like anything else.
public struct SpanSummarization: CompactionStage {
    public let name = "Span summarization"
    public let lossClass = LossClass.detail

    public let keepFirst: Int
    public let keepLast: Int

    public init(keepFirst: Int = 2, keepLast: Int = 6) {
        self.keepFirst = max(0, keepFirst)
        self.keepLast = max(0, keepLast)
    }

    public func apply(to transcript: Transcript, budget: ContextBudget) -> StageOutcome {
        let before = transcript.tokenCount
        let entries = transcript.entries

        func noOp(_ note: String) -> StageOutcome {
            StageOutcome(transcript: transcript, receipt: StageReceipt(
                stageName: name, lossClass: lossClass, tokensBefore: before, tokensAfter: before,
                entriesRemoved: 0, entriesRewritten: 0, notes: [note]))
        }

        guard entries.count > keepFirst + keepLast else { return noOp("nothing outside the kept window") }

        let middle = Array(entries[keepFirst..<(entries.count - keepLast)])
        let collapsible = middle.filter { !$0.isPinned && $0.kind != .summary }
        guard collapsible.count > 1 else { return noOp("middle span had nothing collapsible") }

        // Grow the collapsed group oldest-first and stop at the first size that fits.
        // Linear in the size of the middle span, which is bounded by the transcript.
        var groupSize = collapsible.count
        var reclaimed = 0
        for size in 1...collapsible.count {
            let group = Array(collapsible.prefix(size))
            reclaimed = group.reduce(0) { $0 + $1.tokenCost }
                - TokenEstimator.estimate(Self.describe(group))
            if before - reclaimed <= budget.usableCeiling {
                groupSize = size
                break
            }
        }

        let group = Array(collapsible.prefix(groupSize))
        guard let anchor = group.first?.sequence else { return noOp("no anchor entry") }
        let collapsedIDs = Set(group.map(\.id))
        let summary = TranscriptEntry(sequence: anchor, kind: .summary, text: Self.describe(group))

        var output = Array(entries.prefix(keepFirst))
        output.append(summary)
        output.append(contentsOf: middle.filter { !collapsedIDs.contains($0.id) })
        output.append(contentsOf: entries.suffix(keepLast))

        let result = transcript.replacing(output)
        return StageOutcome(transcript: result, receipt: StageReceipt(
            stageName: name, lossClass: lossClass, tokensBefore: before, tokensAfter: result.tokenCount,
            entriesRemoved: group.count, entriesRewritten: 1,
            notes: ["collapsed \(group.count) of \(collapsible.count) collapsible entries into #\(anchor)"]))
    }

    static func describe(_ entries: [TranscriptEntry]) -> String {
        var counts: [EntryKind: Int] = [:]
        var tools: [String] = []
        for entry in entries {
            counts[entry.kind, default: 0] += 1
            if let tool = entry.toolName, !tools.contains(tool) { tools.append(tool) }
        }
        let shape = EntryKind.allCases
            .compactMap { kind in counts[kind].map { "\($0) \(kind.rawValue)" } }
            .joined(separator: ", ")
        let toolLine = tools.isEmpty ? "" : " Tools used: \(tools.joined(separator: ", "))."
        return "[summary of \(entries.count) earlier entries: \(shape).\(toolLine)]"
    }
}

// MARK: - Rung 4: span

/// Drops middle-span entries oldest-first, stopping as soon as the transcript fits.
///
/// Like the rung above it, this evicts the minimum that clears the bar rather
/// than everything it is entitled to evict. Pinned entries are never candidates.
public struct MiddleSpanEviction: CompactionStage {
    public let name = "Middle span eviction"
    public let lossClass = LossClass.span

    public let keepFirst: Int
    public let keepLast: Int

    public init(keepFirst: Int = 2, keepLast: Int = 6) {
        self.keepFirst = max(0, keepFirst)
        self.keepLast = max(0, keepLast)
    }

    public func apply(to transcript: Transcript, budget: ContextBudget) -> StageOutcome {
        let before = transcript.tokenCount
        let entries = transcript.entries

        func noOp(_ note: String) -> StageOutcome {
            StageOutcome(transcript: transcript, receipt: StageReceipt(
                stageName: name, lossClass: lossClass, tokensBefore: before, tokensAfter: before,
                entriesRemoved: 0, entriesRewritten: 0, notes: [note]))
        }

        guard entries.count > keepFirst + keepLast else { return noOp("nothing outside the kept window") }

        let middle = Array(entries[keepFirst..<(entries.count - keepLast)])
        let evictable = middle.filter { !$0.isPinned }
        guard !evictable.isEmpty else { return noOp("middle span was entirely pinned") }

        var running = before
        var doomed = Set<UUID>()
        for entry in evictable {
            if running <= budget.usableCeiling { break }
            doomed.insert(entry.id)
            running -= entry.tokenCost
        }
        guard !doomed.isEmpty else { return noOp("already within budget") }

        var output = Array(entries.prefix(keepFirst))
        output.append(contentsOf: middle.filter { !doomed.contains($0.id) })
        output.append(contentsOf: entries.suffix(keepLast))

        let result = transcript.replacing(output)
        return StageOutcome(transcript: result, receipt: StageReceipt(
            stageName: name, lossClass: lossClass, tokensBefore: before, tokensAfter: result.tokenCount,
            entriesRemoved: doomed.count,
            entriesRewritten: 0,
            notes: ["evicted \(doomed.count) of \(evictable.count) evictable entries; kept \(keepFirst) leading and \(keepLast) trailing"]))
    }
}

// MARK: - Rung 5: catastrophic

/// The declared floor: pinned context plus the live question, and nothing else.
///
/// This rung exists so the failure is named. A pipeline without a floor either
/// silently ships an over-budget prompt or throws from somewhere unhelpful.
public struct PinnedFloor: CompactionStage {
    public let name = "Pinned floor"
    public let lossClass = LossClass.catastrophic

    public init() {}

    public func apply(to transcript: Transcript, budget: ContextBudget) -> StageOutcome {
        let before = transcript.tokenCount
        var kept = transcript.entries.filter(\.isPinned)
        if let live = transcript.mostRecentUserTurn,
           !kept.contains(where: { $0.id == live.id }) {
            kept.append(live)
        }

        let result = transcript.replacing(kept)
        return StageOutcome(
            transcript: result,
            receipt: StageReceipt(
                stageName: name,
                lossClass: lossClass,
                tokensBefore: before,
                tokensAfter: result.tokenCount,
                entriesRemoved: max(0, transcript.count - kept.count),
                entriesRewritten: 0,
                notes: ["kept \(kept.count) pinned/live entries"]
            )
        )
    }
}
