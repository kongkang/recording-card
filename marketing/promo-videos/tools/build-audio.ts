// build-audio.ts — 神经网络配音（edge-tts）+ 精确分镜定轴（storyboard.json）+ 15 首独立编曲 + 自动闪避混音 + 电影拟音钉帧
import { spawn } from "node:child_process";
import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { resolve } from "node:path";
import { VIDEOS_SPEC, type SfxKind, type VideoSpec } from "./videos-spec";

const UVX = process.env.UVX || Bun.which("uvx") || "uvx";
const FFMPEG = process.env.FFMPEG || Bun.which("ffmpeg") || "ffmpeg";
const WORK_DIR = "/tmp/rc-promo15/audio";
const VO_DIR = `${WORK_DIR}/vo`;
const STORYBOARD_OUT = resolve(import.meta.dir, "../storyboard.json");

mkdirSync(VO_DIR, { recursive: true });

const SR = 44100;

function runCmd(cmd: string, args: string[]): Promise<{ code: number; stderr: string }> {
  return new Promise((res) => {
    const p = spawn(cmd, args, { stdio: ["ignore", "ignore", "pipe"] });
    let err = "";
    p.stderr.on("data", (d) => (err += d.toString()));
    p.on("close", (code) => res({ code: code ?? 1, stderr: err }));
  });
}

/** 读取 16-bit Stereo 44.1kHz WAV 为交错 Float32Array */
function readWavStereo(path: string): Float32Array {
  const data = readFileSync(path);
  let i = 12;
  let dataStart = 44;
  let dataLen = data.length - 44;
  while (i + 8 <= data.length) {
    const id = data.toString("ascii", i, i + 4);
    const sz = data.readUInt32LE(i + 4);
    if (id === "data") {
      dataStart = i + 8;
      dataLen = Math.min(sz, data.length - dataStart);
      break;
    }
    i += 8 + sz + (sz % 2);
  }
  const samples = Math.floor(dataLen / 2);
  const out = new Float32Array(samples);
  for (let s = 0; s < samples; s++) {
    out[s] = data.readInt16LE(dataStart + s * 2) / 32768;
  }
  return out;
}

function writeWavStereo(path: string, buf: Float32Array) {
  const frames = Math.floor(buf.length / 2);
  const b = Buffer.alloc(44 + frames * 4);
  b.write("RIFF", 0);
  b.writeUInt32LE(36 + frames * 4, 4);
  b.write("WAVE", 8);
  b.write("fmt ", 12);
  b.writeUInt32LE(16, 16);
  b.writeUInt16LE(1, 20);
  b.writeUInt16LE(2, 22);
  b.writeUInt32LE(SR, 24);
  b.writeUInt32LE(SR * 4, 28);
  b.writeUInt16LE(4, 32);
  b.writeUInt16LE(16, 34);
  b.write("data", 36);
  b.writeUInt32LE(frames * 4, 40);
  for (let i = 0; i < frames * 2; i++) {
    const v = Math.max(-32768, Math.min(32767, Math.round(buf[i] * 32767)));
    b.writeInt16LE(v, 44 + i * 2);
  }
  writeFileSync(path, b);
}

