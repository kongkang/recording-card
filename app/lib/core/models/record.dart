/// 录音记录模型 —— 对应 prototype `EVENTS` 元素。
/// `dayOffset` 为相对今天的天数偏移（0=今天），运行期动态推导日期标签。
library;

class TurnLine {
  final String spk; // 说话人（推测归类：A / B）
  final String text;
  final String src; // 来源时间标注
  const TurnLine(this.spk, this.text, this.src);
}

class RecordEvent {
  final String id;
  final int dayOffset;
  final String title;
  final String brief; // 折叠态摘要（卡片展开时显示的 long 用 longText）
  final String longText;
  final String time; // "14:20"
  final String dur; // "18分40秒"
  final String speakers; // "A / B"
  final String mark; // 标记，可空
  final String srcMap; // "来源 14:20—14:38"
  final List<TurnLine> dialog; // 清洗版对话
  final List<TurnLine> raw; // 原始转写（保留语气词/停顿/静音）

  const RecordEvent({
    required this.id,
    required this.dayOffset,
    required this.title,
    required this.brief,
    required this.longText,
    required this.time,
    required this.dur,
    required this.speakers,
    required this.mark,
    required this.srcMap,
    required this.dialog,
    required this.raw,
  });
}
