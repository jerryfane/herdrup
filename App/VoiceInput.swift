import AVFoundation
import Speech
import SwiftUI

/// On-device voice dictation for a text field.
///
/// Tap the mic to start, speak, tap again (or it auto-finalizes on a pause) to stop.
/// Recognition runs ON-DEVICE where the device supports it (private, offline); it falls
/// back to Apple's standard speech service only where on-device recognition is not
/// available for the user's locale. The recognized text is exposed as a live transcript;
/// `MicButton` appends it to the bound field so it never erases text already typed.
///
/// Deliberately built on `SFSpeechRecognizer` (works on the iOS 17 floor) rather than
/// iOS 26's `SpeechTranscriber`, so nothing here gates compilation on the Xcode 26 SDK;
/// the newer, more accurate transcriber is a follow-up once the build runner's Xcode is
/// confirmed.
@MainActor
final class SpeechDictator: ObservableObject {
    enum State: Equatable { case idle, recording, denied, unavailable }

    @Published private(set) var state: State = .idle
    /// The live transcript of the CURRENT dictation session (partial results → final).
    @Published private(set) var transcript: String = ""
    /// A user-facing note (permission denied, unavailable), surfaced by `MicButton`.
    @Published private(set) var note: String?

    private let recognizer = SFSpeechRecognizer()  // the user's current locale
    private let engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?

    var isRecording: Bool { state == .recording }

    /// Start a dictation session, requesting mic + speech permission on first use.
    func start() {
        guard state != .recording else { return }
        transcript = ""
        note = nil
        requestPermissions { [weak self] granted in
            guard let self else { return }
            guard granted else {
                self.state = .denied
                self.note = "To dictate, enable Microphone and Speech Recognition for Herdrup in Settings."
                return
            }
            do {
                try self.beginSession()
            } catch {
                self.teardown()
                self.state = .unavailable
                self.note = "Couldn't start dictation. Try again."
            }
        }
    }

    /// Stop the current session and finalize; the transcript stays put.
    func stop() {
        guard state == .recording else { return }
        finishAudio()
        state = .idle
    }

    // MARK: - internals

    private func requestPermissions(_ completion: @escaping (Bool) -> Void) {
        SFSpeechRecognizer.requestAuthorization { auth in
            let speechOK = auth == .authorized
            // AVAudioApplication.requestRecordPermission is the iOS 17+ replacement for
            // the deprecated AVAudioSession.requestRecordPermission.
            AVAudioApplication.requestRecordPermission { micOK in
                Task { @MainActor in completion(speechOK && micOK) }
            }
        }
    }

    private func beginSession() throws {
        guard let recognizer, recognizer.isAvailable else {
            state = .unavailable
            note = "Dictation isn't available right now."
            return
        }

        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.record, mode: .measurement, options: .duckOthers)
        try session.setActive(true, options: .notifyOthersOnDeactivation)

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        // Keep it on-device (private, offline) wherever the device/locale supports it.
        if recognizer.supportsOnDeviceRecognition { request.requiresOnDeviceRecognition = true }
        self.request = request

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak request] buffer, _ in
            request?.append(buffer)
        }
        engine.prepare()
        try engine.start()
        state = .recording

        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self else { return }
            Task { @MainActor in
                if let result { self.transcript = result.bestTranscription.formattedString }
                // Finalize on error or a final result, but only if we're still recording
                // (a manual stop already tore the session down).
                if (error != nil || (result?.isFinal ?? false)), self.state == .recording {
                    self.finishAudio()
                    self.state = .idle
                }
            }
        }
    }

    private func finishAudio() {
        engine.inputNode.removeTap(onBus: 0)
        if engine.isRunning { engine.stop() }
        request?.endAudio()
        task?.finish()
        request = nil
        task = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func teardown() { finishAudio() }
}

/// A mic button that dictates into a bound text field. The recognized text is APPENDED
/// to whatever is already in the field (captured when recording starts), so dictation
/// never erases what the user typed. Idle shows a mic; recording shows a red stop icon.
/// Permission/availability problems surface as a small alert.
struct MicButton: View {
    @Binding var text: String
    /// Idle tint (matches the sibling composer/reply glyphs at each site).
    var tint: Color = Palette.textDim
    /// Circular footprint + glyph size, matched to the sibling buttons at each site
    /// (Gram composer is 38/16; the terminal reply bar is 40/15).
    var diameter: CGFloat = 38
    var iconSize: CGFloat = 16

    @StateObject private var dictator = SpeechDictator()
    /// The field's content when recording started; the transcript is appended after it.
    @State private var base: String = ""
    @State private var showNote = false

    var body: some View {
        Button {
            if dictator.isRecording {
                dictator.stop()
            } else {
                base = text
                dictator.start()
            }
        } label: {
            Image(systemName: dictator.isRecording ? "stop.circle.fill" : "mic.fill")
                .font(.system(size: iconSize, weight: .semibold))
                .foregroundStyle(dictator.isRecording ? Palette.died : tint)
                .frame(width: diameter, height: diameter)
                .background(Circle().fill(Palette.surface))
        }
        .accessibilityLabel(dictator.isRecording ? "Stop dictation" : "Dictate")
        // Live-append the transcript to the bound field as partial results arrive.
        .onChange(of: dictator.transcript) { _, t in
            guard !t.isEmpty else { return }
            text = base.isEmpty ? t : base + " " + t
        }
        .onChange(of: dictator.note) { _, n in showNote = n != nil }
        .alert("Dictation", isPresented: $showNote, presenting: dictator.note) { _ in
            Button("OK", role: .cancel) {}
        } message: { Text($0) }
    }
}
