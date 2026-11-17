(function () {
  var HERO_SEGMENTS = {
    zh: [
      { text: '别再 ' },
      { text: '边听边记', strike: true },
      { text: '，', br: true },
      { text: '专心聊，它替你 ' },
      { text: '记住', em: true },
      { text: '。' }
    ],
    en: [
      { text: 'Stop ' },
      { text: 'scrambling for notes', strike: true },
      { text: '.', br: true },
      { text: 'Just ' },
      { text: 'talk', em: true },
      { text: ' — it remembers.' }
    ]
  };

  var I18N = {
    zh: {
      pageTitle: '录音卡',
      brandName: '录音卡',
      navWhat: '能帮你做什么',
      navApp: 'App 界面',
      navDetails: '省心细节',
      navFaq: '常见问题',
      navDemo: '视频演示',
      s2bEyebrow: 'WATCH IT WORK',
      s2bTitle: '真实界面，点开就看。',
      s2bDesc: '下面每一段都来自 App 的真实界面——悬停看封面，点击播放。',
      d1Title: '开会见客，只管专心聊',
      d1Desc: '录音卡在桌上自动记录，每满 1 分钟，手机上就多一段整理好的文字；会开完，稿子也差不多齐了。',
      d2Title: '散会 30 秒，纪要就绪',
      d2Desc: '勾选刚聊的几段，一键生成结构化总结——概览、要点、待办，直接转给同事。',
      d3Title: '两个人对谈，发言各自成段',
      d3Desc: '谁说的哪句，按人分好段；现场拍的照片自动贴回那一刻的对话。人名先标「推测」，等你确认。',
      d4Title: '断网，照样出稿',
      d4Desc: '转写引擎就装在手机里，没网也能把话变成字；原始录音只留在本机。',
      d5Title: '原声完整保留，按句回听',
      d5Desc: '看的是清爽重点，留的是完整原话——点哪句，跳哪句。',
      d6Title: '每天的叮嘱，收成一份日报',
      d6Desc: '按天整理成好读的小结，重要的事自动列清楚，早晚各看一眼就安心。',
      d7Title: '医嘱、交代，自动成清单',
      d7Desc: '复查回来打开一看，该做的事一条条列好，不易漏。',
      d8Title: '几小时的课，重点自己浮出来',
      d8Desc: '信息点带溯源，点一下回到老师原话；复习不用重听整节课。',
      d9Title: '采访素材，秒级回放',
      d9Desc: '长录音按句定位，金句随点随听；整理完一键导出 PDF、Markdown 或 Word。',
      d10Title: '开箱到出稿，只要一分钟',
      d10Desc: '自动扫描连接、按下开关就录；第一段文字稿很快出现在手机上。',
      demoHint: '点击播放 · 有声音',
      navCta: '早鸟登记',
      heroKicker: '录音卡 · 早鸟预约开放',
      heroLead: '开会、见客户、上课、陪家人看诊——随身戴着不用管，聊完就有清晰的重点、待办和每日小结。',
      heroCtaPrimary: '免费加入早鸟 →',
      heroCtaSecondary: '看 App 界面',
      heroPerk: '早鸟福利：免费登记赠至少 1 个月会员 · 抽实体录音卡（价值 ¥1,000）',
      meta1: '录音留在自己手机里',
      meta2: '不掏手机盲按即用',
      meta3: '支持 iPhone · Android · Watch',
      stageLabel: '按键体验 · 点一下试试',
      capsuleStatus: '录音中',
      islandIdle: '正在记录对话',
      islandListening: '正在听你问：前几天看的电影叫什么？',
      islandMarkedPrefix: '已记重点 · ',
      pressHint: '不用掏手机 →',
      btnMark: '按一下 · 记重点',
      btnCmd: '按住问 · 查记忆',
      pushPromptBadge: '试试',
      pushPromptText: '点上面两个按钮：按一下随手记重点，按住直接问以前聊过的事。',
      pushMarkBadge: '记重点',
      pushMarkText: '已在 {time} 记下重点，今晚整理小结会重点留意这一段。',
      pushABadge: '收到',
      pushAText: '我现在就去查一下，找到和你说。',
      pushBBadge: '找到了',
      pushBText: '找到了，是《007黄金眼》，前天周三下午看的，你还吃了爆米花。',
      s1Eyebrow: 'WHAT IT DOES',
      s1Title: '聊完就忘、几小时录音懒得重听？交给它。',
      s1Desc: '不用改变说话习惯，也不用会后熬夜补纪要。',
      w1Title: '开会见客，只管专心聊',
      w1Desc: '不用低头打字，也不用刻意掏手机点录音。聊完自动理出重点与待办，谁说了什么随时查原话。',
      w2Title: '拍张白板，自动对上当时的话',
      w2Desc: '开会拍投影、上课拍板书，照片自动贴进那一刻的对话里，回头复盘一目了然。',
      w3Title: '忘了细节，按住问一句就有',
      w3Desc: '想不起前几天聊过的报价、医嘱或电影名？按住卡片问一句，答案直接推到手机上。',
      s2Eyebrow: 'IN THE APP',
      s2Title: '不用翻几小时录音，打开就是结论。',
      s2Desc: '点选场景，看看每天说的话怎么变成好用的记录。',
      t1Title: '按天排好，一眼看清',
      t1Desc: '一天聊了几场、每场讲了什么，点开两行就看清；未归类的照片随时分拣。',
      t1Cap: '每天的对话按时间清晰排列',
      t2Title: '谁说了什么，照片就在旁边',
      t2Desc: '按人分好自然段，人名未确认前标「推测」；当时拍的画面自动贴进那一刻的对话里。',
      t2Cap: '对话与现场画面按时刻自动对齐',
      t3Title: '结论、脉络与待办，一键发走',
      t3Desc: '勾选几段就能汇总概览、逻辑脉络与行动项，随时点回原话核对，支持导出 PDF、Word 或长图。',
      t3Cap: '概览、逻辑脉络与待办随时核对',
      t4Title: '原声完整保留，点哪句听哪句',
      t4Desc: '平时看去掉口头禅的清爽文本；拿不准细节时切到原始记录，点任意一句直接回听当时原声。',
      t4Cap: '点任意一句，直接回听当时原声',
      t5Title: '连上就录，锁屏也能看状态',
      t5Desc: '打开开关即刻省电记录，灵动岛与锁屏实况随时可见；万一断连，手机自动无缝接上。',
      t5Cap: '硬件状态同步锁屏实况卡片',
      s3Eyebrow: 'BUILT AROUND YOU',
      s3Title: '顺着你的习惯，守住你的隐私。',
      s3Desc: '好的工具不抢戏——需要时稳稳接住，平时几乎感觉不到它的存在。',
      v1Tag: 'PRIVACY FIRST',
      v1Title: '录音留在手机里，不上云',
      v1Desc: '语音在你的手机本地转成文字，原始录音默认不上传服务器，聊什么都安心。',
      v2Tag: 'ALWAYS READY',
      v2Title: '不费手机电，断连也不漏话',
      v2Desc: '平时由录音卡省电记录，手机不发热；万一卡片没电或走远断连，手机会自动接上。',
      v3Tag: 'VERIFIABLE',
      v3Title: '看的是清爽重点，留的是完整原话',
      v3Desc: '默认展示去掉口头禅的干净记录，同时完整保留原始录音与原词，随时点开重听或删除。',
      v4Tag: 'FLEXIBLE',
      v4Title: '多设备随手记，不锁定硬件',
      v4Desc: '戴着录音卡最无感；没带卡时用手机、Apple Watch，或手头已有的 Get 笔记卡、Omi 也能连上录，统一归进一条时间轴。',
      s4Eyebrow: 'FAQ',
      s4Title: '常见问题',
      fq1: '整天开着录音，手机会跟着耗电发热吗？',
      fa1: '不会。连着录音卡时只由卡片自己录音，手机麦克风完全休息，平时几乎感觉不到耗电。',
      fq2: '我的录音安全吗？别人能听到吗？',
      fa2: '原始录音保存在你自己的手机里，转文字也在本地完成，音频默认不上传云端。你随时可以在手机里单条或全部删除。',
      fq3: '飞机上、地下室这种没网的地方能用吗？',
      fa3: '能。录音和转文字都不依赖网络；等回到有网的地方，再自动帮你生成总结。',
      fq4: '还没有实体录音卡，能先用起来吗？',
      fa4: '可以。App 支持直接用手机或 Apple Watch 录音（手表轻敲两下就能随手记重点），也兼容 Get 笔记录音卡与 Omi；以后拿到录音卡连上就能接着用。',
      fq5: '早鸟登记收费吗？有什么福利？',
      fa5: '完全免费。正式上线后，所有早鸟登记用户都会获赠至少 1 个月会员，并自动参与抽取实体录音卡（价值 ¥1,000）。',
      wlTitle: '抢先预约体验',
      wlDesc: '留下常用邮箱，上线第一时间通知你。',
      wlEmailPlaceholder: '你的常用邮箱，例如 you@example.com',
      wlSubmit: '免费加入早鸟',
      wlPerk1: '赠送至少 1 个月正式版会员',
      wlPerk2: '自动参与抽取实体录音卡（价值 ¥1,000）',
      wlErrEmail: '请输入有效的邮箱地址',
      wlDoneTitle: '已加入早鸟名单',
      wlDoneDesc: '已登记 {email}（{platform}）。上线第一时间通知你，至少 1 个月会员与实体录音卡抽奖资格（价值 ¥1,000）已为你保留。',
      wlReset: '更换邮箱重新登记',
      modalTitle: '早鸟免费登记',
      modalLead: '留下常用邮箱，上线第一时间通知你：赠送至少 1 个月会员，并自动参与抽取实体录音卡（价值 ¥1,000）。',
      footCopy: '© 2026 ReAI · 录音卡',
      hwName: '录音卡'
    },
    en: {
      pageTitle: 'AI Card — Just talk, it remembers',
      brandName: 'AI Card',
      navWhat: 'What it does',
      navApp: 'The App',
      navDetails: 'Why it fits',
      navFaq: 'FAQ',
      navDemo: 'Videos',
      s2bEyebrow: 'WATCH IT WORK',
      s2bTitle: 'Real screens, one click away.',
      s2bDesc: 'Every clip below comes from the actual app — hover for a preview, click to play.',
      d1Title: 'Meetings run themselves',
      d1Desc: 'Keep the card on the table and just talk. Every minute, another tidy block of notes appears on your phone.',
      d2Title: 'Minutes, thirty seconds after',
      d2Desc: 'Pick the recent clips, tap once, and get a structured summary with key points and action items.',
      d3Title: 'Two speakers, cleanly split',
      d3Desc: 'Lines are grouped by speaker and photos slot back into the moment. Names start as a guess until you confirm.',
      d4Title: 'Works offline',
      d4Desc: 'The transcription engine runs on your phone — no network needed, and audio never leaves the device.',
      d5Title: 'Full audio, sentence-level replay',
      d5Desc: 'Clean summaries up front, complete recordings behind. Tap any line to hear that exact moment.',
      d6Title: 'Daily notes, written for you',
      d6Desc: 'Each day becomes a readable recap, with the important things neatly listed.',
      d7Title: "Doctor's orders, auto-listed",
      d7Desc: 'After the clinic, open the app — everything to do is already laid out.',
      d8Title: 'Hours of class, key points first',
      d8Desc: 'Key points link back to the exact words. No more re-listening to whole lectures.',
      d9Title: 'Interview tapes, instant replay',
      d9Desc: 'Jump to any sentence in long recordings, then export to PDF, Markdown or Word.',
      d10Title: 'Unbox to first draft in a minute',
      d10Desc: 'Scan, connect, press record — the first block of text shows up on your phone shortly.',
      demoHint: 'Click to play · sound on',
      navCta: 'Join Waitlist',
      heroKicker: 'AI Card · Early-Bird Open',
      heroLead: 'Meetings, client chats, lectures, doctor visits — wear it and forget it. Walk away with clear takeaways, to-dos, and a daily recap.',
      heroCtaPrimary: 'Join Free Waitlist →',
      heroCtaSecondary: 'See the App',
      heroPerk: 'Early-Bird Perks: Free signup · 1+ month membership · Win a physical AI Card (worth ¥1,000)',
      meta1: 'Audio stays on your phone',
      meta2: 'Press without unlocking',
      meta3: 'iPhone · Android · Watch',
      stageLabel: 'Try it · Tap a button',
      capsuleStatus: 'Recording',
      islandIdle: 'Recording conversation',
      islandListening: 'Listening: What movie did we watch Wednesday?',
      islandMarkedPrefix: 'Marked · ',
      pressHint: 'Keep phone in pocket →',
      btnMark: 'Press · Mark moment',
      btnCmd: 'Hold · Ask memory',
      pushPromptBadge: 'TRY',
      pushPromptText: 'Tap a button above: press once to mark a key moment, or hold to ask about past conversations.',
      pushMarkBadge: 'MARKED',
      pushMarkText: 'Marked {time} — this part will be highlighted in your notes tonight.',
      pushABadge: 'REPLY',
      pushAText: 'Looking that up for you now — one second.',
      pushBBadge: 'FOUND',
      pushBText: 'It was "GoldenEye (007)" on Wednesday afternoon — and you got popcorn.',
      s1Eyebrow: 'WHAT IT DOES',
      s1Title: 'Walk out of a meeting and already forget half of it?',
      s1Desc: 'Keep talking as you always do. No typing, no late-night catch-up.',
      w1Title: 'Stay present in every conversation',
      w1Desc: 'No looking down to type or pulling out your phone to hit record. Get clear takeaways, action items, and exact quotes when you finish.',
      w2Title: 'Snap a whiteboard, matched to the moment',
      w2Desc: 'Take photos of slides or notes during a meeting or class. Each photo lands right next to what was being said at that moment.',
      w3Title: 'Forgot a detail? Hold and ask',
      w3Desc: 'Can\'t recall last week\'s quote, doctor\'s note, or movie title? Hold the card button and ask — the answer pops up on your phone.',
      s2Eyebrow: 'IN THE APP',
      s2Title: 'Skip hours of playback. Open straight to the point.',
      s2Desc: 'Pick a view to see how everyday conversations turn into notes you actually use.',
      t1Title: 'Organized by day, clear in two lines',
      t1Desc: 'See every conversation of the day at a glance, with unsorted photos ready to file anytime.',
      t1Cap: 'Daily conversations sorted cleanly',
      t2Title: 'Grouped by speaker, photos right inline',
      t2Desc: 'Turns are grouped naturally (labeled "Inferred" until confirmed), with photos placed right beside what was said.',
      t2Cap: 'Dialogue and photos aligned by moment',
      t3Title: 'Takeaways, structure & to-dos, ready to share',
      t3Desc: 'Combine any recordings into an overview, logic map, and action items — check source quotes or export PDF, Word, and image.',
      t3Cap: 'Overview, logic flow, and action items',
      t4Title: 'Original audio kept, tap any line to replay',
      t4Desc: 'Read clean notes first, and tap any sentence in the raw view whenever you want to hear the exact recording.',
      t4Cap: 'Tap any sentence to replay original audio',
      t5Title: 'Flip to record, visible right on Lock Screen',
      t5Desc: 'Start low-power capture in one tap with Live Activity on your Lock Screen — and automatic phone failover if disconnected.',
      t5Cap: 'Card status synced with Lock Screen Live Activity',
      s3Eyebrow: 'BUILT AROUND YOU',
      s3Title: 'Follows your habits. Keeps your privacy.',
      s3Desc: 'Good tools stay out of your way — ready when you need them, invisible when you don\'t.',
      v1Tag: 'PRIVACY FIRST',
      v1Title: 'Recordings stay on your phone',
      v1Desc: 'Speech turns into text right on your phone. Your original audio stays off our servers by default.',
      v2Tag: 'ALWAYS READY',
      v2Title: 'Saves phone battery, never drops a word',
      v2Desc: 'The card records efficiently without heating up your phone. If it runs out of battery or disconnects, your phone steps in seamlessly.',
      v3Tag: 'VERIFIABLE',
      v3Title: 'Clean takeaways, original words intact',
      v3Desc: 'Read tidy summaries without filler words first, while keeping the raw transcript and original audio whenever you want to double-check or delete.',
      v4Tag: 'FLEXIBLE',
      v4Title: 'Card, phone, watch, or your own gear',
      v4Desc: 'Wear the AI Card all day, or record with your phone, Apple Watch, Get Note card, or Omi — everything lands in one timeline.',
      s4Eyebrow: 'FAQ',
      s4Title: 'Frequently asked questions',
      fq1: 'Will recording all day drain or heat up my phone?',
      fa1: 'No. While connected, the card handles recording on its own and your phone\'s mic stays completely idle, using barely any battery.',
      fq2: 'Are my recordings private? Can anyone else hear them?',
      fa2: 'Your original audio stays on your phone and turns into text locally — audio never leaves your device by default. You can delete any item or wipe everything anytime.',
      fq3: 'Does it work offline, like on a flight or in a basement?',
      fa3: 'Yes. Recording and transcription work completely offline. Once you\'re back online, summaries generate automatically.',
      fq4: 'Can I start using the app before getting the physical card?',
      fa4: 'Yes. Record right away with your phone or Apple Watch (double-tap to mark key moments), or connect an existing Get Note card or Omi. Pair your AI Card anytime later.',
      fq5: 'Is the early-bird waitlist free? What do I get?',
      fa5: 'Completely free. Every early-bird signup gets at least 1 month of full membership at launch and enters the giveaway for a physical AI Card (worth ¥1,000).',
      wlTitle: 'Reserve early access',
      wlDesc: 'Leave your email and we\'ll notify you the moment we launch.',
      wlEmailPlaceholder: 'Your email, e.g. you@example.com',
      wlSubmit: 'Join Free Waitlist',
      wlPerk1: 'Guaranteed at least 1 month of full membership',
      wlPerk2: 'Automatic entry to win a physical AI Card (worth ¥1,000)',
      wlErrEmail: 'Please enter a valid email address.',
      wlDoneTitle: 'You\'re on the list',
      wlDoneDesc: 'Saved {email} ({platform}). We\'ll email you at launch — your 1+ month membership and ¥1,000 AI Card giveaway entry are locked in.',
      wlReset: 'Use a different email',
      modalTitle: 'Join the Early-Bird Waitlist',
      modalLead: 'Leave your email for launch access: get at least 1 month of membership and a chance to win a physical AI Card (worth ¥1,000).',
      footCopy: '© 2026 ReAI · AI Card',
      hwName: 'AI CARD'
    }
  };

  var currentLang = 'zh';
  try {
    var urlParams = new URLSearchParams(window.location.search);
    var qLang = urlParams.get('lang');
    var savedLang = localStorage.getItem('aicard-lang');
    if (qLang === 'en' || qLang === 'zh') currentLang = qLang;
    else if (savedLang === 'en' || savedLang === 'zh') currentLang = savedLang;
  } catch (e) {}

  var lastPushMode = 'prompt';
  var lastMarkTime = '01:24:08';

  function t(key) {
    return (I18N[currentLang] && I18N[currentLang][key]) || I18N.zh[key] || key;
  }

  function renderHeroTitle() {
    var el = document.getElementById('hero-title');
    if (!el) return;
    var segs = HERO_SEGMENTS[currentLang] || HERO_SEGMENTS.zh;
    el.textContent = '';
    segs.forEach(function (seg) {
      var node;
      if (seg.strike) node = document.createElement('s');
      else if (seg.em) node = document.createElement('em');
      else node = document.createElement('span');
      node.textContent = seg.text;
      el.appendChild(node);
      if (seg.br) el.appendChild(document.createElement('br'));
    });
  }

  function appendPushLine(parent, badgeText, badgeClass, bodyText) {
    var line = document.createElement('div');
    line.className = 'push-line';
    var badge = document.createElement('span');
    badge.className = badgeClass ? 'push-badge ' + badgeClass : 'push-badge';
    badge.textContent = badgeText;
    var text = document.createElement('span');
    text.textContent = bodyText;
    line.appendChild(badge);
    line.appendChild(text);
    parent.appendChild(line);
  }

  function renderPushFeed() {
    var pushFeed = document.getElementById('push-feed');
    if (!pushFeed) return;
    pushFeed.textContent = '';
    if (lastPushMode === 'prompt') {
      appendPushLine(pushFeed, t('pushPromptBadge'), '', t('pushPromptText'));
    } else if (lastPushMode === 'mark') {
      appendPushLine(
        pushFeed,
        t('pushMarkBadge'),
        'mark',
        t('pushMarkText').replace('{time}', lastMarkTime)
      );
    } else if (lastPushMode === 'cmd-a') {
      appendPushLine(pushFeed, t('pushABadge'), '', t('pushAText'));
    } else if (lastPushMode === 'cmd-b') {
      appendPushLine(pushFeed, t('pushABadge'), '', t('pushAText'));
      appendPushLine(pushFeed, t('pushBBadge'), 'ok', t('pushBText'));
    }
  }

  function applyLang(lang) {
    currentLang = lang === 'en' ? 'en' : 'zh';
    document.documentElement.lang = currentLang === 'en' ? 'en' : 'zh-CN';
    document.title = t('pageTitle');

    try { localStorage.setItem('aicard-lang', currentLang); } catch (e) {}

    renderHeroTitle();

    document.querySelectorAll('[data-i18n]').forEach(function (el) {
      var k = el.getAttribute('data-i18n');
      el.textContent = t(k);
    });

    var brandLogo = document.getElementById('brand-logo');
    if (brandLogo) brandLogo.setAttribute('alt', t('brandName'));

    document.querySelectorAll('[data-i18n-placeholder]').forEach(function (el) {
      var k = el.getAttribute('data-i18n-placeholder');
      el.setAttribute('placeholder', t(k));
    });

    for (var i = 1; i <= 5; i++) {
      var tab = document.querySelector('[data-tab-idx="' + i + '"]');
      if (tab && tab.classList.contains('active')) {
        document.getElementById('shot-caption').textContent = t('t' + i + 'Cap');
      }
    }

    var langZh = document.getElementById('lang-zh');
    var langEn = document.getElementById('lang-en');
    if (langZh && langEn) {
      langZh.classList.toggle('on', currentLang === 'zh');
      langEn.classList.toggle('on', currentLang === 'en');
    }

    var island = document.getElementById('island');
    var islandText = document.getElementById('island-text');
    if (island && islandText) {
      if (island.classList.contains('listening')) {
        islandText.textContent = t('islandListening');
      } else if (lastPushMode === 'mark') {
        islandText.textContent = t('islandMarkedPrefix') + lastMarkTime;
      } else {
        islandText.textContent = t('islandIdle');
      }
    }

    renderPushFeed();
    renderWaitlistState();
  }

  // 1. Live Clock
  var sec = 1 * 3600 + 24 * 60 + 8;
  var clockEl = document.getElementById('island-clock');
  setInterval(function () {
    sec += 1;
    var h = String(Math.floor(sec / 3600)).padStart(2, '0');
    var m = String(Math.floor((sec % 3600) / 60)).padStart(2, '0');
    var s = String(sec % 60).padStart(2, '0');
    clockEl.textContent = h + ':' + m + ':' + s;
  }, 1000);

  // 2. Interactive Card Buttons
  var island = document.getElementById('island');
  var islandText = document.getElementById('island-text');
  var cmdTimer = null;

  document.getElementById('btn-mark').addEventListener('click', function () {
    if (cmdTimer) { clearTimeout(cmdTimer); cmdTimer = null; }
    lastMarkTime = clockEl.textContent;
    lastPushMode = 'mark';
    island.classList.remove('listening');
    islandText.textContent = t('islandMarkedPrefix') + lastMarkTime;
    renderPushFeed();
  });

  document.getElementById('btn-cmd').addEventListener('click', function () {
    if (cmdTimer) { clearTimeout(cmdTimer); }
    lastPushMode = 'cmd-a';
    island.classList.add('listening');
    islandText.textContent = t('islandListening');
    renderPushFeed();

    cmdTimer = setTimeout(function () {
      lastPushMode = 'cmd-b';
      island.classList.remove('listening');
      islandText.textContent = t('islandIdle');
      renderPushFeed();
    }, 1200);
  });

  // 3. App Showcase Tabs
  var tabs = document.querySelectorAll('.feat-tab');
  var shotImg = document.getElementById('app-shot');
  var shotCap = document.getElementById('shot-caption');

  tabs.forEach(function (tab) {
    tab.addEventListener('click', function () {
      tabs.forEach(function (tb) {
        tb.classList.remove('active');
        tb.setAttribute('aria-selected', 'false');
      });
      tab.classList.add('active');
      tab.setAttribute('aria-selected', 'true');
      shotImg.src = tab.getAttribute('data-shot');
      var idx = tab.getAttribute('data-tab-idx');
      shotCap.textContent = t('t' + idx + 'Cap');
    });
  });

  // 4. FAQ Accordion
  var faqItems = document.querySelectorAll('.faq-item');
  faqItems.forEach(function (item) {
    var btn = item.querySelector('.faq-q');
    if (!btn) return;
    btn.addEventListener('click', function () {
      var willOpen = !item.classList.contains('open');
      faqItems.forEach(function (other) {
        other.classList.remove('open');
        var otherBtn = other.querySelector('.faq-q');
        if (otherBtn) otherBtn.setAttribute('aria-expanded', 'false');
      });
      if (willOpen) {
        item.classList.add('open');
        btn.setAttribute('aria-expanded', 'true');
      }
    });
  });

  // 5. Waitlist Registration (Inline Section & Modal)
  var WL_KEY = 'aicard-waitlist-v1';

  function getSavedWaitlist() {
    try {
      var raw = localStorage.getItem(WL_KEY);
      return raw ? JSON.parse(raw) : null;
    } catch (e) {
      return null;
    }
  }

  function saveWaitlist(email, platform) {
    var payload = { email: email, platform: platform, ts: Date.now() };
    try { localStorage.setItem(WL_KEY, JSON.stringify(payload)); } catch (e) {}
    return payload;
  }

  function clearWaitlist() {
    try { localStorage.removeItem(WL_KEY); } catch (e) {}
  }

  function renderWaitlistState() {
    var saved = getSavedWaitlist();
    document.querySelectorAll('[data-wl-widget]').forEach(function (wrap) {
      var form = wrap.querySelector('.wl-form');
      var done = wrap.querySelector('.wl-done');
      var err = wrap.querySelector('.wl-err');
      if (err) err.textContent = '';
      if (saved && saved.email) {
        form.hidden = true;
        done.hidden = false;
        done.querySelector('.wl-done-title').textContent = t('wlDoneTitle');
        done.querySelector('.wl-done-desc').textContent =
          t('wlDoneDesc').replace('{email}', saved.email).replace('{platform}', saved.platform);
      } else {
        form.hidden = false;
        done.hidden = true;
      }
    });
  }

  document.querySelectorAll('[data-wl-widget]').forEach(function (wrap) {
    var form = wrap.querySelector('.wl-form');
    var emailInput = wrap.querySelector('input[type="email"]');
    var platSelect = wrap.querySelector('select');
    var err = wrap.querySelector('.wl-err');
    var resetBtn = wrap.querySelector('.wl-reset');

    form.addEventListener('submit', function (e) {
      e.preventDefault();
      var val = (emailInput.value || '').trim();
      if (!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(val)) {
        err.textContent = t('wlErrEmail');
        emailInput.focus();
        return;
      }
      err.textContent = '';
      saveWaitlist(val, platSelect.value);
      renderWaitlistState();
    });

    if (resetBtn) {
      resetBtn.addEventListener('click', function () {
        clearWaitlist();
        renderWaitlistState();
      });
    }
  });

  // 6. Modal
  var modal = document.getElementById('modal');
  function openModal() { modal.classList.add('open'); }
  function closeModal() { modal.classList.remove('open'); }
  document.querySelectorAll('[data-open-modal]').forEach(function (btn) {
    btn.addEventListener('click', openModal);
  });
  document.getElementById('modal-close').addEventListener('click', closeModal);
  modal.addEventListener('click', function (e) {
    if (e.target === modal) closeModal();
  });
  document.addEventListener('keydown', function (e) {
    if (e.key === 'Escape') closeModal();
  });

  // 7. Language Switcher
  document.getElementById('lang-zh').addEventListener('click', function () { applyLang('zh'); });
  document.getElementById('lang-en').addEventListener('click', function () { applyLang('en'); });

  // 8. Scene Videos（悬停看封面 · 点击播放；同时只播一个）
  var demoCards = document.querySelectorAll('.demo-video');
  demoCards.forEach(function (card) {
    var video = card.querySelector('video');
    if (!video) return;
    card.addEventListener('click', function () {
      if (video.paused) {
        demoCards.forEach(function (other) {
          var v = other.querySelector('video');
          if (other !== card && v && !v.paused) v.pause();
        });
        var playPromise = video.play();
        if (playPromise && typeof playPromise.catch === 'function') {
          playPromise.catch(function () {});
        }
      } else {
        video.pause();
      }
    });
    video.addEventListener('play', function () { card.classList.add('playing'); });
    video.addEventListener('pause', function () { card.classList.remove('playing'); });
    video.addEventListener('ended', function () {
      card.classList.remove('playing');
      try { video.load(); } catch (e) {}
    });
  });

  // Init
  applyLang(currentLang);
})();
