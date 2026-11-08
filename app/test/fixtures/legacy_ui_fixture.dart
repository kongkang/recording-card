import 'dart:async';
import 'dart:io';

import 'package:recording_card/core/device/card_gateway.dart';
import 'package:recording_card/core/models/summary.dart';
import 'package:recording_card/core/models/record.dart';
import 'package:recording_card/core/store/app_backend.dart';
import 'package:recording_card/core/store/app_store.dart';
import 'package:recording_card/core/store/device_store.dart';
import 'package:recording_card/core/store/store_persistence.dart';
import 'package:recording_card/data/seed.dart' as seed;
import 'package:recording_card/services/auth_service.dart';
import 'package:http/testing.dart';

import '../a_auth/support.dart';

import 'package:recording_card/services/auth/oauth_token_store.dart';
import 'package:recording_card/services/export/export_service.dart';

/// Timed UI specimens ONLY. These callbacks cannot enter a release build.
AppStore legacyAppFixture({DateTime Function()? clock}) {
  final sourceClock = clock ?? DateTime.now;
  final epoch = sourceClock();
  return AppStore(
    clock: () => DateTime(2026, 11, 8, 15).add(sourceClock().difference(epoch)),
    events: _calendarEvents(),
    persistence: MemoryStorePersistence(),
    backend: CallbackAppBackend(
      load: () async => _calendarEvents(),
      apply: (_) async {},
      generate: (events, target, policy, progress) async {
        progress(const TaskProgress('分析测试来源…'));
        await Future<void>.delayed(const Duration(seconds: 6));
        seed.fillSummaryContent(target, events);
        target.state = SummaryState.done;
        return target;
      },
    ),
    exportService: _FixtureExport(),
  );
}

// 2026-11-08 is Sunday: Monday is 6 days ago; prior week is 7 days
// ago but still in November. Fixture dates must not depend on wall clock.
List<RecordEvent> _calendarEvents() => [
  for (final e in seed.seedEvents)
    e.copyWith(
      dayOffset: e.id == 'e5'
          ? 6
          : e.id == 'e6'
          ? 7
          : e.dayOffset,
    ),
];

class _FixtureExport extends ExportService {
  @override
  Future<ExportArtifact> export(
    SummaryCard card,
    sources,
    ExportFormat format, {
    Set<int> completedTodos = const {},
  }) async => ExportArtifact(
    files: [File('/test-only/specimen.pdf')],
    mimeType: 'application/pdf',
    title: card.title ?? 'fixture',
  );
  @override
  Future<void> share(ExportArtifact artifact, {RectOrigin? origin}) async {}
}

AuthService fixtureAuth() {
  final http = MockClient((request) async {
    if (request.url.path.endsWith('/token')) return jsonResponse(tokenJson());
    if (request.url.path.contains('profile')) return profileResponse();
    return jsonResponse({'revoked': true});
  });
  final oauth = testOAuth(http);
  return AuthService(
    config: testConfig,
    oauthClient: oauth,
    tokenStore: OAuthTokenStore(
      client: oauth,
      storage: MemoryTokenStorage(),
      clock: () => testTime,
    ),
    launcher: CallbackLauncher(),
    httpClient: http,
    clock: () => testTime,
  );
}

class _DeviceSpecimen {
  int seconds = 10800;
  bool updated = false;
  String connectedWifi = '';
  final saved = ['HomeWiFi', 'Studio-2.4G', 'Bedroom-2.4G', 'Old-2.4G'];
  CardSnapshot get snapshot => CardSnapshot(
    batteryLevel: 86,
    isCharging: false,
    wifiOpen: true,
    recording: true,
    fwVersion: updated ? '2.2.0' : '2.1.0',
    wifiVersion: updated ? '1.5.0' : '1.4.2',
    deviceId: 'fixture-card',
  );
  DeviceReading get reading => DeviceReading(
    snapshot,
    id: 'fixture-card',
    targetId: 'fixture-card',
    recordedSeconds: seconds,
    batteryEstimate: '可录至今晚',
    connectedWifi: connectedWifi.isEmpty ? null : connectedWifi,
  );
}

class _LegacyDeviceFixture extends DeviceStore {
  _LegacyDeviceFixture._(this.specimen, DeviceBackend backend)
    : super(backend: backend, persistence: MemoryStorePersistence()) {
    reading = specimen.reading;
    connected = true;
    lastDeviceId = 'fixture-card';
    lastSync = DateTime.now();
    wifiSaved = [const SavedWifi('HomeWiFi'), const SavedWifi('Studio-2.4G')];
    wifiSavedKnown = true;
  }
  final _DeviceSpecimen specimen;
  Timer? _fixtureClock;
  @override
  String get recClockText {
    final s = specimen.seconds;
    return '${s ~/ 3600}:${((s % 3600) ~/ 60).toString().padLeft(2, '0')}:${(s % 60).toString().padLeft(2, '0')}';
  }

  @override
  void openSheet() {
    super.openSheet();
    _fixtureClock?.cancel();
    _fixtureClock = Timer.periodic(const Duration(seconds: 1), (_) {
      specimen.seconds++;
      notifyListeners();
    });
  }

  @override
  void closeSheet() {
    if (fwUpdating) return;
    _fixtureClock?.cancel();
    super.closeSheet();
  }

  @override
  void dispose() {
    _fixtureClock?.cancel();
    super.dispose();
  }
}

DeviceStore legacyDeviceFixture() {
  final data = _DeviceSpecimen();
  final backend = CallbackDeviceBackend(
    isAvailable: () => true,
    scanDevices: () async => [const DeviceChoice('fixture-card', '测试卡')],
    connectDevice: (_) async => data.reading,
    readStatus: () async => data.reading,
    disconnectDevice: () async {},
    synchronize: (_, progress) async {
      await Future<void>.delayed(const Duration(milliseconds: 800));
    },
    listSavedWifi: () async => [for (final n in data.saved) SavedWifi(n)],
    scanNetworks: () async {
      await Future<void>.delayed(const Duration(milliseconds: 1100));
      return [
        const WifiNet('HomeWiFi', 3, lock: true, frequencyMhz: 2412),
        const WifiNet('Office-2.4G', 2, lock: true, frequencyMhz: 2437),
        const WifiNet('Cafe_Guest', 2, frequencyMhz: 2462),
      ];
    },
    connectSavedNetwork: (name) async {
      await Future<void>.delayed(const Duration(milliseconds: 1100));
      data.connectedWifi = name;
    },
    joinNetwork: (name, password) async {
      await Future<void>.delayed(const Duration(milliseconds: 1100));
      data.connectedWifi = name;
      if (!data.saved.contains(name)) data.saved.add(name);
    },
    checkFirmware: () async => const FirmwareOffer(
      packageId: 'fixture-two-stage',
      deviceId: 'fixture-card',
      targetMainVersion: '2.2.0',
      targetWifiVersion: '1.5.0',
      checksum:
          'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
      notes: '测试双阶段包',
    ),
    installFirmware: (_, consent, progress) async {
      progress(const TaskProgress('阶段 1/2 · 主控芯片', percent: 0));
      await Future<void>.delayed(const Duration(seconds: 3));
      progress(const TaskProgress('阶段 2/2 · Wi-Fi 芯片', percent: 50));
      await Future<void>.delayed(const Duration(seconds: 3));
      data.updated = true;
    },
  );
  return _LegacyDeviceFixture._(data, backend);
}