/** 生成单条场景神经网络配音并裁剪首尾静音（按文本内容哈希缓存，修改台词自动重录） */
async function synthSceneVo(v: VideoSpec, sIdx: number): Promise<string> {
  const sc = v.scenes[sIdx]!;
  const txtHash = Bun.hash(`${v.voice.name}|${v.voice.rate}|${v.voice.pitch}|${sc.vo}`).toString(36).slice(0, 8);
  const key = `${v.id}-${sc.id}-${txtHash}`;
  const mp3 = `${VO_DIR}/${key}.mp3`;
  const wav = `${VO_DIR}/${key}.wav`;
  const legacyWav = `${VO_DIR}/${v.id}-${sc.id}.wav`;
  for (const cand of [wav, legacyWav]) {
    if (existsSync(cand)) {
      const existing = readWavStereo(cand);
      if (existing.length > SR * 0.8) return cand;
    }
  }

  let ok = false;
  for (let attempt = 0; attempt < 3; attempt++) {
    const r = await runCmd(UVX, [
      "edge-tts",
      "--voice",
      v.voice.name,
      `--rate=${v.voice.rate}`,
      `--pitch=${v.voice.pitch}`,
      "--text",
      sc.vo,
      "--write-media",
      mp3,
    ]);
    if (r.code === 0 && existsSync(mp3)) {
      ok = true;
      break;
    }
    await new Promise((r2) => setTimeout(r2, 600 * (attempt + 1)));
  }

  if (!ok) {
    // 本地兜底（仅当离线时触发）
    const aiff = `${VO_DIR}/${key}.aiff`;
    await runCmd("/usr/bin/say", ["-v", "Tingting", "-r", "205", "-o", aiff, sc.vo]);
    await runCmd(FFMPEG, ["-y", "-i", aiff, "-ar", "44100", "-ac", "2", "-c:a", "pcm_s16le", wav]);
    return wav;
  }

  await runCmd(FFMPEG, [
    "-y",
    "-i",
    mp3,
    "-af",
    "silenceremove=start_periods=1:start_silence=0.03:start_threshold=-46dB,areverse,silenceremove=start_periods=1:start_silence=0.05:start_threshold=-46dB,areverse,highpass=f=80,equalizer=f=3400:t=q:w=1.2:g=2.2",
    "-ar",
    "44100",
    "-ac",
    "2",
    "-c:a",
    "pcm_s16le",
    wav,
  ]);
  return wav;
}

/* ==================== 物理与电影系拟音合成（严禁游戏电子提示音，遵循 video-shotcraft S1/S2/S4） ==================== */
function makeRng(seed: number) {
  let a = seed | 0;
  return () => {
    a = (a + 0x6d2b79f5) | 0;
    let t = Math.imul(a ^ (a >>> 15), 1 | a);
    t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296 - 0.5;
  };
}

function addStereo(dst: Float32Array, tSec: number, srcL: Float32Array, srcR: Float32Array, gain = 1) {
  const startFrame = Math.max(0, Math.round(tSec * SR));
  const totalFrames = Math.floor(dst.length / 2);
  for (let i = 0; i < srcL.length && startFrame + i < totalFrames; i++) {
    const idx = (startFrame + i) * 2;
    dst[idx] += srcL[i]! * gain;
    dst[idx + 1] += srcR[i]! * gain;
  }
}

