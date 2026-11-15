// music.ts — 参数化合成 5 条宣传片的配乐，输出 44.1kHz 16bit 立体声 WAV
// usage: bun music.ts [videoId]   (缺省全部)
import { writeFileSync, mkdirSync } from "node:fs";

const SR = 44100;
const mtof = (m: number) => 440 * Math.pow(2, (m - 69) / 12);

interface Note { t: number; d: number; f: number; g: number; pan?: number; a?: number; }

function render(notes: Note[], dur: number, opts: { kick?: number[]; hat?: number[]; clap?: number[]; boom?: number[]; riser?: [number, number]; fadeOut?: number } = {}): Float32Array {
  const n = Math.ceil(dur * SR) * 2;
  const buf = new Float32Array(n);
  const add = (i: number, l: number, r: number) => {
    if (i >= 0 && i + 1 < n) { buf[i] += l; buf[i + 1] += r; }
  };
  // pads / plucks
  for (const nt of notes) {
    const start = Math.floor(nt.t * SR) * 2;
    const len = Math.floor(nt.d * SR) * 2;
    const a = nt.a ?? 0.02;
    const pan = nt.pan ?? 0;
    const gl = nt.g * Math.sqrt(0.5 * (1 - pan)), gr = nt.g * Math.sqrt(0.5 * (1 + pan));
    const w1 = 2 * Math.PI * nt.f / SR, w2 = 2 * Math.PI * nt.f * 1.003 / SR, w3 = 2 * Math.PI * nt.f * 0.5 / SR;
    const isPluck = nt.d < 1.6;
    for (let s = 0; s < len; s += 2) {
      const tt = s / 2 / SR;
      let env: number;
      if (isPluck) env = Math.exp(-tt / (nt.d * 0.4)) * Math.min(1, tt / 0.004);
      else env = Math.min(1, tt / a) * Math.min(1, Math.max(0, (nt.d - tt) / 0.6)) * (0.85 + 0.15 * Math.sin(tt * 0.7));
      const v = Math.sin(w1 * s / 2) * 0.62 + Math.sin(w2 * s / 2) * 0.28 + Math.sin(w3 * s / 2) * (isPluck ? 0.10 : 0.38);
      add(start + s, v * env * gl, v * env * gr);
    }
  }
  const rnd = (() => { let x = 12345; return () => { x = (x * 1103515245 + 12345) & 0x7fffffff; return x / 0x7fffffff - 0.5; }; })();
  // kick
  for (const t0 of opts.kick ?? []) {
    const start = Math.floor(t0 * SR) * 2;
    const len = Math.floor(0.28 * SR) * 2;
    for (let s = 0; s < len; s += 2) {
      const tt = s / 2 / SR;
      const f = 42 + 110 * Math.exp(-tt / 0.035);
      const env = Math.exp(-tt / 0.13) * Math.min(1, tt / 0.001);
      const v = Math.sin(2 * Math.PI * f * tt) * env;
      add(start + s, v * 0.5, v * 0.5);
    }
  }
  // boom (sub)
  for (const t0 of opts.boom ?? []) {
    const start = Math.floor(t0 * SR) * 2;
    const len = Math.floor(1.4 * SR) * 2;
    for (let s = 0; s < len; s += 2) {
      const tt = s / 2 / SR;
      const env = Math.exp(-tt / 0.6) * Math.min(1, tt / 0.01);
      const v = Math.sin(2 * Math.PI * 42 * tt + 2.5 * Math.exp(-tt / 0.09)) * env;
      add(start + s, v * 0.42, v * 0.42);
    }
  }
  // hats
  let hp = 0;
  for (const t0 of opts.hat ?? []) {
    const start = Math.floor(t0 * SR) * 2;
    const len = Math.floor(0.05 * SR) * 2;
    for (let s = 0; s < len; s += 2) {
      const tt = s / 2 / SR;
      const x = rnd() * Math.exp(-tt / 0.028);
      const v = x - hp; hp = x;
      add(start + s, v * 0.5, v * 0.5);
    }
  }
  // clap
  for (const t0 of opts.clap ?? []) {
    const start = Math.floor(t0 * SR) * 2;
    const len = Math.floor(0.14 * SR) * 2;
    for (let s = 0; s < len; s += 2) {
      const tt = s / 2 / SR;
      const env = Math.exp(-tt / 0.05) * (1 + 0.4 * Math.sin(tt * 180));
      const v = rnd() * env;
      add(start + s, v * 0.34, v * 0.3);
    }
  }
  // riser
  if (opts.riser) {
    const [t0, t1] = opts.riser;
    const s0 = Math.floor(t0 * SR) * 2, s1 = Math.floor(t1 * SR) * 2;
    let lp = 0;
    for (let s = s0; s < s1; s += 2) {
      const p = (s - s0) / (s1 - s0);
      const x = rnd() * p * p;
      lp += 0.12 * (x - lp);
      add(s, lp * 0.5, lp * 0.5);
    }
  }
  // master: soft clip + fades
  const fadeOut = opts.fadeOut ?? 1.3;
  const fadeSamples = fadeOut * SR * 2, fadeInSamples = 0.25 * SR * 2;
  for (let i = 0; i < n; i += 2) {
    const tt = i / 2 / SR;
    let l = Math.tanh(buf[i] * 1.4) * 0.92;
    let r = Math.tanh(buf[i + 1] * 1.4) * 0.92;
    if (i < fadeInSamples) { l *= i / fadeInSamples; r *= i / fadeInSamples; }
    const rem = (n - i) / 2 / SR;
    if (rem < fadeOut) { const k = rem / fadeOut; l *= k; r *= k; }
    buf[i] = l; buf[i + 1] = r;
  }
  // normalize to 0.55
  let peak = 0;
  for (let i = 0; i < n; i++) peak = Math.max(peak, Math.abs(buf[i]));
  const k = peak > 0 ? 0.55 / peak : 1;
  for (let i = 0; i < n; i++) buf[i] *= k;
  return buf;
}

