#!/usr/bin/env python3
"""Fail-closed public game fixture preflight for real native iPhone/iPad smoke.

Checks real published data, never seeds or synthesizes a game. Reports only
bounded status/counts and an opaque game-ID digest; no response bodies/URLs.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import sys
from typing import Callable
from urllib import error, parse, request


MAX_JSON_BYTES = 4 * 1024 * 1024
MAX_PACKAGE_PROBES = 15


class FixtureUnavailable(ValueError):
    """Sanitized error code, safe to print in CI."""


def _nonblank(value: object) -> bool:
    return isinstance(value, str) and bool(value.strip())


def eligible_games(feed: object) -> tuple[int, list[dict]]:
    if not isinstance(feed, dict) or not isinstance(feed.get("games"), list):
        raise FixtureUnavailable("feed_shape_missing_games")
    games = feed["games"]
    candidates = []
    for game in games:
        if not isinstance(game, dict):
            continue
        game_id = game.get("id") or game.get("game_id")
        if not _nonblank(game_id) or not _nonblank(game.get("owner_id")):
            continue
        if (game.get("status") != "ready"
                or game.get("visibility") != "public"
                or game.get("moderation_status") != "approved"):
            continue
        if game.get("quarantined") is True:
            continue
        # A public, approved record must also have an actual published version.
        version = game.get("published_version")
        if not isinstance(version, int) or isinstance(version, bool) or version < 1:
            continue
        candidates.append(game)
    return len(games), candidates


def package_is_playable(package: object, expected_id: str) -> bool:
    if not isinstance(package, dict) or package.get("gameId") != expected_id:
        return False
    if not all(_nonblank(package.get(field)) for field in (
            "packageFormatVersion", "minRuntimeVersion", "irVersion")):
        return False
    ir = package.get("ir")
    return isinstance(ir, dict) and bool(ir) and _nonblank(ir.get("irVersion"))


def package_url(feed_url: str, game_id: str) -> str:
    origin = parse.urlsplit(feed_url)
    if (origin.scheme != "https" or not origin.hostname
            or origin.username is not None or origin.password is not None
            or origin.path != "/v1/feed" or origin.query or origin.fragment):
        raise FixtureUnavailable("invalid_https_feed_origin")
    # Never accept a URL or host from the untrusted feed: use only our origin.
    return f"{origin.scheme}://{origin.netloc}/v1/games/{parse.quote(game_id, safe='')}/package"


def verify_fixture(
    feed_url: str, read_json: Callable[[str], object]
) -> dict[str, object]:
    # Validate origin even when no games are returned.
    package_url(feed_url, "probe")
    total, candidates = eligible_games(read_json(feed_url))
    result: dict[str, object] = {
        "feed_games": total,
        "eligible_games": len(candidates),
        "packages_checked": 0,
        "package_errors": 0,
        "verified": False,
    }
    for game in candidates[:MAX_PACKAGE_PROBES]:
        game_id = (game.get("id") or game.get("game_id")).strip()
        result["packages_checked"] = int(result["packages_checked"]) + 1
        try:
            package = read_json(package_url(feed_url, game_id))
        except FixtureUnavailable:
            result["package_errors"] = int(result["package_errors"]) + 1
            continue
        if not package_is_playable(package, game_id):
            result["package_errors"] = int(result["package_errors"]) + 1
            continue
        result["verified"] = True
        # Never print real creator names, account IDs or full game IDs.
        result["game_sha12"] = hashlib.sha256(
            game_id.encode("utf-8")).hexdigest()[:12]
        return result
    return result


class _NoRedirect(request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


def network_read_json(url: str, timeout: float = 12.0) -> object:
    opener = request.build_opener(_NoRedirect())
    req = request.Request(url, headers={"Accept": "application/json",
                                        "User-Agent": "hephaestus-ci-fixture-preflight"})
    try:
        with opener.open(req, timeout=timeout) as response:
            if response.status != 200:
                raise FixtureUnavailable("http_not_200")
            if response.headers.get_content_type() != "application/json":
                raise FixtureUnavailable("content_type_not_json")
            raw = response.read(MAX_JSON_BYTES + 1)
    except error.HTTPError as exc:
        raise FixtureUnavailable(f"http_{exc.code}") from None
    except (error.URLError, TimeoutError, OSError):
        raise FixtureUnavailable("transport_unavailable") from None
    if len(raw) > MAX_JSON_BYTES:
        raise FixtureUnavailable("response_too_large")
    try:
        return json.loads(raw)
    except (ValueError, UnicodeDecodeError):
        raise FixtureUnavailable("invalid_json") from None


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--feed-url", required=True,
                        help="Existing production public /v1/feed URL; never logged")
    parser.add_argument("--timeout", type=float, default=12.0)
    args = parser.parse_args(argv)
    if not (1 <= args.timeout <= 30):
        print("PUBLIC_FIXTURE status=failed reason=invalid_timeout")
        return 2
    try:
        result = verify_fixture(
            args.feed_url, lambda url: network_read_json(url, timeout=args.timeout))
    except FixtureUnavailable as exc:
        print(f"PUBLIC_FIXTURE status=failed reason={exc}")
        return 1
    report = " ".join(f"{key}={value}" for key, value in result.items())
    if not result["verified"]:
        print("PUBLIC_FIXTURE status=failed reason=no_ready_public_approved_owner_package "
              + report)
        return 1
    print("PUBLIC_FIXTURE status=ok " + report)
    return 0


if __name__ == "__main__":
    sys.exit(main())