function synthSfx(kind: SfxKind, seed = 101): [Float32Array, Float32Array] {
  const rnd = makeRng(seed);
  if (kind === "whoosh" || kind === "deep-whoosh") {
    const dur = kind === "deep-whoosh" ? 0.52 : 0.34;
    const n = Math.floor(dur * SR);
    const L = new Float32Array(n), R = new Float32Array(n);
    let lpL = 0, lpR = 0;
    for (let i = 0; i < n; i++) {
      const p = i / n;
      const env = Math.sin(Math.pow(p, 0.75) * Math.PI);
      const cutoff = kind === "deep-whoosh" ? 0.03 + 0.14 * env : 0.06 + 0.28 * env;
      lpL += cutoff * (rnd() * 2 - lpL);
      lpR += cutoff * (rnd() * 2 - lpR);
      const pan = -0.35 + 0.7 * p;
      const sub = kind === "deep-whoosh" ? Math.sin(2 * Math.PI * (55 + 45 * (1 - p)) * (i / SR)) * 0.32 * env : 0;
      L[i] = (lpL * 0.65 + sub) * env * Math.sqrt(0.5 * (1 - pan));
      R[i] = (lpR * 0.65 + sub) * env * Math.sqrt(0.5 * (1 + pan));
    }
    return [L, R];
  }
  if (kind === "click") {
    // 真实微动机械开关拟音：双瞬态（按下 0ms + 弹片 14ms）
    const n = Math.floor(0.065 * SR);
    const L = new Float32Array(n), R = new Float32Array(n);
    for (let i = 0; i < n; i++) {
      const t = i / SR;
      const c1 = Math.exp(-t / 0.0022) * (Math.sin(2 * Math.PI * 1850 * t) * 0.5 + rnd() * 0.8);
      const dt = t - 0.014;
      const c2 = dt > 0 ? Math.exp(-dt / 0.003) * (Math.sin(2 * Math.PI * 2600 * dt) * 0.35 + rnd() * 0.5) : 0;
      const v = (c1 + c2 * 0.65) * 0.7;
      L[i] = v; R[i] = v * 0.96;
    }
    return [L, R];
  }
  if (kind === "shutter") {
    // 真实双帘快门拟音
    const n = Math.floor(0.16 * SR);
    const L = new Float32Array(n), R = new Float32Array(n);
    let bp = 0;
    for (let i = 0; i < n; i++) {
      const t = i / SR;
      const x = rnd();
      bp += 0.35 * (x - bp);
      const hp = x - bp;
      const curtain1 = Math.exp(-t / 0.0045) * (hp * 1.1 + Math.sin(2 * Math.PI * 1200 * t) * 0.35);
      const t2 = t - 0.042;
      const curtain2 = t2 > 0 ? Math.exp(-t2 / 0.006) * (hp * 0.85 + Math.sin(2 * Math.PI * 920 * t2) * 0.3) : 0;
      L[i] = (curtain1 + curtain2) * 0.75;
      R[i] = (curtain1 * 0.92 + curtain2 * 1.05) * 0.75;
    }
    return [L, R];
  }
  if (kind === "paper") {
    // 干燥纸卡滑动拟音
    const n = Math.floor(0.24 * SR);
    const L = new Float32Array(n), R = new Float32Array(n);
    let b1 = 0, b2 = 0;
    for (let i = 0; i < n; i++) {
      const p = i / n;
      const env = Math.pow(Math.sin(p * Math.PI), 0.8) * Math.exp(-p * 1.4);
      const x = rnd();
      b1 += 0.45 * (x - b1);
      b2 += 0.12 * (b1 - b2);
      const band = b1 - b2;
      L[i] = band * env * 1.3;
      R[i] = band * env * 1.15;
    }
    return [L, R];
  }
  if (kind === "type") {
    // 双样本交替 + 音量阶梯递减键盘拟音（video-shotcraft S2）
    const n = Math.floor(0.58 * SR);
    const L = new Float32Array(n), R = new Float32Array(n);
    const hits = [0.0, 0.095, 0.175, 0.245, 0.305, 0.36];
    hits.forEach((ht, idx) => {
      const gain = 0.42 - idx * 0.04;
      const f = idx % 2 === 0 ? 1520 : 1780;
      const s0 = Math.floor(ht * SR);
      const len = Math.floor(0.035 * SR);
      for (let k = 0; k < len && s0 + k < n; k++) {
        const tt = k / SR;
        const v = Math.exp(-tt / 0.0032) * (rnd() * 0.9 + Math.sin(2 * Math.PI * f * tt) * 0.35) * gain;
        L[s0 + k] += v * (idx % 2 ? 0.9 : 1.05);
        R[s0 + k] += v * (idx % 2 ? 1.05 : 0.9);
      }
    });
    return [L, R];
  }
  if (kind === "riser") {
    const n = Math.floor(0.95 * SR);
    const L = new Float32Array(n), R = new Float32Array(n);
    let lpL = 0, lpR = 0;
    for (let i = 0; i < n; i++) {
      const p = i / n;
      const env = p * p * p;
      const cut = 0.02 + 0.32 * env;
      lpL += cut * (rnd() - lpL);
      lpR += cut * (rnd() - lpR);
      const tone = Math.sin(2 * Math.PI * (140 + 280 * p * p) * (i / SR)) * 0.22 * env;
      L[i] = lpL * 1.2 * env + tone;
      R[i] = lpR * 1.2 * env + tone;
    }
    return [L, R];
  }
  if (kind === "shimmer") {
    const n = Math.floor(1.15 * SR);
    const L = new Float32Array(n), R = new Float32Array(n);
    const freqs = [1046.5, 1318.5, 1568.0, 2093.0];
    for (let i = 0; i < n; i++) {
      const t = i / SR;
      let vL = 0, vR = 0;
      freqs.forEach((f, k) => {
        const dt = Math.max(0, t - k * 0.032);
        if (dt <= 0) return;
        const env = Math.min(1, dt / 0.008) * Math.exp(-dt / (0.42 - k * 0.05));
        const s = Math.sin(2 * Math.PI * f * dt) * env * 0.16;
        vL += s * (k % 2 ? 0.75 : 1.0);
        vR += s * (k % 2 ? 1.0 : 0.75);
      });
      L[i] = vL; R[i] = vR;
    }
    return [L, R];
  }
  // impact (cinematic sub impact + crisp transient)
  const n = Math.floor(1.35 * SR);
  const L = new Float32Array(n), R = new Float32Array(n);
  for (let i = 0; i < n; i++) {
    const t = i / SR;
    const subF = 44 + 88 * Math.exp(-t / 0.05);
    const sub = Math.sin(2 * Math.PI * subF * t) * Math.exp(-t / 0.48) * Math.min(1, t / 0.004);
    const punch = rnd() * Math.exp(-t / 0.018) * 0.45;
    const shimmer = (Math.sin(2 * Math.PI * 523.25 * t) + Math.sin(2 * Math.PI * 783.99 * t) * 0.7) * Math.exp(-t / 0.75) * 0.11;
    L[i] = sub * 0.68 + punch + shimmer;
    R[i] = sub * 0.68 + punch * 0.92 + shimmer * 1.08;
  }
  return [L, R];
}

