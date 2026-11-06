// 录音卡原型验收脚本：390×844 @2x，本地 file://，断言无网络请求、无 JS 异常。
// 运行：cd prototype && npm install && node verify.cjs
const fs = require('node:fs');
const path = require('node:path');
const { pathToFileURL } = require('node:url');
const assert = require('node:assert/strict');

let pp;
try { pp = require('puppeteer-core'); }
catch { pp = require('/tmp/node_modules/puppeteer-core'); }

const CHROME_CANDIDATES = [
  process.env.CHROME_PATH,
  '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome',
  '/usr/bin/google-chrome',
].filter(Boolean);
const exe = CHROME_CANDIDATES.find(p => fs.existsSync(p));
if (!exe) { console.error('未找到 Chrome，可用 CHROME_PATH 指定'); process.exit(1); }

(async () => {
  const b = await pp.launch({ executablePath: exe, headless: true, args: ['--no-sandbox', '--disable-gpu'] });
  const p = await b.newPage();
  await p.setViewport({ width: 390, height: 844, deviceScaleFactor: 2 });
  let errors = [], net = [];
  p.on('pageerror', e => errors.push(e.message));
  p.on('request', r => { if (!r.url().startsWith('file:') && !r.url().startsWith('data:')) net.push(r.url()) });
  await p.goto(pathToFileURL(path.join(__dirname, 'index.html')).href);
  const shot = async n => p.screenshot({ path: path.join(__dirname, 'screenshots', `${n}.png`) });

  assert.equal(await p.$$eval('nav.bottom button', e => e.length), 2);
  assert.deepEqual(await p.$$eval('nav.bottom button', e => e.map(x => x.innerText.trim())), ['Timeline', 'Setting']);
  assert.deepEqual(await p.$$eval('.tabs button', e => e.map(x => x.innerText.trim())), ['全部', '记录', '总结']);

  await shot('timeline-collapsed');
  // 折叠卡两行：标题 + 时间·时长；点开展开，再点收起（不进详情）
  const h3 = await p.$eval('[data-testid="card-e1"] h3', x => x.innerText.trim());
  assert(h3.length > 0);
  assert(await p.$eval('[data-testid="card-e1"] .when', x => /\d{2}:\d{2} · /.test(x.innerText)));
  await p.click('[data-testid="card-e1"]');
  assert(await p.$eval('[data-testid="card-e1"]', x => x.classList.contains('open')));
  assert(await p.$eval('[data-testid="detail-e1"]', x => x.innerText.includes('详情')));
  await shot('timeline-expanded');
  await p.click('[data-testid="card-e1"]');
  assert(!(await p.$eval('[data-testid="card-e1"]', x => x.classList.contains('open'))));
  // 展开态经详情按钮进详情页
  await p.click('[data-testid="card-e1"]');
  await p.click('[data-testid="detail-e1"]');
  assert(await p.$eval('#p-detail', x => x.classList.contains('show')));
  await shot('event-detail');
  await p.click('[data-testid="raw-e1"]');
  assert(await p.$eval('#raw-body', x => x.innerText.includes('啊不对')));
  await shot('raw-data');
  await p.click('#p-raw .back');
  await p.click('#p-detail .back');
  // 总结 = 时间轴内勾选模式 + 此刻 Action Card + 范围全选
  await p.click('[data-testid="summary-start"]');
  assert.equal(await p.$$eval('#feed [data-sel]', x => x.length), 6);
  assert(await p.$eval('#feed .card[data-kind="summary"]', x => x.classList.contains('sumcard')));
  assert(await p.$eval('#rangebar', x => x.classList.contains('show')));
  await shot('summary-multiselect');
  const checkedCount = () => p.$$eval('[data-sel]:checked', x => x.length);
  await p.click('.rangebar .chip[data-r="today"]');
  assert.equal(await checkedCount(), 3);
  await p.click('.rangebar .chip[data-r="week"]');
  assert.equal(await checkedCount(), 5);
  await p.click('.rangebar .chip[data-r="month"]');
  assert.equal(await checkedCount(), 6);
  await p.click('.rangebar .chip[data-r="none"]');
  assert.equal(await checkedCount(), 0);
  await p.click('[data-testid="card-e4"]');
  assert.equal(await checkedCount(), 1);
  await p.click('[data-testid="card-e4"]');
  assert.equal(await checkedCount(), 0);
  await p.click('.rangebar .chip[data-r="week"]');
  assert.equal(await checkedCount(), 5);
  assert.equal(await p.$eval('#sel-count2', x => x.innerText), '已选 5 项');
  await p.click('[data-testid="generate-summary"]');
  assert(await p.$eval('#p-sumres', x => x.classList.contains('show')));
  await shot('summary-result');
  await p.click('#tab-ix');
  await p.click('[data-ix="0"]');
  assert.equal(await p.$eval('#ix-done', x => x.innerText), '1');
  await p.click('details summary');
  await shot('summary-result-html');
  await p.click('#p-sumres .back');
  assert.equal(await p.$$eval('.card[data-kind="summary"]', x => x.length), 1);
  assert(await p.$eval('.card[data-kind="summary"]', x => x.classList.contains('open')));
  assert(await p.$eval('.card[data-kind="summary"] .when', x => x.innerText.includes('已选 5 片段')));
  await shot('timeline-summary-card');
  await p.click('[data-f="summary"]');
  assert.equal(await p.$$eval('#feed [data-kind="event"]', x => x.length), 0);
  await p.click('.card[data-kind="summary"]');
  await p.click('.card[data-kind="summary"]');
  await p.click('[data-testid="open-sum"]');
  assert(await p.$eval('#p-sumres', x => x.classList.contains('show')));
  await p.click('#p-sumres .back');
  await p.click('[data-f="all"]');
  // 取消总结：pending Action Card 移除，退出勾选模式
  await p.click('[data-testid="summary-start"]');
  assert.equal(await p.$$eval('.card[data-kind="summary"]', x => x.length), 2);
  await p.click('#sumbar .btn.ghost');
  assert.equal(await p.$$eval('.card[data-kind="summary"]', x => x.length), 1);
  assert.equal(await p.$$eval('#feed [data-sel]', x => x.length), 0);
  assert(!(await p.$eval('#rangebar', x => x.classList.contains('show'))));
  assert(!(await p.$eval('#sumbar', x => x.classList.contains('show'))));
  // Setting 与硬件胶囊
  await p.click('[data-testid="nav-setting"]');
  await shot('setting');
  const sw = await p.$eval('.sw', x => x.getAttribute('aria-checked'));
  await p.click('.sw');
  assert.notEqual(await p.$eval('.sw', x => x.getAttribute('aria-checked')), sw);
  await p.click('[data-testid="hw-capsule"]');
  assert(await p.$eval('#sheet', x => x.classList.contains('show')));
  await shot('hardware-capsule');
  await p.click('#sheet .btn');
  await p.click('#sheet .btn:last-child');

  assert.equal(await p.evaluate(() => document.documentElement.scrollWidth > innerWidth), false);
  assert.equal(errors.length, 0, errors.join(','));
  assert.equal(net.length, 0, net.join(','));
  console.log(JSON.stringify({ pass: true, viewport: '390x844 @2x', navigation: 2, errors, networkRequests: net, checks: ['two-line-card', 'expand-collapse', 'detail-entry', 'raw-mapping', 'select-mode', 'action-card', 'range-today', 'range-week', 'range-month', 'clear-none', 'tap-toggle', 'generate-summary', 'interactive-html', 'filter', 'summary-reopen', 'cancel-summary', 'setting-toggle', 'hardware-sheet', 'no-overflow'] }, null, 2));
  await b.close();
})().catch(e => { console.error(e); process.exit(1) });
