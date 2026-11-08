import 'package:flutter_test/flutter_test.dart';
import 'package:recording_card/services/transcribe/speaker_clusterer.dart';

SpeakerSample _s(String id, List<double> v, {int ms = 5000}) =>
    SpeakerSample(id: id, embedding: v, durationMs: ms);

void main() {
  group('SpeakerClusterer', () {
    const clusterer = SpeakerClusterer();

    test('两组明显不同的向量 → 2 个说话人，组内一致', () {
      final result = clusterer.cluster([
        _s('a1', [1, 0, 0.05]),
        _s('b1', [0.05, 1, 0]),
        _s('a2', [0.95, 0.1, 0]),
        _s('b2', [0.1, 0.95, 0]),
      ]);
      final byId = {for (final a in result.assignments) a.id: a};
      expect(result.speakerCount, 2);
      expect(byId['a1']!.cluster, byId['a2']!.cluster);
      expect(byId['b1']!.cluster, byId['b2']!.cluster);
      expect(byId['a1']!.cluster, isNot(byId['b1']!.cluster));
      expect(byId['a1']!.confidence, greaterThan(0.9));
    });

    test('只有一个样本 → 1 个说话人', () {
      final result = clusterer.cluster([_s('a', [1, 0, 0])]);
      expect(result.speakerCount, 1);
      expect(result.assignments.single.cluster, 0);
    });

    test('空向量 → 未区分', () {
      final result = clusterer.cluster([
        _s('a', [1, 0, 0]),
        _s('b', const []),
        _s('c', [0, 0, 0]),
      ]);
      final byId = {for (final a in result.assignments) a.id: a};
      expect(byId['a']!.known, isTrue);
      expect(byId['b']!.cluster, -1);
      expect(byId['c']!.cluster, -1);
    });

    test('极短且孤立的簇判为噪声（未区分）', () {
      final result = clusterer.cluster([
        _s('a1', [1, 0, 0]),
        _s('a2', [0.98, 0.05, 0]),
        _s('b1', [0, 1, 0]),
        _s('b2', [0.05, 0.98, 0]),
        _s('noise', [0, 0, 1], ms: 300),
      ]);
      final byId = {for (final a in result.assignments) a.id: a};
      expect(result.speakerCount, 2);
      expect(byId['noise']!.cluster, -1);
    });

    test('说话时间最多的簇编号为 0（界面显示「说话人 1」）', () {
      final result = clusterer.cluster([
        _s('a1', [1, 0, 0], ms: 9000),
        _s('b1', [0, 1, 0], ms: 2000),
        _s('a2', [0.99, 0.02, 0], ms: 8000),
        _s('b2', [0.02, 0.99, 0], ms: 2000),
      ]);
      final byId = {for (final a in result.assignments) a.id: a};
      expect(byId['a1']!.cluster, 0);
      expect(byId['b1']!.cluster, 1);
    });

    test('质心会输出，供跨文件匹配', () {
      final result = clusterer.cluster([
        _s('a', [1, 0, 0]),
        _s('b', [0, 1, 0]),
      ]);
      expect(result.centroids.keys.toSet(), {0, 1});
      for (final c in result.centroids.values) {
        final norm = c.fold<double>(0, (a, v) => a + v * v);
        expect(norm, closeTo(1.0, 1e-6));
      }
    });
  });
}
