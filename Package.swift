// swift-tools-version:5.9
import PackageDescription

// HerdrKit is the transport + protocol layer for the iOS herdr client.
//
// It deliberately contains NO UIKit/SwiftUI so it builds and tests on Linux,
// where it can be exercised against a real herdr server. The iOS target
// consumes it unchanged.
let package = Package(
    name: "HerdrKit",
    // REQUIRED, and its absence was invisible from Linux. With no `platforms`,
    // SwiftPM assumes macOS 10.10 and every modern-concurrency symbol this
    // package is built on becomes unavailable — Task, AsyncThrowingStream,
    // CancellationError, withTaskCancellationHandler, and the rest. Linux does
    // no availability checking at all, so the package compiled there while
    // being unbuildable on any Apple platform.
    //
    // The floors are chosen, not defaults: macOS 14 for the toolchain that runs
    // the tests (Citadel requires .macOS(.v14); a v13 floor fails `swift build`
    // on macOS with a dependency-floor mismatch — invisible on Linux, which
    // ignores `platforms:` entirely), iOS 17 because that is the floor the app
    // target will inherit and it decides which SwiftUI is available to the UI
    // work (and it matches Citadel's iOS floor, which is why iOS already builds).
    // `platforms` constrains Apple platforms only, so the "builds on Linux too"
    // property above is untouched.
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "HerdrKit", targets: ["HerdrKit"])
    ],
    dependencies: [
        // The pure-Swift SSH stack (swift-nio-ssh + Citadel's key parsing and
        // BoringSSL crypto). Cross-platform — this is what lets HerdrKit link
        // into iOS, which libssh2 cannot. Pinned exactly: Citadel pulls a
        // swift-nio-ssh FORK (Wellz26/swift-nio-ssh), and a fork carrying the
        // transport's crypto is worth a fixed, reviewed revision rather than a
        // range. Proven to build+link for iOS-simulator (spike/citadel-ios).
        .package(url: "https://github.com/orlandos-nl/Citadel.git", exact: "0.12.1"),
    ],
    targets: [
        // libssh2 is gone: CitadelTransport (pure-Swift nio-ssh + Citadel)
        // replaced SSHTransport, and with it CSSH, DescriptorAudit, LiveChannel
        // and the fd-ownership thread pool. This is what lets HerdrKit build for
        // iOS at all — the libssh2 XCFramework could not link there.
        .target(
            name: "HerdrKit",
            dependencies: [.product(name: "Citadel", package: "Citadel")]),
        // `AgentActivityState` IS A TEST DEPENDENCY HERE, and it is the mechanical
        // cross-check I previously reported as impossible. The forcing argument against
        // sharing these types is about the SHIPPED binaries — the widget links only
        // WidgetKit/SwiftUI/ActivityKit and cannot link HerdrKit, and a HerdrKit dependency
        // would duplicate Shared's symbols in the app binary. NEITHER CONSTRAINT REACHES A
        // TEST TARGET, which is linked into the test bundle and into nothing else. So the
        // two duplicated wording tables, and HerdrKit's activity mapping against the state
        // type it feeds, can both be pinned by real assertions instead of a "change both"
        // comment. Reported as unfixable in note 102391; a reviewer showed it was one word.
        .testTarget(
            name: "HerdrKitTests",
            dependencies: ["HerdrKit", "AgentActivityState",
                           .product(name: "Citadel", package: "Citadel")]),
        // The Live Activity's ContentState, compiled WITHOUT ActivityKit so it can be
        // tested on Linux. `sources` names the one file deliberately: its sibling in the
        // same directory imports ActivityKit and must stay out of this target.
        //
        // Nothing links this product. The Xcode app and widget targets compile the whole
        // Shared directory as sources, exactly as before, so these symbols are not in
        // either binary twice. The target exists ONLY so the tests below can run: while
        // these types were nested in the ActivityKit-importing file, a one-line revert in
        // LiveActivityController reintroduced a shipped defect and survived everything.
        .target(
            name: "AgentActivityState",
            path: "Shared",
            sources: ["AgentActivityState.swift"]),
        .testTarget(
            name: "AgentActivityStateTests",
            dependencies: ["AgentActivityState"]),
    ]
)
