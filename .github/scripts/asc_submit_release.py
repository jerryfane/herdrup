#!/usr/bin/env python3
"""Submit the exact authorized Herdr build to App Store review, idempotently."""

import base64
import json
import os
import re
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
SOURCE_VERSION = "1.0.5"
BUILD_NUMBER = "156"
LOCALE = "en-US"
WHATS_NEW = "Smoother keyboard transitions and improved reply-field spacing."
SUBMITTED_VERSION_STATES = {
    "ACCEPTED",
    "WAITING_FOR_REVIEW",
    "IN_REVIEW",
    "PENDING_DEVELOPER_RELEASE",
    "PENDING_APPLE_RELEASE",
    "PROCESSING_FOR_DISTRIBUTION",
    "READY_FOR_SALE",
}
SUBMITTED_REVIEW_STATES = {"WAITING_FOR_REVIEW", "IN_REVIEW", "COMPLETE"}

for required in ("ASC_ISSUER_ID", "ASC_KEY_ID", "ASC_P8_BASE64", "HERDR_REVIEW_DEMO_PASSWORD"):
    if not os.environ.get(required):
        raise RuntimeError(f"Missing required release credential: {required}")


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
    valid = [
        build for build in builds
        if attrs(build).get("processingState") == "VALID"
        and attrs(build).get("expired") is False
    ]
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


def versions_for_app(app_id: str) -> list[dict]:
    return query(
        f"/v1/apps/{app_id}/appStoreVersions",
        **{"filter[platform]": "IOS", "limit": "200"},
    ).get("data", [])


def version_named(versions: list[dict], version_string: str) -> dict | None:
    return next((version for version in versions if attrs(version).get("versionString") == version_string), None)


def version_localizations(version_id: str) -> list[dict]:
    return request(
        "GET", f"/v1/appStoreVersions/{version_id}/appStoreVersionLocalizations?limit=200"
    ).get("data", [])


def localization_named(version_id: str, locale: str) -> dict | None:
    return next((item for item in version_localizations(version_id) if attrs(item).get("locale") == locale), None)


def source_metadata(source_version: dict) -> tuple[dict, dict, str]:
    source_localization = localization_named(source_version["id"], LOCALE)
    if not source_localization:
        raise RuntimeError(f"Live {SOURCE_VERSION} has no {LOCALE} localization")
    source_review = request(
        "GET", f"/v1/appStoreVersions/{source_version['id']}/appStoreReviewDetail"
    ).get("data")
    if not source_review:
        raise RuntimeError(f"Live {SOURCE_VERSION} has no review detail")
    notes = attrs(source_review).get("notes") or ""
    password = os.environ["HERDR_REVIEW_DEMO_PASSWORD"]
    notes, replacements = re.subn(r"herdr-review-demo-[A-Za-z0-9_-]+", password, notes)
    if replacements != 1 or password not in notes:
        raise RuntimeError("Could not replace exactly one demo credential in inherited review notes")
    return source_localization, source_review, notes


def active_submissions(app_id: str) -> list[dict]:
    submissions = query(f"/v1/apps/{app_id}/reviewSubmissions", **{"limit": "50"}).get("data", [])
    return [submission for submission in submissions if attrs(submission).get("state") != "COMPLETE"]


def create_version(app: dict, source_version: dict) -> dict:
    source = attrs(source_version)
    body = {
        "data": {
            "type": "appStoreVersions",
            "attributes": {
                "platform": "IOS",
                "versionString": VERSION,
                "releaseType": "AFTER_APPROVAL",
                "copyright": source.get("copyright") or "2026 Jerry Fanelli",
            },
            "relationships": {"app": relationship("apps", app["id"])},
        }
    }
    version = request("POST", "/v1/appStoreVersions", body).get("data")
    if not version:
        raise RuntimeError("Creating App Store version returned no resource")
    print_resource("created-version", version, ("versionString", "appStoreState", "releaseType"))
    return version


def select_build(version: dict, build: dict) -> None:
    request(
        "PATCH",
        f"/v1/appStoreVersions/{version['id']}",
        {
            "data": {
                "type": "appStoreVersions",
                "id": version["id"],
                "relationships": {"build": relationship("builds", build["id"])},
            }
        },
    )
    selected = request("GET", f"/v1/appStoreVersions/{version['id']}/build").get("data")
    if not selected or selected["id"] != build["id"]:
        raise RuntimeError("App Store version did not retain exact build 156")
    print_resource("selected-build", selected, ("version", "processingState", "uploadedDate"))


