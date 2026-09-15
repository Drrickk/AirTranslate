import Foundation

struct ConversationSegment: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    let createdAt: Date
    let sourceText: String
    var translatedText: String
    var speaker: ConversationSpeaker?
    var sourceLanguage: AppLanguage?
    var targetLanguage: AppLanguage?

    init(
        id: UUID = UUID(),
        createdAt: Date = Date(),
        sourceText: String,
        translatedText: String = "",
        speaker: ConversationSpeaker? = nil,
        sourceLanguage: AppLanguage? = nil,
        targetLanguage: AppLanguage? = nil
    ) {
        self.id = id
        self.createdAt = createdAt
        self.sourceText = sourceText
        self.translatedText = translatedText
        self.speaker = speaker
        self.sourceLanguage = sourceLanguage
        self.targetLanguage = targetLanguage
    }
}

enum TranslationRequestPurpose: Hashable, Sendable {
    case preview
    case speechChunk
    case final
}

struct TranslationRequest: Identifiable, Hashable, Sendable {
    let id: UUID
    let segmentID: UUID?
    let text: String
    let direction: TranslationDirection
    let sourceLanguage: AppLanguage
    let targetLanguage: AppLanguage
    let purpose: TranslationRequestPurpose
    let speakAfterTranslation: Bool
}

/// Thread-safe bridge between the MainActor view model and SwiftUI's long-lived
/// TranslationSession task. Final requests are retained; preview work is
/// coalesced by the view model so it cannot build an unbounded queue.
final class TranslationRequestPipe: @unchecked Sendable {
    let stream: AsyncStream<TranslationRequest>
    private let continuation: AsyncStream<TranslationRequest>.Continuation

    init() {
        let pair = AsyncStream<TranslationRequest>.makeStream(bufferingPolicy: .unbounded)
        stream = pair.stream
        continuation = pair.continuation
    }

    func send(_ request: TranslationRequest) {
        continuation.yield(request)
    }
}
