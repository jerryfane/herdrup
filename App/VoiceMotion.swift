import Accelerate
import AVFoundation
import Observation
import SwiftUI

/// Carries input levels from the audio tap (a realtime thread) to the main actor.
///
/// Delivery is coalesced: while one level is waiting for the main actor, newer ones only
/// replace it, so a busy main thread never builds a queue of stale levels.
final class VoiceLevelRelay: @unchecked Sendable {
    private let lock = NSLock()
    private var pending: Float?
    @MainActor var handler: ((Float) -> Void)?

    func publish(_ level: Float) {
        lock.lock()
        let scheduled = pending != nil
        pending = level
        lock.unlock()
        guard !scheduled else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.lock.lock()
            let latest = self.pending
            self.pending = nil
            self.lock.unlock()
            if let latest { self.handler?(latest) }
        }
    }

    /// Root-mean-square amplitude of the first channel, 0…1.
    static func rms(of buffer: AVAudioPCMBuffer) -> Float {
        guard let samples = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return 0 }
        var value: Float = 0
        vDSP_rmsqv(samples, 1, &value, vDSP_Length(buffer.frameLength))
        return value
    }
}

/// The composer's view of the microphone while dictating: a smoothed level (fast attack,
/// slower release) and a short history for the scrolling waveform. Main-thread only:
/// levels arrive through `VoiceLevelRelay`, which delivers on the main actor.
@Observable
final class VoiceLevelMeter {
    /// 0…1, perceptual (roughly logarithmic) and smoothed.
    private(set) var level: CGFloat = 0
    /// Recent levels, newest last, sampled at about 30 Hz.
    private(set) var history: [CGFloat] = []
    private(set) var startedAt: Date?
    @ObservationIgnored private var lastSample = Date.distantPast

    static let historyLength = 120

    func begin() {
        level = 0
        history = []
        startedAt = .now
        lastSample = .distantPast
    }

    func end() {
        startedAt = nil
        level = 0
    }

    func push(_ rms: Float) {
        guard startedAt != nil else { return }
        // Speech RMS sits around 0.01–0.2; map about -50…-10 dBFS onto 0…1.
        let decibels = 20 * log10(max(Double(rms), 1e-6))
        let target = CGFloat(min(1, max(0, (decibels + 50) / 40)))
        level += (target - level) * (target > level ? 0.6 : 0.2)
        let now = Date.now
        guard now.timeIntervalSince(lastSample) >= 1.0 / 30 else { return }
        lastSample = now
        history.append(level)
        if history.count > Self.historyLength { history.removeFirst(history.count - Self.historyLength) }
    }
}

/// While recording: a red dot, the scrolling waveform of the input level, and a timer.
struct VoiceWaveformStrip: View {
    @Environment(VoiceLevelMeter.self) private var meter: VoiceLevelMeter?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var blink = false

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(Palette.died)
                .frame(width: 8, height: 8)
                .opacity(blink ? 0.3 : 1)
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.6).repeatForever(autoreverses: true),
                           value: blink)
                .onAppear { blink = !reduceMotion }
            Canvas(opaque: false, rendersAsynchronously: false) { context, size in
                Self.drawBars(meter?.history ?? [], in: context, size: size)
            }
            .frame(height: 22)
            if let start = meter?.startedAt {
                Text(timerInterval: start...Date.distantFuture, countsDown: false)
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .monospacedDigit()
                    .foregroundStyle(Palette.textFaint)
                    .fixedSize()
            }
        }
        .frame(height: ComposerStyle.lineHeight)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Recording")
        .accessibilityIdentifier("composer-recording-waveform")
    }

    /// Bars scroll in from the right: the newest sample is the rightmost bar, and older
    /// ones fade as they move left.
    static func drawBars(_ history: [CGFloat], in context: GraphicsContext, size: CGSize) {
        let barWidth: CGFloat = 3, step: CGFloat = 5
        let count = Int(size.width / step)
        guard count > 0 else { return }
        for index in 0..<min(count, history.count) {
            let value = history[history.count - 1 - index]
            let height = max(2, value * size.height)
            let rect = CGRect(x: size.width - CGFloat(index + 1) * step + (step - barWidth),
                              y: (size.height - height) / 2, width: barWidth, height: height)
            let recent = index < 2
            let fade = recent ? 1 : max(0.3, 1 - Double(index) / Double(count))
            context.fill(Path(roundedRect: rect, cornerRadius: barWidth / 2),
                         with: .color((recent ? Palette.text : Palette.textDim).opacity(fade)))
        }
    }
}

/// The composer border while recording: a slowly turning red–ink–amber gradient whose
/// glow grows with the voice. The ripples are `VoiceRipples`, behind the stop button.
struct VoiceGlowBorder: View {
    let cornerRadius: CGFloat
    @Environment(VoiceLevelMeter.self) private var meter: VoiceLevelMeter?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        let level = meter?.level ?? 0
        Group {
            if reduceMotion {
                shape.strokeBorder(Palette.died.opacity(0.8), lineWidth: 1.5)
            } else {
                TimelineView(.animation) { timeline in
                    let seconds = timeline.date.timeIntervalSinceReferenceDate
                    // The turn speeds up with the voice: about 40°/s at rest, 180°/s loud.
                    let angle = Angle.degrees((seconds * (40 + 140 * Double(level))).truncatingRemainder(dividingBy: 360))
                    shape.strokeBorder(
                        AngularGradient(colors: [Palette.died, Palette.text.opacity(0.55), Palette.died.opacity(0.25),
                                                 Palette.waiting.opacity(0.7), Palette.died],
                                        center: .center, angle: angle),
                        lineWidth: 1.5)
                }
            }
        }
        .shadow(color: Palette.died.opacity(0.12 + 0.35 * level), radius: 8 + 24 * level)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// Rings that leave the stop button on loud moments while recording.
struct VoiceRipples: View {
    @Environment(VoiceLevelMeter.self) private var meter: VoiceLevelMeter?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var ripples: [UUID] = []
    @State private var lastRipple = Date.distantPast

    var body: some View {
        ZStack {
            ForEach(ripples, id: \.self) { _ in RippleRing() }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .onChange(of: meter?.level ?? 0) { _, level in
            let now = Date.now
            guard !reduceMotion, level > 0.55, now.timeIntervalSince(lastRipple) > 0.21 else { return }
            lastRipple = now
            let id = UUID()
            ripples.append(id)
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(950))
                ripples.removeAll { $0 == id }
            }
        }
    }

    private struct RippleRing: View {
        @State private var grown = false

        var body: some View {
            Circle()
                .stroke(Palette.died, lineWidth: 1.5)
                .frame(width: 40, height: 40)
                .scaleEffect(grown ? 2.3 : 0.8)
                .opacity(grown ? 0 : 0.55)
                .onAppear { withAnimation(.easeOut(duration: 0.9)) { grown = true } }
        }
    }
}