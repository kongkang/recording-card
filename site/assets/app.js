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
      pageTitle: 'AI Card · 录音卡 — 专心聊，它替你记住',
      brandName: 'AI Card · 录音卡',
      navWhat: '能帮你做什么',
      navApp: 'App 界面',
      navDetails: '省心细节',
      navFaq: '常见问题',
      navCta: '早鸟登记',
      heroKicker: 'AI Card · 早鸟预约开放',
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
      t1Title: '按天排好，图文对轨',
      t1Desc: '一天聊了几场、每场讲了什么，两行看清；当时拍的照片就在对话旁。',
      t1Cap: '每天的对话按时间清晰排列',
      t2Title: '结论与待办，一键发给同事',
      t2Desc: '选几段记录就能汇总要点和行动项，点一下核对原话，直接导出 PDF、Word 或长图。',
      t2Cap: '重点、待办与原话随时核对',
      t3Title: '睡前五分钟，轻松回顾今天',
      t3Desc: '晚上把一天的忙碌写成好读的日记；拿不准的人名问你一句，点一下就记住。',
      t3Cap: '像读日记一样回顾一天',
      t4Title: '聊过的人和事，越用越熟',
      t4Desc: '新声音先标「推测」等你确认；认熟之后，自动帮你串起每个人的偏好与约定。',
      t4Cap: '人名与过往约定自动串联',
      t5Title: '睡着时归档，常做的事顺手代劳',
      t5Desc: '夜里自动把记忆整理归档，偶尔画成几格小漫画；重复两三次的琐事还会提醒你下次交办。',
      t5Cap: '一觉醒来，记忆已整理归档',
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
      v4Title: '录音卡、手机、手表都能记',
      v4Desc: '随身戴卡最无感；没带卡时用手机或抬起 Apple Watch 也能录，自动归进同一条时间轴。',
      s4Eyebrow: 'FAQ',
      s4Title: '常见问题',
      fq1: '整天开着录音，手机会跟着耗电发热吗？',
      fa1: '不会。连着录音卡时只由卡片自己录音，手机麦克风完全休息，平时几乎感觉不到耗电。',
      fq2: '我的录音安全吗？别人能听到吗？',
      fa2: '原始录音保存在你自己的手机里，转文字也在本地完成，音频默认不上传云端。你随时可以在手机里单条或全部删除。',
      fq3: '飞机上、地下室这种没网的地方能用吗？',
      fa3: '能。录音和转文字都不依赖网络；等回到有网的地方，再自动帮你生成总结。',
      fq4: '还没有实体录音卡，能先用起来吗？',
      fa4: '可以。App 支持直接用手机录音，也能配合 Apple Watch 抬腕记录；以后拿到录音卡，连上就能接着用。',
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
      footCopy: '© 2026 ReAI · AI Card 录音卡'
    },
    en: {
      pageTitle: 'AI Card — Just talk, it remembers',
      brandName: 'AI Card',
      navWhat: 'What it does',
      navApp: 'The App',
      navDetails: 'Why it fits',
      navFaq: 'FAQ',
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
      t1Title: 'Organized by day, photos inline',
      t1Desc: 'See every conversation at a glance in two clean lines, with photos tucked right beside what was said.',
      t1Cap: 'Your days, cleanly sorted with photos inline',
      t2Title: 'Takeaways & to-dos, ready to share',
      t2Desc: 'Select any conversations to pull out key points and next steps, check exact quotes in one tap, or export as PDF, Word, or image.',
      t2Cap: 'Key points, to-dos, and quotes linked together',
      t3Title: 'Five minutes at night to wrap up the day',
      t3Desc: 'Read your day like a story instead of dry minutes. Confirm an unfamiliar name in one tap so it sticks next time.',
      t3Cap: 'A quick, readable recap before bed',
      t4Title: 'People and promises, remembered over time',
      t4Desc: 'New voices stay labeled "Inferred" until you confirm them. Once confirmed, preferences and past agreements stay connected.',
      t4Cap: 'People, context, and past promises connected',
      t5Title: 'Sorted overnight, chores handled next time',
      t5Desc: 'Quietly organizes your day while you sleep — sometimes into a short comic — and spots repeat errands it can help handle.',
      t5Cap: 'Sorted while you sleep, ready by morning',
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
      v4Title: 'Card, phone, or watch — all one timeline',
      v4Desc: 'Wear the card for hands-free capture, or record with your phone or Apple Watch anytime. Everything lands in the same place.',
      s4Eyebrow: 'FAQ',
      s4Title: 'Frequently asked questions',
      fq1: 'Will recording all day drain or heat up my phone?',
      fa1: 'No. While connected, the card handles recording on its own and your phone\'s mic stays completely idle, using barely any battery.',
      fq2: 'Are my recordings private? Can anyone else hear them?',
      fa2: 'Your original audio stays on your phone and turns into text locally — audio never leaves your device by default. You can delete any item or wipe everything anytime.',
      fq3: 'Does it work offline, like on a flight or in a basement?',
      fa3: 'Yes. Recording and transcription work completely offline. Once you\'re back online, summaries generate automatically.',
      fq4: 'Can I start using the app before getting the physical card?',
      fa4: 'Yes. You can record directly with your phone or Apple Watch right away, and connect the AI Card whenever it arrives.',
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
      footCopy: '© 2026 ReAI · AI Card'
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

  // Init
  applyLang(currentLang);
})();
