@preconcurrency import AVFoundation
@preconcurrency import Speech
import Foundation

@MainActor
final class SpeechCaptureService: NSObject {
    enum RecognitionMode: Equatable {
        case onDevice
        case online

        var statusText: String {
            switch self {
            case .onDevice: return "设备端离线识别"
            case .online: return "Apple 在线识别"
            }
        }
    }

    enum ServiceError: LocalizedError {
        case microphoneDenied
        case speechPermissionDenied
        case unsupportedLocale(String)
        case onDeviceRecognitionUnavailable(String)
        case onlineRecognitionUnavailable(String)
        case noAudioDevice
        case failedToStart(String)

        var errorDescription: String? {
            switch self {
            case .microphoneDenied:
                return "没有麦克风权限，请到系统设置中允许访问。"
            case .speechPermissionDenied:
                return "没有语音识别权限，请到系统设置中允许访问。"
            case .unsupportedLocale(let locale):
                return "当前设备不支持 \(locale) 的语音识别。"
            case .onDeviceRecognitionUnavailable(let locale):
                return "当前设备没有可用的 \(locale) 设备端语音识别资源。可开启“允许联网语音识别兜底”继续使用。"
            case .onlineRecognitionUnavailable(let locale):
                return "\(locale) 的 Apple 在线语音识别当前不可用，请检查网络后重试。"
            case .noAudioDevice:
                return "没有找到可用的音频输入设备。"
            case .failedToStart(let detail):
                return "无法启动语音识别：\(detail)"
            }
        }
    }

    private var audioEngine: AVAudioEngine?
    private var speechRecognizer: SFSpeechRecognizer?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var sessionToken: UUID?
    private(set) var recognitionMode: RecognitionMode?

    func start(
        localeIdentifier: String,
        preferBluetoothMic: Bool,
        allowOnlineFallback: Bool,
        onPartial: @escaping @Sendable (String) async -> Void,
        onFinal: @escaping @Sendable (String) async -> Void,
        onStatus: @escaping @Sendable (String) async -> Void
    ) async throws -> RecognitionMode {
        await stop()

        guard await requestMicrophonePermission() else {
            throw ServiceError.microphoneDenied
        }
        guard await requestSpeechRecognitionPermission() else {
            throw ServiceError.speechPermissionDenied
        }

        try configureAudioSession(preferBluetoothMic: preferBluetoothMic)

        let locale = Locale(identifier: localeIdentifier)
        guard let recognizer = SFSpeechRecognizer(locale: locale) else {
            throw ServiceError.unsupportedLocale(localeIdentifier)
        }

        let mode: RecognitionMode
        if recognizer.supportsOnDeviceRecognition {
            mode = .onDevice
        } else if allowOnlineFallback {
            guard recognizer.isAvailable else {
                throw ServiceError.onlineRecognitionUnavailable(localeIdentifier)
            }
            mode = .online
        } else {
            throw ServiceError.onDeviceRecognitionUnavailable(localeIdentifier)
        }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = (mode == .onDevice)
        request.taskHint = .dictation
        if #available(iOS 16.0, *) {
            request.addsPunctuation = true
        }

        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        let recordingFormat = inputNode.outputFormat(forBus: 0)
        guard recordingFormat.sampleRate > 0, recordingFormat.channelCount > 0 else {
            throw ServiceError.noAudioDevice
        }

        let token = UUID()
        sessionToken = token
        speechRecognizer = recognizer
        recognitionRequest = request
        recognitionMode = mode
        audioEngine = engine

        recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            Task { @MainActor [weak self] in
                guard let self, self.sessionToken == token else { return }

                if let result {
                    let text = result.bestTranscription.formattedString
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    if !text.isEmpty {
                        if result.isFinal {
                            await onPartial("")
                            await onFinal(text)
                        } else {
                            await onPartial(text)
                        }
                    }
                }

                if let error, self.sessionToken == token {
                    let prefix = self.recognitionMode == .online ? "在线语音识别已停止" : "离线语音识别已停止"
                    await onStatus("\(prefix)：\(error.localizedDescription)")
                }
            }
        }

        inputNode.installTap(
            onBus: 0,
            bufferSize: 2048,
            format: recordingFormat
        ) { buffer, _ in
            request.append(buffer)
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            inputNode.removeTap(onBus: 0)
            recognitionTask?.cancel()
            recognitionTask = nil
            recognitionRequest = nil
            speechRecognizer = nil
            audioEngine = nil
            recognitionMode = nil
            sessionToken = nil
            throw ServiceError.failedToStart(error.localizedDescription)
        }

        await onStatus(mode == .onDevice ? "正在设备端离线识别" : "正在使用 Apple 在线语音识别")
        return mode
    }

    func prepareLocales(
        _ localeIdentifiers: [String],
        onStatus: @escaping @Sendable (String) async -> Void
    ) async throws {
        guard await requestSpeechRecognitionPermission() else {
            throw ServiceError.speechPermissionDenied
        }

        var messages: [String] = []
        for localeIdentifier in Array(Set(localeIdentifiers)).sorted() {
            let locale = Locale(identifier: localeIdentifier)
            guard let recognizer = SFSpeechRecognizer(locale: locale) else {
                messages.append("\(localeIdentifier)：不支持")
                continue
            }
            if recognizer.supportsOnDeviceRecognition {
                messages.append("\(localeIdentifier)：设备端离线可用")
            } else if recognizer.isAvailable {
                messages.append("\(localeIdentifier)：仅在线识别可用")
            } else {
                messages.append("\(localeIdentifier)：当前不可用")
            }
        }

        await onStatus(messages.joined(separator: " · "))
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
        let token = sessionToken
        sessionToken = nil

        if let engine = audioEngine {
            if engine.isRunning {
                engine.stop()
            }
            engine.inputNode.removeTap(onBus: 0)
        }
        audioEngine = nil

        recognitionRequest?.endAudio()
        recognitionTask?.cancel()
        recognitionTask = nil
        recognitionRequest = nil
        speechRecognizer = nil
        recognitionMode = nil

        if token != nil {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
    }

    private func requestSpeechRecognitionPermission() async -> Bool {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized:
            return true
        case .notDetermined:
            return await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { status in
                    continuation.resume(returning: status == .authorized)
                }
            }
        default:
            return false
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

        let mode: AVAudioSession.Mode = preferBluetoothMic ? .default : .spokenAudio
        try session.setCategory(.playAndRecord, mode: mode, options: options)
        try session.setActive(true, options: .notifyOthersOnDeactivation)

        if !preferBluetoothMic,
           let builtIn = session.availableInputs?.first(where: { $0.portType == .builtInMic }) {
            try? session.setPreferredInput(builtIn)
        }
    }
}
