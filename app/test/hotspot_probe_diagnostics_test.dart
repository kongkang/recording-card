import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:recording_card/services/runtime/accessory_hotspot_session.dart';

class LocalProbeOverrides extends HttpOverrides {}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'AP probe reports bounded HTTP/JSON diagnostics, never response contents',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final subscription = server.listen((request) async {
        if (request.uri.path == '/http') {
          request.response.statusCode = 503;
          request.response.write('private-do-not-display');
        } else if (request.uri.path == '/html') {
          request.response.write('<html>private-do-not-display</html>');
        } else if (request.uri.path == '/shape') {
          request.response.write('{"private-do-not-display":[]}');
        } else {
          request.response.write('{"files":[]}');
        }
        await request.response.close();
      });
      addTearDown(() async {
        await subscription.cancel();
        await server.close(force: true);
      });
      for (final entry in {
        '/http': 'HTTP 503',
        '/html': '不是有效 JSON',
        '/shape': '不是 SDK 文件列表',
        '/ok': null,
      }.entries) {
        final failures = <String>[];
        final ok = await HttpOverrides.runWithHttpOverrides(
          () => AccessoryHotspotSession.probeFileService(
            Uri.parse('http://127.0.0.1:${server.port}${entry.key}'),
            const Duration(seconds: 1),
            onFailure: failures.add,
          ),
          LocalProbeOverrides(),
        );
        expect(ok, entry.value == null);
        if (entry.value != null) expect(failures.single, contains(entry.value));
        expect(failures.join(), isNot(contains('private-do-not-display')));
      }
    },
  );

  test(
    'unreachable AP probe exposes socket category without claiming readiness',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final port = server.port;
      await server.close(force: true);
      final failures = <String>[];
      final ok = await HttpOverrides.runWithHttpOverrides(
        () => AccessoryHotspotSession.probeFileService(
          Uri.parse('http://127.0.0.1:$port/api/files'),
          const Duration(seconds: 1),
          onFailure: failures.add,
        ),
        LocalProbeOverrides(),
      );
      expect(ok, isFalse);
      expect(failures.single, startsWith('局域网连接失败'));
    },
  );
}
