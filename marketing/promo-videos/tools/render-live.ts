// render-live.ts — 真人实景混合电影渲染管线（FFmpeg 30fps 动态实拍/35mm 运镜底片 + Chrome 32-bit Alpha AR 叠加层）
import { spawn, spawnSync } from "node:child_process";
import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { resolve } from "node:path";

const CHROME = process.env.CHROME || "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome";
const FFMPEG = process.env.FFMPEG || Bun.which("ffmpeg") || "ffmpeg";
const RENDERER_URL = `file://${resolve(import.meta.dir, "./renderer.html")}`;
const STORYBOARD_PATH = resolve(import.meta.dir, "../storyboard.json");
const LIVE_ASSETS = resolve(import.meta.dir, "../assets/live");
const BROLL_DIR = "/tmp/rc-promo15/broll";
const BG_DIR = "/tmp/rc-promo15/live-bg";
const OUT_DIR = resolve(import.meta.dir, "../out");

mkdirSync(BG_DIR, { recursive: true });
mkdirSync(BROLL_DIR, { recursive: true });
mkdirSync(OUT_DIR, { recursive: true });

const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

async function ensureBrollClip(mediaName: string) {
  if (!mediaName.endsWith(".mp4")) return;
  const dst = `${BROLL_DIR}/${mediaName}`;
  if (existsSync(dst)) return;
  const idMatch = mediaName.match(/clip-(\d+)\.mp4/);
  if (!idMatch) throw new Error(`Unknown B-roll clip name: ${mediaName}`);
  const id = idMatch[1];
  const res = await fetch(`https://assets.mixkit.co/videos/${id}/${id}-720.mp4`);
  if (!res.ok) throw new Error(`Failed to fetch B-roll clip ${id}: ${res.status}`);
  writeFileSync(dst, Buffer.from(await res.arrayBuffer()));
}

function runFfmpeg(args: string[], label: string) {
  const res = spawnSync(FFMPEG, ["-y", "-loglevel", "error", ...args], { stdio: ["ignore", "pipe", "pipe"] });
  if (res.status !== 0) {
    throw new Error(`FFmpeg failed (${label}): ${res.stderr?.toString()}`);
  }
}

function renderSubClip(
  mediaName: string,
  frames: number,
  W: number,
  H: number,
  motion: string,
  isCta: boolean,
  outPath: string
) {
  const dur = (frames / 30).toFixed(4);
  if (mediaName.endsWith(".mp4")) {
    const src = `${BROLL_DIR}/${mediaName}`;
    if (!existsSync(src)) throw new Error(`Missing B-roll clip: ${src}`);
    const blur = isCta ? ",gblur=sigma=12" : "";
    const vf = `fps=30,scale=${W}:${H}:force_original_aspect_ratio=increase,crop=${W}:${H},eq=contrast=1.06:saturation=1.06:brightness=-0.02${blur},vignette=PI/6,setsar=1,format=yuv420p`;
    runFfmpeg(
      [
        "-stream_loop", "-1",
        "-i", src,
        "-frames:v", String(frames),
        "-vf", vf,
        "-an",
        "-c:v", "libx264",
        "-preset", "veryfast",
        "-crf", "16",
        outPath,
      ],
      `broll:${mediaName}`
    );
  } else {
    const src = `${LIVE_ASSETS}/${mediaName}`;
    if (!existsSync(src)) throw new Error(`Missing live photo: ${src}`);
    const upW = W * 2;
    const upH = H * 2;
    const N = Math.max(2, frames);
    let zp = `z='1.02+0.10*on/${N}':x='iw/2-(iw/zoom/2)':y='ih/2-(ih/zoom/2)'`;
    if (motion === "pull-out") {
      zp = `z='1.12-0.10*on/${N}':x='iw/2-(iw/zoom/2)':y='ih/2-(ih/zoom/2)'`;
    } else if (motion === "pan-right") {
      zp = `z='1.10':x='(iw-iw/zoom)*(0.22+0.56*on/${N})':y='(ih-ih/zoom)/2'`;
    } else if (motion === "pan-left") {
      zp = `z='1.10':x='(iw-iw/zoom)*(0.78-0.56*on/${N})':y='(ih-ih/zoom)/2'`;
    } else if (motion === "drift" || isCta) {
      zp = `z='1.05+0.05*on/${N}':x='iw/2-(iw/zoom/2)':y='ih/2-(ih/zoom/2)'`;
    }
    const blur = isCta ? ",gblur=sigma=14" : "";
    // Subtle 35mm organic film grain + lens vignette
    const vf = `scale=${upW}:${upH}:force_original_aspect_ratio=increase,crop=${upW}:${upH},zoompan=${zp}:d=${frames}:s=${W}x${H}:fps=30,eq=contrast=1.04:saturation=1.05${blur},noise=alls=3:allf=t,vignette=PI/6,setsar=1,format=yuv420p`;
    runFfmpeg(
      [
        "-loop", "1",
        "-i", src,
        "-frames:v", String(frames),
        "-t", dur,
        "-vf", vf,
        "-an",
        "-c:v", "libx264",
        "-preset", "veryfast",
        "-crf", "16",
        outPath,
      ],
      `photo:${mediaName}`
    );
  }
}

