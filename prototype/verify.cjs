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

  // 首页：固定高度顶栏、底栏（含居中凸起日出 AI 入口 OS1）、tab 文案、根页 crumb 隐藏
  assert.equal(await p.$$eval('nav.bottom button', e => e.length), 3);
  assert.deepEqual(await p.$$eval('nav.bottom button', e => e.map(x => x.innerText.trim())), ['Timeline', 'OS1', 'Setting']);
  const sunriseRise = await p.evaluate(() => {
    const navTop = document.querySelector('nav.bottom').getBoundingClientRect().top;
    const orbTop = document.querySelector('[data-testid="nav-ai-sunrise"] .ai-sunrise-orb').getBoundingClientRect().top;
    return navTop - orbTop;
  });
  assert(sunriseRise >= 14, '底部日出圆钮应高于底栏顶部 >=14px，实际 ' + sunriseRise);
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
  // 总结卡的图片计数：放在左下角时间与「已选 N 片段」之后（含 2 张 = e2 的两张），右侧仅保留箭头
  assert.equal(await p.$eval('[data-testid="card-sum-demo"] .sumphotos', x => x.textContent.trim()), '含 2 张图片');
  assert(await p.$eval('[data-testid="card-sum-demo"] .when', x => x.textContent.includes('已选 1 片段 · 含 2 张图片')));
  assert.equal(await p.$('[data-testid="card-sum-demo"] .sum-side .sumphotos'), null);
  // 分组内倒序：日终产物（总结/睡前日记/未归类）在顶部，记录中间，做梦卡在底部
  const dayKinds = await p.evaluate(() => {
    const out = []; let cur = null;
    [...document.querySelectorAll('#feed > *')].forEach(el => {
      if (el.classList.contains('tl-date')) { cur = { day: el.textContent.trim(), kinds: [] }; out.push(cur); }
      else if (cur) { const c = el.querySelector('.card'); if (c) cur.kinds.push(c.dataset.kind); }
    });
    return out;
  });
  assert.equal(dayKinds[0].day, '今天');
  assert.deepEqual(dayKinds[0].kinds.slice(0, 3), ['summary', 'daily', 'unclassified'], '总结/睡前日记/未归类应在今天分组顶部');
  assert.equal(dayKinds[0].kinds[dayKinds[0].kinds.length - 1], 'dream', '做梦卡是当天最早事件，应在倒序分组底部');
  assert.equal(dayKinds[1].kinds[0], 'daily', '睡前日记应在昨天分组顶部');
  assert(await p.$eval('[data-testid="card-dream-0"]', x => x.innerText.includes('做梦完成') && x.innerText.includes('知识库')));
  assert.equal(await p.$eval('[data-testid="tbc-dream"]', x => x.innerText.trim()), 'TBC');
  assert(await p.$eval('[data-testid="card-unc-0"]', x => x.innerText.includes('今日未归类图片') && x.innerText.includes('1 张')));
  assert.equal(await p.$('[data-testid="tbc-unc"]'), null, '未归类图片卡片本身已对齐上线，外层不再标 TBC');
  assert(await p.$eval('[data-testid="card-daily-0"]', x => x.innerText.includes('今日睡前日记') && x.innerText.includes('待标注 3')));
  assert(await p.$eval('[data-testid="card-daily-1"]', x => x.innerText.includes('昨日睡前日记') && x.innerText.includes('已标注')));
  assert.equal(await p.$eval('[data-testid="tbc-daily"]', x => x.innerText.trim()), 'TBC');
  assert.equal(await p.$('[data-testid="tbc-slice-merge"]'), null);
  assert.equal(await p.$('[data-testid="nc-btn"]'), null, '行为与健康信号已落地，index.html 不再展示 NC 胶囊');
  assert.equal(await p.$$eval('.nc-badge', x => x.length), 0, 'index.html 不再展示行为与健康信号 NC 徽标');
  assert(await p.$('[data-testid="set-health-location"]'), 'index.html 应包含定位与健康采集行');
  assert.equal(await p.$('[data-testid="nc-merge-panel"]'), null);
  assert(await p.$eval('[data-testid="ev-merge-badge-e1"]', x => x.innerText.includes('已合并 6 分片')));
  const sumTop = await p.$eval('[data-testid="card-sum-demo"]', x => x.getBoundingClientRect().top);
  const e1Top = await p.$eval('[data-testid="card-e1"]', x => x.getBoundingClientRect().top);
  assert(sumTop < e1Top, '总结卡应在当天记录上方');
  // 睡前日记：有趣叙事 + 点赞反馈 + 1~5 个待确认轻标注（点选后同步声纹与待标注计数）
  await p.evaluate(() => document.querySelector('[data-testid="card-daily-0"]').click());
  assert(await p.$eval('#p-diary', x => x.classList.contains('show')));
  assert(await p.$eval('#diary-title', x => x.innerText.includes('今日睡前日记')));
  const annotCnt = await p.$$eval('#diary-body [data-testid^="annot-card-"]', x => x.length);
  assert(annotCnt >= 1 && annotCnt <= 5, '睡前日记每次应提供 1~5 个待确认标注点，实际 ' + annotCnt);
  await p.click('[data-testid="diary-like-0"]');
  assert(await p.$eval('[data-testid="diary-like-0"]', x => x.classList.contains('on') && x.innerText.includes('已赞')));
  await p.click('[data-testid="annot-yes-0"]');
  assert(await p.$eval('[data-testid="diary-annot-prog"]', x => x.innerText.includes('已标注 1 / 3')));
  assert(await p.$eval('[data-testid="card-daily-0"]', x => x.innerText.includes('待标注 2')));
  assert.equal(await p.evaluate(() => SPEAKER_DB.s1.confirmed && SPEAKER_DB.s1.name), '老陈');
  await shot('bedtime-diary');
  await p.click('[data-testid="diary-sw-1"]');
  assert(await p.$eval('#diary-title', x => x.innerText.includes('昨日睡前日记')));
  await p.evaluate(() => goBack());
  await new Promise(r => setTimeout(r, 300));
  // 做梦卡：4~6 格天马行空梦境漫画（可切换无漫画常规夜保留每日总结）+ 重复事项提醒提炼 Skill + 记忆纠偏
  await p.evaluate(() => document.querySelector('[data-testid="card-dream-0"]').click());
  assert(await p.$eval('#dream-wrap', x => x.classList.contains('show')));
  const comicPanels = await p.$$eval('[data-testid="dream-comic"] .drm-panel svg', x => x.length);
  assert(comicPanels >= 4 && comicPanels <= 6, '做梦漫画应为 4~6 格，实际 ' + comicPanels);
  assert(await p.$eval('[data-testid="dream-repeat-card"]', x => x.innerText.includes('3 次') && x.innerText.includes('Skill')));
  await shot('dream-comic');
  await p.click('[data-testid="dream-mode-plain"]');
  assert.equal(await p.$('[data-testid="dream-comic"]'), null, '无漫画日不展示漫画格，但保留每日总结与 Skill');
  assert(await p.$('[data-testid="dream-repeat-card"]'));
  await p.click('[data-testid="dream-mode-comic"]');
  assert(await p.$('[data-testid="dream-comic"]'));
  assert.equal(await p.$$eval('#drm-body .drm-mem', x => x.length), 6);
  await p.click('[data-testid="dream-rm-0"]');
  assert.equal(await p.$$eval('#drm-body .drm-mem', x => x.length), 5);
  assert(await p.$eval('[data-testid="card-dream-0"]', x => x.innerText.includes('加入知识库 5 条')));
  await p.click('[data-testid="dream-skill-sw"]');
  assert(await p.$eval('[data-testid="card-dream-0"]', x => x.innerText.includes('提炼技能 0 个')));
  await p.click('[data-testid="dream-skill-sw"]');
  await p.evaluate(() => closeDreamSheet());
  await shot('timeline-collapsed');

  // 详情：照片按时间插入对话流；标记「不属于本段」→ 外侧缩略图减少 + 移入未归类
  await p.click('[data-testid="card-e2"]');
  await p.click('[data-testid="detail-e2"]');
  assert(await p.$eval('#p-detail', x => x.classList.contains('show')));
  assert.equal(await p.$$eval('#dt-dlg .dphoto', x => x.length), 2);
  const flowKinds = await p.$$eval('#dt-dlg > *', els => els.map(el => el.classList.contains('dphoto') ? 'photo' : 'turn'));
  assert(flowKinds.includes('photo') && flowKinds[0] === 'turn', '照片应插在对话中间');
  await shot('detail-photo');
  const exclBtnW = await p.$eval('#dt-dlg .dphoto-x', x => x.getBoundingClientRect().width);
  assert(exclBtnW > 40 && exclBtnW < 100, '「不属于本段」按钮应紧凑不拉伸，实际宽度 ' + exclBtnW);
  await p.evaluate(() => document.querySelector('#dt-dlg .dphoto-x').click());
  assert.equal(await p.$$eval('#dt-dlg .dphoto', x => x.length), 1);
  assert.equal(await p.$$eval('[data-testid="pics-e2"] .pthumb', x => x.length), 1);
  assert.equal(await p.$eval('[data-testid="card-sum-demo"] .sumphotos', x => x.textContent.trim()), '含 1 张图片');
  assert.equal(await p.$eval('[data-testid="card-unc-0"] .unccount', x => x.textContent.trim()), '2 张');
  await p.evaluate(() => goBack());
  await new Promise(r => setTimeout(r, 300));
  // 未归类图片卡：右下角提供「不归类」按钮；点击卡片进入双列正方形相册详情页查看或归类
  assert(await p.$('[data-testid="unc-dismiss-day-0"]'), '未归类图片卡片右下角应提供「不归类」按钮');
  await p.click('[data-testid="card-unc-0"]');
  assert(await p.$eval('#p-unc', x => x.classList.contains('show')));
  assert.equal(await p.$$eval('#uncp-body .unc-tile', x => x.length), 2);
  const uncSq = await p.$eval('#uncp-body .unc-sq', x => { const r = x.getBoundingClientRect(); return { w: r.width, h: r.height }; });
  assert(Math.abs(uncSq.w - uncSq.h) < 1.5, '未归类详情相册图片应为 1:1 正方形，实际 ' + uncSq.w + 'x' + uncSq.h);
  const uncCols = await p.$$eval('#uncp-body .unc-tile', els => new Set(els.map(e => Math.round(e.getBoundingClientRect().left))).size);
  assert.equal(uncCols, 2, '未归类详情页应为双列网格');
  await p.click('[data-testid="unc-reassign-e2-0-e2"]');
  assert.equal(await p.$$eval('#uncp-body .unc-tile', x => x.length), 1);
  assert.equal(await p.$eval('[data-testid="card-unc-0"] .unccount', x => x.textContent.trim()), '1 张');
  assert.equal(await p.$$eval('[data-testid="pics-e2"] .pthumb', x => x.length), 2);
  assert.equal(await p.$eval('[data-testid="card-sum-demo"] .sumphotos', x => x.textContent.trim()), '含 2 张图片');
  await p.evaluate(() => { goBack(); excludePhoto('e2', 0); });
  assert.equal(await p.$eval('[data-testid="card-unc-0"] .unccount', x => x.textContent.trim()), '2 张');

  // 卡片展开/收起 → 详情按钮进详情页（单屏压栈）
  await p.click('[data-testid="card-e1"]');
  assert(await p.$eval('[data-testid="card-e1"]', x => x.classList.contains('open')));
  await shot('timeline-expanded');
  await p.click('[data-testid="card-e1"]');
  assert(!(await p.$eval('[data-testid="card-e1"]', x => x.classList.contains('open'))));
  await p.click('[data-testid="card-e1"]');
  await p.$eval('[data-testid="detail-e1"]', x => x.scrollIntoView({ block: 'center' }));
  await p.click('[data-testid="detail-e1"]');
  assert(await p.$eval('#p-detail', x => x.classList.contains('show')));
  assert(!(await navVisible()));
  assert(await p.$eval('#crumb-back', x => getComputedStyle(x).display !== 'none' && x.innerText.includes('Timeline')));
  assert(await p.$eval('#dtab-refs', x => x.hidden));
  // 声纹标记 + 上下文呼语称呼消解（“老陈，你点什么喝的？”）+ 日间清洗三元记忆提取
  assert(await p.$eval('[data-testid="vp-infer-banner"]', x => x.innerText.includes('老陈') && x.innerText.includes('声纹簇已绑定')));
  assert(await p.$eval('[data-testid="turn-who-e1-1"]', x => x.innerText.includes('老陈') && x.innerText.includes('声纹已标')));
  assert(await p.$eval('[data-testid="turn-mark-e1"]', x => x.innerText.includes('单击重点 14:26')));
  assert(await p.$eval('[data-testid="dlg-mem-extract"]', x => x.innerText.includes('冰美式少冰') && x.innerText.includes('关系升格') && x.innerText.includes('可验证小方案')));
  await p.click('[data-testid="vp-card-s1"]');
  assert(await p.$eval('#spk-wrap', x => x.classList.contains('show')));
  assert(await p.$eval('#spk-body', x => x.innerText.includes('冰美式少冰') && x.innerText.includes('94%')));
  assert(await p.$('[data-testid="spk-detach-cur"]'), '声纹卡应提供单段防串音解绑入口');
  assert(await p.$('[data-testid="spk-merge-s2_e4"]'), '声纹卡应支持合并至已有声纹档案');
  assert(await p.$('[data-testid="spk-prov-e1"]'), '声纹卡应支持点击关联事件溯源原话');
  await p.click('[data-testid="spk-detach-cur"]');
  assert(await p.$eval('[data-testid="turn-who-e1-1"]', x => x.innerText.includes('本段已解绑')));
  await p.click('[data-testid="spk-detach-cur"]');
  assert(await p.$eval('[data-testid="turn-who-e1-1"]', x => x.innerText.includes('老陈')));
  await p.evaluate(() => resetSpeaker('s1'));
  assert(await p.$eval('[data-testid="vp-infer-banner"]', x => x.innerText.includes('上下文称呼推断') && x.innerText.includes('你点什么喝的')));
  await p.click('[data-testid="vp-confirm-s1"]');
  assert(await p.$eval('[data-testid="turn-who-e1-1"]', x => x.innerText.includes('老陈')));
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
  assert(await p.$('[data-testid="raw-audio-slider"]'));
  await p.click('[data-testid="rawline-e1-2"]');
  assert(await p.$eval('[data-testid="raw-audio-time"]', x => x.innerText.startsWith('06:0')));
  assert(await p.$eval('[data-testid="rawline-e1-2"]', x => x.classList.contains('active')));
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
  assert.deepEqual(await p.$$eval('#stabs button', e => e.map(x => x.innerText.trim())), ['全部', '概览', '逻辑结构', '信息点', '行动项', '全文', '来源记录']);
  assert(await secVis('sec-ov') && await secVis('sec-map') && await secVis('sec-pt') && await secVis('sec-todo') && await secVis('sec-ft') && await secVis('sec-src'));
  assert(await p.$eval('[data-testid="sum-fulltext-body"]', x => x.innerText.trim().length > 10));
  // 总结结果页图文穿插（不设独立多媒体模块）：概览自然穿插单张代表图；逻辑结构关联节点配线性 icon；信息点正文内联配图
  assert.equal(await p.$('[data-testid="sum-ov-photos"]'), null, '不应渲染独立多媒体模块框');
  assert(await p.$('[data-testid="sum-ov-inline-photo"]'), '概览下方应自然穿插有价值的代表图');
  assert.equal(await p.$('[data-testid="mleaf-pic-e2-0"]'), null, '已排除照片节点应自动降级为纯文字胶囊');
  assert(await p.$eval('[data-testid="mleaf-pic-e2-1"]', x => !!x.querySelector('svg') && !x.querySelector('img')));
  assert(await p.$eval('[data-testid="mleaf-pic-e3-1"]', x => !!x.querySelector('svg') && !x.querySelector('img')));
  assert.equal(await p.$('[data-testid="map-photo-legend"]'), null);
  assert.equal(await p.$('[data-testid="pt-picico-0"]'), null, 'e1 无照片，对应信息点不应出现图片图标');
  assert(await p.$('[data-testid="pt-picico-1"]'), 'e2 有照片，对应信息点标题应显示线性图片图标');
  assert(await p.$('[data-testid="pt-picico-3"]'), 'e3 10:14-10:15 对应信息点标题应显示线性图片图标');
  assert.equal(await p.$('[data-testid="pt-figs-0"]'), null);
  assert(await p.$('[data-testid="pt-figs-1"]'));
  assert(await p.$('[data-testid="pt-figs-3"]'));
  // 行动项按需元信息芯片（已标记声纹自动实名联动）+ 极简版切换
  assert.equal(await p.$('[data-testid="td-meta-0"]'), null, '无额外元信息的行动项应保持极简单行');
  assert(await p.$eval('[data-testid="td-who-1"]', x => x.innerText.includes('@老陈（声纹）')));
  assert(await p.$eval('[data-testid="td-who-2"]', x => x.innerText.includes('@说话人 2（推测）')));
  assert(await p.$eval('[data-testid="td-due-2"]', x => x.innerText.includes('周五前')));
  assert(await p.$eval('[data-testid="td-src-2"]', x => x.innerText.includes('14:31')));
  await p.click('[data-testid="todo-mode-plain"]');
  assert.equal(await p.$('[data-testid="td-meta-2"]'), null);
  await p.click('[data-testid="todo-mode-rich"]');
  assert(await p.$('[data-testid="td-meta-2"]'));
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
  assert.equal(await p.$eval('#dt-refs .refbox', x => getComputedStyle(x).borderTopWidth), '0px', '被引用总结列表外层不应再套边框');
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
  // 窄屏滚动到底部留白校验：结尾必须保留 >= 44px 呼吸空间
  const narrowSumBottomGap = await p.evaluate(() => {
    window.scrollTo(0, document.documentElement.scrollHeight);
    const items = [...document.querySelectorAll('#p-sumres .srclist .srcitem')];
    const last = items[items.length - 1];
    const gap = window.innerHeight - last.getBoundingClientRect().bottom;
    window.scrollTo(0, 0);
    return gap;
  });
  assert(narrowSumBottomGap >= 44, '窄屏总结结果页滚到底部必须保留留白 padding（>=44px），实际 ' + narrowSumBottomGap);
  await p.click('#stabs button[data-st="src"]');
  assert(await secVis('sec-src') && !(await secVis('sec-ov')));
  // 来源记录：单层卡片展示标题、时间时长，有图记录在左下元信息紧跟「含 N 张图片」
  assert.equal(await p.$('[data-testid="src-piccount-e1"]'), null, '无图记录不应展示图片计数');
  assert(await p.$eval('[data-testid="src-piccount-e2"]', x => x.innerText.includes('含 1 张图片')));
  assert(await p.$eval('[data-testid="src-piccount-e3"]', x => x.innerText.includes('含 4 张图片')));
  await p.click('[data-testid="src-e1"]');
  assert(await p.$eval('#p-detail', x => x.classList.contains('show')));
  await p.click('[data-testid="crumb-back"]');
  assert(await p.$eval('#p-sumres', x => x.classList.contains('show')));

  // 导出：4 种纯格式完整导出（含图文纪要与文字记录：默认 AI 智能优化版 / 可切原文，不包含标记说话人按钮）
  await p.click('[data-testid="export-btn"]');
  assert(await p.$eval('#export-pop', x => !x.hidden));
  assert.equal(await p.$('[data-testid="export-mark-speaker-btn"]'), null, '导出弹层不应展示标记说话人按钮');
  assert.deepEqual(await p.$$eval('#export-pop .export-fmt-btn', e => e.map(x => x.innerText.trim())), ['PDF', 'Word 文档', 'Markdown', '图片']);
  assert(await p.$eval('#exp-mode-ai', x => x.classList.contains('on')));
  await p.click('#exp-mode-raw');
  assert(await p.$eval('#exp-mode-raw', x => x.classList.contains('on')));
  await p.click('#exp-mode-ai');
  assert(await p.$eval('#exp-mode-ai', x => x.classList.contains('on')));
  await shot('summary-export');
  await p.click('[data-testid="export-fmt-PDF"]');
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

  // Setting 与录音卡状态页（含 App 反向同步的 V2 模型/提示词/扩展/隐私页，以及未实现项 TBC 标记）
  await p.click('[data-testid="nav-setting"]');
  await shot('setting');
  assert.equal(await p.$eval('[data-testid="tbc-sw-continuous"]', x => x.innerText.trim()), 'TBC');
  assert.equal(await p.$eval('[data-testid="tbc-sw-mark"]', x => x.innerText.trim()), 'TBC');
  assert.equal(await p.$('[data-testid="tbc-sw-wifi"]'), null, '仅使用 Wi-Fi 同步已在 App 实装，不再标 TBC');
  const sw = await p.$eval('#p-setting [aria-label="自动转录开关"]', x => x.getAttribute('aria-checked'));
  await p.click('#p-setting [aria-label="自动转录开关"]');
  assert.notEqual(await p.$eval('#p-setting [aria-label="自动转录开关"]', x => x.getAttribute('aria-checked')), sw);
  // 外脑 OAuth2 与微信/Google/GitHub/Facebook 绑定
  assert.equal(await p.$eval('[data-testid="sv-auth"]', x => x.innerText.trim()), 'owner@wainao.chat');
  await p.click('[data-testid="set-auth-entry"]');
  assert(await p.$('[data-testid="auth-wainao-card"]'));
  assert(await p.$('[data-testid="auth-signout-btn"]'));
  assert(await p.$('[data-testid="auth-bind-wechat"]'));
  assert(await p.$('[data-testid="auth-bind-apple"]'));
  assert(await p.$('[data-testid="auth-bind-google"]'));
  assert(await p.$('[data-testid="auth-bind-github"]'));
  assert(await p.$('[data-testid="auth-bind-facebook"]'));
  await p.click('[data-testid="auth-open-login-page"]');
  assert(await p.$eval('#login-gate', x => x.classList.contains('show')));
  assert(await p.$('[data-testid="login-submit"]'));
  assert(await p.$('[data-testid="login-wechat"]'));
  assert(await p.$('[data-testid="login-apple"]'));
  assert(await p.$('[data-testid="login-google"]'));
  await p.click('[data-testid="login-gate-close"]');
  assert.equal(await p.$eval('#login-gate', x => x.classList.contains('show')), false);
  await p.evaluate(() => {
    window.__prevPhotoState = { p: agCfg.photoPerm, a: agCfg.askedPhotoOnRec };
    startPhoneRec(false);
  });
  await p.click('[data-testid="auth-signout-btn"]');
  assert(await p.$eval('#signout-rec-wrap', x => x.classList.contains('show')));
  assert(await p.$eval('[data-testid="signout-recording-confirm-dialog"]', x => x.innerText.includes('自动关闭录音')));
  await p.click('[data-testid="signout-recording-cancel"]');
  assert.equal(await p.$eval('#signout-rec-wrap', x => x.classList.contains('show')), false);
  assert.equal(await p.evaluate(() => phoneRec.on && agCfg.auth), true);
  await p.click('[data-testid="auth-signout-btn"]');
  await p.click('[data-testid="signout-recording-confirm"]');
  assert.equal(await p.evaluate(() => phoneRec.on), false);
  assert.equal(await p.evaluate(() => agCfg.auth), false);
  await p.click('[data-testid="auth-signin-btn"]');
  assert.equal(await p.evaluate(() => agCfg.auth), true);
  await p.evaluate(() => {
    if (window.__prevPhotoState) {
      agCfg.photoPerm = window.__prevPhotoState.p;
      agCfg.askedPhotoOnRec = window.__prevPhotoState.a;
      delete window.__prevPhotoState;
    }
  });
  await p.click('[data-testid="crumb-back"]');
  // 本地语音三引擎：移除校验、就绪隐藏下载、右上角垃圾桶删除前必弹风险确认框
  await p.click('[data-testid="set-local-model"]');
  assert(await p.$eval('#p-setsub', x => x.classList.contains('show') && x.innerText.includes('本地转写已就绪') && x.innerText.includes('SenseVoice')));
  assert.equal(await p.$('[data-testid="local-verify-btn"]'), null);
  assert.equal(await p.$('[data-testid="model-install-all"]'), null);
  await p.click('[data-testid="model-delete-sensevoice-small-int8"]');
  assert(await p.$eval('#mdl-del-wrap', x => x.classList.contains('show')));
  assert(await p.$eval('[data-testid="model-delete-confirm-dialog"]', x => x.innerText.includes('付费云端模式') && x.innerText.includes('隐私')));
  await p.click('[data-testid="model-delete-confirm-btn"]');
  await p.waitForSelector('[data-testid="model-install-all"]', { timeout: 3000 });
  await p.click('[data-testid="model-install-all"]');
  await p.waitForFunction(() => document.getElementById('p-setsub').innerText.includes('本地转写已就绪'), { timeout: 4000 });
  await p.click('[data-testid="crumb-back"]');
  assert(await p.$eval('#p-setting', x => x.classList.contains('show')));
  // 云端模型极简模式 + 连击版本号 7 次解锁开发者模式
  assert.equal(await p.$eval('#sv-cloud', x => x.innerText.trim()), '已开启');
  await p.click('[data-testid="set-cloud-model"]');
  assert(await p.$('[data-testid="cloud-enable-switch"]'));
  assert(await p.$('[data-testid="cloud-custom-api-input"]'));
  assert.equal(await p.$('[data-testid="model-opt-qwen-max"]'), null);
  await p.click('[data-testid="crumb-back"]');
  for (let i = 0; i < 7; i++) {
    await p.click('[data-testid="setting-version"]');
  }
  assert.equal(await p.$eval('#lbl-version', x => x.innerText.trim()), '版本（开发者）');
  await p.click('[data-testid="set-cloud-model"]');
  await p.click('[data-testid="model-opt-qwen-max"]');
  assert(await p.$('[data-testid="temp-0.2"]'));
  assert.equal(await p.$eval('[data-testid="tbc-ctx-fullday"]', x => x.innerText.trim()), 'TBC');
  await p.click('[data-testid="crumb-back"]');
  assert.equal(await p.$eval('#sv-cloud', x => x.innerText.trim()), 'qwen-max');
  // 交叉反馈：每分钟自动关联系统相册照片（默认开启开关 + 关后重开弹权限弹窗）+ 灵动岛按机型隐藏
  assert.equal(await p.$eval('[data-testid="sw-photo-sync"]', x => x.getAttribute('aria-checked')), 'true');
  assert(await p.$eval('#sv-photo-imp', x => x.innerText.includes('每分钟随切片自动对齐')));
  await p.$eval('[data-testid="set-photo-import"]', x => x.scrollIntoView({ block: 'center' }));
  await p.click('[data-testid="set-photo-import"]');
  assert.equal(await p.$eval('[data-testid="sw-photo-sync"]', x => x.getAttribute('aria-checked')), 'false');
  assert(await p.$eval('#sv-photo-imp', x => x.innerText.includes('已关闭')));
  await p.$eval('[data-testid="set-photo-import"]', x => x.scrollIntoView({ block: 'center' }));
  await p.click('[data-testid="set-photo-import"]');
  assert(await p.$eval('#photo-perm-wrap', x => x.classList.contains('show')));
  assert(await p.$('[data-testid="photo-perm-dialog"]'));
  await p.click('[data-testid="photo-perm-grant"]');
  assert.equal(await p.$eval('[data-testid="sw-photo-sync"]', x => x.getAttribute('aria-checked')), 'true');
  assert(await p.$eval('#sv-photo-imp', x => x.innerText.includes('每分钟随切片自动对齐')));
  assert(await p.$eval('[data-testid="set-dynamic-island"]', x => !x.hidden));
  await p.$eval('[data-testid="toggle-island-hw"]', x => x.scrollIntoView({ block: 'center' }));
  await p.click('[data-testid="toggle-island-hw"]');
  assert(await p.$eval('[data-testid="set-dynamic-island"]', x => x.hidden));
  await p.$eval('[data-testid="toggle-island-hw"]', x => x.scrollIntoView({ block: 'center' }));
  await p.click('[data-testid="toggle-island-hw"]');
  assert(await p.$eval('[data-testid="set-dynamic-island"]', x => !x.hidden));
  await p.click('[data-testid="set-prompts"]');
  await p.click('[data-testid="preset-meeting"]');
  await p.click('[data-testid="prompt-save"]');
  await p.click('[data-testid="crumb-back"]');
  assert.equal(await p.$eval('#sv-preset', x => x.innerText.trim()), '深度会议');
  await p.click('[data-testid="set-extensions"]');
  assert.equal(await p.$eval('[data-testid="tbc-mcp"]', x => x.innerText.trim()), 'TBC');
  await p.click('[data-testid="sw-sk-risk"]');
  await p.click('[data-testid="crumb-back"]');
  assert.equal(await p.$eval('#sv-ext', x => x.innerText.trim()), '已启用 6 项');
  // 开发者设置（清洗周期 + 层叠重叠上下文 + 存量重洗）
  await p.click('[data-testid="set-developer"]');
  assert.equal(await p.$eval('[data-testid="dev-cycle-value"]', x => x.innerText.trim()), '10 分钟');
  await p.click('[data-testid="dev-cycle-preset-30"]');
  assert.equal(await p.$eval('[data-testid="dev-cycle-value"]', x => x.innerText.trim()), '30 分钟');
  await p.click('[data-testid="dev-overlap-mode-minutes"]');
  await p.click('[data-testid="dev-overlap-min-5"]');
  assert.equal(await p.$eval('[data-testid="dev-overlap-value"]', x => x.innerText.trim()), '5 分钟');
  await p.click('[data-testid="dev-reclean-btn"]');
  assert(await p.$eval('[data-testid="dev-reclean-status"]', x => x.innerText.includes('30 分钟')));
  await p.click('[data-testid="crumb-back"]');
  assert.equal(await p.$eval('#sv-developer', x => x.innerText.trim()), '每 30 分钟 · 叠 5分');
  await p.click('[data-testid="privacy-entry"]');
  assert(await p.$eval('#p-setsub', x => x.innerText.includes('privacy@reai.chat')));
  await p.click('[data-testid="crumb-back"]');
  // 三元记忆图谱（事件 / 可升格为点的关系 / 人·物·私有概念实体 + 不在场提及人保护 + 状态新陈代谢）
  await p.click('[data-testid="set-memory-graph"]');
  assert(await p.$eval('#p-setsub', x => x.classList.contains('show') && x.innerText.includes('《007黄金眼》') && x.innerText.includes('可验证小方案')));
  assert(await p.$eval('[data-testid="mg-mentioned-only"]', x => x.innerText.includes('未在场无声纹') && x.innerText.includes('防误绑保护')));
  assert(await p.$eval('[data-testid="mg-rel-upgraded"]', x => x.innerText.includes('升格关系点') && x.innerText.includes('老陈') && x.innerText.includes('当前生效')));
  assert(await p.$eval('[data-testid="mg-rel-archived"]', x => x.innerText.includes('历史归档')));
  await shot('memory-graph');
  await p.click('[data-testid="crumb-back"]');
  // 录音卡物理按键触发（单击 Mark / 长按灵动岛收听 + A/B 先后两条系统消息推送 / 双击暂空预留）
  await p.click('[data-testid="set-hw-button"]');
  assert(await p.$eval('#p-setsub', x => x.innerText.includes('单击') && x.innerText.includes('长按') && x.innerText.includes('双击')));
  await p.click('[data-testid="sub-trig-agent"]');
  assert(await p.$eval('#dyn-island', x => x.classList.contains('show') && x.innerText.includes('前几天看的电影是什么名字')));
  await p.waitForFunction(() => !!document.querySelector('[data-testid="agent-push-a"]'), { timeout: 4000 });
  assert(await p.$eval('[data-testid="agent-push-a"]', x => x.innerText.includes('我现在就去查一下')));
  await p.waitForFunction(() => !!document.querySelector('[data-testid="agent-push-b"]'), { timeout: 5000 });
  assert(await p.$eval('[data-testid="agent-push-b"]', x => x.innerText.includes('《007黄金眼》') && x.innerText.includes('9 月 5 日周三下午') && x.innerText.includes('爆米花')));
  await shot('agent-island-push');
  await p.click('[data-testid="push-dismiss"]');
  assert.equal(await p.$('[data-testid="agent-push-a"]'), null);
  assert(!(await p.evaluate(() => document.body.innerText.includes('模拟') || document.body.innerText.includes('演示'))));
  await p.click('[data-testid="crumb-back"]');
  assert.equal(await p.$$eval('.app-badge', x => x.length), 0, '已对齐项不应再展示不同步/已同步对比徽标');
  await p.click('[data-testid="parity-btn"]');
  assert(await p.$eval('#parity-wrap', x => x.classList.contains('show')));
  assert.equal(await p.$('#parity-tabs'), null, '清理后不再保留 App 超前对比分页');
  assert.equal(await p.$$eval('#parity-list .p-item', x => x.length), 12);
  await p.evaluate(() => closeParity());
  assert.equal(await p.$('[data-testid="nc-btn"]'), null, '行为与健康信号落地后不再保留 NC 胶囊');
  await p.click('[data-testid="hw-capsule"]');
  assert(await p.$eval('#sheet', x => x.classList.contains('show')));
  // 默认未连接：弹层先给连接引导，自动扫描三款自有硬件（DYJ* / REAI_VB_*），按 RSSI 从强到弱
  assert(await p.$eval('#dev-connect', x => !x.hidden));
  assert(await p.$eval('#dev-main', x => x.hidden));
  assert(await p.$eval('#conn-sub', x => x.innerText.includes('扫描')));
  await p.waitForFunction(() => document.querySelectorAll('#conn-list .conn-item').length === 3, { timeout: 5000 });
  assert.deepEqual(await p.$$eval('#conn-list .cn', e => e.map(x => x.innerText.trim())), ['T4W25T', 'B7K9Q2', 'L3M8N1']);
  assert.deepEqual(await p.$$eval('#conn-list .cbadge', e => e.map(x => x.innerText.trim())), ['录音卡 V2', '点一机 V1', '语音AI键盘 V2.1']);
  assert(await p.evaluate(() => {
    const items = [...document.querySelectorAll('#conn-list .conn-item')];
    const bgs = items.map(it => getComputedStyle(it.querySelector('.cbadge')).backgroundColor);
    const leftOk = items.every(it => it.querySelector('.cbadge').getBoundingClientRect().left < it.querySelector('.cn').getBoundingClientRect().left);
    return leftOk && new Set(bgs).size === 3;
  }), '产品徽章应置前且分色展示');
  assert.equal(await p.$$eval('#conn-list .conn-item', e => e.length), 3, '非自有硬件设备不应出现');
  // 未绑定硬件时，支持独立开启本机录音，胶囊展示「本机录音」且灵动岛展示 App Logo
  assert(await p.$('[data-testid="phone-rec-row"]'));
  await p.click('[data-testid="phone-rec-toggle"]');
  assert(await p.$eval('[data-testid="capsule-phone-rec"]', x => getComputedStyle(x).display !== 'none' && x.innerText.trim() === '本机录音'));
  assert(await p.$eval('#dyn-island', x => x.classList.contains('show') && !x.querySelector('[data-testid="di-app-logo"]').hidden));
  await p.click('[data-testid="phone-rec-toggle"]');
  assert(!(await p.$eval('#dyn-island', x => x.classList.contains('show'))));
  await shot('device-connect');
  await p.click('#conn-list .conn-item');
  await p.waitForFunction(() => !document.getElementById('dev-main').hidden, { timeout: 5000 });
  assert.equal(await p.$eval('#dev-name', x => x.innerText.trim()), 'T4W25T');
  assert(await p.evaluate(() => document.querySelector('[data-testid="dev-header-kind"]').getBoundingClientRect().left < document.getElementById('dev-name').getBoundingClientRect().left));
  assert(await p.$('[data-testid="dev-bt-icon"]'));
  assert(await p.$eval('[data-testid="dev-disconnect"]', x => getComputedStyle(x).borderStyle === 'none' || getComputedStyle(x).borderWidth === '0px'));
  assert.equal(await p.$('[data-testid="tbc-hw-wifi"]'), null, '硬件 Wi-Fi 配网已在 App 实装，不再标 TBC');
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
  // 已连硬件不展示本机录音行，且硬件蓝牙录音同样亮起灵动岛与锁屏实况提示
  assert.equal(await p.$('#dev-main [data-testid="phone-rec-main-row"]'), null, '已连硬件时不应显示本机录音开关行');
  assert(await p.$eval('#dyn-island', x => x.classList.contains('show') && !x.querySelector('[data-testid="di-app-logo"]').hidden && x.innerText.includes('蓝牙录音中') && x.innerText.includes('锁屏实况')));
  assert(!(await p.$eval('[data-testid="hw-capsule"]', x => x.classList.contains('idle'))));
  assert.equal(await p.$eval('.capsule .dot', x => getComputedStyle(x).backgroundColor), 'rgb(52, 199, 89)');
  assert.equal(await p.$('#dev-main .chip-ok'), null);
  assert(await p.$eval('#dev-sub', x => !x.innerText.includes('已连接') && !x.innerText.includes('可用') && x.innerText.includes('固件 2.1.0')));
  assert(await p.$eval('#dev-main', x => x.innerText.includes('可录至') && x.innerText.includes('电量高')));
  // 充电中闪电图标与呼吸效果（顶栏胶囊 + 弹层电量行）
  await p.click('[data-testid="toggle-charge-btn"]');
  assert.equal(await p.$$eval('.batt.charging [data-testid="batt-bolt"]', x => x.filter(el => getComputedStyle(el).display !== 'none').length), 2);
  await p.click('[data-testid="toggle-charge-btn"]');
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
  // 录音进行中点升级：弹出确认弹窗，确认后停硬件录音、自动切本机录音（灵动岛显示 App Logo），升级完成后关闭本机录音
  await p.click('#upg-btn');
  assert(await p.$eval('[data-testid="ota-rec-confirm-dialog"]', x => !x.hidden && x.innerText.includes('当前正在录音')));
  assert.equal(await p.$eval('#upg-back', x => x.disabled), false);
  await p.click('[data-testid="ota-rec-confirm"]');
  await new Promise(r => setTimeout(r, 120));
  assert(await p.evaluate(() => phoneRec.on === true && rec.on === false));
  assert(await p.$eval('#dyn-island', x => x.classList.contains('show') && !x.querySelector('[data-testid="di-app-logo"]').hidden));
  assert(await p.$eval('#upg-back', x => x.disabled));
  assert(await p.$eval('#upg-warn', x => !x.hidden));
  // 更新中锁定：点空白处弹层不消失
  await p.click('#sheet .backdrop');
  assert(await p.$eval('#sheet', x => x.classList.contains('show')));
  await new Promise(r => setTimeout(r, 1200));
  assert(await p.$eval('#upg-stage', x => x.innerText.includes('主控芯片')));
  await p.waitForFunction(() => document.getElementById('upg-back') && document.getElementById('upg-back').disabled === false, { timeout: 15000 });
  assert(await p.evaluate(() => phoneRec.on === false));
  assert.equal(await p.$eval('#fw-val', x => x.innerText.trim()), '已是最新');
  assert(await p.$eval('#dev-state', x => x.innerText.includes('已更新到 主控 2.2.0 / Wi-Fi 1.5.0')));
  // 同步冷却结束后恢复箭头，再开启录音以验收 Timeline 顶部实时状态块
  await p.waitForFunction(() => document.querySelector('#sync-ico.syncidle'), { timeout: 13000 });
  assert(await p.$eval('#sync-txt', x => x.innerText.includes('手动同步')));
  await p.click('[data-testid="rec-toggle"]');
  // Wi-Fi 二级页：已保存置顶（前3+展开）→ 扫描 → 范围外置灰 → 直连 → 新网络保存
  await p.click('[data-testid="wifi-row"]');
  assert(await p.$eval('#dev-wifi', x => !x.hidden));
  assert.equal(await p.$('#dev-wifi .tbc-badge'), null);
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
  await p.$eval('[data-testid="detail-e1"]', x => x.scrollIntoView({ block: 'center' }));
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
  // 宽屏滚动到底部留白校验：修复前 height:100% 会导致溢出后底部 padding 丢失（间距=0）
  await p.click('#stabs button[data-st="all"]');
  const wideSumBottomGap = await p.evaluate(() => {
    const sc = document.getElementById('sidecol');
    sc.scrollTop = sc.scrollHeight;
    const scRect = sc.getBoundingClientRect();
    const items = [...document.querySelectorAll('#p-sumres .srclist .srcitem')];
    const last = items[items.length - 1];
    return scRect.bottom - last.getBoundingClientRect().bottom;
  });
  assert(wideSumBottomGap >= 44, '宽屏总结结果页滚到底部必须保留留白 padding（>=44px），实际 ' + wideSumBottomGap);
  const wideTlBottomGap = await p.evaluate(() => {
    const rc = document.getElementById('rootcol');
    rc.scrollTop = rc.scrollHeight;
    const rcRect = rc.getBoundingClientRect();
    const cards = [...document.querySelectorAll('#p-timeline #feed .card')];
    const last = cards[cards.length - 1];
    return rcRect.bottom - last.getBoundingClientRect().bottom;
  });
  assert(wideTlBottomGap >= 44, '宽屏 Timeline 滚到底部必须保留留白 padding（>=44px），实际 ' + wideTlBottomGap);
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

  // 目标版三项新特性（TBC）：1) GPS 圈地运动；2) 睡眠 × 心率/HRV 对话情绪标定；3) 底部日出 AI 空间（Her OS1 + 有人味轻聊）
  await p.setViewport({ width: 390, height: 844, deviceScaleFactor: 2 });
  await p.click('[data-testid="nav-timeline"]');
  assert(await p.$eval('[data-testid="territory-card"]', x => !x.hidden && x.innerText.includes('老陈') && x.innerText.includes('TBC')));
  await p.click('[data-testid="territory-card"]');
  assert(await p.$eval('#territory-wrap', x => x.classList.contains('show')));
  assert(await p.$eval('[data-testid="tr-zone-today"]', x => x.tagName.toLowerCase() === 'polygon'));
  assert.equal(await p.$eval('[data-testid="tr-fast-route"] path', x => x.getAttribute('fill')), 'none', '高速骑行/驾车路段只画虚线，不填充圈地');
  assert(await p.$eval('[data-testid="tr-total-area"]', x => x.innerText.includes('0.42 km²')));
  const sw0 = await p.$eval('[data-testid="tr-path-afternoon"]', x => parseFloat(x.getAttribute('stroke-width')));
  await p.click('[data-testid="tr-walk-plus-btn"]');
  await p.click('[data-testid="tr-walk-plus-btn"]');
  const sw2 = await p.$eval('[data-testid="tr-path-afternoon"]', x => parseFloat(x.getAttribute('stroke-width')));
  assert(sw2 > sw0, `同路径走得越多线条应越粗: ${sw0} -> ${sw2}`);
  await p.click('[data-testid="tr-color-sky"]');
  await p.$eval('[data-testid="territory-sign-inp"]', el => { el.value = '陈哥'; el.dispatchEvent(new Event('input', { bubbles: true })); });
  await p.click('[data-testid="tr-close-loop-btn"]');
  assert(await p.$eval('[data-testid="tr-zone-afternoon"]', x => x.tagName.toLowerCase() === 'polygon' && x.getAttribute('fill') === '#2563EB'));
  assert(await p.$eval('[data-testid="tr-total-area"]', x => x.innerText.includes('陈哥 · 0.69 km²')));
  await shot('territory-map');
  await p.evaluate(() => closeTerritorySheet());

  await p.evaluate(() => openDetail('e1', true));
  assert(await p.$eval('#dt-bio-box', x => !x.hidden));
  assert(await p.$eval('[data-testid="bio-sleep-baseline"]', x => x.innerText.includes('深睡') && x.innerText.includes('HRV 48ms')));
  assert(await p.$('[data-testid="bio-chart-svg"]'));
  assert(await p.$eval('[data-testid="turn-bio-e1-3"]', x => x.innerText.includes('静坐 0 步/分') && x.innerText.includes('情绪波动') && x.innerText.includes('HRV 22ms')));
  assert(await p.$eval('[data-testid="turn-bio-e1-6"]', x => x.innerText.includes('106 步/分') && x.innerText.includes('非情绪')));
  await shot('bio-emotion-detail');
  await p.click('[data-testid="crumb-back"]');

  await p.click('[data-testid="nav-ai-sunrise"]');
  assert(await p.$eval('#ai-space', x => x.classList.contains('show')));
  assert(await p.$eval('#ai-her-pane', x => !x.hidden), '日出 AI 默认进入《Her》OS1 沉浸通话形态');
  assert(await p.$eval('#ai-chat-pane', x => x.hidden));
  await p.click('[data-testid="ai-her-prompt-mood"]');
  await new Promise(r => setTimeout(r, 360));
  const herPixels = await p.$eval('[data-testid="ai-her-canvas"]', cv => {
    const ctx = cv.getContext('2d').getImageData(0, 0, cv.width, cv.height).data;
    let cnt = 0; for (let i = 3; i < ctx.length; i += 16) if (ctx[i] > 20) cnt++;
    return cnt;
  });
  assert(herPixels > 50, '《Her》OS1 蠕动声波条纹圆环应正常绘制');
  assert((await p.$$eval('#ai-her-emojis .her-emoji', els => els.length)) >= 1, '情绪起伏应冒出无声小心思 emoji');
  await shot('ai-her-os1');

  await p.click('[data-testid="ai-mode-chat"]');
  assert(await p.$eval('#ai-chat-pane', x => !x.hidden));
  await p.click('[data-testid="ai-quick-1"]');
  await new Promise(r => setTimeout(r, 220));
  assert(await p.$('[data-testid="ai-typing-bubble"]'), '工作时仅显示极简 typing 省略点');
  const latestReact = await p.$$eval('.ai-msg.me .ai-react', els => els[els.length - 1].innerText);
  assert(latestReact.includes('get'), '发出任务后应实时贴上轻确认反应徽章: ' + latestReact);
  const chatTxtBusy = await p.$eval('#ai-chat-pane', x => x.innerText);
  assert(!chatTxtBusy.includes('思考过程') && !chatTxtBusy.includes('调用工具'), '轻聊不应展示冰冷工具/思考链');
  await new Promise(r => setTimeout(r, 600));
  assert.equal(await p.$('[data-testid="ai-typing-bubble"]'), null);
  await shot('ai-human-chat');
  await p.click('[data-testid="ai-space-close"]');
  assert(!(await p.$eval('#ai-space', x => x.classList.contains('show'))));

  // 行为与健康信号已从 NC 落地；目标版仍保留圈地与生理信号的 TBC 入口
  await p.click('[data-testid="nav-setting"]');
  assert(await p.$('[data-testid="set-health-location"]'));
  await p.click('[data-testid="set-health-location"]');
  assert(await p.$('[data-testid="health-sync-switch"]'));
  assert.equal(await p.$$eval('#p-setsub .nc-badge', x => x.length), 0);
  assert(await p.$('[data-testid="health-to-territory"]'), '目标版保留 GPS 圈地 TBC');
  assert(await p.$('[data-testid="health-to-bio-detail"]'), '目标版保留生理信号 TBC');
  await p.click('[data-testid="crumb-back"]');

  // 当前版本基线（current.html · App 已有功能）：零 TBC 标记、保持两栏底栏、无日出 AI 与目标版新项
  const pCur = await b.newPage();
  await pCur.setViewport({ width: 390, height: 844, deviceScaleFactor: 2 });
  pCur.on('pageerror', e => errors.push('current.html: ' + e.message));
  pCur.on('request', r => { if (!r.url().startsWith('file:') && !r.url().startsWith('data:')) net.push(r.url()) });
  await pCur.goto(pathToFileURL(path.join(__dirname, 'current.html')).href);
  assert.equal(await pCur.title(), '当前版本 · 录音卡（App 已有功能）');
  assert.equal(await pCur.$eval('[data-testid="parity-btn"]', x => x.innerText.trim()), '当前版');
  assert.equal(await pCur.$eval('[data-testid="ver-switch-target"]', x => x.getAttribute('href')), 'index.html');
  assert.equal(await p.$eval('[data-testid="ver-switch-current"]', x => x.getAttribute('href')), 'current.html');
  assert.equal(await pCur.$$eval('.tbc-badge', x => x.length), 0, 'current.html 不应出现 TBC 标记');
  assert.deepEqual(await pCur.$$eval('nav.bottom button', e => e.map(x => x.innerText.trim())), ['Timeline', 'Setting'], 'current.html 保持两枚底部 Tab，不含目标版 OS1 入口');
  assert.equal(await pCur.$('[data-testid="nav-ai-sunrise"]'), null);
  assert.equal(await pCur.$('[data-testid="nc-btn"]'), null, 'current.html 行为与健康信号已落地，不再展示 NC 胶囊');
  assert.equal(await pCur.$$eval('.nc-badge', x => x.length), 0, 'current.html 不再展示 NC 徽标');
  assert.equal(await pCur.$$eval('.card[data-kind="daily"], .card[data-kind="dream"]', x => x.length), 0);
  assert(!(await pCur.evaluate(() => document.body.innerText.includes('模拟') || document.body.innerText.includes('演示'))));
  // 验证当前版同样具备：总结卡左下图片数、未归类双列正方形详情页与「不归类」按钮、总结正文自然穿插配图
  assert(await pCur.$eval('[data-testid="card-sum-demo"] .when', x => x.textContent.includes('已选 1 片段 · 含 2 张图片')));
  await pCur.click('[data-testid="card-unc-0"]');
  assert(await pCur.$eval('#p-unc', x => x.classList.contains('show')));
  assert.equal(await pCur.$$eval('#uncp-body .unc-tile', x => x.length), 1);
  await pCur.click('[data-testid="crumb-back"]');
  await pCur.click('[data-testid="unc-dismiss-day-0"]');
  assert.equal(await pCur.$('[data-testid="card-unc-0"]'), null, '点击卡片右下角「不归类」后未归类卡片应收起');
  await pCur.click('[data-testid="card-sum-demo"]');
  assert(await pCur.$('[data-testid="sum-ov-inline-photo"]'));
  assert(await pCur.$('[data-testid="mleaf-pic-e2-0"]'));
  assert(await pCur.$('[data-testid="pt-figs-0"]'));
  assert.deepEqual(await pCur.$$eval('#stabs button', e => e.map(x => x.innerText.trim())), ['全部', '概览', '逻辑结构', '信息点', '行动项', '全文', '来源记录']);
  assert(await pCur.$eval('[data-testid="sum-fulltext-body"]', x => x.innerText.trim().length > 10));
  assert.equal(await pCur.$('[data-testid="sum-mark-speaker-btn"]'), null, '全文直接点击说话人命名，不再展示复杂按钮');
  assert.equal(await pCur.$('[data-testid="nc-ft-merge"]'), null);
  // 全文同说话人连续发言应合并为单段整段（e2 共 5 条 dlg，首两条均为说话人 2，合并后为 4 组）
  assert.equal(await pCur.$$eval('#sec-ft [data-testid^="sum-ft-group-e2-"]', e => e.length), 4);
  assert(await pCur.$eval('[data-testid="sum-ft-group-e2-0"]', x => x.innerText.includes('偏慢') && x.innerText.includes('两三秒')));
  assert.equal(await pCur.$$eval('#export-pop .export-fmt-btn', e => e.length), 4);
  assert(await pCur.$eval('#exp-mode-ai', x => x.classList.contains('on')));
  assert.equal(await pCur.$('[data-testid="export-mark-speaker-btn"]'), null, '导出弹层不应出现标记说话人按钮');
  // 点击全文说话人弹出极简命名弹窗（记住声音、同改其余 X 处、最近 5 个名称、可能为他提示）
  await pCur.click('[data-testid="sum-ft-who-e2-0"]');
  assert(await pCur.$eval('#spk-quick-wrap', x => x.classList.contains('show')));
  assert(await pCur.$eval('[data-testid="qspk-fuzzy-hint"]', x => x.innerText.includes('可能为') && x.innerText.includes('张总')));
  assert.equal(await pCur.$eval('[data-testid="qspk-chk-remember"]', x => x.checked), true);
  assert.equal(await pCur.$eval('[data-testid="qspk-chk-batch"]', x => x.checked), true);
  assert.equal(await pCur.$eval('[data-testid="qspk-other-cnt"]', x => x.textContent.trim()), '2');
  assert.equal(await pCur.$$eval('[data-testid="qspk-recent-list"] .qspk-chip', e => e.length), 5);
  // 取消勾选「同时修改其他 X 处」时，只修改当前这 1 处
  await pCur.click('[data-testid="qspk-chk-batch"]');
  await pCur.$eval('[data-testid="qspk-name-inp"]', x => { x.value = '陈总'; x.dispatchEvent(new Event('input', { bubbles: true })); });
  await pCur.click('[data-testid="qspk-save-btn"]');
  assert(!(await pCur.$eval('#spk-quick-wrap', x => x.classList.contains('show'))));
  assert.equal(await pCur.$$eval('#sec-ft [data-testid^="sum-ft-group-e2-"]', e => e.length), 5, '只改首句后与次句说话人不同应拆开');
  assert(await pCur.$eval('[data-testid="sum-ft-who-e2-0"]', x => x.innerText.includes('陈总')));
  assert(await pCur.$eval('[data-testid="sum-ft-who-e2-1"]', x => x.innerText.includes('说话人 2')));
  // 再次勾选「同时修改其他 X 处」并用「可能为：张总」快捷填入
  await pCur.click('[data-testid="sum-ft-who-e2-1"]');
  await pCur.click('[data-testid="qspk-apply-hint"]');
  assert.equal(await pCur.$eval('[data-testid="qspk-name-inp"]', x => x.value), '张总');
  await pCur.click('[data-testid="qspk-save-btn"]');
  assert.equal(await pCur.$$eval('#sec-ft [data-testid^="sum-ft-group-e2-"]', e => e.length), 4);
  assert(await pCur.$eval('[data-testid="sum-ft-who-e2-0"]', x => x.innerText.includes('张总')));
  assert(await pCur.evaluate(() => diClockHTML(3660).includes('di-colon') && diClockHTML(3661).includes('dim')));
  await pCur.click('[data-testid="crumb-back"]');
  // 验证「当前版」已落地清单、合并分片徽标及声纹管理（5 常用槽位含我的声音+单独录音 / 不限人数人物库）
  assert.equal(await pCur.$eval('[data-testid="ver-switch-target"]', x => x.innerText.trim()), '目标版·12');
  assert.equal(await pCur.$('[data-testid="nc-btn"]'), null, 'current.html 不再保留 NC 待确认胶囊');
  await pCur.click('[data-testid="parity-btn"]');
  assert(await pCur.$eval('#parity-wrap', x => x.classList.contains('show')));
  assert((await pCur.$$eval('#parity-list .p-item', x => x.length)) >= 9);
  await pCur.evaluate(() => closeParity());
  assert(await pCur.$eval('[data-testid="ev-merge-badge-e1"]', x => x.innerText.includes('已合并 6 分片')));
  await pCur.click('[data-testid="nav-setting"]');
  await pCur.evaluate(() => { agCfg.local.spk = 'none'; syncSetSummary(); });
  await pCur.$eval('[data-testid="set-voiceprint"]', x => x.scrollIntoView({ block: 'center' }));
  await pCur.click('[data-testid="set-voiceprint"]');
  assert(await pCur.$('[data-testid="voiceprint-install-btn"]'));
  await pCur.click('[data-testid="voiceprint-install-btn"]');
  await pCur.waitForFunction(() => agCfg.local.spk === 'ready', { timeout: 3000 });
  assert.equal(await pCur.$('[data-testid="voiceprint-install-btn"]'), null);
  assert.equal(await pCur.$$eval('[data-testid="vp-frequent-section"] .vp-slot', e => e.length), 5);
  assert(await pCur.$eval('[data-testid="vp-slot-1"]', x => x.innerText.includes('我的声音') && x.innerText.includes('3 组样本')));
  await pCur.click('[data-testid="vp-record-self-btn"]');
  await pCur.waitForFunction(() => document.querySelector('[data-testid="vp-record-countdown-dialog"]'), { timeout: 2000 });
  await pCur.waitForFunction(() => document.querySelector('[data-testid="vp-slot-1"]').innerText.includes('4 组样本'), { timeout: 6000 });
  assert(await pCur.$('[data-testid^="vp-sample-"]'), '录音样本应为可点胶囊条');
  assert((await pCur.$$eval('[data-testid="vp-library-section"] [data-testid^="vp-lib-person-"]', e => e.length)) >= 7, '人物库人数应大于 5（无上限）');
  await pCur.click('[data-testid="crumb-back"]');
  await pCur.$eval('[data-testid="set-developer"]', x => x.scrollIntoView({ block: 'center' }));
  await pCur.click('[data-testid="set-developer"]');
  await pCur.click('[data-testid="dev-cycle-preset-60"]');
  await pCur.click('[data-testid="dev-overlap-para-5"]');
  await pCur.click('[data-testid="dev-reclean-btn"]');
  assert(await pCur.$eval('[data-testid="dev-reclean-status"]', x => x.innerText.includes('1 小时')));
  await pCur.click('[data-testid="crumb-back"]');
  assert.equal(await pCur.$eval('#sv-developer', x => x.innerText.trim()), '每 1 小时 · 叠 5段');
  await pCur.$eval('[data-testid="set-auth-entry"]', x => x.scrollIntoView({ block: 'center' }));
  await pCur.click('[data-testid="set-auth-entry"]');
  await pCur.click('[data-testid="auth-open-login-page"]');
  assert(await pCur.$eval('#login-gate', x => x.classList.contains('show')));
  await pCur.click('[data-testid="login-apple"]');
  assert.equal(await pCur.$eval('#login-gate', x => x.classList.contains('show')), false);
  // 当前版验证：连接硬件后不显示本机录音行；硬件蓝牙录音同步点亮灵动岛/锁屏实况并挂起待命；蓝牙意外断开自动开启本机保底录音
  await pCur.click('[data-testid="hw-capsule"]');
  await pCur.waitForFunction(() => document.querySelectorAll('#conn-list .conn-item').length === 3, { timeout: 5000 });
  assert(await pCur.$('[data-testid="phone-rec-row"]'), '未连硬件时应显示独立本机录音行');
  await pCur.click('#conn-list .conn-item');
  await pCur.waitForFunction(() => !document.getElementById('dev-main').hidden, { timeout: 5000 });
  assert.equal(await pCur.$('#dev-main [data-testid="phone-rec-main-row"]'), null, 'current.html 已连硬件不应显示本机录音行');
  await pCur.click('[data-testid="rec-toggle"]');
  assert.deepEqual(await pCur.evaluate(() => ({ hw: rec.on, phone: phoneRec.on, standby: phoneRec.standby })), { hw: true, phone: false, standby: true });
  assert(await pCur.$eval('#dyn-island', x => x.classList.contains('show') && x.innerText.includes('蓝牙录音中') && x.innerText.includes('锁屏实况')));
  await pCur.click('[data-testid="hw-unexpected-drop-btn"]');
  await pCur.waitForFunction(() => !conn.retrying && !conn.connected, { timeout: 4000 });
  assert.deepEqual(await pCur.evaluate(() => ({ hw: rec.on, phone: phoneRec.on, failover: phoneRec.failover })), { hw: false, phone: true, failover: true });
  assert(await pCur.$eval('[data-testid="capsule-phone-rec"]', x => getComputedStyle(x).display !== 'none' && x.innerText.trim() === '本机录音'));
  assert(await pCur.$eval('#dyn-island', x => x.classList.contains('show') && x.innerText.includes('本机保底录音中')));
  await pCur.evaluate(() => stopPhoneRec());
  assert(!(await pCur.$eval('#dyn-island', x => x.classList.contains('show'))));
  assert.equal(await pCur.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth), true);
  // 当前版验证：Setting → Apple Watch 硬件联动（默认关闭保持3设备，开启后加入四硬件扫描与能力裁剪）
  await pCur.click('[data-testid="crumb-back"]');
  assert.equal(await pCur.$eval('#sv-watch', x => x.innerText.trim()), '未开启');
  await pCur.$eval('[data-testid="set-apple-watch"]', x => x.scrollIntoView({ block: 'center' }));
  assert.equal(await pCur.$('[data-testid="nc-watch-entry"]'), null);
  await pCur.click('[data-testid="set-apple-watch"]');
  assert(await pCur.$('[data-testid="watch-link-toggle-row"]'));
  assert(await pCur.$('[data-testid="watch-link-status-card"]'));
  assert(await pCur.$('[data-testid="watch-complication-guide"]'));
  assert.equal(await pCur.$('[data-testid="watch-remote-card"]'), null);
  assert.equal(await pCur.$('[data-testid="watch-slices-card"]'), null);
  assert.equal(await pCur.$$eval('#p-setsub .nc-badge', x => x.length), 0);
  const watchBtnGeom = await pCur.evaluate(() => {
    const b1 = document.querySelector('[data-testid="watch-connect-btn"]').getBoundingClientRect();
    const b2 = document.querySelector('[data-testid="watch-flush-btn"]').getBoundingClientRect();
    return { topDiff: Math.abs(b1.top - b2.top), widthDiff: Math.abs(b1.width - b2.width), w1: b1.width };
  });
  assert(watchBtnGeom.topDiff <= 1 && watchBtnGeom.widthDiff <= 1 && watchBtnGeom.w1 > 100, 'Watch 两个操作按钮必须左右同行且 50%/50% 等宽: ' + JSON.stringify(watchBtnGeom));
  assert(await pCur.$eval('[data-testid="watch-link-status-card"]', x => !x.innerText.includes('%') && !x.innerText.includes('已充满')));
  // 验证「表端未安装」自检横幅按状态显示与恢复
  await pCur.evaluate(() => { agCfg.watchInstalled = false; renderSetSub('watch'); });
  assert(await pCur.$('[data-testid="watch-install-guide-banner"]'));
  await pCur.evaluate(() => { agCfg.watchInstalled = true; renderSetSub('watch'); });
  assert.equal(await pCur.$('[data-testid="watch-install-guide-banner"]'), null);
  await pCur.click('[data-testid="watch-link-switch"]');
  await pCur.click('[data-testid="crumb-back"]');
  assert.equal(await pCur.$eval('#sv-watch', x => x.innerText.trim()), '已配对');
  await pCur.click('[data-testid="hw-capsule"]');
  await pCur.waitForFunction(() => document.querySelectorAll('#conn-list .conn-item').length === 4, { timeout: 5000 });
  assert(await pCur.$eval('#conn-list', x => x.innerText.includes('Apple Watch')));
  await pCur.click('[data-testid="dev-item-APPLE_WATCH_S10"]');
  await pCur.waitForFunction(() => !document.getElementById('dev-main').hidden, { timeout: 5000 });
  assert.equal(await pCur.$eval('#dev-kind-badge', x => x.innerText.trim()), 'Apple Watch');
  assert(await pCur.$eval('#row-sync', x => !x.hidden));
  assert(await pCur.$eval('#row-wifi', x => x.hidden));
  assert(await pCur.$eval('#row-fw', x => x.hidden));
  assert(await pCur.$eval('#row-batt', x => !x.innerText.includes('%') && !x.innerText.includes('已充满')));
  await pCur.click('[data-testid="rec-toggle"]');
  assert.deepEqual(await pCur.evaluate(() => ({ hw: rec.on, phone: phoneRec.on, standby: phoneRec.standby })), { hw: true, phone: false, standby: true });
  assert(await pCur.$eval('#dyn-island', x => x.classList.contains('show') && x.innerText.includes('Apple Watch 录音中') && x.innerText.includes('锁屏实况')));
  await pCur.click('[data-testid="rec-toggle"]');
  await pCur.click('[data-testid="dev-disconnect"]');
  await pCur.click('[data-testid="disconnect-confirm"]');
  await pCur.waitForFunction(() => !document.getElementById('dev-connect').hidden, { timeout: 5000 });
  await pCur.evaluate(() => closeSheet());
  await pCur.evaluate(() => { agCfg.watchLinkEnabled = false; syncSetSummary(); });
  assert.equal(await pCur.$eval('#sv-watch', x => x.innerText.trim()), '未开启');
  // 当前版验证：Setting → 第三方硬件联动（Get笔记卡 / Omi 录音器）
  assert.equal(await pCur.$eval('#sv-exthw', x => x.innerText.trim()), '未开启');
  await pCur.$eval('[data-testid="set-ext-hw"]', x => x.scrollIntoView({ block: 'center' }));
  await pCur.click('[data-testid="set-ext-hw"]');
  await pCur.waitForSelector('[data-testid="ext-getseed-switch"]', { timeout: 3000 });
  await pCur.click('[data-testid="ext-getseed-switch"]');
  await pCur.click('[data-testid="ext-omi-switch"]');
  await pCur.click('[data-testid="crumb-back"]');
  assert.equal(await pCur.$eval('#sv-exthw', x => x.innerText.trim()), '已开启 2 款');
  await pCur.click('[data-testid="hw-capsule"]');
  await pCur.waitForFunction(() => document.querySelectorAll('#conn-list .conn-item').length === 5, { timeout: 5000 });
  assert.deepEqual(await pCur.$$eval('#conn-list .cn', e => e.map(x => x.innerText.trim())), ['T4W25T', 'A102', '7F20', 'B7K9Q2', 'L3M8N1']);
  await pCur.click('[data-testid="dev-item-Get-A102"]');
  await pCur.waitForFunction(() => !document.getElementById('dev-main').hidden, { timeout: 5000 });
  assert.equal(await pCur.$eval('#dev-kind-badge', x => x.innerText.trim()), 'Get笔记卡');
  assert(await pCur.$eval('[data-testid="rec-physical-only"]', x => !x.hidden && x.innerText.trim() === '机身按键控录'));
  assert(await pCur.$eval('#rec-sw', x => x.hidden));
  assert(await pCur.$eval('#row-sync', x => !x.hidden));
  assert(await pCur.$eval('#row-wifi', x => x.hidden));
  assert(await pCur.$eval('#row-fw', x => x.hidden));
  await pCur.click('[data-testid="dev-disconnect"]');
  await pCur.click('[data-testid="disconnect-confirm"]');
  await pCur.waitForFunction(() => document.querySelectorAll('#conn-list .conn-item').length === 5, { timeout: 5000 });
  await pCur.click('[data-testid="dev-item-Omi-7F20"]');
  await pCur.waitForFunction(() => !document.getElementById('dev-main').hidden, { timeout: 5000 });
  assert.equal(await pCur.$eval('#dev-kind-badge', x => x.innerText.trim()), 'Omi 录音器');
  assert(await pCur.$eval('#rec-sw', x => !x.hidden));
  assert(await pCur.$eval('[data-testid="rec-physical-only"]', x => x.hidden));
  assert(await pCur.$eval('#row-sync', x => !x.hidden));
  assert(await pCur.$eval('#row-wifi', x => x.hidden));
  assert(await pCur.$eval('#row-fw', x => x.hidden));
  await pCur.click('[data-testid="dev-disconnect"]');
  await pCur.click('[data-testid="disconnect-confirm"]');
  await pCur.waitForFunction(() => !document.getElementById('dev-connect').hidden, { timeout: 5000 });
  await pCur.evaluate(() => { closeSheet(); agCfg.getSeedLinkEnabled = false; agCfg.omiLinkEnabled = false; syncSetSummary(); });
  assert.equal(await pCur.$eval('#sv-exthw', x => x.innerText.trim()), '未开启');
  // 当前版：定位与健康采集读设计列表，开关可关，且没有目标版的信号联动预览
  assert.equal(await pCur.$eval('#sv-health', x => x.innerText.trim()), '已开启 · 6 条');
  await pCur.$eval('[data-testid="set-health-location"]', x => x.scrollIntoView({ block: 'center' }));
  await pCur.click('[data-testid="set-health-location"]');
  assert(await pCur.$('[data-testid="health-sync-switch"]'));
  assert.equal(await pCur.$$eval('[data-testid^="health-item-"]', x => x.length), 6);
  assert.equal(await pCur.$$eval('#p-setsub .nc-badge', x => x.length), 0);
  assert.equal(await pCur.$('[data-testid="health-to-territory"]'), null);
  assert.equal(await pCur.$('[data-testid="health-to-bio-detail"]'), null);
  await pCur.click('[data-testid="health-sync-switch"]');
  assert.equal(await pCur.$eval('#sv-health', x => x.innerText.trim()), '已关闭');
  assert.equal(await pCur.$$eval('[data-testid^="health-item-"]', x => x.length), 6, '关闭开关不清空已展示的设计列表');
  await pCur.evaluate(() => { agCfg.healthSignalEnabled = true; syncSetSummary(); });
  await pCur.click('[data-testid="crumb-back"]');
  // 当前版宽屏全页面滚动到底部留白验证（Timeline / Setting / 总结详情 / 记录详情）
  await pCur.setViewport({ width: 900, height: 680, deviceScaleFactor: 2 });
  await pCur.click('[data-testid="nav-timeline"]');
  await pCur.click('[data-testid="card-sum-demo"]');
  const curWideGaps = await pCur.evaluate(() => {
    const sc = document.getElementById('sidecol');
    sc.scrollTop = sc.scrollHeight;
    const sumLast = [...document.querySelectorAll('#p-sumres .srclist .srcitem')].pop();
    const sumGap = sc.getBoundingClientRect().bottom - sumLast.getBoundingClientRect().bottom;
    const rc = document.getElementById('rootcol');
    rc.scrollTop = rc.scrollHeight;
    const tlLast = [...document.querySelectorAll('#p-timeline #feed .card')].pop();
    const tlGap = rc.getBoundingClientRect().bottom - tlLast.getBoundingClientRect().bottom;
    return { sumGap, tlGap };
  });
  assert(curWideGaps.sumGap >= 44 && curWideGaps.tlGap >= 44, 'current.html 宽屏底部留白不足: ' + JSON.stringify(curWideGaps));
  await pCur.click('[data-testid="nav-setting"]');
  const curSetGap = await pCur.evaluate(() => {
    const rc = document.getElementById('rootcol');
    rc.scrollTop = rc.scrollHeight;
    const kids = [...document.querySelectorAll('#p-setting > *')].filter(el => el.offsetParent !== null);
    const last = kids[kids.length - 1];
    return rc.getBoundingClientRect().bottom - last.getBoundingClientRect().bottom;
  });
  assert(curSetGap >= 44, 'current.html Setting 宽屏底部留白不足: ' + curSetGap);
  await pCur.close();

  assert.equal(errors.length, 0, errors.join(','));
  assert.equal(net.length, 0, net.join(','));
  console.log(JSON.stringify({ pass: true, viewport: '390x844 @2x + 900x1100', navigation: 2, errors, networkRequests: net, checks: ['fixed-chrome', 'crumb-root-hidden', 'feed-time-desc', 'photo-thumbs', 'photo-detail', 'bedtime-diary', 'diary-likes-annotations', 'dream-card', 'dream-sheet', 'dream-comic-skill', 'unc-triage-sheet', 'voiceprint-context-tag', 'voiceprint-merge-detach', 'memory-graph-triad', 'memory-provenance-metabolism', 'hw-button-island-push', 'tbc-markers', 'parity-drawer', 'two-line-card', 'expand-collapse', 'detail-entry', 'subpage-hides-nav', 'detail-tabs-raw', 'raw-audio-player', 'raw-seek', 'select-mode', 'tabs-lock-on-summary', 'action-card', 'range-today', 'range-week', 'range-month', 'tap-toggle', 'sumbar-rows', 'gen-status-view', 'generate-progress', 'sum-tabs', 'default-all-view', 'sum-contextual-photos', 'map-photo-hierarchy', 'todo-progressive-meta', 'point-expand', 'point-trace', 'src-photo-infocards', 'refs-tab', 'detail-backlink', 'history-flatten', 'src-tab-loop', 'export-sheet', 'filter', 'cancel-summary', 'setting-toggle', 'setting-v2-subpages', 'connect-default', 'capsule-nodata', 'scan-dyj-sorted', 'multi-hw-scan', 'rec-default-off', 'rec-switch', 'device-sheet', 'sheet-single-rows', 'battery-capsule', 'battery-row', 'clock-stable', 'row-inline-actions', 'rec-clock-tick', 'rel-sync', 'wifi-count', 'no-sim-labels', 'sync-now', 'sync-cooldown', 'live-card', 'auto-sync', 'live-hide-summary', 'dfu-rec-guard', 'two-stage-fw', 'fw-lock', 'wifi-setup', 'toc-float', 'tabs-sticky', 'pt-default-open', 'wide-two-pane', 'wide-list-stays', 'wide-crumb-off', 'pane-back', 'wide-flatten', 'fresh-from-list', 'session-restore', 'apple-watch-hardware-link', 'territory-checkin-map', 'sleep-hr-hrv-emotion', 'sunrise-ai-her-chat', 'no-overflow'] }, null, 2));
  await b.close();
})().catch(e => { console.error(e); process.exit(1) });
