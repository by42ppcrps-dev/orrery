# Orrery contributor handoff

Read README.md for current installation and behavior, CHANGELOG.md for shipped changes and BUG-LEDGER.md for known limits.

## Project map

- `Sources/Orrery/Orchestrator`: Team scheduling, roles, session reuse and direct context.
- `Sources/Orrery/Tasks`: bounded task persistence and isolated working copies.
- `Sources/Orrery/Views`: native workspace, Team, setup, connections and settings.
- `Sources/Orrery/Audit`: repeatable functional and layout checks.
- `scripts/public_guard.py`: committed-tree and history privacy checks.
- `scripts/export_public.py`: allowlisted, history-free source package.

## Verification and release

Run `swift build`, one `.build/debug/Orrery --audit`, `swift test`, and the Python unittest discovery shown in README. Focused audit suites help reproduce regressions. Use exact, reversible mutations to demonstrate regression checks fail; do not restore entire files over another contributor's work. Skips need an explicit missing prerequisite and reason.

Build locally with `build-app.sh`. Increment VERSION and BUILD for installed changes. Quit an idle app before replacing it, retain the previous bundle and verify the installed version. Distribution binaries require Developer ID and successful notarization; source releases do not include signing credentials.

Public push order is private origin first, then public. Keep historical private branches off public. Use a neutral maintainer commit identity and the ignored, owner-only `.public-guard-terms` denylist. Do not publish local handoffs or verification evidence. Store local evidence in ignored `docs/verification-*`; public screenshots must use a clean demonstration project and be visually reviewed.

Preserve project trust, explicit access settings, cancellation, stale-session protection, bounded inputs, symlink refusal, atomic writes and credential isolation. Never put secrets in process logs or source files.
