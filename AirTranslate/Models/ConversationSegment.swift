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

struct TranslationRequest: Identifiable, Hashable, Sendable {
    let id: UUID
    let segmentID: UUID
    let text: String
    let direction: TranslationDirection
    let sourceLanguage: AppLanguage
    let targetLanguage: AppLanguage
}
