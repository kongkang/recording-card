// usage: bun capture.ts <videoId> [fps=30] [onlyFrameIndex]
// renders deterministic frames from renderer.html via headless Chrome CDP
import { spawn } from "node:child_process";
import { mkdirSync, writeFileSync, existsSync, rmSync } from "node:fs";

const vid = process.argv[2]!;
const fps = Number(process.argv[3] ?? 30);
const only = process.argv[4] ? Number(process.argv[4]) : null;
if (!vid) { console.error("usage: bun capture.ts <videoId> [fps] [onlyFrame]"); process.exit(1); }

const CHROME = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome";
const RENDERER = "file:///Users/kongkang/Developer/recording-card/marketing/videos/tools/renderer.html";
const OUT_DIR = `/tmp/rc-promo/frames/${vid}`;
const PORT = 9430 + Math.floor(Math.random() * 500);

mkdirSync(OUT_DIR, { recursive: true });

const chrome = spawn(CHROME, [
  "--headless", `--remote-debugging-port=${PORT}`,
  `--user-data-dir=/tmp/rc-promo/chrome-prof-${vid}`,
  "--no-first-run", "--disable-gpu", "--hide-scrollbars",
  "--force-device-scale-factor=1", "--window-size=1920,1080",
  "about:blank",
], { stdio: "ignore" });

const sleep = (ms: number) => new Promise(r => setTimeout(r, ms));

async function getWsUrl(): Promise<string> {
  for (let i = 0; i < 60; i++) {
    try {
      const res = await fetch(`http://127.0.0.1:${PORT}/json/list`);
      const list = await res.json() as any[];
      const page = list.find((t: any) => t.type === "page");
      if (page?.webSocketDebuggerUrl) return page.webSocketDebuggerUrl;
    } catch {}
    await sleep(250);
  }
  throw new Error("chrome devtools not reachable");
}

const wsUrl = await getWsUrl();
const ws = new WebSocket(wsUrl);
let msgId = 0;
const pending = new Map<number, { resolve: (v: any) => void; reject: (e: any) => void }>();

await new Promise((res, rej) => { ws.onopen = res; ws.onerror = rej; });

ws.onmessage = (ev) => {
  const msg = JSON.parse(ev.data as string);
  if (msg.id && pending.has(msg.id)) {
    const p = pending.get(msg.id)!;
    pending.delete(msg.id);
    msg.error ? p.reject(new Error(JSON.stringify(msg.error))) : p.resolve(msg.result);
  }
};

function send(method: string, params: any = {}): Promise<any> {
  const id = ++msgId;
  return new Promise((resolve, reject) => {
    pending.set(id, { resolve, reject });
    ws.send(JSON.stringify({ id, method, params }));
  });
}

await send("Page.enable");
await send("Runtime.enable");
await send("Emulation.setDeviceMetricsOverride", { width: 1920, height: 1080, deviceScaleFactor: 1, mobile: false });
await send("Page.navigate", { url: RENDERER });
await sleep(1500);

const durRes = await send("Runtime.evaluate", { expression: `DUR['${vid}']`, returnByValue: true });
const dur = durRes?.result?.value;
if (!dur) { console.error(`video '${vid}' not found in renderer`); chrome.kill(); process.exit(1); }

const total = Math.round(dur * fps);
console.log(`capturing ${vid}: dur=${dur}s fps=${fps} frames=${total} -> ${OUT_DIR}`);
if (vid.startsWith("sd")) {
  await send("Runtime.evaluate", { expression: "loadShots()", returnByValue: true, awaitPromise: true });
  const keys = await send("Runtime.evaluate", { expression: "Object.keys(window.SHOT).join(',')", returnByValue: true });
  console.log(`shots loaded: ${keys?.result?.value}`);
}

const t0 = Date.now();
for (let i = 0; i < total; i++) {
  if (only !== null && i !== only) continue;
  const t = i / fps;
  const r = await send("Runtime.evaluate", { expression: `render('${vid}',${t})` });
  if (r?.exceptionDetails) { console.error(`render error at frame ${i}:`, JSON.stringify(r.exceptionDetails).slice(0, 400)); break; }
  let shot = await send("Page.captureScreenshot", { format: "png", optimizeForSpeed: true }).catch(() => null);
  if (!shot) shot = await send("Page.captureScreenshot", { format: "png" });
  writeFileSync(`${OUT_DIR}/${String(i).padStart(5, "0")}.png`, Buffer.from(shot.data, "base64"));
  if (i % 60 === 0) {
    const rate = (i + 1) / ((Date.now() - t0) / 1000);
    console.log(`  frame ${i}/${total} (${rate.toFixed(1)} fps capture)`);
  }
}

ws.close();
chrome.kill();
console.log(`done ${vid} in ${((Date.now() - t0) / 1000).toFixed(1)}s`);
process.exit(0);
