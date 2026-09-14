import SwiftUI
@preconcurrency import Translation

struct ContentView: View {
    @StateObject private var model = LiveTranslateViewModel()
    @State private var forwardConfiguration: TranslationSession.Configuration?
    @State private var reverseConfiguration: TranslationSession.Configuration?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    modeCard
                    languageCard
                    if model.mode == .conversation { conversationTurnCard }
                    controlsCard
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
            Task { await model.refreshHistory() }
        }
        .onChange(of: model.sourceLanguage) { _, _ in resetTranslationConfigurations() }
        .onChange(of: model.targetLanguage) { _, _ in resetTranslationConfigurations() }
        .onChange(of: model.forwardTranslationVersion) { _, _ in forwardConfiguration?.invalidate() }
        .onChange(of: model.reverseTranslationVersion) { _, _ in reverseConfiguration?.invalidate() }
        .translationTask(forwardConfiguration) { session in
            do {
                try await session.prepareTranslation()
                while let request = model.dequeueForwardTranslation() {
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
                while let request = model.dequeueReverseTranslation() {
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
                ForEach(model.segments) { segment in
                    VStack(alignment: .leading, spacing: 6) {
                        if let speaker = segment.speaker {
                            Text(speaker == .me ? "我" : "对方")
                                .font(.caption.bold())
                                .foregroundStyle(.secondary)
                        }
                        Text(segment.sourceText)
                        if segment.translatedText.isEmpty {
                            HStack(spacing: 6) {
                                ProgressView().controlSize(.small)
                                Text("正在翻译…")
                            }
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        } else {
                            Text(segment.translatedText).fontWeight(.medium)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14))
                }

                if !model.partialTranscript.isEmpty {
                    Text(model.partialTranscript)
                        .foregroundStyle(.secondary)
                        .italic()
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
                Label("会话总结", systemImage: "sparkles").font(.headline)
                Spacer()
                if !model.summaryMode.isEmpty {
                    Text(model.summaryMode).font(.caption).foregroundStyle(.secondary)
                }
            }

            Picker("总结引擎", selection: $model.summaryEngine) {
                ForEach(SummaryEngineChoice.allCases) { engine in
                    Text(engine.rawValue).tag(engine)
                }
            }
            .pickerStyle(.segmented)

            Text(summaryEngineDescription)
                .font(.caption)
                .foregroundStyle(.secondary)

            if model.isSummarizing, let progress = model.summaryProgress, progress < 1 {
                ProgressView(value: progress)
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
        case .automatic:
            return "优先 Apple 本地 AI；不可用时自动使用 Qwen3 离线 AI。Qwen3 第一次需联网下载模型，之后可断网。"
        case .localAI:
            return "强制使用 Qwen3 0.6B 4-bit 本地模型；首次需联网下载数百 MB 模型。"
        case .quick:
            return "不下载大模型，直接在设备上做关键句提取；速度最快，但不是生成式 AI。"
        }
    }

    private var privacyCard: some View {
        VStack(alignment: .leading, spacing: 7) {
            Label("离线与隐私", systemImage: "lock.shield").font(.headline)
            Text("语音识别和系统 Translation 翻译走 Apple 设备端框架；首次使用语言需要下载资源。Qwen3 离线 AI 只在首次下载模型时联网，模型加载后总结在设备本机运行。会话记录保存到本机 Documents。")
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
