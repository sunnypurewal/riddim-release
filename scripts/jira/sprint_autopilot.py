#!/usr/bin/env python3
"""
Close the active Jira sprint and start the next sprint when repo work is done.

The script is intentionally dependency-free so it can run from GitHub Actions
without a package install step. It expects Jira basic auth credentials and a
GitHub token with repository read access.
"""
import argparse
import base64
import json
import os
import sys
import urllib.error
import urllib.parse
import urllib.request
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone
from typing import Any


JsonObject = dict[str, Any]


@dataclass(frozen=True)
class Sprint:
    id: int
    name: str
    state: str
    start_date: str | None = None
    end_date: str | None = None


@dataclass(frozen=True)
class Issue:
    key: str
    status: str
    status_category: str


@dataclass(frozen=True)
class Decision:
    should_advance: bool
    reason: str


class ApiClient:
    def __init__(self, base_url: str, headers: dict[str, str]):
        self.base_url = base_url.rstrip("/")
        self.headers = headers

    def request(
        self,
        method: str,
        path: str,
        *,
        params: dict[str, Any] | None = None,
        payload: JsonObject | None = None,
    ) -> JsonObject:
        query = ""
        if params:
            query = "?" + urllib.parse.urlencode(params)
        url = f"{self.base_url}{path}{query}"
        data = None
        headers = dict(self.headers)

        if payload is not None:
            data = json.dumps(payload).encode("utf-8")
            headers["Content-Type"] = "application/json"

        req = urllib.request.Request(url, data=data, headers=headers, method=method)
        try:
            with urllib.request.urlopen(req, timeout=30) as resp:
                body = resp.read().decode("utf-8")
        except urllib.error.HTTPError as exc:
            detail = exc.read().decode("utf-8", errors="replace")
            raise RuntimeError(f"{method} {url} failed with HTTP {exc.code}: {detail}") from exc

        if not body:
            return {}
        return json.loads(body)


def jira_client(base_url: str, email: str, api_token: str) -> ApiClient:
    auth = base64.b64encode(f"{email}:{api_token}".encode("utf-8")).decode("ascii")
    return ApiClient(
        base_url,
        {
            "Accept": "application/json",
            "Authorization": f"Basic {auth}",
        },
    )


def github_client(token: str) -> ApiClient:
    return ApiClient(
        "https://api.github.com",
        {
            "Accept": "application/vnd.github+json",
            "Authorization": f"Bearer {token}",
            "X-GitHub-Api-Version": "2022-11-28",
        },
    )


def paged_values(
    client: ApiClient,
    path: str,
    key: str,
    *,
    params: dict[str, Any] | None = None,
    start_field: str = "startAt",
    limit_field: str = "maxResults",
) -> list[JsonObject]:
    values: list[JsonObject] = []
    start_at = 0
    max_results = 50

    while True:
        page_params = dict(params or {})
        page_params[start_field] = start_at
        page_params[limit_field] = max_results
        data = client.request("GET", path, params=page_params)
        batch = data.get(key, [])
        values.extend(batch)

        if data.get("isLast") is True:
            break
        total = data.get("total")
        if total is not None and start_at + len(batch) >= int(total):
            break
        if not batch:
            break
        start_at += len(batch)

    return values


def get_active_sprint(client: ApiClient, board_id: str) -> Sprint | None:
    sprints = paged_values(
        client,
        f"/rest/agile/1.0/board/{board_id}/sprint",
        "values",
        params={"state": "active"},
    )
    if not sprints:
        return None
    sprint = sprints[0]
    return Sprint(
        id=int(sprint["id"]),
        name=sprint["name"],
        state=sprint["state"],
        start_date=sprint.get("startDate"),
        end_date=sprint.get("endDate"),
    )


def get_next_future_sprint(client: ApiClient, board_id: str) -> Sprint | None:
    sprints = paged_values(
        client,
        f"/rest/agile/1.0/board/{board_id}/sprint",
        "values",
        params={"state": "future"},
    )
    if not sprints:
        return None
    sprint = sprints[0]
    return Sprint(
        id=int(sprint["id"]),
        name=sprint["name"],
        state=sprint["state"],
        start_date=sprint.get("startDate"),
        end_date=sprint.get("endDate"),
    )


def get_sprint_issues(client: ApiClient, board_id: str, sprint_id: int) -> list[Issue]:
    raw_issues = paged_values(
        client,
        f"/rest/agile/1.0/board/{board_id}/sprint/{sprint_id}/issue",
        "issues",
        params={"fields": "status"},
    )
    issues: list[Issue] = []
    for issue in raw_issues:
        status = issue.get("fields", {}).get("status", {})
        issues.append(
            Issue(
                key=issue["key"],
                status=status.get("name", "unknown"),
                status_category=status.get("statusCategory", {}).get("key", "unknown"),
            )
        )
    return issues


