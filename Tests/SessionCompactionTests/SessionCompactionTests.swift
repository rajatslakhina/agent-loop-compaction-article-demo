import XCTest
@testable import SessionCompaction

final class TranscriptTests: XCTestCase {
    func testTokenCountSumsEntries() {
        var transcript = Transcript()
        transcript.append(TranscriptEntry(sequence: 0, kind: .userTurn, text: String(repeating: "a", count: 40)))
        transcript.append(TranscriptEntry(sequence: 1, kind: .assistantTurn, text: String(repeating: "b", count: 8)))
        XCTAssertEqual(transcript.tokenCount, 10 + 2)
    }

    func testEmptyTextCostsNothingAndNonEmptyCostsAtLeastOne() {
        XCTAssertEqual(TokenEstimator.estimate(""), 0)
        XCTAssertEqual(TokenEstimator.estimate("a"), 1)
        XCTAssertEqual(TokenEstimator.estimate("abcd"), 1)
        XCTAssertEqual(TokenEstimator.estimate("abcde"), 2)
    }

    func testEntriesAreOrderedBySequenceNotInsertionOrder() {
        let transcript = Transcript(entries: [
            TranscriptEntry(sequence: 5, kind: .userTurn, text: "late"),
            TranscriptEntry(sequence: 1, kind: .userTurn, text: "early")
        ])
        XCTAssertEqual(transcript.entries.map(\.sequence), [1, 5])
        XCTAssertEqual(transcript.nextSequence, 6)
    }

    func testNextSequenceOnEmptyTranscriptIsZero() {
        XCTAssertEqual(Transcript().nextSequence, 0)
    }
}

final class BudgetTests: XCTestCase {
    func testUsableCeilingSubtractsHeadroom() {
        XCTAssertEqual(ContextBudget.onDevice.usableCeiling, 4_096 - 768)
    }

    func testHeadroomLargerThanCeilingIsClamped() {
        let budget = ContextBudget(ceiling: 100, headroom: 400)
        XCTAssertEqual(budget.headroom, 100)
        XCTAssertEqual(budget.usableCeiling, 0)
    }

    func testNegativeCeilingIsClampedToZero() {
        XCTAssertEqual(ContextBudget(ceiling: -50, headroom: 10).ceiling, 0)
        XCTAssertEqual(ContextBudget(ceiling: -50, headroom: 10).usableCeiling, 0)
    }
}

final class StageTests: XCTestCase {
    private func toolResult(_ sequence: Int, _ text: String, tool: String = "readFile", pinned: Bool = false) -> TranscriptEntry {
        TranscriptEntry(sequence: sequence, kind: .toolResult, text: text, toolName: tool, isPinned: pinned)
    }

    func testDuplicateElisionKeepsNewestCopyAndPointsEarlierOnesAtIt() {
        let body = String(repeating: "identical body. ", count: 20)
        let transcript = Transcript(entries: [
            toolResult(0, body), toolResult(1, body), toolResult(2, body)
        ])
        let outcome = DuplicateToolResultElision().apply(to: transcript, budget: .onDevice)
        XCTAssertEqual(outcome.receipt.entriesRewritten, 2)
        XCTAssertEqual(outcome.transcript.entries.last?.text, body)
        XCTAssertTrue(outcome.transcript.entries[0].text.contains("#2"))
        XCTAssertLessThan(outcome.transcript.tokenCount, transcript.tokenCount)
    }

    func testDuplicateElisionNeverTouchesPinnedEntries() {
        let body = String(repeating: "identical body. ", count: 20)
        let transcript = Transcript(entries: [
            toolResult(0, body, pinned: true), toolResult(1, body, pinned: true)
        ])
        let outcome = DuplicateToolResultElision().apply(to: transcript, budget: .onDevice)
        XCTAssertEqual(outcome.receipt.entriesRewritten, 0)
        XCTAssertEqual(outcome.transcript, transcript)
    }

    func testTruncationKeepsHeadAndTail() {
        let text = "HEAD" + String(repeating: "x", count: 2_000) + "TAIL"
        let outcome = ToolResultTruncation(headCharacters: 10, tailCharacters: 10, threshold: 100)
            .apply(to: Transcript(entries: [toolResult(0, text)]), budget: .onDevice)
        let result = outcome.transcript.entries[0].text
        XCTAssertTrue(result.hasPrefix("HEAD"))
        XCTAssertTrue(result.hasSuffix("TAIL"))
        XCTAssertTrue(result.contains("characters elided"))
        XCTAssertEqual(outcome.receipt.entriesRewritten, 1)
    }

