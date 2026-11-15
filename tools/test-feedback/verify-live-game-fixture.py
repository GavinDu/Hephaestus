#!/usr/bin/env python3
"""Validate a real, published live game fixture before mandatory iOS smoke.

Only public GETs are used. Never seed fake games, set moderator state,
suppress a failing XCTest, or print a full public feed/creator identity.
"""

import argparse
import hashlib
import json
import re
import sys
import time
from collections import Counter
from urllib import error, parse, request

MAX_JSON_BYTES = 2_000_000
SAFE_GAME_ID = re.compile(r"^[A-Za-z0-9_-]{1,128}$")


class FixtureError(Exception):
    pass


class NoRedirect(request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        raise FixtureError("live fixture endpoint redirected; same-origin contract not established")


def read_public_json(opener, url, timeout):
    req = request.Request(url, headers={"Accept": "application/json"})
    try:
        with opener.open(req, timeout=timeout) as response:
            if response.status != 200:
                raise FixtureError(f"endpoint returned HTTP {response.status}")
            # A successful reverse-proxy HTML response is not feed JSON.
            # Do not parse/print its body or misrepresent it as a fixture.
            if response.headers.get_content_type() != "application/json":
                raise FixtureError("public fixture endpoint is not JSON content")
            raw = response.read(MAX_JSON_BYTES + 1)
    except (error.HTTPError, error.URLError, TimeoutError, OSError) as exc:
        if isinstance(exc, error.HTTPError):
            raise FixtureError(f"endpoint returned HTTP {exc.code}") from exc
        raise FixtureError("public fixture endpoint unreachable or timed out") from exc
    if len(raw) > MAX_JSON_BYTES:
        raise FixtureError("public fixture JSON exceeds 2 MB bound")
    try:
        value = json.loads(raw)
    except (json.JSONDecodeError, UnicodeDecodeError) as exc:
        raise FixtureError("public fixture response is not valid JSON") from exc
    if not isinstance(value, dict):
        raise FixtureError("public fixture response must be a JSON object")
    return value


def candidates_in_feed(payload):
    games = payload.get("games")
    if not isinstance(games, list):
        raise FixtureError("live feed lacks a games array")
    eligible = []
    for entry in games:
        if not isinstance(entry, dict):
            continue
        game_id = entry.get("game_id")
        owner_id = entry.get("owner_id")
        if not isinstance(game_id, str) or not SAFE_GAME_ID.fullmatch(game_id):
            continue
        if not isinstance(owner_id, str) or not owner_id.strip():
            continue
        if entry.get("status") != "ready" or entry.get("visibility") != "public":
            continue
        if entry.get("quarantined") is True:
            continue
        # Match the existing backend canDeliver gate. Older shipped
        # inventory has an unset moderation field; do not mistake it for
        # "rejected". Independently approved publisher seeding is #288.
        if entry.get("moderation_status") not in (None, "", "approved"):
            continue
        eligible.append(game_id)
    return eligible


def package_invalid_reason(payload, expected_game_id):
    """Return only a fixed diagnostic category, never any input data."""
    if not isinstance(payload, dict):
        return "not_object"
    if payload.get("gameId") != expected_game_id:
        return "game_id_mismatch"
    # Match the current Go GamePackage v2.0 wire contract, not any
    # nonempty legacy string. A versioned incompatible package is not a
    # playable smoke prerequisite just because it returned HTTP 200.
    format_version = payload.get("packageFormatVersion")
    if not isinstance(format_version, str) or not format_version:
        return "missing_package_format"
    if format_version != "2.0":
        return "unsupported_package_format"
    for key, category in (
        ("minRuntimeVersion", "missing_min_runtime"),
        ("irVersion", "missing_ir_version"),
    ):
        if not isinstance(payload.get(key), str) or not payload[key].strip():
            return category
    ir = payload.get("ir")
    if not isinstance(ir, dict) or not ir:
        return "missing_ir"
    if not isinstance(ir.get("irVersion"), str) or not ir["irVersion"].strip():
        return "missing_ir_ir_version"
    if ir["irVersion"] != payload["irVersion"]:
        return "ir_version_mismatch"
    # The full digest is required in the canonical v2.0 response. Only
    # test safe shape/legacy-prefix consistency here: Python JSON encoding
    # is not the canonical Go Game IR marshaler and cannot attest the hash.
    full_sha = payload.get("irSha256")
    if not isinstance(full_sha, str) or not re.fullmatch(r"[0-9a-f]{64}", full_sha):
        return "missing_full_ir_sha"
    if payload.get("irHash") != full_sha[:12]:
        return "short_ir_hash_mismatch"
    if not isinstance(payload.get("assets"), list):
        return "missing_assets_array"
    return None


def package_is_playable(payload, expected_game_id):
    return package_invalid_reason(payload, expected_game_id) is None


def package_failure_category(message):
    """Safe finite diagnostic vocabulary: never echo game IDs/URLs/profile data."""
    if message.startswith("endpoint returned HTTP "):
        status = message.removeprefix("endpoint returned HTTP ")
        if len(status) == 3 and status.isascii() and status.isdecimal():
            return "http_" + status
    if message == "public fixture endpoint is not JSON content":
        return "not_json"
    if message == "public fixture response is not valid JSON":
        return "invalid_json"
    if message == "public fixture JSON exceeds 2 MB bound":
        return "too_large"
    if message == "live fixture endpoint redirected; same-origin contract not established":
        return "redirect"
    if message == "public fixture endpoint unreachable or timed out":
        return "transport"
    return "unavailable"


def check_once(opener, feed_url, timeout):
    feed = read_public_json(opener, feed_url, timeout)
    eligible = candidates_in_feed(feed)
    total = len(feed["games"])
    if not eligible:
        raise FixtureError(
            f"live feed HTTP 200 but no eligible owner-linked public ready game "
            f"(feed_count={total}); fixture #288 not ready"
        )
    origin = parse.urlsplit(feed_url)
    failure_reasons = Counter()
    for game_id in eligible[:5]:
        package_url = parse.urlunsplit(
            (origin.scheme, origin.netloc,
             f"/v1/games/{parse.quote(game_id, safe='')}/package", "", "")
        )
        try:
            package = read_public_json(opener, package_url, timeout)
        except FixtureError as exc:
            failure_reasons[package_failure_category(str(exc))] += 1
            continue
        if package_is_playable(package, game_id):
            return game_id, total, len(eligible)
        failure_reasons["invalid_envelope_" + package_invalid_reason(package, game_id)] += 1
    # Only categorical bounded counts; never the raw URL, response or ID.
    breakdown = ",".join(f"{key}:{failure_reasons[key]}" for key in sorted(failure_reasons))
    raise FixtureError(
        f"feed has owner-linked game(s) but no retrievable matching playable package "
        f"(feed_count={total}, eligible_count={len(eligible)}, "
        f"package_failure_breakdown={breakdown}); fixture #288 not ready"
    )


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--feed-url", required=True)
    parser.add_argument("--attempts", type=int, default=3)
    parser.add_argument("--timeout", type=float, default=10.0)
    parser.add_argument("--retry-seconds", type=float, default=5.0)
    args = parser.parse_args(argv)
    url = parse.urlsplit(args.feed_url)
    if url.scheme != "https" or not url.netloc or url.username or url.password:
        parser.error("feed URL must be a public HTTPS endpoint without credentials")
    if url.path != "/v1/feed" or url.query or url.fragment:
        parser.error("feed URL must be the exact public /v1/feed path")
    if not (1 <= args.attempts <= 18 and 0 < args.timeout <= 20 and 0 <= args.retry_seconds <= 15):
        parser.error("invalid bounded preflight attempts/timeout")
    opener = request.build_opener(NoRedirect())
    for attempt in range(1, args.attempts + 1):
        try:
            game_id, total, eligible = check_once(opener, args.feed_url, args.timeout)
            print(
                f"LIVE_FIXTURE_READY game_sha12={hashlib.sha256(game_id.encode()).hexdigest()[:12]} "
                f"owner_present=true feed_count={total} eligible_count={eligible} package=valid"
            )
            return 0
        except FixtureError as exc:
            print(f"LIVE_FIXTURE_NOT_READY attempt={attempt}: {exc}", file=sys.stderr)
            if attempt < args.attempts:
                time.sleep(args.retry_seconds)
    print("::error title=real-feed-prerequisite::Published public game/package fixture absent. See Hephaestus #288/#345.", file=sys.stderr)
    return 1


if __name__ == "__main__":
    sys.exit(main())
