import Foundation

/// The result of running the ladder once.
public struct CompactionResult: Sendable {
    public enum Status: Sendable, Equatable {
        /// The transcript fits. `stagesRun` is how far down the ladder it went.
        case withinBudget(stagesRun: Int)
        /// Every rung ran and the transcript still does not fit. This is a
        /// reported outcome, not a thrown error: the caller decides whether to
        /// split the task, drop the tool or refuse.
        case overBudget(excess: Int)
    }

    public let transcript: Transcript
    public let receipts: [StageReceipt]
    public let status: Status
    public let tokensBefore: Int

    public var tokensAfter: Int { transcript.tokenCount }
    public var tokensReclaimed: Int { max(0, tokensBefore - tokensAfter) }
    /// The worst damage any rung that actually changed something was allowed to do.
    public var deepestLossClass: LossClass? {
        receipts.filter(\.didAnything).map(\.lossClass).max()
    }
}

/// An ordered ladder of compaction stages, run cheapest-damage-first and
/// stopped at the first rung that gets the transcript under budget.
///
/// The ordering is the design. Any single stage in here is unremarkable; what
/// makes the pipeline a system rather than a heuristic is that the stages are
/// sorted by declared loss class, each one reports what it destroyed, and the
/// bottom rung turns "we could not fit" into a value instead of a crash.
public struct CompactionPipeline: Sendable {
    public let stages: [any CompactionStage]

    /// Stages are sorted by loss class on construction, so a caller cannot
    /// accidentally put eviction ahead of truncation.
    public init(stages: [any CompactionStage]) {
        self.stages = stages.sorted { $0.lossClass < $1.lossClass }
    }

    /// The five-rung ladder this demo is built around.
    public static func onDeviceDefault(keepFirst: Int = 2, keepLast: Int = 6) -> CompactionPipeline {
        CompactionPipeline(stages: [
            DuplicateToolResultElision(),
            ToolResultTruncation(),
            SpanSummarization(keepFirst: keepFirst, keepLast: keepLast),
            MiddleSpanEviction(keepFirst: keepFirst, keepLast: keepLast),
            PinnedFloor()
        ])
    }

    public func compact(_ transcript: Transcript, budget: ContextBudget) -> CompactionResult {
        let startingTokens = transcript.tokenCount
        guard startingTokens > budget.usableCeiling else {
            return CompactionResult(
                transcript: transcript,
                receipts: [],
                status: .withinBudget(stagesRun: 0),
                tokensBefore: startingTokens
            )
        }

        var current = transcript
        var receipts: [StageReceipt] = []

        for stage in stages {
            let outcome = stage.apply(to: current, budget: budget)
            current = outcome.transcript
            receipts.append(outcome.receipt)
            if current.tokenCount <= budget.usableCeiling {
                return CompactionResult(
                    transcript: current,
                    receipts: receipts,
                    status: .withinBudget(stagesRun: receipts.count),
                    tokensBefore: startingTokens
                )
            }
        }

        return CompactionResult(
            transcript: current,
            receipts: receipts,
            status: .overBudget(excess: current.tokenCount - budget.usableCeiling),
            tokensBefore: startingTokens
        )
    }
}
