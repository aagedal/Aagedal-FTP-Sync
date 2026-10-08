# Coordinator and checklist setup verification — 2026-09-09

Scope: scheduling and manual-test infrastructure only. No 3.0 application feature,
model, supported OS, or release readiness is asserted by this report.

Source baseline: `d6661e2c14d831c2f40a897ce0a0cdcd911ae213`, with this setup's uncommitted
files during verification. The setup commit containing this report identifies the final
artifact. Interpreter: Homebrew Python 3.14.7; UI: Codex in-app browser on the local Mac.

## Automated verification

`python3 Scripts/test-3.0-checklist.py` — 5 tests passed after final server changes:

- Results survive server restart; user/agent lanes and history stay separate.
- Stale revisions are rejected without overwriting results.
- Missing token/origin, invalid statuses, missing evidence and stale candidates are rejected.
- Corrupt persisted JSON is preserved, with an explicit read failure.
- A second server cannot acquire the same results-file lock.
- Agent submissions cannot complete the user-only acceptance case.

`node --check /tmp/ftp-checklist-syntax.js` validates the extracted inline script.
`git diff --check` checks whitespace before the setup commit.
Catalog validated: 42 unique cases, each with prerequisites, numbered steps and expected
results. 41 require agent evidence before handoff; `m6-004` belongs to the user's final
acceptance. All 42 remain required for final human acceptance of the candidate.

## Independent review and fixes

A separate reviewer identified save/reload races and conflict recovery shortcomings.
Submitted controls are now locked through save/load, reload restores unsaved drafts,
pending drafts force the relevant tests visible regardless of filters, and removed cases
or candidate changes refuse to discard pending notes. An unsaved-notes export provides
an additional recovery path. The reviewer found the readiness protocol conservative,
with explicit real-model/OS evidence, independent review and final user acceptance.

## Observed browser checks

Opened a separate test server at 127.0.0.1:8764 with results under `/tmp`, never the
user's durable checklist result file. Through browser controls:

1. Loaded all 42 human cases; switched to agent mode and observed 41 required cases.
2. Expanded the first case and inspected setup, numbered actions and expected outcomes.
3. Entered a synthetic Blocked result, environment and notes; Save reported saved to disk.
4. Reloaded the browser, selected agent mode and saw the saved Blocked result, environment,
   notes and count restored.
5. Entered new unsaved notes and used Reload saved results. The same draft remained visible
   and explicitly unsaved, ready for a deliberate save.
6. Inspected a screenshot: readable dark appearance, wrapping controls, visible details.

Synthetic results stay outside the repository result file. These observations validate
checklist behavior; they do not pass any app acceptance case. Accessibility for the app,
mobile checklist viewport, final candidate UI labels/fixture paths and final app testing
remain for later implementation/verification cycles.

## Scheduled continuation

Created ACTIVE heartbeat `ftp-sync-3-0-implementation-coordinator`, every 10 minutes,
attached to this task. Its saved prompt reads the protocol, plan, readiness, candidate and
local results; implements with sub-agents, local commits and computer testing; pauses and
notifies on verified handoff or three fully blocked cycles. The separate Photo Agent
coordinator is unchanged. Public release remains after user testing and authorization.
