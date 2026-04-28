#!/usr/bin/env python3
from __future__ import annotations

import os
import time
from pathlib import Path
from typing import Any

import jwt
import requests


class AscApiError(RuntimeError):
    def __init__(self, status_code: int, message: str, response_body: str = ""):
        super().__init__(message)
        self.status_code = status_code
        self.response_body = response_body

    @property
    def manifest_status(self) -> str:
        if self.status_code in (401, 403):
            return "permission_blocked"
        if self.status_code == 404:
            return "unavailable"
        return "error"


def get_asc_token(key_id: str, issuer_id: str, private_key_path: str) -> str:
    private_key = Path(os.path.expanduser(private_key_path)).read_text()
    now = int(time.time())
    payload = {
        "iss": issuer_id,
        "iat": now,
        "exp": now + 1200,
        "aud": "appstoreconnect-v1",
    }
    return jwt.encode(payload, private_key, algorithm="ES256", headers={"kid": key_id})


class AscClient:
    def __init__(self, token: str, base_url: str = "https://api.appstoreconnect.apple.com"):
        self.base_url = base_url.rstrip("/")
        self.session = requests.Session()
        self.session.headers.update({"Authorization": f"Bearer {token}"})

    def request(self, method: str, path_or_url: str, **kwargs: Any) -> requests.Response:
        url = path_or_url if path_or_url.startswith("http") else f"{self.base_url}{path_or_url}"
        response = self.session.request(method, url, timeout=60, **kwargs)
        if response.status_code >= 400:
            detail = _error_detail(response)
            raise AscApiError(response.status_code, _actionable_message(response.status_code, detail), response.text)
        return response

    def get_json(self, path: str, params: dict[str, Any] | None = None) -> dict[str, Any]:
        return self.request("GET", path, params=params).json()

    def post_json(self, path: str, payload: dict[str, Any]) -> dict[str, Any]:
        return self.request("POST", path, json=payload).json()

    def download(self, url: str) -> bytes:
        return self.request("GET", url).content

    def paged_get(self, path: str, params: dict[str, Any] | None = None) -> list[dict[str, Any]]:
        items: list[dict[str, Any]] = []
        next_url: str | None = path
        next_params = params
        seen: set[str] = set()
        while next_url:
            response = self.get_json(next_url, next_params)
            items.extend(response.get("data", []))
            next_link = response.get("links", {}).get("next")
            if not next_link or next_link in seen:
                break
            seen.add(next_link)
            next_url = next_link
            next_params = None
        return items


def _error_detail(response: requests.Response) -> str:
    try:
        errors = response.json().get("errors", [])
    except ValueError:
        errors = []
    if errors:
        first = errors[0]
        return first.get("detail") or first.get("title") or response.text
    return response.text


def _actionable_message(status_code: int, detail: str) -> str:
    if status_code == 401:
        return f"ASC authentication failed; check ASC_KEY_ID, ASC_ISSUER_ID, and private key. {detail}".strip()
    if status_code == 403:
        return f"ASC request is forbidden; check API key role and report-family access. {detail}".strip()
    if status_code == 404:
        return f"ASC report resource is unavailable or not generated yet. {detail}".strip()
    if status_code == 429:
        return f"ASC rate limit reached; rerun later. {detail}".strip()
    if status_code >= 500:
        return f"ASC server error; no report should be marked complete from this partial run. {detail}".strip()
    return detail or f"ASC API error {status_code}"
