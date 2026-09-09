# Bug ledger

## Addressed in 1.9.0

| Defect | Correction and coverage |
|---|---|
| Team hid its orchestrator under collapsed options | Visible setup picker; hosted-view audit and live selection checks. |
| Team lacked direct reference and skill attachments | Bounded text snapshots, project/user skill discovery, direct delivery to every role; scripted multi-item and supplied-plan checks. |
| Team drafts and preparation errors could be lost or hidden | Per-project draft persistence and visible notices; disk round-trip and context isolation checks. |
| Solo model controls appeared in Team and Roundtable | Mode-specific controls. |
| Idle agents offered only sign-in during setup | Offer Use agent for installed agents; keep explicit sign-in for expired accounts. |
| Empty file-search keyboard navigation could select a negative index | Clamp navigation and refuse invalid results; accessible result buttons also support activation. |
| Connection settings could stall during layout | Lazy settings and connection lists, simpler cards; a real 100-connection hosting test bounds native controls and layout time. |
| Incomplete updater data could say up to date | Response validation, safe version comparison and visible failure reporting. |
| Public history metadata and deleted private files escaped checks | Scan every pushed commit tree and author/committer metadata; Python regression fixtures cover historical deletion and private identities. |
| First installation failed obscurely with old tools | macOS/Swift prerequisite messages; installer fixtures cover unsupported and successful setups. |

## Limits requiring real external setup

- Public binary signing and notarization require a Developer ID certificate and a configured notarization profile. The source release is locally buildable.
- Every provider account and external MCP sign-in must be configured by its user; scripted audits cannot validate those credentials.
- Native Claude computer control needs the interactive CLI. Shared desktop screenshots cover the main display.
- iOS device distribution requires the user's signing and distribution account.
- The main-thread watchdog records stalls; isolated native UI checks do not establish that every possible long-running workspace is free of layout stalls.
- Replacing public Git history removes old commits from advertised branches. Previously cached commits, forks and clones require separate removal by their holders or the hosting service.