    func testTruncationLeavesShortResultsAlone() {
        let transcript = Transcript(entries: [toolResult(0, "short")])
        let outcome = ToolResultTruncation().apply(to: transcript, budget: .onDevice)
        XCTAssertEqual(outcome.receipt.entriesRewritten, 0)
        XCTAssertEqual(outcome.transcript, transcript)
    }

    func testSummarizationCollapsesMiddleAndNamesTheShape() {
        var entries: [TranscriptEntry] = []
        for index in 0..<12 {
            entries.append(TranscriptEntry(sequence: index,
                                           kind: index % 2 == 0 ? .toolCall : .toolResult,
                                           text: String(repeating: "body ", count: 30),
                                           toolName: "readFile"))
        }
        let transcript = Transcript(entries: entries)
        let outcome = SpanSummarization(keepFirst: 2, keepLast: 3)
            .apply(to: transcript, budget: ContextBudget(ceiling: 100, headroom: 0))
        let summaries = outcome.transcript.entries.filter { $0.kind == .summary }
        XCTAssertEqual(summaries.count, 1)
        XCTAssertTrue(summaries[0].text.contains("readFile"))
        XCTAssertEqual(outcome.receipt.entriesRemoved, 7)
        XCTAssertLessThan(outcome.transcript.tokenCount, transcript.tokenCount)
    }

    func testSummarizationCollapsesOnlyAsFarAsTheBudgetRequires() {
        // Twelve entries of ~38 tokens each. A ceiling that needs roughly two of
        // them reclaimed must not cost all seven collapsible entries.
        var entries: [TranscriptEntry] = []
        for index in 0..<12 {
            entries.append(TranscriptEntry(sequence: index, kind: .assistantTurn,
                                           text: String(repeating: "body ", count: 30)))
        }
        let transcript = Transcript(entries: entries)
        let ceiling = transcript.tokenCount - 60
        let outcome = SpanSummarization(keepFirst: 2, keepLast: 3)
            .apply(to: transcript, budget: ContextBudget(ceiling: ceiling, headroom: 0))
        XCTAssertGreaterThan(outcome.receipt.entriesRemoved, 0)
        XCTAssertLessThan(outcome.receipt.entriesRemoved, 7, "must not collapse the whole span to save two entries")
        XCTAssertLessThanOrEqual(outcome.transcript.tokenCount, ceiling)
    }

    func testSummarizationIsANoOpWhenEverythingIsInsideTheKeptWindow() {
        let entries = (0..<4).map { TranscriptEntry(sequence: $0, kind: .userTurn, text: "hi") }
        let transcript = Transcript(entries: entries)
        let outcome = SpanSummarization(keepFirst: 2, keepLast: 6)
            .apply(to: transcript, budget: ContextBudget(ceiling: 1, headroom: 0))
        XCTAssertEqual(outcome.transcript, transcript)
        XCTAssertFalse(outcome.receipt.didAnything)
    }

    func testEvictionKeepsPinnedEntriesInTheMiddle() {
        var entries: [TranscriptEntry] = []
        for index in 0..<12 {
            entries.append(TranscriptEntry(sequence: index, kind: .assistantTurn,
                                           text: String(repeating: "body ", count: 20),
                                           isPinned: index == 5))
        }
        let outcome = MiddleSpanEviction(keepFirst: 2, keepLast: 3)
            .apply(to: Transcript(entries: entries), budget: ContextBudget(ceiling: 1, headroom: 0))
        XCTAssertTrue(outcome.transcript.entries.contains { $0.sequence == 5 })
        XCTAssertEqual(outcome.receipt.entriesRemoved, 6)
    }

