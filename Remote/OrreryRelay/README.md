# Orrery Relay 2

An optional Cloudflare Worker connecting Orrery viewers to Macs on other networks. One room
per Mac, with up to eight simultaneous viewers. Every viewer has its own end-to-end encrypted
session; the Worker routes opaque envelopes by channel and never broadcasts a viewer's reply.
Pairing and authentication are verified by the Mac. A room token gates access to the relay;
only its SHA-256 hash is stored, and existing stored tokens migrate automatically.

## Set up or update

```sh
cd Remote/OrreryRelay
npm ci
npm test
npm run deploy
```

Use your own Cloudflare account. Paste the resulting Worker URL in Agent settings → Remote →
Relay on each host Mac, then pair devices so their code includes the relay address and room.
The Mac stays awake with Orrery open and maintains an outbound WebSocket. No inbound internet
port or central Orrery account is needed. A relay cannot make an offline Mac run work.

Deploy this update to your existing Worker to enable multiple viewers with Orrery 1.10.0.
Existing device pairings keep working. Older Macs continue to use one viewer; additional viewers
are refused without disconnecting the first. An updated Mac can still use an older Worker in
single-viewer mode until its owner updates the deployment.

The relay uses explicit WebSocket close coordination. Its open sockets keep the Durable Object
active, so hosting can incur charges on your account even while idle. It stores no messages,
transcripts or provider credentials. Do not enable request logging of token-bearing URLs.

## Verification

`npm test` runs the Worker in Cloudflare's local runtime with actual WebSocket clients. It
checks text and binary frames, concurrent isolated channels, wrong tokens, Mac replacement,
legacy clients, viewer limits, targeted revocation, malformed routing and frame-size limits.
The Mac `--remote-only` audit also exercises the shipping Swift clients and Mac relay transport
against this Worker. `tests/serve.js` is a local fixture, not a deployed endpoint.

The development tools are pinned. The image-processing dependency override resolves a
published vulnerability in the toolchain; it is not included in the deployed Worker.