def ensure_localization(version: dict, source_localization: dict) -> dict:
    localization = localization_named(version["id"], LOCALE)
    if localization:
        localization = request(
            "PATCH",
            f"/v1/appStoreVersionLocalizations/{localization['id']}",
            {
                "data": {
                    "type": "appStoreVersionLocalizations",
                    "id": localization["id"],
                    "attributes": {"whatsNew": WHATS_NEW},
                }
            },
        ).get("data")
    else:
        allowed = ("description", "keywords", "marketingUrl", "promotionalText", "supportUrl")
        copied = {key: attrs(source_localization).get(key) for key in allowed}
        copied = {key: value for key, value in copied.items() if value is not None}
        copied.update({"locale": LOCALE, "whatsNew": WHATS_NEW})
        localization = request(
            "POST",
            "/v1/appStoreVersionLocalizations",
            {
                "data": {
                    "type": "appStoreVersionLocalizations",
                    "attributes": copied,
                    "relationships": {
                        "appStoreVersion": relationship("appStoreVersions", version["id"])
                    },
                }
            },
        ).get("data")
    if not localization or attrs(localization).get("whatsNew") != WHATS_NEW:
        raise RuntimeError("Authorized release note was not saved exactly")
    print_resource("release-note", localization, ("locale", "whatsNew"))
    return localization


def ensure_review_detail(version: dict, source_review: dict, notes: str) -> None:
    target = request("GET", f"/v1/appStoreVersions/{version['id']}/appStoreReviewDetail").get("data")
    allowed = (
        "contactEmail",
        "contactFirstName",
        "contactLastName",
        "contactPhone",
        "demoAccountName",
        "demoAccountPassword",
        "demoAccountRequired",
    )
    copied = {key: attrs(source_review).get(key) for key in allowed}
    copied = {key: value for key, value in copied.items() if value is not None}
    copied["notes"] = notes
    if target:
        target = request(
            "PATCH",
            f"/v1/appStoreReviewDetails/{target['id']}",
            {
                "data": {
                    "type": "appStoreReviewDetails",
                    "id": target["id"],
                    "attributes": copied,
                }
            },
        ).get("data")
    else:
        target = request(
            "POST",
            "/v1/appStoreReviewDetails",
            {
                "data": {
                    "type": "appStoreReviewDetails",
                    "attributes": copied,
                    "relationships": {
                        "appStoreVersion": relationship("appStoreVersions", version["id"])
                    },
                }
            },
        ).get("data")
    if not target or os.environ["HERDR_REVIEW_DEMO_PASSWORD"] not in (attrs(target).get("notes") or ""):
        raise RuntimeError("Rotated demo credential was not saved in review instructions")
    print(f"review-detail: id={target['id']} contact-and-rotated-demo-instructions=verified")


def verify_screenshots(localization: dict) -> None:
    expected = {"APP_IPHONE_67", "APP_IPAD_PRO_3GEN_129"}
    for attempt in range(8):
        sets = request(
            "GET", f"/v1/appStoreVersionLocalizations/{localization['id']}/appScreenshotSets?limit=200"
        ).get("data", [])
        complete: set[str] = set()
        evidence: dict[str, dict] = {}
        for screenshot_set in sets:
            display_type = attrs(screenshot_set).get("screenshotDisplayType")
            if display_type not in expected:
                continue
            screenshots = request(
                "GET", f"/v1/appScreenshotSets/{screenshot_set['id']}/appScreenshots?limit=200"
            ).get("data", [])
            states = [
                (attrs(screenshot).get("assetDeliveryState") or {}).get("state")
                for screenshot in screenshots
            ]
            evidence[display_type] = {"count": len(screenshots), "states": states}
            if screenshots and all(state == "COMPLETE" for state in states):
                complete.add(display_type)
        print(f"screenshot-assets attempt={attempt + 1}: {json.dumps(evidence, sort_keys=True)}")
        if expected <= complete:
            return
        time.sleep(10)
    raise RuntimeError(f"New version lacks complete screenshots for {sorted(expected)}")


def review_submission_items(submission_id: str) -> list[dict]:
    return request("GET", f"/v1/reviewSubmissions/{submission_id}/items?limit=200").get("data", [])


def review_item_version_id(item: dict) -> str:
    version = (
        item.get("relationships", {})
        .get("appStoreVersion", {})
        .get("data")
    )
    if not version:
        raise RuntimeError(f"Review submission item {item['id']} has no App Store version relationship")
    return version["id"]

def resumable_submission(active: list[dict], version: dict) -> dict | None:
    if not active:
        return None
    if len(active) != 1:
        details = [(item["id"], attrs(item).get("state")) for item in active]
        raise RuntimeError(f"Refusing multiple active review submissions: {details}")
    submission = active[0]
    state = attrs(submission).get("state")
    if state != "READY_FOR_REVIEW":
        raise RuntimeError(f"Active review submission {submission['id']} is not resumable: {state}")
    items = review_submission_items(submission["id"])
    version_ids = {review_item_version_id(item) for item in items}
    if version_ids and version_ids != {version["id"]}:
        raise RuntimeError(
            f"Active review submission {submission['id']} belongs to other versions: {sorted(version_ids)}"
        )
    print(
        f"resuming-review: id={submission['id']} state={state} "
        f"target-items={len(items)}"
    )
    return submission


