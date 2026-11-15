// render-all.ts — 多进程并发 Chrome CDP 确定性帧渲染器 + FFmpeg H.264/AAC 合成器
// 用法：
//   bun render-all.ts --preview        # 全部分镜覆盖预检 + 抽样静帧输出
//   bun render-all.ts                  # 6 Worker 并发渲染全部 15 支 1080p30 成片
//   bun render-all.ts v01 v05          # 指定重渲某几支视频
import { spawn } from "node:child_process";
import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { resolve } from "node:path";

const CHROME = process.env.CHROME || "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome";
const FFMPEG = process.env.FFMPEG || Bun.which("ffmpeg") || "ffmpeg";
const RENDERER_URL = `file://${resolve(import.meta.dir, "./renderer.html")}`;
const STORYBOARD_PATH = resolve(import.meta.dir, "../storyboard.json");
const OUT_DIR = resolve(import.meta.dir, "../out");
const PREVIEW_DIR = "/tmp/rc-promo15/preview";

mkdirSync(OUT_DIR, { recursive: true });
mkdirSync(PREVIEW_DIR, { recursive: true });

const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

interface CdpWorker {
  port: number;
  proc: ReturnType<typeof spawn>;
  ws: WebSocket;
  send: (method: string, params?: any) => Promise<any>;
  evalJs: (expression: string, awaitPromise?: boolean) => Promise<any>;
  close: () => void;
}

async function createWorker(workerIdx: number): Promise<CdpWorker> {
  const port = 9720 + workerIdx * 7 + Math.floor(Math.random() * 5);
  const profDir = `/tmp/rc-promo15/chrome-render-w${workerIdx}-${port}`;
  mkdirSync(profDir, { recursive: true });

  const proc = spawn(
    CHROME,
    [
      "--headless",
      `--remote-debugging-port=${port}`,
      `--user-data-dir=${profDir}`,
      "--no-first-run",
      "--disable-gpu",
      "--hide-scrollbars",
      "--force-device-scale-factor=1",
      "--window-size=1920,1920",
      "about:blank",
    ],
    { stdio: "ignore" }
  );

  let wsUrl = "";
  for (let i = 0; i < 60; i++) {
    try {
      const res = await fetch(`http://127.0.0.1:${port}/json/list`);
      const list = (await res.json()) as any[];
      const page = list.find((t) => t.type === "page");
      if (page?.webSocketDebuggerUrl) {
        wsUrl = page.webSocketDebuggerUrl;
        break;
      }
    } catch {}
    await sleep(200);
  }
  if (!wsUrl) {
    proc.kill();
    throw new Error(`Worker ${workerIdx} Chrome DevTools unreachable on port ${port}`);
  }

  const ws = new WebSocket(wsUrl);
  await new Promise((res, rej) => {
    ws.onopen = res;
    ws.onerror = rej;
  });

  let mid = 0;
  const pending = new Map<number, { resolve: (v: any) => void; reject: (e: any) => void }>();
  ws.onmessage = (ev) => {
    const m = JSON.parse(ev.data as string);
    if (m.id && pending.has(m.id)) {
      const p = pending.get(m.id)!;
      pending.delete(m.id);
      if (m.error) p.reject(new Error(JSON.stringify(m.error)));
      else p.resolve(m.result);
    }
  };

  const send = (method: string, params: any = {}) =>
    new Promise<any>((resolve, reject) => {
      const id = ++mid;
      pending.set(id, { resolve, reject });
      ws.send(JSON.stringify({ id, method, params }));
    });

  const evalJs = async (expression: string, awaitPromise = false) => {
    const r = await send("Runtime.evaluate", {
      expression,
      returnByValue: true,
      awaitPromise,
    });
    if (r?.exceptionDetails) {
      throw new Error(`JS Exception: ${JSON.stringify(r.exceptionDetails)}`);
    }
    return r?.result?.value;
  };

  await send("Page.enable");
  await send("Runtime.enable");
  await send("Page.navigate", { url: RENDERER_URL });
  await sleep(900);

  const loadedCount = await evalJs("window.preloadAll()", true);
  if (loadedCount < 25) {
    console.warn(`  [w${workerIdx}] Warning: preloaded ${loadedCount}/25 UI assets`);
  }

  return {
    port,
    proc,
    ws,
    send,
    evalJs,
    close: () => {
      try {
        ws.close();
      } catch {}
      try {
        proc.kill();
      } catch {}
    },
  };
}

async function runPreview(plans: any[]) {
  console.log(`=== Preview & 75-Scene Preflight Check (${plans.length} videos) ===`);
  const w = await createWorker(0);
  const sampleIds = new Set(["v01", "v02", "v03", "v05", "v07", "v08", "v10", "v13", "v15"]);

  try {
    for (const plan of plans) {
      await w.send("Emulation.setDeviceMetricsOverride", {
        width: plan.width,
        height: plan.height,
        deviceScaleFactor: 1,
        mobile: false,
      });
      await w.evalJs(`window.setPlan(${JSON.stringify(plan)})`);

      for (let sIdx = 0; sIdx < plan.scenes.length; sIdx++) {
        const sc = plan.scenes[sIdx];
        // Sample at 58% into each scene so spring entrance has settled and VO highlight is active
        const t = sc.startSec + sc.durationSec * 0.58;
        await w.evalJs(`window.renderFrame(${t.toFixed(4)})`);

        if (sampleIds.has(plan.id) && (sIdx === 0 || sIdx === 1 || sIdx === 2 || sIdx === 4)) {
          const shot = await w.send("Page.captureScreenshot", { format: "jpeg", quality: 92 });
          writeFileSync(
            `${PREVIEW_DIR}/${plan.id}-s${sIdx}-${sc.act}.jpg`,
            Buffer.from(shot.data, "base64")
          );
        }
      }
      console.log(`  ✓ Preflight OK: [${plan.num}] ${plan.slug} (${plan.width}x${plan.height}, ${plan.durationSec}s, ${plan.scenes.length} acts)`);
    }
  } finally {
    w.close();
  }
  console.log(`=== Preflight Complete! Sample stills saved to ${PREVIEW_DIR} ===`);
}

