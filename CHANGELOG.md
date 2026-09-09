# Changelog

## 1.10.0 (build 39) — 2026-09-09

- Add Activity on Mac, iPhone and iPad: open projects, every Solo agent, Team tasks, Roundtable and native CLI session status across up to eight paired Macs. Search by project, agent or task; filter working items and pending decisions.
- Keep each viewer's project, mode and agent independent of the host Mac and other viewers. Block controls until the destination is confirmed, and route Stop to that destination.
- Keep offline snapshots visibly stale, reconnect each host independently, and preserve unsent drafts per project, mode and provider while the app is running.
- Return to Activity after successfully forgetting a Mac, and explain empty working, decision and search filters.
- Share the remote client between platforms. Store all pairings and relay credentials in Keychain, migrating the previous phone pairing only after a successful secure write.
- Relay 2 supports up to eight viewers per Mac with separate encrypted sessions, bounded routing, targeted revocation and safe Mac replacement. Older relays remain usable with one viewer; owners must update their Worker for multiple viewers.
- Include the relay code, tests and deployment configuration in source archives; exclude local dependencies and relay state. Pin relay development tools and resolve the vulnerable image-processing dependency.
- Orrery Remote 1.3 (5) uses the shared dashboard. The public release remains source-only; iOS signing and optional relay deployment belong to each user.

## 1.9.0 (build 37) — 2026-09-08

- Team keeps the orchestrator selector visible and removes unrelated Solo provider/model controls from Team and Roundtable.
- Select skills, attach text files, or attach editor context directly to Team. Each role receives a bounded context snapshot, without resending it on every pooled turn.
- Use an existing plan to skip the planner turn while retaining implementation and independent review. Agent work still uses provider allowance.
- Persist unsent Team drafts, context, planning mode and lead. Clear context when changing projects and show preparation failures in Team.
- Simplify connection cards and mount long settings lists as needed to reduce opening and layout stalls.
- Distinguish missing, installed, connected and expired agent accounts during setup. Explain missing macOS or Swift prerequisites before installation. Let idle agents use their existing accounts without repeating sign-in.
- Make file search results accessible buttons and prevent Down then Return on an empty result list from producing an invalid index.
- Add an Orrery update check against the public release feed. Handle incomplete provider update responses, numeric prereleases, empty versions and failed updates honestly.
- Require notarization for a public binary release. This release distributes installable source; it includes no notarized binary.
- Extend the public guard to historical file versions and author/committer metadata, renamed public remotes, missing private denylists, symlinks, private configuration files and unreviewed binaries. The previous guard did not adequately check historical metadata.
- Replace session-specific public documentation with installation and contributor guidance. Export packages automatically apply the local privacy denylist.

## Earlier releases

- 1.8: skills compatibility, session reuse, Roundtable steering and resume, remote relay, command palette and native computer integrations.
- 1.7: studio layout, shared connections, first-run setup and native transcript rendering.
- 1.6 and earlier: isolated task working copies, recovery, review/apply/undo, provider adapters, native editor, terminals and language tools.
