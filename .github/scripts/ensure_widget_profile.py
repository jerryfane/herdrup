#!/usr/bin/env python3
"""Ensure an App Store distribution profile for the widget extension exists and is
installed, so the manual Distribution archive can sign the widget target.

Option B (owner-approved, directive 61335/61376): create the profile via the App Store
Connect API, reusing the team's EXISTING distribution certificate — no cloud signing,
no owner portal step. Idempotent: reuses an existing active profile of the same name.

If the ASC key lacks permission to create the bundle id or the profile, this FAILS
LOUDLY with a clear message. Per the overnight directive that is the signal to STOP and
leave the profile for the owner to mint — this script never falls back to touching the
distribution certificate or minting anything by hand.

Env: ASC_KEY_ID, ASC_ISSUER_ID, ASC_KEYFILE (path to the .p8).
"""
import base64
import json
import os
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

import jwt  # PyJWT (installed in the widget-signing venv)

BUNDLE_ID = "com.jerryfane.herdr.widgets"
BUNDLE_NAME = "Herdrup Widgets"
PROFILE_NAME = "Herdrup Widgets App Store"
PROFILE_TYPE = "IOS_APP_STORE"
DIST_TYPES = ("DISTRIBUTION", "IOS_DISTRIBUTION")
BASE = "https://api.appstoreconnect.apple.com/v1"
INSTALL_DIR = os.path.expanduser("~/Library/MobileDevice/Provisioning Profiles")

TOKEN = None


def make_token():
    with open(os.environ["ASC_KEYFILE"]) as f:
        private_key = f.read()
    now = int(time.time())
    return jwt.encode(
        {"iss": os.environ["ASC_ISSUER_ID"], "iat": now, "exp": now + 600,
         "aud": "appstoreconnect-v1"},
        private_key,
        algorithm="ES256",
        headers={"kid": os.environ["ASC_KEY_ID"], "typ": "JWT"},
    )


def api(method, path, body=None):
    url = path if path.startswith("http") else BASE + path
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(url, data=data, method=method)
    req.add_header("Authorization", "Bearer " + TOKEN)
    if data is not None:
        req.add_header("Content-Type", "application/json")
    try:
        with urllib.request.urlopen(req) as resp:
            raw = resp.read()
            return resp.status, (json.loads(raw) if raw else {})
    except urllib.error.HTTPError as e:
        raw = e.read()
        try:
            return e.code, json.loads(raw)
        except Exception:
            return e.code, {"raw": raw.decode(errors="replace")}


def die(msg, payload=None):
    print("::error::" + msg)
    if payload is not None:
        print(json.dumps(payload, indent=2)[:2000])
    sys.exit(1)


def ensure_bundle_id():
    q = urllib.parse.quote(BUNDLE_ID)
    st, r = api("GET", f"/bundleIds?filter[identifier]={q}&limit=1")
    if st != 200:
        die(f"ASC bundleIds query failed (HTTP {st}) — the key may lack "
            "Certificates/Identifiers access.", r)
    if r.get("data"):
        rid = r["data"][0]["id"]
        print(f"bundle id exists: {BUNDLE_ID} ({rid})")
        return rid
    st, r = api("POST", "/bundleIds", {"data": {"type": "bundleIds", "attributes": {
        "identifier": BUNDLE_ID, "name": BUNDLE_NAME, "platform": "IOS"}}})
    if st not in (200, 201):
        die(f"could not CREATE bundle id {BUNDLE_ID} (HTTP {st}) — the ASC key likely "
            "lacks permission. STOP and have the owner mint the widget profile.", r)
    rid = r["data"]["id"]
    print(f"created bundle id: {BUNDLE_ID} ({rid})")
    return rid


def distribution_cert_ids():
    st, r = api("GET", "/certificates?limit=200")
    if st != 200:
        die(f"ASC certificates query failed (HTTP {st}).", r)
    ids = [c["id"] for c in r.get("data", [])
           if c.get("attributes", {}).get("certificateType") in DIST_TYPES]
    if not ids:
        die("no distribution certificate found in App Store Connect for this team — "
            "cannot build a signing profile.", r)
    print(f"distribution certificates: {len(ids)}")
    return ids


def find_active_profile():
    q = urllib.parse.quote(PROFILE_NAME)
    st, r = api("GET", f"/profiles?filter[name]={q}&limit=1")
    if st == 200 and r.get("data"):
        prof = r["data"][0]
        if prof.get("attributes", {}).get("profileState") == "ACTIVE":
            print(f"reusing active profile: {PROFILE_NAME} ({prof['id']})")
            return prof
        # Not active (expired/invalid) — remove so we can recreate cleanly.
        api("DELETE", f"/profiles/{prof['id']}")
        print(f"deleted stale profile {PROFILE_NAME} ({prof['id']})")
    return None


def create_profile(bundle_rid, cert_ids):
    body = {"data": {
        "type": "profiles",
        "attributes": {"name": PROFILE_NAME, "profileType": PROFILE_TYPE},
        "relationships": {
            "bundleId": {"data": {"type": "bundleIds", "id": bundle_rid}},
            "certificates": {"data": [{"type": "certificates", "id": cid} for cid in cert_ids]},
        },
    }}
    st, r = api("POST", "/profiles", body)
    if st not in (200, 201):
        die(f"could not CREATE the widget profile '{PROFILE_NAME}' (HTTP {st}) — the "
            "ASC key likely lacks permission. STOP and have the owner mint it.", r)
    prof = r["data"]
    print(f"created profile: {PROFILE_NAME} ({prof['id']})")
    return prof


def install(prof):
    content = prof.get("attributes", {}).get("profileContent")
    if not content:
        st, r = api("GET", f"/profiles/{prof['id']}")
        content = r.get("data", {}).get("attributes", {}).get("profileContent")
    if not content:
        die("the profile has no profileContent to install.", prof)
    os.makedirs(INSTALL_DIR, exist_ok=True)
    out = os.path.join(INSTALL_DIR, "herdr-widgets.mobileprovision")
    with open(out, "wb") as f:
        f.write(base64.b64decode(content))
    print(f"installed widget profile -> {out}")


def main():
    global TOKEN
    TOKEN = make_token()
    bundle_rid = ensure_bundle_id()
    cert_ids = distribution_cert_ids()
    prof = find_active_profile() or create_profile(bundle_rid, cert_ids)
    install(prof)


if __name__ == "__main__":
    main()
