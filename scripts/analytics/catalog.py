#!/usr/bin/env python3
from __future__ import annotations

import json
from pathlib import Path
from typing import Any


def load_catalog(path: str | Path) -> dict[str, Any]:
    text = Path(path).read_text()
    try:
        loaded = json.loads(text)
    except json.JSONDecodeError as exc:
        raise SystemExit(f"Report catalog must be JSON for v1 analytics collection: {exc}") from exc
    if not isinstance(loaded, dict):
        raise SystemExit("Report catalog must be a JSON object.")
    return loaded


def analytics_family(config: dict[str, Any]) -> dict[str, Any]:
    return config.get("families", {}).get("analytics_reports") or config.get("families", {}).get("analytics") or {}


def analytics_enabled(config: dict[str, Any]) -> bool:
    return bool(analytics_family(config).get("enabled", False))


def analytics_request_type(family: dict[str, Any]) -> str:
    return str(family.get("request_type") or family.get("access_type") or "ONGOING").upper()


def app_id(config: dict[str, Any]) -> str:
    app = config.get("app", {})
    value = app.get("app_id") or app.get("apple_app_id")
    if not value:
        raise SystemExit("Report catalog requires app.app_id.")
    return str(value)
