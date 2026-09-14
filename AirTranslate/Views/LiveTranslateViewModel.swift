import Foundation
import SwiftUI

@MainActor
final class LiveTranslateViewModel: ObservableObject {
    @Published var sourceLanguage: AppLanguage = .english
    @Published var targetLanguage: AppLanguage = .simplifiedChinese
    @Published var mode: TranslationMode = .listen
    @Published var activeSide: ConversationSide = .other
    @Published var isListening = false
    @Published var partialTranscript = ""
    @Published var segments: [ConversationSegment] = []
    @Published var statusMessage = "准备就绪"
    @Published var routeMessage = ""
    @Published var autoSpeakTranslation = true
    @Published var speakMyTranslationOnSpeaker = true
    @Published var preferBluetoothMic = false
    @Published var summaryText = ""
    @Published var summaryMode = ""
    @Published var summaryEngine: SummaryEngineChoice = .automatic
    @Published var isSummarizing = false
    @Published var summaryProgress: Double?
    @Published var history: [SavedConversation] = []
    @Published private(set) var forwardTranslationVersion = 0
    @Published private(set) var reverseTranslationVersion = 0

    private let captureService = SpeechCaptureService()
    private let speechOutput = SpeechOutputService()
    private let summaryService = SummaryService()
    private let store = ConversationStore()
    private var forwardQueue: [TranslationRequest] = []
    private var reverseQueue: [TranslationRequest] = []

    var currentInputLanguage: AppLanguage {
        if mode == .conversation && activeSide == .me { return targetLanguage }
        return sourceLanguage
    }

    var currentOutputLanguage: AppLanguage {
        if mode == .conversation && activeSide == .me { return sourceLanguage }
        return targetLanguage
    }

    var fullTranscriptForSummary: String {
        segments.map { segment in
            let speaker: String
            switch segment.speaker {
            case .me: speaker = "我"
            case .other: speaker = "对方"
            case .none: speaker = "原文"
            }
            if segment.translatedText.isEmpty {
                return "[\(speaker)] \(segment.sourceText)"
            }
            return "[\(speaker)] \(segment.sourceText)\n[译文] \(segment.translatedText)"
        }.joined(separator: "\n")
    }

    func toggleListening() {
        if isListening { stopListening() } else { startListening() }
    }

    func startListening() {
        guard !isListening else { return }
        Task { await startListeningTask() }
    }

    private func startListeningTask() async {
        summaryText = ""
        summaryMode = ""
        statusMessage = "正在启动设备端语音识别…"
        let inputLanguage = currentInputLanguage
        let outputLanguage = currentOutputLanguage

        do {
            try await captureService.start(
                localeIdentifier: inputLanguage.speechLocaleIdentifier,
                preferBluetoothMic: preferBluetoothMic,
                onPartial: { [weak self] text in
                    await MainActor.run { self?.partialTranscript = text }
                },
                onFinal: { [weak self] text in
                    await MainActor.run { self?.receiveFinalTranscript(text) }
                },
                onStatus: { [weak self] text in
                    await MainActor.run { self?.statusMessage = text }
                }
            )
            isListening = true
            statusMessage = "正在离线识别 · \(inputLanguage.name) → \(outputLanguage.name)"
            routeMessage = await captureService.currentRouteDescription()
        } catch {
            isListening = false
            statusMessage = error.localizedDescription
        }
    }

    func stopListening() {
        guard isListening else { return }
        isListening = false
        partialTranscript = ""
        speechOutput.stop()
        statusMessage = "已停止"
        Task { await captureService.stop() }
    }

    func switchConversationSide(_ side: ConversationSide) {
        guard mode == .conversation, side != activeSide else { return }
        let shouldResume = isListening
        isListening = false
        partialTranscript = ""
        speechOutput.stop()
        Task {
            await captureService.stop()
            activeSide = side
            statusMessage = side == .other ? "轮到对方说" : "轮到我来说"
            if shouldResume { await startListeningTask() }
        }
    }

    func swapLanguages() {
        guard !isListening else { return }
        let oldSource = sourceLanguage
        sourceLanguage = targetLanguage
        targetLanguage = oldSource
        statusMessage = "已切换语言"
    }

    func clearConversation() {
        stopListening()
        segments.removeAll()
        forwardQueue.removeAll()
        reverseQueue.removeAll()
        summaryText = ""
        summaryMode = ""
        statusMessage = "已清空"
    }

