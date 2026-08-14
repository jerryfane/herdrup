import AVFoundation
import Speech
import SwiftUI

/// On-device voice dictation for a text field.
///
/// Tap the mic to start, speak, tap again (or it auto-finalizes on a pause) to stop.
/// Recognition runs ON-DEVICE ONLY (private, offline); where the device/locale cannot do
/// it on-device, dictation reports unavailable rather than silently sending audio to
/// Apple's servers — so the permission promise ("stays on your phone") is always true.
/// The recognized text is exposed as a live transcript; `MicButton` appends it to the
/// bound field so it never erases text already typed.
///
/// Deliberately built on `SFSpeechRecognizer` (works on the iOS 17 floor) rather than
/// iOS 26's `SpeechTranscriber`, so nothing here gates compilation on the Xcode 26 SDK;
/// the newer transcriber is a follow-up once the build runner's Xcode is confirmed.
@MainActor
final class SpeechDictator: ObservableObject {
    enum State: Equatable { case idle, requesting, recording, denied, unavailable }

    @Published private(set) var state: State = .idle
    /// The live transcript of the CURRENT dictation session (partial results → final).
    @Published private(set) var transcript: String = ""
    /// A user-facing note (permission denied, unavailable), surfaced by `MicButton`.
    @Published private(set) var note: String?

    private let recognizer = SFSpeechRecognizer()  // the user's current locale
    private let engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    /// Bumped for every session and on every stop/finalize. An in-flight recognition
    /// callback captures its generation and no-ops if it no longer matches, so a stale
    /// callback from a finished session can't touch a newer one.
    private var generation = 0

    var isRecording: Bool { state == .recording }

    /// Start a dictation session, requesting mic + speech permission on first use.
    func start() {
        // Block re-entry while a start is already in flight or a session is live: a rapid
        // double-tap would otherwise install a SECOND tap on the input node (a crash) and
        // spawn a second recognition task.
        guard state != .requesting, state != .recording else { return }
        transcript = ""
        note = nil
        state = .requesting
        requestPermissions { [weak self] granted in
            guard let self else { return }
            // A stop() (or another start) may have superseded this request meanwhile.
            guard self.state == .requesting else { return }
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
        guard state == .recording || state == .requesting else { return }
        generation &+= 1   // invalidate any in-flight callbacks from this session
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
        // On-device ONLY — we never fall back to Apple's server recognition, so the
        // "stays on your phone" permission copy holds for every path.
        guard recognizer.supportsOnDeviceRecognition else {
            state = .unavailable
            note = "On-device dictation isn't available for your language on this device."
            return
        }

        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.record, mode: .measurement, options: .duckOthers)
        try session.setActive(true, options: .notifyOthersOnDeactivation)

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = true
        self.request = request

        generation &+= 1
        let gen = generation

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
                // Ignore a callback that belongs to a session we've already torn down.
                guard gen == self.generation, self.state == .recording else { return }
                if let result { self.transcript = result.bestTranscription.formattedString }
                if error != nil || (result?.isFinal ?? false) {
                    self.generation &+= 1
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
        task?.cancel()
        request = nil
        task = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func teardown() { finishAudio() }
}

/// A mic button that dictates into a bound text field. The recognized text is APPENDED
/// to whatever is already in the field (captured when recording starts), so dictation
/// never erases what the user typed. Idle shows a mic; recording shows a red stop icon.
/// Recording auto-stops when the app backgrounds, when the enclosing surface goes
/// inactive (a keep-mounted terminal pane that is no longer front — so the mic is never
/// hot behind a hidden pane), or when the button leaves the hierarchy.
struct MicButton: View {
    @Binding var text: String
    /// Idle tint (matches the sibling composer/reply glyphs at each site).
    var tint: Color = Palette.textDim
    /// Circular footprint + glyph size, matched to the sibling buttons at each site
    /// (Gram composer is 38/16; the terminal reply bar is 40/15).
    var diameter: CGFloat = 38
    var iconSize: CGFloat = 16
    /// False when the enclosing surface is backgrounded (e.g. a keep-mounted terminal
    /// pane that is no longer front): recording auto-stops so the mic never runs hidden.
    var isActive: Bool = true
    /// Mirrors the live recording state out to the parent (used to disable the field
    /// while dictating and to suppress the terminal's ctrl-chord interception).
    var recording: Binding<Bool>?
    /// Called when a dictation session begins — e.g. to disarm a pending ctrl chord.
    var onStart: () -> Void = {}

    @Environment(\.scenePhase) private var scenePhase
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
                onStart()
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
        .onChange(of: dictator.isRecording) { _, r in recording?.wrappedValue = r }
        .onChange(of: isActive) { _, active in if !active { dictator.stop() } }
        .onChange(of: scenePhase) { _, phase in if phase != .active { dictator.stop() } }
        .onDisappear { dictator.stop() }
        .onChange(of: dictator.note) { _, n in showNote = n != nil }
        .alert("Dictation", isPresented: $showNote, presenting: dictator.note) { _ in
            Button("OK", role: .cancel) {}
        } message: { Text($0) }
    }
}
