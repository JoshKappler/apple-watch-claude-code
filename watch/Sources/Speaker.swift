//
//  Speaker.swift
//  AVSpeechSynthesizer readback for `assistant_message`, paired with a haptic.
//
//  IMPORTANT watchOS caveat: TTS can be SILENT when there's no Bluetooth/AirPods
//  audio route connected (the watch's tiny speaker often won't play synthesized
//  speech). So we ALWAYS fire a haptic alongside speaking, and expose a mute toggle.
//  We configure the session as .playback / .spokenAudio with .duckOthers so podcasts
//  etc. dip rather than fight the readback.
//

import Foundation
import AVFoundation

@MainActor
final class Speaker: NSObject, ObservableObject {

    /// User toggle (persisted by the view via @AppStorage and pushed in here).
    @Published var isMuted = false

    /// True while audio is actively being spoken — drives the transcript "speaking pulse".
    @Published private(set) var isSpeaking = false

    private let synth = AVSpeechSynthesizer()

    override init() {
        super.init()
        synth.delegate = self
    }

    /// Speak an assistant message aloud (if unmuted) and ALWAYS fire a haptic.
    func speak(_ text: String) {
        // The haptic is the reliable channel — fire it whether or not audio is muted/routed.
        Haptics.spoken()

        guard !isMuted else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        activateSession()

        let utterance = AVSpeechUtterance(string: trimmed)
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        synth.speak(utterance)
    }

    /// Stop any in-progress speech immediately (e.g. on cancel / new turn).
    func stop() {
        if synth.isSpeaking {
            synth.stopSpeaking(at: .immediate)
        }
        isSpeaking = false
    }

    func setMuted(_ muted: Bool) {
        isMuted = muted
        if muted { stop() }
    }

    // MARK: - Audio session

    private func activateSession() {
        let session = AVAudioSession.sharedInstance()
        // .spokenAudio mode is the right policy for TTS; duckOthers dips background audio.
        try? session.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
        try? session.setActive(true, options: [])
    }

    private func deactivateSession() {
        // Release the route so background audio un-ducks. Best-effort.
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
    }
}

extension Speaker: AVSpeechSynthesizerDelegate {
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                                       didStart utterance: AVSpeechUtterance) {
        Task { @MainActor in self.isSpeaking = true }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                                       didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in
            self.isSpeaking = false
            self.deactivateSession()
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                                       didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in
            self.isSpeaking = false
            self.deactivateSession()
        }
    }
}
