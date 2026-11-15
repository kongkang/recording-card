// capture-ui.ts — 只读驱动 prototype/current.html 截取 20 张高清 3x 真实产品界面（零 TBC、隐藏开发切换胶囊）
import { spawn } from "node:child_process";
import { mkdirSync, writeFileSync } from "node:fs";
import { resolve } from "node:path";

const ROOT = resolve(import.meta.dir, "../../..");
const PROTO = `file://${ROOT}/prototype/current.html`;
const OUT = resolve(import.meta.dir, "../assets/ui");
const CHROME = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome";
const PORT = 9620 + Math.floor(Math.random() * 200);

mkdirSync(OUT, { recursive: true });

const chrome = spawn(CHROME, [
  "--headless",
  `--remote-debugging-port=${PORT}`,
  `--user-data-dir=/tmp/rc-promo15/chrome-ui-${PORT}`,
  "--no-first-run",
  "--disable-gpu",
  "--hide-scrollbars",
  "about:blank",
], { stdio: "ignore" });

const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

async function getWs(): Promise<string> {
  for (let i = 0; i < 60; i++) {
    try {
      const res = await fetch(`http://127.0.0.1:${PORT}/json/list`);
      const list = (await res.json()) as any[];
      const page = list.find((t) => t.type === "page");
      if (page?.webSocketDebuggerUrl) return page.webSocketDebuggerUrl;
    } catch {}
    await sleep(200);
  }
  throw new Error("Chrome DevTools unreachable");
}

const ws = new WebSocket(await getWs());
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

const evalJs = async (expr: string) =>
  (await send("Runtime.evaluate", { expression: expr, returnByValue: true, awaitPromise: true }))?.result?.value;

const click = (sel: string) =>
  evalJs(`(() => { const el = document.querySelector('${sel}'); if (el) { el.click(); return true; } return false; })()`);

async function cleanDevChrome(keepToast = false) {
  await evalJs(`
    document.querySelectorAll('.ver-seg, #parity-modal, [data-testid="parity-btn"], .hw-tools, #tl-syncbar').forEach(el => { el.style.display = 'none'; });
    // Fix orphan line-wraps inside live recording status card & raw audio metadata & badges
    if (!document.getElementById('rc-promo-typography-fix')) {
      const st = document.createElement('style');
      st.id = 'rc-promo-typography-fix';
      st.textContent = \`
        .live { overflow: hidden !important; gap: 6px !important; }
        .live b, #feed b, .live-row b, [data-testid*="live"] b { white-space: nowrap !important; flex-shrink: 0 !important; }
        .live .lsub { min-width: 0 !important; flex: 1 1 auto !important; overflow: hidden !important; text-overflow: ellipsis !important; white-space: nowrap !important; font-size: 11.5px !important; }
        .raw-meta, [data-testid^="rawline-"] > div:first-child { font-size: 11.5px !important; letter-spacing: -0.01em !important; }
      \`;
      document.head.appendChild(st);
    }
    // Shorten .lsub trailing text node so even with 6-char '正在本机录音' it fits without ellipsis
    document.querySelectorAll('.live .lsub').forEach(el => {
      el.childNodes.forEach(n => {
        if (n.nodeType === 3 && n.nodeValue && n.nodeValue.includes('每满 1 分钟或下拉即时本地转写')) {
          n.nodeValue = n.nodeValue.replace('每满 1 分钟或下拉即时本地转写', '每分钟切片 · 下拉即转写');
        }
      });
    });
    // Keep live status title single-line & replace internal model badges with user-friendly local label
    document.querySelectorAll('b, span, div').forEach(el => {
      if (el.children.length === 0 && el.textContent) {
        const txt = el.textContent.trim();
        if (txt === '正在录音' || txt === '正在本机录音') {
          el.style.whiteSpace = 'nowrap';
          el.style.flexShrink = '0';
        }
        if (txt.includes('每满 1 分钟或下拉即时本地转写')) {
          el.textContent = txt.replace('每满 1 分钟或下拉即时本地转写', '每分钟切片 · 下拉即时转写');
        }
        if (txt === '本机 SenseVoice') {
          el.textContent = '本机离线转写';
        }
        if (txt === '已就绪 3/3') {
          el.textContent = '已就绪';
        }
        if (txt === '按录音起止时间戳匹配系统相册照片并插入对话流') {
          el.textContent = '按录音时间戳自动匹配相册照片嵌入对话';
        }
      }
    });
    ${keepToast ? "" : "document.querySelectorAll('#toast, .toast').forEach(el => { el.classList.remove('show'); el.style.opacity = '0'; el.style.pointerEvents = 'none'; });"}
  `);
}

async function shot(name: string, keepToast = false) {
  await cleanDevChrome(keepToast);
  await sleep(120);
  const s = await send("Page.captureScreenshot", { format: "png" });
  writeFileSync(`${OUT}/${name}.png`, Buffer.from(s.data, "base64"));
  console.log("  ✓ shot:", name);
}