function wav(buf: Float32Array): Buffer {
  const n = buf.length / 2;
  const b = Buffer.alloc(44 + n * 4);
  b.write("RIFF", 0); b.writeUInt32LE(36 + n * 4, 4); b.write("WAVE", 8);
  b.write("fmt ", 12); b.writeUInt32LE(16, 16); b.writeUInt16LE(1, 20); b.writeUInt16LE(2, 22);
  b.writeUInt32LE(SR, 24); b.writeUInt32LE(SR * 4, 28); b.writeUInt16LE(4, 32); b.writeUInt16LE(16, 34);
  b.write("data", 36); b.writeUInt32LE(n * 4, 40);
  for (let i = 0; i < n; i++) {
    b.writeInt16LE(Math.max(-32768, Math.min(32767, Math.round(buf[i * 2] * 32767))), 44 + i * 4);
    b.writeInt16LE(Math.max(-32768, Math.min(32767, Math.round(buf[i * 2 + 1] * 32767))), 46 + i * 4);
  }
  return b;
}

const pad = (t: number, d: number, midis: number[], g: number, a = 1.2): Note[] =>
  midis.map((m, i) => ({ t, d, f: mtof(m), g: g * (i === 0 ? 1 : 0.8), pan: (i % 2 ? 0.3 : -0.3), a }));
const pluck = (t: number, midi: number, g = 0.12, pan = 0): Note => ({ t, d: 1.1, f: mtof(midi), g, pan });
const chime = (t: number, midi: number, g = 0.14): Note => ({ t, d: 2.2, f: mtof(midi), g, a: 0.003 });

