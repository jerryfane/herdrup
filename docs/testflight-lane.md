# TestFlight / App Store distribution lane (Herdrup)

How a signed build of the herdr iOS app (bundle id `com.jerryfane.herdr`, marketed
as **Herdrup**) gets to TestFlight. The app is authored on Linux; the archive can
only run on a Mac, so this lane is a reviewable in-repo script + config rather than
Xcode-UI state.

## Design

- **Signing goes through the Mac's signed-in Xcode account.** `scripts/testflight.sh`
  archives with `-allowProvisioningUpdates`, so Xcode creates/renews the **Apple
  Distribution** certificate and **App Store** provisioning profile from the Apple ID
  signed into Xcode. Nothing is committed and nothing is hand-installed. This path
  does **not** require the App Store Connect API key to hold provisioning /
  cloud-managed-distribution access (which an individual-account or non-Admin key may
  not have).
- **The API key is used only for the upload leg.** Upload is Xcode-native —
  `xcodebuild -exportArchive` with `ci/ExportOptions-upload.plist`
  (`destination: upload`) authenticated by the API key — so nothing depends on the
  deprecated `xcrun altool`.
- **`project.yml`** carries `DEVELOPMENT_TEAM: FXQ5Z9HHY6` + `CODE_SIGN_STYLE:
  Automatic`. These are **inert for the buildbox's iphonesimulator build** (the
  simulator is never code-signed), so the existing green sim build is unaffected;
  they take effect only for a device archive.
- **Export compliance is NOT predeclared.** The app links third-party crypto
  (BoringSSL via swift-nio-ssh/Citadel) that provides confidentiality — not merely
  OS-provided or authentication-only encryption — so it is **not automatically
  exempt** and may require annual self-classification. `project.yml` deliberately
  omits `ITSAppUsesNonExemptEncryption`; App Store Connect then asks the
  export-compliance question and the **owner** makes the determination there (the
  correct authority). See Apple's [export-compliance guidance](https://developer.apple.com/documentation/security/complying-with-encryption-export-regulations).

## Running it (on the Mac)

```sh
scripts/testflight.sh                          # archive + export a signed .ipa (no upload, no key needed)

TESTFLIGHT_UPLOAD=1 \
ASC_KEY_ID=4X6YN5S8US \
ASC_ISSUER_ID=<issuer-uuid> \
ASC_KEY_PATH=/path/to/AuthKey_4X6YN5S8US.p8 \
scripts/testflight.sh                          # ...and upload to TestFlight
```

A plain run is a self-contained signing dry-run (needs no API key) that proves the
signing chain before the first upload. `BUILD_NUMBER` defaults to a second-precision
timestamp (App Store requires a unique, monotonic build number per upload); pass a
durable CI counter for rapid successive uploads.

## Discovered account state (App Store Connect, read-only, 2026-08-04)

- Team **FXQ5Z9HHY6** (Jerry Fanelli, individual).
- App record for `com.jerryfane.herdr`: **none yet**.
- Bundle id `com.jerryfane.herdr`: **not registered** (registers on the first archive
  via the signed-in Xcode account).
- Distribution certificate: **none** (one Development cert exists); created by the
  first archive.
- App Store provisioning profile: **none**; created by the first archive.

## Needs the owner

1. **Create the App Store Connect app record** for `com.jerryfane.herdr` — public
   name (proposed **Herdrup**), primary language, SKU. Required before upload.
2. **On the Mac: sign Xcode into the Apple ID** for team FXQ5Z9HHY6 (this is what
   signs the archive). And for the upload, provide an **upload-capable App Store
   Connect API key** (App Manager or Admin). NOTE: an API key's role is **immutable** —
   if the current key `…4X6YN5S8US` is not upload-capable, **create a new key** with
   the right role rather than trying to change it.
3. **Complete the export-compliance determination** in App Store Connect (the app
   uses third-party SSH crypto, so it is not automatically exempt — see above).
4. **Put the `.p8` key file on the Mac** so the upload leg can read it.

## Verification

- The signing config must NOT regress the buildbox iphonesimulator build (it is
  inert there) — buildbox green at the exact head is the gate.
- The archive/export/upload is verified on the Mac once items 1–4 land; a plain
  `scripts/testflight.sh` (no upload) produces a signed `.ipa` and proves the signing
  chain before the first TestFlight push.