function buildLiveBackdrop(v: any): string {
  const totalFrames = Math.round(v.durationSec * 30);
  const W = v.width;
  const H = v.height;
  const segPaths: string[] = [];

  let cursorFrame = 0;
  for (let si = 0; si < v.scenes.length; si++) {
    const sc = v.scenes[si];
    const endFrame = si === v.scenes.length - 1 ? totalFrames : Math.round(sc.endSec * 30);
    const segFrames = Math.max(15, endFrame - cursorFrame);
    cursorFrame = endFrame;

    const segOut = `${BG_DIR}/${v.id}-s${si}.mp4`;
    const prim = sc.liveMedia?.primary || "live-16-hook.jpg";
    const cut = sc.liveMedia?.cutaway;
    const motion = sc.liveMedia?.motion || "push-in";
    const isCta = sc.act === "cta";

    if (cut && !isCta && segFrames >= 90) {
      const xfadeFrames = 10; // 0.33s smooth cinema dissolve
      const fA = Math.round(segFrames * 0.56) + xfadeFrames;
      const fB = segFrames - Math.round(segFrames * 0.56);
      const partA = `${BG_DIR}/${v.id}-s${si}-a.mp4`;
      const partB = `${BG_DIR}/${v.id}-s${si}-b.mp4`;
      renderSubClip(prim, fA, W, H, motion, false, partA);
      renderSubClip(cut, fB, W, H, motion === "push-in" ? "pull-out" : "push-in", false, partB);
      const offsetSec = ((fA - xfadeFrames) / 30).toFixed(4);
      runFfmpeg(
        [
          "-i", partA,
          "-i", partB,
          "-filter_complex", `[0:v][1:v]xfade=transition=fade:duration=0.3333:offset=${offsetSec},trim=end_frame=${segFrames},setpts=PTS-STARTPTS[v]`,
          "-map", "[v]",
          "-c:v", "libx264",
          "-preset", "veryfast",
          "-crf", "16",
          segOut,
        ],
        `xfade:${v.id}:s${si}`
      );
    } else {
      renderSubClip(prim, segFrames, W, H, motion, isCta, segOut);
    }
    segPaths.push(segOut);
  }

  const listFile = `${BG_DIR}/${v.id}-concat.txt`;
  writeFileSync(listFile, segPaths.map((p) => `file '${p}'`).join("\n"));
  const bgMp4 = `${BG_DIR}/${v.id}-bg.mp4`;
  runFfmpeg(
    [
      "-f", "concat",
      "-safe", "0",
      "-i", listFile,
      "-c:v", "libx264",
      "-preset", "fast",
      "-crf", "16",
      "-pix_fmt", "yuv420p",
      bgMp4,
    ],
    `concat:${v.id}`
  );
  console.log(`  ✓ Backdrop ready: ${v.slug} (${W}x${H}, ${totalFrames} frames)`);
  return bgMp4;
}

