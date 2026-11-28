#!/usr/bin/env python3
"""Fail-closed *schema-only* probe for the deployed public creator directory.

Never print the response body, identity data, raw exception text, request URL,
or account headers. A 200 HTML app-shell is not a successful empty directory.
"""
from __future__ import annotations

import json
import sys
from urllib import error, parse, request

MAX_BODY_BYTES = 1_048_576
PUBLIC_ENDPOINT = "https://html-5-game-generator.replit.app/v1/creators?limit=20"


class ContractError(Exception):
    """A fixed, non-sensitive error class, never a server-provided message."""

    def __init__(self, category: str, http_status: int | None = None,
                 redirect_category: str | None = None):
        super().__init__(category)
        self.category = category
        self.http_status = http_status
        self.redirect_category = redirect_category


class RejectRedirects(request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None

    def http_error_302(self, req, fp, code, msg, headers):
        # Reject before urllib resolves or parses an untrusted Location.
        raise error.HTTPError(req.full_url, code, msg, headers, fp)

    http_error_301 = http_error_303 = http_error_307 = http_error_308 = http_error_302


# Only these fixed values may enter public workflow output.
REDIRECT_CATEGORIES = frozenset({
    "same_origin_player", "same_origin_login", "same_origin_other",
    "cross_origin", "insecure_or_non_https", "missing_or_invalid",
})


def classify_redirect(location: str | None, endpoint: str = PUBLIC_ENDPOINT) -> str:
    """Classify the target without a network request, retaining no raw URL."""
    if not location or location.startswith("///") or any(c.isspace() or ord(c) < 32 or ord(c) == 127
                           or c == "\\" for c in location):
        return "missing_or_invalid"
    try:
        source = parse.urlsplit(endpoint)
        raw = parse.urlsplit(location)
        # Do not normalize ambiguous explicit schemes (e.g. https:login).
        if raw.scheme and not raw.netloc:
            return ("insecure_or_non_https" if raw.scheme.lower() != "https"
                    else "missing_or_invalid")
        target = parse.urlsplit(parse.urljoin(endpoint, location))
        if target.scheme.lower() != "https":
            return "insecure_or_non_https"
        if not target.hostname or target.username is not None or target.password is not None:
            return "missing_or_invalid"
        def origin(parts):
            port = parts.port
            return (parts.scheme.lower(), parts.hostname, 443 if port is None else port)
        if origin(target) != origin(source):
            return "cross_origin"
        # Match only explicit known route boundaries; query and fragment
        # are never interpreted or emitted, and unknown routes stay unknown.
        path = target.path.rstrip("/") or "/"
        if path == "/player":
            return "same_origin_player"
        if path in ("/login", "/signin", "/sign-in", "/auth/login"):
            return "same_origin_login"
        return "same_origin_other"
    except (ValueError, UnicodeError):
        return "missing_or_invalid"


def validate_response(status: int, content_type: str, body: bytes,
                      location: str | None = None) -> int:
    """Return array cardinality only; never expose entries or creator IDs."""
    if 300 <= status < 400:
        raise ContractError("unexpected_redirect", status, classify_redirect(location))
    if status != 200:
        raise ContractError("unexpected_http_status", status)
    mime = content_type.split(";", 1)[0].strip().lower()
    if mime == "text/html":
        raise ContractError("html_instead_of_json", status)
    if mime != "application/json" and not (mime.startswith("application/") and mime.endswith("+json")):
        raise ContractError("non_json_content_type", status)
    if len(body) > MAX_BODY_BYTES:
        raise ContractError("oversized_response")
    try:
        value = json.loads(body)
    except (ValueError, UnicodeDecodeError):
        raise ContractError("malformed_json") from None
    if not isinstance(value, dict):
        raise ContractError("wrong_root_type")
    if "creators" not in value or not isinstance(value["creators"], list):
        raise ContractError("missing_or_invalid_creators")
    if "next_cursor" not in value or (
        value["next_cursor"] is not None and not isinstance(value["next_cursor"], str)
    ):
        raise ContractError("missing_or_invalid_cursor")
    for row in value["creators"]:
        if not isinstance(row, dict):
            raise ContractError("invalid_creator_entry")
        if not isinstance(row.get("creator_id"), str) or not row["creator_id"].strip():
            raise ContractError("invalid_creator_id_type")
        count = row.get("post_count")
        if not isinstance(count, int) or isinstance(count, bool) or count < 0:
            raise ContractError("invalid_post_count_type")
        topics = row.get("topics")
        if not isinstance(topics, list) or not all(isinstance(x, str) for x in topics):
            raise ContractError("invalid_topics_type")
    return len(value["creators"])


def probe() -> tuple[int, int]:
    req = request.Request(
        PUBLIC_ENDPOINT,
        headers={"Accept": "application/json", "User-Agent": "HephaestusCreatorSchemaProbe/1"},
    )
    opener = request.build_opener(RejectRedirects)
    try:
        with opener.open(req, timeout=12) as response:
            status = int(response.status)
            mime = response.headers.get("Content-Type", "")
            if 300 <= status < 400:
                raise ContractError("unexpected_redirect", status,
                                    classify_redirect(response.headers.get("Location")))
            body = response.read(MAX_BODY_BYTES + 1)
    except error.HTTPError as failure:
        # No response body, headers or raw exception text is logged.
        status = int(failure.code)
        category = "unexpected_redirect" if 300 <= status < 400 else "unexpected_http_status"
        try:
            redirect_category = (classify_redirect(failure.headers.get("Location")
                                                   if failure.headers else None)
                                 if 300 <= status < 400 else None)
        finally:
            failure.close()
        raise ContractError(category, status, redirect_category) from None
    except (error.URLError, TimeoutError, OSError):
        raise ContractError("transport_unavailable") from None
    return status, validate_response(status, mime, body)


def main() -> int:
    try:
        status, count = probe()
    except ContractError as failure:
        # HTTP status is public, low-cardinality metadata; never log response text.
        suffix = f" http_status={failure.http_status}" if failure.http_status is not None else ""
        if failure.category == "unexpected_redirect":
            redirect = failure.redirect_category
            suffix += " redirect_category=" + (redirect if redirect in REDIRECT_CATEGORIES
                                                else "missing_or_invalid")
        print(f"creator_schema_contract result=FAIL category={failure.category}{suffix}")
        return 1
    print(f"creator_schema_contract result=PASS http_status={status} creators_count={count}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
