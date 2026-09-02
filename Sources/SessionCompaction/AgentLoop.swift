import Foundation

public enum ModelResponse: Sendable, Equatable {
    case message(String)
    case toolCall(name: String, argument: String)
    case done(String)
}

public protocol ModelClient: Sendable {
    func respond(to transcript: Transcript) -> ModelResponse
}

public protocol ToolRunner: Sendable {
    func run(tool: String, argument: String) -> String
}

public enum LoopOutcome: Sendable, Equatable {
    case finished(answer: String, steps: Int)
    case exhausted(steps: Int)
    case refused(reason: String, steps: Int)
}

/// The loop. This is the whole thing.
///
/// It is worth reading once and then never again, because nothing interesting
/// happens here. Every decision that determines whether an agent is usable —
/// what gets dropped when the window fills, what a tool is allowed to do, what
/// survives a restart — lives in the systems this function calls, not in the
/// function.
public struct AgentLoop: Sendable {
    private let model: any ModelClient
    private let tools: any ToolRunner
    private let pipeline: CompactionPipeline
    private let budget: ContextBudget

    public init(
        model: any ModelClient,
        tools: any ToolRunner,
        pipeline: CompactionPipeline = .onDeviceDefault(),
        budget: ContextBudget = .onDevice
    ) {
        self.model = model
        self.tools = tools
        self.pipeline = pipeline
        self.budget = budget
    }

    public struct Run: Sendable {
        public var transcript: Transcript
        public var receipts: [StageReceipt]
        public var outcome: LoopOutcome
    }

    public func run(_ seed: Transcript, maxSteps: Int = 12) -> Run {
        var transcript = seed
        var receipts: [StageReceipt] = []
        for step in 1...max(1, maxSteps) {
            let compacted = pipeline.compact(transcript, budget: budget)
            transcript = compacted.transcript
            receipts.append(contentsOf: compacted.receipts)
            if case .overBudget(let excess) = compacted.status {
                return Run(transcript: transcript, receipts: receipts,
                           outcome: .refused(reason: "over budget by \(excess) tokens", steps: step))
            }
            switch model.respond(to: transcript) {
            case .done(let answer):
                return Run(transcript: transcript, receipts: receipts,
                           outcome: .finished(answer: answer, steps: step))
            case .message(let text):
                transcript.append(TranscriptEntry(sequence: transcript.nextSequence,
                                                  kind: .assistantTurn, text: text))
            case .toolCall(let name, let argument):
                transcript.append(TranscriptEntry(sequence: transcript.nextSequence,
                                                  kind: .toolCall, text: argument, toolName: name))
                transcript.append(TranscriptEntry(sequence: transcript.nextSequence,
                                                  kind: .toolResult,
                                                  text: tools.run(tool: name, argument: argument),
                                                  toolName: name))
            }
        }
        return Run(transcript: transcript, receipts: receipts, outcome: .exhausted(steps: maxSteps))
    }
}
