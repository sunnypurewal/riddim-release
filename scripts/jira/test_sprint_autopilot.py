#!/usr/bin/env python3
import unittest
from contextlib import redirect_stdout
from io import StringIO

import sprint_autopilot


class FakeClient:
    def __init__(self, responses=None):
        self.responses = responses or []
        self.requests = []

    def request(self, method, path, *, params=None, payload=None):
        self.requests.append(
            {
                "method": method,
                "path": path,
                "params": params,
                "payload": payload,
            }
        )
        if not self.responses:
            return {}
        return self.responses.pop(0)


class SprintAutopilotTests(unittest.TestCase):
    def test_decision_blocks_incomplete_issues(self):
        issue = sprint_autopilot.Issue("RIDDIM-1", "In Progress", "indeterminate")

        decision = sprint_autopilot.decide([issue], [])

        self.assertFalse(decision.should_advance)
        self.assertIn("RIDDIM-1", decision.reason)

    def test_decision_blocks_open_pull_requests(self):
        decision = sprint_autopilot.decide([], [{"number": 42}])

        self.assertFalse(decision.should_advance)
        self.assertIn("#42", decision.reason)

    def test_decision_allows_advance_when_done_and_no_open_prs(self):
        decision = sprint_autopilot.decide([], [])

        self.assertTrue(decision.should_advance)

    def test_run_closes_active_sprint_and_starts_future_sprint(self):
        jira = FakeClient(
            [
                {"values": [{"id": 10, "name": "Sprint 10", "state": "active"}], "isLast": True},
                {"values": [{"id": 11, "name": "Sprint 11", "state": "future"}], "isLast": True},
                {
                    "issues": [
                        {
                            "key": "RIDDIM-1",
                            "fields": {
                                "status": {
                                    "name": "Done",
                                    "statusCategory": {"key": "done"},
                                }
                            },
                        }
                    ],
                    "isLast": True,
                },
            ]
        )
        github = FakeClient([[]])

        with redirect_stdout(StringIO()):
            result = sprint_autopilot.run(
                jira=jira,
                github=github,
                board_id="7",
                repo="RiddimSoftware/riddim-release",
                dry_run=False,
                next_sprint_duration_days=14,
            )

        self.assertEqual(result, 0)
        self.assertEqual(jira.requests[-2]["method"], "POST")
        self.assertEqual(jira.requests[-2]["path"], "/rest/agile/1.0/sprint/10")
        self.assertEqual(jira.requests[-2]["payload"], {"state": "closed"})
        self.assertEqual(jira.requests[-1]["method"], "POST")
        self.assertEqual(jira.requests[-1]["path"], "/rest/agile/1.0/sprint/11")
        self.assertEqual(jira.requests[-1]["payload"]["state"], "active")
        self.assertIn("startDate", jira.requests[-1]["payload"])
        self.assertIn("endDate", jira.requests[-1]["payload"])

    def test_run_dry_run_skips_mutations(self):
        jira = FakeClient(
            [
                {"values": [{"id": 10, "name": "Sprint 10", "state": "active"}], "isLast": True},
                {"values": [{"id": 11, "name": "Sprint 11", "state": "future"}], "isLast": True},
                {"issues": [], "isLast": True},
            ]
        )
        github = FakeClient([[]])

        with redirect_stdout(StringIO()):
            sprint_autopilot.run(
                jira=jira,
                github=github,
                board_id="7",
                repo="RiddimSoftware/riddim-release",
                dry_run=True,
                next_sprint_duration_days=14,
            )

        methods = [request["method"] for request in jira.requests]
        self.assertNotIn("POST", methods)


if __name__ == "__main__":
    unittest.main()