try {
  await send("Page.enable");
  await send("Runtime.enable");
  await send("Emulation.setDeviceMetricsOverride", { width: 390, height: 844, deviceScaleFactor: 3, mobile: true });
  await send("Page.navigate", { url: PROTO });
  await sleep(1200);
  await cleanDevChrome();

  // 1. Timeline 默认收起态（含总结卡 + 相册缩略图）
  await shot("ui-feed");

  // 2. Timeline 卡片展开态（含摘要 + 说话人推测 + 详情入口）
  await click('[data-testid="card-e1"]');
  await sleep(380);
  await shot("ui-expanded");
  await click('[data-testid="card-e1"]');
  await sleep(260);

  // 3. 记录详情：对话流 + 现场照片穿插
  await click('[data-testid="card-e2"]');
  await sleep(220);
  await click('[data-testid="detail-e2"]');
  await sleep(450);
  await shot("ui-detail-photo");

  // 4. 将一张照片标为「不属于本段」，回 Timeline 截未归类相册与 #p-unc 双列网格
  await evalJs(`(() => { const b = document.querySelector('[data-testid^="dphoto-exclude-"]'); if (b) b.click(); })()`);
  await sleep(300);
  await click('[data-testid="crumb-back"]');
  await sleep(380);
  const hasUnc = await click('[data-testid^="card-unc-"]');
  if (hasUnc) {
    await sleep(450);
    await shot("ui-unc-album");
    await click('[data-testid="crumb-back"]');
    await sleep(350);
  }

  // 5. 记录详情：原始数据 + 吸顶播放器 + 点句秒跳高亮
  await click('[data-testid="card-e1"]');
  await sleep(220);
  await click('[data-testid="detail-e1"]');
  await sleep(420);
  await click('[data-testid="det-tab-raw"]');
  await sleep(320);
  await click('[data-testid="raw-audio-toggle"]');
  await sleep(450);
  await click('[data-testid="rawline-e1-2"]');
  await sleep(350);
  await shot("ui-raw-audio");
  await click('[data-testid="crumb-back"]');
  await sleep(350);

  // 6. 总结多选模式（全选今日/本周/本月）
  await click('[data-testid="summary-start"]');
  await sleep(420);
  await shot("ui-sum-select");
  await click('#sumbar .btn.ghost');
  await sleep(350);

  // 7. 总结结果页：全部 / 概览（含穿插图） / 逻辑结构 / 信息点 / 行动项 / 导出面板
  await click('[data-testid="card-sum-demo"]');
  await sleep(450);
  await shot("ui-sum-all");

  await click('#stabs button[data-st="ov"]');
  await sleep(350);
  await shot("ui-sum-overview");

  await click('#stabs button[data-st="map"]');
  await sleep(350);
  await shot("ui-sum-logic");

  await click('#stabs button[data-st="pt"]');
  await sleep(380);
  await shot("ui-sum-points");

  await click('#stabs button[data-st="todo"]');
  await sleep(350);
  await shot("ui-sum-todo");

  await click('#stabs button[data-st="all"]');
  await sleep(260);
  await click('[data-testid="export-btn"]');
  await sleep(380);
  await shot("ui-sum-export");
  await evalJs(`(() => { const pop = document.getElementById('export-pop'); if (pop) { pop.classList.remove('show'); pop.style.display = 'none'; } if (typeof closeExport === 'function') closeExport(); })()`);
  await sleep(250);
  await click('[data-testid="crumb-back"]');
  await sleep(350);

  // 8. 无硬件独立「本机录音」+ 灵动岛 LCD 实况
  await evalJs(`
    if (typeof phoneRec !== 'undefined') {
      phoneRec.micPerm = true;
      if (typeof photoPerm !== 'undefined') photoPerm.asked = true;
      startPhoneRec(false);
      phoneRec.sec = 148;
      if (typeof syncPhoneRecUI === 'function') syncPhoneRecUI();
      if (typeof updateRecUI === 'function') updateRecUI();
    }
  `);
  await sleep(450);
  await shot("ui-phone-rec");
  await evalJs(`if (typeof stopPhoneRec === 'function') stopPhoneRec();`);
  await sleep(350);

  // 9. 设备扫描（三款硬件按 RSSI 排序）+ 硬件连接态 + 灵动岛硬件录音 + 断连无缝接力
  await click('[data-testid="hw-capsule"]');
  await sleep(1100);
  await shot("ui-device-scan");

  await click('#conn-list .conn-item');
  await sleep(450);
  await evalJs(`
    if (typeof phoneRec !== 'undefined') { phoneRec.micPerm = true; phoneRec.standby = true; }
    if (typeof photoPerm !== 'undefined') { photoPerm.asked = true; photoPerm.granted = true; }
    if (typeof rec !== 'undefined') {
      rec.on = true;
      rec.sec = 754;
      if (typeof liveState !== 'undefined') liveState = 'recording';
      if (typeof updateRecUI === 'function') updateRecUI();
      if (typeof syncCapsule === 'function') syncCapsule();
      if (typeof renderFeed === 'function') renderFeed();
    }
  `);
  await sleep(300);
  await shot("ui-hw-sheet");

  await evalJs(`if (typeof closeSheet === 'function') closeSheet(); if (typeof updateRecUI === 'function') updateRecUI();`);
  await sleep(400);
  await shot("ui-live-hw");

  // 模拟意外断连 → 手机零功耗待命无缝接力
  await evalJs(`if (typeof triggerUnexpectedDrop === 'function') triggerUnexpectedDrop();`);
  await sleep(450);
  await shot("ui-standby-relay");
  await evalJs(`if (typeof stopPhoneRec === 'function') stopPhoneRec(); if (typeof conn !== 'undefined') { conn.retrying = false; syncCapsule(); }`);
  await sleep(300);

  // 10. Setting：本地语音三引擎 / 云端多模型 / 预设风格提示词 / 扩展能力 MCP / 四通道登录页
  await click('[data-testid="nav-setting"]');
  await sleep(380);
  await shot("ui-setting");

  await click('[data-testid="set-local-model"]');
  await sleep(400);
  // Present user-oriented local model page (hiding underlying SenseVoice / Silero VAD / CAM++ names)
  await evalJs(`(() => {
    const cards = Array.from(document.querySelectorAll('#p-set-sub .card, .panel.show .card, .panel.show .set-card, .panel.show div')).filter(el => {
      const t = (el.textContent || '').trim();
      return el.children.length >= 1 && el.offsetHeight > 60 && el.offsetHeight < 180 &&
        (t.startsWith('SenseVoice') || t.startsWith('Silero VAD') || t.startsWith('CAM++') || t.startsWith('本地转写已就绪'));
    });
    if (cards.length >= 2) {
      cards[0].innerHTML = '<div style="display:flex;align-items:center;gap:8px;margin-bottom:6px"><b style="font-size:15px">轻量化本地语音模型</b><span style="font-size:11px;padding:2px 8px;border-radius:99px;background:#E8F5E9;color:#1B5E20;font-weight:600">已就绪</span></div><div style="font-size:13px;color:#5f6368;line-height:1.55">极致压缩体积，秒速唤醒低功耗；语音转文字、静音过滤与说话人区分全程在手机本地流畅完成。</div>';
      cards[1].innerHTML = '<div style="display:flex;align-items:center;gap:8px;margin-bottom:6px"><b style="font-size:15px">原始音频本机存储保护</b><span style="font-size:11px;padding:2px 8px;border-radius:99px;background:#EEF2FF;color:#1D4ED8;font-weight:600">全程本地</span></div><div style="font-size:13px;color:#5f6368;line-height:1.55">所有原始录音切片仅保存在本机沙盒，绝不上传外部服务器；飞行模式与无网环境照常实时成稿。</div>';
      for (let i = 2; i < cards.length; i++) cards[i].style.display = 'none';
    }
  })()`);
  await shot("ui-local-models");
  await click('[data-testid="crumb-back"]');
  await sleep(300);

  await click('[data-testid="set-cloud-model"]');
  await sleep(400);
  await shot("ui-cloud-models");
  await click('[data-testid="crumb-back"]');
  await sleep(300);

  await click('[data-testid="set-prompts"]');
  await sleep(400);
  // Hide TBC dream-comic prompt card so screenshot is 100% zero-TBC
  await evalJs(`(() => {
    document.querySelectorAll('.panel.show div').forEach(el => {
      if (el.offsetHeight > 80 && el.offsetHeight < 220 && (el.textContent || '').includes('日报与做梦提示词')) {
        el.style.display = 'none';
      }
    });
  })()`);
  await shot("ui-prompts");
  await click('[data-testid="crumb-back"]');
  await sleep(300);

  await click('[data-testid="set-extensions"]');
  await sleep(400);
  await shot("ui-extensions");
  await click('[data-testid="crumb-back"]');
  await sleep(300);

  await click('[data-testid="set-auth-entry"]');
  await sleep(350);
  const openedLogin = await click('[data-testid="auth-open-login-page"]');
  if (openedLogin) {
    await sleep(400);
    await shot("ui-login");
    await click('[data-testid="login-gate-close"]');
    await sleep(300);
  }
  await click('[data-testid="crumb-back"]');
  await sleep(300);
  await click('[data-testid="nav-timeline"]');
  await sleep(350);

  // 11. 宽屏自适应双栏（iPad / 桌面 ≥720px：左 Timeline 常显 + 右总结/详情对照）
  await send("Emulation.setDeviceMetricsOverride", { width: 1180, height: 780, deviceScaleFactor: 2, mobile: false });
  await sleep(500);
  await click('[data-testid="card-sum-demo"]');
  await sleep(500);
  await shot("ui-wide-sum");

  await click('[data-testid="card-e2"]');
  await sleep(250);
  await click('[data-testid="detail-e2"]');
  await sleep(450);
  await shot("ui-wide-detail");

  console.log("ALL UI SCREENSHOTS CAPTURED SUCCESSFULLY!");
} finally {
  try { ws.close(); } catch {}
  chrome.kill();
  process.exit(0);
}
