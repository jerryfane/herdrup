import Accelerate
import AVFoundation
import HerdrKit
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

    /// Chosen when a session starts (see `DictationLocale`), so a language the user sets
    /// up while the app is running is picked up without a relaunch.
    private var recognizer: SFSpeechRecognizer?
    private let engine = AVAudioEngine()
    /// The recognition request the audio tap feeds. Held in a lock-guarded box because
    /// the tap runs on an audio thread and the request is SWAPPED on every segment roll
    /// (see `rollSegment`) while the engine + tap keep running uninterrupted.
    private let box = RequestBox()
    private var task: SFSpeechRecognitionTask?
    /// Finalized segments so far this session. Keeps the exposed `transcript` MONOTONIC —
    /// it never loses its head when the recognizer re-segments near its ceiling.
    private var accumulator = TranscriptAccumulator()
    /// The current segment's latest best transcription, not yet committed.
    private var lastPartial = ""
    /// A segment we rolled away from whose OWN final result has not landed yet: its last
    /// partial is shown provisionally so the screen never flickers, then its full final (the
    /// tail the old task keeps recognising after the swap) replaces it. Assumes one rolled
    /// segment finalizes before the next ~50s roll — true given on-device finals arrive in
    /// ~1s.
    private var pending = ""
    /// Generation of the segment whose text is in `pending`, so its own (non-active) final
    /// commits exactly once and a rare pause-at-a-roll-boundary can't double-commit it.
    private var pendingGen: Int?
    /// Consecutive error-driven rolls with no successful result between them. Capped so a
    /// PERSISTENT failure (asset evicted, dictation disabled mid-session) stops with a note
    /// instead of churning new tasks forever.
    private var errorRolls = 0
    /// Rolls the recognition task over before `SFSpeechRecognizer`'s ~1-minute audio
    /// ceiling, so it never reaches the window where it would drop earlier text.
    private var rollTimer: Timer?
    /// Seconds a single recognition task runs before we commit + restart it — under
    /// Apple's ~60s ceiling with margin.
    private let segmentSeconds: TimeInterval = 50
    /// Bumped on every stop/finalize/roll. An in-flight recognition callback captures its
    /// generation and no-ops if it no longer matches, so a stale callback from a retired
    /// task can't touch a newer one.
    private var generation = 0
    /// Receives the input level (RMS of each tapped buffer) on the main actor while
    /// recording, for the composer's waveform and glow. Measured in the tap that already
    /// feeds recognition, so it costs no second audio path.
    var levelHandler: ((Float) -> Void)? {
        get { levelRelay.handler }
        set { levelRelay.handler = newValue }
    }
    private let levelRelay = VoiceLevelRelay()

    var isRecording: Bool { state == .recording }
    /// Busy from the moment the mic is tapped (permission acquisition) through recording.
    /// Callers gate Send on this so a rapid Send DURING permission acquisition can't clear
    /// the field out from under a session that is about to start (and then have the next
    /// partial restore the just-sent text).
    var isBusy: Bool { state == .recording || state == .requesting }

    /// Start a dictation session, requesting mic + speech permission on first use.
    func start() {
        // Block re-entry while a start is already in flight or a session is live: a rapid
        // double-tap would otherwise install a SECOND tap on the input node (a crash) and
        // spawn a second recognition task.
        guard state != .requesting, state != .recording else { return }
        accumulator.reset()
        lastPartial = ""
        pending = ""
        pendingGen = nil
        errorRolls = 0
        transcript = ""
        note = nil
        state = .requesting
        requestPermissions { [weak self] granted in
            guard let self else { return }
            // A stop() (or another start) may have superseded this request meanwhile.
            guard self.state == .requesting else { return }
            guard granted else {
                self.state = .denied
                self.note = "To dictate, enable Microphone and Speech Recognition for herdrup in Settings."
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
        let choice = DictationLocale.choose()
        recognizer = choice.recognizer
        guard let recognizer else {
            state = .unavailable
            note = choice.unavailableNote
            return
        }

        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.record, mode: .measurement, options: .duckOthers)
        try session.setActive(true, options: .notifyOthersOnDeactivation)

        // The tap runs for the WHOLE dictation and feeds whatever request is current in
        // the box; only the request + task are swapped on a segment roll, never the engine.
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        let box = self.box
        let relay = levelRelay
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            box.append(buffer)
            relay.publish(VoiceLevelRelay.rms(of: buffer))
        }
        // Ready the first request BEFORE the engine runs, so the very first audio buffers
        // have a request to go to (the box is otherwise nil for a beat and drops them).
        state = .recording
        startSegment(recognizer: recognizer)
        engine.prepare()
        try engine.start()

        // Roll the recognition task over before SFSpeechRecognizer's ~1-minute ceiling.
        // segmentSeconds keeps ~10s of margin under it; that margin is a heuristic — the
        // pure TranscriptAccumulator tests can't cover the driver committing before a
        // within-segment shrink, so it's tuned conservatively.
        rollTimer = Timer.scheduledTimer(withTimeInterval: segmentSeconds, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.rollSegment() }
        }
    }

    /// Begin one recognition segment: a fresh request + task on the already-running engine.
    /// The OUTGOING task is NOT cancelled — `box.set` ends its request so it delivers a full
    /// FINAL result (the tail it was still recognising after the swap), which the callback
    /// commits. Cancelling would discard that final and re-introduce the per-roll boundary
    /// loss this avoids.
    private func startSegment(recognizer: SFSpeechRecognizer) {
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = true
        box.set(request)   // ends the previous request (it finalizes), routes audio here
        lastPartial = ""

        generation &+= 1
        let gen = generation
        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self else { return }
            Task { @MainActor in
                guard self.state == .recording else { return }
                let isActive = (gen == self.generation)
                if let result {
                    self.errorRolls = 0          // a result means we're making progress
                    let text = result.bestTranscription.formattedString
                    if result.isFinal {
                        if isActive {
                            // Active segment finalized on a natural pause: commit it and keep
                            // going (a pause no longer stops dictation).
                            if let pg = self.pendingGen, pg != gen {
                                self.accumulator.commit(self.pending)   // an earlier provisional
                            }
                            self.pending = ""; self.pendingGen = nil
                            self.accumulator.commit(text)
                            self.lastPartial = ""
                            self.transcript = self.accumulator.committed
                            self.startSegment(recognizer: recognizer)
                        } else if self.pendingGen == gen {
                            // The segment we rolled away from delivered its FULL final (incl.
                            // the tail): commit the whole thing, replacing its provisional.
                            self.accumulator.commit(text)
                            self.pending = ""; self.pendingGen = nil
                            self.refreshTranscript()
                        }
                        // a non-active final for an already-committed segment: ignore.
                    } else if isActive {
                        self.lastPartial = text
                        self.refreshTranscript()
                    }
                    // Partials from a non-active (finalizing) segment are ignored.
                } else if error != nil, isActive {
                    // Roll on error (routinely the ceiling), but CAP consecutive error-rolls
                    // so a persistent failure stops with feedback instead of churning forever.
                    self.errorRolls += 1
                    if self.errorRolls >= 3 {
                        self.note = "Dictation stopped. Tap the mic to start again."
                        self.stop()
                    } else {
                        self.rollSegment()
                    }
                }
            }
        }
    }

    /// Roll to a fresh segment before the recognizer's ceiling. The current segment's text is
    /// kept on screen as `pending` (so nothing flickers) and its task is left to FINALIZE;
    /// its full final commits in the callback above and supersedes the provisional.
    private func rollSegment() {
        guard state == .recording, let recognizer else { return }
        let rolledGen = generation
        pending = [pending, lastPartial].filter { !$0.isEmpty }.joined(separator: " ")
        pendingGen = rolledGen
        lastPartial = ""
        startSegment(recognizer: recognizer)   // box.set ends the rolled request -> it finalizes
    }

    /// Rebuild the displayed transcript: committed + the provisional rolled segment + the
    /// active partial. Never shorter than `committed`.
    private func refreshTranscript() {
        let tail = [pending, lastPartial].filter { !$0.isEmpty }.joined(separator: " ")
        transcript = accumulator.text(withPartial: tail)
    }

    private func finishAudio() {
        rollTimer?.invalidate()
        rollTimer = nil
        engine.inputNode.removeTap(onBus: 0)
        if engine.isRunning { engine.stop() }
        // Keep everything on screen: fold the provisional rolled segment AND the last live
        // partial into `committed` before tearing down (makes `transcript` self-consistent).
        let tail = [pending, lastPartial].filter { !$0.isEmpty }.joined(separator: " ")
        if !tail.isEmpty { accumulator.commit(tail) }
        transcript = accumulator.committed
        lastPartial = ""
        pending = ""
        pendingGen = nil
        box.set(nil)   // ends the current request
        task?.cancel()
        task = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func teardown() { finishAudio() }
}

