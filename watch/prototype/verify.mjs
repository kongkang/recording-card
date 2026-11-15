#!/usr/bin/env node
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { createRequire } from 'node:module';
import { fileURLToPath, pathToFileURL } from 'node:url';

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
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

// 2. Inline <script> compiles without syntax errors
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

// 3. Design tokens, isolated storage key, and redline wording checks
check('Contains design token --bg:#FAFAF8', /--bg:\s*#FAFAF8\b/i.test(html));
check('Contains bottom padding token --page-pad-b:48px', /--page-pad-b:\s*48px\b/i.test(html));
check('Contains isolated storage key rc-watch-proto-v2', html.includes('rc-watch-proto-v2'));
check('Contains zero forbidden redline words (模拟/演示/已充满)', !/(模拟|演示|已充满)/.test(html));

// 4. Required data-testid anchors (static attributes & JS template anchors)
const staticTestIds = [
  'view-mode-seg',
  'tb-toggle-reach',
  'tb-unexpected-drop',
  'tb-cut-slice',
  'proto-reset',
  'phone-dyn-island',
  'hw-capsule',
  'nav-timeline',
  'nav-setting',
  'set-apple-watch',
  'phone-refresh-btn',
  'phone-record-toggle',
  'phone-mark-btn',
  'sync-now',
  'wifi-row',
  'fw-update',
  'phone-rec-row',
  'watch-screen-tabs',
  'watch-aod-toggle',
  'comp-corner',
  'comp-circular',
  'comp-rectangular',
  'comp-inline',
  'watch-record-toggle',
  'watch-mark-btn',
  'watch-queue-entry',
  'watch-flush-btn',
];

for (const id of staticTestIds) {
  const re = new RegExp(`data-testid=["']${id}["']`);
  check(`Contains static data-testid="${id}"`, re.test(html));
}

const dynamicTestIds = [
  'watch-link-switch',
  'watch-link-status-card',
  'watch-complication-guide',
  'watch-connect-btn',
  'phone-flush-btn',
  'received-slice-',
  'play-slice-',
  'delete-slice-',
];

for (const id of dynamicTestIds) {
  check(
    `Contains dynamic data-testid "${id}"`,
    html.includes(`data-testid="${id}`) || html.includes(`data-testid='${id}`)
  );
}

// 5. No duplicate static HTML id attributes outside <script>/<style>
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

// 6. Optional headless Chromium E2E verification when puppeteer-core + Chrome exist
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

if (pp && chromePath) {
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
      if (!req.url().startsWith('file:') && !req.url().startsWith('data:')) {
        netReqs.push(req.url());
      }
    });

    await page.goto(pathToFileURL(htmlPath).href, { waitUntil: 'load' });

    // Clear any stale storage and reload clean
    await page.evaluate(() => resetPrototype());

    // Baseline redline & overflow check
    const bodyText = await page.evaluate(() => document.body.innerText);
    check(
      'E2E: Rendered DOM contains zero forbidden words',
      !/模拟|演示|已充满/.test(bodyText)
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

    // Flow 1: Default 3-device scan -> enable Apple Watch link -> 4-device scan -> capability gating
    await page.click('[data-testid="hw-capsule"]');
    assert.equal(await page.$$eval('#conn-list .conn-item', (els) => els.length), 3);
    check('E2E: Default scan hides Watch and keeps 3 hardware devices', true);

    await page.evaluate(() => closeSheet());
    await page.click('[data-testid="nav-setting"]');
    assert.equal(await page.$eval('#sv-watch', (el) => el.innerText.trim()), '未开启');
    await page.click('[data-testid="set-apple-watch"]');
    assert(await page.$('[data-testid="watch-link-status-card"]'));
    assert(await page.$('[data-testid="watch-complication-guide"]'));
    assert(
      await page.$eval(
        '[data-testid="watch-link-status-card"]',
        (el) => !el.innerText.includes('%') && !el.innerText.includes('已充满')
      )
    );
    await page.click('[data-testid="watch-link-switch"]');
    await page.click('[data-testid="crumb-back"]');
    assert.equal(await page.$eval('#sv-watch', (el) => el.innerText.trim()), '已配对');

    await page.click('[data-testid="hw-capsule"]');
    assert.equal(await page.$$eval('#conn-list .conn-item', (els) => els.length), 4);
    await page.click('[data-testid="dev-item-APPLE_WATCH_S10"]');
    assert.equal(await page.$eval('#dev-kind-badge', (el) => el.innerText.trim()), 'Apple Watch');
    assert.equal(await page.$eval('#row-sync', (el) => !el.hidden), true);
    assert.equal(await page.$eval('#row-wifi', (el) => el.hidden), true);
    assert.equal(await page.$eval('#row-fw', (el) => el.hidden), true);
    assert.equal(await page.$('#dev-main [data-testid="phone-rec-row"]'), null);
    assert(
      await page.$eval(
        '#row-batt',
        (el) => !el.innerText.includes('%') && !el.innerText.includes('已充满')
      )
    );
    check('E2E: Watch link enables 4-device scan and hides Wi-Fi/FW in StatusSheet', true);
    await page.evaluate(() => closeSheet());
    await page.click('[data-testid="nav-timeline"]');

    // Flow 2: Watch complication start -> Dynamic Island -> slice cut -> iPhone WAV Timeline play/delete
    await page.click('[data-testid="comp-corner"]');
    assert.equal(await page.evaluate(() => S.hwRecOn && S.watchTab === 'app'), true);
    assert(
      await page.$eval(
        '[data-testid="phone-dyn-island"]',
        (el) =>
          el.classList.contains('show') &&
          el.innerText.includes('Apple Watch 录音中') &&
          el.innerText.includes('本机保底待命中')
      )
    );
    await page.click('[data-testid="tb-cut-slice"]');
    const sliceSelector = '[data-testid="received-slice-watch-slice-2"]';
    assert(await page.$(sliceSelector), 'Expected ingested Watch slice card in Timeline');
    await page.click(`${sliceSelector} .card`);
    await page.click('[data-testid="play-slice-watch-slice-2"]');
    assert.equal(
      await page.$eval('[data-testid="play-slice-watch-slice-2"]', (el) => el.innerText.trim()),
      '暂停播放'
    );
    await page.click('[data-testid="delete-slice-watch-slice-2"]');
    assert(
      await page.$eval(sliceSelector, (el) => el.innerText.includes('原始录音已清理'))
    );
    check('E2E: Complication start, Dynamic Island, Watch slice ingestion, WAV play & cleanup', true);

    // Flow 3: Unexpected drop -> phone standby failover -> offline queue -> reconnect flush
    await page.click('[data-testid="tb-unexpected-drop"]');
    assert.deepEqual(
      await page.evaluate(() => ({
        phoneRecOn: S.phoneRecOn,
        failover: S.phoneFailover,
        wcsReachable: S.wcsReachable,
      })),
      { phoneRecOn: true, failover: true, wcsReachable: false }
    );
    assert(
      await page.$eval(
        '[data-testid="phone-dyn-island"]',
        (el) => el.classList.contains('show') && el.innerText.includes('本机保底录音中')
      )
    );
    await page.click('[data-testid="tb-cut-slice"]');
    assert.equal(await page.$eval('#w-q-cnt', (el) => el.innerText.trim()), '1');
    await page.click('[data-testid="tb-toggle-reach"]');
    await page.click('[data-testid="watch-flush-btn"]');
    assert.equal(await page.$eval('#w-q-cnt', (el) => el.innerText.trim()), '0');
    assert(
      await page.$('[data-testid="received-slice-watch-slice-3"]'),
      'Expected flushed offline slice in iPhone Timeline'
    );
    check('E2E: Unexpected drop triggers phone failover and reconnect flushes Watch queue', true);

    // Reset clean
    await page.click('[data-testid="proto-reset"]');
    assert.equal(
      await page.evaluate(() => !S.hwRecOn && !S.phoneRecOn && !S.watchLinkEnabled),
      true
    );

    check('E2E: Zero pageerror exceptions', pageErrors.length === 0, pageErrors.join('; '));
    check('E2E: Zero external network requests', netReqs.length === 0, netReqs.join('; '));
  } finally {
    if (browser) await browser.close();
  }
} else {
  console.log('INFO: Puppeteer/Chrome unavailable or static-only mode; E2E browser checks skipped.');
}

console.log(`\nSummary: ${results.length - failures}/${results.length} checks passed.`);
if (failures > 0) {
  process.exit(1);
}
