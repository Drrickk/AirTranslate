@preconcurrency import AVFoundation
import Speech

private struct SendableAudioBuffer: @unchecked Sendable {
    let buffer: AVAudioPCMBuffer
}

private final class BufferConverter {
    enum ConversionError: LocalizedError {
        case failedToCreateConverter
        case failedToCreateConversionBuffer
        case conversionFailed(NSError?)

        var errorDescription: String? {
            switch self {
            case .failedToCreateConverter:
                return "无法创建音频格式转换器。"
            case .failedToCreateConversionBuffer:
                return "无法创建音频转换缓冲区。"
            case .conversionFailed(let error):
                return error?.localizedDescription ?? "音频格式转换失败。"
            }
        }
    }

    private var converter: AVAudioConverter?

    func convertBuffer(_ buffer: AVAudioPCMBuffer, to format: AVAudioFormat) throws -> AVAudioPCMBuffer {
        let inputFormat = buffer.format
        guard inputFormat != format else { return buffer }

        if converter == nil || converter?.inputFormat != inputFormat || converter?.outputFormat != format {
            converter = AVAudioConverter(from: inputFormat, to: format)
            converter?.primeMethod = .none
        }

        guard let converter else {
            throw ConversionError.failedToCreateConverter
        }

        let sampleRateRatio = converter.outputFormat.sampleRate / converter.inputFormat.sampleRate
        let scaledInputFrameLength = Double(buffer.frameLength) * sampleRateRatio
        let frameCapacity = max(AVAudioFrameCount(1), AVAudioFrameCount(scaledInputFrameLength.rounded(.up)))

        guard let conversionBuffer = AVAudioPCMBuffer(
            pcmFormat: converter.outputFormat,
            frameCapacity: frameCapacity
        ) else {
            throw ConversionError.failedToCreateConversionBuffer
        }

        var nsError: NSError?
        var bufferProcessed = false

        let status = converter.convert(to: conversionBuffer, error: &nsError) { _, inputStatusPointer in
            defer { bufferProcessed = true }
            inputStatusPointer.pointee = bufferProcessed ? .noDataNow : .haveData
            return bufferProcessed ? nil : buffer
        }

        guard status != .error else {
            throw ConversionError.conversionFailed(nsError)
        }

        return conversionBuffer
    }
}

