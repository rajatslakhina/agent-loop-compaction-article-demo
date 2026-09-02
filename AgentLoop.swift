import Foundation

public enum ModelResponse: Sendable, Equatable {
    case message(String)
    case toolCall(name: String, argument: String)
    case done(String)
}

public protocol ModelClient: Sendable {
    func respond(to transcript: Transcript) -> ModelResponse
}
