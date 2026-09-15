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
    @Published var partialTranslation = ""
    @Published var segments: [ConversationSegment] = []
    @Published var statusMessage = "准备就绪"
    @Published var routeMessage = ""
    @Published var autoSpeakTranslation = true
    @Published var speakMyTranslationOnSpeaker = true
    @Published var preferBluetoothMic = false
    @Published var lowLatencyTranslation = true
    @Published var adaptiveSpeechCatchUp = true
    @Published var speechBaseRate: Double = 0.58
    @Published var summaryText = ""
    @Published var summaryMode = ""
    @Published var summaryEngine: SummaryEngineChoice = .automatic
    @Published var isSummarizing = false
    @Published var summaryProgress: Double?
    @Published var history: [SavedConversation] = []

    let forwardTranslationPipe = TranslationRequestPipe()
    let reverseTranslationPipe = TranslationRequestPipe()

    private let captureService = SpeechCaptureService()
    private let speechOutput = SpeechOutputService()
    private let summaryService = SummaryService()
    private let store = ConversationStore()

    private var partialThrottleTask: Task<Void, Never>?
    private var latestPartialRequestID: UUID?
    private var lastPreviewedText = ""
    private var forwardPreviewInFlight = false
    private var reversePreviewInFlight = false

    init() {
        if let phase = SpeechCaptureService.lastStartupPhase {
            statusMessage = "上次启动停在：\(phase)"
        }
    }

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
        partialTranslation = ""
        statusMessage = "正在启动设备端语音识别…"
        let inputLanguage = currentInputLanguage
        let outputLanguage = currentOutputLanguage

        do {
            try await captureService.start(
                localeIdentifier: inputLanguage.speechLocaleIdentifier,
                preferBluetoothMic: preferBluetoothMic,
                onPartial: { [weak self] text in
                    await MainActor.run { self?.receivePartialTranscript(text) }
                },
                onFinal: { [weak self] text in
                    await MainActor.run { self?.receiveFinalTranscript(text) }
                },
                onStatus: { [weak self] text in
                    await MainActor.run { self?.statusMessage = text }
                }
            )
            isListening = true
            statusMessage = "低延迟离线同传 · \(inputLanguage.name) → \(outputLanguage.name)"
            routeMessage = await captureService.currentRouteDescription()
        } catch {
            isListening = false
            statusMessage = error.localizedDescription
        }
    }

    func stopListening() {
        guard isListening else { return }
        isListening = false
        cancelPartialPreview()
        partialTranscript = ""
        partialTranslation = ""
        speechOutput.stop()
        statusMessage = "已停止"
        Task { await captureService.stop() }
    }

    func switchConversationSide(_ side: ConversationSide) {
        guard mode == .conversation, side != activeSide else { return }
        let shouldResume = isListening
        isListening = false
        cancelPartialPreview()
        partialTranscript = ""
        partialTranslation = ""
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
        partialTranslation = ""
        statusMessage = "已切换语言"
    }

    func clearConversation() {
        stopListening()
        segments.removeAll()
        cancelPartialPreview()
        partialTranscript = ""
        partialTranslation = ""
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

    func completeTranslation(request: TranslationRequest, translatedText: String) {
        let cleanTranslation = translatedText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanTranslation.isEmpty else { return }

        if request.purpose == .preview {
            markPreviewFinished(direction: request.direction)
            if lowLatencyTranslation,
               latestPartialRequestID == request.id,
               request.text == partialTranscript {
                partialTranslation = cleanTranslation
            }
            scheduleAnotherPreviewIfNeeded(after: request.text)
            return
        }

        guard let segmentID = request.segmentID,
              let index = segments.firstIndex(where: { $0.id == segmentID }) else { return }
        segments[index].translatedText = cleanTranslation

        guard autoSpeakTranslation else { return }
        if request.direction == .reverse && mode == .conversation && speakMyTranslationOnSpeaker {
            if isListening { stopListening() }
            _ = speechOutput.speak(
                cleanTranslation,
                languageCode: request.targetLanguage.speechLocaleIdentifier,
                route: .speaker,
                baseRate: Float(speechBaseRate),
                adaptiveCatchUp: adaptiveSpeechCatchUp
            )
            statusMessage = "已外放译文；可点“对方说”继续"
        } else {
            if let decision = speechOutput.speak(
                cleanTranslation,
                languageCode: request.targetLanguage.speechLocaleIdentifier,
                route: .current,
                baseRate: Float(speechBaseRate),
                adaptiveCatchUp: adaptiveSpeechCatchUp
            ), decision.resynced {
                statusMessage = "语音已追赶到最新译文 · 当前语速 \(String(format: "%.2f", decision.rate))"
            }
        }
    }

    func translationFailed(request: TranslationRequest, error: Error) {
        if request.purpose == .preview {
            markPreviewFinished(direction: request.direction)
            if latestPartialRequestID == request.id {
                partialTranslation = ""
            }
            scheduleAnotherPreviewIfNeeded(after: request.text)
            return
        }

        if let segmentID = request.segmentID,
           let index = segments.firstIndex(where: { $0.id == segmentID }) {
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

    private func receivePartialTranscript(_ text: String) {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        partialTranscript = clean

        guard !clean.isEmpty else {
            cancelPartialPreview()
            partialTranslation = ""
            return
        }

        guard lowLatencyTranslation else {
            partialTranslation = ""
            return
        }

        // Throttle rather than debounce: keep translating during continuous speech,
        // but coalesce many SpeechTranscriber partial updates into roughly one
        // request every 300 ms. At most one preview per direction may be in flight,
        // so preview work can never build an unbounded queue in front of a final sentence.
        schedulePartialPreview()
    }

    private func enqueueLatestPartialPreviewIfNeeded() {
        let clean = partialTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard lowLatencyTranslation,
              clean.count >= 3,
              clean != lastPreviewedText else { return }

        let direction: TranslationDirection = (mode == .conversation && activeSide == .me) ? .reverse : .forward
        if direction == .forward, forwardPreviewInFlight { return }
        if direction == .reverse, reversePreviewInFlight { return }
        lastPreviewedText = clean

        let source = direction == .forward ? sourceLanguage : targetLanguage
        let target = direction == .forward ? targetLanguage : sourceLanguage
        let request = TranslationRequest(
            id: UUID(),
            segmentID: nil,
            text: clean,
            direction: direction,
            sourceLanguage: source,
            targetLanguage: target,
            purpose: .preview
        )
        latestPartialRequestID = request.id

        if direction == .forward {
            forwardPreviewInFlight = true
            forwardTranslationPipe.send(request)
        } else {
            reversePreviewInFlight = true
            reverseTranslationPipe.send(request)
        }
    }

    private func receiveFinalTranscript(_ text: String) {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }

        cancelPartialPreview()
        partialTranscript = ""
        partialTranslation = ""
        lastPreviewedText = ""

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
            targetLanguage: target,
            purpose: .final
        )

        if direction == .forward {
            forwardTranslationPipe.send(request)
        } else {
            reverseTranslationPipe.send(request)
        }
    }

    private func schedulePartialPreview(delayNanoseconds: UInt64 = 300_000_000) {
        guard lowLatencyTranslation, partialThrottleTask == nil else { return }
        partialThrottleTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: delayNanoseconds)
            } catch {
                return
            }
            guard let self, !Task.isCancelled else { return }
            self.partialThrottleTask = nil
            self.enqueueLatestPartialPreviewIfNeeded()
        }
    }

    private func markPreviewFinished(direction: TranslationDirection) {
        if direction == .forward {
            forwardPreviewInFlight = false
        } else {
            reversePreviewInFlight = false
        }
    }

    private func scheduleAnotherPreviewIfNeeded(after translatedSource: String) {
        guard lowLatencyTranslation,
              !partialTranscript.isEmpty,
              partialTranscript != translatedSource else { return }
        // A short follow-up delay catches the newest accumulated partial without
        // hammering TranslationSession while it is still busy.
        schedulePartialPreview(delayNanoseconds: 120_000_000)
    }

    private func cancelPartialPreview() {
        partialThrottleTask?.cancel()
        partialThrottleTask = nil
        latestPartialRequestID = nil
        lastPreviewedText = ""
    }
}
