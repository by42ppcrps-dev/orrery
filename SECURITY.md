# Security

Orrery runs third-party coding agents against your files, so its security model is
explicit and tested. This page says what is protected, what is not, and how to report a problem.

## Reporting

Please report vulnerabilities privately through the repository's security advisory feature
("Report a vulnerability") rather than in a public issue. Include the app version (About, or
`CFBundleShortVersionString` in `build-app.sh`), the provider CLI versions, and steps to
reproduce. Expect an acknowledgement within a week.

## What the app protects

- **Credentials.** Subscription sign-in is left entirely to each CLI's own store. API keys you
  paste are stored in the macOS Keychain (`kSecAttrAccessibleWhenUnlockedThisDeviceOnly`), read
  once per child launch, handed only to that provider's processes as its documented variable,
  never logged, never written to disk in plain text. Presence is checked by attributes only.
- **Environment hygiene.** Every child environment starts from a sanitized copy of the app's
  environment: `*_API_KEY`, `*_TOKEN`, `*_SECRET`, `*_PASSWORD`, `AWS_*`, `AZURE_*`, Google
  credential paths, `DYLD_*`/`LD_*`, `NODE_OPTIONS`, `PYTHONPATH` and shell startup overrides
  are removed before anything project-specific is merged in.
- **Write confinement.** Provider and native-CLI children run under a sandbox-exec profile that
  allows writes only inside the project (or the task's isolated working copy) and the caches the
  CLI needs, and denies credential folders of other providers. Full Access is an explicit,
  labeled per-project choice.
- **Project trust.** Nothing runs in a project until it is trusted; automatic tool approval is a
  separate, per-project setting; stale sessions are refused.
- **Local files.** Settings, task history, working copies, usage records and captures are
  written atomically with owner-only permissions; symlinks are refused where a path is opened for
  writing; inputs are bounded.
- **Local UI verification.** The verifier's WebKit view can only reach loopback addresses, with
  content rules that block everything else, and it has no access to native apps.
- **IDE tools and the browser.** Agent sessions of a trusted project get IDE tools (tasks,
  problems, search, editor navigation) that run only what the project itself defines. The
  Browser pane's navigation is limited to the user's allowed sites plus loopback; its sign-ins
  live in an app-private data store; the `browser_*` tools exist only while the user has
  switched them on, and on those sites an agent acts as the signed-in user, which the settings
  say in plain words. Desktop control (screenshots, clicks) needs a separate explicit grant.

- **Plugins and registries.** Plugins are folders of scripts run as child processes, never
  code loaded into the app; they get a sanitized environment, a 60-second limit and a 4 MB
  output cap. A project's registry and plugins load only when the project is trusted and you
  have allowed them for that folder (the consent is tied to the folder's identity like trust).
  Loading never runs a command. A plugin's MCP server reaches every agent session it declares
  itself for, so read a plugin before enabling it.

## What it does not protect

- Codex's own sandbox cannot start inside the confinement profile (macOS refuses nested
  profiles), so under *Confine local writes* Codex runs with its sandbox off and the confinement
  profile is its only boundary; plan mode makes the project read-only in that profile.
- Remote control (Agent settings → Remote) is off by default. Pairing needs a one-time code
  shown on the Mac that expires in five minutes and is consumed on use; the code also binds
  the pairing key, so a wrong code cannot even be read. Sessions use both static and fresh
  ephemeral Curve25519 keys, frames are ChaCha20-Poly1305 with strictly increasing counters
  (replays and reorders are refused and the session dropped), unpaired devices get no session,
  and a removed device is cut off at once. A phone can only do what the window can: send,
  approve, stop. The Mac's private key is a local file under `Application Support/Orrery/Remote`
  (owner-only). An optional self-hosted relay forwards encrypted frames; pairing does not
  require an Orrery account.
- *Bypass every tool approval everywhere* (Agent settings → Tools) is a global switch that
  removes every tool and computer-action prompt in every project and mode. It is off by
  default and labeled in every pane it affects. macOS Accessibility and Screen Recording
  permissions still require the user's approval.
- Roundtable Work mode runs every agent in one isolated working copy under the same write
  confinement and the same per-project approval rule as Solo and Team; Discuss mode refuses
  every tool approval. Nothing reaches the project until the user applies it from Changes.
- The write boundary is a *write* boundary: confined agents can still read most files your user
  can read and can reach the network.
- Third-party MCP servers started by a provider are confined only because they are children of
  the confined process; the app does not wrap them itself and does not claim to.
- The native CLI pane edits the project directly and bypasses the Changes review.
- Desktop computer-use tools act with your user's Screen Recording and Accessibility grants.
- Provider configuration files may contain secrets you put there; the app keeps them owner-only
  but does not scan or rewrite them.

## Verifying

`Orrery --audit --security-only` exercises the sanitizer, the profile, the symlink refusal,
and the atomic owner-only writes; `--accounts-only` covers the Keychain-backed account modes with
an in-memory store; `--keychain-probe <provider>` exercises the real Keychain with a throwaway
key and removes it; the full `--audit` runs a sandboxed probe that must succeed inside the
boundary and fail outside it.
