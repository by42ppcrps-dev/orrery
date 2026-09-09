import { test } from "node:test";
import assert from "node:assert/strict";
import { Miniflare, convertV4MiniflareOptions } from "miniflare";
import WebSocket from "ws";
import { fileURLToPath } from "node:url";

async function fixture(t) {
  const mf = new Miniflare(convertV4MiniflareOptions({ modules: true, scriptPath: fileURLToPath(new URL("../src/index.js", import.meta.url)),
    compatibilityDate: "2026-06-01", durableObjects: { ROOMS: { className: "Room", useSQLite: true } } }));
  t.after(() => mf.dispose());
  const sockets = [];
  async function connect(side, { version = "2", token = "audit-room-token-1234567890", room = "auditroom" } = {}) {
    const address = new URL(await mf.ready);
    address.protocol = "ws:"; address.pathname = `/${side}/${room}`;
    address.search = new URLSearchParams({ token, protocol: version }).toString();
    const socket = new WebSocket(address);
    const pending = []; const waiters = [];
    socket.addEventListener("message", event => {
      const value = typeof event.data === "string" ? event.data : new TextDecoder().decode(event.data);
      const waiter = waiters.shift(); if (waiter) waiter(value); else pending.push(value);
    });
    const result = { socket, pending, status: 101, closed: false,
      send: data => socket.send(typeof data === "string" ? data : JSON.stringify(data)),
      next: (timeout = 2000) => new Promise((resolve, reject) => {
        if (pending.length) { resolve(pending.shift()); return; }
        const done = value => { clearTimeout(timer); resolve(value); };
        const timer = setTimeout(() => { const index = waiters.indexOf(done); if (index >= 0) waiters.splice(index, 1); reject(new Error("message timeout")); }, timeout);
        waiters.push(done);
      }) };
    socket.addEventListener("close", () => { result.closed = true; });
    sockets.push(socket);
    return await new Promise(resolve => {
      socket.once("open", () => resolve(result));
      socket.once("unexpected-response", (request, response) => { response.resume(); request.destroy(); resolve({ status: response.statusCode }); });
      socket.on("error", () => {});
    });
  }
  t.after(() => { for (const socket of sockets) { try { socket.close(); } catch {} } });
  return { connect, mf };
}
const until = async predicate => {
  for (let i = 0; i < 500; i++) { if (predicate()) return; await new Promise(resolve => setTimeout(resolve, 10)); }
  assert.ok(predicate(), "condition did not become true");
};

test("two viewers have isolated channels; one disconnect leaves the other live", async t => {
  const { connect } = await fixture(t);
  const mac = await connect("mac"); assert.deepEqual(JSON.parse(await mac.next()), { type: "relay.ready" });
  const first = await connect("phone"); const a = JSON.parse(await mac.next());
  const second = await connect("phone"); const b = JSON.parse(await mac.next());
  assert.equal(a.type, "relay.open"); assert.equal(b.type, "relay.open"); assert.notEqual(a.id, b.id);
  first.socket.send(Buffer.from("sealed-first")); assert.deepEqual(JSON.parse(await mac.next()), { type: "relay.data", id: a.id, data: "sealed-first" });
  second.send("sealed-second"); assert.deepEqual(JSON.parse(await mac.next()), { type: "relay.data", id: b.id, data: "sealed-second" });
  mac.socket.send(Buffer.from(JSON.stringify({ type: "relay.data", id: b.id, data: "reply-second" }))); assert.equal(await second.next(), "reply-second"); assert.deepEqual(first.pending, []);
  mac.send({ type: "relay.data", id: a.id, data: "reply-first" }); assert.equal(await first.next(), "reply-first"); assert.deepEqual(second.pending, []);
  first.socket.close(); assert.deepEqual(JSON.parse(await mac.next()), { type: "relay.close", id: a.id });
  second.send("still-live"); assert.equal(JSON.parse(await mac.next()).data, "still-live"); assert.equal(mac.closed, false);
});

test("replacement Mac closes old viewers; stale close cannot disconnect replacement", async t => {
  const { connect } = await fixture(t);
  const old = await connect("mac"); await old.next();
  const first = await connect("phone"); await old.next();
  const replacement = await connect("mac"); await replacement.next();
  await until(() => first.closed && old.closed);
  const second = await connect("phone"); const channel = JSON.parse(await replacement.next());
  second.send("fresh"); assert.equal(JSON.parse(await replacement.next()).data, "fresh");
  replacement.send({ type: "relay.data", id: channel.id, data: "confirmed" }); assert.equal(await second.next(), "confirmed");
});

