#!/usr/bin/env node
import assert from 'node:assert/strict';
import fs from 'node:fs';
import http from 'node:http';
import path from 'node:path';
import { createRequire } from 'node:module';
import { fileURLToPath } from 'node:url';

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
const repoRoot = path.resolve(__dirname, '../..');
const htmlPath = path.join(__dirname, 'index.html');
const html = fs.readFileSync(htmlPath, 'utf8');

const results = [];
let failures = 0;

function check(name, pass, detail = '') {
  results.push({ name, pass, detail });
  if (!pass) {
    failures++;
    console.error(`FAIL: ${name}${detail ? ` — ${detail}` : ''}`);
  } else {
    console.log(`PASS: ${name}`);
  }
}

// 1. Self-contained single-file / zero external HTTP dependencies
check(
  'No external <script src=...>',
  !/<script\b[^>]*\bsrc\s*=/i.test(html),
  'Found external <script src=...>'
);
check(
  'No external <link href="http...">',
  !/<link\b[^>]*\bhref\s*=\s*["']https?:/i.test(html),
  'Found external HTTP <link>'
);
check(
  'No external <img src="http...">',
  !/<img\b[^>]*\bsrc\s*=\s*["']https?:/i.test(html),
  'Found external HTTP <img>'
);
check(
  'No external CSS @import url(http...)',
  !/@import\s+url\(\s*["']?https?:/i.test(html),
  'Found external CSS @import'
);

// 2. Directly references confirmed phone dual-version source-of-truth prototypes
const phoneCurPath = path.join(repoRoot, 'prototype', 'current.html');
const phoneTargetPath = path.join(repoRoot, 'prototype', 'index.html');
check('Phone current.html source-of-truth exists', fs.existsSync(phoneCurPath), phoneCurPath);
check('Phone target index.html source-of-truth exists', fs.existsSync(phoneTargetPath), phoneTargetPath);
check(
  'Watch prototype embeds ../../prototype/current.html and ../../prototype/index.html',
  html.includes('../../prototype/current.html') && html.includes('../../prototype/index.html')
);

// 3. Inline <script> compiles without syntax errors
const scriptMatches = [
  ...html.matchAll(
    /<script\b(?![^>]*\btype\s*=\s*["']application\/json["'])[^>]*>([\s\S]*?)<\/script>/gi
  ),
];
check('Has inline <script> block', scriptMatches.length >= 1, `Found ${scriptMatches.length}`);

scriptMatches.forEach((m, idx) => {
  let compiled = false;
  let errMsg = '';
  try {
    new Function(m[1]);
    compiled = true;
  } catch (err) {
    errMsg = err && err.message ? err.message : String(err);
  }
  check(`Inline script #${idx + 1} compiles cleanly`, compiled, errMsg);
});

// 4. Design tokens, isolated storage key, and redline wording checks
check('Contains design token --bg:#FAFAF8', /--bg:\s*#FAFAF8\b/i.test(html));
check('Contains bottom padding token --page-pad-b:48px', /--page-pad-b:\s*48px\b/i.test(html));
check('Contains isolated storage key rc-watch-proto-v2', html.includes('rc-watch-proto-v2'));
check('Contains zero forbidden redline words (模拟/演示/已充满)', !/(模拟|演示|已充满)/.test(html));

// 4b. 2026-11-15 watch recording UI redesign: watch-face style, one-screen, anti-mistouch stop, NC markers
check('Watch screen drops keep-alive wording (运动保活)', !html.includes('运动保活'));
check(
  'Watch app top bar shows conn status & battery, not app title',
  html.includes('data-testid="watch-conn-status"') &&
    html.includes('data-testid="watch-batt-pill"') &&
    !html.includes('id="w-nav-title"')
);
check(
  'Watch hero area with watch-face clock / rec duration variants',
  html.includes('data-testid="watch-hero"') && html.includes('w-bigclock') && html.includes('w-bighero')
);
check('Watch recording hero shows remaining recordable time (还可录)', html.includes('还可录'));
check(
  'Watch mark gesture is non-button double-knock on body (轻敲两下机身打点)',
  html.includes('轻敲两下机身打点') && !html.includes('watch-mark-btn') && !html.includes('双击打重点')
);
check(
  'Watch slide-to-stop strip with wake-first hint (先点亮屏幕)',
  html.includes('watch-stop-slider') && html.includes('先点亮屏幕')
);
check(
  'Watch bottom bar shows single-lap 60s countdown + slice sync state (单圈 / 已同步 / 待传)',
  html.includes('单圈 60s') && html.includes('已同步') && html.includes('待传')
);
check('Watch bottom bar does NOT embed GPS·心率 / w-signal-nc clutter', !html.includes('w-signal-nc') && !html.includes('GPS·心率'));

const phoneCurHtml = fs.readFileSync(phoneCurPath, 'utf8');
const phoneTargetHtml = fs.readFileSync(phoneTargetPath, 'utf8');
check(
  'Phone current.html carries health & location Setting row',
  phoneCurHtml.includes('set-health-location') && phoneCurHtml.includes('行为与健康信号')
);
check(
  'Phone current.html has NT pill (nt-btn) and graduated health out of NC',
  phoneCurHtml.includes('data-testid="nt-btn"') && !phoneCurHtml.includes('nc-item-health')
);
check('Phone target index.html synced with health Setting block', phoneTargetHtml.includes('set-health-location'));

// 5. Required data-testid anchors on host & Watch UI (WatchMainView + RecordingCardComplication)
const staticTestIds = [
  'phone-version-seg',
  'view-mode-seg',
  'tb-toggle-reach',
  'tb-unexpected-drop',
  'tb-cut-slice',
  'tb-knock-mark',
  'proto-reset',
  'phone-dyn-island',
  'ios-live-activity-card',
  'phone-frame',
  'watch-screen-tabs',
  'watch-aod-toggle',
  'watch-conn-status',
  'watch-batt-pill',
  'watch-hero',
  'watch-stop-slider',
  'watch-stop-knob',
  'watch-slice-lap',
  'comp-corner',
  'comp-circular',
  'comp-rectangular',
  'comp-inline',
  'watch-record-toggle',
  'watch-queue-entry',
  'watch-queue-back',
  'watch-flush-btn',
];

for (const id of staticTestIds) {
  const re = new RegExp(`data-testid=["']${id}["']`);
  check(`Contains static data-testid="${id}"`, re.test(html));
}

// 6. No duplicate static HTML id attributes outside <script>/<style>
const markupOnly = html
  .replace(/<script\b[^>]*>[\s\S]*?<\/script>/gi, '')
  .replace(/<style\b[^>]*>[\s\S]*?<\/style>/gi, '');
const idCounts = new Map();
for (const m of markupOnly.matchAll(/\bid\s*=\s*["']([^"']+)["']/g)) {
  idCounts.set(m[1], (idCounts.get(m[1]) || 0) + 1);
}
const dupIds = [...idCounts.entries()]
  .filter(([, c]) => c > 1)
  .map(([id, c]) => `${id}(${c})`);
check('No duplicate static id attributes in HTML', dupIds.length === 0, dupIds.join(', '));

// 7. Headless Chromium E2E verification over ephemeral local HTTP (same-origin iframe scripting)
function resolvePuppeteer() {
  if (process.env.WATCH_PROTO_STATIC_ONLY === '1') return null;
  const require = createRequire(import.meta.url);
  for (const mod of ['puppeteer-core', 'puppeteer', '/tmp/node_modules/puppeteer-core']) {
    try {
      return require(mod);
    } catch {
      // try next candidate
    }
  }
  return null;
}

const chromePath = [
  process.env.CHROME_PATH,
  '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome',
  '/usr/bin/google-chrome',
  '/usr/bin/chromium',
].filter(Boolean).find((p) => fs.existsSync(p));

const pp = resolvePuppeteer();

function startStaticServer(rootDir) {
  const mime = {
    '.html': 'text/html; charset=utf-8',
    '.js': 'text/javascript; charset=utf-8',
    '.mjs': 'text/javascript; charset=utf-8',
    '.css': 'text/css; charset=utf-8',
    '.svg': 'image/svg+xml',
    '.png': 'image/png',
    '.json': 'application/json; charset=utf-8',
  };
  const server = http.createServer((req, res) => {
    const reqPath = decodeURIComponent((req.url || '/').split('?')[0]);
    const safeRel = path.normalize(reqPath).replace(/^(\.\.(\/|\\|$))+/, '');
    let filePath = path.join(rootDir, safeRel === '/' ? 'index.html' : safeRel);
    if (!filePath.startsWith(rootDir)) {
      res.writeHead(403);
      res.end('Forbidden');
      return;
    }
    if (fs.existsSync(filePath) && fs.statSync(filePath).isDirectory()) {
      filePath = path.join(filePath, 'index.html');
    }
    if (!fs.existsSync(filePath)) {
      res.writeHead(404);
      res.end('Not found');
      return;
    }
    const ext = path.extname(filePath).toLowerCase();
    res.writeHead(200, { 'Content-Type': mime[ext] || 'application/octet-stream' });
    fs.createReadStream(filePath).pipe(res);
  });
  return new Promise((resolve) => {
    server.listen(0, '127.0.0.1', () => {
      const addr = server.address();
      resolve({ server, baseUrl: `http://127.0.0.1:${addr.port}` });
    });
  });
}

async function getPhoneFrame(page) {
  const handle = await page.$('[data-testid="phone-frame"]');
  assert(handle, 'Missing #phone-frame');
  const frame = await handle.contentFrame();
  assert(frame, 'Unable to access #phone-frame contentFrame');
  return frame;
}

if (pp && chromePath) {
  const { server, baseUrl } = await startStaticServer(repoRoot);
  let browser;
  try {
    browser = await pp.launch({
      executablePath: chromePath,
      headless: true,
      args: ['--no-sandbox', '--disable-gpu'],
    });
    const page = await browser.newPage();
    await page.setViewport({ width: 1280, height: 960, deviceScaleFactor: 2 });

    const pageErrors = [];
    const netReqs = [];
    page.on('pageerror', (e) => pageErrors.push(e.message));
    page.on('request', (req) => {
      const u = req.url();
      if (!u.startsWith(baseUrl) && !u.startsWith('data:') && !u.startsWith('about:')) {
        netReqs.push(u);
      }
    });

    await page.goto(`${baseUrl}/watch/prototype/index.html`, { waitUntil: 'load' });
    await page.waitForFunction(() => !!window.bridgeBoundWin);

    let pf = await getPhoneFrame(page);

    // Clear storage & wait clean reload
    await Promise.all([
      page.waitForFunction(() => {
        const fr = document.getElementById('phone-frame');
        return fr && window.bridgeBoundWin === fr.contentWindow;
      }),
      page.evaluate(() => resetPrototype()),
    ]);
    pf = await getPhoneFrame(page);

    // Baseline redline, Watch battery tier wording & overflow check
    const bodyText = await page.evaluate(() => document.body.innerText);
    const phoneText = await pf.evaluate(() => document.body.innerText);
    check(
      'E2E: Outer & inner rendered DOM omit forbidden words',
      !/模拟|演示|未接云端|已充满/.test(bodyText + phoneText)
    );
    check(
      'E2E: Watch battery pill & rectangular slot omit %',
      await page.evaluate(() => {
        const b = document.getElementById('w-batt-pill')?.innerText || '';
        const r = document.getElementById('comp-rect-sub')?.innerText || '';
        return !b.includes('%') && !r.includes('%') && !b.includes('已充满');
      })
    );
    check(
      'E2E: Zero horizontal overflow at 1280x960',
      await page.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth)
    );

    // Flow 1: Version switch 当前版 <-> 目标版·11 inside shared phone iframe
    assert.equal(await pf.$eval('[data-testid="parity-btn"]', (el) => el.innerText.trim()), '当前版', 'Current version parity-btn must say 当前版');
    assert.equal(await pf.$$eval('.tbc-badge', (els) => els.length), 0, 'Current version must have zero TBC badges');
    await Promise.all([
      page.waitForFunction(() => S.phoneVersion === 'target' && window.bridgeBoundWin === document.getElementById('phone-frame').contentWindow),
      page.click('[data-testid="phone-version-seg"] button[data-pver="target"]'),
    ]);
    pf = await getPhoneFrame(page);
    assert.equal(await pf.$eval('[data-testid="parity-btn"]', (el) => el.innerText.trim()), '目标版·11', 'Target version parity-btn must say 目标版·11');
    assert((await pf.$$eval('.tbc-badge', (els) => els.length)) > 0, 'Target version must contain TBC badges');

    await Promise.all([
      page.waitForFunction(() => S.phoneVersion === 'current' && window.bridgeBoundWin === document.getElementById('phone-frame').contentWindow),
      page.click('[data-testid="phone-version-seg"] button[data-pver="current"]'),
    ]);
    pf = await getPhoneFrame(page);
    assert.equal(await pf.$eval('[data-testid="parity-btn"]', (el) => el.innerText.trim()), '当前版');
    check('E2E: Dual-version switch (当前版 <-> 目标版·11) syncs real phone iframe', true);

    // Flow 2: Real Setting -> Apple Watch link -> 4-device scan -> capability gating
    await pf.click('[data-testid="hw-capsule"]');
    await pf.waitForSelector('#conn-list .conn-item');
    assert.equal(await pf.$$eval('#conn-list .conn-item', (els) => els.length), 3);
    check('E2E: Default scan hides Watch and keeps 3 hardware devices', true);

    await pf.evaluate(() => closeSheet());
    await pf.click('[data-testid="nav-setting"]');
    assert.equal(await pf.$eval('#sv-watch', (el) => el.innerText.trim()), '未开启');
    await pf.click('[data-testid="set-apple-watch"]');
    assert(await pf.$('[data-testid="watch-link-status-card"]'));
    assert(await pf.$('[data-testid="watch-complication-guide"]'));
    assert(
      await pf.$eval(
        '[data-testid="watch-link-status-card"]',
        (el) => !el.innerText.includes('%') && !el.innerText.includes('已充满')
      )
    );
    await pf.click('[data-testid="watch-link-switch"]');
    await pf.click('[data-testid="crumb-back"]');
    assert.equal(await pf.$eval('#sv-watch', (el) => el.innerText.trim()), '已配对');

    await pf.click('[data-testid="hw-capsule"]');
    await pf.waitForSelector('[data-testid="dev-item-APPLE_WATCH_S10"]');
    assert.equal(await pf.$$eval('#conn-list .conn-item', (els) => els.length), 4);
    await pf.click('[data-testid="dev-item-APPLE_WATCH_S10"]');
    await pf.waitForFunction(() => conn.connected && conn.curDev && conn.curDev.kind === 'watch');

    assert.equal(await pf.$eval('#dev-kind-badge', (el) => el.innerText.trim()), 'Apple Watch');
    const subTxt = await pf.$eval('#dev-sub-txt', (el) => el.innerText.trim());
    assert(subTxt.includes('watchOS 11.1 · 本地直连'), `Unexpected dev-sub-txt: ${subTxt}`);
    assert.equal(await pf.$eval('#row-sync', (el) => !el.hidden), true);
    assert.equal(await pf.$eval('#row-wifi', (el) => el.hidden), true);
    assert.equal(await pf.$eval('#row-fw', (el) => el.hidden), true);
    assert.equal(await pf.$('#dev-main [data-testid="phone-rec-row"]'), null);
    assert(
      await pf.$eval(
        '#row-batt',
        (el) => !el.innerText.includes('%') && !el.innerText.includes('已充满')
      )
    );
    check('E2E: Watch link enables 4-device scan and gates Watch capabilities in real Phone', true);
    await pf.evaluate(() => closeSheet());
    await pf.click('[data-testid="nav-timeline"]');

    // Flow 3: Watch Complication -> Live Activity -> Timeline Live -> Slice Ingestion -> Detail WAV play/delete
    await page.click('[data-testid="watch-screen-tabs"] button[data-wtab="face"]');
    check(
      'E2E: Watch Face hides duplicate app status bar and fits cleanly inside dial',
      await page.evaluate(() => {
        const tb = document.getElementById('w-top-bar');
        const s = document.getElementById('watch-screen');
        return !!tb && tb.hidden && s.scrollHeight <= s.clientHeight && s.scrollWidth <= s.clientWidth;
      })
    );
    await page.click('[data-testid="comp-corner"]');
    assert.equal(await page.evaluate(() => S.watchRec && S.watchTab === 'app'), true);
    assert.equal(
      await page.$eval('[data-testid="watch-record-toggle"]', (el) => el.hidden),
      true,
      'Start button must hide while recording'
    );
    assert.equal(
      await page.$eval('[data-testid="watch-stop-slider"]', (el) => !el.hidden),
      true,
      'Slide-to-stop strip must show while recording'
    );
    assert.equal(await page.$('[data-testid="watch-mark-btn"]'), null, 'Knock-twice mark must NOT be a screen button');
    assert.equal(await page.$('#w-signal-nc'), null, 'Watch bottom bar must not show GPS·心率');

    // Watch recording UI: conn/battery top bar, hero duration + remaining, flat knob, one-screen fit, bottom single-lap countdown
    check(
      'E2E: Watch top bar shows conn status & battery, no app title',
      await page.evaluate(() => {
        const conn = document.getElementById('w-conn-status');
        const batt = document.getElementById('w-batt-pill');
        return (
          !!conn &&
          conn.innerText.includes('已连手机') &&
          !conn.innerText.includes('录音卡') &&
          !!batt &&
          batt.innerText.includes('电量高') &&
          !batt.innerText.includes('%')
        );
      })
    );
    check(
      'E2E: Watch hero shows rec duration + remaining + non-button knock hint, zero keep-alive wording',
      await page.evaluate(() => {
        const hero = document.getElementById('w-hero');
        const hint = document.querySelector('[data-testid="watch-knock-hint"]');
        const screenTxt = document.getElementById('watch-screen').innerText;
        return (
          !!hero &&
          hero.innerText.includes('录音中') &&
          hero.innerText.includes('还可录') &&
          !!hint &&
          hint.tagName !== 'BUTTON' &&
          !screenTxt.includes('运动保活')
        );
      })
    );
    check(
      'E2E: Stop knob is flat matte solid color (no metallic gradient)',
      await page.evaluate(() => {
        const cs = getComputedStyle(document.getElementById('w-stop-knob'));
        return cs.backgroundImage === 'none';
      })
    );
    check(
      'E2E: Watch screen fits one screen (no overflow while recording)',
      await page.evaluate(() => {
        const s = document.getElementById('watch-screen');
        return s.scrollHeight <= s.clientHeight && s.scrollWidth <= s.clientWidth;
      })
    );
    check(
      'E2E: Single-lap 60s countdown pinned to watch bottom with flat slide-to-stop flush above',
      await page.evaluate(() => {
        const sRect = document.getElementById('watch-screen').getBoundingClientRect();
        const stop = document.getElementById('w-stop-slider').getBoundingClientRect();
        const q = document.getElementById('w-queue-entry').getBoundingClientRect();
        const lap = document.querySelector('[data-testid="watch-slice-lap"]');
        return (
          !!lap &&
          lap.innerText.includes('单圈') &&
          sRect.bottom - q.bottom <= 18 &&
          q.top - stop.bottom >= 0 &&
          q.top - stop.bottom <= 12
        );
      })
    );
    await page.click('[data-testid="watch-hero"]');
    await page.click('[data-testid="watch-hero"]');
    assert.equal(await page.evaluate(() => S.curMarks), 1, 'Double-knocking watch dial should increment curMarks');
    assert(
      await page.$eval('[data-testid="watch-mark-count"]', (el) => el.innerText.includes('已打点 1')),
      'Watch dial should show mark pill after knocking twice'
    );
    await page.click('[data-testid="tb-knock-mark"]');
    assert.equal(await page.evaluate(() => S.curMarks), 2, 'Toolbar knock helper should increment curMarks');

    assert(
      await page.$eval('[data-testid="phone-dyn-island"]', (el) => el.classList.contains('show'))
    );
    await page.click('[data-testid="phone-dyn-island"]');
    assert(
      await page.$eval(
        '[data-testid="ios-live-activity-card"]',
        (el) => !el.hidden && el.innerText.includes('Apple Watch · 蓝牙录音中')
      )
    );
    await pf.waitForSelector('#live-status');
    assert(await pf.$eval('#live-status', (el) => el.innerText.includes('正在录音')));

    await page.click('[data-testid="tb-cut-slice"]');
    const sliceCardSel = '[data-testid="card-watch-slice-1"]';
    await pf.waitForSelector(sliceCardSel);
    await pf.click(sliceCardSel);
    await pf.click('[data-testid="detail-watch-slice-1"]');
    await pf.click('[data-testid="det-tab-raw"]');
    await pf.waitForSelector('[data-testid="raw-audio-toggle"]');
    await pf.click('[data-testid="raw-audio-toggle"]');
    assert.equal(await pf.$eval('[data-testid="raw-audio-toggle"]', (el) => el.innerText.trim()), '❚❚');
    await pf.click('[data-testid="raw-audio-delete"]');
    await pf.waitForSelector('[data-testid="raw-audio-delete-confirm"]');
    await pf.click('[data-testid="raw-audio-delete-confirm"]');
    await pf.waitForSelector('[data-testid="raw-audio-cleared"]');
    check('E2E: Complication start, Compact/LockScreen Live Activity, slice ingestion & real WAV playback', true);

    // Return to Timeline via mobile top breadcrumb bar
    await pf.click('[data-testid="crumb-back"]');

    // Flow 4: Unexpected drop -> Phone failover -> Watch offline queue -> Reconnect & manual flush
    await page.click('[data-testid="tb-unexpected-drop"]');
    await pf.waitForFunction(() => !conn.retrying && phoneRec.on && phoneRec.failover);
    assert.equal(await page.evaluate(() => S.watchRec && !S.reachable), true);
    assert.equal(await page.$eval('#w-conn-pill', (el) => el.innerText.trim()), '离线暂存');
    assert(
      await page.$eval(
        '[data-testid="ios-live-activity-card"]',
        (el) => !el.hidden && el.innerText.includes('蓝牙断连 · 本机保底录音中')
      )
    );

    await page.click('[data-testid="tb-cut-slice"]');
    assert.equal(await page.$eval('#w-q-cnt', (el) => el.innerText.trim()), '1');
    await page.click('[data-testid="watch-queue-entry"]');
    assert.equal(await page.$eval('[data-testid="watch-slice-row-2"]', (el) => el.innerText.includes('等待手机')), true);

    await page.click('[data-testid="tb-toggle-reach"]');
    await page.click('[data-testid="watch-flush-btn"]');
    assert.equal(await page.$eval('#w-q-cnt', (el) => el.innerText.trim()), '0');
    await pf.waitForSelector('[data-testid="card-watch-slice-2"]');
    check('E2E: Unexpected drop -> failover -> Watch queue -> reconnect flush to real Phone Timeline', true);

    // Reset clean
    await Promise.all([
      page.waitForFunction(() => !S.watchRec && document.getElementById('phone-frame').contentWindow && window.bridgeBoundWin === document.getElementById('phone-frame').contentWindow),
      page.click('[data-testid="proto-reset"]'),
    ]);

    // Flow 5: Phone NT list + Setting health item-by-item data + redesigned clean exthw subpage
    pf = await getPhoneFrame(page);
    await pf.click('[data-testid="nav-setting"]');
    await pf.click('[data-testid="nt-btn"]');
    assert.equal(await pf.$eval('#nt-pop', (el) => !el.hidden), true, 'NT pill should open Need Test list');
    await pf.click('[data-testid="nt-btn"]');
    assert.equal(await pf.$eval('#nt-pop', (el) => el.hidden), true, 'NT pill should toggle closed');
    await pf.$eval('[data-testid="set-health-location"]', (el) => el.scrollIntoView({ block: 'center' }));
    await pf.click('[data-testid="set-health-location"]');
    assert.equal(
      await pf.$eval('#setsub-title', (el) => el.innerText.includes('行为与健康信号')),
      true,
      'Setting row should jump to health sub page'
    );
    assert(await pf.$('[data-testid="health-location-card"]'), 'Health NC card should render');
    assert.equal(
      await pf.$$eval('[data-testid^="health-item-"]', (els) => els.length >= 6),
      true,
      'Health page should display item-by-item collected records'
    );
    assert(
      await pf.$eval(
        '[data-testid="health-location-card"]',
        (el) => el.innerText.includes('bpm') && el.innerText.includes('睡眠') && !el.innerText.includes('分钟前半转写')
      )
    );
    await pf.click('[data-testid="health-sync-switch"]');
    assert.equal(await pf.$eval('[data-testid="health-sync-switch"]', (el) => el.getAttribute('aria-checked')), 'false');
    await pf.click('[data-testid="health-sync-switch"]');
    assert.equal(await pf.$eval('[data-testid="health-sync-switch"]', (el) => el.getAttribute('aria-checked')), 'true');

    await pf.click('[data-testid="crumb-back"]');
    await pf.$eval('[data-testid="set-ext-hw"]', (el) => el.scrollIntoView({ block: 'center' }));
    await pf.click('[data-testid="set-ext-hw"]');
    assert(await pf.$('[data-testid="ext-getseed-switch"]'));
    assert(await pf.$('[data-testid="ext-omi-switch"]'));
    assert.equal(
      await pf.evaluate(() => !document.getElementById('p-setsub').innerText.includes('SDK Crate') && document.documentElement.scrollWidth <= window.innerWidth),
      true,
      'External HW subpage should omit SDK Crate jargon and fit cleanly without overflow'
    );
    check('E2E: Phone health item list and clean third-party hardware subpage work seamlessly', true);

    // Flow 6: Anti-mistouch stop on clean watch state — wake-first in AOD, full-drag to stop
    await page.evaluate(() => {
      S.watchAod = false;
      S.watchTab = 'app';
      S.watchRoute = 'main';
      saveState();
      renderWatchUI();
    });
    await page.click('[data-testid="watch-record-toggle"]');
    assert.equal(await page.evaluate(() => S.watchRec), true, 'Start button should begin recording');
    await page.click('[data-testid="watch-aod-toggle"]');
    assert.equal(
      await page.$eval('#w-stop-label', (el) => el.innerText.includes('先点亮屏幕')),
      true,
      'AOD stop strip should instruct wake-first flow'
    );
    await page.click('[data-testid="watch-stop-slider"]');
    assert.deepEqual(
      await page.evaluate(() => ({ aod: S.watchAod, rec: S.watchRec })),
      { aod: false, rec: true },
      'Tapping stop strip in AOD must wake screen without stopping recording'
    );
    check('E2E: AOD tap wakes screen first and never stops recording directly', true);

    const stopStrip = await page.$('[data-testid="watch-stop-slider"]');
    const stopKnob = await page.$('[data-testid="watch-stop-knob"]');
    const stripBox = await stopStrip.boundingBox();
    const knobBox = await stopKnob.boundingBox();
    await page.mouse.move(knobBox.x + knobBox.width / 2, knobBox.y + knobBox.height / 2);
    await page.mouse.down();
    await page.mouse.move(stripBox.x + stripBox.width - 4, knobBox.y + knobBox.height / 2, { steps: 10 });
    await page.mouse.up();
    assert.equal(await page.evaluate(() => S.watchRec), false, 'Full slide must stop recording');
    const idleCheck = await page.evaluate(() => {
      const clock = document.getElementById('w-idle-clock');
      const s = document.getElementById('watch-screen');
      return {
        pass:
          !!clock &&
          /^\d{1,2}:\d{2}$/.test(clock.textContent) &&
          s.scrollHeight <= s.clientHeight &&
          s.scrollWidth <= s.clientWidth,
        detail: `clock=${clock ? clock.textContent : 'null'} sh=${s.scrollHeight}/${s.clientHeight} sw=${s.scrollWidth}/${s.clientWidth} rec=${S.watchRec} aod=${S.watchAod}`
      };
    });
    check(
      'E2E: Idle watch hero falls back to watch-face clock after stop (still one screen)',
      idleCheck.pass,
      idleCheck.detail
    );

    check('E2E: Zero pageerror exceptions', pageErrors.length === 0, pageErrors.join('; '));
    check('E2E: Zero external network requests', netReqs.length === 0, netReqs.join('; '));
  } finally {
    if (browser) await browser.close();
    server.close();
  }
} else {
  console.log('INFO: Puppeteer/Chrome unavailable or static-only mode; E2E browser checks skipped.');
}

console.log(`\nSummary: ${results.length - failures}/${results.length} checks passed.`);
if (failures > 0) {
  process.exit(1);
}
