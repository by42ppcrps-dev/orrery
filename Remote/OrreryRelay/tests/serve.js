// Local-only integration fixture. Prints one port number, never a pairing code or room token.
import { Miniflare, convertV4MiniflareOptions } from "miniflare";
import { fileURLToPath } from "node:url";
import { writeFile } from "node:fs/promises";
const mf = new Miniflare(convertV4MiniflareOptions({ modules: true,
  scriptPath: fileURLToPath(new URL("../src/index.js", import.meta.url)),
  compatibilityDate: "2026-06-01", durableObjects: { ROOMS: { className: "Room", useSQLite: true } } }));
const address = await mf.ready;
await writeFile(process.argv[2], address.port, { mode: 0o600 });
async function stop() { await mf.dispose(); process.exit(0); }
process.on("SIGTERM", stop); process.on("SIGINT", stop);