/* ==================== 15 首独立风格原创配乐引擎 ==================== */
const mtof = (m: number) => 440 * Math.pow(2, (m - 69) / 12);

const SCALES: Record<VideoSpec["music"]["scale"], number[]> = {
  minor: [0, 2, 3, 5, 7, 8, 10],
  major: [0, 2, 4, 5, 7, 9, 11],
  dorian: [0, 2, 3, 5, 7, 9, 10],
  pentatonic: [0, 2, 4, 7, 9, 12, 14],
  lydian: [0, 2, 4, 6, 7, 9, 11],
};

function composeMusic(v: VideoSpec, totalDur: number, seed: number): Float32Array {
  const totalSamples = Math.ceil(totalDur * SR) * 2;
  const buf = new Float32Array(totalSamples);
  const { bpm, rootMidi, scale, feel } = v.music;
  const beatSec = 60 / bpm;
  const barSec = beatSec * 4;
  const deg = SCALES[scale];
  const rnd = makeRng(seed);

  const chordProg =
    scale === "minor" || scale === "dorian"
      ? [
          [0, 2, 4, 6],
          [5, 0 + 7, 2 + 7, 4 + 7],
          [3, 5, 0 + 7, 2 + 7],
          [4, 6, 1 + 7, 3 + 7],
        ]
      : [
          [0, 2, 4, 6],
          [4, 6, 1 + 7, 3 + 7],
          [5, 0 + 7, 2 + 7, 4 + 7],
          [3, 5, 0 + 7, 2 + 7],
        ];

  const noteAt = (d: number, octOffset = 0) => {
    const oct = Math.floor(d / 7);
    const idx = ((d % 7) + 7) % 7;
    return mtof(rootMidi + (oct + octOffset) * 12 + deg[idx]!);
  };

  const addTone = (
    t0: number,
    dur: number,
    freq: number,
    gain: number,
    pan: number,
    timbre: "pad" | "pluck" | "bell" | "bass"
  ) => {
    const s0 = Math.max(0, Math.floor(t0 * SR));
    const len = Math.min(Math.floor(dur * SR), Math.floor(totalSamples / 2) - s0);
    if (len <= 0) return;
    const gL = gain * Math.sqrt(0.5 * (1 - pan));
    const gR = gain * Math.sqrt(0.5 * (1 + pan));
    const w = (2 * Math.PI * freq) / SR;
    for (let i = 0; i < len; i++) {
      const tt = i / SR;
      let env = 0;
      let sig = 0;
      if (timbre === "pad") {
        env = Math.min(1, tt / 0.35) * Math.min(1, Math.max(0, (dur - tt) / 0.45));
        sig = Math.sin(w * i) * 0.58 + Math.sin(w * 1.004 * i) * 0.28 + Math.sin(w * 0.5 * i) * 0.22;
      } else if (timbre === "pluck") {
        env = Math.min(1, tt / 0.004) * Math.exp(-tt / (dur * 0.42));
        sig = Math.sin(w * i) * 0.65 + Math.sin(w * 2 * i) * 0.24 * Math.exp(-tt / 0.08) + Math.sin(w * 3 * i) * 0.08;
      } else if (timbre === "bell") {
        env = Math.min(1, tt / 0.003) * Math.exp(-tt / (dur * 0.55));
        sig = Math.sin(w * i) * 0.7 + Math.sin(w * 2.0 * i) * 0.2 + Math.sin(w * 4.0 * i) * 0.08 * Math.exp(-tt / 0.05);
      } else {
        // bass
        env = Math.min(1, tt / 0.012) * Math.min(1, Math.max(0, (dur - tt) / 0.08)) * Math.exp(-tt / (dur * 0.9));
        sig = Math.tanh((Math.sin(w * i) + 0.35 * Math.sin(w * 2 * i)) * 1.4) * 0.75;
      }
      const idx = (s0 + i) * 2;
      buf[idx] += sig * env * gL;
      buf[idx + 1] += sig * env * gR;
    }
  };

  const bars = Math.ceil(totalDur / barSec);
  const hasDrums = !["warmpad", "ambient", "chamber"].includes(feel);
  const energetic = ["techhouse", "hyperpop", "streetbeat", "synthwave", "industrial", "anthem"].includes(feel);

  for (let b = 0; b < bars; b++) {
    const bt0 = b * barSec;
    const ch = chordProg[b % chordProg.length]!;
    // Warm stereo pad
    ch.forEach((d, k) => {
      addTone(bt0, barSec * 1.05, noteAt(d, 1), 0.095, k % 2 === 0 ? -0.32 : 0.32, "pad");
    });
    // Bassline
    if (energetic) {
      for (let step = 0; step < 8; step++) {
        const t = bt0 + step * (beatSec * 0.5);
        addTone(t, beatSec * 0.44, noteAt(ch[0]!, 0), step % 2 === 0 ? 0.22 : 0.15, 0, "bass");
      }
    } else {
      addTone(bt0, barSec * 0.95, noteAt(ch[0]!, 0), 0.19, 0, "bass");
      if (feel !== "ambient") {
        addTone(bt0 + beatSec * 2, beatSec * 1.8, noteAt(ch[0]!, 0), 0.15, 0, "bass");
      }
    }
    // Arpeggio / Melody plucks
    const stepsPerBar = feel === "hyperpop" || feel === "synthwave" ? 8 : 4;
    for (let s = 0; s < stepsPerBar; s++) {
      const t = bt0 + s * (barSec / stepsPerBar);
      const degPick = ch[(s + b) % ch.length]!;
      const oct = feel === "warmpad" || feel === "ambient" || feel === "chamber" ? 2 : 2;
      const timb = feel === "warmpad" || feel === "ambient" ? "bell" : "pluck";
      addTone(t, beatSec * 0.85, noteAt(degPick, oct), 0.11, s % 2 ? 0.28 : -0.28, timb);
    }

    // Drums (kick, crisp snare/clap, hi-hat)
    if (hasDrums) {
      for (let beat = 0; beat < 4; beat++) {
        const kt = bt0 + beat * beatSec;
        // Kick on 0, 2 (or 4-on-the-floor for energetic)
        if (energetic || beat === 0 || beat === 2) {
          const ks0 = Math.floor(kt * SR);
          const klen = Math.min(Math.floor(0.22 * SR), Math.floor(totalSamples / 2) - ks0);
          for (let i = 0; i < klen; i++) {
            const tt = i / SR;
            const kf = 46 + 105 * Math.exp(-tt / 0.028);
            const kv = Math.sin(2 * Math.PI * kf * tt) * Math.exp(-tt / 0.12) * Math.min(1, tt / 0.002) * 0.36;
            buf[(ks0 + i) * 2] += kv;
            buf[(ks0 + i) * 2 + 1] += kv;
          }
        }
        // Soft crisp snare/clap on beat 1 & 3
        if ((beat === 1 || beat === 3) && (energetic || feel === "lofi" || feel === "cinematic" || feel === "acoustic")) {
          const cs0 = Math.floor(kt * SR);
          const clen = Math.min(Math.floor(0.11 * SR), Math.floor(totalSamples / 2) - cs0);
          let lp = 0;
          for (let i = 0; i < clen; i++) {
            const tt = i / SR;
            const n = rnd();
            lp += 0.28 * (n - lp);
            const hp = n - lp;
            const cv = hp * Math.exp(-tt / 0.042) * (energetic ? 0.24 : 0.14);
            buf[(cs0 + i) * 2] += cv * 1.04;
            buf[(ks0Safe(cs0, i, totalSamples)) + 1] += cv * 0.96;
          }
        }
        // Hi-hats on 8ths
        for (let sub = 0; sub < 2; sub++) {
          const ht = kt + sub * beatSec * 0.5;
          const hs0 = Math.floor(ht * SR);
          const hlen = Math.min(Math.floor(0.04 * SR), Math.floor(totalSamples / 2) - hs0);
          let prev = 0;
          for (let i = 0; i < hlen; i++) {
            const tt = i / SR;
            const x = rnd();
            const hp = x - prev;
            prev = x;
            const hv = hp * Math.exp(-tt / 0.016) * (sub === 1 ? 0.11 : 0.07);
            buf[(hs0 + i) * 2] += hv * 0.9;
            buf[(hs0 + i) * 2 + 1] += hv * 1.1;
          }
        }
      }
    }
  }
  return buf;
}

