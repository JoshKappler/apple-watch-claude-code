//
//  PhoneDictation.swift
//  Live voice dictation for the phone, using SFSpeechRecognizer + AVAudioEngine.
//
//  The watch can't do this (SFSpeechRecognizer doesn't function on watchOS, so the watch
//  uses WatchKit's presentTextInputController). The phone can: this streams partial results
//  as you speak and commits the final transcription into the composer. The keyboard's own
//  dictation mic still works too — this is the in-app, hands-on-the-composer path.
//
//  Permissions: NSMicrophoneUsageDescription + NSSpeechRecognitionUsageDescription (Info.plist).
//

import Foundation
import Speech
import AVFoundation

@MainActor
final class DictationController: ObservableObject {
    /// True while actively listening.
    @Published private(set) var isListening = false
    /// Best transcription so far for the current utterance (partial, updates live).
    @Published private(set) var partial = ""
    /// Set if mic/speech permission was denied — the UI can prompt the user to Settings.
    @Published private(set) var denied = false

    /// Called with the final transcription when listening stops (only if non-empty).
    var onCommit: ((String) -> Void)?
    /// Called with each live partial so the composer can show it in place.
    var onPartial: ((String) -> Void)?

    private let recognizer = SFSpeechRecognizer(locale: Locale.current) ?? SFSpeechRecognizer()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private let engine = AVAudioEngine()

    func toggle() {
        if isListening { stop() } else { start() }
    }

    func start() {
        guard !isListening else { return }
        requestAuth { [weak self] granted in
            guard let self else { return }
            guard granted else { self.denied = true; return }
            self.beginSession()
        }
    }

    func stop() {
        guard isListening else { return }
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        task?.finish()
        task = nil
        request = nil
        isListening = false
        let final = partial.trimmingCharacters(in: .whitespacesAndNewlines)
        if !final.isEmpty { onCommit?(final) }
        partial = ""
        deactivateAudioSession()
    }

    // MARK: - Internals

    private func requestAuth(_ completion: @escaping (Bool) -> Void) {
        SFSpeechRecognizer.requestAuthorization { speechStatus in
            let speechOK = (speechStatus == .authorized)
            AVAudioApplication.requestRecordPermission { micOK in
                DispatchQueue.main.async { completion(speechOK && micOK) }
            }
        }
    }

    private func beginSession() {
        guard let recognizer, recognizer.isAvailable else { return }

        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.record, mode: .measurement, options: .duckOthers)
            try session.setActive(true, options: .notifyOthersOnDeactivation)
        } catch {
            return
        }

        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        request = req

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak req] buffer, _ in
            req?.append(buffer)
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            stop()
            return
        }

        isListening = true
        partial = ""

        task = recognizer.recognitionTask(with: req) { [weak self] result, error in
            guard let self else { return }
            Task { @MainActor in
                if let result {
                    self.partial = result.bestTranscription.formattedString
                    self.onPartial?(self.partial)
                }
                if error != nil || (result?.isFinal ?? false) {
                    if self.isListening { self.stop() }
                }
            }
        }
    }

    private func deactivateAudioSession() {
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}