const tracks: Record<string, () => Float32Array> = {
  // v1 极简白 · 96bpm 明亮克制
  v1: () => {
    const notes: Note[] = [];
    const prog = [[57, 60, 64, 67], [53, 57, 60, 64], [48, 52, 55, 59], [55, 59, 62, 66]]; // Am7 F C G
    for (let bar = 0; bar < 8; bar++) {
      const t0 = bar * 2.5;
      if (t0 >= 21) break;
      notes.push(...pad(t0, 2.7, prog[bar % 4], 0.085));
      const arp = prog[bar % 4];
      for (let k = 0; k < 4; k++) notes.push(pluck(t0 + k * 0.625 + (bar >= 3 ? 0.31 : 0), arp[k % arp.length] + 12, 0.085, k % 2 ? 0.25 : -0.25));
    }
    notes.push(chime(20.3, 84, 0.12), chime(20.45, 88, 0.10), chime(20.6, 91, 0.09));
    const beats = []; for (let t = 8.4; t < 19.6; t += 1.25) beats.push(t);
    const hats = []; for (let t = 9.0; t < 19.6; t += 0.625) hats.push(t);
    return render(notes, 21.5, { kick: beats, hat: hats, fadeOut: 1.1 });
  },
  // v2 暗黑科技 · 低音铺底 + 脉冲
  v2: () => {
    const notes: Note[] = [];
    notes.push(...pad(0, 22.5, [33, 45], 0.11, 2.0));          // A1/A2 drone
    const prog = [[57, 60, 64, 71], [55, 58, 62, 69], [53, 57, 60, 67], [52, 55, 59, 66]];
    for (let bar = 0; bar < 9; bar++) {
      const t0 = bar * 2.5;
      if (t0 >= 22) break;
      notes.push(...pad(t0, 2.6, prog[bar % 4], 0.07, 1.6));
      if (bar >= 3) {
        notes.push(pluck(t0 + 0.4, prog[bar % 4][0] + 12, 0.10, -0.3));
        notes.push(pluck(t0 + 0.58, prog[bar % 4][2] + 12, 0.05, -0.3));
        notes.push(pluck(t0 + 1.6, prog[bar % 4][1] + 12, 0.09, 0.3));
      }
    }
    notes.push(chime(20.5, 81, 0.12), chime(20.7, 88, 0.09));
    const kicks = []; for (let t = 7.4; t < 19.4; t += 1.43) kicks.push(t);
    const hats = []; for (let t = 12.2; t < 18.8; t += 0.357) hats.push(t);
    return render(notes, 22.5, { kick: kicks, hat: hats, boom: [0.1, 19.85], riser: [18.3, 19.7], fadeOut: 1.6 });
  },
  // v3 温暖家庭 · 八音盒
  v3: () => {
    const notes: Note[] = [];
    const prog = [[60, 64, 67, 71], [57, 60, 64, 69], [57, 60, 64, 67], [55, 59, 62, 67]]; // C F Am G
    const mel = [76, 74, 72, 67, 69, 72, 74, 76, 72, 69, 67, 64, 65, 67, 69, 72];
    for (let bar = 0; bar < 9; bar++) {
      const t0 = bar * 2.5;
      if (t0 >= 22.5) break;
      notes.push(...pad(t0, 2.8, prog[bar % 4], 0.075, 1.4));
      for (let k = 0; k < 4; k++) {
        const m = mel[(bar * 4 + k) % mel.length];
        notes.push(pluck(t0 + k * 0.62, m, 0.10, k % 2 ? 0.3 : -0.3));
      }
    }
    notes.push(chime(20.8, 84, 0.13), chime(21.0, 88, 0.11), chime(21.2, 91, 0.09));
    return render(notes, 23, { fadeOut: 1.6 });
  },
  // v4 学生记者 · 120bpm 明快
  v4: () => {
    const notes: Note[] = [];
    const roots = [36, 33, 29, 31]; // C A F G
    const arp = [72, 76, 79, 83, 79, 76];
    for (let bar = 0; bar < 10; bar++) {
      const t0 = bar * 2.0;
      if (t0 >= 18.4) break;
      notes.push(...pad(t0, 2.1, [roots[bar % 4] + 24, roots[bar % 4] + 28 + 12], 0.06, 0.4));
      for (let k = 0; k < 4; k++) notes.push(pluck(t0 + k * 0.25, arp[(bar * 4 + k) % arp.length], 0.075, k % 2 ? 0.3 : -0.3));
    }
    notes.push(chime(16.9, 84, 0.15), chime(17.05, 88, 0.12), chime(17.2, 91, 0.10));
    const kicks = [], hats = [], claps = [];
    for (let t = 2.0; t < 16.5; t += 0.5) { kicks.push(t); hats.push(t + 0.25); if ((Math.round(t * 2) / 2) % 1 === 0.5 || Math.round(t * 2) % 4 === 2) claps.push(t); }
    return render(notes, 18.5, { kick: kicks, hat: hats, clap: claps, fadeOut: 1.2 });
  },
  // v5 发布会 · 电影感（17.5s 紧凑版）
  v5: () => {
    const notes: Note[] = [];
    const prog = [[48, 55, 62, 64, 67], [44, 51, 56, 60, 63], [46, 53, 58, 62, 65], [48, 55, 60, 64, 67]];
    for (let sec = 0; sec < 4; sec++) {
      const t0 = sec * 4.4;
      if (t0 >= 17) break;
      notes.push(...pad(t0, Math.min(4.7, 17.5 - t0), prog[sec % 4], 0.10, 1.4));
      for (let k = 0; k < 4; k++) notes.push(pluck(t0 + 1.0 + k * 0.95, prog[sec % 4][2] + 24, 0.06, k % 2 ? 0.35 : -0.35));
    }
    notes.push(...pad(14.6, 2.9, [48, 60, 64, 67, 72], 0.13, 1.0));
    notes.push(chime(15.6, 84, 0.12), chime(15.85, 91, 0.10));
    return render(notes, 17.5, { boom: [0.1, 2.25, 5.6, 8.2, 10.8, 14.7], riser: [13.5, 15.0], fadeOut: 1.6 });
  },
  // 场景系列（10 条实拍场景宣传片共用，12s 轻快中性）
  scene: () => {
    const notes: Note[] = [];
    const prog = [[57, 60, 64, 67], [53, 57, 60, 64], [48, 52, 55, 59], [55, 59, 62, 66]];
    for (let bar = 0; bar < 5; bar++) {
      const t0 = bar * 2.4;
      if (t0 >= 12) break;
      notes.push(...pad(t0, Math.min(2.6, 12 - t0), prog[bar % 4], 0.08, 0.9));
      const arp = prog[bar % 4];
      for (let k = 0; k < 4; k++) notes.push(pluck(t0 + 0.3 + k * 0.55, arp[k % arp.length] + 12, 0.07, k % 2 ? 0.25 : -0.25));
    }
    notes.push(chime(10.5, 84, 0.12), chime(10.7, 88, 0.09), chime(10.9, 91, 0.08));
    const kicks = [], hats = [];
    for (let t = 2.45; t < 10.3; t += 1.2) kicks.push(t);
    for (let t = 3.05; t < 10.3; t += 0.6) hats.push(t);
    return render(notes, 12, { kick: kicks, hat: hats, fadeOut: 1.3 });
  },
};

mkdirSync("/tmp/rc-promo/music", { recursive: true });
const ids = process.argv[2] ? [process.argv[2]] : Object.keys(tracks);
for (const id of ids) {
  const t0 = Date.now();
  writeFileSync(`/tmp/rc-promo/music/${id}.wav`, wav(tracks[id]()));
  console.log(`music ${id} done in ${((Date.now() - t0) / 1000).toFixed(1)}s`);
}
