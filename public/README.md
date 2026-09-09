# Orrery

Build with Grok, Claude Code and Codex in one native Mac workspace, using your own accounts. Work with one agent, let a Team plan and review changes, or bring agents together in a Roundtable.

**1.9.0 · macOS 14+ · Swift 6 · MIT license**

## Install

1. Install **Xcode 16 or newer** from the Mac App Store. Open it once to finish setup. In Xcode → Settings → Locations, select its Command Line Tools.
2. Download **Orrery-1.9.0-source.zip** from the [latest release](https://github.com/by42ppcrps-dev/orrery/releases/latest) and unzip it.
3. Double-click **Install.command** in the Orrery folder. The first local build takes several minutes and installs the app in Applications. If macOS blocks the downloaded script, review the source and use System Settings → Privacy & Security → Open Anyway, or run `bash Install.command` from that folder in Terminal.
4. Open Orrery, create a project or open a folder, then choose **Workspace setup**. Install and sign in to one agent to start. Add more whenever you need them.

This is a **source release**, built on your Mac. It does not include a notarized app download. You need Xcode for installation; agent subscriptions or API usage are separate. No Orrery account is required.

To update, quit Orrery and run the new release's installer. Your projects, settings and accounts are retained. **Orrery → Check for Updates…** opens the current public release when one is available.

## Choose how to work

| Mode | Use it for |
|---|---|
| **Solo** · ⌘1 | Ask one agent to build, debug or explain a project. |
| **Team** · ⌘2 | Choose the orchestrator, attach skills and context, then let workers implement and review a plan. |
| **Roundtable** · ⌘3 | Discuss an idea with multiple agents, or use Work to give them access to enabled tools. |
| **CLI** · ⌘4 | Use the provider's native interactive interface and commands. |

In **Team**, the orchestrator selector is always visible. **Add skills** searches installed and project skill folders; **Attach files** and **Editor context** provide reference material directly. Every planner, author and reviewer receives your selected text. Supporting files remain subject to the agent's existing file permissions. Attach up to eight text files, 128 KB total. Your unsent task, selected lead, planning choice and attachments are saved for the project.

Already prepared a plan in ChatGPT or elsewhere? Choose **Use my plan · skip the planner turn** and paste it in. A worker implements it and a separate review follows. This saves the planning turn; implementation and review still use your provider's allowance. Orrery does not automate ordinary ChatGPT Chat as its engine. ChatGPT's optional GitHub connection can provide read-only repository context; availability and limits depend on your plan.

Team and Solo changes use isolated working copies. Open **Changes** to review and apply them to the project. Running agents cannot silently apply over newer edits. Stop cancels active work; interrupted tasks return for review and do not automatically resume.

## Connect your agents and tools

- [Grok installation](https://x.ai/build)
- [Claude Code quickstart](https://code.claude.com/docs/en/quickstart)
- [Codex CLI installation](https://developers.openai.com/codex/cli/)

Choose a subscription sign-in or store your own API key in macOS Keychain. **Connections** imports MCP settings, offers templates and accepts pasted setups. Choose which agents receive each connection. Remote services may require their own sign-in inside the native CLI.

The editor includes syntax highlighting, language services, search, Git changes, build tasks, terminals, image/video previews, an embedded browser and an optional iPhone Simulator surface. **⌘⇧P** opens the command palette; **⌘⌥/** lists shortcuts. **Code / Studio / Focus** controls how much space the editor and assistant receive.

Desktop control needs the macOS permissions shown in Tool access. The browser uses separate embedded tools. Claude's native desktop tool requires its interactive CLI and Full macOS account access; the non-interactive connection can use Orrery's shared tools instead. Codex's native tools depend on its installed Computer Use integration. These integrations and their accounts are not bundled.

## Privacy and permissions

Public source and release packages exclude local accounts, credentials, project lists, conversations, verification logs, signing identities and provisioning files. Documentation screenshots use a disposable demo project. `scripts/public_guard.py` scans committed files, historical versions and commit identities before public pushes; `scripts/export_public.py` creates a history-free package from an allowlist. Keep personal denylist terms in the ignored `.public-guard-terms` file.

Your chosen AI provider receives the prompt and context you send. Projects must be trusted before running tools. Automatic approvals, shared computer access and Full macOS account access are explicit settings. File confinement limits local writes; it is not a network or complete confidentiality sandbox. Cancellation and existing provider permissions remain in effect.

## Build and verify

```sh
swift build
.build/debug/Orrery --audit
swift test
python3 -m unittest discover -s Tests -p 'test_*.py'
./build-app.sh --install
```

Run only one audit at a time. Checks requiring unavailable tools print a skip reason. The audit uses scripted agents for repeatable orchestration checks without spending provider quota; this does not prove every external account or service is connected.

The optional iOS companion and relay live under `Remote/`. They require your own setup and signing. A binary intended for other Macs must use `build-app.sh --release` with Developer ID signing and a notarization profile; the script refuses an incomplete distribution setup.

See [CONTRIBUTING](CONTRIBUTING.md), [SECURITY](SECURITY.md) and [LICENSE](LICENSE).
