import Foundation
import SwiftUI
@preconcurrency import Translation

struct ContentView: View {
    @StateObject private var model = LiveTranslateViewModel()
    @State private var forwardConfiguration: TranslationSession.Configuration?
    @State private var reverseConfiguration: TranslationSession.Configuration?
    @State private var showingAISettings = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    modeCard
                    languageCard
                    if model.mode == .conversation { conversationTurnCard }
                    controlsCard
                    translationQualityCard
                    transcriptCard
                    summaryCard
                    privacyCard
                }
                .padding()
            }
            .navigationTitle("离线同传")
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    NavigationLink {
                        HistoryView(model: model)
                    } label: {
                        Image(systemName: "clock.arrow.circlepath")
                    }

                    Menu {
                        Button("检查离线语音并准备翻译包", systemImage: "arrow.down.circle") {
                            model.prepareOfflineSpeechPacks()
                            forwardConfiguration?.invalidate()
                            reverseConfiguration?.invalidate()
                        }
                        Button("保存本次记录", systemImage: "square.and.arrow.down") {
                            model.saveConversation()
                        }
                        if !model.segments.isEmpty {
                            ShareLink(item: model.currentExportText) {
                                Label("分享/导出文字", systemImage: "square.and.arrow.up")
                            }
                        }
                        Button("清空", systemImage: "trash", role: .destructive) {
                            model.clearConversation()
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
        }
        .onAppear {
            resetTranslationConfigurations()
            model.refreshVoiceOptions()
            Task { await model.refreshHistory() }
        }
        .onChange(of: model.sourceLanguage) { _, _ in
            resetTranslationConfigurations()
        }
        .onChange(of: model.targetLanguage) { _, _ in
            resetTranslationConfigurations()
            model.refreshVoiceOptions()
        }
        .onChange(of: model.translationQuality) { _, _ in
            model.translationQualityChanged()
        }
        .sheet(isPresented: $showingAISettings) {
            AISummarySettingsView(model: model)
        }
        .translationTask(forwardConfiguration) { session in
            do {
                try await session.prepareTranslation()
                for await request in model.forwardTranslationPipe.stream {
                    if Task.isCancelled { break }
                    do {
                        let response = try await session.translate(request.text)
                        model.completeTranslation(request: request, translatedText: response.targetText)
                    } catch {
                        model.translationFailed(request: request, error: error)
                    }
                }
            } catch {
                model.statusMessage = "翻译语言包准备失败：\(error.localizedDescription)"
            }
        }
        .translationTask(reverseConfiguration) { session in
            do {
                try await session.prepareTranslation()
                for await request in model.reverseTranslationPipe.stream {
                    if Task.isCancelled { break }
                    do {
                        let response = try await session.translate(request.text)
                        model.completeTranslation(request: request, translatedText: response.targetText)
                    } catch {
                        model.translationFailed(request: request, error: error)
                    }
                }
            } catch {
                model.statusMessage = "反向翻译语言包准备失败：\(error.localizedDescription)"
            }
        }
    }

    private var modeCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("使用模式", systemImage: "person.2.wave.2")
                .font(.headline)
            Picker("模式", selection: $model.mode) {
                ForEach(TranslationMode.allCases) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .disabled(model.isListening)

            Text(model.mode == .listen
                 ? "对方讲话 → iPhone 收音 → 本地翻译 → AirPods 听译文。"
                 : "对方说外语时你在 AirPods 听中文；你说中文时可把外语译文从 iPhone 外放给对方。")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .cardStyle()
    }

    private var languageCard: some View {
        VStack(spacing: 12) {
            HStack(spacing: 8) {
                languagePicker(title: model.mode == .conversation ? "对方语言" : "听到", selection: $model.sourceLanguage)
                Button {
                    model.swapLanguages()
                    resetTranslationConfigurations()
                } label: {
                    Image(systemName: "arrow.left.arrow.right")
                        .font(.title3)
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.bordered)
                .disabled(model.isListening)
                languagePicker(title: model.mode == .conversation ? "我的语言" : "翻译成", selection: $model.targetLanguage)
            }
        }
        .cardStyle()
    }

    private func languagePicker(title: String, selection: Binding<AppLanguage>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Picker(title, selection: selection) {
                ForEach(AppLanguage.all) { language in
                    Text(language.name).tag(language)
                }
            }
            .pickerStyle(.menu)
            .disabled(model.isListening)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var conversationTurnCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("现在谁说话？", systemImage: "arrow.triangle.2.circlepath")
                .font(.headline)
            HStack {
                turnButton(.other, icon: "person.wave.2")
                turnButton(.me, icon: "person.fill")
            }
            Text(model.activeSide == .other
                 ? "当前识别 \(model.sourceLanguage.name)，翻译为 \(model.targetLanguage.name) 并优先读到耳机。"
                 : "当前识别 \(model.targetLanguage.name)，翻译为 \(model.sourceLanguage.name)。开启外放时会自动停止收音，避免把机器朗读再次识别进去。")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .cardStyle()
    }

    @ViewBuilder
    private func turnButton(_ side: ConversationSide, icon: String) -> some View {
        if model.activeSide == side {
            Button {
                model.switchConversationSide(side)
            } label: {
                Label(side.rawValue, systemImage: icon)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
        } else {
            Button {
                model.switchConversationSide(side)
            } label: {
                Label(side.rawValue, systemImage: icon)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
        }
    }

    private var controlsCard: some View {
        VStack(spacing: 14) {
            Button {
                model.toggleListening()
            } label: {
                HStack {
                    Image(systemName: model.isListening ? "stop.fill" : "waveform")
                    Text(model.isListening ? "停止" : (model.mode == .conversation ? "开始当前回合" : "开始同传"))
                        .fontWeight(.semibold)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)

            Toggle("自动朗读译文", isOn: $model.autoSpeakTranslation)
            if model.autoSpeakTranslation {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("目标语言声音")
                        Spacer()
                        Picker("目标语言声音", selection: $model.selectedVoiceIdentifier) {
                            Text("系统默认").tag("")
                            ForEach(model.voiceOptions) { voice in
                                Text("\(voice.name) · \(voice.language)").tag(voice.id)
                            }
                        }
                        .pickerStyle(.menu)
                    }

                    HStack {
                        Text("基础朗读速度")
                        Spacer()
                        Text(String(format: "%.2f", model.speechBaseRate))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    Slider(value: $model.speechBaseRate, in: 0.50...0.65, step: 0.01)
                    Toggle("语音自动追赶，避免越听越落后", isOn: $model.adaptiveSpeechCatchUp)
                }
            }

            if model.mode == .conversation {
                Toggle("我说中文后，把外语译文从 iPhone 外放", isOn: $model.speakMyTranslationOnSpeaker)
                    .disabled(!model.autoSpeakTranslation)
            }
            Toggle("优先使用 AirPods 麦克风", isOn: $model.preferBluetoothMic)
                .disabled(model.isListening)

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Circle()
                        .fill(model.isListening ? Color.green : Color.secondary)
                        .frame(width: 8, height: 8)
                    Text(model.statusMessage).font(.footnote).foregroundStyle(.secondary)
                    Spacer()
                }
                if !model.routeMessage.isEmpty {
                    Text(model.routeMessage)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .cardStyle()
    }

    private var translationQualityCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("翻译质量", systemImage: "character.book.closed")
                .font(.headline)

            Picker("翻译质量", selection: $model.translationQuality) {
                ForEach(TranslationQualityMode.allCases) { quality in
                    Text(quality.rawValue).tag(quality)
                }
            }
            .pickerStyle(.segmented)

            Text(model.translationQuality.description)
                .font(.footnote)
                .foregroundStyle(.secondary)

            if model.translationQuality == .lowLatency {
                Toggle("低延迟朗读", isOn: $model.lowLatencySpeech)
                    .disabled(!model.autoSpeakTranslation)
                Text("短暂停顿或稳定分句后即可提前翻译并朗读；最终句仍会完整重译用于字幕。若识别后续发生修正，会优先避免重复播报。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .cardStyle()
    }

    private var transcriptCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("实时字幕", systemImage: "captions.bubble").font(.headline)
                Spacer()
                Text("\(model.segments.count) 段").font(.caption).foregroundStyle(.secondary)
            }

            if model.segments.isEmpty && model.partialTranscript.isEmpty {
                ContentUnavailableView(
                    "还没有内容",
                    systemImage: "waveform",
                    description: Text("默认建议 iPhone 放桌面收音、AirPods 只负责听译文。")
                )
                .frame(minHeight: 160)
            } else {
                ForEach(Array(model.segments.enumerated()), id: \.element.id) { index, segment in
                    VStack(alignment: .leading, spacing: 7) {
                        HStack {
                            if segment.translatedText.isEmpty {
                                Label("翻译中", systemImage: "ellipsis.circle")
                                    .font(.caption.bold())
                                    .foregroundStyle(.secondary)
                            } else {
                                Label("已完成", systemImage: "checkmark.circle.fill")
                                    .font(.caption.bold())
                                    .foregroundStyle(.green)
                            }
                            Spacer()
                            Text("#\(index + 1)")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }

                        if let speaker = segment.speaker {
                            Text(speaker == .me ? "我" : "对方")
                                .font(.caption.bold())
                                .foregroundStyle(.secondary)
                        }
                        Text(segment.sourceText)
                            .foregroundStyle(.secondary)
                        if segment.translatedText.isEmpty {
                            HStack(spacing: 6) {
                                ProgressView().controlSize(.small)
                                Text("正在生成最终译文…")
                            }
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        } else {
                            Text(segment.translatedText)
                                .font(.title3.weight(.semibold))
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14))
                }

                if !model.partialTranscript.isEmpty {
                    VStack(alignment: .leading, spacing: 7) {
                        HStack {
                            Label("正在听", systemImage: "waveform")
                                .font(.caption.bold())
                                .foregroundStyle(.cyan)
                            Spacer()
                            if model.translationQuality == .lowLatency {
                                Text("稳定片段预览")
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        Text(model.partialTranscript)
                            .foregroundStyle(.secondary)
                            .italic()
                        if !model.partialTranslation.isEmpty {
                            Text(model.partialTranslation)
                                .fontWeight(.medium)
                        } else if model.translationQuality == .lowLatency {
                            HStack(spacing: 6) {
                                ProgressView().controlSize(.small)
                                Text("等待稳定片段…")
                            }
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
                }
            }
        }
        .cardStyle()
    }

    private var summaryCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("AI 总结", systemImage: "sparkles").font(.headline)
                Spacer()
                if !model.summaryMode.isEmpty {
                    Text(model.summaryMode).font(.caption).foregroundStyle(.secondary)
                }
            }

            Picker("服务商", selection: $model.summaryEngine) {
                ForEach(SummaryEngineChoice.allCases) { engine in
                    Text(engine.rawValue).tag(engine)
                }
            }
            .pickerStyle(.segmented)
            .onChange(of: model.summaryEngine) { _, _ in
                model.saveSummaryPreferences()
            }

            Picker("总结模板", selection: $model.summaryTemplate) {
                ForEach(SummaryTemplateChoice.allCases) { template in
                    Text(template.rawValue).tag(template)
                }
            }
            .pickerStyle(.segmented)
            .onChange(of: model.summaryTemplate) { _, _ in
                model.saveSummaryPreferences()
            }

            if model.summaryEngine.usesNetwork {
                Toggle("实时刷新总结", isOn: $model.autoSummaryEnabled)
                    .onChange(of: model.autoSummaryEnabled) { _, _ in
                        model.saveSummaryPreferences()
                    }

                if model.autoSummaryEnabled {
                    HStack {
                        Text("刷新间隔")
                        Spacer()
                        Picker("刷新间隔", selection: $model.autoSummaryInterval) {
                            Text("30 秒").tag(30.0)
                            Text("1 分钟").tag(60.0)
                            Text("2 分钟").tag(120.0)
                            Text("3 分钟").tag(180.0)
                        }
                        .labelsHidden()
                        .onChange(of: model.autoSummaryInterval) { _, _ in
                            model.saveSummaryPreferences()
                        }
                    }
                    Text("只在有新的最终转写/译文时刷新；不会上传原始音频。首次总结会较快生成，之后按所选间隔更新。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            HStack {
                Text(summaryEngineDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                if model.summaryEngine.usesNetwork {
                    Button("API 设置") { showingAISettings = true }
                        .font(.caption)
                        .buttonStyle(.bordered)
                }
            }

            if model.isSummarizing {
                if let progress = model.summaryProgress, progress < 1 {
                    ProgressView(value: progress)
                } else {
                    ProgressView()
                }
            }

            if !model.summaryText.isEmpty {
                Text(model.summaryText)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Button {
                model.summarize()
            } label: {
                Label("生成总结", systemImage: "text.badge.checkmark")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .disabled(model.segments.isEmpty || model.isSummarizing)
        }
        .cardStyle()
    }

    private var summaryEngineDescription: String {
        switch model.summaryEngine {
        case .deepSeek:
            return "联网调用 DeepSeek，只上传最终转写/译文文本；默认 deepseek-flash。"
        case .zhipu:
            return "联网调用智谱 GLM，只上传最终转写/译文文本；默认 glm-5.3-flash。"
        case .quick:
            return "完全本地关键句提取，不调用联网 AI，速度最快但总结能力较弱。"
        }
    }

    private var privacyCard: some View {
        VStack(alignment: .leading, spacing: 7) {
            Label("离线与隐私", systemImage: "lock.shield").font(.headline)
            Text("实时语音识别与 Translation 翻译继续使用 Apple 设备端框架，本机语音由 AVSpeechSynthesizer 朗读。选择 DeepSeek/智谱总结时只上传最终转写与译文文本，不上传原始音频；API Key 使用 iOS 钥匙串保存。会话记录保存到本机 Documents。")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .cardStyle()
    }

    private func resetTranslationConfigurations() {
        forwardConfiguration = TranslationSession.Configuration(
            source: Locale.Language(identifier: model.sourceLanguage.translationIdentifier),
            target: Locale.Language(identifier: model.targetLanguage.translationIdentifier)
        )
        reverseConfiguration = TranslationSession.Configuration(
            source: Locale.Language(identifier: model.targetLanguage.translationIdentifier),
            target: Locale.Language(identifier: model.sourceLanguage.translationIdentifier)
        )
    }
}

private extension View {
    func cardStyle() -> some View {
        self
            .padding(16)
            .frame(maxWidth: .infinity)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }
}
