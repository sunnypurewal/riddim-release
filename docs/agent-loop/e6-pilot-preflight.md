# E6 Pilot Preflight

**Epic:** RIDDIM-98 — End-to-end pilot on epac  
**Parent initiative:** RIDDIM-91

Use this checklist before starting any E6 pilot run. E6 is the first production-repo walking skeleton for the autonomous PR loop, so the correct outcome is to stop and hand off if the dependency or budget gates are not closed.

---

## Start gates

All gates must be true before labeling any epac pilot issue with `agent:build`.

| Gate | Required evidence | If false |
| --- | --- | --- |
| E1 identities and secrets complete | RIDDIM-93 is Done; `CLAUDE_CODE_OAUTH_TOKEN`, `DEV_BOT_APP_ID`, `DEV_BOT_PRIVATE_KEY`, `REVIEWER_BOT_APP_ID`, and `REVIEWER_BOT_PRIVATE_KEY` are available to `riddim-release` and `epac` | Stop. Comment on RIDDIM-98 with the missing secret or app and link the blocking RIDDIM-93 child. |
| E2 developer workflow merged | RIDDIM-94 is Done and `.github/workflows/developer.yml` is on `riddim-release/main` | Stop. Link the open PR or ticket blocking developer workflow execution. |
| E3 reviewer workflow merged | RIDDIM-95 is Done and `.github/workflows/reviewer.yml` is on `riddim-release/main` | Stop. Link the open PR or ticket blocking reviewer approval. |
| E4 epac enrollment merged | RIDDIM-96 is Done; epac has the trigger wrapper, CODEOWNERS, labels, branch protection, and required `reviewer-agent-passed` check | Stop. Link the open epac enrollment PR or branch-protection gap. |
| E5 safety gates merged | RIDDIM-97 is Done; `agent:pause`, attempt caps, cap-hit handling, and guard scripts are on `riddim-release/main` | Stop. Do not run production-repo pilots without the safety gates. |
| E8/E9/E10 stale-PR path ready | RIDDIM-136, RIDDIM-137, and RIDDIM-138 are Done, or RIDDIM-91 explicitly narrows the E6 pilot to avoid stale/conflict coverage | Stop or record the explicit scope waiver on RIDDIM-98 before running. |
| Budget ceiling agreed | RIDDIM-98 has a kickoff comment with the ceiling template below filled in | Stop. Ask for the ceiling and do not spend pilot runs speculatively. |

---

## Budget kickoff comment template

Post this on RIDDIM-98 before starting pilot issue 1.

```markdown
E6 pilot kickoff budget ceiling:

- Max total pilot runs: 3 issue runs plus at most 1 retry per issue.
- Max wall-clock window: <fill in, e.g. 4 hours>.
- Max Claude/Max-plan messages: <fill in, e.g. 30 messages total>.
- Max API-token spend if any API fallback is used: <fill in dollar or token ceiling>.
- Stop condition: pause the pilot immediately when any ceiling is reached, apply `agent:pause` or `agent:needs-human` where appropriate, and comment on RIDDIM-98 with the run URL, PR URL, and observed spend.
- Approved by: <user / owner>.
- Approval timestamp: <YYYY-MM-DD HH:MM TZ>.
```

If the budget ceiling is unknown, E6 is blocked even if all workflow code is merged.

---

## Pilot issue selection

Select three epac issues that exercise the terminal paths without putting release-critical code at risk.

| Pilot | Shape | Safe examples | Avoid |
| --- | --- | --- | --- |
| 1 | Trivial clean merge | README copy, non-runtime docs, comment-only cleanup | SwiftData model changes, release workflows, signing, credentials |
| 2 | Small bug fix or test addition | Focused unit test, typo in non-user-facing config, small script assertion | Broad refactors, iOS navigation changes, App Store metadata |
| 3 | Ambiguous or cap-hit expected | Deliberately underspecified issue, large enough to exceed attempt/budget cap | Anything that could accidentally merge unsafe code if the guard fails |

Each pilot issue must name RIDDIM-98 and must include the expected terminal path in its issue body.

---

## Evidence to capture per pilot

Record the following on RIDDIM-98 after each run.

```markdown
E6 pilot run <1/2/3> evidence:

- Source issue:
- Trigger label timestamp:
- Developer workflow run:
- PR:
- Reviewer workflow run:
- Outcome: merged / merged-after-iteration / needs-human / blocked
- Wall-clock:
- Attempt labels observed:
- Rebase guard labels observed:
- Budget consumed:
- Notable prompt or workflow failures:
- Follow-up tuning ticket needed: yes/no, link if created
```

The final synthesis belongs in `docs/agent-loop/E6-pilot-evidence.md` after all three runs complete or the pilot is stopped by a budget/dependency gate.

---

## Current blocker handoff format

When E6 is still blocked, post a comment on RIDDIM-98 using this format and stop without opening pilot PRs.

```markdown
E6 preflight blocked on <YYYY-MM-DD HH:MM TZ>; no pilot PR opened.

Blocking gates:

- <Gate>: <precise missing dependency, ticket, PR, or setting>
- <Gate>: <precise missing dependency, ticket, PR, or setting>

Current open PRs checked:

- riddim-release: <links and mergeability>
- epac: <links and mergeability>

Next eligible action:

- Start pilot issue 1 only after the gates above are closed and the budget kickoff comment is posted.
```

Do not transition RIDDIM-98 to Done until all three pilot outcomes and the final `E6-pilot-evidence.md` synthesis are present.
