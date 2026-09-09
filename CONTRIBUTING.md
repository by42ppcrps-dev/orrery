# Contributing

Orrery is a Swift 6 / SwiftUI / AppKit app with a local package for the optional remote protocol. It builds with the Xcode
toolchain on macOS 14 or later:

```bash
swift build
swift test
python3 -m unittest discover -s Tests -p 'test_*.py'
.build/debug/Orrery --audit        # the whole suite, headless, spends no quota
./build-app.sh --install               # signed app bundle in /Applications
```

## The rule for changes

A change is done when a check that would fail without it passes. Every feature and every fix
lands with an audit check in `Sources/Orrery/Audit/`, and the check is proven by breaking
the code once and watching it fail. Focused subsets keep the loop short:
`--recovery-only`, `--tasks-only`, `--security-only`, `--verification-only`,
`--languages-only`, `--accounts-only`, `--inline-only`, `--registry-only`, `--plugins-only`,
`--team-single-only`, `--studio-only`, `--windows-only`, `--skills-only`,
`--connectors-only`, `--updates-only`.
`swift test` runs the full suite through XCTest.

Audits must not touch the user's data: headless runs use a wiped private `UserDefaults` suite,
an in-memory key store instead of the Keychain, temporary directories for every file, and
scripted stand-ins for the provider CLIs (`ScriptedBackend`, `/bin/sh` scripts on the wire).
Live provider probes (`--probe`) spend quota and are run by hand, never by the suite;
`--keychain-probe <provider>` checks the real Keychain path with a throwaway key.

## What must stay true

These are enforced in code and checked by the suite; a pull request that weakens one of them
needs a very good reason in its description:

- Credentials belong to the CLIs (subscription) or to the macOS Keychain (API credits). No new
  plaintext secrets, no key in logs, no key passed to a provider other than its own.
- Inherited `*_API_KEY`, `*_TOKEN`, `*_SECRET`, cloud and dynamic-loader variables are stripped
  from every child environment before anything is merged in.
- Provider children run under the sandbox-exec write boundary unless the user chose Full Access,
  which is labeled as such everywhere it shows.
- Project trust, automatic-tool settings, cancellation, stale-session protection, symlink
  refusal, bounded inputs and atomic owner-only writes are preserved.
- No idle polling, hashing or per-keystroke disk writes; workspaces are created when work
  begins; idle sessions are releasable; child launches are never duplicated.
- The app only ever signals its own child processes.

## Style

Swift 6 language mode with strict concurrency; `@MainActor` for UI-facing models, no `@unchecked
Sendable` without a comment saying why. Prefer data tables over `switch` ladders (see
`Editor/Language.swift`, `Diagnostics/Checkers.swift`, `LSP/LSPManager.swift`). Comments explain
why, not what. User-facing text names the real thing that happened ("pyright-langserver is not
installed") instead of a generic failure.

## Reporting bugs

Open an issue with the `--audit` output for the smallest focused subset that shows the problem,
the provider CLI versions (`grok --version`, `claude --version`, `codex --version`) and the
macOS version. For anything security-related, follow [SECURITY.md](SECURITY.md) instead.

## No personal data in the tree

`scripts/public_guard.py --tree HEAD` refuses home paths, signing team ids, tokens, private keys,
credential URLs and evidence folders (`docs/verification-*`), and CI runs it on every push. A
maintainer's checkout also runs it as a `pre-push` hook for the remote named `public`, with a
local, ignored `.public-guard-terms` file listing names that must never appear. The hook also
checks every historical file version and commit identity, recognizes the public repository
even under a different remote name, and refuses a missing denylist. Commit with the neutral
identity `Orrery Maintainers <maintainers@users.noreply.github.com>`. Keep
screenshots under `docs/images/` and check them by eye before committing.
