# E9 Spot-Check Protocol (E6 Pilot)

## Overview

During the E6 pilot, **100% of agent-resolved conflicts are manually reviewed**
before the spot-check sample rate is reduced. This document defines the checklist
reviewers use and how to escalate when the agent has silently changed intent.

---

## When to run this protocol

Run a spot-check on every PR where `agent-rebase.yml` resolved at least one
conflict marker and successfully pushed a rebased branch:

- PR was previously classified as `dirty`.
- Rebase completed path is `dirty` in the watcher status comment (state:
  `rebased-dirty`) written by `update-watcher-status.sh`.

---

## Spot-check checklist

For each agent-resolved PR, verify the following in order:

### 1. PR intent preserved

- [ ] Read the original PR description and any linked Jira acceptance criteria.
- [ ] Read the diff between the base branch and the new HEAD (`git diff origin/main..HEAD`).
- [ ] Confirm that every functional change in the diff was present in the original
  PR (before the rebase). No new logic, no removed logic outside conflict regions.
- [ ] Confirm the resolution did not silently adopt the base-branch version of a
  changed line when the PR-branch version should have won.

### 2. No logic changes outside conflict regions

- [ ] For each conflicting file, compare the agent's resolution against
  `git show ORIG_HEAD:<file>` (the pre-conflict PR-branch version).
- [ ] All edited lines must have been between `<<<<<<<` / `=======` / `>>>>>>>`
  markers in the conflicted state. Lines outside those regions must be identical
  to their pre-rebase state.
- [ ] The `validate-conflict-resolution.sh` script (run automatically by
  `agent-rebase.yml`) provides the initial signal; human spot-check confirms.

### 3. Tests would have caught intent drift

- [ ] Verify that the consuming repo's test suite meaningfully covers the
  conflicting code paths. If test coverage is weak, note it in the PR comment
  so the team can add tests.
- [ ] If a test failure was narrowly avoided by luck (e.g. the test covers an
  adjacent but not the exact changed line), flag for coverage improvement.

---

## How to escalate when intent was silently changed

If you find that the agent changed intent (even if tests passed):

1. **Revert the resolution commit** on the PR branch:
   ```bash
   git rebase --onto <sha-before-agent-resolution> <sha-of-resolution-commit> HEAD
   git push --force-with-lease
   ```
2. **Apply the `agent:needs-human` label** to the PR:
   ```bash
   gh pr edit <pr-number> --repo <owner/repo> --add-label "agent:needs-human"
   ```
3. **Post a PR comment** explaining what changed vs. the PR's stated intent and
   why the agent's resolution was incorrect. Include:
   - The file(s) where intent drifted
   - The line(s) that were incorrectly resolved
   - The correct resolution (if known)
4. **File a follow-up** in RIDDIM-137 comments with the PR number, the
   conflict pattern that caused the drift, and a suggested prompt or guard
   improvement for `conflict-resolver-v1.md` or `rebase-guard.sh`.

---

## Sample rate after pilot

After the E6 pilot completes without a trust-eroding regression (target: ≥20
cleanly resolved PRs with zero intent-drift findings), the sample rate may be
reduced to 20% spot-checks at the team's discretion. Any intent-drift finding
after the reduction resets the clock to 100% for the next 10 PRs.
