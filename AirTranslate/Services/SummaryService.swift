import Foundation
import FoundationModels

struct SummaryResult: Sendable {
    let text: String
    let mode: String
}

actor SummaryService {
    private let localLLM = LocalLLMSummaryService()

    func summarize(
        _ text: String,
        engine: SummaryEngineChoice,
        onProgress: @escaping @Sendable (Double?, String) async -> Void
    ) async throws -> SummaryResult {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else {
            return SummaryResult(text: "暂无可总结内容。", mode: "本地")
        }

        switch engine {
        case .quick:
            return SummaryResult(text: fallbackSummary(clean), mode: "快速本地")
        case .localAI:
            do {
                let text = try await localLLM.summarize(clean, onProgress: onProgress)
                return SummaryResult(text: text, mode: "Qwen3 离线 AI")
            } catch {
                await onProgress(nil, "离线 AI 不可用，已切换快速本地摘要")
                return SummaryResult(
                    text: fallbackSummary(clean) + "\n\n离线 AI 加载失败：\(error.localizedDescription)",
                    mode: "快速本地兜底"
                )
            }
        case .automatic:
            let model = SystemLanguageModel.default
            if model.isAvailable {
                let session = LanguageModelSession(instructions: """
                你是一个会议与对话整理助手。请只根据输入内容，用简体中文输出：
                【核心要点】3-6条；
                【时间/数字/地点】明确出现的信息；
                【待办事项】明确行动项，没有写“无明确待办”。
                不得补充输入中不存在的事实。
                """)
                let response = try await session.respond(to: clean)
                return SummaryResult(text: response.content, mode: "Apple 本地 AI")
            }

            do {
                let text = try await localLLM.summarize(clean, onProgress: onProgress)
                return SummaryResult(text: text, mode: "Qwen3 离线 AI")
            } catch {
                await onProgress(nil, "AI 模型不可用，已使用快速本地摘要")
                return SummaryResult(text: fallbackSummary(clean), mode: "快速本地兜底")
            }
        }
    }

    private func fallbackSummary(_ text: String) -> String {
        let normalized = text.replacingOccurrences(of: "\n", with: " ")
        let separators = CharacterSet(charactersIn: "。！？!?;；")
        let sentences = normalized
            .components(separatedBy: separators)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        let keywords = ["要", "需要", "必须", "计划", "明天", "今天", "时间", "完成", "确认", "联系", "安排", "deadline", "need", "must", "tomorrow"]
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

        guard !selected.isEmpty else { return "未提取到有效内容。" }
        var output = "【核心要点】\n"
        for (index, sentence) in selected.enumerated() {
            output += "\(index + 1). \(sentence)\n"
        }
        output += "\n【时间/数字/地点】\n请结合上方原文核对明确出现的信息。"
        output += "\n\n【待办事项】\n未启用生成式模型时仅做关键句提取，请从上方要点确认行动项。"
        return output
    }
}
