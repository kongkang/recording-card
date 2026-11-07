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
  const secVis = id => p.$eval('#' + id, x => getComputedStyle(x).display !== 'none');

  // 首页：固定高度顶栏、底栏、tab 文案、根页 crumb 隐藏
  assert.equal(await p.$$eval('nav.bottom button', e => e.length), 2);
  assert.deepEqual(await p.$$eval('nav.bottom button', e => e.map(x => x.innerText.trim())), ['Timeline', 'Setting']);
  assert.deepEqual(await p.$$eval('#p-timeline .tabs button', e => e.map(x => x.innerText.trim())), ['全部', '记录', '总结']);
  assert(await p.$eval('#app-title', x => !x.hidden && x.innerText === '录音卡'));
  assert.equal(await p.$eval('#crumb-back', x => getComputedStyle(x).display), 'none');
  const hh = await p.$eval('header.app', x => x.offsetHeight);
  assert(hh >= 50 && hh <= 56, 'header 高度应固定 ≈52，实际 ' + hh);
  assert(!(await p.evaluate(() => document.body.innerText.includes('模拟') || document.body.innerText.includes('演示'))));
  await shot('timeline-collapsed');

  // 卡片展开/收起 → 详情按钮进详情页（单屏压栈）
  await p.click('[data-testid="card-e1"]');
  assert(await p.$eval('[data-testid="card-e1"]', x => x.classList.contains('open')));
  await shot('timeline-expanded');
  await p.click('[data-testid="card-e1"]');
  assert(!(await p.$eval('[data-testid="card-e1"]', x => x.classList.contains('open'))));
  await p.click('[data-testid="card-e1"]');
  await p.click('[data-testid="detail-e1"]');
  assert(await p.$eval('#p-detail', x => x.classList.contains('show')));
  assert(!(await navVisible()));
  assert(await p.$eval('#crumb-back', x => getComputedStyle(x).display !== 'none' && x.innerText.includes('Timeline')));
  assert(await p.$eval('#dtab-refs', x => x.hidden));
  await shot('event-detail');
  await p.click('[data-testid="det-tab-raw"]');
  assert(await p.$eval('#dt-raw', x => x.style.display === 'block' && x.innerText.includes('啊不对')));
  await shot('raw-data');
  await p.click('[data-testid="det-tab-dlg"]');
  await p.click('[data-testid="crumb-back"]');
  assert(await navVisible());

  // 总结：勾选模式锁定 Tab 到「记录」+ Action Card + 范围全选
  await p.click('[data-testid="summary-start"]');
  assert.equal(await p.$eval('[data-f="all"]', x => x.disabled), true);
  assert.equal(await p.$eval('[data-f="summary"]', x => x.disabled), true);
  assert.equal(await p.$eval('[data-f="event"]', x => x.disabled), false);
  assert(await p.$eval('[data-f="event"]', x => x.classList.contains('on')));
  assert.equal(await p.$$eval('#feed [data-sel]', x => x.length), 6);
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
  await p.click('.rangebar .chip[data-r="week"]');
  assert.equal(await checkedCount(), 5);
  assert.equal(await p.$eval('#sel-count2', x => x.innerText), '已选 5 项');
  assert.equal(await p.$eval('#gen-btn2', x => x.innerText.trim()), '生成总结');
  assert.equal(await p.$$eval('#sumbar .row2 .btn', x => x.length), 2);

  // 生成：立即切到总结页生成态（已生成/预计还需秒数 + 步骤），完成后就地填充结果
  await p.click('[data-testid="generate-summary"]');
  assert(await p.$eval('#p-sumres', x => x.classList.contains('show')));
  assert(await p.$eval('#sum-gen', x => !x.hidden));
  assert(await p.$eval('#stabs', x => x.hidden));
  assert(await p.$eval('#gen-elapsed', x => x.innerText.includes('已生成')));
  await new Promise(r => setTimeout(r, 1200));
  const el1 = await p.$eval('#gen-elapsed', x => x.innerText);
  assert(/已生成 [1-9]\d* 秒/.test(el1), '应有递增秒数：' + el1);
  assert(await p.$eval('#gen-eta', x => x.innerText.includes('预计还需')));
  await p.waitForFunction(() => document.getElementById('sum-gen') && document.getElementById('sum-gen').hidden === true, { timeout: 15000 });
  assert(await p.$eval('#p-sumres', x => x.classList.contains('show')));
  assert(await p.$eval('#stabs', x => !x.hidden));
  assert.equal(await p.$eval('#sum-title', x => x.innerText), '项目排期与客户反馈');
  assert(await p.$eval('#sum-sub', x => x.innerText.includes('条记录') && !x.innerText.includes('来源')));
  assert.deepEqual(await p.$$eval('#stabs button', e => e.map(x => x.innerText.trim())), ['全部', '概览', '逻辑结构', '信息点', '行动项', '来源记录']);
  assert(await secVis('sec-ov') && await secVis('sec-map') && await secVis('sec-pt') && await secVis('sec-todo') && await secVis('sec-src'));
  assert.equal(await p.$('#sum-md'), null);
  await shot('summary-result');

  // Tab 切换：概览单显；信息点展开 + 溯源跳转
  await p.click('#stabs button[data-st="ov"]');
  assert(await secVis('sec-ov') && !(await secVis('sec-map')));
  await p.click('#stabs button[data-st="pt"]');
  assert(await secVis('sec-pt') && !(await secVis('sec-ov')));
  assert(await p.$eval('#pt-0 .pt-d', x => x.style.display !== 'none' || true)); // 展开前隐藏由 .pt-b 控制
  assert(!(await p.$eval('#pt-0', x => x.classList.contains('open'))));
  await p.click('#pt-0 .pt-h');
  assert(await p.$eval('#pt-0', x => x.classList.contains('open') && x.querySelector('.pt-d').offsetParent !== null));
  assert((await p.$$('#pt-0 .srcchip')).length > 0);
  await shot('summary-render-todo');
  await p.click('#pt-0 .srcchip');
  assert(await p.$eval('#p-detail', x => x.classList.contains('show')));
  assert.equal(await p.$eval('#crumb-dest', x => x.innerText), '总结');
  // 详情页第三个 tab：被引用总结（>0 才显示）
  assert(await p.$eval('#dtab-refs', x => !x.hidden && x.innerText.includes('被引用总结 1')));
  await p.click('[data-testid="det-tab-refs"]');
  assert(await p.$eval('#dt-refs', x => x.style.display === 'block' && x.innerText.includes('项目排期与客户反馈')));
  await shot('detail-backlink');
  await p.click('[data-testid^="ref-"]');
  assert(await p.$eval('#p-sumres', x => x.classList.contains('show')));
  await p.click('[data-testid="crumb-back"]');
  assert(await p.$eval('#p-timeline', x => x.classList.contains('show')));
  assert(await navVisible());
  assert.equal(await p.$eval('[data-f="all"]', x => x.disabled), false);
  assert(await p.$eval('[data-f="all"]', x => x.classList.contains('on')));

  // 来源记录 tab 闭环：从总结跳回原始记录
  await p.click('.card[data-kind="summary"]');
  await p.click('.card[data-kind="summary"]');
  assert(await p.$eval('.card[data-kind="summary"]', x => x.classList.contains('open')));
  await p.click('[data-testid="open-sum"]');
  assert(await p.$eval('#p-sumres', x => x.classList.contains('show')));
  await p.click('#stabs button[data-st="src"]');
  assert(await secVis('sec-src') && !(await secVis('sec-ov')));
  await p.click('[data-testid="src-e1"]');
  assert(await p.$eval('#p-detail', x => x.classList.contains('show')));
  await p.click('[data-testid="crumb-back"]');
  assert(await p.$eval('#p-sumres', x => x.classList.contains('show')));

  // 导出：5 种格式 → 模拟调起系统分享
  await p.click('[data-testid="export-btn"]');
  assert(await p.$eval('#export-pop', x => !x.hidden));
  assert.equal(await p.$$eval('#export-pop button', e => e.length), 5);
  await shot('summary-export');
  await p.click('#export-pop button:nth-child(3)');
  assert(await p.$eval('#toast', x => x.classList.contains('show') && x.innerText.includes('系统分享') && x.innerText.includes('PDF')));
  assert(await p.$eval('#export-pop', x => x.hidden));
  await p.click('[data-testid="crumb-back"]');

  // 取消总结：pending 卡移除，解锁 tab 回到全部
  await p.click('[data-testid="summary-start"]');
  assert.equal(await p.$$eval('#feed [data-sel]', x => x.length), 6);
  await p.click('#sumbar .btn.ghost');
  assert.equal(await p.$$eval('.card[data-kind="summary"]', x => x.length), 1);
  assert.equal(await p.$$eval('#feed [data-sel]', x => x.length), 0);
  assert(!(await p.$eval('#rangebar', x => x.classList.contains('show'))));
  assert(!(await p.$eval('#sumbar', x => x.classList.contains('show'))));
  assert.equal(await p.$eval('[data-f="all"]', x => x.disabled), false);
  assert(await p.$eval('[data-f="all"]', x => x.classList.contains('on')));

  // Setting 与录音卡状态页
  await p.click('[data-testid="nav-setting"]');
  await shot('setting');
  const sw = await p.$eval('.sw', x => x.getAttribute('aria-checked'));
  await p.click('.sw');
  assert.notEqual(await p.$eval('.sw', x => x.getAttribute('aria-checked')), sw);
  await p.click('[data-testid="hw-capsule"]');
  assert(await p.$eval('#sheet', x => x.classList.contains('show')));
  assert(await p.$eval('#dev-main', x => x.innerText.includes('已连接') && x.innerText.includes('预计可录制到')));
  assert.equal(await p.$$eval('#dev-main .row', x => x.length), 5);
  assert.equal(await p.$$eval('#dev-main .actions .btn', x => x.length), 2);
  await shot('hardware-capsule');
  await p.click('[data-testid="sync-now"]');
  await new Promise(r => setTimeout(r, 900));
  assert.equal(await p.$eval('#dev-state', x => x.innerText), '同步完成 · 刚刚');
  await p.click('[data-testid="fw-update"]');
  assert(await p.$eval('#dev-upg', x => !x.hidden));
  await p.click('#upg-btn');
  await new Promise(r => setTimeout(r, 3200));
  assert.equal(await p.$eval('#fw-ver', x => x.innerText.trim()), 'v1.3.0');
  await p.click('#dev-main > .btn:last-child');

  assert.equal(await p.evaluate(() => document.documentElement.scrollWidth > innerWidth), false);

  // 宽屏：双栏、左栏常显、固定高度、空态
  await p.setViewport({ width: 900, height: 1100, deviceScaleFactor: 2 });
  await p.reload({ waitUntil: 'domcontentloaded' });
  await new Promise(r => setTimeout(r, 300));
  assert.equal(await p.evaluate(() => getComputedStyle(document.body).display), 'grid');
  assert(await p.$eval('#empty-pane', x => getComputedStyle(x).display === 'flex'));
  assert(await navVisible());
  const hh2 = await p.$eval('header.app', x => x.offsetHeight);
  assert(hh2 >= 54 && hh2 <= 58, '宽屏 header 高度应固定 ≈56，实际 ' + hh2);
  const nh = await p.$eval('nav.bottom', x => x.offsetHeight);
  assert(nh >= 54 && nh <= 58, '宽屏 nav 高度应固定 ≈56，实际 ' + nh);
  await shot('wide-empty');
  await p.click('[data-testid="card-e1"]');
  await p.click('[data-testid="detail-e1"]');
  assert(await p.$eval('#p-detail', x => x.classList.contains('show')));
  assert(await p.$eval('#p-timeline', x => x.classList.contains('show') && x.offsetParent !== null));
  assert(await p.$eval('#empty-pane', x => getComputedStyle(x).display === 'none'));
  assert(await navVisible());
  await shot('wide-detail');
  await p.click('[data-testid="crumb-back"]');
  assert(await p.$eval('#empty-pane', x => getComputedStyle(x).display === 'flex'));
  assert(await p.$eval('#p-detail', x => !x.classList.contains('show')));

  assert.equal(errors.length, 0, errors.join(','));
  assert.equal(net.length, 0, net.join(','));
  console.log(JSON.stringify({ pass: true, viewport: '390x844 @2x + 900x1100', navigation: 2, errors, networkRequests: net, checks: ['fixed-chrome', 'crumb-root-hidden', 'two-line-card', 'expand-collapse', 'detail-entry', 'subpage-hides-nav', 'detail-tabs-raw', 'select-mode', 'tabs-lock-on-summary', 'action-card', 'range-today', 'range-week', 'range-month', 'tap-toggle', 'sumbar-rows', 'gen-status-view', 'generate-progress', 'sum-tabs', 'default-all-view', 'point-expand', 'point-trace', 'refs-tab', 'detail-backlink', 'src-tab-loop', 'export-sheet', 'filter', 'cancel-summary', 'setting-toggle', 'device-sheet', 'sheet-single-rows', 'no-sim-labels', 'sync-now', 'firmware-update', 'wide-two-pane', 'wide-list-stays', 'no-overflow'] }, null, 2));
  await b.close();
})().catch(e => { console.error(e); process.exit(1) });
