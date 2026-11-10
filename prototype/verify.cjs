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
  // 没连设备：灰点 + 电量位置改显「无设备」（文字替代电池图标，不给用户留疑问）
  assert(await p.$eval('[data-testid="hw-capsule"]', x => x.classList.contains('off')));
  assert(await p.$eval('[data-testid="hw-capsule"]', x => (x.getAttribute('aria-label') || '').includes('无设备')));
  assert(await p.$eval('[data-testid="capsule-nodata"]', x => x.innerText.trim() === '无设备'));
  assert(
    await p.$eval('[data-testid="capsule-nodata"]', x => getComputedStyle(x).display !== 'none'),
    '无设备时电量位置必须是「无设备」文字',
  );
  assert.equal(await p.$eval('.capsule .batt', x => getComputedStyle(x).display), 'none');
  assert(!(await p.$eval('[data-testid="hw-capsule"]', x => /\d/.test(x.innerText))));
  // feed 倒序：按日分组今天→昨天→更早；同一天内按时间从晚到早（不依赖数据源顺序）
  const feedGroups = await p.evaluate(() => {
    const groups = []; let cur = null;
    [...document.querySelectorAll('#feed > *')].forEach(el => {
      if (el.classList.contains('tl-date')) {
        cur = { day: el.textContent.trim(), times: [] };
        groups.push(cur);
      } else if (cur && el.classList.contains('tl-item')) {
        const card = el.querySelector('.card');
        const when = el.querySelector('.when');
        if (card && card.dataset.kind === 'event' && when) {
          cur.times.push(when.textContent.split('·')[0].trim());
        }
      }
    });
    return groups;
  });
  for (const g of feedGroups) {
    const mins = g.times.map(t => { const [h, m] = t.split(':').map(Number); return h * 60 + m; });
    for (let i = 1; i < mins.length; i++) {
      assert(mins[i - 1] >= mins[i], `${g.day} 内时间应倒序：${g.times.join(', ')}`);
    }
  }
  // 相册缩略图：每天最多两张带图记录；1 张单图、2 张层叠、>3 张第 4 层总数遮罩
  assert.equal(await p.$('[data-testid="pics-e1"]'), null, 'e1 今天不带图（今天最多 e2/e3 两张）');
  assert.equal(await p.$$eval('[data-testid="pics-e2"] .pthumb', x => x.length), 2);
  assert.equal(await p.$$eval('[data-testid="pics-e3"] .pthumb', x => x.length), 4);
  assert.equal(await p.$$eval('[data-testid="pics-e5"] .pthumb', x => x.length), 1);
  assert.equal(await p.$$eval('[data-testid="pics-e6"] .pthumb', x => x.length), 3);
  assert.equal(await p.$$eval('[data-testid="pics-e3"] .pthumb.count', x => x.length), 1);
  assert.equal(await p.$eval('[data-testid="pics-e3"] .pcount', x => x.textContent.trim()), '4');
  assert.equal(await p.$('[data-testid="pics-e6"] .pcount'), null);
  const thumbBox = await p.$eval('[data-testid="pics-e3"] .pthumb', x => { const r = x.getBoundingClientRect(); return { w: r.width, h: r.height }; });
  assert(Math.abs(thumbBox.w - thumbBox.h) < 0.5, '缩略图应为正方形');
  const stackH = await p.$eval('[data-testid="pics-e3"]', x => x.getBoundingClientRect().height);
  const textH = await p.$eval('[data-testid="card-e3"] .pc-text', x => x.getBoundingClientRect().height);
  assert(Math.abs(stackH - textH) <= 1, `缩略图应与标题时间同高：${stackH}/${textH}`);
  assert(await p.$eval('[data-testid="card-e3"] .pc-text h3', x => getComputedStyle(x).textOverflow === 'ellipsis' && getComputedStyle(x).whiteSpace === 'nowrap'));
  // 总结卡的图片计数（含 2 张 = e2 的两张）
  assert.equal(await p.$eval('[data-testid="card-sum-demo"] .sumphotos', x => x.textContent.trim()), '含 2 张图片');
  // 分组内倒序：日终产物（总结/日报/未归类）在顶部，记录中间，做梦卡在底部
  const dayKinds = await p.evaluate(() => {
    const out = []; let cur = null;
    [...document.querySelectorAll('#feed > *')].forEach(el => {
      if (el.classList.contains('tl-date')) { cur = { day: el.textContent.trim(), kinds: [] }; out.push(cur); }
      else if (cur) { const c = el.querySelector('.card'); if (c) cur.kinds.push(c.dataset.kind); }
    });
    return out;
  });
  assert.equal(dayKinds[0].day, '今天');
  assert.deepEqual(dayKinds[0].kinds.slice(0, 2), ['summary', 'unclassified'], '总结/未归类应在今天分组顶部');
  assert.equal(dayKinds[0].kinds[dayKinds[0].kinds.length - 1], 'dream', '做梦卡是当天最早事件，应在倒序分组底部');
  assert.equal(dayKinds[1].kinds[0], 'daily', '日报是当天最后产物，应在昨天分组顶部');
  assert(await p.$eval('[data-testid="card-dream-0"]', x => x.innerText.includes('做梦完成') && x.innerText.includes('知识库')));
  assert(await p.$eval('[data-testid="card-unc-0"]', x => x.innerText.includes('今日未归类图片') && x.innerText.includes('1 张')));
  assert(await p.$eval('[data-testid="card-daily-1"]', x => x.innerText.includes('昨日日报') && x.innerText.includes('自动生成')));
  assert.equal(await p.$('[data-testid="card-daily-0"]'), null, '今天已有手动总结，不应出现日报');
  const sumTop = await p.$eval('[data-testid="card-sum-demo"]', x => x.getBoundingClientRect().top);
  const e1Top = await p.$eval('[data-testid="card-e1"]', x => x.getBoundingClientRect().top);
  assert(sumTop < e1Top, '总结卡应在当天记录上方');
  // 日报可点开结果页
  await p.evaluate(() => document.querySelector('[data-testid="card-daily-1"]').click());
  assert(await p.$eval('#p-sumres', x => x.classList.contains('show')));
  assert(await p.$eval('#sum-title', x => x.innerText.includes('昨日日报')));
  await p.evaluate(() => goBack());
  await new Promise(r => setTimeout(r, 300));
  await shot('timeline-collapsed');

  // 详情：照片按时间插入对话流；标记「不属于本段」→ 外侧缩略图减少 + 移入未归类
  await p.click('[data-testid="card-e2"]');
  await p.click('[data-testid="detail-e2"]');
  assert(await p.$eval('#p-detail', x => x.classList.contains('show')));
  assert.equal(await p.$$eval('#dt-dlg .dphoto', x => x.length), 2);
  const flowKinds = await p.$$eval('#dt-dlg > *', els => els.map(el => el.classList.contains('dphoto') ? 'photo' : 'turn'));
  assert(flowKinds.includes('photo') && flowKinds[0] === 'turn', '照片应插在对话中间');
  await shot('detail-photo');
  await p.evaluate(() => document.querySelector('#dt-dlg .dphoto-x').click());
  assert.equal(await p.$$eval('#dt-dlg .dphoto', x => x.length), 1);
  assert.equal(await p.$$eval('[data-testid="pics-e2"] .pthumb', x => x.length), 1);
  assert.equal(await p.$eval('[data-testid="card-sum-demo"] .sumphotos', x => x.textContent.trim()), '含 1 张图片');
  assert.equal(await p.$eval('[data-testid="card-unc-0"] .unccount', x => x.textContent.trim()), '2 张');
  await p.evaluate(() => goBack());
  await new Promise(r => setTimeout(r, 300));

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
  // 原始数据顶部必须能回听：只播本机实收录音，断档如实提示，清理后只剩一行说明
  assert(
    await p.evaluate(() => document.getElementById('dt-raw').firstElementChild?.dataset.testid === 'raw-audio-player'),
    '播放器应是原始数据页的第一个元素',
  );
  assert(await p.$eval('[data-testid="raw-audio-state"]', x => x.innerText.includes('本机原始录音')));
  const rawTime = await p.$eval('[data-testid="raw-audio-time"]', x => x.innerText.trim());
  assert(/^00:00 \/ \d{2}:\d{2}$/.test(rawTime), '时长格式应为 mm:ss / mm:ss，实际 ' + rawTime);
  assert(!rawTime.endsWith('00:00'), '播放器应显示本段真实时长');
  // 播放控件是触控目标：不低于 44
  assert(await p.$eval('[data-testid="raw-audio-toggle"]', x => x.getBoundingClientRect().height >= 44));
  await p.click('[data-testid="raw-audio-toggle"]');
  await p.waitForFunction(
    (initial) => document.querySelector('[data-testid="raw-audio-time"]').innerText.trim() !== initial,
    { timeout: 3000 },
    rawTime,
  );
  await shot('detail-raw-audio');
  await p.click('[data-testid="raw-audio-delete"]');
  assert(await p.$eval('[data-testid="raw-audio-cleared"]', x => x.innerText.includes('原始录音已清理')));
  assert.equal(await p.$('[data-testid="raw-audio-player"]'), null, '清理后不应假装还能播');
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
  // 范围计数按页面同一套日期语义推导（周一/月初跑脚本时硬编码会过期）
  const expCount = async r => p.evaluate((r) => {
    const pred = r === 'today' ? (o) => o === 0
      : r === 'week' ? (o) => o <= (new Date().getDay() + 6) % 7
      : (o) => { const d = new Date(); d.setDate(d.getDate() - o); const n = new Date(); return d.getMonth() === n.getMonth() && d.getFullYear() === n.getFullYear(); };
    return EVENTS.filter(e => pred(e.off)).length;
  }, r);
  await p.click('.rangebar .chip[data-r="today"]');
  assert.equal(await checkedCount(), await expCount('today'));
  await p.click('.rangebar .chip[data-r="week"]');
  assert.equal(await checkedCount(), await expCount('week'));
  await p.click('.rangebar .chip[data-r="month"]');
  assert.equal(await checkedCount(), await expCount('month'));
  await p.click('.rangebar .chip[data-r="none"]');
  assert.equal(await checkedCount(), 0);
  await p.click('.rangebar .chip[data-r="week"]');
  assert.equal(await checkedCount(), await expCount('week'));
  assert.equal(await p.$eval('#sel-count2', x => x.innerText), '已选 ' + (await expCount('week')) + ' 项');
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

  // 总结卡：位置在它所总结内容的最早一条之后；整卡点击直接进结果页
  const anchorInfo = await p.evaluate(() => {
    const mins = t => { const [h, m] = (t || '0:0').split(':').map(Number); return h * 60 + m; };
    const s = summaries.find(x => x.state === 'done' && x.id !== 'sum-demo');
    const srcs = EVENTS.filter(e => (s.srcIds || []).includes(e.id));
    // 最新来源：日偏移最小、同日时间最晚；总结卡应在这条记录上方（分组顶部）
    srcs.sort((a, b) => (a.off - b.off) || (mins(b.time) - mins(a.time)));
    const anchor = srcs[0];
    const cardEl = document.querySelector('[data-testid="card-' + s.id + '"]');
    const anchorEl = anchor ? document.querySelector('[data-testid="card-' + anchor.id + '"]') : null;
    return {
      hasCards: !!cardEl && !!anchorEl,
      cardTop: cardEl ? cardEl.getBoundingClientRect().top : -1,
      anchorTop: anchorEl ? anchorEl.getBoundingClientRect().top : -1,
    };
  });
  assert(anchorInfo.hasCards, '总结卡或锚点记录不在 DOM');
  assert(anchorInfo.cardTop < anchorInfo.anchorTop, '总结卡应在最新来源记录上方（当天分组顶部）');
  // 点「刚生成的」总结卡（demo 卡也在这条 feed 里，不能按 first 点）
  const genSumId = await p.evaluate(() => summaries.find(s => s.state === 'done' && s.id !== 'sum-demo').id);
  await p.click(`[data-testid="card-${genSumId}"]`);
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
  // demo 卡常驻；这里只关心本次生成的卡是否被取消
  assert.equal(await p.$$eval('.card[data-kind="summary"]:not([data-id="sum-demo"])', x => x.length), 1);
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
  // 默认未连接：弹层先给「连接录音卡」引导，自动扫描；只列 DYJ 系列，按 RSSI 从强到弱
  assert(await p.$eval('#dev-connect', x => !x.hidden));
  assert(await p.$eval('#dev-main', x => x.hidden));
  assert(await p.$eval('#conn-sub', x => x.innerText.includes('扫描')));
  await p.waitForFunction(() => document.querySelectorAll('#conn-list .conn-item').length === 3, { timeout: 5000 });
  assert.deepEqual(await p.$$eval('#conn-list .cn', e => e.map(x => x.innerText.trim())), ['DYJV2_T4W25T', 'DYJV2_B7K9Q2', 'DYJV2_L3M8N1']);
  assert.equal(await p.$$eval('#conn-list .conn-item', e => e.length), 3, '非 DYJ 设备不应出现');
  await shot('device-connect');
  await p.click('#conn-list .conn-item');
  await p.waitForFunction(() => !document.getElementById('dev-main').hidden, { timeout: 5000 });
  assert(await p.$eval('[data-testid="hw-capsule"]', x => !x.classList.contains('off')));
  // 已连接未录音 = 橙点待机（绿点只代表正在录音）
  assert(await p.$eval('[data-testid="hw-capsule"]', x => x.classList.contains('idle')));
  assert.equal(await p.$eval('.capsule .dot', x => getComputedStyle(x).backgroundColor), 'rgb(255, 149, 0)');
  assert(await p.$eval('.capsule .batt', x => x.classList.contains('lv-hi') && getComputedStyle(x).display !== 'none'));
  // 连上后默认未录音；录音状态行本身就是开关
  assert(await p.$eval('#rec-off', x => getComputedStyle(x).display !== 'none' && x.innerText.includes('未录音')));
  assert.equal(await p.$eval('#rec-sw', x => x.getAttribute('aria-checked')), 'false');
  await p.click('[data-testid="rec-toggle"]');
  assert(await p.$eval('#recval', x => x.classList.contains('on')));
  assert.equal(await p.$eval('#rec-sw', x => x.getAttribute('aria-checked')), 'true');
  assert(!(await p.$eval('[data-testid="hw-capsule"]', x => x.classList.contains('idle'))));
  assert.equal(await p.$eval('.capsule .dot', x => getComputedStyle(x).backgroundColor), 'rgb(52, 199, 89)');
  assert(await p.$eval('#dev-main', x => x.innerText.includes('已连接') && x.innerText.includes('可录至') && x.innerText.includes('电量高')));
  assert.equal(await p.$$eval('#dev-main .row', x => x.length), 5);
  assert.equal(await p.$$eval('.batt', x => x.length), 2);
  assert.equal(await p.$$eval('.batt svg', x => x.length), 2);
  assert(['inline-flex', 'flex'].includes(await p.$eval('.recval', x => getComputedStyle(x).display)));
  assert.equal(await p.$$eval('#dev-main .actions', x => x.length), 0);
  assert(await p.$eval('#rec-clock', x => /^\d+:\d{2}:\d{2}$/.test(x.innerText)));
  const ck = await p.$eval('#rec-clock', x => x.innerText);
  const cw = await p.$eval('#rec-clock', x => x.offsetWidth);
  await new Promise(r => setTimeout(r, 1300));
  assert.notEqual(await p.$eval('#rec-clock', x => x.innerText), ck);
  assert.equal(await p.$eval('#rec-clock', x => x.offsetWidth), cw);
  assert(await p.$eval('#sync-rel', x => /刚刚|秒前|分钟前/.test(x.innerText)));
  assert.equal(await p.$$eval('#dev-main .syncico', x => x.length), 0);
  assert(await p.$eval('[data-testid="sync-now"]', x => x.innerText.includes('自动同步') && !!x.querySelector('.syncidle svg')));
  assert(await p.$eval('[data-testid="wifi-row"]', x => x.textContent.includes('已配置 · 2 个网络') && !!x.querySelector('.rowchev')));
  await shot('hardware-capsule');
  await p.click('[data-testid="sync-now"]');
  assert(await p.$eval('#sync-ico.spin svg', x => !!x));
  assert(await p.$eval('#sync-txt', x => x.innerText.includes('正在同步')));
  await new Promise(r => setTimeout(r, 1200));
  assert(await p.$eval('#sync-ico.okcheck', x => !!x));
  assert(await p.$eval('#sync-txt', x => x.innerText.includes('同步成功')));
  // 10 秒冷却：点击无效
  await p.click('[data-testid="sync-now"]');
  await new Promise(r => setTimeout(r, 400));
  assert(await p.$eval('#sync-ico.okcheck', x => !!x));
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
  await p.waitForFunction(() => document.querySelector('#sync-ico.syncidle'), { timeout: 13000 });
  assert(await p.$eval('#sync-txt', x => x.innerText.includes('手动同步')));
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
  assert(await p.$eval('[data-testid="wifi-row"]', x => x.textContent.includes('5 个网络')));
  await p.click('#dev-main > .btn:last-child');
  // 状态弹层是从 Setting 页打开的；先回 Timeline 再看记录顶部状态块
  await p.click('[data-testid="nav-timeline"]');

  // 录音中：Timeline 记录顶部有实时状态块（计时跟着走）
  assert(await p.$eval('#live-status', x => x.innerText.includes('正在录音') && !!x.querySelector('#live-clock')));
  // 停止录音：自动同步，状态块切「正在同步」并在完成后收起
  await p.click('[data-testid="hw-capsule"]');
  await new Promise(r => setTimeout(r, 200));
  await p.click('[data-testid="rec-toggle"]');
  assert.equal(await p.$eval('#rec-sw', x => x.getAttribute('aria-checked')), 'false');
  assert(await p.$eval('[data-testid="hw-capsule"]', x => x.classList.contains('idle')));
  await p.evaluate(() => closeSheet());
  await new Promise(r => setTimeout(r, 300));
  assert(await p.$eval('#live-status', x => x.innerText.includes('正在同步')));
  await p.waitForFunction(() => !document.getElementById('live-status'), { timeout: 6000 });
  // 勾选总结 / 总结 Tab 时不出现在记录顶部
  await p.click('[data-testid="hw-capsule"]');
  await new Promise(r => setTimeout(r, 200));
  await p.click('[data-testid="rec-toggle"]');
  await p.evaluate(() => closeSheet());
  await new Promise(r => setTimeout(r, 300));
  assert(await p.$eval('#live-status', x => x.innerText.includes('正在录音')));
  await p.click('[data-testid="summary-start"]');
  assert.equal(await p.$('#live-status'), null, '勾选总结时不应出现实时状态块');
  await p.click('#sumbar .btn.ghost');
  assert(await p.$eval('#live-status', x => x.innerText.includes('正在录音')));
  await p.click('[data-f="summary"]');
  assert.equal(await p.$('#live-status'), null, '总结 Tab 不应出现实时状态块');
  await p.click('[data-f="all"]');
  // 收尾：停止录音
  await p.click('[data-testid="hw-capsule"]');
  await new Promise(r => setTimeout(r, 200));
  await p.click('[data-testid="rec-toggle"]');
  await p.evaluate(() => closeSheet());
  await new Promise(r => setTimeout(r, 300));
  await p.waitForFunction(() => !document.getElementById('live-status'), { timeout: 6000 });

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
  // demo 卡每次初始化都会补回；这里验证 sessionStorage 里的两张生成卡
  assert.equal(await p.$$eval('.card[data-kind="summary"]:not([data-id="sum-demo"])', x => x.length), 2);

  assert.equal(errors.length, 0, errors.join(','));
  assert.equal(net.length, 0, net.join(','));
  console.log(JSON.stringify({ pass: true, viewport: '390x844 @2x + 900x1100', navigation: 2, errors, networkRequests: net, checks: ['fixed-chrome', 'crumb-root-hidden', 'feed-time-desc', 'photo-thumbs', 'photo-detail', 'daily-report', 'dream-card', 'two-line-card', 'expand-collapse', 'detail-entry', 'subpage-hides-nav', 'detail-tabs-raw', 'raw-audio-player', 'select-mode', 'tabs-lock-on-summary', 'action-card', 'range-today', 'range-week', 'range-month', 'tap-toggle', 'sumbar-rows', 'gen-status-view', 'generate-progress', 'sum-tabs', 'default-all-view', 'point-expand', 'point-trace', 'refs-tab', 'detail-backlink', 'history-flatten', 'src-tab-loop', 'export-sheet', 'filter', 'cancel-summary', 'setting-toggle', 'connect-default', 'capsule-nodata', 'scan-dyj-sorted', 'rec-default-off', 'rec-switch', 'device-sheet', 'sheet-single-rows', 'battery-capsule', 'battery-row', 'clock-stable', 'row-inline-actions', 'rec-clock-tick', 'rel-sync', 'wifi-count', 'no-sim-labels', 'sync-now', 'sync-cooldown', 'live-card', 'auto-sync', 'live-hide-summary', 'two-stage-fw', 'fw-lock', 'wifi-setup', 'toc-float', 'tabs-sticky', 'pt-default-open', 'wide-two-pane', 'wide-list-stays', 'wide-crumb-off', 'pane-back', 'wide-flatten', 'fresh-from-list', 'session-restore', 'no-overflow'] }, null, 2));
  await b.close();
})().catch(e => { console.error(e); process.exit(1) });
