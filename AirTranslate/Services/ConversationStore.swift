import Foundation

struct SavedConversation: Identifiable, Codable, Sendable {
    let id: UUID
    let createdAt: Date
    let sourceLanguage: AppLanguage
    let targetLanguage: AppLanguage
    let segments: [ConversationSegment]
    let summary: String?
    let mode: TranslationMode?

    init(
        id: UUID,
        createdAt: Date,
        sourceLanguage: AppLanguage,
        targetLanguage: AppLanguage,
        segments: [ConversationSegment],
        summary: String?,
        mode: TranslationMode? = nil
    ) {
        self.id = id
        self.createdAt = createdAt
        self.sourceLanguage = sourceLanguage
        self.targetLanguage = targetLanguage
        self.segments = segments
        self.summary = summary
        self.mode = mode
    }

    var exportText: String {
        var lines: [String] = []
        lines.append("离线同传记录")
        lines.append("时间：\(createdAt.formatted(date: .numeric, time: .shortened))")
        lines.append("语言：\(sourceLanguage.name) ↔︎ \(targetLanguage.name)")
        lines.append("")

        for segment in segments {
            let speakerText: String
            switch segment.speaker {
            case .me: speakerText = "我"
            case .other: speakerText = "对方"
            case .none: speakerText = "原文"
            }
            lines.append("[\(speakerText)] \(segment.sourceText)")
            if !segment.translatedText.isEmpty {
                lines.append("→ \(segment.translatedText)")
            }
            lines.append("")
        }

        if let summary, !summary.isEmpty {
            lines.append("—— 总结 ——")
            lines.append(summary)
        }
        return lines.joined(separator: "\n")
    }
}

actor ConversationStore {
    private let fileURL: URL

    init() {
        let base = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        fileURL = base.appendingPathComponent("airtranslate-history.json")
    }

    func append(_ conversation: SavedConversation) throws {
        var all = (try? load()) ?? []
        all.insert(conversation, at: 0)
        if all.count > 100 { all = Array(all.prefix(100)) }
        try save(all)
    }

    func load() throws -> [SavedConversation] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        let data = try Data(contentsOf: fileURL)
        return try JSONDecoder().decode([SavedConversation].self, from: data)
    }

    func delete(id: UUID) throws {
        var all = (try? load()) ?? []
        all.removeAll { $0.id == id }
        try save(all)
    }

    func deleteAll() throws {
        try save([])
    }

    private func save(_ conversations: [SavedConversation]) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted]
        let data = try encoder.encode(conversations)
        try data.write(to: fileURL, options: .atomic)
    }
}