function ks0Safe(base: number, i: number, maxLen: number) {
  const idx = (base + i) * 2;
  return idx + 1 < maxLen ? idx : maxLen - 2;
}

/* ==================== 主执行流程 ==================== */
console.log(`=== Step 1: Synthesizing 75 studio neural voiceovers across 15 personas ===`);
const allTasks: Array<() => Promise<void>> = [];
const voMap = new Map<string, string>();

for (const v of VIDEOS_SPEC) {
  v.scenes.forEach((sc, idx) => {
    allTasks.push(async () => {
      const p = await synthSceneVo(v, idx);
      voMap.set(`${v.id}-${sc.id}`, p);
      process.stdout.write(`.`);
    });
  });
}

// Run 6 parallel TTS workers
const CONCURRENCY = 6;
let cursor = 0;
await Promise.all(
  Array.from({ length: CONCURRENCY }, async () => {
    while (cursor < allTasks.length) {
      const idx = cursor++;
      await allTasks[idx]!();
    }
  })
);
console.log("\nAll 75 neural voiceovers ready!");

console.log(`=== Step 2: Building millisecond-locked storyboard.json & mixing 15 soundtracks ===`);

export interface RenderedSceneTiming {
  id: string;
  act: string;
  startSec: number;
  endSec: number;
  durationSec: number;
  voStartSec: number;
  voEndSec: number;
  vo: string;
  headline: [string, string?];
  accentWord?: string;
  badge?: string;
  uiShot?: string;
  uiShot2?: string;
  focus?: [number, number, number];
  sfx: SfxKind;
}