actor SpeechCaptureService {
    enum ServiceError: LocalizedError {
        case microphoneDenied
        case noAudioDevice
        case unsupportedLocale(String)
        case analyzerFormatUnavailable
        case failedToStart

        var errorDescription: String? {
            switch self {
            case .microphoneDenied:
                return "没有麦克风权限，请到系统设置中允许访问。"
            case .noAudioDevice:
                return "没有找到可用的音频输入设备。"
            case .unsupportedLocale(let locale):
                return "当前设备不支持 \(locale) 的新一代离线语音识别。"
            case .analyzerFormatUnavailable:
                return "无法取得语音识别所需的音频格式。"
            case .failedToStart:
                return "无法启动语音识别。"
            }
        }
    }

    private var analyzer: SpeechAnalyzer?
    private var transcriber: SpeechTranscriber?
    private var analyzerFormat: AVAudioFormat?
    private var inputBuilder: AsyncStream<AnalyzerInput>.Continuation?

    private var audioEngine: AVAudioEngine?
    private var audioContinuation: AsyncStream<SendableAudioBuffer>.Continuation?
    private var recognitionTask: Task<Void, Never>?
    private var audioFeedTask: Task<Void, Never>?

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
        guard let supportedLocale = await SpeechTranscriber.supportedLocale(equivalentTo: requestedLocale) else {
            throw ServiceError.unsupportedLocale(localeIdentifier)
        }

        let transcriber = SpeechTranscriber(
            locale: supportedLocale,
            preset: .progressiveTranscription
        )
        self.transcriber = transcriber

        if let installationRequest = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            await onStatus("正在下载 \(localeIdentifier) 离线语音模型…")
            try await installationRequest.downloadAndInstall()
        }

        guard let analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            throw ServiceError.analyzerFormatUnavailable
        }
        self.analyzerFormat = analyzerFormat

        let analyzer = SpeechAnalyzer(modules: [transcriber])
        self.analyzer = analyzer

        let (inputSequence, inputBuilder) = AsyncStream<AnalyzerInput>.makeStream(bufferingPolicy: .unbounded)
        self.inputBuilder = inputBuilder
        try await analyzer.start(inputSequence: inputSequence)

        recognitionTask = Task { [weak self] in
            await self?.consumeRecognitionResults(
                onPartial: onPartial,
                onFinal: onFinal,
                onStatus: onStatus
            )
        }

        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        let recordingFormat = inputNode.outputFormat(forBus: 0)
        guard recordingFormat.sampleRate > 0, recordingFormat.channelCount > 0 else {
            await analyzer.cancelAndFinishNow()
            throw ServiceError.noAudioDevice
        }

        let (audioStream, audioContinuation) = AsyncStream<SendableAudioBuffer>.makeStream(
            bufferingPolicy: .bufferingNewest(12)
        )
        self.audioContinuation = audioContinuation

        inputNode.installTap(
            onBus: 0,
            bufferSize: 4096,
            format: recordingFormat
        ) { buffer, _ in
            audioContinuation.yield(SendableAudioBuffer(buffer: buffer))
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            inputNode.removeTap(onBus: 0)
            audioContinuation.finish()
            inputBuilder.finish()
            await analyzer.cancelAndFinishNow()
            throw error
        }
        self.audioEngine = engine

        audioFeedTask = Task { [weak self] in
            await self?.consumeAudioStream(audioStream, onStatus: onStatus)
        }

        await onStatus("正在离线识别")
    }

    func prepareLocales(
        _ localeIdentifiers: [String],
        onStatus: @escaping @Sendable (String) async -> Void
    ) async throws {
        for localeIdentifier in Array(Set(localeIdentifiers)) {
            let requestedLocale = Locale(identifier: localeIdentifier)
            guard let supportedLocale = await SpeechTranscriber.supportedLocale(equivalentTo: requestedLocale) else {
                throw ServiceError.unsupportedLocale(localeIdentifier)
            }

            let transcriber = SpeechTranscriber(
                locale: supportedLocale,
                preset: .progressiveTranscription
            )

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
        if let engine = audioEngine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        audioEngine = nil

        audioContinuation?.finish()
        audioContinuation = nil
        audioFeedTask?.cancel()
        audioFeedTask = nil

        inputBuilder?.finish()
        inputBuilder = nil

        if let analyzer {
            do {
                try await analyzer.finalizeAndFinishThroughEndOfInput()
            } catch {
                await analyzer.cancelAndFinishNow()
            }
        }

        recognitionTask?.cancel()
        recognitionTask = nil
        transcriber = nil
        self.analyzer = nil
        analyzerFormat = nil

        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func consumeAudioStream(
        _ stream: AsyncStream<SendableAudioBuffer>,
        onStatus: @escaping @Sendable (String) async -> Void
    ) async {
        guard let analyzerFormat, let inputBuilder else { return }
        let converter = BufferConverter()

        do {
            for await wrapped in stream {
                if Task.isCancelled { break }
                let converted = try converter.convertBuffer(wrapped.buffer, to: analyzerFormat)
                inputBuilder.yield(AnalyzerInput(buffer: converted))
            }
        } catch {
            if !Task.isCancelled {
                await onStatus("音频转换结束：\(error.localizedDescription)")
            }
        }
    }

    private func consumeRecognitionResults(
        onPartial: @escaping @Sendable (String) async -> Void,
        onFinal: @escaping @Sendable (String) async -> Void,
        onStatus: @escaping @Sendable (String) async -> Void
    ) async {
        guard let transcriber else { return }

        do {
            for try await result in transcriber.results {
                if Task.isCancelled { break }
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

        let audioMode: AVAudioSession.Mode = preferBluetoothMic ? .default : .spokenAudio
        try session.setCategory(.playAndRecord, mode: audioMode, options: options)
        try session.setActive(true)

        if !preferBluetoothMic,
           let builtIn = session.availableInputs?.first(where: { $0.portType == .builtInMic }) {
            try? session.setPreferredInput(builtIn)
        }
    }
}
