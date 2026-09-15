import Foundation

struct SummaryResult: Sendable {
    let text: String
    let mode: String
}

struct OnlineSummaryConfiguration: Sendable {
    let engine: SummaryEngineChoice
    let endpoint: String
    let apiKey: String
    let model: String
}

actor SummaryService {
    enum SummaryError: LocalizedError {
        case missingAPIKey
        case invalidEndpoint
        case invalidResponse
        case emptyResponse
        case server(status: Int, message: String)

        var errorDescription: String? {
            switch self {
            case .missingAPIKey:
                return "还没有填写 API Key。"
            case .invalidEndpoint:
                return "API 地址格式不正确。"
            case .invalidResponse:
                return "AI 返回了无法解析的数据。"
            case .emptyResponse:
                return "AI 没有返回有效总结。"
            case let .server(status, message):
                return "API 请求失败（HTTP \(status)）：\(message)"
            }
        }
    }

    func summarize(
        _ text: String,
        engine: SummaryEngineChoice,
        template: SummaryTemplateChoice,
        configuration: OnlineSummaryConfiguration?,
        onProgress: @escaping @Sendable (Double?, String) async -> Void
    ) async throws -> SummaryResult {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else {
            return SummaryResult(text: "暂无可总结内容。", mode: "本地")
        }

        if engine == .quick {
            return SummaryResult(text: fallbackSummary(clean, template: template), mode: "快速本地")
        }

        guard let configuration else { throw SummaryError.missingAPIKey }
        await onProgress(nil, "正在通过 \(engine.rawValue) 整理…")
        let result = try await requestSummary(clean, template: template, configuration: configuration)
        await onProgress(1.0, "\(engine.rawValue) 总结完成")
        return SummaryResult(text: result, mode: "\(engine.rawValue) · \(configuration.model)")
    }

    func testConnection(configuration: OnlineSummaryConfiguration) async throws -> String {
        let result = try await chatCompletion(
            systemPrompt: "你是 API 连通性测试助手。",
            userPrompt: "只回复两个字：正常",
            configuration: configuration,
            maxTokens: 32
        )
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func requestSummary(
        _ text: String,
        template: SummaryTemplateChoice,
        configuration: OnlineSummaryConfiguration
    ) async throws -> String {
        let clipped = String(text.prefix(40_000))
        let systemPrompt = prompt(for: template)
        let userPrompt = """
        请只依据下面的最终转写与译文进行总结。不要猜测、不要补齐没有出现的信息；如果信息不足，请明确写“信息不足”或“无明确内容”。

        【转写内容】
        \(clipped)
        """
        return try await chatCompletion(
            systemPrompt: systemPrompt,
            userPrompt: userPrompt,
            configuration: configuration,
            maxTokens: template == .meeting ? 1400 : 1000
        )
    }

    private func prompt(for template: SummaryTemplateChoice) -> String {
        switch template {
        case .daily:
            return """
            你是一个严谨的对话整理助手。请用简体中文，结构固定为：
            【核心要点】3-6条；
            【重要信息】只列明确出现的人名、时间、地点、数字、产品或事件；没有写“无”；
            【待办事项】只列明确行动项；没有写“无明确待办”；
            【问题与风险】只列明确提出的问题、疑问或风险；没有写“无明确问题”。
            内容非常少、含义不清或只是测试语句时，不要强行总结，直接说明信息不足。
            """
        case .meeting:
            return """
            你是一个严谨的会议纪要助手。只能依据输入内容，不得补充或推断没有出现的事实。请用简体中文，结构固定为：
            【会议摘要】用2-4句概括讨论主题；
            【核心结论】列明确达成的决定或结论，没有写“无明确结论”；
            【待办事项】逐条列任务；只有原文明确出现时才写责任人、时间节点；
            【问题与风险】列明确问题、分歧、风险或待确认事项；
            【关键时间/数字】只列原文明确出现的信息，没有写“无”。
            若素材不足以形成会议结论，必须明确写“信息不足”，不要脑补。
            """
        }
    }

    private struct ChatMessage: Encodable {
        let role: String
        let content: String
    }

    private struct Thinking: Encodable {
        let type: String
    }

    private struct ChatRequest: Encodable {
        let model: String
        let messages: [ChatMessage]
        let temperature: Double
        let max_tokens: Int
        let stream: Bool
        let thinking: Thinking?
    }

    private struct ChatResponse: Decodable {
        struct Choice: Decodable {
            struct Message: Decodable {
                let content: String?
            }
            let message: Message
        }
        let choices: [Choice]
    }

    private struct ErrorEnvelope: Decodable {
        struct APIError: Decodable { let message: String? }
        let error: APIError?
        let message: String?
        let msg: String?
    }

    private func chatCompletion(
        systemPrompt: String,
        userPrompt: String,
        configuration: OnlineSummaryConfiguration,
        maxTokens: Int
    ) async throws -> String {
        let apiKey = configuration.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !apiKey.isEmpty else { throw SummaryError.missingAPIKey }
        guard let url = URL(string: configuration.endpoint),
              let scheme = url.scheme?.lowercased(),
              scheme == "https" else { throw SummaryError.invalidEndpoint }

        let body = ChatRequest(
            model: configuration.model.trimmingCharacters(in: .whitespacesAndNewlines),
            messages: [
                ChatMessage(role: "system", content: systemPrompt),
                ChatMessage(role: "user", content: userPrompt)
            ],
            temperature: 0.2,
            max_tokens: maxTokens,
            stream: false,
            thinking: Thinking(type: "disabled")
        )

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 75
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw SummaryError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            let envelope = try? JSONDecoder().decode(ErrorEnvelope.self, from: data)
            let raw = String(data: data, encoding: .utf8) ?? "未知错误"
            let message = envelope?.error?.message ?? envelope?.message ?? envelope?.msg ?? String(raw.prefix(500))
            throw SummaryError.server(status: http.statusCode, message: message)
        }

        let decoded = try JSONDecoder().decode(ChatResponse.self, from: data)
        guard let content = decoded.choices.first?.message.content?.trimmingCharacters(in: .whitespacesAndNewlines),
              !content.isEmpty else { throw SummaryError.emptyResponse }
        return content
    }

    private func fallbackSummary(_ text: String, template: SummaryTemplateChoice) -> String {
        let normalized = text.replacingOccurrences(of: "\n", with: " ")
        let separators = CharacterSet(charactersIn: "。！？!?;；")
        let sentences = normalized
            .components(separatedBy: separators)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        let keywords = ["要", "需要", "必须", "计划", "明天", "今天", "时间", "完成", "确认", "联系", "安排", "风险", "问题", "deadline", "need", "must", "tomorrow"]
        let scored = sentences.enumerated().map { index, sentence -> (Int, Int, String) in
            var score = min(sentence.count / 18, 4)
            for keyword in keywords where sentence.localizedCaseInsensitiveContains(keyword) { score += 3 }
            if sentence.range(of: #"\d"#, options: .regularExpression) != nil { score += 2 }
            return (score, -index, sentence)
        }
        let selected = scored.sorted { lhs, rhs in
            if lhs.0 == rhs.0 { return lhs.1 > rhs.1 }
            return lhs.0 > rhs.0
        }.prefix(6).map(\.2)

        guard !selected.isEmpty else { return "信息不足，未提取到有效内容。" }
        var output = template == .meeting ? "【会议摘要】\n" : "【核心要点】\n"
        for (index, sentence) in selected.enumerated() {
            output += "\(index + 1). \(sentence)\n"
        }
        if template == .meeting {
            output += "\n【核心结论】\n快速本地模式不推断结论，请核对原文。"
        }
        output += "\n\n【待办事项】\n快速本地模式仅提取关键句，请从上方内容确认明确行动项。"
        output += "\n\n【问题与风险】\n快速本地模式不做生成式判断。"
        return output
    }
}
