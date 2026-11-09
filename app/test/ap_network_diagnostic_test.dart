import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:recording_card/services/recordings/recording_download_gateway.dart';
import 'package:recording_card/services/runtime/accessory_hotspot_session.dart';

import 'ios_hotspot_session_test.dart' show HotspotCard, cardId;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  AccessoryHotspotSession fixture(
    HotspotCard card, {
    required Future<Map<String, dynamic>> Function() network,
    required Future<bool> Function() http,
  }) => AccessoryHotspotSession(
    card,
    isIos: () => true,
    join: () async {},
    closePhoneConfiguration: () async {},
    networkProbe: network,
    probe: (_, _) => http(),
    readyTimeout: const Duration(milliseconds: 5),
    probeTimeout: const Duration(milliseconds: 1),
    probeInterval: const Duration(milliseconds: 1),
  );

  test(
    'native Wi-Fi TCP ready never replaces the valid HTTP files response',
    () async {
      final card = HotspotCard();
      var probes = 0;
      final session = fixture(
        card,
        network: () async {
          probes++;
          return {
            'tcpReady': true,
            'hasAccessoryWifiIPv4': true,
            'localNetworkDenied': true,
          };
        },
        http: () async => false,
      );
      await expectLater(
        session.prepare(cardId),
        throwsA(
          isA<StateError>().having(
            (e) => e.message.toString(),
            'diagnosis',
            contains('TCP已通'),
          ),
        ),
      );
      expect(probes, 2);
      expect(session.ready, isFalse);
      expect(session.active, isFalse);
      expect(card.wifiOpen, isFalse);
    },
  );

  test(
    'schema-checked HTTP readiness may succeed after initial DHCP diagnostic',
    () async {
      final card = HotspotCard();
      final session = fixture(
        card,
        network: () async => {'tcpReady': false, 'hasAccessoryWifiIPv4': false},
        http: () async => true,
      );
      await session.prepare(cardId);
      expect(session.ready, isTrue);
      await session.close();
      expect(card.wifiOpen, isFalse);
    },
  );

  test(
    'missing native network fields remain unknown rather than acquired IP',
    () async {
      final card = HotspotCard();
      final session = fixture(
        card,
        network: () async => {},
        http: () async => false,
      );
      await expectLater(
        session.prepare(cardId),
        throwsA(
          isA<StateError>().having(
            (e) => e.message.toString(),
            'unknown diagnostic',
            contains('未返回可验证的网络路径'),
          ),
        ),
      );
      expect(session.ready, isFalse);
      expect(card.wifiOpen, isFalse);
    },
  );

  test(
    'cancel during native network probe awaits its final and skips HTTP',
    () async {
      final card = HotspotCard();
      final entered = Completer<void>();
      final finalResult = Completer<Map<String, dynamic>>();
      var httpCalls = 0;
      final session = fixture(
        card,
        network: () {
          entered.complete();
          return finalResult.future;
        },
        http: () async {
          httpCalls++;
          return true;
        },
      );
      final prepare = session.prepare(cardId);
      final expected = expectLater(
        prepare,
        throwsA(isA<RecordingSyncCancelled>()),
      );
      await entered.future;
      var closed = false;
      final close = session.close().then((_) => closed = true);
      await Future<void>.delayed(Duration.zero);
      expect(closed, isFalse);
      expect(session.active, isTrue);
      finalResult.complete({'tcpReady': true, 'hasAccessoryWifiIPv4': true});
      await expected;
      await close;
      expect(closed, isTrue);
      expect(httpCalls, 0);
      expect(session.ready, isFalse);
      expect(card.wifiOpen, isFalse);
    },
  );
}
