// build-gallery.ts — 生成零外部依赖、支持 file:// 直接打开的 15 支宣传片交互展映墙 index.html
import { readFileSync, writeFileSync } from "node:fs";
import { resolve } from "node:path";

const sb = JSON.parse(readFileSync(resolve(import.meta.dir, "../storyboard.json"), "utf-8"));
const videos = sb.videos;

const compact = videos.map((v: any) => ({
  id: v.id,
  num: v.num,
  slug: v.slug,
  title: v.title,
  persona: v.persona,
  channel: v.channel,
  aspect: v.aspect,
  category: v.category || (v.engine === "live-cinema" ? "live-action" : "motion-design"),
  width: v.width,
  height: v.height,
  durationSec: v.durationSec,
  styleName: v.styleName,
  engine: v.engine,
  palette: v.palette,
  voice: v.voice,
  music: v.music,
  ctaButton: v.ctaButton,
  ctaSub: v.ctaSub,
  socialCopy: v.socialCopy,
  scenes: v.scenes.map((s: any) => ({
    act: s.act,
    startSec: s.startSec,
    endSec: s.endSec,
    vo: s.vo,
    headline: s.headline.filter(Boolean).join(" / "),
  })),
}));

const html = `<!doctype html>
<html lang="zh-CN">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>录音卡 · 15 支跨风格跨人群高转化宣传片矩阵</title>
<style>
  :root {
    --bg: #090b10;
    --panel: #121621;
    --panel-2: #181e2c;
    --border: rgba(255,255,255,0.10);
    --ink: #f8fafc;
    --sub: #94a3b8;
    --accent: #3b82f6;
    --gold: #e5b869;
  }
  * { box-sizing: border-box; }
  body {
    margin: 0;
    font-family: "PingFang SC", -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
    background: radial-gradient(circle at 50% -10%, rgba(59,130,246,0.18), transparent 45%), var(--bg);
    color: var(--ink);
    padding-bottom: 72px;
  }
  header {
    max-width: 1380px;
    margin: 0 auto;
    padding: 44px 28px 24px;
  }
  .eyebrow {
    display: inline-flex;
    align-items: center;
    gap: 8px;
    font-size: 12px;
    font-weight: 700;
    letter-spacing: 0.08em;
    text-transform: uppercase;
    color: var(--gold);
    background: rgba(229,184,105,0.12);
    border: 1px solid rgba(229,184,105,0.32);
    padding: 6px 14px;
    border-radius: 999px;
  }
  h1 {
    font-size: clamp(28px, 3.6vw, 44px);
    margin: 16px 0 10px;
    letter-spacing: -0.02em;
  }
  .lead {
    color: var(--sub);
    font-size: 16px;
    line-height: 1.65;
    max-width: 920px;
    margin: 0 0 26px;
  }
  .toolbar {
    display: flex;
    flex-wrap: wrap;
    gap: 10px;
    align-items: center;
    justify-content: space-between;
    padding: 14px 18px;
    background: rgba(18,22,33,0.85);
    backdrop-filter: blur(16px);
    border: 1px solid var(--border);
    border-radius: 16px;
    position: sticky;
    top: 14px;
    z-index: 30;
  }
  .tabs {
    display: flex;
    flex-wrap: wrap;
    gap: 8px;
  }
  .tab {
    border: 1px solid var(--border);
    background: transparent;
    color: var(--sub);
    padding: 8px 16px;
    border-radius: 999px;
    font-size: 14px;
    font-weight: 600;
    cursor: pointer;
    transition: all .18s ease;
  }
  .tab:hover { color: var(--ink); border-color: rgba(255,255,255,0.25); }
  .tab.active {
    background: var(--ink);
    color: #090b10;
    border-color: var(--ink);
  }
  .stats {
    font-size: 13px;
    color: var(--sub);
  }
  .grid {
    max-width: 1380px;
    margin: 24px auto 0;
    padding: 0 28px;
    display: grid;
    grid-template-columns: repeat(auto-fill, minmax(390px, 1fr));
    gap: 22px;
  }
  .card {
    background: var(--panel);
    border: 1px solid var(--border);
    border-radius: 20px;
    overflow: hidden;
    display: flex;
    flex-direction: column;
    transition: transform .2s ease, border-color .2s ease;
  }
  .card:hover {
    transform: translateY(-3px);
    border-color: rgba(255,255,255,0.24);
  }
  .stage {
    position: relative;
    background: #040609;
    display: flex;
    align-items: center;
    justify-content: center;
    aspect-ratio: 16 / 9;
    border-bottom: 1px solid var(--border);
    overflow: hidden;
  }
  .stage video {
    width: 100%;
    height: 100%;
    object-fit: contain;
    background: #000;
  }
  .badge-row {
    display: flex;
    align-items: center;
    justify-content: space-between;
    gap: 8px;
    margin-bottom: 10px;
  }
  .num-pill {
    display: inline-flex;
    align-items: center;
    gap: 6px;
    font-size: 12px;
    font-weight: 700;
    padding: 4px 10px;
    border-radius: 999px;
    background: rgba(255,255,255,0.07);
  }
  .aspect-pill {
    font-size: 11px;
    font-family: ui-monospace, SFMono-Regular, Menlo, monospace;
    padding: 3px 9px;
    border-radius: 6px;
    border: 1px solid var(--border);
    color: var(--sub);
  }
  .body {
    padding: 18px 20px 20px;
    display: flex;
    flex-direction: column;
    flex: 1;
  }
  .title {
    font-size: 20px;
    font-weight: 800;
    margin: 0 0 6px;
  }
  .persona {
    font-size: 13.5px;
    color: #cbd5e1;
    margin-bottom: 4px;
  }
  .meta {
    font-size: 12.5px;
    color: var(--sub);
    margin-bottom: 14px;
  }
  .copy-box {
    background: var(--panel-2);
    border: 1px solid rgba(255,255,255,0.07);
    border-radius: 12px;
    padding: 11px 13px;
    font-size: 13px;
    line-height: 1.55;
    color: #e2e8f0;
    margin-bottom: 14px;
  }
  details {
    margin-bottom: 14px;
    border: 1px solid rgba(255,255,255,0.07);
    border-radius: 10px;
    padding: 8px 12px;
    background: rgba(255,255,255,0.02);
  }
  summary {
    cursor: pointer;
    font-size: 12.5px;
    font-weight: 600;
    color: var(--sub);
  }
  .script-list {
    margin: 10px 0 2px;
    padding-left: 16px;
    font-size: 12.5px;
    color: #cbd5e1;
    line-height: 1.6;
  }
  .actions {
    margin-top: auto;
    display: flex;
    gap: 10px;
  }
  .btn {
    flex: 1;
    display: inline-flex;
    align-items: center;
    justify-content: center;
    gap: 6px;
    padding: 9px 12px;
    border-radius: 10px;
    font-size: 13px;
    font-weight: 700;
    text-decoration: none;
    cursor: pointer;
    border: 1px solid var(--border);
    background: rgba(255,255,255,0.05);
    color: var(--ink);
    transition: background .15s ease;
  }
  .btn:hover { background: rgba(255,255,255,0.12); }
  .btn.primary {
    background: var(--accent);
    border-color: var(--accent);
    color: #fff;
  }
  .btn.primary:hover { filter: brightness(1.08); }
  #toast {
    position: fixed;
    bottom: 24px;
    left: 50%;
    transform: translateX(-50%) translateY(20px);
    background: #10b981;
    color: #04130d;
    font-weight: 700;
    font-size: 13.5px;
    padding: 10px 20px;
    border-radius: 999px;
    opacity: 0;
    pointer-events: none;
    transition: all .22s ease;
    z-index: 99;
  }
  #toast.show {
    opacity: 1;
    transform: translateX(-50%) translateY(0);
  }
</style>
</head>
<body>
<header>
  <span class="eyebrow">Recording Card · 20 Promo Videos Matrix (15 Motion + 5 Live-Action)</span>
  <h1>录音卡 · 20 支全矩阵宣传片展映墙（含 5 支真人实景大片）</h1>
  <p class="lead">
    涵盖 <strong>5 支 35mm 真人实景电影感商业大片（#16–#20）</strong> 与 <strong>15 支跨风格跨人群高转化动效宣传片（#01–#15）</strong>，覆盖 <strong>12 支 16:9 横屏大片</strong> 与 <strong>8 支 9:16 竖屏信息流爆款</strong>。全片采用真人感神经网络配音、独立编曲 BGM、自动闪避混音与零 TBC 真实产品界面实拍，聚焦轻量化本地模型与原始音频留存本机体验。
  </p>
  <div class="toolbar">
    <div class="tabs">
      <button class="tab active" data-filter="all">全部成片 (20)</button>
      <button class="tab" data-filter="live-action">🎬 真人实景大片 (5)</button>
      <button class="tab" data-filter="motion-design">✨ 风格动效大片 (15)</button>
      <button class="tab" data-filter="16:9">16:9 横屏 (12)</button>
      <button class="tab" data-filter="9:16">9:16 竖屏 (8)</button>
    </div>
    <div class="stats">编码规格：1080p @ 30fps · H.264 High + AAC 192kbps · 真人实景 + 真实界面实拍</div>
  </div>
</header>

<main class="grid" id="grid"></main>
<div id="toast">已复制社交媒体投放文案</div>

<script>
const VIDEOS = ${JSON.stringify(compact)};
const grid = document.getElementById('grid');
const toast = document.getElementById('toast');

function showToast(msg) {
  toast.textContent = msg;
  toast.classList.add('show');
  setTimeout(() => toast.classList.remove('show'), 1800);
}

function renderGrid(filter) {
  const list = filter === 'all'
    ? VIDEOS
    : (filter === 'live-action' || filter === 'motion-design')
      ? VIDEOS.filter(v => v.category === filter)
      : VIDEOS.filter(v => v.aspect === filter);
  grid.innerHTML = list.map(v => \`
    <article class="card" style="\${v.category === 'live-action' ? 'border-color: rgba(229,184,105,0.38);' : ''}">
      <div class="stage">
        <video controls preload="metadata" playsinline src="./out/\${v.slug}.mp4#t=0.6"></video>
      </div>
      <div class="body">
        <div class="badge-row">
          <span class="num-pill" style="\${v.category === 'live-action' ? 'background: rgba(229,184,105,0.18); color: #fde68a;' : ''}">
            <span style="width:9px;height:9px;border-radius:50%;background:\${v.palette.accent};display:inline-block"></span>
            #\${v.num} · \${v.category === 'live-action' ? '🎬 真人实景 · ' : ''}\${v.styleName.split('·')[1] ? v.styleName.split('·')[1].trim() : v.styleName}
          </span>
          <span class="aspect-pill">\${v.aspect} · \${v.width}×\${v.height} · \${v.durationSec.toFixed(1)}s</span>
        </div>
        <h2 class="title">\${v.title}</h2>
        <div class="persona">🎯 人群：\${v.persona}</div>
        <div class="meta">📺 渠道：\${v.channel} · 🎙️ \${v.voice.roleDesc} (\${v.music.bpm} BPM)</div>
        <div class="copy-box">\${v.socialCopy}</div>
        <details>
          <summary>查看 5 幕分镜台词与时间轴</summary>
          <ol class="script-list">
            \${v.scenes.map(s => \`<li><strong>[\${s.startSec.toFixed(1)}s–\${s.endSec.toFixed(1)}s · \${s.act.toUpperCase()}]</strong> \${s.vo}</li>\`).join('')}
          </ol>
        </details>
        <div class="actions">
          <button class="btn" onclick="copyCopy('\${v.id}')">📋 复制投放文案</button>
          <a class="btn primary" href="./out/\${v.slug}.mp4" download="\${v.slug}.mp4">⬇ 下载 MP4</a>
        </div>
      </div>
    </article>
  \`).join('');

  // Pause other videos when one starts playing
  const vids = grid.querySelectorAll('video');
  vids.forEach(el => {
    el.addEventListener('play', () => {
      vids.forEach(other => { if (other !== el && !other.paused) other.pause(); });
    });
  });
}

window.copyCopy = function(id) {
  const v = VIDEOS.find(x => x.id === id);
  if (!v) return;
  navigator.clipboard.writeText(v.socialCopy).then(() => showToast('已复制 #' + v.num + ' 投放文案！'));
};

document.querySelectorAll('.tab').forEach(btn => {
  btn.addEventListener('click', () => {
    document.querySelectorAll('.tab').forEach(b => b.classList.remove('active'));
    btn.classList.add('active');
    renderGrid(btn.dataset.filter);
  });
});

renderGrid('all');
</script>
</body>
</html>`;

const outHtml = resolve(import.meta.dir, "../index.html");
writeFileSync(outHtml, html);
console.log("Gallery written to", outHtml);
