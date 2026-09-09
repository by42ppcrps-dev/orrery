// Orrery Relay: a Cloudflare Worker that lets Orrery Remote reach a Mac that is not on the
// same network. One Durable Object per Mac ("room"); the Mac keeps an outbound WebSocket to
// its room, the phone connects to the same room, and every frame is forwarded unchanged.
//
// The relay never sees plaintext: every frame is already sealed end to end by the Orrery
// remote protocol (Curve25519 pairing, ChaCha20-Poly1305 per frame, replay counters). The
// relay only checks that both sides present the room's token, made at pairing and carried in
// the QR code, so strangers cannot occupy a room or read its ciphertext.
//
// Deploy: `npx wrangler deploy` in this folder with your Cloudflare account. Orrery then gets
// the Worker's URL under Agent settings → Remote → Relay.

export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    const match = url.pathname.match(/^\/(mac|phone)\/([A-Za-z0-9_-]{8,64})$/);
    if (!match) return new Response("Orrery relay: /mac/<room> or /phone/<room>", { status: 404 });
    if (request.headers.get("Upgrade") !== "websocket") return new Response("Expected a WebSocket", { status: 426 });
    const [, side, room] = match;
    const id = env.ROOMS.idFromName(room);
    return env.ROOMS.get(id).fetch(new Request(`https://room/${side}?token=${encodeURIComponent(url.searchParams.get("token") || "")}`, request));
  },
};

export class Room {
  constructor(state) {
    this.state = state;
    this.mac = null;
    this.phones = new Set();
    this.token = null;
    this.state.blockConcurrencyWhile(async () => { this.token = (await this.state.storage.get("token")) || null; });
  }

  async fetch(request) {
    const url = new URL(request.url);
    const side = url.pathname.slice(1);
    const token = url.searchParams.get("token") || "";
    if (token.length < 16) return new Response("token required", { status: 403 });
    // The Mac sets the room's token on first connection; everyone after must match it.
    if (side === "mac") {
      if (this.token && this.token !== token) return new Response("wrong token", { status: 403 });
      if (!this.token) { this.token = token; await this.state.storage.put("token", token); }
    } else if (this.token !== token) {
      return new Response("wrong token", { status: 403 });
    }
    const pair = new WebSocketPair();
    const [client, server] = Object.values(pair);
    server.accept();
    if (side === "mac") {
      if (this.mac) { try { this.mac.close(1000, "replaced"); } catch {} }
      this.mac = server;
      server.addEventListener("message", (event) => { for (const phone of this.phones) { try { phone.send(event.data); } catch {} } });
      server.addEventListener("close", () => { if (this.mac === server) this.mac = null; for (const phone of this.phones) { try { phone.close(1001, "mac gone"); } catch {} } this.phones.clear(); });
    } else {
      if (!this.mac) { server.close(1013, "mac offline"); return new Response(null, { status: 101, webSocket: client }); }
      // One phone at a time: a newcomer replaces the previous phone, and when the phone leaves
      // the Mac's socket is closed too, so the Mac reconnects with a clean session for the next one.
      for (const previous of this.phones) { try { previous.close(1000, "replaced"); } catch {} }
      this.phones.clear();
      this.phones.add(server);
      server.addEventListener("message", (event) => { try { this.mac?.send(event.data); } catch {} });
      server.addEventListener("close", () => {
        this.phones.delete(server);
        if (this.phones.size === 0 && this.mac) { const mac = this.mac; this.mac = null; try { mac.close(1000, "phone gone"); } catch {} }
      });
    }
    return new Response(null, { status: 101, webSocket: client });
  }
}
