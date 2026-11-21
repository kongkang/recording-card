import 'package:flutter_test/flutter_test.dart';
import 'package:recording_card/core/models/record.dart';
import 'package:recording_card/core/models/summary.dart';

RecordEvent _event({
  required String title,
  String brief = '',
  String speakers = '未区分',
  List<TurnLine> dialog = const [],
}) {
  return RecordEvent(
    id: title,
    dayOffset: 0,
    title: title,
    brief: brief,
    longText: brief,
    time: '15:38',
    dur: '10秒',
    speakers: speakers,
    mark: '',
    srcMap: '',
    dialog: dialog,
    raw: dialog,
  );
}

void main() {
  test('无内容和几个字的记录不进入时间轴', () {
    expect(
      isFragmentRecord(
        _event(
          title: '未识别到语音',
          brief: '这段时间没有识别到人声，原始录音仍保留在本机。',
          speakers: '无语音',
        ),
      ),
      isTrue,
    );
    expect(
      isFragmentRecord(
        _event(
          title: '现在',
          brief: '现在',
          dialog: const [TurnLine('未区分', '现在', '15:38')],
        ),
      ),
      isTrue,
    );
    expect(
      isFragmentRecord(
        _event(
          title: '询问深圳晚间天气',
          brief: '核心是确认深圳今晚是否下雨。',
          dialog: const [TurnLine('未区分', '深圳今晚会下雨吗', '15:36')],
        ),
      ),
      isFalse,
    );
  });
}
