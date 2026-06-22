//
//  Speech.swift
//  Push-to-talk dictation: SFSpeechRecognizer + AVAudioEngine input tap.
//
//  Flow: the mic button uses a press-and-hold gesture. On press → start() begins an
//  AVAudioEngine tap feeding an SFSpeechAudioBufferRecognitionRequest with
//  shouldReportPartialResults so the composer updates live. On release → stop() ends
//  audio and the final transcription lands in `transcript`. There's also a plain
//  dictation TextField fallback in the composer for when speech auth is denied or
//  recognition is flaky.
//
//  Permissions: request SFSpeechRecognizer.requestAuthorization AND record permission.
//  Info.plist must carry NSSpeechRecognitionUsageDescription + NSMicrophoneUsageDescription.
//

import Foundation
import Speech
import AVFoundation

@MainActor
final class SpeechRecognizer: ObservableObject {

    /// Live (partial) + final transcript text. The composer binds to this.
    @Published var transcript = ""
    @Published private(set) var isRecording = false
    @Published private(set) var isAuthorized = false
    @Published var lastError: String?

    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private let audioEngine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?

    /// Ask for both speech-recognition and microphone permission up front.
    func requestAuthorization() async {
        let speechStatus = await withCheckedContinuation { (cont: CheckedContinuation<SFSpeechRecognizerAuthorizationStatus, Never>) in
            SFSpeechRecognizer.requestAuthorization { cont.resume(returning: $0) }
        }
        let micGranted = await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            // watchOS 10+/iOS 17+ non-deprecated record-permission request.
            AVAudioApplication.requestRecordPermission(completionHandler: { granted in
                cont.resume(returning: granted)
            })
        }
        isAuthorized = (speechStatus == .authorized) && micGranted
        if !isAuthorized {
            lastError = "Speech or mic permission denied — use the keyboard fallback."
        }
    }

    /// Begin live dictation. Call on mic-button press-down.
    func start() {
        guard !isRecording else { return }
        guard isAuthorized, let recognizer, recognizer.isAvailable else {
            lastError = "Speech recognizer unavailable."
            return
        }

        transcript = ""
        lastError = nil

        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.record, mode: .measurement, options: [.duckOthers])
            try session.setActive(true, options: [])

            let request = SFSpeechAudioBufferRecognitionRequest()
            request.shouldReportPartialResults = true
            // On-device when possible keeps latency low and works without network.
            request.requiresOnDeviceRecognition = recognizer.supportsOnDeviceRecognition
            self.request = request

            let input = audioEngine.inputNode
            let format = input.outputFormat(forBus: 0)
            input.removeTap(onBus: 0)
            input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
                self?.request?.append(buffer)
            }

            audioEngine.prepare()
            try audioEngine.start()
            isRecording = true

            task = recognizer.recognitionTask(with: request) { [weak self] result, error in
                guard let self else { return }
                if let result {
                    Task { @MainActor in self.transcript = result.bestTranscription.formattedString }
                }
                if error != nil || (result?.isFinal ?? false) {
                    Task { @MainActor in self.finishAudio() }
                }
            }
        } catch {
            lastError = "Could not start recording: \(error.localizedDescription)"
            finishAudio()
        }
    }

    /// End dictation. Call on mic-button release. Returns the captured text.
    @discardableResult
    func stop() -> String {
        request?.endAudio()
        finishAudio()
        return transcript.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Clear after a prompt is sent.
    func reset() {
        transcript = ""
    }

    private func finishAudio() {
        if audioEngine.isRunning {
            audioEngine.stop()
            audioEngine.inputNode.removeTap(onBus: 0)
        }
        task?.cancel()
        task = nil
        request = nil
        isRecording = false
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
    }
}
