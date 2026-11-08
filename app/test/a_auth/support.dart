import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:recording_card/core/config/remote/client_config.dart';
import 'package:recording_card/services/auth/oauth_client.dart';
import 'package:recording_card/services/auth/oauth_config.dart';
import 'package:recording_card/services/auth/oauth_token_store.dart';
import 'package:recording_card/services/auth/web_auth_launcher.dart';

const testConfig = ClientConfig(
  oauthClientId: 'test-public-client',
  oauthBaseUrl: 'https://approved.test',
  trustedHosts: ['approved.test'],
);
final testTime = DateTime.utc(2026, 11, 8, 12);

class MemoryTokenStorage implements TokenStorage {
  final Map<String, String> values = {};
  final List<String> writes = [];
  final List<String> deletes = [];
  Future<void> Function(String key, String value)? beforeWrite;
  bool failWrites = false;
  @override
  Future<String?> read(String key) async => values[key];
  @override
  Future<void> write(String key, String value) async {
    if (failWrites) throw StateError('test storage write failure');
    await beforeWrite?.call(key, value);
    writes.add(key);
    values[key] = value;
  }

  @override
  Future<void> delete(String key) async {
    deletes.add(key);
    values.remove(key);
  }
}

class CallbackLauncher implements WebAuthLauncher {
  CallbackLauncher({this.callback});
  FutureOr<Uri> Function(Uri url)? callback;
  Uri? lastUrl;
  String? lastScheme;
  int calls = 0;
  @override
  Future<Uri> launch({
    required Uri authorizeUrl,
    required String callbackScheme,
  }) async {
    lastUrl = authorizeUrl;
    lastScheme = callbackScheme;
    calls++;
    return callback == null
        ? successfulCallback(authorizeUrl)
        : await callback!(authorizeUrl);
  }
}

Uri successfulCallback(Uri authorizeUrl) =>
    Uri.parse(authorizeUrl.queryParameters['redirect_uri']!).replace(
      queryParameters: {
        'code': 'synthetic-code',
        'state': authorizeUrl.queryParameters['state']!,
      },
    );

Map<String, Object?> tokenJson({
  String access = 'synthetic-access-1',
  String? refresh = 'synthetic-refresh-1',
  int expires = 3600,
}) => {
  'access_token': access,
  'refresh_token': ?refresh,
  'token_type': 'Bearer',
  'expires_in': expires,
  if (refresh != null) 'refresh_expires_in': 86400,
  'scope': 'mobile:full profile:read',
};
http.Response jsonResponse(Object? body, {int status = 200}) =>
    http.Response.bytes(
      utf8.encode(jsonEncode(body)),
      status,
      headers: {'content-type': 'application/json'},
    );
http.Response profileResponse({String id = 'test-user-1'}) => jsonResponse({
  'data': {
    'user_id': id,
    'email': '$id@example.test',
    'display_name': 'Test User',
  },
});
OAuthClient testOAuth(
  http.Client httpClient, {
  ClientConfig config = testConfig,
}) => OAuthClient(
  config: OAuthConfig(clientConfig: config),
  httpClient: httpClient,
);
Future<void> seedTokens(
  OAuthTokenStore store, {
  String access = 'synthetic-access-1',
  String? refresh = 'synthetic-refresh-1',
  int expires = 3600,
}) => store.saveTokens(
  OAuthTokenResponse.fromJson(
    tokenJson(access: access, refresh: refresh, expires: expires),
  ),
);