/// Which language dictation listens in.
///
/// `SFSpeechRecognizer()` uses the region format locale alone. That is often not a
/// language the phone can transcribe on-device: an English phone set to an Italian
/// region is "en_IT", and an on-device model exists only for the languages whose
/// Dictation assets are installed. Try, in order, the region locale, the preferred
/// languages, then the keyboards in use, mapping each to a locale the recognizer
/// supports. Take the first that is available and can run on-device. We never fall back
/// to Apple's servers: the permission copy promises speech stays on the phone.
enum DictationLocale {
    struct Choice {
        let recognizer: SFSpeechRecognizer?
        let unavailableNote: String
    }

    @MainActor
    static func choose() -> Choice {
        let supported = SFSpeechRecognizer.supportedLocales()
        var tried = Set<String>()
        var languages: [String] = []
        var installedButBusy = false
        for candidate in candidates() {
            for locale in ranked(candidate, in: supported) where tried.insert(locale.identifier).inserted {
                guard let recognizer = SFSpeechRecognizer(locale: locale),
                      recognizer.supportsOnDeviceRecognition else { continue }
                if recognizer.isAvailable { return Choice(recognizer: recognizer, unavailableNote: "") }
                installedButBusy = true
            }
            if let code = candidate.language.languageCode?.identifier, !languages.contains(code) {
                languages.append(code)
            }
        }
        if installedButBusy {
            return Choice(recognizer: nil, unavailableNote: "Dictation isn't available right now.")
        }
        let names = languages.prefix(2).compactMap { Locale.current.localizedString(forLanguageCode: $0) }
        let language = names.isEmpty ? "your language" : names.joined(separator: " or ")
        return Choice(
            recognizer: nil,
            unavailableNote: "On-device dictation isn't set up for \(language). Turn on Dictation in "
                + "Settings › General › Keyboard, let the language download, then try again.")
    }

