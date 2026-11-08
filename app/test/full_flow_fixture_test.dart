import 'package:flutter_test/flutter_test.dart';
import 'package:recording_card/core/models/summary.dart';

import 'fixtures/full_flow_fixture.dart';

void main() {
  test(
    'qa fixture is explicit, fresh, and unrelated to production seed ids',
    () {
      final first = fullFlowFixtureEvents();
      final second = fullFlowFixtureEvents();
      expect(first.map((event) => event.id), ['qa-orchid', 'qa-lantern']);
      first.clear();
      expect(second, hasLength(2));
    },
  );

  test(
    'qa fixture preserves original disfluency separately from cleaned text',
    () {
      final event = fullFlowFixtureEvents().first;
      expect(event.raw.first.text, contains('啊'));
      expect(event.dialog.first.text, isNot(contains('啊')));
      expect(event.raw.first.src, event.dialog.first.src);
      expect(event.speakers, contains('推测'));
    },
  );

  test('qa result contains only selected source with legal clock range', () {
    expect(
      auditFixtureSources(
        fullFlowFixtureSummary(),
        fullFlowFixtureEvents(),
        selectedIds: {'qa-orchid'},
      ),
      isEmpty,
    );
  });

  test('qa result round-trip keeps source mapping and raw markdown', () {
    final result = fullFlowFixtureSummary();
    final restored = SummaryCard.fromJson(result.toJson());
    expect(restored.toJson(), result.toJson());
    expect(restored.points.single.sources.single.eventId, 'qa-orchid');
    expect(restored.srcIds, isNot(contains('qa-lantern')));
  });

  test('qa source oracle rejects unselected source', () {
    final result = fullFlowFixtureSummary()..srcIds = ['qa-lantern'];
    expect(
      auditFixtureSources(
        result,
        fullFlowFixtureEvents(),
        selectedIds: {'qa-orchid'},
      ),
      contains('illegal summary source: qa-lantern'),
    );
  });

  test('qa source oracle rejects fabricated id and duplicate source', () {
    final result = fullFlowFixtureSummary()..srcIds = ['missing', 'missing'];
    final errors = auditFixtureSources(
      result,
      fullFlowFixtureEvents(),
      selectedIds: {'qa-orchid'},
    );
    expect(errors, contains('duplicate summary source'));
    expect(errors, contains('illegal summary source: missing'));
  });

  test('qa source oracle rejects range outside selected recording', () {
    final result = fullFlowFixtureSummary()
      ..points = [
        const InfoPoint('bad', 'bad', [
          SourceRef('qa-orchid', '兰花实验记录', '09:10—09:13'),
        ]),
      ];
    expect(
      auditFixtureSources(
        result,
        fullFlowFixtureEvents(),
        selectedIds: {'qa-orchid'},
      ),
      contains('out-of-range source: qa-orchid 09:10—09:13'),
    );
  });

  test('qa source oracle rejects completed empty-source summary', () {
    final result = fullFlowFixtureSummary()..srcIds = [];
    expect(
      auditFixtureSources(result, [], selectedIds: {}),
      contains('completed summary without sources'),
    );
  });
}
