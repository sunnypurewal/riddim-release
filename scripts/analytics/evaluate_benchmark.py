#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import sys
from datetime import date
from pathlib import Path
from typing import Any

REPO_ROOT = Path(__file__).resolve().parents[2]
if str(REPO_ROOT) not in sys.path:
    sys.path.insert(0, str(REPO_ROOT))

from scripts.analytics import TOOL_VERSION
from scripts.analytics.artifact import load_json, utc_now, write_json


def evaluate(root: Path, jira_key: str, goal_path: Path | None = None) -> Path:
    manifest = load_json(root / "manifest.json")
    goal_path = goal_path or root.parents[1] / "benchmarks" / f"{jira_key}.json"
    output_path = root / "evaluation" / f"{jira_key}.md"
    output_path.parent.mkdir(parents=True, exist_ok=True)
    if not goal_path.exists():
        write_missing_goal(output_path, jira_key, goal_path)
        record_evaluation(manifest, root, output_path, jira_key, "insufficient_data")
        return output_path
    goals = load_json(goal_path)
    rows = load_rows(manifest)
    metric_results = [evaluate_metric(metric, goals, rows, manifest) for metric in goals.get("metrics", [])]
    status = rollup_status(metric_results)
    write_evaluation(output_path, jira_key, goals, metric_results, status, manifest)
    record_evaluation(manifest, root, output_path, jira_key, status)
    return output_path


def load_rows(manifest: dict[str, Any]) -> list[dict[str, Any]]:
    rows: list[dict[str, Any]] = []
    for report in manifest.get("reports", []):
        normalized = report.get("normalized_path")
        if not normalized or not Path(normalized).exists():
            continue
        with Path(normalized).open() as handle:
            for line in handle:
                rows.append(json.loads(line))
    return rows


def evaluate_metric(metric: dict[str, Any], goals: dict[str, Any], rows: list[dict[str, Any]], manifest: dict[str, Any]) -> dict[str, Any]:
    source_column = metric.get("source_column") or metric["name"]
    baseline = sum_window(rows, source_column, goals.get("baseline_window", {}))
    campaign = sum_window(rows, source_column, goals.get("campaign_window", {}))
    if baseline is None or campaign is None:
        return {**metric, "baseline": baseline, "actual": campaign, "delta": None, "status": "insufficient_data", "caveat": "No matching rows or source column for one of the requested windows."}
    if baseline == 0:
        delta = None
        status = "inconclusive"
    else:
        delta = (campaign - baseline) / baseline
        direction = metric.get("direction", "increase")
        target_delta = float(metric.get("target_delta", 0))
        status = "met" if (delta >= target_delta if direction == "increase" else delta <= -abs(target_delta)) else "missed"
    caveats = manifest.get("completeness", {}).get("caveats", [])
    return {**metric, "baseline": baseline, "actual": campaign, "delta": delta, "status": status, "caveat": "; ".join(caveats)}


def sum_window(rows: list[dict[str, Any]], source_column: str, window: dict[str, str]) -> float | None:
    start = parse_date(window.get("start"))
    end = parse_date(window.get("end"))
    if not start or not end:
        return None
    total = 0.0
    matched = False
    for row in rows:
        row_date = parse_date(row.get("Date") or row.get("date") or row.get("Begin Date") or row.get("Start Date"))
        if not row_date or row_date < start or row_date > end:
            continue
        if source_column not in row or row[source_column] in ("", None):
            continue
        try:
            total += float(str(row[source_column]).replace(",", ""))
            matched = True
        except ValueError:
            continue
    return total if matched else None


def parse_date(value: Any) -> date | None:
    if not value:
        return None
    try:
        return date.fromisoformat(str(value)[:10])
    except ValueError:
        return None


def rollup_status(results: list[dict[str, Any]]) -> str:
    if not results or any(result["status"] == "insufficient_data" for result in results):
        return "insufficient_data"
    if any(result["status"] == "inconclusive" for result in results):
        return "inconclusive"
    return "met" if all(result["status"] == "met" for result in results) else "missed"


def write_missing_goal(output_path: Path, jira_key: str, goal_path: Path) -> None:
    output_path.write_text(
        "\n".join(
            [
                f"# Benchmark Evaluation: {jira_key}",
                "",
                "Status: insufficient_data",
                "",
                f"Goal metadata was not found at `{goal_path}`.",
                "",
                "Create a goal file like:",
                "",
                "```json",
                json.dumps(
                    {
                        "jira_key": jira_key,
                        "baseline_window": {"start": "2026-04-01", "end": "2026-04-07"},
                        "campaign_window": {"start": "2026-04-08", "end": "2026-04-14"},
                        "metrics": [{"name": "impressions", "source_column": "Impressions", "target_delta": 0.1, "direction": "increase"}],
                    },
                    indent=2,
                ),
                "```",
                "",
            ]
        )
    )


def write_evaluation(output_path: Path, jira_key: str, goals: dict[str, Any], results: list[dict[str, Any]], status: str, manifest: dict[str, Any]) -> None:
    lines = [
        f"# Benchmark Evaluation: {jira_key}",
        "",
        f"Status: {status}",
        "",
        f"- Baseline window: {goals.get('baseline_window', {}).get('start')} to {goals.get('baseline_window', {}).get('end')}",
        f"- Campaign window: {goals.get('campaign_window', {}).get('start')} to {goals.get('campaign_window', {}).get('end')}",
        f"- Generated at: {utc_now()}",
        "",
        "## Metrics",
        "",
        "| Metric | Target | Baseline | Actual | Delta | Status | Caveats |",
        "| --- | ---: | ---: | ---: | ---: | --- | --- |",
    ]
    for result in results:
        delta = "n/a" if result.get("delta") is None else f"{result['delta']:.2%}"
        target = f"{float(result.get('target_delta', 0)):.2%}"
        lines.append(f"| {result.get('name')} | {target} | {fmt(result.get('baseline'))} | {fmt(result.get('actual'))} | {delta} | {result.get('status')} | {result.get('caveat', '')} |")
    lines.extend(["", "## Sources", "", "- Manifest: `manifest.json`"])
    for report in manifest.get("reports", []):
        lines.append(f"- `{report.get('artifact_id')}`: raw `{report.get('raw_path')}`, normalized `{report.get('normalized_path')}`")
    lines.extend(["", "## Interpretation Notes", "", "This artifact compares configured goals to available App Store Connect rows. It does not infer causality; missing or thresholded Apple data is reported as insufficient or caveated evidence.", ""])
    output_path.write_text("\n".join(lines))


def fmt(value: Any) -> str:
    if value is None:
        return "n/a"
    return f"{float(value):.0f}" if float(value).is_integer() else f"{float(value):.2f}"


def record_evaluation(manifest: dict[str, Any], root: Path, output_path: Path, jira_key: str, status: str) -> None:
    manifest.setdefault("evaluations", []).append({"jira_key": jira_key, "status": status, "path": str(output_path), "generated_at": utc_now(), "tool_version": TOOL_VERSION})
    write_json(root / "manifest.json", manifest)


def main() -> None:
    parser = argparse.ArgumentParser(description="Evaluate a Jira benchmark against normalized ASC data.")
    parser.add_argument("--artifact-root", required=True)
    parser.add_argument("--jira-key", required=True)
    parser.add_argument("--goal", default="")
    args = parser.parse_args()
    evaluate(Path(args.artifact_root), args.jira_key, Path(args.goal) if args.goal else None)


if __name__ == "__main__":
    main()