test("wrong token, offline Mac and unsupported protocol are refused", async t => {
  const { connect } = await fixture(t);
  assert.equal((await connect("phone")).status, 403);
  const mac = await connect("mac"); await mac.next();
  assert.equal((await connect("phone", { token: "different-room-token-1234" })).status, 403);
  assert.equal((await connect("mac", { token: "different-room-token-1234" })).status, 403);
  assert.equal((await connect("mac", { version: "99" })).status, 400);
  mac.socket.close(); await until(() => mac.closed);
  assert.equal((await connect("phone")).status, 503);
});

test("legacy Mac keeps its original single viewer and works in both directions", async t => {
  const { connect } = await fixture(t);
  const mac = await connect("mac", { version: "1" });
  const phone = await connect("phone");
  assert.equal((await connect("phone")).status, 409);
  phone.send("legacy-pair"); assert.equal(await mac.next(), "legacy-pair");
  mac.send("legacy-reply"); assert.equal(await phone.next(), "legacy-reply");
  phone.socket.close(); await until(() => mac.closed);
});

test("viewer limit, targeted revocation and stale channel routing are bounded", async t => {
  const { connect } = await fixture(t);
  const mac = await connect("mac"); await mac.next();
  const viewers = []; const ids = [];
  for (let i = 0; i < 8; i++) { viewers.push(await connect("phone")); ids.push(JSON.parse(await mac.next()).id); }
  assert.equal((await connect("phone")).status, 429);
  mac.send({ type: "relay.close", id: ids[0] }); await until(() => viewers[0].closed);
  mac.send({ type: "relay.data", id: ids[0], data: "stale" });
  mac.send({ type: "relay.data", id: ids[1], data: "live" }); assert.equal(await viewers[1].next(), "live");
  for (let i = 2; i < 8; i++) assert.deepEqual(viewers[i].pending, []);
  assert.equal((await connect("phone")).status, 101); assert.equal(JSON.parse(await mac.next()).type, "relay.open");
});

test("oversized viewer frame closes only that viewer", async t => {
  const { connect } = await fixture(t);
  const mac = await connect("mac"); await mac.next();
  const bad = await connect("phone"); const a = JSON.parse(await mac.next());
  const good = await connect("phone"); await mac.next();
  bad.send("x".repeat(1024 * 1024 + 1));
  assert.deepEqual(JSON.parse(await mac.next()), { type: "relay.close", id: a.id }); await until(() => bad.closed);
  good.send("alive"); assert.equal(JSON.parse(await mac.next()).data, "alive");
});

test("malformed routing closes the Mac and its viewers rather than broadcasting", async t => {
  const { connect } = await fixture(t);
  const mac = await connect("mac"); await mac.next();
  const phone = await connect("phone"); await mac.next();
  mac.send({ type: "relay.data", id: "not-a-channel", data: "never forwarded" });
  await until(() => mac.closed && phone.closed); assert.deepEqual(phone.pending, []);
});

test("encoding expansion cannot disconnect other viewers", async t => {
  const { connect } = await fixture(t);
  const mac = await connect("mac"); await mac.next();
  const bad = await connect("phone"); const a = JSON.parse(await mac.next());
  const good = await connect("phone"); await mac.next();
  bad.send('"'.repeat(600000));
  assert.deepEqual(JSON.parse(await mac.next()), { type: "relay.close", id: a.id });
  good.send("still isolated"); assert.equal(JSON.parse(await mac.next()).data, "still isolated");
});

test("message floods close one viewer and leave the room usable", async t => {
  const { connect } = await fixture(t);
  const mac = await connect("mac"); await mac.next();
  const bad = await connect("phone"); const a = JSON.parse(await mac.next());
  for (let i = 0; i < 61; i++) bad.send("frame");
  let closed = false;
  for (let i = 0; i < 61; i++) {
    const packet = JSON.parse(await mac.next());
    if (packet.type === "relay.close") { assert.equal(packet.id, a.id); closed = true; break; }
  }
  assert.equal(closed, true); assert.equal(mac.closed, false);
  const good = await connect("phone"); await mac.next();
  good.send("healthy"); assert.equal(JSON.parse(await mac.next()).data, "healthy");
});
