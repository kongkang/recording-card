import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../../core/config/remote/client_config.dart';
import '../../core/config/remote/endpoint_resolver.dart';
import 'auth_exception.dart';

class OAuthConfig {
  OAuthConfig({ClientConfig? clientConfig})
    : clientConfig = clientConfig ?? ClientConfig.instance;
  final ClientConfig clientConfig;

  Uri get baseUri {
    final value = sanitizeTrustedEndpoint(
      clientConfig.effectiveOAuthBaseUrl,
      trustedHosts: clientConfig.trustedHosts,
    );
    if (value == null) {
      throw const AuthException('invalid_config', 'OAuth服务端未配置或不在可信主机列表');
    }
    return Uri.parse(value);
  }

  String get clientId => clientConfig.oauthClientId.trim();
  String get scope => clientConfig.oauthScope.trim();
  Uri get redirectUri => Uri.parse(clientConfig.oauthRedirectUri);
  String get callbackScheme => redirectUri.scheme;
  static const pendingTtl = Duration(minutes: 10);

  void validate() {
    baseUri;
    final redirect = Uri.tryParse(clientConfig.oauthRedirectUri);
    if (clientId.isEmpty ||
        scope.isEmpty ||
        redirect == null ||
        !RegExp(r'^[a-z][a-z0-9+.-]*$').hasMatch(redirect.scheme) ||
        ['http', 'https', 'reai-mobile'].contains(redirect.scheme) ||
        redirect.host != 'callback' ||
        redirect.path.isNotEmpty ||
        redirect.userInfo.isNotEmpty ||
        redirect.hasPort ||
        redirect.hasQuery ||
        redirect.hasFragment) {
      throw const AuthException(
        'invalid_config',
        'OAuth客户端、scope或独立callback配置无效',
      );
    }
  }

  Uri endpoint(String path) => Uri.parse('${baseUri.toString()}$path');

  /// Changing issuer/client/redirect/scope cannot accidentally reuse old tokens.
  String get storageNamespace {
    final identity = [
      clientConfig.effectiveOAuthBaseUrl,
      clientId,
      clientConfig.oauthRedirectUri,
      scope,
    ].join('\n');
    final fingerprint = sha256.convert(utf8.encode(identity)).toString();
    return 'recording_card.oauth.v1.$fingerprint';
  }
}
