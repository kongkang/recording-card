import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:recording_card/core/device/card_gateway.dart';
import 'package:recording_card/core/store/device_store.dart';
import 'package:recording_card/core/store/service_backends.dart';
import 'package:recording_card/core/store/store_persistence.dart';
import 'package:recording_card/services/settings/settings_repository.dart';

import 'ios_hotspot_session_test.dart' as hotspot;

class PollingCard extends hotspot.HotspotCard {
  Completer<void>? nextStatusFinal;
  @override
  Future<CardSnapshot> status() async {
    final finalEvent = nextStatusFinal;
    nextStatusFinal = null;
    await finalEvent?.future;
    return super.status();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late PollingCard card;
  late hotspot.HotspotOps ops;
  late DeviceStore store;
  late Directory root;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('ap-poll-priority-');
    card = PollingCard();
    ops = hotspot.HotspotOps();
    final session = ops.session(card);
    store = DeviceStore(
      backend: ServiceDeviceBackend(
        gateway: card,
        settingsRepository: SettingsRepository(directory: root),
        hotspotSession: session,
      ),
      persistence: MemoryStorePersistence(),
      fastTransferActive: () => session.active,
    );
    await store.connectDevice('transport');
  });
  tearDown(() async {
    store.dispose();
    await card.stream.close();
    await root.delete(recursive: true);
  });

  test('foreground fast transfer waits current status final instead of rejecting ordinary polling', () async {
    final statusFinal = Completer<void>();
    card.nextStatusFinal = statusFinal;
    final refresh = store.refreshFromDevice();
    await hotspot.nextTurn();
    expect(store.deviceBusy, isTrue);
    final preparing = store.prepareFastTransfer();
    await hotspot.nextTurn();
    expect(store.fastTransferPreparing, isTrue);
    expect(card.log, isEmpty);
    expect(ops.log, isEmpty);
    await store.refreshFromDevice(); // A new poll cannot overtake foreground.
    statusFinal.complete();
    await refresh;
    expect(await preparing, isTrue);
    expect(ops.log, ['join', 'probe']);
    expect(store.fastTransferPrepared, isTrue);
    await store.cancelFastTransfer();
    expect(store.deviceBusy, isFalse);
  });

  test('cancel while waiting status final invalidates foreground ticket, never starts late WIFI_OPEN/join', () async {
    final statusFinal = Completer<void>();
    card.nextStatusFinal = statusFinal;
    final refresh = store.refreshFromDevice();
    await hotspot.nextTurn();
    final preparing = store.prepareFastTransfer();
    await hotspot.nextTurn();
    await store.cancelFastTransfer();
    expect(
      store.deviceBusy,
      isTrue,
    ); // Original preparation/status still finalizing.
    statusFinal.complete();
    await refresh;
    expect(await preparing, isFalse);
    expect(card.log, isEmpty);
    expect(ops.log, isEmpty);
    expect(store.deviceBusy, isFalse);
  });

  test(
    'polling plus a real firmware operation still rejects fast transfer',
    () async {
      final statusFinal = Completer<void>();
      card.nextStatusFinal = statusFinal;
      final refresh = store.refreshFromDevice();
      await hotspot.nextTurn();
      store.fwUpdating = true;
      expect(await store.prepareFastTransfer(), isFalse);
      expect(store.fastTransferPreparing, isFalse);
      expect(card.log, isEmpty);
      expect(ops.log, isEmpty);
      store.fwUpdating = false;
      statusFinal.complete();
      await refresh;
    },
  );
}
