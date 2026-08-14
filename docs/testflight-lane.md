# TestFlight / App Store distribution lane (Herdrup)

How a signed build of the herdr iOS app (`com.jerryfane.herdr`, marketed **Herdrup**)
reaches TestFlight. The app is authored on Linux; the archive runs on a Mac, so the
lane is reviewable in-repo config + a workflow, not Xcode-UI state.

## Primary lane — headless GitHub Actions (no developer Mac)

`.github/workflows/testflight.yml` (GitHub Actions, macOS runner), on
`workflow_dispatch` or a `v*` tag:

- **Signs AUTOMATICALLY**: the archive/export run `xcodebuild -allowProvisioningUpdates`
  with the App Store Connect API key, so Xcode creates/renews the App Store provisioning
  profiles on demand — for the app AND its widget extension. The shared team **distribution
  certificate** is still imported from the `testflight` GitHub **Environment** into a
  throwaway keychain; only the per-bundle PROFILES are automatic (no hand-minted profile).
- Uses the **`Distribution` build configuration** (project.yml), which inherits the base
  automatic signing scoped to the Herdr **app target** — the signing settings live on the
  target, not the xcodebuild command line, so they never touch the SwiftPM dependency
  targets (swift-crypto / swift-nio via Citadel), libraries that "do not support
  provisioning profiles" and would otherwise fail the archive.
- Archives → exports → uploads → **verifies at the destination**: polls `/v1/builds`
  and requires the build to reach `READY_FOR_BETA_TESTING` / `IN_BETA_TESTING` (failing
  loudly on `FAILED` / `INVALID` / `MISSING_EXPORT_COMPLIANCE`), so a green run always
  means the build actually arrived — not just that the pipeline was green.
- **No developer Mac touches the signing material.** The Apple **Distribution
  certificate** is a team-wide cert (shared across the owner's apps), imported from the
  Environment; the **provisioning profiles are created by Xcode on demand** at archive
  time via `-allowProvisioningUpdates` + the App Store Connect API key — for
  `com.jerryfane.herdr` and its widget extension, with no hand-minted profile to maintain.

**Environment secrets** (`testflight`, scoped to main + `v*` tags — a feature-branch
run cannot read them): `DIST_CERT_P12_BASE64`, `DIST_CERT_PASSWORD`,
`KEYCHAIN_PASSWORD`, `APPLE_TEAM_ID`, `APP_STORE_CONNECT_ISSUER_ID`,
`APP_STORE_CONNECT_KEY_ID`, `APP_STORE_CONNECT_P8_BASE64`. (The old
`PROVISIONING_PROFILE_BASE64` / `PROVISIONING_PROFILE_NAME` are no longer used — the
profiles are automatic now.)

## Signing config (project.yml)

- Base `DEVELOPMENT_TEAM: FXQ5Z9HHY6` + `CODE_SIGN_STYLE: Automatic` — **inert for the
  buildbox's iphonesimulator build** (the simulator is never code-signed).
- `Distribution` config (release-type): **inherits the base automatic signing** (it no
  longer overrides to manual). Used by the CI archive, which passes
  `-allowProvisioningUpdates` + the ASC key so Xcode manages the profiles.
- `Release` also automatic — it belongs to the Mac fallback lane.

## Export compliance

`ITSAppUsesNonExemptEncryption = false` (project.yml). herdr uses only standard,
published encryption (AES/SSH via a standard library — no proprietary or custom crypto),
which qualifies for the standard mass-market exemption (EAR Category 5 Part 2) — the
declaration used by essentially every SSH client on the App Store. Owner-approved
determination, 2026-08-05. The stricter `true` value was tried first but requires a full
CCATS filing to upload (App Store Connect altool error 90592), disproportionate for a
standard-encryption test build. A public App Store release should confirm the
self-classification paperwork with a compliance specialist. The CI verifier still fails
loudly on `MISSING_EXPORT_COMPLIANCE` as a backstop, but with `false` an internal build
goes straight to testable. See Apple's [export-compliance guidance](https://developer.apple.com/documentation/security/complying-with-encryption-export-regulations).

## Fallback — run on a Mac by hand

`scripts/testflight.sh` archives the **`Release`** config with **automatic** signing via
a Mac's signed-in Xcode account (`-allowProvisioningUpdates`) and exports/uploads through
that same account (no API key). Use it only when building on a Mac without the CI; it is
independent of the CI's `Distribution` config. `TESTFLIGHT_UPLOAD=1 scripts/testflight.sh`
uploads; a plain run is a signing dry-run.

## What the owner set up (one-time)

1. The App Store Connect **app record** for `com.jerryfane.herdr` (name Herdrup) —
   created in the ASC web UI, because Apple's API forbids app creation (POST /v1/apps →
   403; GET/UPDATE only).
2. The `testflight` environment **secrets** (the seven above; the private keys never
   transit a pane/transcript — written repo-to-repo).
3. (No per-build export-compliance answer is needed — `ITSAppUsesNonExemptEncryption =
   false` declares the standard-encryption exemption up front, so internal builds are
   testable on upload.)

The bundle id and the shared distribution certificate are set up once; the App Store
provisioning profiles are created automatically by Xcode at archive time (no hand-minted
profile).

## Verification

- Every change must keep the buildbox iphonesimulator build green at the exact head (the
  signing config is inert there).
- The full archive/export/upload + the destination check run on GitHub Actions from
  **main** (the environment secrets are gated to main + `v*` tags), so a run on main is
  the end-to-end gate.
