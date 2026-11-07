// 录音卡原型验收脚本：窄屏 390×844 @2x + 宽屏双栏检查；本地 file://，断言无网络请求、无 JS 异常。
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
  const navVisible = () => p.$eval('nav.bottom', x => getComputedStyle(x).display !== 'none');

  // 首页：底栏可见、标题与胶囊、tab 文案
  assert.equal(await p.$$eval('nav.bottom button', e => e.length), 2);
  assert.deepEqual(await p.$$eval('nav.bottom button', e => e.map(x => x.innerText.trim())), ['Timeline', 'Setting']);
  assert.deepEqual(await p.$$eval('#p-timeline .tabs button', e => e.map(x => x.innerText.trim())), ['全部', '记录', '总结']);
  assert(await p.$eval('#app-title', x => !x.hidden && x.innerText === '录音卡'));
  assert(await p.$eval('#crumb-back', x => x.hidden));
  assert(await p.$eval('#cap-txt', x => x.innerText.includes('录音卡') && x.innerText.includes('82%')));
  assert(!(await p.evaluate(() => document.body.innerText.includes('模拟') || document.body.innerText.includes('演示'))));
  await shot('timeline-collapsed');

  // 卡片两行折叠：展开 → 收起；展开态「详情」按钮进详情页
  await p.click('[data-testid="card-e1"]');
  assert(await p.$eval('[data-testid="card-e1"]', x => x.classList.contains('open')));
  await shot('timeline-expanded');
  await p.click('[data-testid="card-e1"]');
  assert(!(await p.$eval('[data-testid="card-e1"]', x => x.classList.contains('open'))));
  await p.click('[data-testid="card-e1"]');
  await p.click('[data-testid="detail-e1"]');
  assert(await p.$eval('#p-detail', x => x.classList.contains('show')));
  assert(await p.$eval('#app-title', x => x.hidden));
  assert(await p.$eval('#crumb-back', x => !x.hidden && x.innerText.includes('Timeline')));
  assert(!(await navVisible()));
  await shot('event-detail');
  // 原始数据为详情页平级 tab
  await p.click('[data-testid="det-tab-raw"]');
  assert(await p.$eval('#dt-raw', x => x.style.display === 'block' && x.innerText.includes('啊不对')));
  await shot('raw-data');
  await p.click('[data-testid="det-tab-dlg"]');
  assert(await p.$eval('#dt-dlg', x => x.style.display === 'block'));
  await p.click('[data-testid="crumb-back"]');
  assert(await p.$eval('#p-timeline', x => x.classList.contains('show')));
  assert(await navVisible());

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
  assert.equal(await p.$eval('#gen-btn2', x => x.innerText.trim()), '生成总结');
  assert.equal(await p.$$eval('#sumbar .row2 .btn', x => x.length), 2);
  // 生成：卡片先显示进度，完成后自动进入结果页
  await p.click('[data-testid="generate-summary"]');
  assert(!(await p.$eval('#p-sumres', x => x.classList.contains('show'))));
  assert(await p.$('#feed .card[data-kind="summary"] .cardprog i'));
  assert.equal(await p.$eval('.card[data-kind="summary"]', x => x.getAttribute('aria-disabled')), 'true');
  await new Promise(r => setTimeout(r, 2600));
  assert(await p.$eval('#p-sumres', x => x.classList.contains('show')));
  assert(!(await navVisible()));
  assert.equal(await p.$eval('#sum-title', x => x.innerText), '项目排期与客户反馈');
  assert(await p.$eval('#sum-sub', x => x.innerText.includes('条记录') && !x.innerText.includes('来源')));
  for (const id of ['sec-ov', 'sec-map', 'sec-pt', 'sec-todo']) assert(await p.$('#' + id));
  assert.equal(await p.$eval('#sum-md', x => getComputedStyle(x).display), 'none');
  await shot('summary-result');
  // 目录：右上弹出导航
  await p.click('[data-testid="toc-btn"]');
  assert(await p.$eval('#toc-pop', x => !x.hidden));
  await p.click('#toc-pop button:nth-child(4)');
  assert(await p.$eval('#toc-pop', x => x.hidden));
  await p.click('[data-ix="0"]');
  assert.equal(await p.$eval('#ix-done', x => x.innerText), '1');
  await shot('summary-render-todo');
  // Markdown 原文作为导出选项
  await p.click('[data-testid="toc-btn"]');
  await p.click('#toc-pop button:nth-child(5)');
  assert(await p.$eval('#sum-md', x => x.style.display === 'block' && x.innerText.includes('## 行动项')));
  await shot('summary-md-export');
  await p.click('[data-testid="toc-btn"]');
  await p.click('#toc-pop button:nth-child(5)');
  assert.equal(await p.$eval('#sum-md', x => x.style.display), 'none');
  await p.click('[data-testid="crumb-back"]');
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
  await p.click('[data-testid="crumb-back"]');
  await p.click('[data-f="all"]');
  // 取消总结：pending Action Card 移除，退出勾选模式
  await p.click('[data-testid="summary-start"]');
  assert.equal(await p.$$eval('.card[data-kind="summary"]', x => x.length), 2);
  await p.click('#sumbar .btn.ghost');
  assert.equal(await p.$$eval('.card[data-kind="summary"]', x => x.length), 1);
  assert.equal(await p.$$eval('#feed [data-sel]', x => x.length), 0);
  assert(!(await p.$eval('#rangebar', x => x.classList.contains('show'))));
  assert(!(await p.$eval('#sumbar', x => x.classList.contains('show'))));

  // Setting 与录音卡状态页
  await p.click('[data-testid="nav-setting"]');
  await shot('setting');
  const sw = await p.$eval('.sw', x => x.getAttribute('aria-checked'));
  await p.click('.sw');
  assert.notEqual(await p.$eval('.sw', x => x.getAttribute('aria-checked')), sw);
  await p.click('[data-testid="hw-capsule"]');
  assert(await p.$eval('#sheet', x => x.classList.contains('show')));
  assert(await p.$eval('#dev-main', x => x.innerText.includes('已连接') && x.innerText.includes('预计可录制到')));
  await shot('hardware-capsule');
  await p.click('[data-testid="sync-now"]');
  await new Promise(r => setTimeout(r, 900));
  assert.equal(await p.$eval('#dev-state', x => x.innerText), '同步完成 · 刚刚');
  await p.click('[data-testid="fw-update"]');
  assert(await p.$eval('#dev-upg', x => !x.hidden));
  await p.click('#upg-btn');
  await new Promise(r => setTimeout(r, 3200));
  assert.equal(await p.$eval('#fw-ver', x => x.innerText), 'v1.3.0');
  assert(await p.$eval('#fw-upd', x => x.hidden));
  await p.click('#dev-main > .btn:last-child');
  assert(!(await p.$eval('#sheet', x => x.classList.contains('show'))));

  // 窄屏收尾断言
  assert.equal(await p.evaluate(() => document.documentElement.scrollWidth > innerWidth), false);

  // 宽屏：双栏、底栏保留、空态
  await p.setViewport({ width: 900, height: 1100, deviceScaleFactor: 2 });
  await p.reload({ waitUntil: 'domcontentloaded' });
  await new Promise(r => setTimeout(r, 300));
  assert.equal(await p.evaluate(() => getComputedStyle(document.body).display), 'grid');
  assert(await p.$eval('#empty-pane', x => getComputedStyle(x).display === 'flex'));
  assert(await navVisible());
  await shot('wide-empty');
  await p.click('[data-testid="card-e1"]');
  await p.click('[data-testid="detail-e1"]');
  assert(await p.$eval('#p-detail', x => x.classList.contains('show')));
  assert(await navVisible());
  assert(await p.$eval('#empty-pane', x => getComputedStyle(x).display === 'none'));
  await shot('wide-detail');
  await p.click('[data-testid="crumb-back"]');
  assert(await p.$eval('#empty-pane', x => getComputedStyle(x).display === 'flex'));

  assert.equal(errors.length, 0, errors.join(','));
  assert.equal(net.length, 0, net.join(','));
  console.log(JSON.stringify({ pass: true, viewport: '390x844 @2x + 900x1100', navigation: 2, errors, networkRequests: net, checks: ['two-line-card', 'expand-collapse', 'detail-entry', 'breadcrumb-back', 'subpage-hides-nav', 'detail-tabs-raw', 'select-mode', 'action-card', 'range-today', 'range-week', 'range-month', 'clear-none', 'tap-toggle', 'sumbar-rows', 'generate-progress', 'rendered-view', 'toc-nav', 'md-export', 'filter', 'summary-reopen', 'cancel-summary', 'setting-toggle', 'device-sheet', 'no-sim-labels', 'sync-now', 'firmware-update', 'wide-two-pane', 'no-overflow'] }, null, 2));
  await b.close();
})().catch(e => { console.error(e); process.exit(1) });
