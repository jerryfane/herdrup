# TestFlight / App Store distribution lane (Herdrup)

How a signed build of the herdr iOS app (`com.jerryfane.herdr`, marketed **Herdrup**)
reaches TestFlight. The app is authored on Linux; the archive runs on a Mac, so the
lane is reviewable in-repo config + a workflow, not Xcode-UI state.

## Primary lane — headless GitHub Actions (no developer Mac)

`.github/workflows/testflight.yml` (GitHub Actions, macOS runner), on
`workflow_dispatch` or a `v*` tag:

- **Signs MANUALLY** from a distribution certificate + provisioning profile imported
  from the repo's `testflight` GitHub **Environment** into a throwaway keychain.
- Uses a **dedicated `Distribution` build configuration** (project.yml) so the manual
  profile is scoped to the Herdr **app target** and never touches the SwiftPM
  dependency targets (swift-crypto / swift-nio via Citadel) — libraries that "do not
  support provisioning profiles" and would otherwise fail the archive.
- Archives → exports → uploads → **verifies at the destination**: polls `/v1/builds`
  and requires the build to reach `READY_FOR_BETA_TESTING` / `IN_BETA_TESTING` (failing
  loudly on `FAILED` / `INVALID` / `MISSING_EXPORT_COMPLIANCE`), so a green run always
  means the build actually arrived — not just that the pipeline was green.
- **No developer Mac touches the signing material.** The Apple **Distribution
  certificate + provisioning profile are created on Linux** via `openssl` + the App
  Store Connect API key (the recipe the keephair seat proved). The team distribution
  cert is shared across the owner's apps; herdr's profile is `Herdrup App Store`
  against `com.jerryfane.herdr`.

**Environment secrets** (`testflight`, scoped to main + `v*` tags — a feature-branch
run cannot read them): `DIST_CERT_P12_BASE64`, `DIST_CERT_PASSWORD`,
`KEYCHAIN_PASSWORD`, `APPLE_TEAM_ID`, `APP_STORE_CONNECT_ISSUER_ID`,
`APP_STORE_CONNECT_KEY_ID`, `APP_STORE_CONNECT_P8_BASE64`, `PROVISIONING_PROFILE_BASE64`,
`PROVISIONING_PROFILE_NAME`.

## Signing config (project.yml)

- Base `DEVELOPMENT_TEAM: FXQ5Z9HHY6` + `CODE_SIGN_STYLE: Automatic` — **inert for the
  buildbox's iphonesimulator build** (the simulator is never code-signed).
- `Distribution` config (release-type): manual signing on the app target
  (`CODE_SIGN_STYLE: Manual`, `PROVISIONING_PROFILE_SPECIFIER: "Herdrup App Store"`,
  `CODE_SIGN_IDENTITY: "Apple Distribution"`). Used only by the CI archive.
- `Release` stays automatic — it belongs to the Mac fallback lane, not the CI.

## Export compliance

`ITSAppUsesNonExemptEncryption = true` (project.yml). herdr bundles third-party crypto
(BoringSSL via swift-nio-ssh/Citadel) that encrypts the whole SSH channel — not exempt.
It uses only standard encryption, so it qualifies for the mass-market (Cat. 5 Part 2)
exemption via a one-time self-classification answered in App Store Connect
(owner-approved determination, 2026-08-05). The CI verifier fails loudly on
`MISSING_EXPORT_COMPLIANCE` rather than shipping a build that reaches no testers. See
Apple's [export-compliance guidance](https://developer.apple.com/documentation/security/complying-with-encryption-export-regulations).

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
2. The `testflight` environment **secrets** (the nine above; the private keys never
   transit a pane/transcript — written repo-to-repo).
3. The export-compliance **answer** in App Store Connect on the first build ("standard
   encryption, qualifies for exemption").

The bundle id, the shared distribution certificate, and the `Herdrup App Store` profile
are created via the ASC API on Linux, not by hand.

## Verification

- Every change must keep the buildbox iphonesimulator build green at the exact head (the
  signing config is inert there).
- The full archive/export/upload + the destination check run on GitHub Actions from
  **main** (the environment secrets are gated to main + `v*` tags), so a run on main is
  the end-to-end gate.
