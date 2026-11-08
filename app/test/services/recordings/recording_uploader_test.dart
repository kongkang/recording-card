import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:recording_card/services/recordings/recording_models.dart';
import 'package:recording_card/services/recordings/recording_uploader.dart';

class TestHeaders implements HttpHeaders {
  final values = <String, Object>{};
  @override
  ContentType? contentType;
  @override
  void set(String name, Object value, {bool preserveHeaderCase = false}) {
    values[name.toLowerCase()] = value;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class TestResponse extends Stream<List<int>> implements HttpClientResponse {
  @override
  final int statusCode;
  final String body;
  TestResponse(this.statusCode, this.body);
  @override
  StreamSubscription<List<int>> listen(
    void Function(List<int>)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) => Stream<List<int>>.value(utf8.encode(body)).listen(
    onData,
    onError: onError,
    onDone: onDone,
    cancelOnError: cancelOnError,
  );
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class TestRequest implements HttpClientRequest {
  @override
  final TestHeaders headers = TestHeaders();
  @override
  bool followRedirects = true;
  @override
  int contentLength = -1;
  final List<int> sent = [];
  final TestResponse response;
  TestRequest(this.response);
  @override
  Future<void> addStream(Stream<List<int>> stream) async {
    await for (final bytes in stream) {
      sent.addAll(bytes);
    }
  }

  @override
  Future<HttpClientResponse> close() async => response;
  @override
  void abort([Object? exception, StackTrace? stackTrace]) {}
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class TestHttpClient implements HttpClient {
  final TestRequest request;
  int opens = 0;
  TestHttpClient(this.request);
  @override
  Future<HttpClientRequest> openUrl(String method, Uri url) async {
    opens++;
    return request;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  late Directory temp;
  late File audio;
  late RecordingUploadRequest job;
  setUp(() async {
    temp = await Directory.systemTemp.createTemp('http-upload-test-');
    audio = await File('${temp.path}/test.apm')
        .writeAsBytes(List.generate(128, (i) => i));
    job = RecordingUploadRequest(
      entry: RecordingIndexEntry(
        key: 'stable-source',
        eventId: 'e',
        deviceId: 'card',
        fileId: 'session:seq',
        audioPath: audio.path,
        sizeBytes: await audio.length(),
        contentHash: (await sha256.bind(audio.openRead()).first).toString(),
        importedAt: DateTime.now(),
      ),
    );
  });
  tearDown(() async {
    await temp.delete(recursive: true);
  });

  HttpRecordingUploader adapter(
    TestHttpClient client, {
    Uri? url,
    Set<String> hosts = const {'upload.example.org'},
    Future<Map<String, String>> Function()? headers,
  }) => HttpRecordingUploader(
    endpoint: url ?? Uri.parse('https://upload.example.org/api/recordings'),
    allowedHosts: hosts,
    authorizationHeaders:
        headers ?? () async => {'Authorization': 'Bearer test-only'},
    client: client,
  );

  test('missing endpoint/auth or malformed/unapproved endpoint fails before sending bytes', () async {
    final request = TestRequest(TestResponse(200, '{}'));
    final client = TestHttpClient(request);
    final missing = HttpRecordingUploader(client: client);
    expect(
      missing.validateConfiguration,
      throwsA(isA<RecordingUploadConfigurationException>()),
    );
    for (final url in [
      'http://upload.example.org/api',
      'file:///tmp/audio',
      'https://evil.example.org/api',
      'https://user:password@upload.example.org/api',
      'https://upload.example.org/api#fragment',
    ]) {
      await expectLater(
        adapter(client, url: Uri.parse(url)).upload(job),
        throwsA(isA<RecordingUploadConfigurationException>()),
      );
    }
    await expectLater(
      adapter(client, hosts: {}).upload(job),
      throwsA(isA<RecordingUploadConfigurationException>()),
    );
    final noAuth = HttpRecordingUploader(
      endpoint: Uri.parse('https://upload.example.org/api'),
      allowedHosts: {'upload.example.org'},
      client: client,
    );
    await expectLater(
      noAuth.upload(job),
      throwsA(isA<RecordingUploadConfigurationException>()),
    );
    expect(client.opens, 0);
  });

  test('streams exact bytes, prevents redirects, sets stable idempotency and accepts explicit receipt', () async {
    final request = TestRequest(
      TestResponse(201, '{"accepted":true,"fileId":"server-file-id"}'),
    );
    final client = TestHttpClient(request);
    var checks = 0;
    final withPolicy = RecordingUploadRequest(
      entry: job.entry,
      requireNetwork: () async {
        checks++;
      },
    );
    final receipt = await adapter(client).upload(withPolicy);
    expect(receipt.cloudFileId, 'server-file-id');
    expect(request.sent, await audio.readAsBytes());
    expect(request.followRedirects, false);
    expect(request.contentLength, job.entry.sizeBytes);
    expect(request.headers.values['idempotency-key'], job.idempotencyKey);
    expect(request.headers.values['x-content-sha256'], job.entry.contentHash);
    expect(checks, greaterThanOrEqualTo(2));
  });

  test(
    'HTTP 2xx alone, redirects and invalid JSON never imply successful upload',
    () async {
      for (final response in [
        TestResponse(204, ''),
        TestResponse(302, ''),
        TestResponse(500, ''),
        TestResponse(200, '{}'),
        TestResponse(200, '{"accepted":false,"fileId":"x"}'),
        TestResponse(200, '{"accepted":true,"fileId":""}'),
        TestResponse(200, 'not-json'),
      ]) {
        await expectLater(
          adapter(TestHttpClient(TestRequest(response))).upload(job),
          throwsA(isA<RecordingUploadException>()),
        );
      }
    },
  );

  test(
    'changed same-length source fails hash validation before network',
    () async {
      final client = TestHttpClient(TestRequest(TestResponse(200, '{}')));
      await audio.writeAsBytes(List.filled(job.entry.sizeBytes, 42));
      await expectLater(
        adapter(client).upload(job),
        throwsA(isA<RecordingUploadException>()),
      );
      expect(client.opens, 0);
    },
  );

  test(
    'authorization callback cannot override endpoint transport headers',
    () async {
      final client = TestHttpClient(TestRequest(TestResponse(200, '{}')));
      await expectLater(
        adapter(
          client,
          headers: () async => {'Host': 'evil.example.org'},
        ).upload(job),
        throwsA(isA<RecordingUploadConfigurationException>()),
      );
      expect(client.request.sent, isEmpty);
    },
  );
}