    func testEvictionStopsAsSoonAsTheTranscriptFits() {
        let entries = (0..<12).map {
            TranscriptEntry(sequence: $0, kind: .assistantTurn, text: String(repeating: "body ", count: 30))
        }
        let transcript = Transcript(entries: entries)
        let ceiling = transcript.tokenCount - 40
        let outcome = MiddleSpanEviction(keepFirst: 2, keepLast: 3)
            .apply(to: transcript, budget: ContextBudget(ceiling: ceiling, headroom: 0))
        XCTAssertEqual(outcome.receipt.entriesRemoved, 2, "40 tokens is two ~38-token entries, not the whole span")
        XCTAssertLessThanOrEqual(outcome.transcript.tokenCount, ceiling)
    }

    func testEvictionReportsNoOpWhenMiddleSpanIsEntirelyPinned() {
        let entries = (0..<10).map {
            TranscriptEntry(sequence: $0, kind: .userTurn, text: "body", isPinned: true)
        }
        let transcript = Transcript(entries: entries)
        let outcome = MiddleSpanEviction(keepFirst: 2, keepLast: 3)
            .apply(to: transcript, budget: ContextBudget(ceiling: 1, headroom: 0))
        XCTAssertEqual(outcome.transcript, transcript)
        XCTAssertEqual(outcome.receipt.notes, ["middle span was entirely pinned"])
    }

    func testFloorKeepsPinnedPlusMostRecentUserTurn() {
        let transcript = Transcript(entries: [
            TranscriptEntry(sequence: 0, kind: .systemInstruction, text: "rules", isPinned: true),
            TranscriptEntry(sequence: 1, kind: .assistantTurn, text: "chatter"),
            TranscriptEntry(sequence: 2, kind: .userTurn, text: "the live question")
        ])
        let outcome = PinnedFloor().apply(to: transcript, budget: .onDevice)
        XCTAssertEqual(outcome.transcript.entries.map(\.sequence), [0, 2])
        XCTAssertEqual(outcome.receipt.entriesRemoved, 1)
    }

    func testFloorOnEmptyTranscriptDoesNotCrash() {
        let outcome = PinnedFloor().apply(to: Transcript(), budget: .onDevice)
        XCTAssertTrue(outcome.transcript.isEmpty)
        XCTAssertEqual(outcome.receipt.entriesRemoved, 0)
    }
}

final class ReceiptTests: XCTestCase {
    func testDeepestLossClassIgnoresRungsThatChangedNothing() {
        let result = CompactionPipeline.onDeviceDefault()
            .compact(SessionFixture.longToolHeavySession(), budget: .onDevice)
        XCTAssertEqual(result.deepestLossClass, .detail)
        XCTAssertFalse(result.receipts.contains { $0.lossClass == .catastrophic })
    }

    func testLossClassesAreStrictlyAscendingAcrossTheLadder() {
        let classes = CompactionPipeline.onDeviceDefault().stages.map(\.lossClass)
        XCTAssertEqual(classes, [.redundancy, .verbosity, .detail, .span, .catastrophic])
        XCTAssertEqual(classes, classes.sorted())
    }
}

final class PipelineTests: XCTestCase {
    func testPipelineSortsStagesByLossClassRegardlessOfInputOrder() {
        let pipeline = CompactionPipeline(stages: [
            PinnedFloor(), MiddleSpanEviction(), ToolResultTruncation(), DuplicateToolResultElision()
        ])
        XCTAssertEqual(pipeline.stages.map(\.lossClass),
                       [.redundancy, .verbosity, .span, .catastrophic])
    }

    func testTranscriptAlreadyUnderBudgetRunsNoStages() {
        var transcript = Transcript()
        transcript.append(TranscriptEntry(sequence: 0, kind: .userTurn, text: "tiny"))
        let result = CompactionPipeline.onDeviceDefault().compact(transcript, budget: .onDevice)
        XCTAssertEqual(result.status, .withinBudget(stagesRun: 0))
        XCTAssertTrue(result.receipts.isEmpty)
        XCTAssertEqual(result.transcript, transcript)
    }

    func testEmptyTranscriptIsWithinBudget() {
        let result = CompactionPipeline.onDeviceDefault().compact(Transcript(), budget: .onDevice)
        XCTAssertEqual(result.status, .withinBudget(stagesRun: 0))
    }

