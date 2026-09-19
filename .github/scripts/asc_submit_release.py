#!/usr/bin/env python3
"""Inspect or submit Herdr 1.0.6 build 156 through App Store Connect."""

import base64
import json
import os
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime, timezone

import jwt

API = "https://api.appstoreconnect.apple.com"
BUNDLE_ID = "com.jerryfane.herdr"
VERSION = "1.0.6"
BUILD_NUMBER = "156"
LOCALE = "en-US"
WHATS_NEW = "Smoother keyboard transitions and improved reply-field spacing."
MODE = os.environ.get("MODE", "inspect")


def token() -> str:
    now = int(time.time())
    key = base64.b64decode(os.environ["ASC_P8_BASE64"]).decode()
    return jwt.encode(
        {"iss": os.environ["ASC_ISSUER_ID"], "iat": now, "exp": now + 600, "aud": "appstoreconnect-v1"},
        key,
        algorithm="ES256",
        headers={"kid": os.environ["ASC_KEY_ID"], "typ": "JWT"},
    )


def request(method: str, path: str, body: dict | None = None) -> dict:
    payload = None if body is None else json.dumps(body).encode()
    req = urllib.request.Request(
        API + path,
        data=payload,
        method=method,
        headers={"Authorization": "Bearer " + token(), "Content-Type": "application/json"},
    )
    try:
        with urllib.request.urlopen(req, timeout=60) as response:
            raw = response.read()
            return json.loads(raw) if raw else {}
    except urllib.error.HTTPError as error:
        detail = error.read().decode(errors="replace")
        raise RuntimeError(f"App Store Connect {method} {path} failed HTTP {error.code}: {detail}") from error


def query(path: str, **params: str) -> dict:
    return request("GET", path + "?" + urllib.parse.urlencode(params))


def attrs(resource: dict) -> dict:
    return resource.get("attributes", {})


def relationship(resource_type: str, resource_id: str) -> dict:
    return {"data": {"type": resource_type, "id": resource_id}}


def print_resource(label: str, resource: dict | None, fields: tuple[str, ...]) -> None:
    if not resource:
        print(f"{label}: none")
        return
    values = {field: attrs(resource).get(field) for field in fields}
    print(f"{label}: id={resource['id']} {json.dumps(values, sort_keys=True)}")


def app_and_build() -> tuple[dict, dict]:
    apps = query("/v1/apps", **{"filter[bundleId]": BUNDLE_ID, "limit": "2"}).get("data", [])
    if len(apps) != 1:
        raise RuntimeError(f"Expected exactly one app for {BUNDLE_ID}; found {len(apps)}")
    app = apps[0]
    builds = query(
        "/v1/builds",
        **{"filter[app]": app["id"], "filter[version]": BUILD_NUMBER, "limit": "10"},
    ).get("data", [])
    valid = [build for build in builds if attrs(build).get("processingState") == "VALID"]
    if len(valid) != 1:
        raise RuntimeError(f"Expected one VALID build {BUILD_NUMBER}; found {len(valid)}")
    build = valid[0]
    uploaded = attrs(build).get("uploadedDate")
    if not uploaded:
        raise RuntimeError("Selected build has no uploadedDate")
    uploaded_at = datetime.fromisoformat(uploaded.replace("Z", "+00:00"))
    if uploaded_at < datetime(2026, 9, 19, 9, 4, tzinfo=timezone.utc):
        raise RuntimeError(f"Build {BUILD_NUMBER} predates the authorized upload: {uploaded}")
    return app, build


def find_version(app_id: str) -> dict | None:
    versions = query(
        "/v1/appStoreVersions",
        **{"filter[app]": app_id, "filter[platform]": "IOS", "limit": "200"},
    ).get("data", [])
    for version in versions:
        print_resource("version", version, ("versionString", "appStoreState", "releaseType", "createdDate"))
    return next((version for version in versions if attrs(version).get("versionString") == VERSION), None)


def inventory(app: dict, build: dict, version: dict | None) -> None:
    print_resource("app", app, ("name", "bundleId", "sku"))
    print_resource("authorized-build", build, ("version", "processingState", "uploadedDate", "expired"))
    print_resource("target-version", version, ("versionString", "appStoreState", "releaseType", "createdDate"))
    if version:
        selected = request("GET", f"/v1/appStoreVersions/{version['id']}/build").get("data")
        print_resource("selected-build", selected, ("version", "processingState", "uploadedDate"))
        localizations = request("GET", f"/v1/appStoreVersions/{version['id']}/appStoreVersionLocalizations?limit=200").get("data", [])
        for localization in localizations:
            print_resource("localization", localization, ("locale", "whatsNew", "description", "supportUrl"))
    submissions = query("/v1/reviewSubmissions", **{"filter[app]": app["id"], "limit": "50"}).get("data", [])
    for submission in submissions:
        print_resource("review-submission", submission, ("platform", "state", "submittedDate"))


def main() -> None:
    if MODE != "inspect":
        raise RuntimeError(f"This exact branch is read-only; unsupported MODE={MODE}")
    app, build = app_and_build()
    version = find_version(app["id"])
    inventory(app, build, version)
    print("READ_ONLY_INSPECTION_COMPLETE")


if __name__ == "__main__":
    try:
        main()
    except Exception as error:
        print(f"::error::{error}")
        sys.exit(1)