    /// Locales to try, most specific first, without duplicates.
    @MainActor
    static func candidates() -> [Locale] {
        var identifiers = [Locale.current.identifier]
        identifiers += Locale.preferredLanguages
        identifiers += UITextInputMode.activeInputModes.compactMap(\.primaryLanguage)
        var seen = Set<String>()
        return identifiers
            .filter { $0 != "dictation" && $0 != "emoji" }
            .compactMap { seen.insert($0).inserted ? Locale(identifier: $0) : nil }
    }

    /// Every supported locale in `wanted`'s language, best first: the same region, then
    /// the phone's own region, then the rest in a stable order. Only some of these have
    /// an on-device model, so the caller tries them in turn.
    static func ranked(_ wanted: Locale, in supported: Set<Locale>) -> [Locale] {
        guard let language = wanted.language.languageCode?.identifier else { return [] }
        func region(_ locale: Locale) -> String? { locale.region?.identifier }
        func rank(_ locale: Locale) -> Int {
            if region(locale) == region(wanted) { return 0 }
            if region(locale) == region(Locale.current) { return 1 }
            return 2
        }
        return supported
            .filter { $0.language.languageCode?.identifier == language }
            .sorted { (rank($0), $0.identifier) < (rank($1), $1.identifier) }
    }
}

