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

    private var converter: AVAudioConverter?
    private var inputFormat: AVAudioFormat?
    private var outputFormat: AVAudioFormat?

    func convert(_ buffer: AVAudioPCMBuffer, to targetFormat: AVAudioFormat) throws -> AVAudioPCMBuffer {
        if buffer.format == targetFormat {
            return buffer
        }

        if converter == nil || inputFormat != buffer.format || outputFormat != targetFormat {
            guard let newConverter = AVAudioConverter(from: buffer.format, to: targetFormat) else {
                throw ConversionError.cannotCreateConverter
            }
            newConverter.primeMethod = .none
            converter = newConverter
            inputFormat = buffer.format
            outputFormat = targetFormat
        }

        guard let converter else {
            throw ConversionError.cannotCreateConverter
        }

        let ratio = targetFormat.sampleRate / max(buffer.format.sampleRate, 1)
        let capacity = max(
            AVAudioFrameCount(1),
            AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 32
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
        case reservationFailed(String)
        case modelUnavailable(String)
        case analyzerFormatUnavailable(String)
        case noAudioDevice
        case failedToStart(String)

        var errorDescription: String? {
            switch self {
            case .microphoneDenied:
                return "没有麦克风权限，请到系统设置中允许访问。"
            case .speechTranscriberUnavailable:
                return "这台设备不支持 iOS 26 新版端侧语音识别。"
            case .unsupportedLocale(let locale):
                return "SpeechTranscriber 暂不支持 \(locale)。"
            case .reservationFailed(let locale):
                return "无法为 \(locale) 预留端侧语音模型空间。"
            case .modelUnavailable(let locale):
                return "无法准备 \(locale) 的离线语音模型。请保持联网后重试首次下载。"
            case .analyzerFormatUnavailable(let locale):
                return "\(locale) 端侧语音模型尚未准备完成，无法取得识别音频格式。"
            case .noAudioDevice:
                return "没有找到可用的音频输入设备。"
            case .failedToStart(let detail):
                return "无法启动离线语音识别：\(detail)"
            }
        }
    }

    private static let phaseKey = "AirTranslate.SpeechStartupPhase"

    static var lastStartupPhase: String? {
        let value = UserDefaults.standard.string(forKey: phaseKey)
        guard let value, !value.isEmpty, value != "已停止", value != "正在识别" else { return nil }
        return value
    }

    private var audioEngine: AVAudioEngine?
    private var audioContinuation: AsyncStream<SendableAudioBuffer>.Continuation?
    private var inputContinuation: AsyncStream<AnalyzerInput>.Continuation?
    private var analyzer: SpeechAnalyzer?
    private var transcriber: SpeechTranscriber?
    private var analyzerFormat: AVAudioFormat?
    private var audioFeedTask: Task<Void, Never>?
    private var resultTask: Task<Void, Never>?
    private var tapInstalled = false

    func start(
        localeIdentifier: String,
        preferBluetoothMic: Bool,
        onPartial: @escaping @Sendable (String) async -> Void,
        onFinal: @escaping @Sendable (String) async -> Void,
        onStatus: @escaping @Sendable (String) async -> Void
    ) async throws {
        await stop()
        setPhase("1/8 请求麦克风权限")

        guard await requestMicrophonePermission() else {
            throw ServiceError.microphoneDenied
        }

        guard SpeechTranscriber.isAvailable else {
            throw ServiceError.speechTranscriberUnavailable
        }

        setPhase("2/8 检查 en-US 等端侧语言支持")
        let requestedLocale = Locale(identifier: localeIdentifier)
        guard let supportedLocale = await SpeechTranscriber.supportedLocale(equivalentTo: requestedLocale) else {
            throw ServiceError.unsupportedLocale(localeIdentifier)
        }

        let transcriber = SpeechTranscriber(locale: supportedLocale, preset: .progressiveTranscription)
        self.transcriber = transcriber

        setPhase("3/8 预留并准备端侧语音模型")
        try await ensureReservation(for: supportedLocale, localeName: localeIdentifier, onStatus: onStatus)
        try await ensureModel(for: transcriber, locale: supportedLocale, localeName: localeIdentifier, onStatus: onStatus)

        guard let analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            throw ServiceError.analyzerFormatUnavailable(localeIdentifier)
        }
        self.analyzerFormat = analyzerFormat

        setPhase("4/8 创建 SpeechAnalyzer")
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        self.analyzer = analyzer

        let (inputSequence, inputContinuation) = AsyncStream<AnalyzerInput>.makeStream(bufferingPolicy: .unbounded)
        self.inputContinuation = inputContinuation

        resultTask = Task {
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

        setPhase("5/8 配置音频会话")
        try configureAudioSession(preferBluetoothMic: preferBluetoothMic)
        // 给蓝牙/内置麦克风路由一个很短的稳定时间，避免路由刚切换时取得无效格式。
        try? await Task.sleep(nanoseconds: 120_000_000)

        setPhase("6/8 创建麦克风音频引擎")
        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        let hardwareFormat = inputNode.inputFormat(forBus: 0)
        guard hardwareFormat.sampleRate > 0, hardwareFormat.channelCount > 0 else {
            await analyzer.cancelAndFinishNow()
            throw ServiceError.noAudioDevice
        }

        let (audioStream, audioContinuation) = AsyncStream<SendableAudioBuffer>.makeStream(
            bufferingPolicy: .bufferingNewest(16)
        )
        self.audioContinuation = audioContinuation

        setPhase("7/8 安装麦克风监听")
        // format 传 nil，让 AVAudioEngine 使用当前硬件/路由的原生输出格式。
        // 这比在蓝牙路由切换期间强塞一个旧 format 更不容易触发 AVAudioEngine 的运行时异常。
        inputNode.installTap(
            onBus: 0,
            bufferSize: 4096,
            format: nil
        ) { @Sendable buffer, _ in
            // Swift 6 / AVAudioEngine workaround recommended by Apple DTS:
            // the tap callback is invoked on an audio thread, so it must not inherit
            // MainActor isolation from SpeechCaptureService. AsyncStream.Continuation
            // is safe to yield from this callback.
            guard buffer.frameLength > 0 else { return }
            audioContinuation.yield(SendableAudioBuffer(buffer: buffer))
        }
        tapInstalled = true

        engine.prepare()
        setPhase("8/8 启动麦克风音频引擎")
        do {
            try engine.start()
        } catch {
            if tapInstalled {
                inputNode.removeTap(onBus: 0)
                tapInstalled = false
            }
            audioContinuation.finish()
            inputContinuation.finish()
            await analyzer.cancelAndFinishNow()
            throw ServiceError.failedToStart(error.localizedDescription)
        }
        self.audioEngine = engine

        audioFeedTask = Task {
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

        setPhase("正在识别")
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
            try await ensureReservation(for: supportedLocale, localeName: localeIdentifier, onStatus: onStatus)
            try await ensureModel(
                for: transcriber,
                locale: supportedLocale,
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
            if tapInstalled {
                engine.inputNode.removeTap(onBus: 0)
                tapInstalled = false
            }
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
        setPhase("已停止")
    }

    private func ensureReservation(
        for locale: Locale,
        localeName: String,
        onStatus: @escaping @Sendable (String) async -> Void
    ) async throws {
        let reserved = await AssetInventory.reservedLocales
        if containsEquivalentLocale(locale, in: reserved) {
            return
        }

        if reserved.count >= AssetInventory.maximumReservedLocales,
           let releasable = reserved.first {
            await onStatus("端侧模型名额已满，正在释放一个旧语言模型名额…")
            _ = await AssetInventory.release(reservedLocale: releasable)
        }

        await onStatus("正在为 \(localeName) 预留端侧语音模型…")
        let didReserve = try await AssetInventory.reserve(locale: locale)
        guard didReserve else {
            // reserve 返回 false 也可能意味着已经被其他路径预留，再读取一次确认。
            let refreshed = await AssetInventory.reservedLocales
            guard containsEquivalentLocale(locale, in: refreshed) else {
                throw ServiceError.reservationFailed(localeName)
            }
            return
        }
    }

    private func ensureModel(
        for transcriber: SpeechTranscriber,
        locale: Locale,
        localeName: String,
        onStatus: @escaping @Sendable (String) async -> Void
    ) async throws {
        let installedLocales = await SpeechTranscriber.installedLocales
        if containsEquivalentLocale(locale, in: installedLocales) {
            await onStatus("\(localeName) 端侧语音模型已安装")
            return
        }

        let status = await AssetInventory.status(forModules: [transcriber])
        if status == .unsupported {
            throw ServiceError.modelUnavailable(localeName)
        }

        await onStatus("正在下载 \(localeName) 端侧语音模型…首次使用需要联网")
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await request.downloadAndInstall()
        }

        let finalInstalledLocales = await SpeechTranscriber.installedLocales
        guard containsEquivalentLocale(locale, in: finalInstalledLocales) else {
            throw ServiceError.modelUnavailable(localeName)
        }

        await onStatus("\(localeName) 端侧语音模型下载完成")
    }

    private func containsEquivalentLocale(_ locale: Locale, in locales: [Locale]) -> Bool {
        let target = locale.identifier(.bcp47).lowercased()
        return locales.contains { $0.identifier(.bcp47).lowercased() == target }
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

    private func setPhase(_ text: String) {
        UserDefaults.standard.set(text, forKey: Self.phaseKey)
    }
}
