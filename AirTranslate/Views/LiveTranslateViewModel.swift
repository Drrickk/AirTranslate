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
    @Published var translationQuality: TranslationQualityMode = .lowLatency
    @Published var lowLatencySpeech = true
    @Published var adaptiveSpeechCatchUp = true
    @Published var speechBaseRate: Double = 0.58
    @Published var voiceOptions: [LocalVoiceOption] = []
    @Published var selectedVoiceIdentifier = ""
    @Published var summaryText = ""
    @Published var summaryMode = ""
    @Published var summaryEngine: SummaryEngineChoice = .deepSeek
    @Published var summaryTemplate: SummaryTemplateChoice = .meeting
    @Published var deepSeekAPIKey = ""
    @Published var zhipuAPIKey = ""
    @Published var deepSeekModel = "deepseek-flash"
    @Published var zhipuModel = "glm-5.3-flash"
    @Published var deepSeekEndpoint = "https://api.deepseek.com/chat/completions"
    @Published var zhipuEndpoint = "https://open.bigmodel.cn/api/paas/v4/chat/completions"
    @Published var aiSettingsStatus = ""
    @Published var isTestingAIConnection = false
    @Published var isSummarizing = false
    @Published var summaryProgress: Double?
    @Published var autoSummaryEnabled = false
    @Published var autoSummaryInterval: Double = 60
    @Published var history: [SavedConversation] = []

    let forwardTranslationPipe = TranslationRequestPipe()
    let reverseTranslationPipe = TranslationRequestPipe()

    private let captureService = SpeechCaptureService()
    private let speechOutput = SpeechOutputService()
    private let summaryService = SummaryService()
    private let store = ConversationStore()

    private var partialPreviewTask: Task<Void, Never>?
    private var speechStabilityTask: Task<Void, Never>?
    private var latestPartialRequestID: UUID?
    private var lastPreviewedText = ""
    private var forwardPreviewInFlight = false
    private var reversePreviewInFlight = false
    private var partialHistory: [String] = []
    private var spokenSourcePrefix = ""
    private var voiceSelectionLanguageID = ""
    private var voiceByLanguage: [String: String] = [:]
    private var autoSummaryTask: Task<Void, Never>?
    private var lastAutoSummaryAt: Date?
    private var lastAutoSummarySource = ""

    init() {
        if let phase = SpeechCaptureService.lastStartupPhase {
            statusMessage = "上次启动停在：\(phase)"
        }
        loadAISettings()
        refreshVoiceOptions()
    }

    var currentInputLanguage: AppLanguage {
        if mode == .conversation && activeSide == .me { return targetLanguage }
        return sourceLanguage
    }

    var currentOutputLanguage: AppLanguage {
        if mode == .conversation && activeSide == .me { return sourceLanguage }
        return targetLanguage
    }

    var usesLowLatencyTranslation: Bool {
        translationQuality == .lowLatency
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
        resetPartialState(clearVisibleText: true)
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
            statusMessage = "设备端同传 · \(inputLanguage.name) → \(outputLanguage.name)"
            routeMessage = await captureService.currentRouteDescription()
        } catch {
            isListening = false
            statusMessage = error.localizedDescription
        }
    }

    func stopListening() {
        guard isListening else { return }
        isListening = false
        resetPartialState(clearVisibleText: true)
        speechOutput.stop()
        statusMessage = "已停止"
        Task { await captureService.stop() }
    }

    func switchConversationSide(_ side: ConversationSide) {
        guard mode == .conversation, side != activeSide else { return }
        let shouldResume = isListening
        isListening = false
        resetPartialState(clearVisibleText: true)
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
        refreshVoiceOptions()
        statusMessage = "已切换语言"
    }

    func translationQualityChanged() {
        resetPartialState(clearVisibleText: false)
        if translationQuality == .highQuality {
            partialTranslation = ""
        }
    }

    func refreshVoiceOptions() {
        if !voiceSelectionLanguageID.isEmpty {
            voiceByLanguage[voiceSelectionLanguageID] = selectedVoiceIdentifier
        }

        voiceSelectionLanguageID = targetLanguage.id
        voiceOptions = speechOutput.availableVoices(languageCode: targetLanguage.speechLocaleIdentifier)
        let saved = voiceByLanguage[targetLanguage.id] ?? ""
        if saved.isEmpty || voiceOptions.contains(where: { $0.id == saved }) {
            selectedVoiceIdentifier = saved
        } else {
            selectedVoiceIdentifier = ""
        }
    }

    func clearConversation() {
        if isListening { stopListening() } else { speechOutput.stop() }
        segments.removeAll()
        resetPartialState(clearVisibleText: true)
        summaryText = ""
        summaryMode = ""
        autoSummaryTask?.cancel()
        autoSummaryTask = nil
        lastAutoSummarySource = ""
        lastAutoSummaryAt = nil
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

        switch request.purpose {
        case .preview:
            markPreviewFinished(direction: request.direction)
            if usesLowLatencyTranslation,
               latestPartialRequestID == request.id,
               partialTranscript.hasPrefix(request.text) {
                partialTranslation = cleanTranslation
            }
            scheduleAnotherPreviewIfNeeded(after: request.text)

        case .speechChunk:
            if request.speakAfterTranslation {
                speakTranslation(cleanTranslation, request: request)
            }

        case .final:
            guard let segmentID = request.segmentID,
                  let index = segments.firstIndex(where: { $0.id == segmentID }) else { return }
            segments[index].translatedText = cleanTranslation
            if request.speakAfterTranslation {
                speakTranslation(cleanTranslation, request: request)
            }
            scheduleAutoSummaryIfNeeded()
        }
    }

    func translationFailed(request: TranslationRequest, error: Error) {
        switch request.purpose {
        case .preview:
            markPreviewFinished(direction: request.direction)
            if latestPartialRequestID == request.id {
                partialTranslation = ""
            }
            scheduleAnotherPreviewIfNeeded(after: request.text)
        case .speechChunk:
            statusMessage = "低延迟朗读片段翻译失败，等待最终译文"
        case .final:
            if let segmentID = request.segmentID,
               let index = segments.firstIndex(where: { $0.id == segmentID }) {
                segments[index].translatedText = "翻译失败：\(error.localizedDescription)"
            }
            statusMessage = "翻译失败，请确认系统翻译语言包已下载"
        }
    }

    func summarize() {
        performSummary(isAutomatic: false)
    }

    private func performSummary(isAutomatic: Bool) {
        let text = fullTranscriptForSummary
        guard !text.isEmpty, !isSummarizing else { return }
        if isAutomatic {
            guard autoSummaryEnabled, summaryEngine.usesNetwork else { return }
            guard onlineSummaryConfiguration(for: summaryEngine) != nil else { return }
            guard text != lastAutoSummarySource else { return }
        }

        isSummarizing = true
        if !isAutomatic || summaryText.isEmpty {
            summaryText = "正在整理…"
        }
        summaryProgress = nil

        Task {
            do {
                let result = try await summaryService.summarize(
                    text,
                    engine: summaryEngine,
                    template: summaryTemplate,
                    configuration: onlineSummaryConfiguration(for: summaryEngine),
                    onProgress: { [weak self] progress, message in
                        await MainActor.run {
                            self?.summaryProgress = progress
                            if self?.summaryText.isEmpty == true || !isAutomatic {
                                self?.summaryText = message
                            }
                        }
                    }
                )
                summaryText = result.text
                summaryMode = isAutomatic ? "实时 · \(result.mode)" : result.mode
                summaryProgress = 1
                if isAutomatic {
                    lastAutoSummaryAt = Date()
                    lastAutoSummarySource = text
                }
            } catch {
                if !isAutomatic {
                    summaryText = "总结失败：\(error.localizedDescription)"
                    summaryMode = ""
                } else {
                    aiSettingsStatus = "实时总结失败：\(error.localizedDescription)"
                }
                summaryProgress = nil
            }
            isSummarizing = false
            if isAutomatic, fullTranscriptForSummary != lastAutoSummarySource {
                scheduleAutoSummaryIfNeeded()
            }
        }
    }

    func saveSummaryPreferences() {
        let defaults = UserDefaults.standard
        defaults.set(summaryEngine.rawValue, forKey: "ai.summary.engine")
        defaults.set(summaryTemplate.rawValue, forKey: "ai.summary.template")
        defaults.set(autoSummaryEnabled, forKey: "ai.summary.autoEnabled")
        defaults.set(autoSummaryInterval, forKey: "ai.summary.interval")
        if !autoSummaryEnabled {
            autoSummaryTask?.cancel()
            autoSummaryTask = nil
        } else {
            scheduleAutoSummaryIfNeeded()
        }
    }

    private func scheduleAutoSummaryIfNeeded() {
        guard autoSummaryEnabled, summaryEngine.usesNetwork, !segments.isEmpty else { return }
        guard onlineSummaryConfiguration(for: summaryEngine) != nil else { return }
        guard autoSummaryTask == nil else { return }

        let now = Date()
        let delaySeconds: Double
        if let lastAutoSummaryAt {
            delaySeconds = max(3, autoSummaryInterval - now.timeIntervalSince(lastAutoSummaryAt))
        } else {
            // First automatic summary appears quickly, then follows the selected refresh interval.
            delaySeconds = min(12, max(5, autoSummaryInterval / 4))
        }

        autoSummaryTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: UInt64(delaySeconds * 1_000_000_000))
            } catch {
                return
            }
            guard let self, !Task.isCancelled else { return }
            self.autoSummaryTask = nil
            self.performSummary(isAutomatic: true)
        }
    }

    func saveAISettings() {
        let defaults = UserDefaults.standard
        deepSeekModel = deepSeekModel.trimmingCharacters(in: .whitespacesAndNewlines)
        zhipuModel = zhipuModel.trimmingCharacters(in: .whitespacesAndNewlines)
        deepSeekEndpoint = deepSeekEndpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        zhipuEndpoint = zhipuEndpoint.trimmingCharacters(in: .whitespacesAndNewlines)

        defaults.set(deepSeekModel, forKey: "ai.deepseek.model")
        defaults.set(zhipuModel, forKey: "ai.zhipu.model")
        defaults.set(deepSeekEndpoint, forKey: "ai.deepseek.endpoint")
        defaults.set(zhipuEndpoint, forKey: "ai.zhipu.endpoint")
        _ = KeychainService.write(deepSeekAPIKey, account: "deepseek")
        _ = KeychainService.write(zhipuAPIKey, account: "zhipu")
        saveSummaryPreferences()
        aiSettingsStatus = "设置已保存到本机；API Key 使用钥匙串保存。"
    }

    func testAIConnection(_ engine: SummaryEngineChoice) {
        guard engine.usesNetwork, !isTestingAIConnection else { return }
        saveAISettings()
        guard let config = onlineSummaryConfiguration(for: engine) else {
            aiSettingsStatus = "请先填写 \(engine.rawValue) API Key。"
            return
        }
        isTestingAIConnection = true
        aiSettingsStatus = "正在测试 \(engine.rawValue)…"
        Task {
            do {
                let reply = try await summaryService.testConnection(configuration: config)
                aiSettingsStatus = "\(engine.rawValue) 连接正常：\(reply)"
            } catch {
                aiSettingsStatus = "\(engine.rawValue) 测试失败：\(error.localizedDescription)"
            }
            isTestingAIConnection = false
        }
    }

    private func loadAISettings() {
        let defaults = UserDefaults.standard
        deepSeekAPIKey = KeychainService.read(account: "deepseek")
        zhipuAPIKey = KeychainService.read(account: "zhipu")
        deepSeekModel = defaults.string(forKey: "ai.deepseek.model") ?? "deepseek-flash"
        zhipuModel = defaults.string(forKey: "ai.zhipu.model") ?? "glm-5.3-flash"
        deepSeekEndpoint = defaults.string(forKey: "ai.deepseek.endpoint") ?? "https://api.deepseek.com/chat/completions"
        zhipuEndpoint = defaults.string(forKey: "ai.zhipu.endpoint") ?? "https://open.bigmodel.cn/api/paas/v4/chat/completions"
        if let raw = defaults.string(forKey: "ai.summary.engine"),
           let saved = SummaryEngineChoice(rawValue: raw) {
            summaryEngine = saved
        }
        if let raw = defaults.string(forKey: "ai.summary.template"),
           let saved = SummaryTemplateChoice(rawValue: raw) {
            summaryTemplate = saved
        }
        autoSummaryEnabled = defaults.bool(forKey: "ai.summary.autoEnabled")
        let savedInterval = defaults.double(forKey: "ai.summary.interval")
        if savedInterval >= 30 { autoSummaryInterval = savedInterval }
    }

    private func onlineSummaryConfiguration(for engine: SummaryEngineChoice) -> OnlineSummaryConfiguration? {
        switch engine {
        case .deepSeek:
            guard !deepSeekAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return OnlineSummaryConfiguration(
                engine: .deepSeek,
                endpoint: deepSeekEndpoint,
                apiKey: deepSeekAPIKey,
                model: deepSeekModel
            )
        case .zhipu:
            guard !zhipuAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return OnlineSummaryConfiguration(
                engine: .zhipu,
                endpoint: zhipuEndpoint,
                apiKey: zhipuAPIKey,
                model: zhipuModel
            )
        case .quick:
            return nil
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
            resetPartialState(clearVisibleText: false)
            partialTranslation = ""
            return
        }

        partialHistory.append(clean)
        if partialHistory.count > 3 {
            partialHistory.removeFirst(partialHistory.count - 3)
        }

        guard usesLowLatencyTranslation else {
            partialTranslation = ""
            return
        }

        scheduleStablePreview()
        scheduleLowLatencySpeechIfNeeded(for: clean)
    }

    private func receiveFinalTranscript(_ text: String) {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }

        partialPreviewTask?.cancel()
        partialPreviewTask = nil
        speechStabilityTask?.cancel()
        speechStabilityTask = nil
        latestPartialRequestID = nil
        lastPreviewedText = ""
        forwardPreviewInFlight = false
        reversePreviewInFlight = false

        let direction = currentDirection
        let source = direction == .forward ? sourceLanguage : targetLanguage
        let target = direction == .forward ? targetLanguage : sourceLanguage
        let speaker: ConversationSpeaker? = mode == .conversation ? (direction == .forward ? .other : .me) : nil

        var finalShouldSpeak = autoSpeakTranslation
        if usesLowLatencyTranslation && lowLatencySpeech && autoSpeakTranslation && !spokenSourcePrefix.isEmpty {
            if clean.hasPrefix(spokenSourcePrefix) {
                let remainder = String(clean.dropFirst(spokenSourcePrefix.count))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if isUsefulSpeechChunk(remainder) {
                    sendSpeechChunk(remainder, direction: direction, source: source, target: target)
                }
            } else {
                statusMessage = "识别结果发生修正；已避免重复朗读，屏幕以最终译文为准"
            }
            finalShouldSpeak = false
        }

        let segment = ConversationSegment(
            sourceText: clean,
            speaker: speaker,
            sourceLanguage: source,
            targetLanguage: target
        )
        segments.append(segment)

        let finalRequest = TranslationRequest(
            id: UUID(),
            segmentID: segment.id,
            text: clean,
            direction: direction,
            sourceLanguage: source,
            targetLanguage: target,
            purpose: .final,
            speakAfterTranslation: finalShouldSpeak
        )
        send(finalRequest)

        partialTranscript = ""
        partialTranslation = ""
        partialHistory.removeAll()
        spokenSourcePrefix = ""
    }

    private func scheduleStablePreview(delayNanoseconds: UInt64 = 240_000_000) {
        guard usesLowLatencyTranslation, partialPreviewTask == nil else { return }
        partialPreviewTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: delayNanoseconds)
            } catch {
                return
            }
            guard let self, !Task.isCancelled else { return }
            self.partialPreviewTask = nil
            self.enqueueStablePartialPreviewIfNeeded()
        }
    }

    private func enqueueStablePartialPreviewIfNeeded() {
        guard usesLowLatencyTranslation,
              let candidate = stablePreviewCandidate(),
              candidate != lastPreviewedText else { return }

        let direction = currentDirection
        if direction == .forward, forwardPreviewInFlight { return }
        if direction == .reverse, reversePreviewInFlight { return }

        let source = direction == .forward ? sourceLanguage : targetLanguage
        let target = direction == .forward ? targetLanguage : sourceLanguage
        let request = TranslationRequest(
            id: UUID(),
            segmentID: nil,
            text: candidate,
            direction: direction,
            sourceLanguage: source,
            targetLanguage: target,
            purpose: .preview,
            speakAfterTranslation: false
        )

        lastPreviewedText = candidate
        latestPartialRequestID = request.id
        if direction == .forward { forwardPreviewInFlight = true }
        else { reversePreviewInFlight = true }
        send(request)
    }

    private func stablePreviewCandidate() -> String? {
        let current = partialTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !current.isEmpty else { return nil }

        if hasStrongEnding(current), isUsefulPreview(current) {
            return current
        }

        guard partialHistory.count >= 2 else { return nil }
        let previous = partialHistory[partialHistory.count - 2]
        var prefix = longestCommonPrefix(previous, current)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !prefix.isEmpty else { return nil }

        // For space-delimited languages, avoid translating the middle of a word.
        if usesSpaceDelimitedWords(currentInputLanguage),
           !hasStrongEnding(prefix),
           prefix.count < current.count,
           let lastSpace = prefix.lastIndex(of: " ") {
            prefix = String(prefix[..<lastSpace]).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        return isUsefulPreview(prefix) ? prefix : nil
    }

    private func scheduleLowLatencySpeechIfNeeded(for capturedText: String) {
        speechStabilityTask?.cancel()
        guard lowLatencySpeech,
              autoSpeakTranslation,
              usesLowLatencyTranslation else { return }

        let delay: UInt64 = hasStrongEnding(capturedText) ? 180_000_000 : 520_000_000
        speechStabilityTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: delay)
            } catch {
                return
            }
            guard let self, !Task.isCancelled,
                  self.partialTranscript == capturedText else { return }
            self.commitStableSpeechChunk(capturedText)
        }
    }

    private func commitStableSpeechChunk(_ capturedText: String) {
        guard capturedText.hasPrefix(spokenSourcePrefix) else { return }
        let remainder = String(capturedText.dropFirst(spokenSourcePrefix.count))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard isUsefulSpeechChunk(remainder) else { return }

        let direction = currentDirection
        let source = direction == .forward ? sourceLanguage : targetLanguage
        let target = direction == .forward ? targetLanguage : sourceLanguage

        // Mark before enqueueing so a later partial cannot enqueue the same words twice.
        spokenSourcePrefix = capturedText
        sendSpeechChunk(remainder, direction: direction, source: source, target: target)
    }

    private func sendSpeechChunk(
        _ text: String,
        direction: TranslationDirection,
        source: AppLanguage,
        target: AppLanguage
    ) {
        let request = TranslationRequest(
            id: UUID(),
            segmentID: nil,
            text: text,
            direction: direction,
            sourceLanguage: source,
            targetLanguage: target,
            purpose: .speechChunk,
            speakAfterTranslation: true
        )
        send(request)
    }

    private func send(_ request: TranslationRequest) {
        if request.direction == .forward {
            forwardTranslationPipe.send(request)
        } else {
            reverseTranslationPipe.send(request)
        }
    }

    private var currentDirection: TranslationDirection {
        (mode == .conversation && activeSide == .me) ? .reverse : .forward
    }

    private func markPreviewFinished(direction: TranslationDirection) {
        if direction == .forward { forwardPreviewInFlight = false }
        else { reversePreviewInFlight = false }
    }

    private func scheduleAnotherPreviewIfNeeded(after translatedSource: String) {
        guard usesLowLatencyTranslation,
              !partialTranscript.isEmpty,
              stablePreviewCandidate() != translatedSource else { return }
        scheduleStablePreview(delayNanoseconds: 140_000_000)
    }

    private func speakTranslation(_ text: String, request: TranslationRequest) {
        guard autoSpeakTranslation else { return }

        let selectedVoice: String?
        if request.direction == .forward,
           request.targetLanguage.id == voiceSelectionLanguageID,
           !selectedVoiceIdentifier.isEmpty {
            selectedVoice = selectedVoiceIdentifier
        } else {
            selectedVoice = nil
        }

        if request.direction == .reverse && mode == .conversation && speakMyTranslationOnSpeaker {
            if isListening { stopListening() }
            _ = speechOutput.speak(
                text,
                languageCode: request.targetLanguage.speechLocaleIdentifier,
                voiceIdentifier: selectedVoice,
                route: .speaker,
                baseRate: Float(speechBaseRate),
                adaptiveCatchUp: adaptiveSpeechCatchUp
            )
            statusMessage = "已外放译文；可点“对方说”继续"
            return
        }

        if let decision = speechOutput.speak(
            text,
            languageCode: request.targetLanguage.speechLocaleIdentifier,
            voiceIdentifier: selectedVoice,
            route: .current,
            baseRate: Float(speechBaseRate),
            adaptiveCatchUp: adaptiveSpeechCatchUp
        ), decision.resynced {
            statusMessage = "语音已追赶到最新译文 · 当前语速 \(String(format: "%.2f", decision.rate))"
        }
    }

    private func resetPartialState(clearVisibleText: Bool) {
        partialPreviewTask?.cancel()
        partialPreviewTask = nil
        speechStabilityTask?.cancel()
        speechStabilityTask = nil
        latestPartialRequestID = nil
        lastPreviewedText = ""
        forwardPreviewInFlight = false
        reversePreviewInFlight = false
        partialHistory.removeAll()
        spokenSourcePrefix = ""
        if clearVisibleText {
            partialTranscript = ""
            partialTranslation = ""
        }
    }

    private func longestCommonPrefix(_ lhs: String, _ rhs: String) -> String {
        var left = lhs.makeIterator()
        var right = rhs.makeIterator()
        var output = ""
        while let a = left.next(), let b = right.next(), a == b {
            output.append(a)
        }
        return output
    }

    private func hasStrongEnding(_ text: String) -> Bool {
        guard let last = text.trimmingCharacters(in: .whitespacesAndNewlines).last else { return false }
        return ".!?。！？；;：:".contains(last)
    }

    private func usesSpaceDelimitedWords(_ language: AppLanguage) -> Bool {
        ["en", "fr", "de", "es"].contains(language.id)
    }

    private func isUsefulPreview(_ text: String) -> Bool {
        if usesSpaceDelimitedWords(currentInputLanguage) {
            return text.split(whereSeparator: { $0.isWhitespace }).count >= 3
        }
        return text.count >= 4
    }

    private func isUsefulSpeechChunk(_ text: String) -> Bool {
        guard !text.isEmpty else { return false }
        if usesSpaceDelimitedWords(currentInputLanguage) {
            return text.split(whereSeparator: { $0.isWhitespace }).count >= 2 || hasStrongEnding(text)
        }
        return text.count >= 3 || hasStrongEnding(text)
    }
}
