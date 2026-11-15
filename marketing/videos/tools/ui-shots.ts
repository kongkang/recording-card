// ui-shots.ts — 驱动真实 prototype 设计稿（只读），截取宣传视频所需的真实界面
// usage: RC_PROTO_URL=file://.../current.html bun ui-shots.ts   → tools/ui/*.png （390×844 @3x）
// 默认用 current.html（当前版本，零 TBC —— 对外宣传素材一律取当前版）
import { spawn } from "node:child_process";
import { mkdirSync, writeFileSync, existsSync } from "node:fs";

const CUR = "file:///Users/kongkang/Developer/recording-card/prototype/current.html";
const IDX = "file:///Users/kongkang/Developer/recording-card/prototype/index.html";
const PROTO = process.env.RC_PROTO_URL ?? (existsSync("/Users/kongkang/Developer/recording-card/prototype/current.html") ? CUR : IDX);
const OUT = "/Users/kongkang/Developer/recording-card/marketing/videos/tools/ui";
const CHROME = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome";
const PORT = 9770 + Math.floor(Math.random() * 200);

mkdirSync(OUT, { recursive: true });
const chrome = spawn(CHROME, [
  "--headless", `--remote-debugging-port=${PORT}`,
  `--user-data-dir=/tmp/rc-promo/chrome-ui`,
  "--no-first-run", "--disable-gpu", "--hide-scrollbars",
  "about:blank",
], { stdio: "ignore" });
const sleep = (ms: number) => new Promise(r => setTimeout(r, ms));

async function getWs(): Promise<string> {
  for (let i = 0; i < 60; i++) {
    try {
      const res = await fetch(`http://127.0.0.1:${PORT}/json/list`);
      const page = (await res.json() as any[]).find(t => t.type === "page");
      if (page?.webSocketDebuggerUrl) return page.webSocketDebuggerUrl;
    } catch {}
    await sleep(250);
  }
  throw new Error("devtools unreachable");
}
const ws = new WebSocket(await getWs());
await new Promise((res, rej) => { ws.onopen = res; ws.onerror = rej; });
let mid = 0; const pend = new Map<number, { resolve: (v: any) => void; reject: (e: any) => void }>();
ws.onmessage = ev => {
  const m = JSON.parse(ev.data as string);
  if (m.id && pend.has(m.id)) { const p = pend.get(m.id)!; pend.delete(m.id); m.error ? p.reject(new Error(JSON.stringify(m.error))) : p.resolve(m.result); }
};
const send = (method: string, params: any = {}) => new Promise<any>((resolve, reject) => {
  const id = ++mid; pend.set(id, { resolve, reject }); ws.send(JSON.stringify({ id, method, params }));
});
const evalJs = async (expr: string) => (await send("Runtime.evaluate", { expression: expr, returnByValue: true, awaitPromise: true }))?.result?.value;
const click = (sel: string) => evalJs(`(document.querySelector('${sel}')||{click(){}}).click()`);
async function waitFor(expr: string, timeout = 8000, label = expr) {
  const t0 = Date.now();
  while (Date.now() - t0 < timeout) {
    if (await evalJs(expr)) return;
    await sleep(200);
  }
  throw new Error("waitFor timeout: " + label);
}
async function shot(name: string) {
  const s = await send("Page.captureScreenshot", { format: "png" });
  writeFileSync(`${OUT}/${name}.png`, Buffer.from(s.data, "base64"));
  console.log("shot", name);
}
const wait = (ms: number) => sleep(ms);

await send("Page.enable");
await send("Runtime.enable");
await send("Emulation.setDeviceMetricsOverride", { width: 390, height: 844, deviceScaleFactor: 3, mobile: true });
await send("Page.navigate", { url: PROTO });
await wait(1500);

