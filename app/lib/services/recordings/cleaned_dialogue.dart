/// 清洗后对话的展示层合并，对齐 prototype：
/// `joinUtterances` / `mergedDlgParagraphs` / `lifeSpeakerLabel`。
///
/// 同一说话人连续发言留在同一个气泡里。短间隔或相邻/重叠分片拼成一段；
/// 停顿 ≥ 30 秒只在同一气泡里另起一段，不拆成新气泡。只有换人或中间插了照片才换气泡。
library;

import '../../core/models/summary.dart';

/// 同一说话人相邻句之间，达到该间隔则在同一气泡内换段。
const int kCleanDialogueLongPauseSec = 30;

class CleanDialoguePart {
  const CleanDialoguePart({required this.text, this.breakBefore = false});

  final String text;
  final bool breakBefore;
}

class CleanDialogueLine {
  const CleanDialogueLine({
    required this.speakerKey,
    required this.text,
    required this.startSec,
    required this.endSec,
    this.turnIndex = 0,
  });

  final String speakerKey;
  final String text;
  final int startSec;
  final int endSec;
  final int turnIndex;
}

class CleanDialogueBubble {
  const CleanDialogueBubble({
    required this.speakerKey,
    required this.paragraphs,
    required this.startSec,
    required this.endSec,
    required this.firstTurnIndex,
  });

  final String speakerKey;
  final List<String> paragraphs;
  final int startSec;
  final int endSec;
  final int firstTurnIndex;
}

/// 去掉用户可见正文里的工程标记，对应 prototype `lifeSpeakerLabel`。
String lifeSpeakerLabel(String raw) {
  return raw
      .replaceAll('（推测）', '')
      .replaceAll('(推测)', '')
      .replaceAll('（声纹）', '')
      .replaceAll('(声纹)', '')
      .replaceAll('（已命名）', '')
      .replaceAll('(已命名)', '')
      .trim();
}

/// 对应 prototype `joinUtterances`：短间隔拼成一段，`breakBefore` 另起一段。
List<String> joinUtterances(Iterable<CleanDialoguePart> parts) {
  final paras = <String>[];
  var cur = '';
  for (final part in parts) {
    final text = part.text.trim();
    if (text.isEmpty) continue;
    if (part.breakBefore && cur.isNotEmpty) {
      paras.add(cur);
      cur = text;
      continue;
    }
    if (cur.isEmpty) {
      cur = text;
      continue;
    }
    cur = joinPolishedUtterances(cur, text);
  }
  if (cur.isNotEmpty) paras.add(cur);
  return paras;
}

/// 对应 prototype `mergedDlgParagraphs`。
/// [photoSecs] 为按当天秒数定位的插图；夹在两句之间时拆成新气泡。
List<CleanDialogueBubble> mergedDlgParagraphs(
  List<CleanDialogueLine> lines, {
  List<int> photoSecs = const [],
  int longPauseSec = kCleanDialogueLongPauseSec,
}) {
  bool hasPhotoBetween(int prevEnd, int nextStart) {
    if (nextStart <= prevEnd) return false;
    for (final sec in photoSecs) {
      if (sec > prevEnd && sec < nextStart) return true;
    }
    return false;
  }

  final boxes = <_BubbleAcc>[];
  for (final line in lines) {
    final text = line.text.trim();
    if (text.isEmpty) continue;
    final key = lifeSpeakerLabel(line.speakerKey);
    final last = boxes.isNotEmpty ? boxes.last : null;
    if (last != null &&
        last.speakerKey == key &&
        !hasPhotoBetween(last.endSec, line.startSec)) {
      final gapSec = line.startSec - last.endSec;
      last.parts.add(
        CleanDialoguePart(text: text, breakBefore: gapSec >= longPauseSec),
      );
      last.idxs.add(line.turnIndex);
      if (line.endSec > last.endSec) last.endSec = line.endSec;
    } else {
      boxes.add(
        _BubbleAcc(
          speakerKey: key,
          parts: [CleanDialoguePart(text: text)],
          idxs: [line.turnIndex],
          startSec: line.startSec,
          endSec: line.endSec > line.startSec ? line.endSec : line.startSec,
        ),
      );
    }
  }

  return [
    for (final box in boxes)
      if (joinUtterances(box.parts).isNotEmpty)
        CleanDialogueBubble(
          speakerKey: box.speakerKey,
          paragraphs: joinUtterances(box.parts),
          startSec: box.startSec,
          endSec: box.endSec,
          firstTurnIndex: box.idxs.first,
        ),
  ];
}

class _BubbleAcc {
  _BubbleAcc({
    required this.speakerKey,
    required this.parts,
    required this.idxs,
    required this.startSec,
    required this.endSec,
  });

  final String speakerKey;
  final List<CleanDialoguePart> parts;
  final List<int> idxs;
  final int startSec;
  int endSec;
}
