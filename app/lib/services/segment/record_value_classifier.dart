/// 低价值记录 / 无意义碎碎念判定与时长聚合。
///
/// 用于时间轴渲染层将连续的无意义短口水（如“我正在说话”、单字“我”、试麦、寒暄等）
/// 与无语音片段合并折叠为紧凑的「无意义碎碎念」胶囊，保留独立记录详情入口，
/// 同时保护包含有效照片、物理按键重点打点或正在整理中的记录不被折叠。
library;

import 'dart:math' as math;

import '../../core/models/record.dart';
import '../../core/models/summary.dart';
import '../transcribe/utterance_builder.dart';

class RecordValueClassifier {
  const RecordValueClassifier._();

  static final RegExp _gapMarkPattern = RegExp(r'^流中断\s*(\d+)\s*次$');
  static final RegExp _specialTags = RegExp(r'<[^>]*>');
  static final RegExp _nonWord = RegExp(r'[^\p{L}\p{N}]', unicode: true);

  /// 常见试麦、自检与纯口水短语（按长到短排列，避免子串先删造成残留）。
  static const List<String> _micTestPhrases = [
    '我正在说话',
    '测试录音',
    '测试一下',
    '能听到吗',
    '试一下',
    '说话中',
    '在说话',
    '我看看',
    '等一下',
    '没关系',
    '喂喂',
    '试音',
    '测试',
    '稍等',
  ];

  static const List<String> _fillerWords = [
    '就是说',
    '然后呢',
    '没关系',
    '等一下',
    '我看看',
    '是不是',
    '对不对',
    '差不多',
    '那个',
    '这个',
    '就是',
    '然后',
    '好的',
    '可以',
    '是的',
    '没有',
    '没事',
    '稍等',
    '嗯',
    '啊',
    '呃',
    '哦',
    '唉',
    '喂',
    '好',
    '行',
    '对',
    '是',
    '吧',
    '呢',
    '呀',
    '嘛',
    '哈',
  ];

  static final RegExp _fallbackTitles = RegExp(
    r'^(?:简短语音|语音片段|最新片段|录音片段|阶段话题|阶段整理|录音整理|未识别到语音|实时切片\s*#?\d*)$',
  );

  /// 是否为无语音事件。
  static bool isSilentEvent(RecordEvent e) =>
      e.speakers == '无语音' || e.title == '未识别到语音';

  /// 保护条件：正在整理中、外部导入记录（GetNote 等）、带非「流中断 N 次」物理打点、
  /// 以及带有效照片的常规说话片段均不得折叠；纯静音片段附带的照片走「未归类图片」分拣，允许折叠。
  static bool isProtectedFromFolding(
    RecordEvent e, {
    required bool hasActivePhotos,
  }) {
    if (e.live) return true;
    if (e.id.startsWith('getnote-') || e.id.startsWith('ext-')) return true;
    if (hasActivePhotos && !isSilentEvent(e) && !isSilentPlaceholderEvent(e)) {
      return true;
    }
    final mk = e.mark.trim();
    if (mk.isNotEmpty && !_gapMarkPattern.hasMatch(mk)) {
      return true;
    }
    return false;
  }

  /// 判断原始转写/对话文本是否属于“无意义碎碎念”。
  static bool isTrivialSpeechText(
    String text, {
    int turnCount = 1,
    String title = '',
  }) {
    final cleanedRaw = _stripToMeaningful(text);
    final rawLen = cleanedRaw.length;
    if (rawLen == 0) return true;

    final titleMeaningful = _stripToMeaningful(title);
    if (titleMeaningful.isNotEmpty &&
        titleMeaningful.length <= 1 &&
        rawLen < 24) {
      return true;
    }

    final matchesMicTest = _micTestPhrases.any(cleanedRaw.contains);
    if (matchesMicTest && turnCount <= 2 && rawLen < 24) {
      return true;
    }

    var stripped = cleanedRaw;
    for (final phrase in _micTestPhrases) {
      stripped = stripped.replaceAll(phrase, '');
    }
    for (final filler in _fillerWords) {
      stripped = stripped.replaceAll(filler, '');
    }
    final cleanLen = stripped.length;
    if (cleanLen <= 2) return true;
    if (cleanLen <= 12 && turnCount <= 2) return true;
    return false;
  }

