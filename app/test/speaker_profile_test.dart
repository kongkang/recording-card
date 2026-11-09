import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:recording_card/services/recordings/speaker_profile_store.dart';

const _a = [1.0, 0.0, 0.0];
const _b = [0.0, 1.0, 0.0];
const _nearA = [0.98, 0.15, 0.0];
const _c = [0.0, 0.0, 1.0];

SessionSpeakerMatcher matcher({int maxSpeakers = 6}) =>
    SessionSpeakerMatcher(maxSpeakers: maxSpeakers);

void main() {
  group('SessionSpeakerMatcher', () {
    test('首个文件：按语音时长分配编号，主导说话人是 1', () {
      final result = matcher().assign(
        existing: SpeakerProfileSet.empty('S1'),
        fileCentroids: {0: _b, 1: _a},
        clusterSpeechMs: {0: 3000, 1: 7000},
        deviceName: 'A.APM',
      );

      expect(result.clusterToSpeaker, {0: 1, 1: 0});
      expect(result.profiles.profiles.map((p) => p.index), [0, 1]);
      expect(result.profiles.contributors, {'A.APM'});
    });

    test('第二个文件：簇号顺序不同也沿用会话编号', () {
      final first = matcher().assign(
        existing: SpeakerProfileSet.empty('S1'),
        fileCentroids: {0: _a, 1: _b},
        clusterSpeechMs: {0: 6000, 1: 4000},
        deviceName: 'A.APM',
      );
      final second = matcher().assign(
        existing: first.profiles,
        fileCentroids: {0: _b, 1: _nearA},
        clusterSpeechMs: {0: 5000, 1: 7000},
        deviceName: 'B.APM',
      );

      expect(second.clusterToSpeaker, {0: 1, 1: 0});
      expect(second.profiles.contributors, {'A.APM', 'B.APM'});
    });

    test('匹配不上：分配新编号（未超过说话人上限）', () {
      final first = matcher().assign(
        existing: SpeakerProfileSet.empty('S1'),
        fileCentroids: {0: _a},
        clusterSpeechMs: {0: 5000},
        deviceName: 'A.APM',
      );
      final second = matcher().assign(
        existing: first.profiles,
        fileCentroids: {0: _b},
        clusterSpeechMs: {0: 4000},
        deviceName: 'B.APM',
      );

      expect(second.clusterToSpeaker, {0: 1});
      expect(second.profiles.profiles.length, 2);
    });

    test('跨文件匹配阈值更严：0.62~0.75 之间不并成一号', () {
      final first = matcher().assign(
        existing: SpeakerProfileSet.empty('S1'),
        fileCentroids: {0: _a},
        clusterSpeechMs: {0: 5000},
        deviceName: 'A.APM',
      );
      // cos([1,0,0], [0.7, 0.714, 0]) = 0.7：单文件聚类会合并，跨文件不合并
      final second = matcher().assign(
        existing: first.profiles,
        fileCentroids: {
          0: [0.7, math.sqrt(0.51), 0.0],
        },
        clusterSpeechMs: {0: 4000},
        deviceName: 'B.APM',
      );

      expect(second.clusterToSpeaker, {0: 1});
      expect(second.profiles.profiles.length, 2);
    });

    test('达到说话人上限：贴到最相近的旧编号，不无限新增', () {
      final first = matcher(maxSpeakers: 2).assign(
        existing: SpeakerProfileSet.empty('S1'),
        fileCentroids: {0: _a, 1: _b},
        clusterSpeechMs: {0: 5000, 1: 5000},
        deviceName: 'A.APM',
      );
      final second = matcher(maxSpeakers: 2).assign(
        existing: first.profiles,
        fileCentroids: {0: _c},
        clusterSpeechMs: {0: 4000},
        deviceName: 'B.APM',
      );

      expect(second.profiles.profiles.length, 2);
      expect(second.clusterToSpeaker[0], anyOf(0, 1));
    });

    test('同一文件重跑：质心与累计时长不重复累加', () {
      final first = matcher().assign(
        existing: SpeakerProfileSet.empty('S1'),
        fileCentroids: {0: _a},
        clusterSpeechMs: {0: 6000},
        deviceName: 'A.APM',
      );
      final again = matcher().assign(
        existing: first.profiles,
        fileCentroids: {0: _a},
        clusterSpeechMs: {0: 6000},
        deviceName: 'A.APM',
      );

      expect(
        again.profiles.profiles.single.speechMs,
        first.profiles.profiles.single.speechMs,
      );
      expect(again.profiles.toJson(), first.profiles.toJson());
    });

    test('质心按时长加权：长语音文件的影响更大', () {
      final first = matcher().assign(
        existing: SpeakerProfileSet.empty('S1'),
        fileCentroids: {0: _a},
        clusterSpeechMs: {0: 9000},
        deviceName: 'A.APM',
      );
      final second = matcher().assign(
        existing: first.profiles,
        fileCentroids: {0: const [0.8, 0.6, 0.0]},
        clusterSpeechMs: {0: 1000},
        deviceName: 'B.APM',
      );
      final centroid = second.profiles.profiles.single.centroid;

      expect(centroid[0], greaterThan(0.98));
      expect(centroid[1], lessThan(0.1));
      expect(second.profiles.profiles.single.speechMs, 10000);
    });

    test('空质心：不产生映射，也不写档案', () {
      final result = matcher().assign(
        existing: SpeakerProfileSet.empty('S1'),
        fileCentroids: const {},
        clusterSpeechMs: const {},
        deviceName: 'A.APM',
      );

      expect(result.clusterToSpeaker, isEmpty);
      expect(result.profiles.profiles, isEmpty);
    });
  });

  group('SpeakerProfileStore', () {
    late Directory root;
    late SpeakerProfileStore store;

    setUp(() async {
      root = await Directory.systemTemp.createTemp('rc-spk-');
      store = SpeakerProfileStore(root: root);
    });

    tearDown(() async {
      if (await root.exists()) await root.delete(recursive: true);
    });

    test('落盘到 recordings/_sessions，读回一致', () async {
      const set = SpeakerProfileSet(
        session: 'A1B2C3D4',
        profiles: [
          SpeakerProfile(index: 0, centroid: _a, speechMs: 6000),
          SpeakerProfile(index: 1, centroid: _b, speechMs: 3000),
        ],
        contributors: {'A.APM', 'B.APM'},
      );
      await store.save(set);

      final path = store.fileFor('A1B2C3D4').path;
      expect(path, contains('_sessions'));
      final loaded = await store.load('A1B2C3D4');
      expect(loaded.toJson(), set.toJson());
    });

    test('没有文件时返回空表', () async {
      final loaded = await store.load('NOPE');
      expect(loaded.profiles, isEmpty);
      expect(loaded.contributors, isEmpty);
    });

    test('文件损坏时退回空表，不抛异常', () async {
      final file = store.fileFor('BROKEN');
      await file.parent.create(recursive: true);
      await file.writeAsString('{not json');

      final loaded = await store.load('BROKEN');
      expect(loaded.profiles, isEmpty);
    });

    test('JSON 结构：版本、会话、贡献文件与质心', () async {
      await store.save(
        const SpeakerProfileSet(
          session: 'S1',
          profiles: [SpeakerProfile(index: 0, centroid: _a, speechMs: 1)],
          contributors: {'A.APM'},
        ),
      );
      final decoded =
          jsonDecode(await store.fileFor('S1').readAsString())
              as Map<String, dynamic>;

      expect(decoded['v'], 1);
      expect(decoded['ses'], 'S1');
      expect(decoded['files'], ['A.APM']);
      expect((decoded['spk'] as List).single, containsPair('i', 0));
    });
  });
}
