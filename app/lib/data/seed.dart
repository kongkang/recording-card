/// 本地预置示例数据 —— 自 prototype `EVENTS` 原样移植（设计真源，勿改文案）。
/// 边界：未接真实 BLE/ASR/云端；诚实声明只写在文档层（AGENTS/README）。
library;
import '../core/models/record.dart';
import '../core/models/summary.dart';

const _dow = ['周日', '周一', '周二', '周三', '周四', '周五', '周六'];

/// 本周一距今天数（0 表示今天是周一）
int get mondayOffset => (DateTime.now().weekday - 1);

/// 上月同周期一天（与原型 MONPAST=min(MONOFF+7, 当月已过天数) 一致）
int get lastMonthOffset {
  final n = DateTime.now();
  return mondayOffset + 7 <= n.day - 1 ? mondayOffset + 7 : n.day - 1;
}

String dayLabel(int off) {
  if (off == 0) return '今天';
  if (off == 1) return '昨天';
  final d = DateTime.now().subtract(Duration(days: off));
  return '${d.month}月${d.day}日 ${_dow[d.weekday % 7]}';
}

String nowHM() {
  final d = DateTime.now();
  return '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
}

final List<RecordEvent> seedEvents = [
  RecordEvent(
    id: 'e1',
    dayOffset: 0,
    title: '午后项目方向讨论',
    brief: '与同事讨论下一阶段项目方向，明确了交付节奏与分工。讨论中出现排期优先级分歧，约定本周五前给出书面结论，再由负责人确认资源。',
    longText: '与同事讨论下一阶段项目方向，明确了交付节奏与分工。讨论中出现排期优先级分歧，双方各自给出理由后，决定先缩小范围做一版可验证的小方案，约定本周五前给出书面结论，再由负责人确认资源。',
    time: '14:20',
    dur: '18分40秒',
    speakers: 'A / B',
    mark: '重要对话',
    srcMap: '来源 14:20—14:38',
    dialog: [
      TurnLine('A', '这版排期偏紧，特别是测试阶段。', '来源 14:20—14:22'),
      TurnLine('B', '同意。建议先移除两个低优先级功能。', '来源 14:22—14:25'),
      TurnLine('A', '可以，导出功能延后两周。', '来源 14:25—14:27'),
      TurnLine('B', '我整理分工，周五前给出书面结论。', '来源 14:29—14:31'),
      TurnLine('A', '先做一版可验证的小方案，不铺大范围。', '来源 14:34—14:36'),
      TurnLine('B', '下午整理后发出，有问题随时沟通。', '来源 14:36—14:38'),
    ],
    raw: [
      TurnLine('A', '（静音约2分钟）呃……我觉得这版排期有点太紧了，就是那个……测试那一段。', '来源 14:18—14:22 ｜ 清洗版 14:20—14:22'),
      TurnLine('B', '对，嗯，我也这么想。要不我们先砍掉两个低优先级的功能？', '来源 14:22—14:25 ｜ 清洗版 14:22—14:25'),
      TurnLine('A', '可以，那个导出功能可以先放一放，啊不对，是放两周。', '来源 14:25—14:27 ｜ 清洗版 14:25—14:27'),
      TurnLine('B', '那我把分工写一下，那个……周五前给你一份书面的结论。', '来源 14:27—14:31（含停顿）｜ 清洗版 14:29—14:31'),
      TurnLine('A', '好，就先做一版能验证的小方案，别一下子铺太大。', '来源 14:34—14:36 ｜ 清洗版 14:34—14:36'),
      TurnLine('B', '行，那我下午整理完发给你，有问题随时说。', '来源 14:36—14:38 ｜ 清洗版 14:36—14:38'),
    ],
  ),
  RecordEvent(
    id: 'e2',
    dayOffset: 0,
    title: '客户回访要点',
    brief: '电话回访客户，记录对新版本界面的反馈与两条改进建议。客户整体态度积极，但对加载速度提出明确不满，希望下次沟通前有改进数据。',
    longText: '电话回访客户，记录对新版本界面的反馈与两条改进建议：筛选记住上次选择；列表页加载提速。客户整体态度积极，但对加载速度明确表示不满，希望下次沟通前看到改进数据。',
    time: '13:05',
    dur: '9分12秒',
    speakers: 'A / B',
    mark: '',
    srcMap: '来源 13:05—13:14',
    dialog: [
      TurnLine('B', '新界面反馈整体清爽，列表页打开偏慢。', '来源 13:06—13:08'),
      TurnLine('A', '速度问题已记录，下版本专项优化。', '来源 13:08—13:10'),
      TurnLine('B', '筛选希望能记住上次选择条件。', '来源 13:10—13:12'),
      TurnLine('A', '建议有效，已记录。', '来源 13:12—13:14'),
    ],
    raw: [
      TurnLine('B', '那个新界面我们同事都说挺清爽的，就是列表打开有点慢……嗯对，就是列表。', '来源 13:05—13:08 ｜ 清洗版 13:06—13:08'),
      TurnLine('A', '嗯，速度问题我们记下来，下版会专门优化这一块。', '来源 13:08—13:10 ｜ 清洗版 13:08—13:10'),
      TurnLine('B', '还有啊，筛选能不能记住我上次选的条件？每次都要重选，有点麻烦。（静音约10秒）', '来源 13:10—13:12 ｜ 清洗版 13:10—13:12'),
      TurnLine('A', '可以，这个建议很好，我记一下……好的，已经记下来了。', '来源 13:12—13:14 ｜ 清洗版 13:12—13:14'),
    ],
  ),
  RecordEvent(
    id: 'e3',
    dayOffset: 0,
    title: '晨间工作计划',
    brief: '对今日工作的口头规划，列出三件待办并标记一件需重点跟进事项。提到明天上午先确认测试环境是否就绪。',
    longText: '对今日工作的口头规划：发出分工文档、跟进客户加载速度问题、准备周五书面结论三件待办，其中书面结论需重点跟进。提到明天上午先确认测试环境是否就绪。',
    time: '10:12',
    dur: '3分05秒',
    speakers: 'A',
    mark: '',
    srcMap: '来源 10:12—10:15',
    dialog: [
      TurnLine('A', '今日计划：推进排期讨论与客户回访安排。', '来源 10:12—10:13'),
      TurnLine('A', '三件待办：发出分工文档；跟进加载速度问题；准备周五书面结论（重点跟进）。', '来源 10:13—10:14'),
      TurnLine('A', '明日早间先确认测试环境就绪。', '来源 10:14—10:15'),
    ],
    raw: [
      TurnLine('A', '今天打算把排期讨论和客户回访这两块推进一下……嗯，先记三件事。', '来源 10:12—10:13 ｜ 清洗版 10:12—10:13'),
      TurnLine('A', '第一，把分工文档发出去；第二，跟进客户说的加载速度；第三就是准备周五的书面结论，这个要重点盯一下。', '来源 10:13—10:14 ｜ 清洗版 10:13—10:14'),
      TurnLine('A', '对了，明早记得先看看测试环境准备好了没有，别到时候又出岔子。', '来源 10:14—10:15 ｜ 清洗版 10:14—10:15'),
    ],
  ),
  RecordEvent(
    id: 'e4',
    dayOffset: 1,
    title: '与运维确认发布窗口',
    brief: '与运维确认今晚灰度发布窗口与回滚预案，明确灰度比例、监控盯守与发布后状态同步安排。',
    longText: '与运维确认今晚八点开始灰度发布，先放百分之十流量；回滚预案已发群内，监控由运维盯守前半小时，发布完成后在群里同步状态。',
    time: '09:30',
    dur: '5分12秒',
    speakers: 'A / B',
    mark: '',
    srcMap: '来源 09:30—09:35',
    dialog: [
      TurnLine('A', '今晚八点灰度发布，先放百分之十。', '来源 09:30—09:32'),
      TurnLine('B', '回滚预案我放在群里了，监控我盯前半小时。', '来源 09:32—09:34'),
      TurnLine('A', '好，发布完我在群里同步状态。', '来源 09:34—09:35'),
    ],
    raw: [
      TurnLine('A', '那个……今晚八点开始灰度，先放百分之十吧，稳一点。', '来源 09:29—09:32 ｜ 清洗版 09:30—09:32'),
      TurnLine('B', '嗯，回滚预案我发群里了，前半小时我盯着监控。', '来源 09:32—09:34 ｜ 清洗版 09:32—09:34'),
    ],
  ),
  RecordEvent(
    id: 'e5',
    dayOffset: mondayOffset,
    title: '周一例会要点',
    brief: '周例会对齐本周里程碑：接口联调周三前完成，文案周四评审，周五打包提测；风险集中在第三方回调稳定性。',
    longText: '周例会对齐本周里程碑：接口联调周三前完成，文案周四评审，周五打包提测。风险集中在第三方回调稳定性，要求对接方提前提供测试账号。',
    time: '16:40',
    dur: '6分30秒',
    speakers: 'A / B',
    mark: '',
    srcMap: '来源 16:40—16:47',
    dialog: [
      TurnLine('A', '本周里程碑：接口联调周三前完成。', '来源 16:40—16:42'),
      TurnLine('B', '文案周四评审，周五打包提测。', '来源 16:42—16:44'),
      TurnLine('A', '风险还是第三方回调，让对接方提前给测试账号。', '来源 16:44—16:47'),
    ],
    raw: [
      TurnLine('A', '呃，本周的话……接口联调争取周三前搞定。', '来源 16:39—16:42 ｜ 清洗版 16:40—16:42'),
      TurnLine('B', '文案评审放在周四，周五就能打包提测了。', '来源 16:42—16:44 ｜ 清洗版 16:42—16:44'),
    ],
  ),
  RecordEvent(
    id: 'e6',
    dayOffset: lastMonthOffset,
    title: '预约与备忘',
    brief: '口头备忘两件事：下周一下午预约牙医复诊；把体检报告发给保险顾问。',
    longText: '口头备忘两件事：下周一下午预约牙医复诊；把体检报告发给保险顾问。',
    time: '10:05',
    dur: '2分18秒',
    speakers: 'A',
    mark: '',
    srcMap: '来源 10:05—10:08',
    dialog: [
      TurnLine('A', '备忘：下周一下午预约牙医复诊。', '来源 10:05—10:06'),
      TurnLine('A', '体检报告记得发给保险顾问。', '来源 10:07—10:08'),
    ],
    raw: [
      TurnLine('A', '对了，下周一……嗯，下午约一下牙医复诊。', '来源 10:04—10:06 ｜ 清洗版 10:05—10:06'),
      TurnLine('A', '还有体检报告，发给那个保险顾问。', '来源 10:07—10:08 ｜ 清洗版 10:07—10:08'),
    ],
  ),
];

