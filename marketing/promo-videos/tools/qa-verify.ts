// qa-verify.ts — 对全部 15 支成片执行 ffprobe 音视频流校验 + 抽帧生成验收联版图（Contact Sheet）
import { spawn } from "node:child_process";
import { existsSync, mkdirSync, readFileSync, statSync } from "node:fs";
import { resolve } from "node:path";

const FFPROBE = process.env.FFPROBE || Bun.which("ffprobe") || "ffprobe";
const FFMPEG = process.env.FFMPEG || Bun.which("ffmpeg") || "ffmpeg";
const SB_PATH = resolve(import.meta.dir, "../storyboard.json");
const OUT_DIR = resolve(import.meta.dir, "../out");
const QA_DIR = "/tmp/rc-promo15/qa";

mkdirSync(QA_DIR, { recursive: true });

function execOut(cmd: string, args: string[]): Promise<{ code: number; out: string; err: string }> {
  return new Promise((res) => {
    const p = spawn(cmd, args, { stdio: ["ignore", "pipe", "pipe"] });
    let out = "", err = "";
    p.stdout.on("data", (d) => (out += d.toString()));
    p.stderr.on("data", (d) => (err += d.toString()));
    p.on("close", (c) => res({ code: c ?? 1, out, err }));
  });
}

const sb = JSON.parse(readFileSync(SB_PATH, "utf-8"));
let allPass = true;

console.log(`=== Post-Render Technical & Visual QA across ${sb.videos.length} MP4s ===`);
for (const v of sb.videos) {
  const mp4 = `${OUT_DIR}/${v.slug}.mp4`;
  if (!existsSync(mp4)) {
    console.error(`  ✗ MISSING: ${mp4}`);
    allPass = false;
    continue;
  }
  const sizeMB = (statSync(mp4).size / (1024 * 1024)).toFixed(2);
  const pr = await execOut(FFPROBE, [
    "-v", "error",
    "-show_entries", "stream=codec_type,codec_name,width,height,r_frame_rate,sample_rate,channels:format=duration",
    "-of", "json",
    mp4,
  ]);
  const info = JSON.parse(pr.out);
  const vStream = info.streams?.find((s: any) => s.codec_type === "video");
  const aStream = info.streams?.find((s: any) => s.codec_type === "audio");
  const dur = Number(info.format?.duration ?? 0);

  const okW = vStream?.width === v.width && vStream?.height === v.height;
  const okCodec = vStream?.codec_name === "h264" && aStream?.codec_name === "aac";
  const okDur = Math.abs(dur - v.durationSec) < 0.6;

  if (!okW || !okCodec || !okDur) {
    console.error(`  ✗ FAIL [${v.num}] ${v.slug}: ${JSON.stringify({ vStream, aStream, dur, expected: v.durationSec })}`);
    allPass = false;
  } else {
    console.log(
      `  ✓ PASS [${v.num}] ${v.slug}.mp4 | ${vStream.width}x${vStream.height} @ ${vStream.r_frame_rate} | ${vStream.codec_name}+${aStream.codec_name} | ${dur.toFixed(2)}s | ${sizeMB} MB`
    );
  }
}

// Generate 5-act contact sheets for visual spot-check on representative widescreen & vertical MP4s
for (const slug of ["01-exec-keynote", "05-student-exam", "08-sales-field", "13-three-hardware", "15-flagship-allinone"]) {
  const mp4 = `${OUT_DIR}/${slug}.mp4`;
  if (!existsSync(mp4)) continue;
  const sheet = `${QA_DIR}/sheet-${slug}.jpg`;
  await execOut(FFMPEG, [
    "-y",
    "-i", mp4,
    "-vf", "fps=1/6,scale=480:-1,tile=5x2",
    "-frames:v", "1",
    "-q:v", "3",
    sheet,
  ]);
}

if (!allPass) {
  process.exit(1);
}
console.log(`=== ALL ${sb.videos.length} PROMO VIDEOS PASSED TECHNICAL & STREAM QA! ===`);
