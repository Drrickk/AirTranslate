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

enum TranslationQualityMode: String, CaseIterable, Identifiable, Sendable {
    case lowLatency = "低延迟"
    case highQuality = "高质量"

    var id: String { rawValue }

    var description: String {
        switch self {
        case .lowLatency:
            return "只翻译较稳定的实时片段，最终句再完整重译；兼顾速度与准确度。"
        case .highQuality:
            return "等待 SpeechTranscriber 给出最终语义单元后再翻译，准确优先。"
        }
    }
}

enum SummaryEngineChoice: String, CaseIterable, Identifiable, Sendable {
    case deepSeek = "DeepSeek"
    case zhipu = "智谱"
    case quick = "快速本地"

    var id: String { rawValue }

    var usesNetwork: Bool {
        self != .quick
    }
}

enum SummaryTemplateChoice: String, CaseIterable, Identifiable, Sendable {
    case daily = "日常"
    case meeting = "会议"

    var id: String { rawValue }
}
