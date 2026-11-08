// SettingsStore 契约 —— 默认值 / 落盘 / load 幂等。
//
// 这一层是设置页唯一的真相源：值走 KeyValueStore（生产 shared_preferences，
// 测试 InMemoryStore），页面重建后 load() 从盘里读回，状态不再丢。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:recording_card/core/storage/storage.dart';
import 'package:recording_card/core/store/settings_store.dart';

void main() {
  test('6 个开关：分组顺序与默认值对齐设计稿', () {
    final items = SettingsStore.items;
    expect(items.length, 6);
    expect(
      items.map((i) => i.label).toList(),
      ['持续录音', '标记重要对话', '自动转录', '自动清洗口语', '说话人推测归类', '仅使用 Wi-Fi 同步'],
    );
    expect(SettingsStore.groups.map((g) => g.title).toList(), [
      '录音',
      '转录与清洗',
      '同步',
    ]);
    // 前 5 个默认开，仅 Wi-Fi 同步默认关
    expect(items.take(5).every((i) => i.defaultValue), isTrue);
    expect(items.last.defaultValue, isFalse);
  });

  test('未 load 时 value() 直接回落到默认值（首帧就渲染正确状态）', () {
    final store = SettingsStore(store: InMemoryStore());
    addTearDown(store.dispose);
    expect(store.loaded, isFalse);
    expect(store.value('rc.set.record.continuous'), isTrue);
    expect(store.value('rc.set.sync.wifiOnly'), isFalse);
  });

  test('load() 从空盘读回默认值，并标记已加载 + 通知一次', () async {
    final store = SettingsStore(store: InMemoryStore());
    addTearDown(store.dispose);
    var notified = 0;
    store.addListener(() => notified++);

    await store.load();

    expect(store.loaded, isTrue);
    expect(notified, 1);
    for (final item in SettingsStore.items) {
      expect(store.value(item.key), item.defaultValue, reason: item.key);
    }
  });

  test('setValue 真的落盘（键名带 rc.set. 前缀），并通知 UI', () async {
    final backing = InMemoryStore();
    final store = SettingsStore(store: backing);
    addTearDown(store.dispose);
    await store.load();
    var notified = 0;
    store.addListener(() => notified++);

    await store.setValue('rc.set.sync.wifiOnly', true);

    expect(store.value('rc.set.sync.wifiOnly'), isTrue);
    expect(notified, 1);
    expect(await backing.getBool('rc.set.sync.wifiOnly'), isTrue);
    expect(store.touchedKeys, {'rc.set.sync.wifiOnly'});
  });

  test('toggle 往返：点两次回到原值', () async {
    final backing = InMemoryStore();
    final store = SettingsStore(store: backing);
    addTearDown(store.dispose);
    await store.load();

    await store.toggle('rc.set.record.continuous');
    expect(store.value('rc.set.record.continuous'), isFalse);
    expect(await backing.getBool('rc.set.record.continuous'), isFalse);

    await store.toggle('rc.set.record.continuous');
    expect(store.value('rc.set.record.continuous'), isTrue);
  });

  test('load 幂等：重复调用结果一致；本次运行改过的值不被盘里的旧值盖掉', () async {
    final backing = InMemoryStore();
    await backing.setBool('rc.set.trans.auto', false);

    final store = SettingsStore(store: backing);
    addTearDown(store.dispose);

    await store.load();
    expect(store.value('rc.set.trans.auto'), isFalse, reason: '读盘优先于默认值');

    await store.setValue('rc.set.trans.auto', true);
    await store.load(); // 再读一次：磁盘里还是 false
    expect(
      store.value('rc.set.trans.auto'),
      isTrue,
      reason: '用户刚点的开关不能被异步 load 弹回去',
    );

    // 换个新实例（模拟冷启动）：这时读到的是用户改过的盘值
    final reopened = SettingsStore(store: backing);
    addTearDown(reopened.dispose);
    await reopened.load();
    expect(reopened.value('rc.set.trans.auto'), isTrue);
  });

  test('存储读取失败不抛（设置页不因存储不可用白屏）', () async {
    final store = SettingsStore(store: _BrokenStore());
    addTearDown(store.dispose);
    await store.load();
    expect(store.loaded, isTrue);
    expect(store.value('rc.set.record.mark'), isTrue);

    // 写入失败也只记日志，内存态仍然生效
    await store.setValue('rc.set.record.mark', false);
    expect(store.value('rc.set.record.mark'), isFalse);
  });

  test('未知键：defaultValueOf 回退 false，setValue 写不存在的键不会崩', () async {
    expect(SettingsStore.defaultValueOf('rc.set.not.exist'), isFalse);
    final store = SettingsStore(store: InMemoryStore());
    addTearDown(store.dispose);
    await store.load();
    await store.setValue('rc.set.not.exist', true);
    expect(store.value('rc.set.not.exist'), isTrue);
  });
}

/// 所有读写都失败的存储（模拟平台通道不可用）。
class _BrokenStore implements KeyValueStore {
  @override
  Future<bool?> getBool(String key) async => throw StateError('no channel');

  @override
  Future<String?> getString(String key) async => throw StateError('no channel');

  @override
  Future<void> setBool(String key, bool value) async =>
      throw StateError('no channel');

  @override
  Future<void> setString(String key, String value) async =>
      throw StateError('no channel');

  @override
  Future<void> remove(String key) async => throw StateError('no channel');

  @override
  Future<bool> containsKey(String key) async => throw StateError('no channel');
}
