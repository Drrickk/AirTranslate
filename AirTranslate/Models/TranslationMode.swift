import Foundation

enum TranslationMode: String, CaseIterable, Identifiable, Codable, Sendable {
    case listen = "同传模式"
    case conversation = "双人对话"

    var id: String { rawValue }
}

enum ConversationSide: String, CaseIterable, Identifiable, Codable, Sendable {
    case other = "对方说"
    case me = "我来说"

    var id: String { rawValue }
}

enum TranslationDirection: String, Codable, Hashable, Sendable {
    case forward
    case reverse
}

enum ConversationSpeaker: String, Codable, Hashable, Sendable {
    case other
    case me
}

enum SummaryEngineChoice: String, CaseIterable, Identifiable, Sendable {
    case automatic = "自动"
    case localAI = "离线 AI"
    case quick = "快速本地"

    var id: String { rawValue }
}
