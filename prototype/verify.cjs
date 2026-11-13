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
  assert(await p.$eval('[data-testid="card-daily-0"]', x => x.innerText.includes('今日睡前日记') && x.innerText.includes('待标注 3')));
  assert(await p.$eval('[data-testid="card-daily-1"]', x => x.innerText.includes('昨日睡前日记') && x.innerText.includes('已标注')));
  assert.equal(await p.$eval('[data-testid="tbc-daily"]', x => x.innerText.trim()), 'TBC');
  assert.equal(await p.$eval('[data-testid="tbc-slice-merge"]', x => x.innerText.trim()), 'TBC');
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
  await p.evaluate(() => document.querySelector('#dt-dlg .dphoto-x').click());
  assert.equal(await p.$$eval('#dt-dlg .dphoto', x => x.length), 1);
  assert.equal(await p.$$eval('[data-testid="pics-e2"] .pthumb', x => x.length), 1);
  assert.equal(await p.$eval('[data-testid="card-sum-demo"] .sumphotos', x => x.textContent.trim()), '含 1 张图片');
  assert.equal(await p.$eval('[data-testid="card-unc-0"] .unccount', x => x.textContent.trim()), '2 张');
  await p.evaluate(() => goBack());
  await new Promise(r => setTimeout(r, 300));
  // 未归类图片卡：点开分拣抽屉 → 按时间最近推荐一键归位 → 外侧缩略图与总结张数同步更新
  await p.click('[data-testid="card-unc-0"]');
  assert(await p.$eval('#unc-wrap', x => x.classList.contains('show')));
  assert.equal(await p.$$eval('#unc-body .unc-item', x => x.length), 2);
  assert(await p.$eval('[data-testid="unc-reassign-e2-0-e2"]', x => x.classList.contains('best') && x.innerText.includes('时间最接近')));
  await p.click('[data-testid="unc-reassign-e2-0-e2"]');
  assert.equal(await p.$$eval('#unc-body .unc-item', x => x.length), 1);
  assert.equal(await p.$eval('[data-testid="card-unc-0"] .unccount', x => x.textContent.trim()), '1 张');
  assert.equal(await p.$$eval('[data-testid="pics-e2"] .pthumb', x => x.length), 2);
  assert.equal(await p.$eval('[data-testid="card-sum-demo"] .sumphotos', x => x.textContent.trim()), '含 2 张图片');
  await p.evaluate(() => { closeUncSheet(); excludePhoto('e2', 0); });
  assert.equal(await p.$eval('[data-testid="card-unc-0"] .unccount', x => x.textContent.trim()), '2 张');

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
  assert.deepEqual(await p.$$eval('#stabs button', e => e.map(x => x.innerText.trim())), ['全部', '概览', '逻辑结构', '信息点', '行动项', '来源记录']);
  assert(await secVis('sec-ov') && await secVis('sec-map') && await secVis('sec-pt') && await secVis('sec-todo') && await secVis('sec-src'));
  // 总结结果页图文融入：概览内嵌关键画面带；逻辑结构双层图片权重（微缩图=核心实证 vs 图标=辅助附图）；信息点按时间窗挂图
  assert(await p.$('[data-testid="sum-ov-photos"]'));
  assert.equal(await p.$('[data-testid="mleaf-key-e2-0"]'), null, '已排除照片节点应自动降级为纯文字胶囊');
  assert(await p.$eval('[data-testid="mleaf-key-e2-1"]', x => !!x.querySelector('img.mleaf-thumb') && x.innerText.includes('重置现状')));
  assert(await p.$eval('[data-testid="mleaf-aux-e3-1"]', x => !!x.querySelector('svg') && !x.querySelector('img')));
  assert(await p.$('[data-testid="map-photo-legend"]'));
  assert.equal(await p.$('[data-testid="pt-picpill-0"]'), null, 'e1 无照片，对应信息点不应出现图片胶囊');
  assert(await p.$('[data-testid="pt-picpill-1"]'), 'e2 有照片，对应信息点标题应显示图片胶囊');
  assert(await p.$('[data-testid="pt-picpill-3"]'), 'e3 10:14-10:15 对应信息点标题应显示图片胶囊');
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
  // 来源记录：带图片 icon 的结构化信息卡片（有图记录显示 SVG 图片 icon + 张数，无图记录不显示）
  assert.equal(await p.$('[data-testid="src-picbadge-e1"]'), null, '无图记录不应展示图片 icon 徽标');
  assert(await p.$eval('[data-testid="src-picbadge-e2"]', x => x.innerText.includes('1 张图片') && !!x.querySelector('svg')));
  assert(await p.$eval('[data-testid="src-picbadge-e3"]', x => x.innerText.includes('4 张图片') && !!x.querySelector('svg')));
  assert(await p.$eval('[data-testid="src-e2"] .src-brief', x => x.innerText.includes('回访')));
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

  // Setting 与录音卡状态页（含 App 反向同步的 V2 模型/提示词/扩展/隐私页，以及未实现项 TBC 标记）
  await p.click('[data-testid="nav-setting"]');
  await shot('setting');
  assert.equal(await p.$eval('[data-testid="tbc-sw-continuous"]', x => x.innerText.trim()), 'TBC');
  assert.equal(await p.$eval('[data-testid="tbc-sw-mark"]', x => x.innerText.trim()), 'TBC');
  assert.equal(await p.$eval('[data-testid="tbc-sw-wifi"]', x => x.innerText.trim()), 'TBC');
  const sw = await p.$eval('.sw', x => x.getAttribute('aria-checked'));
  await p.click('.sw');
  assert.notEqual(await p.$eval('.sw', x => x.getAttribute('aria-checked')), sw);
  // 外脑 OAuth2 与微信/Google/GitHub/Facebook 绑定
  assert.equal(await p.$eval('[data-testid="sv-auth"]', x => x.innerText.trim()), 'owner@wainao.chat');
  await p.click('[data-testid="set-auth-entry"]');
  assert(await p.$('[data-testid="auth-wainao-card"]'));
  assert(await p.$('[data-testid="auth-signout-btn"]'));
  assert(await p.$('[data-testid="auth-bind-wechat"]'));
  assert(await p.$('[data-testid="auth-bind-google"]'));
  assert(await p.$('[data-testid="auth-bind-github"]'));
  assert(await p.$('[data-testid="auth-bind-facebook"]'));
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
  await p.click('[data-testid="set-cloud-model"]');
  await p.click('[data-testid="model-opt-qwen-max"]');
  assert(await p.$('[data-testid="temp-0.2"]'));
  assert.equal(await p.$eval('[data-testid="tbc-ctx-fullday"]', x => x.innerText.trim()), 'TBC');
  await p.click('[data-testid="crumb-back"]');
  assert.equal(await p.$eval('#sv-cloud', x => x.innerText.trim()), 'qwen-max');
  // 交叉反馈：系统相册权限前置说明弹窗 + 灵动岛按机型隐藏
  await p.click('[data-testid="set-photo-import"]');
  assert(await p.$eval('#photo-perm-wrap', x => x.classList.contains('show')));
  assert(await p.$('[data-testid="photo-perm-dialog"]'));
  await p.click('[data-testid="photo-perm-grant"]');
  assert(await p.$eval('#sv-photo-imp', x => x.innerText.includes('已对齐 6 张照片')));
  assert(await p.$eval('[data-testid="set-dynamic-island"]', x => !x.hidden));
  await p.click('[data-testid="toggle-island-hw"]');
  assert(await p.$eval('[data-testid="set-dynamic-island"]', x => x.hidden));
  await p.click('[data-testid="toggle-island-hw"]');
  assert(await p.$eval('[data-testid="set-dynamic-island"]', x => !x.hidden));
  await p.click('[data-testid="set-prompts"]');
  await p.click('[data-testid="preset-meeting"]');
  await p.click('[data-testid="prompt-save"]');
  await p.click('[data-testid="crumb-back"]');
  assert.equal(await p.$eval('#sv-preset', x => x.innerText.trim()), '会议决策');
  await p.click('[data-testid="set-extensions"]');
  assert.equal(await p.$eval('[data-testid="tbc-mcp"]', x => x.innerText.trim()), 'TBC');
  await p.click('[data-testid="sw-sk-risk"]');
  await p.click('[data-testid="crumb-back"]');
  assert.equal(await p.$eval('#sv-ext', x => x.innerText.trim()), '已启用 6 项');
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
  await p.click('[data-testid="parity-btn"]');
  assert(await p.$eval('#parity-wrap', x => x.classList.contains('show')));
  assert.equal(await p.$$eval('#parity-list .p-item', x => x.length), 14);
  await p.click('#parity-tabs [data-pt="app"]');
  assert.equal(await p.$$eval('#parity-list .p-item', x => x.length), 9);
  await p.evaluate(() => closeParity());
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
  assert.equal(await p.$eval('[data-testid="tbc-hw-wifi"]', x => x.innerText.trim()), 'TBC');
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
  assert.equal(await p.$('#dev-main .chip-ok'), null);
  assert(await p.$eval('#dev-sub', x => !x.innerText.includes('已连接') && !x.innerText.includes('可用') && x.innerText.includes('固件 2.1.0')));
  assert(await p.$eval('#dev-main', x => x.innerText.includes('可录至') && x.innerText.includes('电量高')));
  // 充电中闪电图标与呼吸效果（顶栏胶囊 + 弹层电量行）
  await p.click('[data-testid="toggle-charge-btn"]');
  assert.equal(await p.$$eval('.batt.charging [data-testid="batt-bolt"]', x => x.filter(el => getComputedStyle(el).display !== 'none').length), 2);
  await p.click('[data-testid="toggle-charge-btn"]');
  assert.equal(await p.$$eval('#dev-main .row', x => x.length), 6);
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
  console.log(JSON.stringify({ pass: true, viewport: '390x844 @2x + 900x1100', navigation: 2, errors, networkRequests: net, checks: ['fixed-chrome', 'crumb-root-hidden', 'feed-time-desc', 'photo-thumbs', 'photo-detail', 'bedtime-diary', 'diary-likes-annotations', 'dream-card', 'dream-sheet', 'dream-comic-skill', 'unc-triage-sheet', 'voiceprint-context-tag', 'voiceprint-merge-detach', 'memory-graph-triad', 'memory-provenance-metabolism', 'hw-button-island-push', 'tbc-markers', 'parity-drawer', 'two-line-card', 'expand-collapse', 'detail-entry', 'subpage-hides-nav', 'detail-tabs-raw', 'raw-audio-player', 'raw-seek', 'select-mode', 'tabs-lock-on-summary', 'action-card', 'range-today', 'range-week', 'range-month', 'tap-toggle', 'sumbar-rows', 'gen-status-view', 'generate-progress', 'sum-tabs', 'default-all-view', 'sum-contextual-photos', 'map-photo-hierarchy', 'todo-progressive-meta', 'point-expand', 'point-trace', 'src-photo-infocards', 'refs-tab', 'detail-backlink', 'history-flatten', 'src-tab-loop', 'export-sheet', 'filter', 'cancel-summary', 'setting-toggle', 'setting-v2-subpages', 'connect-default', 'capsule-nodata', 'scan-dyj-sorted', 'multi-hw-scan', 'rec-default-off', 'rec-switch', 'device-sheet', 'sheet-single-rows', 'battery-capsule', 'battery-row', 'clock-stable', 'row-inline-actions', 'rec-clock-tick', 'rel-sync', 'wifi-count', 'no-sim-labels', 'sync-now', 'sync-cooldown', 'live-card', 'auto-sync', 'live-hide-summary', 'dfu-rec-guard', 'two-stage-fw', 'fw-lock', 'wifi-setup', 'toc-float', 'tabs-sticky', 'pt-default-open', 'wide-two-pane', 'wide-list-stays', 'wide-crumb-off', 'pane-back', 'wide-flatten', 'fresh-from-list', 'session-restore', 'no-overflow'] }, null, 2));
  await b.close();
})().catch(e => { console.error(e); process.exit(1) });
