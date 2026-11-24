#!/usr/bin/env python3
"""Read-only diagnostic of published GamePackage v2 envelope shape.

Only public GETs are used. This does not certify canonical IR bytes, renderer
readiness, publisher identity, or deployed release provenance. Never seed fake
games, set moderator state,
suppress a failing XCTest, or print a full public feed/creator identity.
"""

import argparse
import http.client
import math
import json
import re
import sys
import time
from collections import Counter
from urllib import error, parse, request

MAX_JSON_BYTES = 2_000_000
SAFE_GAME_ID = re.compile(r"^[A-Za-z0-9_-]{1,128}$")

# Fixed allowlist ONLY. Deployed package shape can be stale, but logging
# arbitrary dictionary keys leaks data accidentally attached by an upstream
# serializer; never emit raw values, creator profile fields or unknown keys.
SAFE_PACKAGE_WIRE_FIELDS = (
    "gameId", "game_id", "packageFormatVersion", "package_format_version",
    "minRuntimeVersion", "irVersion", "ir", "gameIR", "irHash", "irSha256",
    "assets",
)


def safe_package_field_presence(payload):
    """Names from a fixed public contract allowlist, never caller-owned keys."""
    if not isinstance(payload, dict):
        return "not_object"
    return "|".join(k for k in SAFE_PACKAGE_WIRE_FIELDS if k in payload) or "none"



class FixtureError(Exception):
    pass


