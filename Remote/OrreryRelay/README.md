# Orrery Relay

A small Cloudflare Worker so the iPhone app can reach a Mac that is not on the same network.

- One Durable Object per Mac. The Mac keeps an outbound WebSocket to `/mac/<room>`, the phone
  connects to `/phone/<room>`, and frames are forwarded unchanged in both directions.
- Nothing is readable at the relay: every frame is sealed end to end by the Orrery remote
  protocol before it leaves either device. The relay checks one thing — that both sides carry
  the room's token, made at pairing and carried in the QR code — so nobody else can take a room.
- No accounts, no storage of messages; the only stored value is the room token.

Deploy with your own Cloudflare account:

```bash
cd Remote/OrreryRelay && npx wrangler deploy
```

Then paste the Worker URL (for example `https://orrery-relay.<you>.workers.dev`) into Agent
settings → Remote → Relay on the Mac and pair the phone again so its QR code carries the relay
address and room token. The Mac and phone client integration is tracked in `docs/HANDOFF.md`.
