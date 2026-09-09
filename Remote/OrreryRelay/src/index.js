import { DurableObject } from "cloudflare:workers";

const MAX_VIEWERS = 8;
const MAX_FRAME = 1024 * 1024;
const MAX_PACKET = MAX_FRAME + 4096;
const encoder = new TextEncoder();
const decoder = new TextDecoder("utf-8", { fatal: true });
const channelID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const close = (socket, code, reason) => { try { socket.close(code, reason); } catch {} };

// Only the routing envelope is visible here. Every viewer's inner session has its own
// end-to-end key agreement and replay counters; inner messages are never broadcast.
export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    const match = url.pathname.match(/^\/(mac|phone)\/([A-Za-z0-9_-]{8,64})$/);
    if (!match) return new Response("Orrery relay", { status: 404 });
    if (request.method !== "GET" || request.headers.get("Upgrade")?.toLowerCase() !== "websocket") {
      return new Response("Expected a WebSocket", { status: 426 });
    }
    const token = url.searchParams.get("token") || "";
    if (!/^[A-Za-z0-9_-]{16,128}$/.test(token)) return new Response("Invalid room token", { status: 403 });
    const [, side, room] = match;
    const destination = new URL(`https://room/${side}`);
    destination.searchParams.set("token", token);
    destination.searchParams.set("protocol", url.searchParams.get("protocol") || "1");
    return env.ROOMS.get(env.ROOMS.idFromName(room)).fetch(new Request(destination, request));
  },
};

export class Room extends DurableObject {
  constructor(ctx, env) {
    super(ctx, env);
    this.mac = null;
    this.phones = new Map();
    this.attachments = new WeakMap();
    this.tokenHash = null;
    ctx.blockConcurrencyWhile(async () => {
      this.tokenHash = (await ctx.storage.get("tokenHash")) || null;
      // Upgrade an existing room without changing any owner's pairing code.
      const legacy = await ctx.storage.get("token");
      if (!this.tokenHash && typeof legacy === "string") {
        this.tokenHash = await crypto.subtle.digest("SHA-256", encoder.encode(legacy));
        await ctx.storage.put("tokenHash", this.tokenHash);
      }
      if (legacy !== undefined) await ctx.storage.delete("token");
    });
  }

  async fetch(request) {
    const url = new URL(request.url);
    const side = url.pathname.slice(1);
    const token = url.searchParams.get("token") || "";
    const version = url.searchParams.get("protocol") || "1";
    if (!["mac", "phone"].includes(side) || !/^[A-Za-z0-9_-]{16,128}$/.test(token)) return new Response("Forbidden", { status: 403 });
    if (side === "mac" && !["1", "2"].includes(version)) return new Response("Unsupported relay protocol", { status: 400 });
    const candidate = await crypto.subtle.digest("SHA-256", encoder.encode(token));
    const allowed = await this.ctx.blockConcurrencyWhile(async () => {
      if (!this.tokenHash && side === "mac") {
        await this.ctx.storage.put("tokenHash", candidate); this.tokenHash = candidate;
      }
      return this.tokenHash !== null && crypto.subtle.timingSafeEqual(this.tokenHash, candidate);
    });
    if (!allowed) return new Response("Forbidden", { status: 403 });
    if (side === "phone") {
      if (!this.mac) return new Response("Mac offline", { status: 503 });
      if (this.phones.size >= MAX_VIEWERS) return new Response("Viewer limit reached", { status: 429 });
      if (this.attachments.get(this.mac).version === "1" && this.phones.size) {
        return new Response("Update Orrery on the Mac for multiple viewers", { status: 409 });
      }
    }
    const [client, server] = Object.values(new WebSocketPair());
    const id = crypto.randomUUID();
    this.attachments.set(server, { side, id, version, count: 0, window: Date.now() });
    // The native clients send binary JSON. Workers now default binary messages to Blob.
    server.binaryType = "arraybuffer";
    // Explicit half-open handling completes both legs of the relay close handshake.
    server.accept({ allowHalfOpen: true });
    server.addEventListener("message", event => this.webSocketMessage(server, event.data));
    server.addEventListener("close", event => this.webSocketClose(server, event.code, event.reason, event.wasClean));
    server.addEventListener("error", () => this.webSocketError(server));
    if (side === "mac") {
      if (this.mac) this.dropMac(this.mac, "Mac reconnected");
      this.mac = server;
      if (version === "2") this.send(server, JSON.stringify({ type: "relay.ready" }));
    } else {
      this.phones.set(id, server);
      if (this.attachments.get(this.mac).version === "2") {
        this.send(this.mac, JSON.stringify({ type: "relay.open", id }));
      }
    }
    return new Response(null, { status: 101, webSocket: client });
  }

