import Foundation

/// A deterministic session that reliably blows a 4K on-device window, so the
/// demo shows real compaction rather than a contrived one.
public enum SessionFixture {
    public static func longToolHeavySession() -> Transcript {
        var transcript = Transcript()
        var sequence = 0

        func add(_ kind: EntryKind, _ text: String, tool: String? = nil, pinned: Bool = false) {
            transcript.append(TranscriptEntry(sequence: sequence, kind: kind, text: text,
                                              toolName: tool, isPinned: pinned))
            sequence += 1
        }

        add(.systemInstruction, """
        You are an iOS engineering assistant working inside a Swift package. \
        Prefer reading before writing. Never modify Package.swift without asking.
        """, pinned: true)
        add(.userTurn, "Find why SessionStore drops the last write when the app is backgrounded.", pinned: true)

        let fileBody = """
        import Foundation
        final class SessionStore {
            private var pending: [Record] = []
            private let queue = DispatchQueue(label: "store")
            func append(_ record: Record) { queue.async { self.pending.append(record) } }
            func flush() { queue.async { self.writeAll(self.pending); self.pending.removeAll() } }
            private func writeAll(_ records: [Record]) { /* 40 lines of file IO */ }
        }
        """

        for round in 1...28 {
            add(.assistantTurn, "Checking how the store flushes on round \(round).")
            add(.toolCall, "Sources/Store/SessionStore.swift", tool: "readFile")
            add(.toolResult, fileBody, tool: "readFile")
            add(.toolCall, "backgrounded flush", tool: "searchLogs")
            add(.toolResult, String(repeating: "2026-09-02 12:\(round):11 flush scheduled for batch \(round); app suspended before the queue drained. ", count: 26), tool: "searchLogs")
        }

        add(.userTurn, "Skip the logs. Just tell me whether flush survives suspension.")
        return transcript
    }

    /// A pathological transcript: every entry is pinned and it still will not
    /// fit. Exists so the floor's reported failure is exercised, not theoretical.
    public static func unfittableSession(entries: Int = 24) -> Transcript {
        var transcript = Transcript()
        for index in 0..<max(1, entries) {
            transcript.append(TranscriptEntry(
                sequence: index,
                kind: index == 0 ? .systemInstruction : .userTurn,
                text: String(repeating: "immutable requirement \(index). ", count: 40),
                isPinned: true
            ))
        }
        return transcript
    }
}

/// A scripted model, so the loop is demonstrable offline and in tests.
public struct ScriptedModel: ModelClient {
    private let script: [ModelResponse]
    public init(_ script: [ModelResponse]) { self.script = script }

    public func respond(to transcript: Transcript) -> ModelResponse {
        let calls = transcript.entries.filter { $0.kind == .toolCall || $0.kind == .assistantTurn }.count
        guard calls < script.count else { return .done("no further steps scripted") }
        return script[calls]
    }
}

public struct EchoToolRunner: ToolRunner {
    public let padding: Int
    public init(padding: Int = 40) { self.padding = max(0, padding) }
    public func run(tool: String, argument: String) -> String {
        "\(tool)(\(argument)) -> " + String(repeating: "result row. ", count: padding)
    }
}