    func testRealisticSessionFitsAndStopsBeforeTheFloor() {
        let transcript = SessionFixture.longToolHeavySession()
        XCTAssertGreaterThan(transcript.tokenCount, ContextBudget.onDevice.usableCeiling)

        let result = CompactionPipeline.onDeviceDefault().compact(transcript, budget: .onDevice)
        guard case .withinBudget(let stagesRun) = result.status else {
            return XCTFail("expected the ladder to fit the session, got \(result.status)")
        }
        XCTAssertLessThanOrEqual(result.transcript.tokenCount, ContextBudget.onDevice.usableCeiling)
        XCTAssertGreaterThan(result.tokensReclaimed, 0)
        XCTAssertLessThan(stagesRun, 5, "the floor should not be needed for an ordinary session")
        XCTAssertEqual(result.receipts.count, stagesRun)
    }

    func testPinnedContextSurvivesCompaction() {
        let result = CompactionPipeline.onDeviceDefault()
            .compact(SessionFixture.longToolHeavySession(), budget: .onDevice)
        XCTAssertTrue(result.transcript.entries.contains { $0.kind == .systemInstruction && $0.isPinned })
    }

    func testUnfittableSessionReportsOverBudgetInsteadOfPretending() {
        let transcript = SessionFixture.unfittableSession()
        let result = CompactionPipeline.onDeviceDefault().compact(transcript, budget: .onDevice)
        guard case .overBudget(let excess) = result.status else {
            return XCTFail("expected an over-budget report, got \(result.status)")
        }
        XCTAssertGreaterThan(excess, 0)
        XCTAssertEqual(result.receipts.count, 5, "every rung should have been tried")
        XCTAssertEqual(excess, result.transcript.tokenCount - ContextBudget.onDevice.usableCeiling)
    }

    func testEveryReceiptAccountsForItsOwnTokenChange() {
        let result = CompactionPipeline.onDeviceDefault()
            .compact(SessionFixture.longToolHeavySession(), budget: .onDevice)
        for receipt in result.receipts {
            XCTAssertGreaterThanOrEqual(receipt.tokensBefore, receipt.tokensAfter)
        }
        XCTAssertEqual(result.receipts.first?.tokensBefore, result.tokensBefore)
        XCTAssertEqual(result.receipts.last?.tokensAfter, result.transcript.tokenCount)
    }
}

final class AgentLoopTests: XCTestCase {
    func testLoopFinishesWhenTheModelSaysItIsDone() {
        let loop = AgentLoop(model: ScriptedModel([
            .toolCall(name: "readFile", argument: "Store.swift"),
            .message("found it"),
            .done("flush does not survive suspension")
        ]), tools: EchoToolRunner())

        var seed = Transcript()
        seed.append(TranscriptEntry(sequence: 0, kind: .userTurn, text: "why does flush drop writes?", isPinned: true))

        let run = loop.run(seed)
        XCTAssertEqual(run.outcome, .finished(answer: "flush does not survive suspension", steps: 3))
        XCTAssertTrue(run.transcript.entries.contains { $0.kind == .toolResult })
    }

    func testLoopStopsAtMaxStepsWithoutRunningAway() {
        let loop = AgentLoop(model: ScriptedModel(
            Array(repeating: .toolCall(name: "readFile", argument: "a"), count: 50)
        ), tools: EchoToolRunner(padding: 4))
        let run = loop.run(Transcript(), maxSteps: 3)
        XCTAssertEqual(run.outcome, .exhausted(steps: 3))
    }

    func testLoopRefusesRatherThanShippingAnOverBudgetPrompt() {
        let loop = AgentLoop(model: ScriptedModel([.done("unreachable")]), tools: EchoToolRunner())
        let run = loop.run(SessionFixture.unfittableSession())
        guard case .refused(let reason, _) = run.outcome else {
            return XCTFail("expected a refusal, got \(run.outcome)")
        }
        XCTAssertTrue(reason.contains("over budget"))
    }

    func testLoopStaysUnderBudgetWhileToolResultsPileUp() {
        let loop = AgentLoop(model: ScriptedModel(
            Array(repeating: .toolCall(name: "readFile", argument: "big"), count: 40)
        ), tools: EchoToolRunner(padding: 120))
        let run = loop.run(Transcript(), maxSteps: 20)
        XCTAssertEqual(run.outcome, .exhausted(steps: 20))
        XCTAssertLessThanOrEqual(
            CompactionPipeline.onDeviceDefault().compact(run.transcript, budget: .onDevice).transcript.tokenCount,
            ContextBudget.onDevice.usableCeiling
        )
    }
}