class NoRedirect(request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        raise FixtureError("live fixture endpoint redirected; same-origin contract not established")


def unique_json_object(pairs):
    # Do not let Python's last-key-wins semantics hide an ambiguous wire
    # envelope. Reject duplicates at ANY depth without echoing member names.
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError("duplicate JSON member")
        result[key] = value
    return result


def reject_non_json_constant(_value):
    raise ValueError("non-JSON numeric constant")


def finite_json_float(value):
    result = float(value)
    if not math.isfinite(result):
        raise ValueError("nonfinite JSON number")
    return result


def read_public_json(opener, url, timeout):
    try:
        req = request.Request(url, headers={"Accept": "application/json"})
        with opener.open(req, timeout=timeout) as response:
            if response.status != 200:
                raise FixtureError(f"endpoint returned HTTP {response.status}")
            # A successful reverse-proxy HTML response is not feed JSON.
            # Do not parse/print its body or misrepresent it as a fixture.
            if response.headers.get_content_type() != "application/json":
                raise FixtureError("public fixture endpoint is not JSON content")
            raw = response.read(MAX_JSON_BYTES + 1)
    except (error.HTTPError, error.URLError, TimeoutError, OSError,
            http.client.HTTPException, ValueError) as exc:
        if isinstance(exc, error.HTTPError):
            raise FixtureError(f"endpoint returned HTTP {exc.code}") from exc
        raise FixtureError("public fixture endpoint unreachable or timed out") from exc
    if len(raw) > MAX_JSON_BYTES:
        raise FixtureError("public fixture JSON exceeds 2 MB bound")
    try:
        value = json.loads(raw, object_pairs_hook=unique_json_object,
                           parse_constant=reject_non_json_constant,
                           parse_float=finite_json_float)
    except (ValueError, UnicodeDecodeError, RecursionError) as exc:
        raise FixtureError("public fixture response is not valid JSON") from exc
    if not isinstance(value, dict):
        raise FixtureError("public fixture response must be a JSON object")
    return value


def candidates_in_feed(payload):
    games = payload.get("games")
    if not isinstance(games, list):
        raise FixtureError("live feed lacks a games array")
    eligible = []
    seen = set()
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
        if entry.get("quarantined") is not None and entry.get("quarantined") is not False:
            continue
        # Match the existing backend canDeliver gate. Older shipped
        # inventory has an unset moderation field; do not mistake it for
        # "rejected". Independently approved publisher seeding is #288.
        if entry.get("moderation_status") not in (None, "", "approved"):
            continue
        if game_id not in seen:
            seen.add(game_id)
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
    if message == "public fixture response must be a JSON object":
        return "not_object"
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
    if not valid_public_feed_url(feed_url):
        raise FixtureError("invalid public feed endpoint")
    try:
        feed = read_public_json(opener, feed_url, timeout)
    except FixtureError as exc:
        raise FixtureError("feed_failure=" + package_failure_category(str(exc))) from None
    eligible = candidates_in_feed(feed)
    total = len(feed["games"])
    if not eligible:
        raise FixtureError(
            f"live feed HTTP 200 but no eligible owner-linked public ready game "
            f"(feed_count={total}); fixture #288 not ready"
        )
    origin = parse.urlsplit(feed_url)
    failure_reasons = Counter()
    missing_format_shapes = Counter()
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
        reason = package_invalid_reason(package, game_id)
        if reason is None:
            return total, len(eligible)
        failure_reasons["invalid_envelope_" + reason] += 1
        if reason == "missing_package_format":
            missing_format_shapes[safe_package_field_presence(package)] += 1
    # Only categorical bounded counts; never the raw URL, response or ID.
    breakdown = ",".join(f"{key}:{failure_reasons[key]}" for key in sorted(failure_reasons))
    # At most five real candidates, and only a fixed list of contract key
    # *names*. Never expose a game ID, creator identity or arbitrary JSON.
    shapes = ",".join(f"{key}:{missing_format_shapes[key]}" for key in sorted(missing_format_shapes))
    shape_hint = f", safe_package_keys={shapes}" if shapes else ""
    raise FixtureError(
        f"feed has owner-linked game(s) but no retrievable matching playable package "
        f"(feed_count={total}, eligible_count={len(eligible)}, "
        f"package_failure_breakdown={breakdown}{shape_hint}); fixture #288 not ready"
    )


def valid_public_feed_url(value):
    # urllib may normalize control characters; reject before parsing.
    # The caller supplies the trusted target origin, never a feed entry.
    if not isinstance(value, str) or any(ord(c) <= 32 or ord(c) == 127 for c in value):
        return False
    if "\\" in value or "?" in value or "#" in value:
        return False
    try:
        url = parse.urlsplit(value)
        return (url.scheme == "https" and bool(url.hostname) and
                url.username is None and url.password is None and
                url.port in (None, 443) and url.path == "/v1/feed" and
                not url.query and not url.fragment)
    except ValueError:
        return False


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--feed-url", required=True)
    parser.add_argument("--attempts", type=int, default=3)
    parser.add_argument("--timeout", type=float, default=10.0)
    parser.add_argument("--retry-seconds", type=float, default=5.0)
    args = parser.parse_args(argv)
    if not valid_public_feed_url(args.feed_url):
        parser.error("feed URL must be an exact public HTTPS /v1/feed endpoint without credentials")
    if not (1 <= args.attempts <= 18 and 0 < args.timeout <= 20 and 0 <= args.retry_seconds <= 15):
        parser.error("invalid bounded preflight attempts/timeout")
    opener = request.build_opener(NoRedirect())
    for attempt in range(1, args.attempts + 1):
        try:
            total, eligible = check_once(opener, args.feed_url, args.timeout)
            print(
                f"LIVE_FIXTURE_ENVELOPE_READY owner_present=true feed_count={total} "
                f"eligible_count={eligible} package=v2_shape_only"
            )
            return 0
        except FixtureError as exc:
            # check_once emits fixed categories/counts only. Feed transport
            # errors are classified at the boundary rather than echoed.
            print(f"LIVE_FIXTURE_NOT_READY attempt={attempt}: {exc}", file=sys.stderr)
            if attempt < args.attempts:
                time.sleep(args.retry_seconds)
    print("::error title=real-feed-prerequisite::Published public game/package fixture absent. See Hephaestus #288/#345.", file=sys.stderr)
    return 1


if __name__ == "__main__":
    sys.exit(main())
