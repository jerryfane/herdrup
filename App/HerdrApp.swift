import SwiftUI
import HerdrKit

/// STEP ONE, AND IT IS DELIBERATELY UGLY.
///
/// This app exists to prove the build loop, not to look like anything. The
/// question it answers is narrow: does pushing a `project.yml` make the buildbox
/// switch from `swiftpm` to `xcodebuild`, generate the project, build it, launch
/// it in the simulator, and publish a screenshot of MY commit?
///
/// Until that is answered, every line of real UI would be written blind against
/// an unverified instrument. Issue #17 is the argument for spending a commit
/// here: three macOS-only defects hid behind each other while Linux reported
/// green throughout, and the only thing that found them was a real build on a
/// real platform.
@main
struct HerdrApp: App {
    var body: some Scene {
        WindowGroup { ProofOfLoop() }
    }
}

private struct ProofOfLoop: View {
    var body: some View {
        ZStack {
            // A COLOUR THE AMBIENT STATE CANNOT PRODUCE.
            //
            // If this screen were dark navy — the app's real ground — a
            // screenshot of it would be indistinguishable from a stale capture,
            // an unlaunched simulator, a black launch image, or a crash to the
            // home screen. Every one of those is a way to read "it worked" off a
            // picture that shows nothing of the sort.
            //
            // Magenta is not in the design's palette, not an iOS default, and
            // not a colour any failure mode produces by accident. Seeing it is
            // evidence; seeing anything else is not ambiguous.
            Color(red: 1.0, green: 0.0, blue: 0.6).ignoresSafeArea()

            VStack(spacing: 14) {
                Text("LOOP PROOF")
                    .font(.system(size: 34, weight: .heavy, design: .monospaced))
                Text("step 1 · nothing here is the design")
                    .font(.system(size: 13, design: .monospaced))

                // PROVES THE LINK, not just the build. Referencing a HerdrKit
                // symbol means a screenshot showing this line rules out the
                // package having been dropped, stubbed, or silently unlinked —
                // which a plain colour fill alone would not.
                Text("HerdrKit linked · \(Self.kitProof)")
                    .font(.system(size: 12, design: .monospaced))
                    .padding(.top, 6)
            }
            .foregroundStyle(.white)
            .multilineTextAlignment(.center)
        }
    }

    /// Exercises a real HerdrKit type end to end. `AgentStatus(wire:)` is pure
    /// value logic with no I/O, so it cannot hang or need a connection, and its
    /// unrecognised case carries the raw string — which makes the rendered text
    /// something only the real implementation produces.
    private static var kitProof: String {
        if case .unrecognised(let raw) = AgentStatus(wire: "loop-proof") { return raw }
        return "UNEXPECTED"
    }
}
