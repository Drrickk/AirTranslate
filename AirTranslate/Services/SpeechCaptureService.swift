import AVFoundation
import Speech

actor SpeechCaptureService {
    enum ServiceError: LocalizedError {
        case microphoneDenied
        case noAudioDevice
        case unsupportedLocale(String)
        case failedToStart

        var errorDescription: String? {
            switch self {
            case .microphoneDenied: return "没有麦克风权限，请到系统设置中允许访问。"
            case .noAudioDevice: return "没有找到可用的音频输入设备。"
            case .unsupportedLocale(let locale): return "当前设备不支持 \(locale) 的新一代离线语音识别。"
            case .failedToStart: return "无法启动语音识别。"
            }
        }
    }

    private var analyzer: SpeechAnalyzer?
    private var transcriber: SpeechTranscriber?
    private var provider: CaptureInputSequenceProvider?
    private var recognitionTask: Task<Void, Never>?
    private var analysisTask: Task<Void, Never>?

    func start(
        localeIdentifier: String,
        preferBluetoothMic: Bool,
        onPartial: @escaping @Sendable (String) async -> Void,
        onFinal: @escaping @Sendable (String) async -> Void,
        onStatus: @escaping @Sendable (String) async -> Void
    ) async throws {
        await stop()

        let granted = await requestMicrophonePermission()
        guard granted else { throw ServiceError.microphoneDenied }

        try configureAudioSession(preferBluetoothMic: preferBluetoothMic)

        let requestedLocale = Locale(identifier: localeIdentifier)
        guard let supportedLocale = SpeechTranscriber.supportedLocale(equivalentTo: requestedLocale) else {
            throw ServiceError.unsupportedLocale(localeIdentifier)
        }

        let transcriber = SpeechTranscriber(locale: supportedLocale, preset: .progressiveLiveTranscription)
        self.transcriber = transcriber

        if let installationRequest = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            await onStatus("正在下载 \(localeIdentifier) 离线语音模型…")
            try await installationRequest.downloadAndInstall()
        }

        guard let audioDevice = AVCaptureDevice.default(for: .audio) else {
            throw ServiceError.noAudioDevice
        }

        let provider = try await CaptureInputSequenceProvider.providerWithSession(
            from: audioDevice,
            compatibleWith: [transcriber]
        )
        self.provider = provider

        let analyzer = SpeechAnalyzer(modules: [transcriber])
        self.analyzer = analyzer

        recognitionTask = Task {
            do {
                for try await result in transcriber.results {
                    let text = String(result.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !text.isEmpty else { continue }
                    if result.isFinal {
                        await onPartial("")
                        await onFinal(text)
                    } else {
                        await onPartial(text)
                    }
                }
            } catch {
                if !Task.isCancelled {
                    await onStatus("语音识别结束：\(error.localizedDescription)")
                }
            }
        }

        provider.captureSession.startRunning()
        analysisTask = Task {
            do {
                _ = try await analyzer.analyzeSequence(provider.analyzerInputs)
            } catch {
                if !Task.isCancelled {
                    await onStatus("音频分析结束：\(error.localizedDescription)")
                }
            }
        }

        await onStatus("正在离线识别")
    }

    func prepareLocales(
        _ localeIdentifiers: [String],
        onStatus: @escaping @Sendable (String) async -> Void
    ) async throws {
        for localeIdentifier in Array(Set(localeIdentifiers)) {
            let requestedLocale = Locale(identifier: localeIdentifier)
            guard let supportedLocale = SpeechTranscriber.supportedLocale(equivalentTo: requestedLocale) else {
                throw ServiceError.unsupportedLocale(localeIdentifier)
            }
            let transcriber = SpeechTranscriber(locale: supportedLocale, preset: .progressiveLiveTranscription)
            if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                await onStatus("正在准备 \(localeIdentifier) 语音离线包…")
                try await request.downloadAndInstall()
            }
        }
        await onStatus("语音离线包已准备")
    }

    func currentRouteDescription() -> String {
        let session = AVAudioSession.sharedInstance()
        let inputs = session.currentRoute.inputs.map(\.portName)
        let outputs = session.currentRoute.outputs.map(\.portName)
        let inputText = inputs.isEmpty ? "系统麦克风" : inputs.joined(separator: ", ")
        let outputText = outputs.isEmpty ? "系统输出" : outputs.joined(separator: ", ")
        return "输入：\(inputText) · 输出：\(outputText)"
    }

    func stop() async {
        provider?.captureSession.stopRunning()
        if let analyzer {
            await analyzer.cancelAndFinishNow()
        }
        recognitionTask?.cancel()
        analysisTask?.cancel()
        recognitionTask = nil
        analysisTask = nil
        provider = nil
        transcriber = nil
        self.analyzer = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func requestMicrophonePermission() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return true
        case .notDetermined:
            return await AVCaptureDevice.requestAccess(for: .audio)
        default:
            return false
        }
    }

    private func configureAudioSession(preferBluetoothMic: Bool) throws {
        let session = AVAudioSession.sharedInstance()
        var options: AVAudioSession.CategoryOptions = [.allowBluetoothA2DP]

        if preferBluetoothMic {
            options.insert(.allowBluetoothHFP)
            if #available(iOS 26.0, *) {
                options.insert(.bluetoothHighQualityRecording)
            }
        }

        try session.setCategory(.playAndRecord, mode: .spokenAudio, options: options)
        try session.setActive(true)

        if !preferBluetoothMic,
           let builtIn = session.availableInputs?.first(where: { $0.portType == .builtInMic }) {
            try? session.setPreferredInput(builtIn)
        }
    }
}
