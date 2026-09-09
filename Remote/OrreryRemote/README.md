# Orrery Remote 1.3 (5)

The iPhone and iPad companion for Orrery 1.10.0. Activity shows open projects, Solo agents,
Team tasks, Roundtable and native CLI session status across up to eight paired Macs. Each
viewer keeps its own selected project, mode and provider. Host windows are not switched by
viewing a remote conversation. Each Mac accepts up to eight simultaneous viewers.

## Setup

1. Open `OrreryRemote.xcodeproj` in Xcode. Choose a simulator and Run, or choose your own signing
   team and bundle identifier for a physical device. Public source contains no signing account.
2. Keep each host Mac awake with Orrery open. Enable Agent settings → Remote → Allow control
   from paired devices, then choose Pair a Device.
3. In Activity, choose Add a Mac. Scan or paste the code. Repeat for your other Macs and devices.
4. Select activity to read a conversation, send a message, answer a decision or stop its work.

Use the same network, your VPN, or a self-hosted `Remote/OrreryRelay` Worker. Configure a relay on
the Mac before pairing so the code carries its address and room credential. The client tries
direct addresses before the relay. Update existing Workers to Relay 2 for multiple viewers;
older relay deployments support a single viewer. Hosting may incur charges on your own account.

Pairing codes expire after five minutes and are consumed once. Every viewer has a Keychain
identity; all saved Mac pairings and relay credentials also stay in Keychain. The old single-Mac
phone pairing migrates only after secure storage succeeds. No provider credentials are copied
to the viewer. Remove a device on a host Mac to revoke its access; Forget Mac removes the local
saved connection. This is direct device pairing, not an Orrery cloud account.

Messages use Curve25519 key agreement and ChaCha20-Poly1305 with per-session replay counters.
Each relay viewer has a separate encrypted session. A relay can see connection metadata and
ciphertext, but cannot read authenticated conversation contents. It stores only a room-token
hash. Nothing automatically resends a prompt after connection loss.

Offline snapshots are marked with the last received time. Drafts are separated by project,
mode and provider; they clear only after confirmed acceptance. Drafts and transcripts are kept
in memory while the app is running, not persisted on viewers. The app switcher hides content.
Native CLI output and provider-owned permission prompts stay on the host Mac. Trust and access
settings are managed on the Mac. Chats started outside Orrery are not imported.

## Verify and distribute

The shared client and protocol are in `../OrreryRemoteProtocol`. The Mac `--remote-only` audit
uses the shipping clients against real WebSocket hosts and the actual local relay Worker:
pairing, concurrent viewers, per-viewer routing, background activity, delivery, approval,
cancellation, reconnect, storage failures and revocation. Install relay test dependencies with
`npm ci` in `../OrreryRelay` before running that audit.

The source release includes no App Store or TestFlight binary. To distribute your own build,
select your team locally in Xcode, use your own bundle identifier, Archive for a generic iOS
device and choose Distribute App in Organizer. App Store Connect processing and tester access
are separate steps. Review privacy and encryption declarations for your distribution. The
source project deliberately carries no developer account, team identifier or provisioning file.