async function renderOverlayAndComposite(v: any, bgMp4: string, workerIdx: number) {
  const port = 9840 + workerIdx * 9 + Math.floor(Math.random() * 5);
  const profDir = `/tmp/rc-promo15/chrome-live-w${workerIdx}-${port}`;
  mkdirSync(profDir, { recursive: true });

  const chrome = spawn(
    CHROME,
    [
      "--headless",
      `--remote-debugging-port=${port}`,
      `--user-data-dir=${profDir}`,
      "--no-first-run",
      "--disable-gpu",
      "--hide-scrollbars",
      "--force-device-scale-factor=1",
      "--allow-file-access-from-files",
      "about:blank",
    ],
    { stdio: "ignore" }
  );

  try {
    let wsUrl = "";
    for (let i = 0; i < 60; i++) {
      try {
        const r = await fetch(`http://127.0.0.1:${port}/json/list`);
        const list = (await r.json()) as any[];
        const p = list.find((x) => x.type === "page");
        if (p?.webSocketDebuggerUrl) {
          wsUrl = p.webSocketDebuggerUrl;
          break;
        }
      } catch {}
      await sleep(150);
    }
    if (!wsUrl) throw new Error(`Chrome worker ${workerIdx} unreachable`);

    const ws = new WebSocket(wsUrl);
    await new Promise((res, rej) => { ws.onopen = res; ws.onerror = rej; });
    let mid = 0;
    const pend = new Map<number, { resolve: (v: any) => void; reject: (e: any) => void }>();
    ws.onmessage = (ev) => {
      const m = JSON.parse(ev.data as string);
      if (m.id && pend.has(m.id)) {
        const p = pend.get(m.id)!;
        pend.delete(m.id);
        m.error ? p.reject(new Error(JSON.stringify(m.error))) : p.resolve(m.result);
      }
    };
    const send = (method: string, params: any = {}) =>
      new Promise<any>((resolve, reject) => {
        const id = ++mid;
        pend.set(id, { resolve, reject });
        ws.send(JSON.stringify({ id, method, params }));
      });
    const evalJs = async (expression: string, awaitPromise = true) =>
      (await send("Runtime.evaluate", { expression, returnByValue: true, awaitPromise }))?.result?.value;

    await send("Page.enable");
    await send("Runtime.enable");
    await send("Emulation.setDeviceMetricsOverride", {
      width: v.width,
      height: v.height,
      deviceScaleFactor: 1,
      mobile: false,
    });
    // Transparent page background so captureScreenshot(omitBackground: true) yields 32-bit RGBA PNG!
    await send("Emulation.setDefaultBackgroundColorOverride", {
      color: { r: 0, g: 0, b: 0, a: 0 },
    });
    await send("Page.navigate", { url: RENDERER_URL });
    await sleep(600);
    await evalJs(`window.preloadAll()`, true);
    await evalJs(`window.LIVE_OVERLAY_ONLY = true; window.setPlan(${JSON.stringify(v)});`, false);

    const totalFrames = Math.round(v.durationSec * 30);
    const audioWav = `/tmp/rc-promo15/audio/${v.id}.wav`;
    const outMp4 = `${OUT_DIR}/${v.slug}.mp4`;

    const ff = spawn(
      FFMPEG,
      [
        "-y",
        "-loglevel", "error",
        "-i", bgMp4,
        "-f", "image2pipe",
        "-framerate", "30",
        "-c:v", "png",
        "-i", "-",
        "-i", audioWav,
        "-filter_complex", "[0:v][1:v]overlay=0:0:shortest=1,format=yuv420p[v]",
        "-map", "[v]",
        "-map", "2:a",
        "-c:v", "libx264",
        "-preset", "medium",
        "-crf", "18",
        "-profile:v", "high",
        "-pix_fmt", "yuv420p",
        "-r", "30",
        "-c:a", "aac",
        "-b:a", "192k",
        "-shortest",
        "-movflags", "+faststart",
        outMp4,
      ],
      { stdio: ["pipe", "ignore", "pipe"] }
    );

    let ffErr = "";
    ff.stderr.on("data", (d) => (ffErr += d.toString()));

    const t0 = Date.now();
    for (let f = 0; f < totalFrames; f++) {
      const t = f / 30;
      await evalJs(`window.renderFrame(${t.toFixed(5)})`, false);
      const shot = await send("Page.captureScreenshot", {
        format: "png",
        omitBackground: true,
        optimizeForSpeed: true,
      });
      const buf = Buffer.from(shot.data, "base64");
      if (!ff.stdin.write(buf)) {
        await new Promise<void>((r) => ff.stdin.once("drain", () => r()));
      }
      if ((f + 1) % 300 === 0) {
        const fps = ((f + 1) / ((Date.now() - t0) / 1000)).toFixed(1);
        console.log(`  [live-w${workerIdx}] ${v.slug}: ${f + 1}/${totalFrames} frames (${fps} fps)`);
      }
    }
    ff.stdin.end();
    const exitCode: number = await new Promise((r) => ff.on("close", (c) => r(c ?? 1)));
    if (exitCode !== 0) {
      throw new Error(`FFmpeg composite failed for ${v.slug}: ${ffErr}`);
    }
    const sec = ((Date.now() - t0) / 1000).toFixed(1);
    console.log(`  ★ LIVE DONE [w${workerIdx}] ${v.slug}.mp4 (${v.width}x${v.height}, ${totalFrames}f in ${sec}s)`);
    ws.close();
  } finally {
    chrome.kill("SIGKILL");
  }
}

const sb = JSON.parse(readFileSync(STORYBOARD_PATH, "utf-8"));
const liveVideos = sb.videos.filter((v: any) => v.engine === "live-cinema");

console.log(`=== Step 1: Building 30fps Live-Action + 35mm Cinema Backdrops (${liveVideos.length} videos) ===`);
for (const v of liveVideos) {
  for (const sc of v.scenes) {
    if (sc.liveMedia?.primary) await ensureBrollClip(sc.liveMedia.primary);
    if (sc.liveMedia?.cutaway) await ensureBrollClip(sc.liveMedia.cutaway);
  }
}
const bgMap = new Map<string, string>();
for (const v of liveVideos) {
  bgMap.set(v.id, buildLiveBackdrop(v));
}

console.log(`=== Step 2: Compositing RGBA Spatial AR + Real App UI Overlays (${liveVideos.length} parallel workers) ===`);
await Promise.all(liveVideos.map((v: any, idx: number) => renderOverlayAndComposite(v, bgMap.get(v.id)!, idx)));
console.log("=== ALL 5 LIVE-ACTION SCENARIO PROMO VIDEOS RENDERED! ===");
