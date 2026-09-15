@preconcurrency import AVFoundation
import Foundation

@MainActor
final class SpeechOutputService: NSObject {
    enum OutputRoute {
        case current
        case speaker
    }

    struct PlaybackDecision {
        let rate: Float
        let resynced: Bool
    }

    private let synthesizer = AVSpeechSynthesizer()
    private var overriddenToSpeaker = false
    private var pendingUtteranceCount = 0

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    @discardableResult
    func speak(
        _ text: String,
        languageCode: String,
        route: OutputRoute = .current,
        baseRate: Float = 0.58,
        adaptiveCatchUp: Bool = true
    ) -> PlaybackDecision? {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return nil }

        var didResync = false

        // Once the spoken queue gets several segments behind, continuing to read
        // every old sentence guarantees ever-growing latency. In catch-up mode we
        // discard stale audio only (the transcript remains intact) and resume from
        // the newest completed translation.
        if adaptiveCatchUp && pendingUtteranceCount >= 4 {
            synthesizer.stopSpeaking(at: .immediate)
            pendingUtteranceCount = 0
            didResync = true
        }

        if route == .speaker {
            let session = AVAudioSession.sharedInstance()
            try? session.setActive(true)
            try? session.overrideOutputAudioPort(.speaker)
            overriddenToSpeaker = true
        }

        let utterance = AVSpeechUtterance(string: clean)
        utterance.voice = AVSpeechSynthesisVoice(language: languageCode)
        utterance.preUtteranceDelay = 0
        utterance.postUtteranceDelay = 0

        let rate = adaptiveRate(
            languageCode: languageCode,
            requestedBaseRate: baseRate,
            queueDepth: pendingUtteranceCount,
            adaptiveCatchUp: adaptiveCatchUp
        )
        utterance.rate = rate

        pendingUtteranceCount += 1
        synthesizer.speak(utterance)
        return PlaybackDecision(rate: rate, resynced: didResync)
    }

    func stop() {
        synthesizer.stopSpeaking(at: .immediate)
        pendingUtteranceCount = 0
        restoreRouteIfNeeded()
    }

    private func adaptiveRate(
        languageCode: String,
        requestedBaseRate: Float,
        queueDepth: Int,
        adaptiveCatchUp: Bool
    ) -> Float {
        let isChinese = languageCode.lowercased().hasPrefix("zh")
        let minimumBase: Float = isChinese ? 0.56 : 0.50
        var rate = requestedBaseRate

        guard adaptiveCatchUp else {
            return min(max(rate, 0.40), 0.68)
        }
        rate = max(rate, minimumBase)

        // Gradually speed up as translated speech falls behind. Chinese receives
        // a slightly stronger boost because the default system voice is often
        // slower than conversational speech at AVSpeechUtterance's default rate.
        let step: Float = isChinese ? 0.035 : 0.03
        rate += Float(min(queueDepth, 3)) * step
        return min(rate, isChinese ? 0.69 : 0.66)
    }

    private func utteranceDidFinish() {
        pendingUtteranceCount = max(0, pendingUtteranceCount - 1)
        if pendingUtteranceCount == 0 {
            restoreRouteIfNeeded()
        }
    }

    private func restoreRouteIfNeeded() {
        guard overriddenToSpeaker else { return }
        try? AVAudioSession.sharedInstance().overrideOutputAudioPort(.none)
        overriddenToSpeaker = false
    }
}

extension SpeechOutputService: @preconcurrency AVSpeechSynthesizerDelegate {
    nonisolated func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        didFinish utterance: AVSpeechUtterance
    ) {
        Task { @MainActor [weak self] in
            self?.utteranceDidFinish()
        }
    }

    nonisolated func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        didCancel utterance: AVSpeechUtterance
    ) {
        Task { @MainActor [weak self] in
            self?.utteranceDidFinish()
        }
    }
}
