import SwiftUI
import Citadel  // the pure-Swift SSH stack (nio-ssh + BoringSSL) under test

// PHASE 2 DE-RISK SPIKE. The only question this build answers: does Citadel —
// swift-nio-ssh plus its vendored BoringSSL — cross-compile and LINK into an iOS
// binary? The route-B falsifier proved it on Linux; iOS is a different target
// (the exact class that broke libssh2), so this is the cheap kill-test JARVIS
// asked me to front-load before the transport rewrite.
@main
struct HerdrApp: App {
    var body: some Scene {
        WindowGroup { SpikeView() }
    }
}

private struct SpikeView: View {
    var body: some View {
        ZStack {
            Color(red: 1.0, green: 0.0, blue: 0.6).ignoresSafeArea()  // magenta: not any default
            VStack(spacing: 12) {
                Text("CITADEL LINKS").font(.system(size: 30, weight: .heavy, design: .monospaced))
                // Reference real Citadel types so the linker must resolve the
                // whole SSH stack — a screenshot of this proves it linked, not
                // just that an empty app built.
                Text("SSHClient: \(String(describing: SSHClient.self))")
                    .font(.system(size: 11, design: .monospaced))
                Text("auth: \(String(describing: SSHAuthenticationMethod.self))")
                    .font(.system(size: 11, design: .monospaced))
            }
            .foregroundStyle(.white).multilineTextAlignment(.center).padding()
        }
    }
}