  webSocketMessage(socket, message) {
    const info = this.attachments.get(socket);
    // Late frames from a replaced Mac or a closed viewer cannot reach the new session.
    if (info.side === "mac" ? this.mac !== socket : this.phones.get(info.id) !== socket) return;
    const now = Date.now();
    if (now - info.window >= 1000) { info.window = now; info.count = 0; }
    info.count += 1; this.attachments.set(socket, info);
    if (info.count > (info.side === "mac" ? 512 : 60)) { this.remove(socket, 1008, "Message rate exceeded"); return; }
    let text;
    try {
      const size = typeof message === "string" ? encoder.encode(message).byteLength : message.byteLength;
      if (size > (info.side === "mac" ? MAX_PACKET : MAX_FRAME)) throw new Error("size");
      text = typeof message === "string" ? message : decoder.decode(message);
    } catch { this.remove(socket, 1009, "Invalid frame"); return; }
    if (info.side === "mac") {
      if (info.version === "1") {
        const phone = this.phones.values().next().value;
        if (phone) this.send(phone, text);
        return;
      }
      let packet;
      try { packet = JSON.parse(text); } catch { this.remove(socket, 1008, "Invalid routing"); return; }
      if (!packet || !channelID.test(packet.id || "") || !["relay.data", "relay.close"].includes(packet.type)) {
        this.remove(socket, 1008, "Invalid routing"); return;
      }
      const phone = this.phones.get(packet.id);
      if (packet.type === "relay.close") {
        if (phone) { this.phones.delete(packet.id); close(phone, 1000, "Session closed"); }
      } else {
        if (typeof packet.data !== "string" || encoder.encode(packet.data).byteLength > MAX_FRAME) {
          this.remove(socket, 1009, "Invalid payload"); return;
        }
        if (phone) this.send(phone, packet.data);
      }
    } else if (this.mac) {
      const packet = this.attachments.get(this.mac).version === "2"
        ? JSON.stringify({ type: "relay.data", id: info.id, data: text }) : text;
      if (encoder.encode(packet).byteLength > MAX_PACKET) { this.remove(socket, 1009, "Invalid frame"); return; }
      this.send(this.mac, packet);
    }
  }

  send(socket, data) {
    try { socket.send(data); } catch { this.remove(socket, 1011, "Connection lost"); }
  }
  dropMac(socket, reason) {
    if (this.mac !== socket) return;
    this.mac = null;
    const phones = [...this.phones.values()]; this.phones.clear();
    for (const phone of phones) close(phone, 1001, reason);
    close(socket, 1001, reason);
  }
  remove(socket, code, reason) {
    const info = this.attachments.get(socket);
    if (info.side === "mac") { this.dropMac(socket, reason); return; }
    if (this.phones.get(info.id) !== socket) return;
    this.phones.delete(info.id); close(socket, code, reason);
    if (this.mac && this.attachments.get(this.mac).version === "2") {
      this.send(this.mac, JSON.stringify({ type: "relay.close", id: info.id }));
    } else if (this.mac) { this.dropMac(this.mac, "Viewer disconnected"); }
  }
  webSocketClose(socket, code, reason, wasClean) { close(socket, 1000, "Disconnected"); this.remove(socket, 1000, "Disconnected"); }
  webSocketError(socket) { this.remove(socket, 1011, "Connection lost"); }
}