    func prepareOfflineSpeechPacks() {
        guard !isListening else { return }
        statusMessage = "正在检查离线语音支持…"
        Task {
            do {
                try await captureService.prepareLocales(
                    [sourceLanguage.speechLocaleIdentifier, targetLanguage.speechLocaleIdentifier],
                    onStatus: { [weak self] text in
                        await MainActor.run { self?.statusMessage = text }
                    }
                )
            } catch {
                statusMessage = "离线语音检查失败：\(error.localizedDescription)"
            }
        }
    }

    func dequeueForwardTranslation() -> TranslationRequest? {
        guard !forwardQueue.isEmpty else { return nil }
        return forwardQueue.removeFirst()
    }

    func dequeueReverseTranslation() -> TranslationRequest? {
        guard !reverseQueue.isEmpty else { return nil }
        return reverseQueue.removeFirst()
    }

    func completeTranslation(request: TranslationRequest, translatedText: String) {
        guard let index = segments.firstIndex(where: { $0.id == request.segmentID }) else { return }
        segments[index].translatedText = translatedText

        guard autoSpeakTranslation else { return }
        if request.direction == .reverse && mode == .conversation && speakMyTranslationOnSpeaker {
            if isListening { stopListening() }
            speechOutput.speak(
                translatedText,
                languageCode: request.targetLanguage.speechLocaleIdentifier,
                route: .speaker
            )
            statusMessage = "已外放译文；可点“对方说”继续"
        } else {
            speechOutput.speak(
                translatedText,
                languageCode: request.targetLanguage.speechLocaleIdentifier,
                route: .current
            )
        }
    }

    func translationFailed(request: TranslationRequest, error: Error) {
        if let index = segments.firstIndex(where: { $0.id == request.segmentID }) {
            segments[index].translatedText = "翻译失败：\(error.localizedDescription)"
        }
        statusMessage = "翻译失败，请确认系统翻译语言包已下载"
    }

    func summarize() {
        let text = fullTranscriptForSummary
        guard !text.isEmpty, !isSummarizing else { return }
        isSummarizing = true
        summaryText = "正在整理…"
        summaryProgress = nil

        Task {
            do {
                let result = try await summaryService.summarize(
                    text,
                    engine: summaryEngine,
                    onProgress: { [weak self] progress, message in
                        await MainActor.run {
                            self?.summaryProgress = progress
                            self?.summaryText = message
                        }
                    }
                )
                summaryText = result.text
                summaryMode = result.mode
                summaryProgress = 1
            } catch {
                summaryText = "总结失败：\(error.localizedDescription)"
                summaryMode = ""
                summaryProgress = nil
            }
            isSummarizing = false
        }
    }

    func saveConversation() {
        guard !segments.isEmpty else { return }
        let snapshot = SavedConversation(
            id: UUID(),
            createdAt: Date(),
            sourceLanguage: sourceLanguage,
            targetLanguage: targetLanguage,
            segments: segments,
            summary: summaryText.isEmpty || isSummarizing ? nil : summaryText,
            mode: mode
        )
        Task {
            do {
                try await store.append(snapshot)
                statusMessage = "已保存到本机"
                await refreshHistory()
            } catch {
                statusMessage = "保存失败：\(error.localizedDescription)"
            }
        }
    }

    func refreshHistory() async {
        do { history = try await store.load() }
        catch { history = [] }
    }

    func deleteHistory(_ id: UUID) {
        Task {
            try? await store.delete(id: id)
            await refreshHistory()
        }
    }

    var currentExportText: String {
        SavedConversation(
            id: UUID(),
            createdAt: Date(),
            sourceLanguage: sourceLanguage,
            targetLanguage: targetLanguage,
            segments: segments,
            summary: summaryText.isEmpty ? nil : summaryText,
            mode: mode
        ).exportText
    }

    private func receiveFinalTranscript(_ text: String) {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }

        let direction: TranslationDirection = (mode == .conversation && activeSide == .me) ? .reverse : .forward
        let source = direction == .forward ? sourceLanguage : targetLanguage
        let target = direction == .forward ? targetLanguage : sourceLanguage
        let speaker: ConversationSpeaker? = mode == .conversation ? (direction == .forward ? .other : .me) : nil

        let segment = ConversationSegment(
            sourceText: clean,
            speaker: speaker,
            sourceLanguage: source,
            targetLanguage: target
        )
        segments.append(segment)

        let request = TranslationRequest(
            id: UUID(),
            segmentID: segment.id,
            text: clean,
            direction: direction,
            sourceLanguage: source,
            targetLanguage: target
        )

        if direction == .forward {
            forwardQueue.append(request)
            forwardTranslationVersion += 1
        } else {
            reverseQueue.append(request)
            reverseTranslationVersion += 1
        }
    }
}
