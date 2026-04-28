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


def sales_family(config: dict[str, Any]) -> dict[str, Any]:
    return config.get("families", {}).get("sales_trends") or config.get("families", {}).get("sales") or {}


def finance_family(config: dict[str, Any]) -> dict[str, Any]:
    return config.get("families", {}).get("finance") or {}


def analytics_enabled(config: dict[str, Any]) -> bool:
    return bool(analytics_family(config).get("enabled", False))


def sales_enabled(config: dict[str, Any]) -> bool:
    return bool(sales_family(config).get("enabled", False))


def finance_enabled(config: dict[str, Any]) -> bool:
    return bool(finance_family(config).get("enabled", False))


def analytics_request_type(family: dict[str, Any]) -> str:
    return str(family.get("request_type") or family.get("access_type") or "ONGOING").upper()


def app_id(config: dict[str, Any]) -> str:
    app = config.get("app", {})
    value = app.get("app_id") or app.get("apple_app_id")
    if not value:
        raise SystemExit("Report catalog requires app.app_id.")
    return str(value)


def vendor_number(config: dict[str, Any], report: dict[str, Any], family: dict[str, Any] | None = None) -> str:
    value = (
        report.get("vendor_number")
        or (family or {}).get("vendor_number")
        or config.get("app", {}).get("vendor_number")
    )
    if not value:
        raise SystemExit("Report catalog requires app.vendor_number, family vendor_number, or report vendor_number.")
    return str(value)
