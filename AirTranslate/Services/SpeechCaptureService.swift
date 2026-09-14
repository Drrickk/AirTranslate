@preconcurrency import AVFoundation
import Speech
import Foundation

private struct SendableAudioBuffer: @unchecked Sendable {
    let buffer: AVAudioPCMBuffer
}

private final class SpeechAudioConverter {
    enum ConversionError: LocalizedError {
        case cannotCreateConverter
        case cannotCreateBuffer
        case conversionFailed(String)

        var errorDescription: String? {
            switch self {
            case .cannotCreateConverter:
                return "无法创建语音音频转换器。"
            case .cannotCreateBuffer:
                return "无法创建语音音频缓冲区。"
            case .conversionFailed(let detail):
                return "音频格式转换失败：\(detail)"
            }
        }
    }

    func convert(_ buffer: AVAudioPCMBuffer, to targetFormat: AVAudioFormat) throws -> AVAudioPCMBuffer {
        if buffer.format == targetFormat {
            return buffer
        }

        guard let converter = AVAudioConverter(from: buffer.format, to: targetFormat) else {
            throw ConversionError.cannotCreateConverter
        }
        converter.primeMethod = .none

        let ratio = targetFormat.sampleRate / buffer.format.sampleRate
        let capacity = max(
            AVAudioFrameCount(1),
            AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up))
        )

        guard let converted = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else {
            throw ConversionError.cannotCreateBuffer
        }

        var provided = false
        var conversionError: NSError?
        let status = converter.convert(to: converted, error: &conversionError) { _, inputStatus in
            if provided {
                inputStatus.pointee = .noDataNow
                return nil
            }
            provided = true
            inputStatus.pointee = .haveData
            return buffer
        }

        guard status != .error else {
            throw ConversionError.conversionFailed(conversionError?.localizedDescription ?? "未知错误")
        }

        return converted
    }
}

@MainActor
final class SpeechCaptureService: NSObject {
    enum ServiceError: LocalizedError {
        case microphoneDenied
        case speechTranscriberUnavailable
        case unsupportedLocale(String)
        case modelUnavailable(String)
        case analyzerFormatUnavailable(String)
        case noAudioDevice
        case failedToStart(String)

        var errorDescription: String? {
            switch self {
            case .microphoneDenied:
                return "没有麦克风权限，请到系统设置中允许访问。"
            case .speechTranscriberUnavailable:
                return "这台设备不支持 iOS 26 新版端侧语音识别模型。"
            case .unsupportedLocale(let locale):
                return "SpeechTranscriber 暂不支持 \(locale)。"
            case .modelUnavailable(let locale):
                return "无法准备 \(locale) 的离线语音模型。请联网后重试首次下载。"
            case .analyzerFormatUnavailable(let locale):
                return "\(locale) 离线语音模型尚未准备完成，无法取得识别音频格式。"
            case .noAudioDevice:
                return "没有找到可用的音频输入设备。"
            case .failedToStart(let detail):
                return "无法启动离线语音识别：\(detail)"
            }
        }
    }

    private var audioEngine: AVAudioEngine?
    private var audioContinuation: AsyncStream<SendableAudioBuffer>.Continuation?
    private var inputContinuation: AsyncStream<AnalyzerInput>.Continuation?
    private var analyzer: SpeechAnalyzer?
    private var transcriber: SpeechTranscriber?
    private var analyzerFormat: AVAudioFormat?
    private var audioFeedTask: Task<Void, Never>?
    private var resultTask: Task<Void, Never>?

    func start(
        localeIdentifier: String,
        preferBluetoothMic: Bool,
        onPartial: @escaping @Sendable (String) async -> Void,
        onFinal: @escaping @Sendable (String) async -> Void,
        onStatus: @escaping @Sendable (String) async -> Void
    ) async throws {
        await stop()

        guard await requestMicrophonePermission() else {
            throw ServiceError.microphoneDenied
        }

        guard SpeechTranscriber.isAvailable else {
            throw ServiceError.speechTranscriberUnavailable
        }

        try configureAudioSession(preferBluetoothMic: preferBluetoothMic)

        let requestedLocale = Locale(identifier: localeIdentifier)
        guard let supportedLocale = await SpeechTranscriber.supportedLocale(equivalentTo: requestedLocale) else {
            throw ServiceError.unsupportedLocale(localeIdentifier)
        }

        let transcriber = SpeechTranscriber(locale: supportedLocale, preset: .progressiveTranscription)
        self.transcriber = transcriber

        try await ensureModel(
            for: transcriber,
            localeName: localeIdentifier,
            onStatus: onStatus
        )

        guard let analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            throw ServiceError.analyzerFormatUnavailable(localeIdentifier)
        }
        self.analyzerFormat = analyzerFormat