/// Thread-safe holder for the current recognition request. The audio tap (an audio thread)
/// appends buffers through this while the main actor SWAPS the request on each segment roll.
/// A single `NSLock` around one reference is enough — append and set never contend for long.
private final class RequestBox: @unchecked Sendable {
    private let lock = NSLock()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    /// Install a new request (or nil to clear); ends the one it replaces so its recognizer
    /// finalizes rather than leaking the audio pipeline.
    func set(_ r: SFSpeechAudioBufferRecognitionRequest?) {
        lock.lock(); let old = request; request = r; lock.unlock()
        old?.endAudio()
    }
    func append(_ buffer: AVAudioPCMBuffer) {
        lock.lock(); let r = request; lock.unlock()
        r?.append(buffer)
    }
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
    /// False when the enclosing surface is backgrounded (e.g. a keep-mounted terminal
    /// pane that is no longer front): recording auto-stops so the mic never runs hidden.
    var isActive: Bool = true
    /// Mirrors the live recording state out to the parent (used to disable the field
    /// while dictating and to suppress the terminal's ctrl-chord interception).
    var recording: Binding<Bool>?
    /// Called when a dictation session begins — e.g. to disarm a pending ctrl chord.
    var onStart: () -> Void = {}

    @Environment(\.scenePhase) private var scenePhase
    /// The enclosing composer's level meter, when there is one; it drives the waveform
    /// and the glowing border.
    @Environment(VoiceLevelMeter.self) private var meter: VoiceLevelMeter?
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
                let meter = meter
                dictator.levelHandler = { level in meter?.push(level) }
                dictator.start()
            }
        } label: {
            ZStack {
                if dictator.state == .requesting {
                    ProgressView().controlSize(.small).tint(Palette.textDim)
                        .frame(width: 44, height: 44)
                } else {
                    ComposerActionIcon(
                        image: dictator.isRecording ? Image(systemName: "stop.circle.fill") : Image("ComposerMic"),
                        tint: dictator.isRecording ? Palette.died : tint
                    )
                    .contentTransition(.symbolEffect(.replace))
                }
            }
            .animation(.spring(response: 0.3, dampingFraction: 0.75), value: dictator.state)
        }
        .buttonStyle(.plain)
        .background { if dictator.isRecording { VoiceRipples() } }
        .accessibilityLabel(dictator.isRecording ? "Stop dictation" : "Dictate")
        .sensoryFeedback(.impact(flexibility: .soft, intensity: 0.7), trigger: dictator.isRecording)
        // Live-append the transcript to the bound field as partial results arrive.
        .onChange(of: dictator.transcript) { _, t in
            guard !t.isEmpty else { return }
            text = base.isEmpty ? t : base + " " + t
        }
        // Mirror BUSY (requesting-or-recording), so the parent gates Send from the moment
        // the mic is tapped — not only once recognition is live.
        .onChange(of: dictator.state) { _, state in
            recording?.wrappedValue = dictator.isBusy
            if state == .recording { meter?.begin() } else if !dictator.isBusy { meter?.end() }
        }
        .onChange(of: isActive) { _, active in if !active { dictator.stop() } }
        .onChange(of: scenePhase) { _, phase in if phase != .active { dictator.stop() } }
        .onDisappear { dictator.stop() }
        .onChange(of: dictator.note) { _, n in showNote = n != nil }
        .alert("Dictation", isPresented: $showNote, presenting: dictator.note) { _ in
            Button("OK", role: .cancel) {}
        } message: { Text($0) }
    }
}