async function renderVideoOnWorker(w: CdpWorker, wIdx: number, plan: any) {
  const outMp4 = `${OUT_DIR}/${plan.slug}.mp4`;
  const fps = plan.fps || 30;
  const totalFrames = Math.round(plan.durationSec * fps);
  const t0 = Date.now();

  if (!existsSync(plan.audioWav)) {
    throw new Error(`Missing audioWav for ${plan.id}: ${plan.audioWav}`);
  }

  await w.send("Emulation.setDeviceMetricsOverride", {
    width: plan.width,
    height: plan.height,
    deviceScaleFactor: 1,
    mobile: false,
  });
  await w.evalJs(`window.setPlan(${JSON.stringify(plan)})`);

  const ff = spawn(
    FFMPEG,
    [
      "-y",
      "-f",
      "image2pipe",
      "-vcodec",
      "mjpeg",
      "-framerate",
      String(fps),
      "-i",
      "-",
      "-i",
      plan.audioWav,
      "-c:v",
      "libx264",
      "-preset",
      "veryfast",
      "-crf",
      "17",
      "-pix_fmt",
      "yuv420p",
      "-profile:v",
      "high",
      "-level",
      "4.2",
      "-c:a",
      "aac",
      "-b:a",
      "192k",
      "-ar",
      "44100",
      "-ac",
      "2",
      "-shortest",
      "-movflags",
      "+faststart",
      outMp4,
    ],
    { stdio: ["pipe", "ignore", "pipe"] }
  );

  let ffErr = "";
  ff.stderr.on("data", (d) => {
    ffErr += d.toString();
  });

  for (let i = 0; i < totalFrames; i++) {
    const t = i / fps;
    await w.evalJs(`window.renderFrame(${t.toFixed(5)})`);
    const shot = await w.send("Page.captureScreenshot", {
      format: "jpeg",
      quality: 94,
      optimizeForSpeed: true,
    });
    const buf = Buffer.from(shot.data, "base64");
    if (!ff.stdin.write(buf)) {
      await new Promise<void>((r) => ff.stdin.once("drain", r));
    }
    if (i > 0 && i % 300 === 0) {
      const elapsed = (Date.now() - t0) / 1000;
      const rate = (i / elapsed).toFixed(1);
      console.log(`  [w${wIdx}] ${plan.slug}: ${i}/${totalFrames} frames (${rate} fps)`);
    }
  }

  ff.stdin.end();
  const exitCode: number = await new Promise((res) => ff.on("close", (c) => res(c ?? 1)));
  if (exitCode !== 0) {
    throw new Error(`FFmpeg failed for ${plan.slug} (code ${exitCode}): ${ffErr.slice(-500)}`);
  }

  const totalSec = ((Date.now() - t0) / 1000).toFixed(1);
  console.log(`  ★ DONE [w${wIdx}] ${plan.slug}.mp4 (${plan.width}x${plan.height}, ${totalFrames}f in ${totalSec}s)`);
}

async function main() {
  if (!existsSync(STORYBOARD_PATH)) {
    console.error(`Missing storyboard.json at ${STORYBOARD_PATH}. Run build-audio.ts first.`);
    process.exit(1);
  }
  const sb = JSON.parse(readFileSync(STORYBOARD_PATH, "utf-8"));
  const allPlans: any[] = sb.videos;

  const args = process.argv.slice(2);
  if (args.includes("--preview")) {
    await runPreview(allPlans);
    process.exit(0);
  }

  const filterIds = args.filter((a) => !a.startsWith("--"));
  const queue =
    filterIds.length > 0
      ? allPlans.filter((p) => filterIds.includes(p.id) || filterIds.includes(p.slug))
      : [...allPlans];

  if (queue.length === 0) {
    console.error("No matching videos to render.");
    process.exit(1);
  }

  const concurrency = Math.min(6, queue.length);
  console.log(`=== Rendering ${queue.length} Promo Videos (${concurrency} Parallel Chrome CDP Workers) ===`);
  const tStart = Date.now();

  const workers = await Promise.all(
    Array.from({ length: concurrency }, (_, idx) => createWorker(idx))
  );

  let cursor = 0;
  try {
    await Promise.all(
      workers.map(async (w, wIdx) => {
        while (cursor < queue.length) {
          const myIdx = cursor++;
          const plan = queue[myIdx];
          if (!plan) break;
          await renderVideoOnWorker(w, wIdx, plan);
        }
      })
    );
  } finally {
    workers.forEach((w) => w.close());
  }

  console.log(`\n=== ALL ${queue.length} VIDEOS RENDERED IN ${((Date.now() - tStart) / 1000).toFixed(1)}s ===`);
}

main().catch((err) => {
  console.error("Fatal render error:", err);
  process.exit(1);
});
