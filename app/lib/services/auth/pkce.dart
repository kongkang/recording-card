/// PKCE（RFC 7636）参数生成。
///
/// 默认 **S256**（OAuth 2.1 草案强制，也是绝大多数服务端唯一接受的方式）：
/// `code_challenge = BASE64URL(SHA256(verifier))`，摘要用 `package:crypto`，
/// 不手写密码学原语。`plain` 仅作服务端不支持 S256 时的降级手段。
library;

import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';

/// PKCE 挑战方式。
enum PkceMethod {
  /// `plain`：`code_challenge == code_verifier`（RFC 7636 §4.2，仅防授权码截获重放）。
  plain('plain'),

  /// `S256`：`code_challenge = BASE64URL(SHA256(verifier))`。
  ///
  /// 默认方式；需要 `package:crypto`（已在 pubspec 声明）。
  s256('S256');

  const PkceMethod(this.wireName);

  /// 出现在 `code_challenge_method` 参数里的字面值。
  final String wireName;
}

/// 一次 PKCE 的 verifier / challenge 组合。
class PkcePair {
  const PkcePair({
    required this.codeVerifier,
    required this.codeChallenge,
    required this.method,
  });

  /// 一次性随机串（43–128 字符，unreserved 字符集），换 token 时回传。
  final String codeVerifier;

  /// 授权请求里带的挑战值。
  final String codeChallenge;

  /// 挑战方式。
  final PkceMethod method;

  /// `code_challenge_method` 参数值。
  String get codeChallengeMethod => method.wireName;
}

/// PKCE verifier 长度（RFC 7636 允许 43–128，取 64 兼顾熵与 URL 长度）。
const int kPkceVerifierLength = 64;

/// PKCE 允许的字符集：`[A-Z] [a-z] [0-9] - . _ ~`（unreserved）。
const String _kUnreservedAlphabet =
    'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~';

/// 生成 PKCE 参数。
///
/// [random] 仅测试注入可预测随机源；生产用 [Random.secure]。
/// [verifierLength] 不在 43–128 范围内会被夹到合法区间（防御性，避免服务端拒绝）。
PkcePair generatePkcePair({
  Random? random,
  int verifierLength = kPkceVerifierLength,
  PkceMethod method = PkceMethod.s256,
}) {
  final rng = random ?? Random.secure();
  final length = verifierLength.clamp(43, 128);
  final verifier = _randomString(rng, length, _kUnreservedAlphabet);
  return PkcePair(
    codeVerifier: verifier,
    codeChallenge: codeChallengeFor(verifier, method),
    method: method,
  );
}

/// 由 verifier 计算 challenge。
String codeChallengeFor(String verifier, PkceMethod method) {
  switch (method) {
    case PkceMethod.plain:
      return verifier;
    case PkceMethod.s256:
      return _s256Challenge(verifier);
  }
}

/// `BASE64URL(SHA256(verifier))`，去掉尾部 padding（RFC 7636 §4.2）。
String _s256Challenge(String verifier) =>
    base64UrlNoPadding(sha256.convert(utf8.encode(verifier)).bytes);

String _randomString(Random rng, int length, String alphabet) {
  final buffer = StringBuffer();
  for (var i = 0; i < length; i++) {
    buffer.write(alphabet[rng.nextInt(alphabet.length)]);
  }
  return buffer.toString();
}

/// 生成 `state`（CSRF 防护）：URL-safe 随机串，默认 32 字符。
String generateState({Random? random, int length = 32}) {
  const alphabet =
      'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789';
  return _randomString(random ?? Random.secure(), length, alphabet);
}

/// 把字符串按 UTF-8 编码后 base64url（无 padding）。
///
/// 保留给 S256 升级与调试用（当前 plain 流程不调用）。
String base64UrlNoPadding(List<int> bytes) =>
    base64UrlEncode(bytes).replaceAll('=', '');
