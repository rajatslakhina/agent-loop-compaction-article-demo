import Foundation

/// The hard ceiling a session has to fit inside, and the room reserved for
/// whatever the model is about to say next.
///
/// `headroom` is the part teams forget. A transcript that exactly fills the
/// context window leaves the model nothing to answer with, so the number the
/// compaction pipeline actually targets is `usableCeiling`, not `ceiling`.
public struct ContextBudget: Sendable, Equatable, Codable {
    public let ceiling: Int
    public let headroom: Int

    public init(ceiling: Int, headroom: Int) {
        self.ceiling = max(0, ceiling)
        self.headroom = max(0, min(headroom, max(0, ceiling)))
    }

    public var usableCeiling: Int { max(0, ceiling - headroom) }

    /// The on-device default this demo is built around: a 4,096-token window
    /// with 768 tokens held back for the response.
    public static let onDevice = ContextBudget(ceiling: 4_096, headroom: 768)
}

/// What one stage did, in enough detail that the decision is auditable after
/// the fact. Receipts are the durability format for compaction: without them a
/// session that lost context looks identical to one that never had it.
public struct StageReceipt: Sendable, Equatable, Codable {
    public let stageName: String
    /// The damage this rung is permitted to do, carried on the receipt so a
    /// reader does not have to know the pipeline's ordering to interpret it.
    public let lossClass: LossClass
    public let tokensBefore: Int
    public let tokensAfter: Int
    public let entriesRemoved: Int
    public let entriesRewritten: Int
    public let notes: [String]

    public init(
        stageName: String,
        lossClass: LossClass,
        tokensBefore: Int,
        tokensAfter: Int,
        entriesRemoved: Int,
        entriesRewritten: Int,
        notes: [String]
    ) {
        self.stageName = stageName
        self.lossClass = lossClass
        self.tokensBefore = tokensBefore
        self.tokensAfter = tokensAfter
        self.entriesRemoved = entriesRemoved
        self.entriesRewritten = entriesRewritten
        self.notes = notes
    }

    public var tokensReclaimed: Int { max(0, tokensBefore - tokensAfter) }
    public var didAnything: Bool { entriesRemoved > 0 || entriesRewritten > 0 }
}

public struct StageOutcome: Sendable {
    public let transcript: Transcript
    public let receipt: StageReceipt

    public init(transcript: Transcript, receipt: StageReceipt) {
        self.transcript = transcript
        self.receipt = receipt
    }
}

/// One rung on the escalating-loss ladder.
public protocol CompactionStage: Sendable {
    var name: String { get }
    /// Declared damage class, ascending. The pipeline runs stages in this order
    /// and stops at the first rung that gets the transcript under budget.
    var lossClass: LossClass { get }
    func apply(to transcript: Transcript, budget: ContextBudget) -> StageOutcome
}

/// How much a stage is allowed to destroy. This is the ordering key for the
/// whole pipeline, and it is a policy decision rather than an implementation detail.
public enum LossClass: Int, Sendable, Comparable, CaseIterable, Codable {
    /// Redundant content collapsed to a pointer. Nothing unique is lost.
    case redundancy = 0
    /// The middle of verbose output is dropped. Head and tail both survive.
    case verbosity = 1
    /// A span is replaced by a structural summary. Detail lost, shape kept.
    case detail = 2
    /// A span is dropped outright.
    case span = 3
    /// Everything except pinned context and the live question is dropped.
    case catastrophic = 4

    public static func < (lhs: LossClass, rhs: LossClass) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    /// Short human label, used on receipts and in the demo UI.
    public var label: String {
        switch self {
        case .redundancy: "redundancy"
        case .verbosity: "verbosity"
        case .detail: "detail"
        case .span: "span"
        case .catastrophic: "floor"
        }
    }
}
