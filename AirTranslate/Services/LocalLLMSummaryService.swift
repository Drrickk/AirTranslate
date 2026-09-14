import Foundation
import Hub
import HuggingFace
import MLXHuggingFace
import MLXLLM
import MLXLMCommon
import Tokenizers

actor LocalLLMSummaryService {
    enum LocalLLMError: LocalizedError {
        case emptyResponse

        var errorDescription: String? {
            switch self {
            case .emptyResponse: return "本地 AI 没有返回有效内容。"
            }
        }
    }

    private var modelContainer: ModelContainer?
    private let configuration = LLMRegistry.qwen3_0_6b_4bit

    func summarize(
        _ text: String,
        onProgress: @escaping @Sendable (Double?, String) async -> Void
    ) async throws -> String {
        let container = try await loadModel(onProgress: onProgress)
        await onProgress(nil, "离线 AI 正在整理…")

        let session = ChatSession(
            container,
            instructions: """
            你是一个严谨的会议与对话整理助手。只能依据输入内容总结，不得补充不存在的事实。
            输出必须使用简体中文，结构固定为：
            【核心要点】3-6条；
            【时间/数字/地点】只列明确出现的信息，没有则写“无”；
            【待办事项】列明确行动项，没有则写“无明确待办”。
            尽量简洁。
            """,
            generateParameters: GenerateParameters(maxTokens: 520, temperature: 0.2),
            additionalContext: ["enable_thinking": false]
        )

        let clipped = String(text.prefix(16_000))
        let response = try await session.respond(to: "请总结下面这段对话：\n\n\(clipped)")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !response.isEmpty else { throw LocalLLMError.emptyResponse }
        await onProgress(1.0, "离线 AI 总结完成")
        return response
    }

    private func loadModel(
        onProgress: @escaping @Sendable (Double?, String) async -> Void
    ) async throws -> ModelContainer {
        if let modelContainer { return modelContainer }

        await onProgress(0, "首次使用：正在下载 Qwen3 0.6B 离线模型…")
        let container = try await #huggingFaceLoadModelContainer(
            configuration: configuration,
            progressHandler: { progress in
                let fraction = progress.totalUnitCount > 0 ? progress.fractionCompleted : 0
                Task { await onProgress(fraction, "下载离线 AI 模型 \(Int(fraction * 100))%") }
            }
        )
        await onProgress(nil, "离线 AI 模型已加载")
        modelContainer = container
        return container
    }
}