/// 生成完成后的内容填充 —— 与原型 finishSummary 逻辑一致（内容为预置模板）。
void fillSummaryContent(SummaryCard card, List<RecordEvent> events) {
  final ids = card.srcIds.map((id) => events.firstWhere((e) => e.id == id)).toList();
  final offs = ids.map((e) => e.dayOffset).toSet().toList()..sort();
  final String sub;
  if (offs.length == 1) {
    final ts = ids.map((e) => e.time).toList()..sort();
    sub = '${dayLabel(offs.first)} ${ts.first}–${ts.last} · ${ids.length} 条记录';
  } else {
    sub = '跨 ${dayLabel(offs.last)} 至 ${dayLabel(offs.first)} · ${ids.length} 条记录';
  }
  final title = ids.any((e) => e.id == 'e1' || e.id == 'e2') ? '项目排期与客户反馈' : '要点小结';
  final overview = '本次总结覆盖 $sub。围绕项目排期、客户反馈与待办备忘，梳理出核心信息点、逻辑关系与可直接执行的行动建议。';
  card.state = SummaryState.done;
  card.title = title;
  card.subDesc = sub;
  card.overview = overview;
  card.structure = const [
    MapBranch('排期与分工', ['移除低优先级功能', '先做可验证小方案', '周五前书面结论']),
    MapBranch('客户反馈', ['界面清爽获认可', '列表加载偏慢', '筛选记住上次选择']),
    MapBranch('待定决策', ['小方案是否包含导出功能']),
  ];
  card.points = const [
    InfoPoint('排期偏紧，先移除低优先级功能', 'A 与 B 在午后讨论中对比了测试阶段排期与资源投入，认为一次铺大范围风险高；结论是缩小首版范围，先做可验证的小方案，导出功能延后两周。', [SourceRef('e1', '午后项目方向讨论', '14:20—14:27')]),
    InfoPoint('客户对界面整体满意，加载速度是明确不满点', '电话回访中客户反馈新界面清爽，但列表页打开偏慢，希望下次沟通前看到改进数据；已当场承诺下版本专项优化。', [SourceRef('e2', '客户回访要点', '13:06—13:10')]),
    InfoPoint('分工与书面结论在周五前落地', 'B 认领整理分工并在周五前给出书面结论，A 确认排期调整后随时沟通。', [SourceRef('e1', '午后项目方向讨论', '14:29—14:38')]),
    InfoPoint('测试环境需在明早确认就绪', '晨间口头计划中标记为重点跟进事项，避免后续提测阶段受阻。', [SourceRef('e3', '晨间工作计划', '10:14—10:15')]),
  ];
  card.todos = const ['发出分工文档', '跟进客户加载速度问题', '准备周五书面结论'];
  card.srcDesc = ids.map((e) => '${dayLabel(e.dayOffset)} ${e.time} ${e.title}').join('；');
  card.markdown = '# $title\n\n覆盖：$sub\n\n## 概览\n$overview\n\n## 信息点\n${card.points.map((p) => '- ${p.title}').join('\n')}\n\n## 行动项\n${card.todos.map((t) => '- [ ] $t').join('\n')}\n\n## 来源\n${card.srcDesc}';
}
