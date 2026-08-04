# TestFlight / App Store distribution lane (Herdrup)

How a signed build of the herdr iOS app (bundle id `com.jerryfane.herdr`, marketed
as **Herdrup**) gets to TestFlight. The app is authored on Linux; the archive can
only run on a Mac, so this lane is a reviewable in-repo script + config rather than
Xcode-UI state.

## Design

- **Signing AND upload go through the Mac's signed-in Xcode account.**
  `scripts/testflight.sh` archives with `-allowProvisioningUpdates` (which
  creates/renews the **Apple Distribution** certificate + **App Store** profile from
  the Apple ID signed into Xcode) and, on upload, exports with `destination: upload`
  through that same account. **No App Store Connect API key is used** — deliberately:
  passing a key to `-exportArchive` makes it perform distribution *signing*, not
  upload only, which would require the key to hold cloud-managed-distribution /
  provisioning access that an individual-account or non-Admin key may lack.
- **`project.yml`** carries `DEVELOPMENT_TEAM: FXQ5Z9HHY6` + `CODE_SIGN_STYLE:
  Automatic`. These are **inert for the buildbox's iphonesimulator build** (the
  simulator is never code-signed), so the existing green sim build is unaffected;
  they take effect only for a device archive.
- **Export compliance is NOT predeclared.** The app links third-party crypto
  (BoringSSL via swift-nio-ssh/Citadel) that provides confidentiality — not merely
  OS-provided or authentication-only encryption — so it is **not automatically
  exempt** and may require annual self-classification. `project.yml` deliberately
  omits `ITSAppUsesNonExemptEncryption`; App Store Connect then asks the
  export-compliance question and the **owner** makes the determination there. See
  Apple's [export-compliance guidance](https://developer.apple.com/documentation/security/complying-with-encryption-export-regulations).

## Running it (on the Mac)

```sh
scripts/testflight.sh                          # archive + export a signed .ipa (no upload)
TESTFLIGHT_UPLOAD=1 scripts/testflight.sh      # ...and upload to TestFlight
```

A plain run is a self-contained signing dry-run that proves the signing chain before
the first upload. `BUILD_NUMBER` defaults to a second-precision timestamp (App Store
requires a unique, monotonic build number per upload); pass a durable CI counter for
rapid successive uploads.

### Alternative: fully-headless CI (API-key upload)

If the archive must run on a Mac with no interactive Xcode account, split the two
concerns so the API key stays upload-only:
1. Install a distribution certificate + App Store profile on the Mac keychain
   (or use a non-`upload` export via a cloud-signing-capable **Admin** key), and
2. export the `.ipa` (the plain run above), then upload it with the upload-only
   Transporter: `xcrun iTMSTransporter -m upload -assetFile <path>.ipa
   -apiKey <KEY_ID> -apiIssuer <ISSUER>` (place `AuthKey_<KEY_ID>.p8` in a
   `private_keys` dir). Transporter uploads only — it never signs — so the key needs
   no provisioning access.

## Discovered account state (App Store Connect, read-only, 2026-08-04)

- Team **FXQ5Z9HHY6** (Jerry Fanelli, individual).
- App record for `com.jerryfane.herdr`: **none yet**.
- Bundle id, distribution certificate, App Store profile: **none** — all created by
  the first archive via the signed-in Xcode account.

## Needs the owner

1. **Create the App Store Connect app record** for `com.jerryfane.herdr` — public
   name (proposed **Herdrup**), primary language, SKU. Required before upload.
2. **On the Mac: sign Xcode into the Apple ID** for team FXQ5Z9HHY6. That single
   session does both the distribution signing and the upload — no API key needed for
   the standard flow. (The API key is only for the headless alternative above; note
   an API key's role is **immutable**, so a differently-scoped key means creating a
   new one, not editing the old.)
3. **Complete the export-compliance determination** in App Store Connect (the app
   uses third-party SSH crypto, so it is not automatically exempt — see above).

## Verification

- The signing config must NOT regress the buildbox iphonesimulator build (it is
  inert there) — buildbox green at the exact head is the gate.
- The archive/export/upload is verified on the Mac once items 1–3 land; a plain
  `scripts/testflight.sh` (no upload) produces a signed `.ipa` and proves the signing
  chain before the first TestFlight push.
