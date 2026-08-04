# TestFlight / App Store distribution lane (Herdrup)

How a signed build of the herdr iOS app (bundle id `com.jerryfane.herdr`, marketed
as **Herdrup**) gets to TestFlight. The app is authored on Linux; the archive can
only run on a Mac, so this lane is a reviewable in-repo script + config rather than
Xcode-UI state.

## Design

- **Signing is automatic.** `scripts/testflight.sh` archives with
  `-allowProvisioningUpdates` + an App Store Connect API key, so Xcode creates/renews
  the **Apple Distribution** certificate and the **App Store** provisioning profile
  on demand. Nothing is committed and nothing is hand-installed — *provided the API
  key is an App Manager/Admin key*.
- **`project.yml`** carries `DEVELOPMENT_TEAM: FXQ5Z9HHY6` + `CODE_SIGN_STYLE:
  Automatic`. These are **inert for the buildbox's iphonesimulator build** (the
  simulator is never code-signed), so the existing green sim build is unaffected;
  they take effect only for a device archive.
- **`ci/ExportOptions.plist`** — `method: app-store-connect`, `destination: export`,
  team `FXQ5Z9HHY6`, automatic signing. Produces a signed `.ipa`; the script uploads
  it as a separate, explicitly-gated step (`TESTFLIGHT_UPLOAD=1`).
- **Export compliance:** `ITSAppUsesNonExemptEncryption = false` in the Info.plist
  properties — the only crypto is standard SSH transport (authentication + secure
  channel), which qualifies for the exemption, so no annual self-classification.

## Running it (on the Mac)

```sh
ASC_KEY_ID=4X6YN5S8US \
ASC_ISSUER_ID=<issuer-uuid> \
ASC_KEY_PATH=/path/to/AuthKey_4X6YN5S8US.p8 \
scripts/testflight.sh                    # archive + export a signed .ipa (no upload)

TESTFLIGHT_UPLOAD=1 <same env> scripts/testflight.sh   # ...and upload to TestFlight
```

`BUILD_NUMBER` defaults to a timestamp (App Store requires a unique, monotonic build
number per upload); override for a deterministic CI counter.

## Discovered account state (App Store Connect, read-only, 2026-08-04)

- Team **FXQ5Z9HHY6** (Jerry Fanelli, individual).
- App record for `com.jerryfane.herdr`: **none yet**.
- Bundle id `com.jerryfane.herdr`: **not registered** (auto-registers on first archive
  with an App Manager key).
- Distribution certificate: **none** (one Development cert exists); auto-created by the
  archive.
- App Store provisioning profile: **none**; auto-created by the archive.

## Needs the owner (sent via agentgram 2026-08-04)

1. **Create the App Store Connect app record** for `com.jerryfane.herdr` — public
   name (proposed **Herdrup**), primary language, SKU. Required before upload.
2. **Set the API key `…4X6YN5S8US` to App Manager/Admin** so the archive can create
   the distribution cert + profile (else create them manually and wire in).
3. **Confirm the encryption declaration** (`ITSAppUsesNonExemptEncryption=false`).
4. **The Mac** must have Xcode signed into the account and the `.p8` key present so
   the script can run.

## Verification

- The signing config must NOT regress the buildbox iphonesimulator build (it is
  inert there) — buildbox green at the exact head is the gate.
- The archive/export/upload itself is verified on the Mac once items 1–4 land; a
  dry `scripts/testflight.sh` (no upload) produces a signed `.ipa` to confirm the
  signing chain before the first TestFlight push.
