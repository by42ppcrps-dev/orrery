# Orrery Remote (iPhone)

Orrery Remote 1.1 is the phone companion for Orrery 1.8.5 or later. Choose an open project,
follow its conversation, send messages to Solo, Team or Roundtable, answer approval requests,
and stop work. Mode and agent choices immediately change the conversation being viewed.
The interface uses a dark native design, readable message cards, a multiline composer,
per-project drafts, connection recovery and an app-switcher privacy cover.

## Pair and use

1. Keep Orrery open and the Mac awake. Open Settings → Remote and enable remote control.
2. Choose Pair a Device. In the phone app, scan the code or paste the copied pairing code.
3. Choose a project and conversation mode, then send your request.

Pairing codes expire after five minutes and are consumed after pairing. Each phone has its own
Keychain identity; remove a paired device on the Mac to revoke access. Messages are encrypted
between the phone and Mac using Curve25519 and ChaCha20-Poly1305, with replay refusal.
No relay or provider credentials are stored on the phone. Both devices need the same reachable
network, or a private VPN when away. Network changes trigger bounded reconnect attempts;
the Mac keeps its listening port across restarts. The app never automatically resends a prompt.
Drafts clear only after the Mac acknowledges acceptance and remain separate per project while
the app is running. Force-quitting the phone app does not preserve unsent drafts.

The phone controls conversations, not a streamed desktop. Native CLI terminals and provider
computer-control permission prompts stay on the Mac. The phone cannot enable computer control,
change the Mac's approval policy or grant itself more access. Older Macs without command
acknowledgements remain viewable but must be updated before sending or approving from this app.

## Development

Open `OrreryRemote.xcodeproj` in Xcode. Choose a supported iPhone simulator and Run.
A DEBUG-only `--pair <code>` launch argument supports local verification. Release builds have
no pairing or message-sending launch hooks. Camera denial has a paste-code fallback.
The shared wire package lives in `../OrreryRemoteProtocol`; its Mac audit includes real
WebSocket pairing, encrypted messages, acknowledgement, multi-project routing and revocation.

## TestFlight

Use your own bundle identifier and developer team. The project intentionally has no signing
team or account embedded. Pass your team as a local build setting or configure it locally in
Xcode. Increment `CURRENT_PROJECT_VERSION` for every upload. Archive for a generic iOS device,
then choose Distribute App → App Store Connect in Xcode Organizer. The included export options
also support Xcode's command-line upload workflow. If Xcode 26.2 stalls in SDK stat-cache creation,
`SDK_STAT_CACHE_ENABLE=NO` can be passed for that build without changing system settings.

The privacy manifest declares only app-local UserDefaults access (CA92.1), no tracking and no
collected-data categories. Pairing state stays on the device. Camera and local-network usage
explanations are included. Review these declarations if you add analytics, relays or other data
collection. App Store Connect processing and tester eligibility are required after upload.


## Reaching the Mac from another network (1.2)

If the Mac's pairing code carries a relay (Agent settings → Remote → Relay on the Mac, backed by
the `Remote/OrreryRelay` Worker), the app tries every local address first and then connects
through the relay at `wss://<relay>/phone/<room>?token=…`. The status line says "via relay".
Everything stays sealed end to end; the relay only checks the room token.


### Uploading 1.2 (3)

The project carries no team id (public source). Archive from Xcode's Organizer with your account
signed in, or from a shell that can see that account:

```bash
xcodebuild -project OrreryRemote.xcodeproj -scheme OrreryRemote -destination 'generic/platform=iOS' \
  -configuration Release -archivePath build/OrreryRemote.xcarchive -allowProvisioningUpdates \
  DEVELOPMENT_TEAM=<your team id> archive
xcodebuild -exportArchive -archivePath build/OrreryRemote.xcarchive -exportOptionsPlist ExportOptions.plist \
  -exportPath build/export -allowProvisioningUpdates
```

`ExportOptions.plist` uploads to App Store Connect directly (`destination: upload`).
