/// 录音记录模型 —— 对应 prototype `EVENTS` 元素。
/// `dayOffset` 为相对今天的天数偏移（0=今天），运行期动态推导日期标签。
library;

class TurnLine {
  final String spk; // 说话人（推测归类：A / B）
  final String text;
  final String src; // 来源时间标注
  const TurnLine(this.spk, this.text, this.src);
}

/// 录音关联照片（来源：点一机 V1 硬件抓拍 `dyj_camera` / 系统相册 `system_album`）。
class EventPhoto {
  final String id;
  final String time; // "14:25:10" 或 "14:25"
  final String path; // 本地 JPEG 路径；空串时界面渲染占位缩略图
  final int? capturedAtMs;
  final String source; // 'dyj_camera' | 'system_album'
  final bool excluded; // 标记「不属于本段」后移入当天顶部「未归类图片」

  const EventPhoto({
    required this.id,
    required this.time,
    this.path = '',
    this.capturedAtMs,
    this.source = 'system_album',
    this.excluded = false,
  });

  EventPhoto copyWith({bool? excluded}) => EventPhoto(
    id: id,
    time: time,
    path: path,
    capturedAtMs: capturedAtMs,
    source: source,
    excluded: excluded ?? this.excluded,
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    't': time,
    if (path.isNotEmpty) 'p': path,
    if (capturedAtMs != null) 'ms': capturedAtMs,
    'src': source,
    if (excluded) 'ex': true,
  };

  factory EventPhoto.fromJson(Map<String, dynamic> j) => EventPhoto(
    id: '${j['id'] ?? ''}',
    time: '${j['t'] ?? ''}',
    path: '${j['p'] ?? ''}',
    capturedAtMs: (j['ms'] as num?)?.toInt(),
    source: '${j['src'] ?? 'system_album'}',
    excluded: j['ex'] == true,
  );
}

/// 当天分组顶部的「未归类图片」条目（在详情页点「不属于本段」后归入此处）。
class UnclassifiedPhotosCard {
  final int dayOffset;
  final String dayLabelText;
  final List<EventPhoto> photos;

  const UnclassifiedPhotosCard({
    required this.dayOffset,
    required this.dayLabelText,
    required this.photos,
  });
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

  /// 分段仍在整理中（时间轴显示「整理中」，不可进详情）。
  final bool live;

  /// 降级提示（部分未润色 / 时间未校准 / 总结未完成）；null 表示正常。
  final String? note;

  /// 本段录音关联照片（含初始注入或持久化恢复）。
  final List<EventPhoto> photos;

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
    this.live = false,
    this.note,
    this.photos = const [],
  });
}

/// 持久化序列化（本地清单用）。字段名保持短、稳定，便于向后兼容。
extension RecordEventJson on RecordEvent {
  Map<String, dynamic> toJson() => {
        'id': id,
        'off': dayOffset,
        'title': title,
        'brief': brief,
        'long': longText,
        'time': time,
        'dur': dur,
        'spk': speakers,
        'mark': mark,
        'map': srcMap,
        'dlg': [
          for (final t in dialog) [t.spk, t.text, t.src]
        ],
        'raw': [
          for (final t in raw) [t.spk, t.text, t.src]
        ],
        if (live) 'live': true,
        if (note != null) 'note': note,
        if (photos.isNotEmpty) 'pics': [for (final p in photos) p.toJson()],
      };
}

/// 反序列化；缺字段按空值兜底，不因历史数据缺失崩溃。
RecordEvent recordEventFromJson(Map<String, dynamic> j) {
  List<TurnLine> turns(Object? value) => [
        for (final t in (value as List? ?? const []))
          if (t is List && t.length >= 3)
            TurnLine('${t[0]}', '${t[1]}', '${t[2]}'),
      ];
  return RecordEvent(
    id: '${j['id'] ?? ''}',
    dayOffset: (j['off'] as num?)?.toInt() ?? 0,
    title: '${j['title'] ?? ''}',
    brief: '${j['brief'] ?? ''}',
    longText: '${j['long'] ?? ''}',
    time: '${j['time'] ?? ''}',
    dur: '${j['dur'] ?? ''}',
    speakers: '${j['spk'] ?? ''}',
    mark: '${j['mark'] ?? ''}',
    srcMap: '${j['map'] ?? ''}',
    dialog: turns(j['dlg']),
    raw: turns(j['raw']),
    live: j['live'] == true,
    note: j['note'] as String?,
    photos: [
      for (final p in (j['pics'] as List? ?? const []))
        if (p is Map<String, dynamic>) EventPhoto.fromJson(p),
    ],
  );
}