// 各界面按 verify.cjs 既有流程进入；单步失败不阻塞其余截图（双版本可能能力子集不同）
const steps: Array<[string, () => Promise<void>]> = [
  ["feed-collapsed", async () => { await shot("feed-collapsed"); }],
  ["feed-daily", async () => {
    await evalJs(`document.querySelector('[data-testid="card-daily-1"]').scrollIntoView({block:'center'})`);
    await wait(400); await shot("feed-daily");
    await evalJs(`window.scrollTo(0,0)`); await wait(300);
  }],
  ["timeline-expanded", async () => {
    await click('[data-testid="card-e1"]'); await wait(450); await shot("timeline-expanded");
    await click('[data-testid="card-e1"]'); await wait(300);
  }],
  ["detail-photo", async () => {
    await click('[data-testid="card-e2"]'); await wait(200);
    await click('[data-testid="detail-e2"]'); await waitFor(`document.querySelector('#p-detail').classList.contains('show')`);
    await wait(400); await shot("detail-photo");
    await click('[data-testid="crumb-back"]'); await wait(400);
  }],
  ["detail-raw-audio", async () => {
    await click('[data-testid="card-e1"]'); await wait(200);
    await click('[data-testid="detail-e1"]'); await waitFor(`document.querySelector('#p-detail').classList.contains('show')`);
    await click('[data-testid="det-tab-raw"]'); await wait(300);
    await click('[data-testid="raw-audio-toggle"]'); await wait(600);
    await click('[data-testid="rawline-e1-2"]'); await wait(400); await shot("detail-raw-audio");
    await click('[data-testid="crumb-back"]'); await wait(400);
  }],
  ["summary-multiselect", async () => {
    await click('[data-testid="summary-start"]'); await wait(450); await shot("summary-multiselect");
    await click('#sumbar .btn.ghost'); await wait(400);
  }],
  ["result-all", async () => {
    await click('[data-testid="card-sum-demo"]'); await waitFor(`document.querySelector('#p-sumres').classList.contains('show')`);
    await wait(400); await shot("result-all");
  }],
  ["result-points", async () => {
    await click('#stabs button[data-st="pt"]'); await wait(450); await shot("result-points");
  }],
  ["summary-export", async () => {
    await click('[data-testid="export-btn"]'); await wait(400); await shot("summary-export");
    await evalJs(`document.querySelector('#export-pop button:nth-child(3)').click()`); await wait(400);
    await click('[data-testid="crumb-back"]'); await wait(400);
  }],
  ["local-model", async () => {
    await wait(1600); /* 等导出 toast 消失 */
    await click('[data-testid="nav-setting"]'); await wait(400);
    await click('[data-testid="set-local-model"]'); await wait(450); await shot("local-model");
    await click('[data-testid="crumb-back"]'); await wait(300);
  }],
  ["device-connect", async () => {
    await click('[data-testid="hw-capsule"]'); await wait(300);
    await waitFor(`document.querySelectorAll('#conn-list .conn-item').length>=2`, 8000, "scan devices");
    await shot("device-connect");
  }],
  ["hardware-capsule", async () => {
    await click('#conn-list .conn-item'); await waitFor(`!document.getElementById('dev-main').hidden`);
    await click('[data-testid="rec-toggle"]'); await wait(600); await shot("hardware-capsule");
  }],
  ["live-feed", async () => {
    await evalJs(`closeSheet()`); await wait(300);
    await click('[data-testid="nav-timeline"]'); await wait(400);
    await waitFor(`document.getElementById('live-status')`, 5000, "live-status");
    await shot("live-feed");
  }],
];
for (const [name, fn] of steps) {
  try { await fn(); } catch (e) { console.log("SKIP", name, (e as Error).message.slice(0, 90)); }
}
// 收尾：若仍在录音则停掉
try { await click('[data-testid="hw-capsule"]'); await wait(300); await click('[data-testid="rec-toggle"]'); await wait(200); await evalJs(`closeSheet()`); } catch {}

ws.close(); chrome.kill();
console.log("done ui-shots");
process.exit(0);