export interface RenderedVideoPlan extends Omit<VideoSpec, "scenes"> {
  width: number;
  height: number;
  fps: number;
  durationSec: number;
  audioWav: string;
  scenes: RenderedSceneTiming[];
}

const plans: RenderedVideoPlan[] = [];

for (let vIdx = 0; vIdx < VIDEOS_SPEC.length; vIdx++) {
  const v = VIDEOS_SPEC[vIdx]!;
  const width = v.aspect === "16:9" ? 1920 : 1080;
  const height = v.aspect === "16:9" ? 1080 : 1920;
  const fps = 30;

  let tCursor = 0;
  const sceneTimings: RenderedSceneTiming[] = [];
  const voBuffers: Array<{ voStart: number; pcm: Float32Array }> = [];

  for (let sIdx = 0; sIdx < v.scenes.length; sIdx++) {
    const sc = v.scenes[sIdx]!;
    const wavPath = voMap.get(`${v.id}-${sc.id}`)!;
    const pcm = readWavStereo(wavPath);
    const voDur = pcm.length / 2 / SR;

    const prePad = sIdx === 0 ? 0.22 : 0.20;
    const postPad = sc.holdAfterVoSec ?? 0.42;
    const sceneDur = Math.max(2.6, prePad + voDur + postPad);

    const startSec = Number(tCursor.toFixed(3));
    const voStartSec = Number((tCursor + prePad).toFixed(3));
    const voEndSec = Number((voStartSec + voDur).toFixed(3));
    const endSec = Number((tCursor + sceneDur).toFixed(3));

    sceneTimings.push({
      id: sc.id,
      act: sc.act,
      startSec,
      endSec,
      durationSec: Number((endSec - startSec).toFixed(3)),
      voStartSec,
      voEndSec,
      vo: sc.vo,
      headline: sc.headline,
      accentWord: sc.accentWord,
      badge: sc.badge,
      uiShot: sc.uiShot,
      uiShot2: sc.uiShot2,
      focus: sc.focus,
      liveMedia: sc.liveMedia,
      sfx: sc.sfx,
    });

    voBuffers.push({ voStart: voStartSec, pcm });
    tCursor = endSec;
  }

  // Round total duration cleanly to exact frame multiple
  const totalFrames = Math.ceil(tCursor * fps);
  const totalDur = totalFrames / fps;
  sceneTimings[sceneTimings.length - 1]!.endSec = Number(totalDur.toFixed(3));
  sceneTimings[sceneTimings.length - 1]!.durationSec = Number(
    (totalDur - sceneTimings[sceneTimings.length - 1]!.startSec).toFixed(3)
  );

  // 1. Compose original music bed
  const bgm = composeMusic(v, totalDur, 1000 + vIdx * 37);
  const nFrames = Math.floor(bgm.length / 2);

  // 2. Build voiceover envelope for smooth sidechain ducking
  const voTrack = new Float32Array(bgm.length);
  for (const vb of voBuffers) {
    // Normalize each VO clip cleanly to 0.86 peak
    let pk = 0;
    for (let i = 0; i < vb.pcm.length; i++) pk = Math.max(pk, Math.abs(vb.pcm[i]!));
    const g = pk > 0.01 ? 0.86 / pk : 1;
    const s0 = Math.round(vb.voStart * SR);
    const vFrames = Math.floor(vb.pcm.length / 2);
    for (let f = 0; f < vFrames && s0 + f < nFrames; f++) {
      // 12ms micro fade-in/out to prevent clicks
      const fade = Math.min(1, f / (0.012 * SR)) * Math.min(1, (vFrames - f) / (0.015 * SR));
      voTrack[(s0 + f) * 2] += vb.pcm[f * 2]! * g * fade;
      voTrack[(s0 + f) * 2 + 1] += vb.pcm[f * 2 + 1]! * g * fade;
    }
  }

  // Sidechain envelope follower on VO
  const duckGain = new Float32Array(nFrames);
  let env = 0;
  const atk = 1 - Math.exp(-1 / (0.035 * SR));
  const rel = 1 - Math.exp(-1 / (0.28 * SR));
  for (let f = 0; f < nFrames; f++) {
    const lv = Math.max(Math.abs(voTrack[f * 2]!), Math.abs(voTrack[f * 2 + 1]!));
    env += (lv > env ? atk : rel) * (lv - env);
    // When voice speaks, duck BGM to 0.36x; when silent, bloom to 1.0x
    duckGain[f] = 1.0 - Math.min(0.64, env * 1.45);
  }

  // 3. Pin Foley SFX to exact scene transitions + riser → impact → shimmer closing cadence
  const sfxTrack = new Float32Array(bgm.length);
  sceneTimings.forEach((st, idx) => {
    const [sL, sR] = synthSfx(st.sfx, 500 + vIdx * 19 + idx * 7);
    const tPin = Math.max(0.02, st.startSec - 0.04); // Pre-offset for AAC priming & attack peak
    addStereo(sfxTrack, tPin, sL, sR, st.sfx === "impact" ? 0.48 : 0.34);

    // Before final CTA scene, add subtle cinematic riser + shimmer after impact
    if (idx === sceneTimings.length - 1) {
      const [rL, rR] = synthSfx("riser", 900 + vIdx);
      addStereo(sfxTrack, Math.max(0, st.startSec - 0.92), rL, rR, 0.28);
      const [shL, shR] = synthSfx("shimmer", 950 + vIdx);
      addStereo(sfxTrack, st.startSec + 0.18, shL, shR, 0.32);
    }
  });

  // 4. Master Mix + Soft Limiter + Fade In/Out
  const master = new Float32Array(bgm.length);
  const fadeInF = Math.floor(0.22 * SR);
  const fadeOutF = Math.floor(0.95 * SR);
  for (let f = 0; f < nFrames; f++) {
    const bgmScale = 0.44 * duckGain[f]!;
    let L = voTrack[f * 2]! * 0.94 + bgm[f * 2]! * bgmScale + sfxTrack[f * 2]!;
    let R = voTrack[f * 2 + 1]! * 0.94 + bgm[f * 2 + 1]! * bgmScale + sfxTrack[f * 2 + 1]!;
    if (f < fadeInF) {
      const k = f / fadeInF;
      L *= k; R *= k;
    }
    if (nFrames - f < fadeOutF) {
      const k = (nFrames - f) / fadeOutF;
      // Keep VO intact, fade music & tail smoothly
      L *= Math.max(0, k);
      R *= Math.max(0, k);
    }
    master[f * 2] = Math.tanh(L * 1.12) * 0.92;
    master[f * 2 + 1] = Math.tanh(R * 1.12) * 0.92;
  }

  const outWav = `${WORK_DIR}/${v.id}.wav`;
  writeWavStereo(outWav, master);

  plans.push({
    ...v,
    width,
    height,
    fps,
    durationSec: Number(totalDur.toFixed(3)),
    audioWav: outWav,
    scenes: sceneTimings,
  });

  console.log(`  ✓ [${v.num}] ${v.slug} (${v.aspect}) — ${totalDur.toFixed(1)}s | voice=${v.voice.name} | bpm=${v.music.bpm}`);
}

writeFileSync(STORYBOARD_OUT, JSON.stringify({ generatedAt: new Date().toISOString(), videos: plans }, null, 2));
console.log(`\nMaster storyboard written to ${STORYBOARD_OUT}`);
