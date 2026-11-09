import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:recording_card/core/device/card_gateway.dart';
import 'package:recording_card/services/recordings/recording_download_gateway.dart';
import 'package:recording_card/services/runtime/accessory_hotspot_session.dart';

import 'ios_hotspot_session_test.dart' show HotspotCard, cardId;

class NoDefaultHttp extends HttpOverrides {
  @override
  HttpClient createHttpClient(SecurityContext? context) => throw StateError(
    'must use the SDK accessory route, not Dart default HTTP',
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  AccessoryHotspotSession session(
    HotspotCard card,
    Future<bool> Function(String) probe,
  ) => AccessoryHotspotSession(
    card,
    isIos: () => true,
    join: () async {},
    closePhoneConfiguration: () async {},
    sdkFileProbe: probe,
    readyTimeout: const Duration(milliseconds: 10),
    probeInterval: const Duration(milliseconds: 1),
  );

  test(
    'SDK verified page uses the same target UID and never Dart default HTTP',
    () async {
      final card = HotspotCard();
      var calls = 0;
      final lane = session(card, (id) async {
        expect(id, cardId);
        calls++;
        return true;
      });
      await HttpOverrides.runWithHttpOverrides(
        () => lane.prepare(cardId),
        NoDefaultHttp(),
      );
      expect(calls, 1);
      expect(lane.ready, isTrue);
      await lane.close();
      expect(card.wifiOpen, isFalse);
    },
  );

  test(
    'SDK error is visible and never downgraded to default HTTP or ready',
    () async {
      final card = HotspotCard();
      final lane = session(
        card,
        (_) async => throw const CardGatewayException('http', 'SDK 本地HTTP响应超时'),
      );
      await HttpOverrides.runWithHttpOverrides(() async {
        await expectLater(
          lane.prepare(cardId),
          throwsA(
            isA<StateError>().having(
              (e) => e.message.toString(),
              'actual SDK error',
              contains('SDK 本地HTTP响应超时'),
            ),
          ),
        );
      }, NoDefaultHttp());
      expect(lane.ready, isFalse);
      expect(lane.active, isFalse);
    },
  );

  test(
    'cancelled SDK probe keeps the AP lane until the original final',
    () async {
      final card = HotspotCard();
      final entered = Completer<void>();
      final finalResult = Completer<bool>();
      final lane = session(card, (_) {
        entered.complete();
        return finalResult.future;
      });
      final prepare = lane.prepare(cardId);
      final expected = expectLater(
        prepare,
        throwsA(isA<RecordingSyncCancelled>()),
      );
      await entered.future;
      var closed = false;
      final close = lane.close().then((_) => closed = true);
      await Future<void>.delayed(Duration.zero);
      expect(closed, isFalse);
      expect(lane.active, isTrue);
      finalResult.complete(true);
      await expected;
      await close;
      expect(lane.ready, isFalse);
      expect(lane.active, isFalse);
      expect(card.wifiOpen, isFalse);
    },
  );
}
