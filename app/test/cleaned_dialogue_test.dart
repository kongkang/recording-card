import 'package:flutter_test/flutter_test.dart';
import 'package:recording_card/services/recordings/cleaned_dialogue.dart';
import 'package:recording_card/services/schedule/organize_pass_service.dart';
import 'package:recording_card/services/segment/fast_topic_segment_agent.dart';
import 'package:recording_card/services/segment/section_copy.dart';

void main() {
  group('joinUtterances / mergedDlgParagraphs', () {
    test('同一说话人短间隔拼成一段', () {
      final bubbles = mergedDlgParagraphs(const [
        CleanDialogueLine(
          speakerKey: '说话人 1',
          text: '先把核心流程走通，',
          startSec: 10,
          endSec: 20,
          turnIndex: 0,
        ),
        CleanDialogueLine(
          speakerKey: '说话人 1',
          text: '再补齐异常分支。',
          startSec: 21,
          endSec: 35,
          turnIndex: 1,
        ),
      ]);
      expect(bubbles, hasLength(1));
      expect(bubbles.single.paragraphs, ['先把核心流程走通，再补齐异常分支。']);
      expect(bubbles.single.firstTurnIndex, 0);
    });

    test('同一说话人停顿 >= 30 秒时在同一气泡内另起一段', () {
      final bubbles = mergedDlgParagraphs(const [
        CleanDialogueLine(
          speakerKey: '说话人 1',
          text: '今晚先把方案写完。',
          startSec: 100,
          endSec: 110,
          turnIndex: 0,
        ),
        CleanDialogueLine(
          speakerKey: '说话人 1',
          text: '明日早间再同步给团队。',
          startSec: 150,
          endSec: 165,
          turnIndex: 1,
        ),
      ]);
      expect(bubbles, hasLength(1));
      expect(bubbles.single.paragraphs, [
        '今晚先把方案写完。',
        '明日早间再同步给团队。',
      ]);
    });

    test('换人则另起一个气泡', () {
      final bubbles = mergedDlgParagraphs(const [
        CleanDialogueLine(
          speakerKey: '说话人 1（推测）',
          text: '测试环境今晚能用吗？',
          startSec: 10,
          endSec: 20,
          turnIndex: 0,
        ),
        CleanDialogueLine(
          speakerKey: '说话人 2（推测）',
          text: '应该可以。',
          startSec: 21,
          endSec: 28,
          turnIndex: 1,
        ),
      ]);
      expect(bubbles, hasLength(2));
      expect(bubbles.first.speakerKey, '说话人 1');
      expect(bubbles.last.speakerKey, '说话人 2');
      expect(bubbles.first.paragraphs, ['测试环境今晚能用吗？']);
      expect(bubbles.last.paragraphs, ['应该可以。']);
    });

    test('相邻重叠分片不因切片边界拆段', () {
      final bubbles = mergedDlgParagraphs(const [
        CleanDialogueLine(
          speakerKey: '说话人 1',
          text: '前半句还没说完',
          startSec: 10,
          endSec: 20,
          turnIndex: 0,
        ),
        CleanDialogueLine(
          speakerKey: '说话人 1',
          text: '后半句接上了。',
          startSec: 19,
          endSec: 30,
          turnIndex: 1,
        ),
      ]);
      expect(bubbles, hasLength(1));
      expect(bubbles.single.paragraphs, hasLength(1));
    });

    test('中间插了照片才拆成新气泡', () {
      final bubbles = mergedDlgParagraphs(
        const [
          CleanDialogueLine(
            speakerKey: '说话人 1',
            text: '先看这张图。',
            startSec: 10,
            endSec: 20,
            turnIndex: 0,
          ),
          CleanDialogueLine(
            speakerKey: '说话人 1',
            text: '然后继续说方案。',
            startSec: 30,
            endSec: 40,
            turnIndex: 1,
          ),
        ],
        photoSecs: const [25],
      );
      expect(bubbles, hasLength(2));
    });

    test('用户可见说话人标签去掉推测和声纹标记', () {
      expect(lifeSpeakerLabel('说话人 1（推测）'), '说话人 1');
      expect(lifeSpeakerLabel('说话人 2（声纹）'), '说话人 2');
    });
  });

  group('SectionCopy', () {
    test('只返回 summary 时回填 brief 与 overview', () {
      final copy = SectionCopy.fromModel({
        'title': '下班前同步测试环境',
        'summary': '和同事确认测试环境今晚可用。',
      });
      expect(copy.brief, '和同事确认测试环境今晚可用。');
      expect(copy.overview, '和同事确认测试环境今晚可用。');
      expect(copy.summary, '和同事确认测试环境今晚可用。');
      expect(copy.cardSummary, '和同事确认测试环境今晚可用。');
    });

    test('同时返回 brief / overview / summary 时各用各的，卡片优先 summary', () {
      final copy = SectionCopy.fromModel({
        'title': '联调排期',
        'brief': '一句话摘要',
        'overview': '更完整的概述。',
        'summary': '卡片上的生活摘要。',
      });
      expect(copy.brief, '一句话摘要');
      expect(copy.overview, '更完整的概述。');
      expect(copy.summary, '卡片上的生活摘要。');
      expect(copy.cardSummary, '卡片上的生活摘要。');
    });
  });

  group('模型字段落盘', () {
    test('OrganizedSection 只回 summary 时映射 brief/overview，并保留证据切片', () {
      final section = OrganizedSection.fromJson({
        'anchorId': 'a1',
        'title': '下班前同步',
        'summary': '和同事确认测试环境今晚可用。',
        'startAtMs': 1,
        'endAtMs': 2,
        'evidenceSliceIds': ['s1', 's2'],
        'paragraphs': [
          {
            'speaker': '说话人 1',
            'text': '今晚测试环境能不能用。',
            'startAtMs': 1,
            'endAtMs': 2,
          },
        ],
      });
      expect(section.brief, '和同事确认测试环境今晚可用。');
      expect(section.overview, '和同事确认测试环境今晚可用。');
      expect(section.summary, '和同事确认测试环境今晚可用。');
      expect(section.evidenceSliceIds, ['s1', 's2']);
      final topic = section.toTopicSection();
      expect(topic.summary, section.summary);
      expect(topic.evidenceSliceIds, ['s1', 's2']);
      expect(topic.brief, section.brief);
    });

    test('TopicSectionOverride 可序列化 summary 与 evidenceSliceIds', () {
      const section = TopicSectionOverride(
        title: '联调排期',
        brief: '周三前完成联调。',
        summary: '卡片摘要',
        startTurnIndex: 0,
        endTurnIndex: 1,
        evidenceSliceIds: ['s1'],
      );
      final again = TopicSectionOverride.fromJson(section.toJson());
      expect(again.summary, '卡片摘要');
      expect(again.evidenceSliceIds, ['s1']);
      expect(again.brief, '周三前完成联调。');
    });
  });
}