  /// 时间轴展示是否应归入「无意义碎碎念」胶囊。
  static bool isLowValueForTimeline(
    RecordEvent e, {
    required bool hasActivePhotos,
  }) {
    if (isProtectedFromFolding(e, hasActivePhotos: hasActivePhotos)) {
      return false;
    }
    if (e.lowValue || isSilentEvent(e) || isFragmentRecord(e)) return true;

    final hasTextBody =
        e.dialog.isNotEmpty ||
        e.raw.isNotEmpty ||
        e.brief.trim().isNotEmpty ||
        e.longText.trim().isNotEmpty;
    // 空正文测试夹具（如 feed_order_test）保持普通记录展示，不误折叠。
    if (!hasTextBody) return false;

    final speechText = e.dialog.isNotEmpty
        ? e.dialog.map((t) => t.text).join(' ')
        : (e.raw.isNotEmpty
              ? e.raw.map((t) => t.text).join(' ')
              : (e.longText.trim().isNotEmpty ? e.longText : e.brief));
    final turnCount = e.dialog.isNotEmpty
        ? e.dialog.length
        : (e.raw.isNotEmpty ? e.raw.length : 1);

    final cleanedRaw = _stripToMeaningful(speechText);
    final rawLen = cleanedRaw.length;
    if (rawLen == 0) return true;

    final titleMeaningful = _stripToMeaningful(e.title);
    if (titleMeaningful.isNotEmpty &&
        titleMeaningful.length <= 1 &&
        rawLen < 24) {
      return true;
    }
    if (_micTestPhrases.any(cleanedRaw.contains) &&
        turnCount <= 2 &&
        rawLen < 24) {
      return true;
    }

    // 若记录已经过结构化提炼（拥有独立有意义标题与摘要、与原话并非简单复读），
    // 且并非空口水词，尊重该整理结论不强行折叠。
    final briefClean = _stripToMeaningful(e.brief);
    final longClean = _stripToMeaningful(e.longText);
    final dialogClean = _stripToMeaningful(
      e.dialog.map((t) => t.text).join(' '),
    );
    final hasDistinctMultiRawSummary =
        e.raw.length >= 2 &&
        briefClean.length >= 4 &&
        longClean.length >= 4 &&
        briefClean != longClean &&
        !_fallbackTitles.hasMatch(e.title.trim()) &&
        dialogClean != briefClean &&
        !dialogClean.contains(briefClean);
    final hasCuratedMetadata =
        !_fallbackTitles.hasMatch(e.title.trim()) &&
        titleMeaningful.length >= 4 &&
        briefClean.length >= 4 &&
        titleMeaningful != dialogClean &&
        !dialogClean.contains(titleMeaningful) &&
        dialogClean != briefClean &&
        !dialogClean.contains(briefClean) &&
        !briefClean.contains(dialogClean);
    if (hasDistinctMultiRawSummary || hasCuratedMetadata) {
      var withoutFillers = cleanedRaw;
      for (final filler in _fillerWords) {
        withoutFillers = withoutFillers.replaceAll(filler, '');
      }
      return withoutFillers.length <= 2;
    }

    return isTrivialSpeechText(
      speechText,
      turnCount: turnCount,
      title: e.title,
    );
  }

  /// 从文本生成低价值标记（供本地投影层未经过云端清洗的单段使用）。
  static bool isLocalUtterancesTrivial(
    List<String> texts, {
    String title = '',
  }) {
    final meaningful = texts
        .map((t) => t.trim())
        .where(isMeaningfulSpeechText)
        .toList();
    if (meaningful.isEmpty) return true;
    return isTrivialSpeechText(
      meaningful.join(' '),
      turnCount: meaningful.length,
      title: title,
    );
  }

  static int parseDurationSeconds(String dur) {
    var sec = 0;
    final h = RegExp(r'(\d+)\s*小时').firstMatch(dur);
    final m = RegExp(r'(\d+)\s*分').firstMatch(dur);
    final s = RegExp(r'(\d+)\s*秒').firstMatch(dur);
    if (h != null) sec += (int.tryParse(h.group(1)!) ?? 0) * 3600;
    if (m != null) sec += (int.tryParse(m.group(1)!) ?? 0) * 60;
    if (s != null) sec += int.tryParse(s.group(1)!) ?? 0;
    return sec;
  }

  static String formatDurationSeconds(int totalSeconds) {
    if (totalSeconds <= 0) return '—';
    final h = totalSeconds ~/ 3600;
    final m = (totalSeconds % 3600) ~/ 60;
    final s = totalSeconds % 60;
    if (h > 0) return m == 0 ? '$h小时' : '$h小时$m分';
    if (m == 0) return '$s秒';
    return s == 0 ? '$m分' : '$m分$s秒';
  }

  /// 将连续的低价值记录（已按时间轴倒序排列）聚合为胶囊模型。
  static TrivialClusterCard buildClusterCard(
    int dayOffset,
    List<RecordEvent> itemsDesc,
  ) {
    final ordered = List<RecordEvent>.unmodifiable(itemsDesc);
    var totalSec = 0;
    var silentCount = 0;
    var speechCount = 0;
    for (final e in ordered) {
      totalSec += math.max(0, parseDurationSeconds(e.dur));
      if (isSilentEvent(e)) {
        silentCount++;
      } else {
        speechCount++;
      }
    }
    final latestTime = ordered.first.time.trim();
    final earliestTime = ordered.last.time.trim();
    final timeRange = ordered.length == 1 || latestTime == earliestTime
        ? latestTime
        : '$earliestTime–$latestTime';
    return TrivialClusterCard(
      id: 'trivial-${ordered.first.id}',
      dayOffset: dayOffset,
      items: ordered,
      timeRange: timeRange,
      totalDur: formatDurationSeconds(totalSec),
      speechCount: speechCount,
      silentCount: silentCount,
    );
  }

  static String _stripToMeaningful(String text) =>
      text.replaceAll(_specialTags, '').replaceAll(_nonWord, '').trim();
}
