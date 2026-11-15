(function () {
  var I18N = {
    zh: {
      pageTitle: 'AI Card · 录音卡 — 随身语音记忆硬件与端侧优先伴侣 App',
      brandName: 'AI Card · 录音卡',
      navPipeline: '处理链路',
      navApp: '伴侣 App',
      navHardware: '物理按键',
      navPrivacy: '隐私架构',
      navSpecs: '技术规格',
      navCta: '早鸟登记',
      heroKicker: 'ALWAYS-ON VOICE MEMORY · 物理按键 × 本地转写',
      heroTitle: '把每天说过的每句话，整理成可检索的记忆。',
      heroLead: '一张随身录音卡，一套端侧优先的伴侣 App。无感连续录音、SenseVoice 本地转写、声纹与上下文推理，晚上帮你写好睡前日记与三元记忆图谱。',
      heroCtaPrimary: '加入早鸟 Waitlist',
      heroCtaSecondary: '查看 App 真实界面',
      heroPerk: '早鸟礼遇：登记即赠至少 1 个月会员 · 抽实体录音卡（价值 ¥1,000）',
      meta1: 'SenseVoice + Silero VAD 端侧转写',
      meta2: 'BLE 5.3 + 2.4GHz Wi-Fi',
      meta3: 'GNU AGPL-3.0 开源',
      stageLabel: 'INTERACTIVE HARDWARE PREVIEW',
      capsuleStatus: 'DYJ-Card · 录音中',
      islandIdle: '灵动岛实况 · 硬件录音中',
      islandListening: '正在聆听：前几天看的电影叫什么？',
      islandMarkedPrefix: '已打重点 Mark · ',
      pressHint: 'PRESS TO TEST →',
      btnMark: '单击 · 打重点',
      btnCmd: '长按 · 语音提问',
      pushPromptBadge: '提示',
      pushPromptText: '点击上方卡片按钮，体验「单击打重点 Mark」与「长按唤起灵动岛双阶段推送」。',
      pushMarkBadge: 'MARK',
      pushMarkText: '已记录物理键单击打点（{time}），今晚睡前日记与总结将重点关注此段上下文。',
      pushABadge: 'A · 立即',
      pushAText: '我现在就去查一下，找到和你说。',
      pushBBadge: 'B · 结果',
      pushBText: '找到了，是《007黄金眼》，在前天 9 月 5 日周三下午看的，你还吃了爆米花。',
      s1Num: '01 / SIGNAL PIPELINE',
      s1Title: '从设备切片到记忆图谱，每一步都有诚实边界。',
      s1Desc: '连续录音默认不分段，5 分钟自动切片传回手机；音频与转写默认留在本机，云端只处理用于润色与总结的文本。',
      p1Pill: '硬件',
      p1Title: '随身采集与盲按打点',
      p1Desc: '支持 DYJ 系列录音卡 BLE 连接与 2.4GHz Wi-Fi 自动同步；手机连接硬件期间不并行开麦，断连时本机零功耗待命自动接力。',
      p1Foot: '5 min / 切片 · BLE + STA',
      p2Pill: '端侧',
      p2Title: '本地 VAD 与离线转写',
      p2Desc: 'Silero VAD 切分静音，SenseVoice 直接在手机端侧完成转写；模型缺失时音频入库排队，绝不偷传音频或编造文本。',
      p2Foot: 'Audio stays on-device',
      p3Pill: '清洗',
      p3Title: '增量润色与逻辑分段',
      p3Desc: '连续录音遇到 ≥1 分钟空白触发话题切片，<30 秒紧邻分片自动合并；去除口癖改口，同时完整保留低权重原始对话。',
      p3Foot: '相对起点毫秒时间戳',
      p4Pill: '记忆',
      p4Title: '睡前日记与三元图谱',
      p4Desc: '每晚生成 1～5 项轻标注确认说话人与打点意图，夜间做梦整理「事件 — 关系 — 实体」图谱并提炼可复用 Skill。',
      p4Foot: 'Event · Relation · Entity',
      s2Num: '02 / COMPANION APP',
      s2Title: '没有多余花哨的面板，只有时间轴和可验证的结论。',
      s2Desc: '点击左侧模块，在右侧真实 App 界面中切换查看核心交互。',
      t1Title: 'Timeline 时间轴与相册融合',
      t1Desc: '按今天、昨天倒序排列；点击卡片展开摘要、说话人与打点标记，再点「详情」进入对话流。拍照按时刻自动嵌入对话，支持一键移入或分拣「未归类图片」。',
      t1Tags: ['折叠两行防干扰', '顶部正在录音状态块', '宽屏双栏对照'],
      t1Cap: 'Timeline · 按日倒序与事件展开态',
      t2Title: '多维度总结与双向溯源',
      t2Desc: '勾选今日、本周或任意片段生成结构化总结：概览、逻辑结构、信息点、行动项与合并后全文。每条行动项都可定位原话与现场图，支持导出 Markdown / PDF / 图片 / Word。',
      t2Tags: ['吸顶目录跳转', '@说话人芯片', '来源记录双向回跳'],
      t2Cap: 'Summary · 结构化总结与行动项溯源',
      t3Title: '睡前日记与轻标注确认',
      t3Desc: '告别枯燥的自动会议纪要。每晚用叙事回顾当天经历，高亮上下文推理（支持点赞调高权重），只问你 1～5 个模型无法自行证伪的细节，一锤定音后反哺当晚记忆整理。',
      t3Tags: ['1~5 项轻标注', '上下文呼语推理', '点击即可绑定声纹'],
      t3Cap: 'Bedtime Diary · 睡前轻标注反哺做梦',
      t4Title: '端侧声纹与三元记忆图谱',
      t4Desc: '通过 3D-Speaker CAM++ 在端侧聚类说话人（未确认前始终标注「推测」），确认后沉淀跨对话人物偏好、关系边与私有概念，越用越懂你的团队语境。',
      t4Tags: ['5 个常用自动槽位', '第 1 槽位锁定我的声音', '实体 · 关系 · 事件'],
      t4Cap: 'Memory Graph · 声纹聚类与三元图谱',
      t5Title: '夜间做梦漫画与重复 Skill 养成',
      t5Desc: '夜间空白超过 5 小时自动进入「做梦」整理，按需生成 4～6 格梦境漫画；当发现同一类琐事重复出现 2～3 次，主动提醒沉淀为可复用 Agent Skill。',
      t5Tags: ['4~6 格梦境漫画', '重复事项识别', '图谱节点纠偏'],
      t5Cap: 'Dreaming · 夜间做梦漫画与 Skill 养成',
      s3Num: '03 / HARDWARE & LIVE ACTIVITY',
      s3Title: '不掏手机就能用，断连了也不丢话。',
      s3Desc: '物理按键直接触发记忆检索，硬件优先与零功耗待命机制兼顾续航与可靠性。',
      hwBox1Title: '物理按键交互定义',
      hwBox1Desc: '无需解锁手机或打开 App，盲按录音卡物理按钮即可完成标记与提问。',
      hwKey1Label: '单击 · MARK',
      hwKey1Val: '无感打重点。时间戳随音频写入，模型在总结与睡前日记中优先聚焦此处并推测打点意图。',
      hwKey2Label: '长按 · COMMAND',
      hwKey2Val: '唤起手机顶部灵动岛收听语音提问；松手后先推送 A【立即回执】，查完再推 B【记忆结果】。',
      hwKey3Label: '双击 · RESERVED',
      hwKey3Val: '暂空预留，后续支持绑定自定义快捷指令或特定 Skill。',
      hwBox2Title: '硬件优先与零功耗保底',
      hwBox2Desc: '蓝牙正常录音期间手机麦克风绝不并行采集，避免手机发热耗电；只有意外发生时才接力。',
      hwSb1Label: '正常连接',
      hwSb1Val: '隐藏「本机录音」入口，由硬件低功耗采集并驱动 iOS 灵动岛与锁屏实况卡片。',
      hwSb2Label: '意外断连',
      hwSb2Val: '蓝牙失联、硬件没电或 OTA 重启时，手机本机录音立即自动启动接力，实况卡片无缝切换。',
      hwSb3Label: '重连退回',
      hwSb3Val: '硬件恢复连接后自动停掉手机麦克风，退回零功耗待命状态；手动停录则解除待命。',
      s4Num: '04 / ARCHITECTURE',
      s4Title: '对隐私和数据边界保持克制与诚实。',
      s4Desc: '我们不在产品里包装黑魔法，每一条设计红线都在代码与文档中公开可查。',
      m1Title: '音频默认不出本机',
      m1Desc: '切片、VAD 检测、SenseVoice 语音转写与 CAM++ 声纹 embedding 提取均在手机本地执行；云端仅接收用于润色与总结的文本。',
      m2Title: '说话人只做推测，不断言',
      m2Desc: '未经过你手动确认的说话人永远展示「说话人 1 / 2（推测）」，低置信度片段如实显示「未区分」，保留原始映射可随时纠偏。',
      m3Title: '清洗内容优先，原始记录永不销毁',
      m3Desc: '对话详情与总结默认展示润色后的整洁文本，但原始转写与原始音频切片以低权重完整保留，随时可播放核对或删除。',
      m4Title: 'Rust BLE 桥接与全栈透明',
      m4Desc: 'App 基于 Flutter 构建，通过 Rust C-ABI 桥接 reai-card-sdk 直连真实硬件；OAuth2 PKCE 鉴权与自托管模型网关均可审计。',
      s5Num: '05 / SPECIFICATIONS',
      s5Title: '技术规格与支持环境',
      sp1K: '支持硬件',
      sp1V: 'DYJ 系列随身录音卡（BLE 扫描按 RSSI 信号强度就近排序）',
      sp2K: '传输与固件',
      sp2V: 'BLE 5.3 控制与切片传输 · 2.4GHz Wi-Fi STA 高速同步 · 主控 / Wi-Fi 两阶段 OTA',
      sp3K: '端侧语音引擎',
      sp3V: 'sherpa_onnx · SenseVoice (int8) · Silero VAD · 3D-Speaker CAM++ 声纹聚类',
      sp4K: '客户端支持',
      sp4V: 'iOS（含灵动岛 Live Activity）· Android · Apple Watch 伴侣端',
      sp5K: '开源协议',
      sp5V: 'GNU Affero General Public License v3.0 (AGPL-3.0)',
      wlTitle: '早鸟 Waitlist 登记已开启',
      wlDesc: '留下你的邮箱与常用设备。所有早鸟登记用户承诺赠送至少 1 个月会员，并自动参与实体录音卡抽奖（价值 ¥1,000）。',
      wlEmailPlaceholder: '输入你的常用邮箱，例如 you@example.com',
      wlPlatformLabel: '常用设备',
      wlSubmit: '提交早鸟登记',
      wlPerk1: '承诺赠送至少 1 个月正式版会员',
      wlPerk2: '自动获得实体录音卡抽奖资格（价值 ¥1,000）',
      wlErrEmail: '请输入有效的邮箱地址',
      wlDoneTitle: '已加入早鸟名单',
      wlDoneDesc: '已登记 {email}（{platform}）。上线通知将第一时间发送至该邮箱，你的「1+ 个月会员」与「¥1,000 实体录音卡抽奖资格」已记录。',
      wlReset: '更换邮箱重新登记',
      modalTitle: '早鸟 Waitlist 登记',
      modalLead: '输入邮箱加入 AI Card 早鸟名单：承诺赠送至少 1 个月会员，并参与实体录音卡抽奖（价值 ¥1,000）。',
      footCopy: '© 2026 ReAI · AI Card 录音卡 · ai-card.app.reai.com'
    },
    en: {
      pageTitle: 'AI Card — Always-On Voice Memory Hardware & Local-First Companion App',
      brandName: 'AI Card',
      navPipeline: 'Pipeline',
      navApp: 'App',
      navHardware: 'Hardware',
      navPrivacy: 'Privacy',
      navSpecs: 'Specs',
      navCta: 'Join Waitlist',
      heroKicker: 'ALWAYS-ON VOICE MEMORY · PHYSICAL KEY × ON-DEVICE ASR',
      heroTitle: 'Turn every conversation into searchable memory.',
      heroLead: 'A pocket-sized recording card paired with a local-first companion app. Continuous capture, on-device SenseVoice transcription, voiceprint clustering, and nightly bedtime diaries that build your memory graph.',
      heroCtaPrimary: 'Join Early-Bird Waitlist',
      heroCtaSecondary: 'Explore App Screens',
      heroPerk: 'Early-Bird Perks: At least 1 month free membership · Giveaway for a physical AI Card (worth ¥1,000)',
      meta1: 'SenseVoice + Silero VAD On-Device',
      meta2: 'BLE 5.3 + 2.4GHz Wi-Fi',
      meta3: 'GNU AGPL-3.0 Open Source',
      stageLabel: 'INTERACTIVE HARDWARE PREVIEW',
      capsuleStatus: 'DYJ-Card · Recording',
      islandIdle: 'Live Activity · Card Recording',
      islandListening: 'Listening: What movie did we watch two days ago?',
      islandMarkedPrefix: 'Marked · ',
      pressHint: 'PRESS TO TEST →',
      btnMark: 'Click · Mark',
      btnCmd: 'Hold · Ask Voice',
      pushPromptBadge: 'TIP',
      pushPromptText: 'Click the card buttons above to test "Single-Click Mark" and "Long-Press Dynamic Island A/B Push".',
      pushMarkBadge: 'MARK',
      pushMarkText: 'Keypress mark logged at {time}. Tonight\'s summary and bedtime diary will highlight this context.',
      pushABadge: 'A · INSTANT',
      pushAText: 'Checking your memory graph now — I\'ll ping you as soon as I find it.',
      pushBBadge: 'B · RESULT',
      pushBText: 'Found it: "GoldenEye (007)", watched on Wed Sep 5 afternoon — and you had popcorn.',
      s1Num: '01 / SIGNAL PIPELINE',
      s1Title: 'From raw hardware slices to a structured memory graph, with honest boundaries.',
      s1Desc: 'Continuous recording stays unsegmented by default and syncs in 5-minute slices. Audio and transcripts remain on your phone; only text needed for polishing and summaries is sent to the cloud.',
      p1Pill: 'HARDWARE',
      p1Title: 'Always-On Capture & Blind Mark',
      p1Desc: 'Connects to DYJ recording cards over BLE with 2.4GHz Wi-Fi sync. Your phone mic stays idle while hardware is connected, standing by at zero power for instant failover.',
      p1Foot: '5 min / slice · BLE + STA',
      p2Pill: 'ON-DEVICE',
      p2Title: 'Local VAD & Offline ASR',
      p2Desc: 'Silero VAD trims silence and SenseVoice transcribes directly on-device. If models are missing, audio queues locally — never silently uploaded or fabricated.',
      p2Foot: 'Audio stays on-device',
      p3Pill: 'POLISH',
      p3Title: 'Incremental Polish & Topic Split',
      p3Desc: 'Gaps ≥1 min trigger logical topic segmentation, while <30s adjacent slices merge automatically. Filler words are cleaned while raw transcripts stay preserved.',
      p3Foot: 'Relative ms timestamps',
      p4Pill: 'MEMORY',
      p4Title: 'Bedtime Diary & Triplet Graph',
      p4Desc: 'Each night brings 1–5 lightweight confirmation prompts. Overnight "dreaming" organizes Events, Relations, and Entities and extracts reusable Agent Skills.',
      p4Foot: 'Event · Relation · Entity',
      s2Num: '02 / COMPANION APP',
      s2Title: 'No bloated dashboards. Just a timeline and verifiable conclusions.',
      s2Desc: 'Select a module on the left to inspect real app screens on the right.',
      t1Title: 'Timeline & Contextual Photos',
      t1Desc: 'Grouped by Today and Yesterday in reverse chronological order. Tap to expand summary and speakers, or open Details. Photos align by timestamp and can be sorted from Unclassified.',
      t1Tags: ['2-line collapsed cards', 'Live recording block', 'Split-pane desktop view'],
      t1Cap: 'Timeline · Reverse-chronological feed',
      t2Title: 'Structured Summaries & Backlinks',
      t2Desc: 'Select Today, This Week, or any slices to generate Overview, Logic Flow, Key Points, Action Items, and merged transcripts. Jump straight to source quotes and export Markdown / PDF / Image / Word.',
      t2Tags: ['Sticky TOC', '@Speaker chips', 'Bidirectional source links'],
      t2Cap: 'Summary · Structured insights & action items',
      t3Title: 'Bedtime Diary & Light Annotations',
      t3Desc: 'Skip dry meeting minutes. Read a narrative recap of your day, upvote accurate inferences, and answer 1–5 quick questions the model cannot verify alone to sharpen overnight memory.',
      t3Tags: ['1–5 quick prompts', 'Context name inference', 'One-tap voiceprint bind'],
      t3Cap: 'Bedtime Diary · Light confirmation prompts',
      t4Title: 'On-Device Voiceprints & Memory Graph',
      t4Desc: '3D-Speaker CAM++ clusters speakers locally (always labeled "Inferred" until you confirm). Confirmed profiles accumulate preferences, relations, and team concepts over time.',
      t4Tags: ['5 auto-recognition slots', 'Slot 1 locked to My Voice', 'Entity · Relation · Event'],
      t4Cap: 'Memory Graph · Voiceprints & triplets',
      t5Title: 'Nightly Dream Comics & Skill Discovery',
      t5Desc: 'After 5+ hours of overnight quiet, the app runs "Dreaming" to generate optional 4–6 panel dream comics and spot recurring tasks (2–3x) to turn into reusable Agent Skills.',
      t5Tags: ['4–6 panel comics', 'Recurring task detection', 'Graph node review'],
      t5Cap: 'Dreaming · Nightly comics & Skill extraction',
      s3Num: '03 / HARDWARE & LIVE ACTIVITY',
      s3Title: 'Use it without unlocking your phone. Never lose a word on disconnect.',
      s3Desc: 'Physical key presses trigger memory retrieval directly, while hardware-first zero-power standby protects phone battery.',
      hwBox1Title: 'Physical Button Interactions',
      hwBox1Desc: 'No need to unlock your phone or open the app — press the tactile card button blindly.',
      hwKey1Label: 'CLICK · MARK',
      hwKey1Val: 'Logs a silent highlight timestamp. Summaries and bedtime diaries focus on what was said around your mark.',
      hwKey2Label: 'HOLD · COMMAND',
      hwKey2Val: 'Wakes iOS Dynamic Island to listen to your question, then sends A [Instant Ack] followed by B [Memory Result].',
      hwKey3Label: '2× CLICK · RESERVED',
      hwKey3Val: 'Reserved for custom shortcuts or binding your favorite Agent Skill.',
      hwBox2Title: 'Hardware-First & Zero-Power Standby',
      hwBox2Desc: 'Your phone mic never runs in parallel during normal BLE recording, preventing heat and battery drain.',
      hwSb1Label: 'CONNECTED',
      hwSb1Val: 'Hides the local-mic toggle; the card captures at ultra-low power and drives iOS Dynamic Island & Lock Screen Live Activity.',
      hwSb2Label: 'UNEXPECTED DROP',
      hwSb2Val: 'If BLE drops, battery dies, or OTA reboots, phone recording takes over automatically without missing a beat.',
      hwSb3Label: 'RECONNECTED',
      hwSb3Val: 'Once the card reconnects, the phone mic stops and returns to zero-power standby. Manual stop disarms standby.',
      s4Num: '04 / ARCHITECTURE',
      s4Title: 'Restrained, transparent, and honest about data boundaries.',
      s4Desc: 'No black-box hype — every privacy constraint is enforced in code and documented openly.',
      m1Title: 'Audio Stays On-Device',
      m1Desc: 'Slicing, VAD, SenseVoice ASR, and CAM++ voiceprint embeddings run locally on your phone. Only text for polishing and summaries goes to the cloud.',
      m2Title: 'Inferred, Never Asserted',
      m2Desc: 'Unconfirmed speakers always display "Speaker 1 / 2 (Inferred)", and low-confidence segments show "Unidentified" with full raw mapping preserved.',
      m3Title: 'Clean View First, Raw Data Intact',
      m3Desc: 'Polished transcripts take priority in UI, while original raw ASR text and audio slices remain accessible at low weight for playback or deletion.',
      m4Title: 'Rust BLE Bridge & Open Source',
      m4Desc: 'Built with Flutter + Rust C-ABI bridging reai-card-sdk to real hardware, with OAuth2 PKCE auth and self-hostable model gateways.',
      s5Num: '05 / SPECIFICATIONS',
      s5Title: 'Technical Specifications',
      sp1K: 'Supported Hardware',
      sp1V: 'DYJ-series pocket recording cards (BLE scan sorted by RSSI proximity)',
      sp2K: 'Connectivity & OTA',
      sp2V: 'BLE 5.3 control & slice transfer · 2.4GHz Wi-Fi STA sync · Two-stage MCU / Wi-Fi OTA',
      sp3K: 'On-Device Engine',
      sp3V: 'sherpa_onnx · SenseVoice (int8) · Silero VAD · 3D-Speaker CAM++ clustering',
      sp4K: 'Client Platforms',
      sp4V: 'iOS (with Dynamic Island Live Activity) · Android · Apple Watch companion',
      sp5K: 'License',
      sp5V: 'GNU Affero General Public License v3.0 (AGPL-3.0)',
      wlTitle: 'Join the Early-Bird Waitlist',
      wlDesc: 'Leave your email and primary platform. Every early-bird signup receives at least 1 month of complimentary membership and enters the giveaway for a physical AI Card (worth ¥1,000).',
      wlEmailPlaceholder: 'Enter your email, e.g. you@example.com',
      wlPlatformLabel: 'Platform',
      wlSubmit: 'Join Waitlist',
      wlPerk1: 'Guaranteed at least 1 month of free membership at launch',
      wlPerk2: 'Automatic entry to win a physical AI Card (worth ¥1,000)',
      wlErrEmail: 'Please enter a valid email address.',
      wlDoneTitle: 'You\'re on the Early-Bird List',
      wlDoneDesc: 'Registered {email} ({platform}). We\'ll notify you at launch — your 1+ month free membership and ¥1,000 AI Card giveaway entry are saved.',
      wlReset: 'Register another email',
      modalTitle: 'Early-Bird Waitlist',
      modalLead: 'Join with your email: guaranteed 1+ month of complimentary membership and entry to win a physical AI Card (worth ¥1,000).',
      footCopy: '© 2026 ReAI · AI Card · ai-card.app.reai.com'
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

  function renderPushFeed() {
    var pushFeed = document.getElementById('push-feed');
    if (!pushFeed) return;
    if (lastPushMode === 'prompt') {
      pushFeed.innerHTML =
        '<div class="push-line"><span class="push-badge">' + t('pushPromptBadge') + '</span><span>' + t('pushPromptText') + '</span></div>';
    } else if (lastPushMode === 'mark') {
      pushFeed.innerHTML =
        '<div class="push-line"><span class="push-badge mark">' + t('pushMarkBadge') + '</span><span>' + t('pushMarkText').replace('{time}', lastMarkTime) + '</span></div>';
    } else if (lastPushMode === 'cmd-a') {
      pushFeed.innerHTML =
        '<div class="push-line"><span class="push-badge">' + t('pushABadge') + '</span><span>' + t('pushAText') + '</span></div>';
    } else if (lastPushMode === 'cmd-b') {
      pushFeed.innerHTML =
        '<div class="push-line"><span class="push-badge">' + t('pushABadge') + '</span><span>' + t('pushAText') + '</span></div>' +
        '<div class="push-line"><span class="push-badge ok">' + t('pushBBadge') + '</span><span>' + t('pushBText') + '</span></div>';
    }
  }

  function applyLang(lang) {
    currentLang = lang === 'en' ? 'en' : 'zh';
    document.documentElement.lang = currentLang === 'en' ? 'en' : 'zh-CN';
    document.title = t('pageTitle');

    try { localStorage.setItem('aicard-lang', currentLang); } catch (e) {}

    document.querySelectorAll('[data-i18n]').forEach(function (el) {
      var k = el.getAttribute('data-i18n');
      el.textContent = t(k);
    });

    document.querySelectorAll('[data-i18n-placeholder]').forEach(function (el) {
      var k = el.getAttribute('data-i18n-placeholder');
      el.setAttribute('placeholder', t(k));
    });

    // Update Showcase tab tags & active caption
    for (var i = 1; i <= 5; i++) {
      var tab = document.querySelector('[data-tab-idx="' + i + '"]');
      if (tab) {
        var tagsWrap = tab.querySelector('.feat-tags');
        var tags = t('t' + i + 'Tags');
        if (tagsWrap && Array.isArray(tags)) {
          tagsWrap.innerHTML = tags.map(function (item) { return '<span>' + item + '</span>'; }).join('');
        }
        if (tab.classList.contains('active')) {
          document.getElementById('shot-caption').textContent = t('t' + i + 'Cap');
        }
      }
    }

    // Update language toggle button state
    var langZh = document.getElementById('lang-zh');
    var langEn = document.getElementById('lang-en');
    if (langZh && langEn) {
      langZh.classList.toggle('on', currentLang === 'zh');
      langEn.classList.toggle('on', currentLang === 'en');
    }

    // Update island text if idle
    var island = document.getElementById('island');
    var islandText = document.getElementById('island-text');
    if (island && islandText && !island.classList.contains('listening')) {
      if (lastPushMode === 'mark') islandText.textContent = t('islandMarkedPrefix') + lastMarkTime;
      else islandText.textContent = t('islandIdle');
    }

    renderPushFeed();
    renderWaitlistState();
  }

  // 1. Live Clock on Dynamic Island
  var sec = 1 * 3600 + 24 * 60 + 8;
  var clockEl = document.getElementById('island-clock');
  setInterval(function () {
    sec += 1;
    var h = String(Math.floor(sec / 3600)).padStart(2, '0');
    var m = String(Math.floor((sec % 3600) / 60)).padStart(2, '0');
    var s = String(sec % 60).padStart(2, '0');
    clockEl.textContent = h + ':' + m + ':' + s;
  }, 1000);

  // 2. Interactive Physical Button Demo
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

  // 4. Waitlist Registration (Both Inline Section & Modal)
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

  // 5. Modal
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

  // 6. Language Switcher
  document.getElementById('lang-zh').addEventListener('click', function () { applyLang('zh'); });
  document.getElementById('lang-en').addEventListener('click', function () { applyLang('en'); });

  // Init
  applyLang(currentLang);
})();