def get_open_pull_requests(client: ApiClient, repo: str) -> list[JsonObject]:
    data = client.request(
        "GET",
        f"/repos/{repo}/pulls",
        params={"state": "open", "per_page": 100},
    )
    if isinstance(data, list):
        return data
    raise RuntimeError("GitHub pulls response was not a list")


def decide(incomplete_issues: list[Issue], open_pull_requests: list[JsonObject]) -> Decision:
    if incomplete_issues:
        keys = ", ".join(issue.key for issue in incomplete_issues)
        return Decision(False, f"Jira sprint still has incomplete issues: {keys}")
    if open_pull_requests:
        refs = ", ".join(f"#{pr.get('number')}" for pr in open_pull_requests)
        return Decision(False, f"Repository still has open pull requests: {refs}")
    return Decision(True, "Sprint issues are done and there are no open pull requests")


def close_sprint(client: ApiClient, sprint: Sprint) -> None:
    payload: JsonObject = {"state": "closed"}
    client.request("PUT", f"/rest/agile/1.0/sprint/{sprint.id}", payload=payload)


def start_sprint(client: ApiClient, sprint: Sprint, duration_days: int) -> None:
    now = datetime.now(timezone.utc).replace(microsecond=0)
    start = sprint.start_date or now.isoformat().replace("+00:00", "Z")
    end = sprint.end_date or (now + timedelta(days=duration_days)).isoformat().replace("+00:00", "Z")
    payload: JsonObject = {
        "state": "active",
        "startDate": start,
        "endDate": end,
    }
    client.request("PUT", f"/rest/agile/1.0/sprint/{sprint.id}", payload=payload)


def run(
    *,
    jira: ApiClient,
    github: ApiClient,
    board_id: str,
    repo: str,
    dry_run: bool,
    next_sprint_duration_days: int,
) -> int:
    active = get_active_sprint(jira, board_id)
    if active is None:
        print(f"No active sprint found on Jira board {board_id}; nothing to do.")
        return 0

    future = get_next_future_sprint(jira, board_id)
    if future is None:
        print(f"No future sprint found on Jira board {board_id}; cannot start the next sprint.")
        return 0

    issues = get_sprint_issues(jira, board_id, active.id)
    incomplete = [issue for issue in issues if issue.status_category != "done"]
    open_prs = get_open_pull_requests(github, repo)
    decision = decide(incomplete, open_prs)

    print(f"Active sprint: {active.name} ({active.id})")
    print(f"Next sprint: {future.name} ({future.id})")
    print(decision.reason)

    if not decision.should_advance:
        return 0
    if dry_run:
        print("Dry run enabled; would close the active sprint and start the next sprint.")
        return 0

    close_sprint(jira, active)
    print(f"Closed sprint {active.name} ({active.id}).")
    start_sprint(jira, future, next_sprint_duration_days)
    print(f"Started sprint {future.name} ({future.id}).")
    return 0


def env_bool(name: str, default: bool) -> bool:
    raw = os.environ.get(name)
    if raw is None or raw == "":
        return default
    return raw.lower() in {"1", "true", "yes", "on"}


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--jira-base-url", default=os.environ.get("JIRA_BASE_URL", ""))
    parser.add_argument("--jira-email", default=os.environ.get("JIRA_EMAIL", ""))
    parser.add_argument("--jira-api-token", default=os.environ.get("JIRA_API_TOKEN", ""))
    parser.add_argument("--jira-board-id", default=os.environ.get("JIRA_BOARD_ID", ""))
    parser.add_argument("--github-token", default=os.environ.get("GITHUB_TOKEN", ""))
    parser.add_argument("--github-repository", default=os.environ.get("GITHUB_REPOSITORY", ""))
    parser.add_argument("--next-sprint-duration-days", type=int, default=int(os.environ.get("NEXT_SPRINT_DURATION_DAYS", "14")))
    parser.add_argument("--dry-run", action="store_true", default=env_bool("DRY_RUN", True))
    args = parser.parse_args()

    required = {
        "jira-base-url": args.jira_base_url,
        "jira-email": args.jira_email,
        "jira-api-token": args.jira_api_token,
        "jira-board-id": args.jira_board_id,
        "github-token": args.github_token,
        "github-repository": args.github_repository,
    }
    missing = [name for name, value in required.items() if not value]
    if missing:
        print(f"Missing required configuration: {', '.join(missing)}", file=sys.stderr)
        return 2

    return run(
        jira=jira_client(args.jira_base_url, args.jira_email, args.jira_api_token),
        github=github_client(args.github_token),
        board_id=args.jira_board_id,
        repo=args.github_repository,
        dry_run=args.dry_run,
        next_sprint_duration_days=args.next_sprint_duration_days,
    )


if __name__ == "__main__":
    raise SystemExit(main())
