import AVFoundation

@MainActor
final class SpeechOutputService: NSObject {
    enum OutputRoute {
        case current
        case speaker
    }

    private let synthesizer = AVSpeechSynthesizer()
    private var overriddenToSpeaker = false

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    func speak(_ text: String, languageCode: String, route: OutputRoute = .current) {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }

        if route == .speaker {
            let session = AVAudioSession.sharedInstance()
            try? session.setActive(true)
            try? session.overrideOutputAudioPort(.speaker)
            overriddenToSpeaker = true
        }

        let utterance = AVSpeechUtterance(string: clean)
        utterance.voice = AVSpeechSynthesisVoice(language: languageCode)
        utterance.rate = 0.48
        synthesizer.speak(utterance)
    }

    func stop() {
        synthesizer.stopSpeaking(at: .immediate)
        restoreRouteIfNeeded()
    }

    private func restoreRouteIfNeeded() {
        guard overriddenToSpeaker else { return }
        try? AVAudioSession.sharedInstance().overrideOutputAudioPort(.none)
        overriddenToSpeaker = false
    }
}

extension SpeechOutputService: AVSpeechSynthesizerDelegate {
    nonisolated func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        didFinish utterance: AVSpeechUtterance
    ) {
        Task { @MainActor in
            self.restoreRouteIfNeeded()
        }
    }

    nonisolated func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        didCancel utterance: AVSpeechUtterance
    ) {
        Task { @MainActor in
            self.restoreRouteIfNeeded()
        }
    }
}
