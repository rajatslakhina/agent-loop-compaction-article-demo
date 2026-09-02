#if canImport(SwiftUI)
import SwiftUI

/// A live view of the ladder: a real transcript, a real budget, and the receipt
/// trail from the stages that actually ran.
@available(iOS 17.0, macOS 14.0, *)
public struct CompactionDemoView: View {
    @State private var transcript = SessionFixture.longToolHeavySession()
    @State private var ceiling: Double = 4_096
    @State private var result: CompactionResult?
    @State private var usePathologicalSession = false

    public init() {}

    private var budget: ContextBudget {
        ContextBudget(ceiling: Int(ceiling), headroom: 768)
    }

    private var fillRatio: Double {
        guard budget.usableCeiling > 0 else { return 1 }
        return min(1.6, Double(transcript.tokenCount) / Double(budget.usableCeiling))
    }

    public var body: some View {
        NavigationStack {
            List {
                budgetSection
                controlsSection
                if let result { receiptSection(result) }
                transcriptSection
            }
            .navigationTitle("Compaction Ladder")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
        }
    }

    private var budgetSection: some View {
        Section("Context budget") {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("\(transcript.tokenCount) tokens")
                        .font(.title2.weight(.semibold))
                        .monospacedDigit()
                    Spacer()
                    Text("limit \(budget.usableCeiling)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule().fill(.quaternary)
                        Capsule()
                            .fill(fillRatio > 1 ? Color.red : Color.green)
                            .frame(width: max(4, proxy.size.width * min(1, fillRatio / 1.6)))
                        Rectangle()
                            .fill(.primary)
                            .frame(width: 2)
                            .offset(x: proxy.size.width / 1.6)
                    }
                }
                .frame(height: 12)
                Text(fillRatio > 1
                     ? "Over the usable ceiling by \(transcript.tokenCount - budget.usableCeiling) tokens."
                     : "Fits, with \(budget.usableCeiling - transcript.tokenCount) tokens to spare.")
                    .font(.footnote)
                    .foregroundStyle(fillRatio > 1 ? Color.red : Color.secondary)
                HStack {
                    Text("Ceiling").font(.footnote).foregroundStyle(.secondary)
                    Slider(value: $ceiling, in: 1_024...8_192, step: 256)
                    Text("\(Int(ceiling))").font(.footnote.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 4)
        }
    }

    private var controlsSection: some View {
        Section {
            Button("Run the ladder") {
                let outcome = CompactionPipeline.onDeviceDefault().compact(transcript, budget: budget)
                result = outcome
                transcript = outcome.transcript
            }
            .disabled(transcript.tokenCount <= budget.usableCeiling)

            Toggle("Pathological session (all pinned)", isOn: $usePathologicalSession)
                .onChange(of: usePathologicalSession) { _, pinned in reset(pathological: pinned) }

            Button("Reset session") { reset(pathological: usePathologicalSession) }
        } footer: {
            Text("Stages run cheapest-damage-first and stop at the first rung that fits.")
        }
    }

    private func reset(pathological: Bool) {
        transcript = pathological ? SessionFixture.unfittableSession() : SessionFixture.longToolHeavySession()
        result = nil
    }

    @ViewBuilder
    private func receiptSection(_ result: CompactionResult) -> some View {
        Section("Receipts") {
            switch result.status {
            case .withinBudget(let stagesRun):
                Label("Fits after \(stagesRun) of 5 rungs — \(result.tokensReclaimed) tokens reclaimed",
                      systemImage: "checkmark.seal.fill")
                    .foregroundStyle(.green)
            case .overBudget(let excess):
                Label("All 5 rungs ran and it still overflows by \(excess) tokens",
                      systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
            }
            ForEach(Array(result.receipts.enumerated()), id: \.offset) { index, receipt in
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text("\(index + 1). \(receipt.stageName)").font(.subheadline.weight(.semibold))
                        Text(receipt.lossClass.label)
                            .font(.caption2.weight(.medium))
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Color.secondary.opacity(0.15), in: Capsule())
                            .foregroundStyle(Color.secondary)
                    }
                    Text("\(receipt.tokensBefore) → \(receipt.tokensAfter) tokens  ·  −\(receipt.tokensReclaimed)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                    if receipt.entriesRemoved > 0 || receipt.entriesRewritten > 0 {
                        Text("\(receipt.entriesRemoved) removed, \(receipt.entriesRewritten) rewritten")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    ForEach(receipt.notes, id: \.self) { note in
                        Text(note).font(.caption2).foregroundStyle(.tertiary)
                    }
                }
                .padding(.vertical, 2)
            }
        }
    }

    private var transcriptSection: some View {
        Section("Transcript (\(transcript.count) entries)") {
            ForEach(transcript.entries.prefix(40)) { entry in
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text("#\(entry.sequence)").font(.caption2.monospacedDigit()).foregroundStyle(.tertiary)
                        Text(entry.toolName.map { "\(entry.kind.rawValue) · \($0)" } ?? entry.kind.rawValue)
                            .font(.caption.weight(.medium))
                            .foregroundStyle(color(for: entry.kind))
                        if entry.isPinned { Image(systemName: "pin.fill").font(.caption2).foregroundStyle(.orange) }
                        Spacer()
                        Text("\(entry.tokenCost)t").font(.caption2.monospacedDigit()).foregroundStyle(.tertiary)
                    }
                    Text(entry.text).font(.caption).lineLimit(2).foregroundStyle(.secondary)
                }
                .padding(.vertical, 1)
            }
        }
    }

    private func color(for kind: EntryKind) -> Color {
        switch kind {
        case .systemInstruction: .purple
        case .userTurn: .blue
        case .assistantTurn: .teal
        case .toolCall: .indigo
        case .toolResult: .brown
        case .summary: .orange
        }
    }
}
#endif