        let analyzer = SpeechAnalyzer(modules: [transcriber])
        self.analyzer = analyzer

        let (inputSequence, inputContinuation) = AsyncStream<AnalyzerInput>.makeStream(
            bufferingPolicy: .unbounded
        )
        self.inputContinuation = inputContinuation

        resultTask = Task { [weak self] in
            guard let self else { return }
            do {
                for try await result in transcriber.results {
                    if Task.isCancelled { break }
                    let text = String(result.text.characters)
                        .trimmingCharacters(in: .whitespacesAndNewlines)
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
                    await onStatus("端侧语音识别停止：\(error.localizedDescription)")
                }
            }
        }

        try await analyzer.start(inputSequence: inputSequence)

        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        let recordingFormat = inputNode.outputFormat(forBus: 0)
        guard recordingFormat.sampleRate > 0, recordingFormat.channelCount > 0 else {
            await analyzer.cancelAndFinishNow()
            throw ServiceError.noAudioDevice
        }

        let (audioStream, audioContinuation) = AsyncStream<SendableAudioBuffer>.makeStream(
            bufferingPolicy: .bufferingNewest(16)
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
            inputContinuation.finish()
            await analyzer.cancelAndFinishNow()
            throw ServiceError.failedToStart(error.localizedDescription)
        }
        self.audioEngine = engine

        audioFeedTask = Task { [weak self] in
            guard let self else { return }
            let converter = SpeechAudioConverter()

            do {
                for await wrapped in audioStream {
                    if Task.isCancelled { break }
                    let converted = try converter.convert(wrapped.buffer, to: analyzerFormat)
                    inputContinuation.yield(AnalyzerInput(buffer: converted))
                }
            } catch {
                if !Task.isCancelled {
                    await onStatus("麦克风音频转换停止：\(error.localizedDescription)")
                }
            }
        }

        await onStatus("设备端离线识别 · \(supportedLocale.identifier)")
    }

    func prepareLocales(
        _ localeIdentifiers: [String],
        onStatus: @escaping @Sendable (String) async -> Void
    ) async throws {
        guard SpeechTranscriber.isAvailable else {
            throw ServiceError.speechTranscriberUnavailable
        }

        for localeIdentifier in Array(Set(localeIdentifiers)).sorted() {
            let requestedLocale = Locale(identifier: localeIdentifier)
            guard let supportedLocale = await SpeechTranscriber.supportedLocale(equivalentTo: requestedLocale) else {
                throw ServiceError.unsupportedLocale(localeIdentifier)
            }

            let transcriber = SpeechTranscriber(locale: supportedLocale, preset: .progressiveTranscription)
            try await ensureModel(
                for: transcriber,
                localeName: localeIdentifier,
                onStatus: onStatus
            )
        }

        await onStatus("端侧语音模型已准备；翻译语言包由系统 Translation 框架继续准备")
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
            if engine.isRunning {
                engine.stop()
            }
            engine.inputNode.removeTap(onBus: 0)
        }
        audioEngine = nil

        audioContinuation?.finish()
        audioContinuation = nil

        audioFeedTask?.cancel()
        audioFeedTask = nil

        inputContinuation?.finish()
        inputContinuation = nil

        if let analyzer {
            do {
                try await analyzer.finalizeAndFinishThroughEndOfInput()
            } catch {
                await analyzer.cancelAndFinishNow()
            }
        }

        resultTask?.cancel()
        resultTask = nil
        analyzer = nil
        transcriber = nil
        analyzerFormat = nil

        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func ensureModel(
        for transcriber: SpeechTranscriber,
        localeName: String,
        onStatus: @escaping @Sendable (String) async -> Void
    ) async throws {
        let initialStatus = await AssetInventory.status(forModules: [transcriber])

        switch initialStatus {
        case .installed:
            await onStatus("\(localeName) 端侧语音模型已安装")
            return
        case .unsupported:
            throw ServiceError.modelUnavailable(localeName)
        case .supported, .downloading:
            break
        @unknown default:
            break
        }

        await onStatus("正在下载 \(localeName) 端侧语音模型…首次使用需要联网")

        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await request.downloadAndInstall()
        }

        let finalStatus = await AssetInventory.status(forModules: [transcriber])
        guard finalStatus == .installed else {
            throw ServiceError.modelUnavailable(localeName)
        }

        await onStatus("\(localeName) 端侧语音模型下载完成")
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

        let mode: AVAudioSession.Mode = preferBluetoothMic ? .default : .spokenAudio
        try session.setCategory(.playAndRecord, mode: mode, options: options)
        try session.setActive(true, options: .notifyOthersOnDeactivation)

        if !preferBluetoothMic,
           let builtIn = session.availableInputs?.first(where: { $0.portType == .builtInMic }) {
            try? session.setPreferredInput(builtIn)
        }
    }
}