def create_and_submit_review(app: dict, version: dict, submission: dict | None) -> dict:
    if not submission:
        submission = request(
            "POST",
            "/v1/reviewSubmissions",
            {
                "data": {
                    "type": "reviewSubmissions",
                    "attributes": {"platform": "IOS"},
                    "relationships": {"app": relationship("apps", app["id"])},
                }
            },
        ).get("data")
        if not submission:
            raise RuntimeError("Creating review submission returned no resource")
    items = review_submission_items(submission["id"])
    if not items:
        item = request(
            "POST",
            "/v1/reviewSubmissionItems",
            {
                "data": {
                    "type": "reviewSubmissionItems",
                    "relationships": {
                        "reviewSubmission": relationship("reviewSubmissions", submission["id"]),
                        "appStoreVersion": relationship("appStoreVersions", version["id"]),
                    },
                }
            },
        ).get("data")
        if not item:
            raise RuntimeError("Creating review submission item returned no resource")
    else:
        version_ids = {review_item_version_id(item) for item in items}
        if version_ids != {version["id"]}:
            raise RuntimeError(
                f"Review submission {submission['id']} contains other versions: {sorted(version_ids)}"
            )
    submitted = request(
        "PATCH",
        f"/v1/reviewSubmissions/{submission['id']}",
        {
            "data": {
                "type": "reviewSubmissions",
                "id": submission["id"],
                "attributes": {"submitted": True},
            }
        },
    ).get("data")
    if not submitted:
        raise RuntimeError("Review submission PATCH returned no resource")
    print_resource("submitted-review", submitted, ("platform", "state", "submittedDate"))
    return submitted


def verify_submission(version_id: str, submission_id: str) -> None:
    for attempt in range(20):
        version = request("GET", f"/v1/appStoreVersions/{version_id}").get("data")
        submission = request("GET", f"/v1/reviewSubmissions/{submission_id}").get("data")
        version_state = attrs(version).get("appStoreState") if version else None
        review_state = attrs(submission).get("state") if submission else None
        print(f"verification attempt={attempt + 1}: appStoreState={version_state} reviewState={review_state}")
        if version_state in SUBMITTED_VERSION_STATES and review_state in SUBMITTED_REVIEW_STATES:
            print("APP_STORE_SUBMISSION_VERIFIED")
            return
        if review_state in {"UNRESOLVED_ISSUES", "CANCELING"}:
            raise RuntimeError(f"Review submission entered failure state {review_state}")
        time.sleep(15)
    raise RuntimeError("Timed out waiting for App Store review submission acceptance")


def main() -> None:
    app, build = app_and_build()
    versions = versions_for_app(app["id"])
    source_version = version_named(versions, SOURCE_VERSION)
    if not source_version:
        raise RuntimeError(f"Cannot find live {SOURCE_VERSION} metadata source")
    if attrs(source_version).get("releaseType") != "AFTER_APPROVAL":
        raise RuntimeError(
            f"Live {SOURCE_VERSION} no longer uses AFTER_APPROVAL; refusing to change release policy"
        )
    source_localization, source_review, notes = source_metadata(source_version)
    target = version_named(versions, VERSION)
    print_resource("app", app, ("name", "bundleId", "sku"))
    print_resource("authorized-build", build, ("version", "processingState", "uploadedDate", "expired"))
    print_resource("target-before", target, ("versionString", "appStoreState", "releaseType"))

    if target and attrs(target).get("releaseType") != "AFTER_APPROVAL":
        raise RuntimeError(
            f"Target version release policy is {attrs(target).get('releaseType')}, not AFTER_APPROVAL"
        )
    if target and attrs(target).get("appStoreState") in SUBMITTED_VERSION_STATES:
        selected = request("GET", f"/v1/appStoreVersions/{target['id']}/build").get("data")
        localization = localization_named(target["id"], LOCALE)
        if not selected or selected["id"] != build["id"]:
            raise RuntimeError("Submitted version does not use exact authorized build 156")
        if not localization or attrs(localization).get("whatsNew") != WHATS_NEW:
            raise RuntimeError("Submitted version does not contain exact authorized release note")
        print("APP_STORE_SUBMISSION_ALREADY_VERIFIED")
        return

    active = active_submissions(app["id"])
    if target and attrs(target).get("appStoreState") != "PREPARE_FOR_SUBMISSION":
        raise RuntimeError(f"Target version is not mutable: {attrs(target).get('appStoreState')}")
    if not target:
        if active:
            details = [(item["id"], attrs(item).get("state")) for item in active]
            raise RuntimeError(f"Refusing active review submission without target version: {details}")
        target = create_version(app, source_version)
    reusable = resumable_submission(active, target)

    select_build(target, build)
    localization = ensure_localization(target, source_localization)
    ensure_review_detail(target, source_review, notes)
    verify_screenshots(localization)
    submission = create_and_submit_review(app, target, reusable)
    verify_submission(target["id"], submission["id"])


if __name__ == "__main__":
    try:
        main()
    except Exception as error:
        print(f"::error::{error}")
        sys.exit(1)
