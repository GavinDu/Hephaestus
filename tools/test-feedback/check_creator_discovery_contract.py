#!/usr/bin/env python3
"""Fail-closed *schema-only* probe for the deployed public creator directory.

Never print the response body, identity data, raw exception text, request URL,
or account headers. A 200 HTML app-shell is not a successful empty directory.
"""
from __future__ import annotations

import json
import sys
from urllib import error, request

MAX_BODY_BYTES = 1_048_576
PUBLIC_ENDPOINT = "https://html-5-game-generator.replit.app/v1/creators?limit=20"


class ContractError(Exception):
    """A fixed, non-sensitive error class, never a server-provided message."""

    def __init__(self, category: str):
        super().__init__(category)
        self.category = category


class RejectRedirects(request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


def validate_response(status: int, content_type: str, body: bytes) -> int:
    """Return array cardinality only; never expose entries or creator IDs."""
    if status != 200:
        raise ContractError("unexpected_http_status")
    mime = content_type.split(";", 1)[0].strip().lower()
    if mime != "application/json" and not (mime.startswith("application/") and mime.endswith("+json")):
        raise ContractError("non_json_content_type")
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
            body = response.read(MAX_BODY_BYTES + 1)
    except error.HTTPError as failure:
        # No raw HTTP body, headers or diagnostic string is logged.
        raise ContractError("unexpected_http_status") from None
    except (error.URLError, TimeoutError, OSError):
        raise ContractError("transport_unavailable") from None
    return status, validate_response(status, mime, body)


def main() -> int:
    try:
        status, count = probe()
    except ContractError as failure:
        print(f"creator_schema_contract result=FAIL category={failure.category}")
        return 1
    print(f"creator_schema_contract result=PASS http_status={status} creators_count={count}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
