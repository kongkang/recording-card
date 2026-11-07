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
  // 电池胶囊：仅图标（无数字），按电量分三色
  assert(await p.$eval('.capsule .batt', x => x.classList.contains('lv-hi')));
  assert(!(await p.$eval('[data-testid="hw-capsule"]', x => /\d/.test(x.innerText))));
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
  assert(await p.$eval('#stickbar', x => x.hidden));
  assert(await p.$eval('#gen-elapsed', x => x.innerText.includes('已生成')));
  await new Promise(r => setTimeout(r, 1200));
  const el1 = await p.$eval('#gen-elapsed', x => x.innerText);
  assert(/已生成 [1-9]\d* 秒/.test(el1), '应有递增秒数：' + el1);
  assert(await p.$eval('#gen-eta', x => x.innerText.includes('预计还需')));
  await p.waitForFunction(() => document.getElementById('sum-gen') && document.getElementById('sum-gen').hidden === true, { timeout: 15000 });
  assert(await p.$eval('#p-sumres', x => x.classList.contains('show')));
  assert(await p.$eval('#stickbar', x => !x.hidden));
  assert.equal(await p.$eval('#sum-title', x => x.innerText), '项目排期与客户反馈');
  assert(await p.$eval('#sum-sub', x => x.innerText.includes('条记录') && !x.innerText.includes('来源')));
  assert.deepEqual(await p.$$eval('#stabs button', e => e.map(x => x.innerText.trim())), ['全部', '概览', '逻辑结构', '信息点', '行动项', '来源记录']);
  assert(await secVis('sec-ov') && await secVis('sec-map') && await secVis('sec-pt') && await secVis('sec-todo') && await secVis('sec-src'));
  assert.equal(await p.$('#sum-md'), null);
  await shot('summary-result');
  // 目录浮钮：滚动中持续右上角；全部视图信息点默认收起
  assert.equal(await p.$$eval('#sum-render .pt.open', x => x.length), 0);
  await p.click('[data-testid="toc-btn"]');
  assert(await p.$eval('#toc-pop', x => !x.hidden));
  await p.click('#toc-pop button:nth-child(4)');
  assert(await p.$eval('#toc-pop', x => x.hidden));
  assert(await secVis('sec-todo') && await secVis('sec-ov'));
  await p.evaluate(() => window.scrollTo(0, 900));
  const sb = await p.$eval('#stickbar', x => x.getBoundingClientRect().top);
  assert(sb >= 46 && sb <= 60, '吸顶位置异常: ' + sb);
  const tb = await p.$eval('#toc-btn', x => x.getBoundingClientRect().top);
  assert(tb >= 90 && tb <= 118, '目录浮钮应悬于内容右上角且留出间距: ' + tb);
  assert.equal(await p.$eval('#stabs', x => getComputedStyle(x).borderBottomWidth), '1px');
  assert.equal(await p.$eval('#stabs', x => getComputedStyle(x).overflowX), 'auto');
  assert.equal(await p.$eval('.stabs button', x => getComputedStyle(x).whiteSpace), 'nowrap');
  // 窄屏下 tabs 溢出可横向滑动
  await p.setViewport({ width: 320, height: 844, deviceScaleFactor: 2 });
  await new Promise(r => setTimeout(r, 200));
  assert.equal(await p.$eval('#stabs', x => x.scrollWidth > x.clientWidth), true);
  await p.setViewport({ width: 390, height: 844, deviceScaleFactor: 2 });
  await new Promise(r => setTimeout(r, 200));

  // Tab 切换：概览单显；信息点展开 + 溯源跳转
  await p.click('#stabs button[data-st="ov"]');
  assert(await secVis('sec-ov') && !(await secVis('sec-map')));
  await p.click('#stabs button[data-st="pt"]');
  assert(await secVis('sec-pt') && !(await secVis('sec-ov')));
  // 信息点 tab：默认全部展开；可手动收起/再展开
  assert.equal(await p.$$eval('#sum-render .pt.open', x => x.length), 4);
  await p.click('#pt-0 .pt-h');
  assert(!(await p.$eval('#pt-0', x => x.classList.contains('open'))));
  await p.click('#pt-0 .pt-h');
  assert(await p.$eval('#pt-0', x => x.classList.contains('open') && x.querySelector('.pt-d').offsetParent !== null));
  assert((await p.$$('#pt-0 .srcchip')).length > 0);
  await shot('summary-render-todo');
  await p.click('#pt-0 .srcchip');
  assert(await p.$eval('#p-detail', x => x.classList.contains('show')));
  assert.equal(await p.$eval('#crumb-dest', x => x.innerText), '总结');
  assert.equal(await p.$eval('#pb-detail', x => getComputedStyle(x).display), 'none');
  // 详情页第三个 tab：被引用总结（>0 才显示）
  assert(await p.$eval('#dtab-refs', x => !x.hidden && x.innerText.includes('被引用总结 1')));
  await p.click('[data-testid="det-tab-refs"]');
  assert(await p.$eval('#dt-refs', x => x.style.display === 'block' && x.innerText.includes('项目排期与客户反馈')));
  await shot('detail-backlink');
  await p.click('[data-testid^="ref-"]');
  // 历史扁平化：该总结已在路由栈中 → 直接回到先前的总结（不纵深），面包屑即显示 Timeline
  assert(await p.$eval('#p-sumres', x => x.classList.contains('show')));
  assert.equal(await p.$eval('#crumb-dest', x => x.innerText), 'Timeline');
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
  assert(await p.$eval('#dev-main', x => x.innerText.includes('已连接') && x.innerText.includes('可录至') && x.innerText.includes('电量高')));
  assert.equal(await p.$$eval('#dev-main .row', x => x.length), 5);
  assert.equal(await p.$$eval('.batt', x => x.length), 2);
  assert.equal(await p.$$eval('.batt svg', x => x.length), 2);
  assert.equal(await p.$eval('.recval', x => getComputedStyle(x).display), 'inline-flex');
  assert.equal(await p.$$eval('#dev-main .actions', x => x.length), 0);
  assert(await p.$eval('#rec-clock', x => /^\d+:\d{2}:\d{2}$/.test(x.innerText)));
  const ck = await p.$eval('#rec-clock', x => x.innerText);
  const cw = await p.$eval('#rec-clock', x => x.offsetWidth);
  await new Promise(r => setTimeout(r, 1300));
  assert.notEqual(await p.$eval('#rec-clock', x => x.innerText), ck);
  assert.equal(await p.$eval('#rec-clock', x => x.offsetWidth), cw);
  assert(await p.$eval('#sync-rel', x => /刚刚|秒前|分钟前/.test(x.innerText)));
  assert.equal(await p.$$eval('#dev-main .syncico', x => x.length), 0);
  assert(await p.$eval('[data-testid="sync-now"]', x => x.innerText.includes('最近同步') && !!x.querySelector('.rowchev')));
  assert(await p.$eval('[data-testid="wifi-row"]', x => x.innerText.includes('已配置 · 2 个网络') && !!x.querySelector('.rowchev')));
  await shot('hardware-capsule');
  await p.click('[data-testid="sync-now"]');
  assert(await p.$eval('#sync-ico .spin', x => !!x));
  assert(await p.$eval('#sync-txt', x => x.innerText.includes('正在同步')));
  await new Promise(r => setTimeout(r, 1200));
  assert(await p.$eval('#sync-ico .okcheck', x => !!x));
  assert(await p.$eval('#sync-txt', x => x.innerText.includes('同步成功')));
  // 10 秒冷却：点击无效
  await p.click('[data-testid="sync-now"]');
  await new Promise(r => setTimeout(r, 400));
  assert(await p.$eval('#sync-ico .okcheck', x => !!x));
  await p.click('[data-testid="fw-update"]');
  assert(await p.$eval('#dev-upg', x => !x.hidden && x.innerText.includes('主控芯片') && x.innerText.includes('2.1.0 → 2.2.0') && x.innerText.includes('1.4.2 → 1.5.0')));
  await p.click('#upg-btn');
  assert(await p.$eval('#upg-back', x => x.disabled));
  assert(await p.$eval('#upg-warn', x => !x.hidden));
  // 更新中锁定：点空白处弹层不消失
  await p.click('#sheet .backdrop');
  assert(await p.$eval('#sheet', x => x.classList.contains('show')));
  await new Promise(r => setTimeout(r, 1200));
  assert(await p.$eval('#upg-stage', x => x.innerText.includes('主控芯片')));
  await p.waitForFunction(() => document.getElementById('upg-back') && document.getElementById('upg-back').disabled === false, { timeout: 15000 });
  assert.equal(await p.$eval('#fw-val', x => x.innerText.trim()), '已是最新');
  assert(await p.$eval('#dev-state', x => x.innerText.includes('已更新到 主控 2.2.0 / Wi-Fi 1.5.0')));
  // 同步冷却结束后恢复箭头
  await p.waitForFunction(() => document.querySelector('#sync-ico .rowchev'), { timeout: 13000 });
  assert(await p.$eval('#sync-txt', x => x.innerText.includes('最近同步')));
  // Wi-Fi 二级页：已保存置顶（前3+展开）→ 扫描 → 范围外置灰 → 直连 → 新网络保存
  await p.click('[data-testid="wifi-row"]');
  assert(await p.$eval('#dev-wifi', x => !x.hidden));
  assert.equal(await p.$$eval('#wsaved .witem', x => x.length), 3);
  assert(await p.$eval('#wmore', x => !x.hidden && x.innerText.includes('查看更多已保存')));
  assert(await p.$eval('#wstate', x => x.innerText.includes('正在扫描')));
  await p.waitForFunction(() => document.getElementById('wstate') && document.getElementById('wstate').textContent.includes('扫描完成'), { timeout: 8000 });
  assert.equal(await p.$$eval('#wsaved .witem.off', x => x.length), 2);
  assert.equal(await p.$$eval('#wlist .witem', x => x.length), 3);
  assert(await p.$eval('#dev-wifi', x => x.innerText.includes('2.4GHz')));
  // 直连已保存且在范围内的网络
  await p.click('#wsaved .witem:not(.off)');
  assert(await p.$eval('#wsaved', x => x.innerText.includes('正在连接')));
  await p.waitForFunction(() => document.getElementById('wstate') && document.getElementById('wstate').textContent.includes('连接成功'), { timeout: 8000 });
  // 新网络：输入密码 → 保存 → 连接并计数
  await p.click('[data-n="Office-2.4G"]');
  await new Promise(r => setTimeout(r, 200));
  await p.type('#wifi-pwd', 'demo-password');
  await p.click('[data-testid="wifi-connect"]');
  assert(await p.$eval('#wlist .wform', x => x.innerText.includes('正在验证')));
  await p.waitForFunction(() => document.getElementById('wstate') && document.getElementById('wstate').textContent.includes('Office-2.4G 连接成功'), { timeout: 8000 });
  assert(await p.$eval('#wlist', x => x.innerText.includes('已连接')));
  assert.equal(await p.$eval('#wifi-n', x => x.innerText), '5');
  await p.click('[data-testid="wifi-back"]');
  assert(await p.$eval('#dev-main', x => !x.hidden));
  assert(await p.$eval('[data-testid="wifi-row"]', x => x.innerText.includes('5 个网络')));
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
  // 宽屏：面包屑停用（恒显标题），栈底时无面板内返回
  assert.equal(await p.$eval('#crumb-back', x => getComputedStyle(x).display), 'none');
  assert(await p.$eval('#app-title', x => getComputedStyle(x).display !== 'none'));
  assert(await p.$eval('#pb-detail', x => x.hidden));
  await shot('wide-detail');
  await p.click('[data-testid="nav-timeline"]');
  assert(await p.$eval('#empty-pane', x => getComputedStyle(x).display === 'flex'));
  assert(await p.$eval('#p-detail', x => !x.classList.contains('show')));
  // 宽屏嵌套：生成总结 → 溯源进详情 → 面板内「‹ 返回总结」→ 再跳回栈内已有的总结（扁平化）
  await p.click('[data-testid="summary-start"]');
  await p.click('.rangebar .chip[data-r="week"]');
  await p.click('[data-testid="generate-summary"]');
  await p.waitForFunction(() => document.getElementById('sum-gen') && document.getElementById('sum-gen').hidden === true, { timeout: 15000 });
  assert(await p.$eval('#p-sumres', x => x.classList.contains('show')));
  assert(await p.$eval('#pb-sum', x => x.hidden));
  await p.click('#stabs button[data-st="src"]');
  await p.click('[data-testid="src-e1"]');
  assert(await p.$eval('#p-detail', x => x.classList.contains('show')));
  assert(await p.$eval('#pb-detail', x => !x.hidden && x.innerText.includes('返回总结')));
  await shot('wide-nested');
  await p.click('#pb-detail');
  assert(await p.$eval('#p-sumres', x => x.classList.contains('show')));
  await p.click('#stabs button[data-st="src"]');
  await p.click('[data-testid="src-e1"]');
  assert(await p.$eval('#p-detail', x => x.classList.contains('show')));
  await p.click('[data-testid="det-tab-refs"]');
  await p.click('[data-testid^="ref-"]');
  assert(await p.$eval('#p-sumres', x => x.classList.contains('show')));
  assert(await p.$eval('#pb-sum', x => x.hidden));
  // 直接点左侧列表（根上下文）→ 栈重置为单层，不出现「返回记录」
  await p.click('[data-testid="card-e4"]');
  await p.click('[data-testid="detail-e4"]');
  assert(await p.$eval('#p-detail', x => x.classList.contains('show')));
  assert(await p.$eval('#pb-detail', x => x.hidden));
  // 会话存储：刷新后右栏页面与总结卡保留
  await p.reload({ waitUntil: 'domcontentloaded' });
  await new Promise(r => setTimeout(r, 300));
  assert(await p.$eval('#p-detail', x => x.classList.contains('show')));
  assert(await p.$eval('#dt-h3', x => x.innerText.includes('发布窗口')));
  assert(await p.$eval('#pb-detail', x => x.hidden));
  await p.click('[data-testid="nav-timeline"]');
  assert(await p.$eval('#empty-pane', x => getComputedStyle(x).display === 'flex'));
  // sessionStorage 同标签页跨刷新保留：窄屏段 1 张 + 宽屏段 1 张
  assert.equal(await p.$$eval('.card[data-kind="summary"]', x => x.length), 2);

  assert.equal(errors.length, 0, errors.join(','));
  assert.equal(net.length, 0, net.join(','));
  console.log(JSON.stringify({ pass: true, viewport: '390x844 @2x + 900x1100', navigation: 2, errors, networkRequests: net, checks: ['fixed-chrome', 'crumb-root-hidden', 'two-line-card', 'expand-collapse', 'detail-entry', 'subpage-hides-nav', 'detail-tabs-raw', 'select-mode', 'tabs-lock-on-summary', 'action-card', 'range-today', 'range-week', 'range-month', 'tap-toggle', 'sumbar-rows', 'gen-status-view', 'generate-progress', 'sum-tabs', 'default-all-view', 'point-expand', 'point-trace', 'refs-tab', 'detail-backlink', 'history-flatten', 'src-tab-loop', 'export-sheet', 'filter', 'cancel-summary', 'setting-toggle', 'device-sheet', 'sheet-single-rows', 'battery-capsule', 'battery-row', 'clock-stable', 'row-inline-actions', 'rec-clock-tick', 'rel-sync', 'wifi-count', 'no-sim-labels', 'sync-now', 'sync-cooldown', 'two-stage-fw', 'fw-lock', 'wifi-setup', 'toc-float', 'tabs-sticky', 'pt-default-open', 'wide-two-pane', 'wide-list-stays', 'wide-crumb-off', 'pane-back', 'wide-flatten', 'fresh-from-list', 'session-restore', 'no-overflow'] }, null, 2));
  await b.close();
})().catch(e => { console.error(e); process.exit(1) });
