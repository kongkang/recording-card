// 微信登录服务单测：fluwx 适配层全部用替身顶掉，验证协议与边界。
//
// 断言点（对齐 reai_mobile_app 的服务语义 + 本仓新增约束）：
// - AppID 校验：空串 / xcconfig 占位串（rc-wechat-disabled）/ 非 wx 前缀均视为未配置；
// - authorize 的 state 严格匹配（迟到旧回调不消费）、-2/-4/其他错误码映射、超时；
// - 单飞（在途期间第二发直接拒绝）、注册失败可重试；
// - 三态安装缓存：未探测 null / 明确未装 false / 已装 true；
// - FluwxWechatSdkAdapter 懒创建——纯 Dart 环境构造不触发平台通道。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:recording_card/services/wechat_login/wechat_login_service.dart';

class _FakeWechatSdk implements WechatSdkAdapter {
  _FakeWechatSdk({
    this.registerOk = true,
    this.installed = true,
    this.launchOk = true,
  });

  bool registerOk;
  bool installed;
  bool launchOk;

  String? lastAppId;
  String? lastUniversalLink;
  String? lastScope;
  String? lastState;
  final List<void Function(WechatSdkAuthResponse)> listeners = [];

  /// 手动注入一次回调（模拟微信回跳）。
  void emit(WechatSdkAuthResponse response) {
    for (final listener in listeners.toList()) {
      listener(response);
    }
  }

  @override
  Future<bool> registerApi({
    required String appId,
    required String universalLink,
  }) async {
    lastAppId = appId;
    lastUniversalLink = universalLink;
    return registerOk;
  }

  @override
  Future<bool> get isInstalled async => installed;

  @override
  Future<bool> requestAuth({required String scope, required String state}) async {
    lastScope = scope;
    lastState = state;
    return launchOk;
  }

  @override
  void addResponseListener(listener) => listeners.add(listener);

  @override
  void removeResponseListener(listener) => listeners.remove(listener);
}

WechatSdkAuthResponse _okResponse(String state, {String? lang}) =>
    WechatSdkAuthResponse(errorCode: 0, code: 'wx-code-1', state: state, lang: lang);

void main() {
  group('AppID 配置校验（fail-closed）', () {
    for (final (label, appId) in [
      ('空串', ''),
      ('xcconfig 占位串', 'rc-wechat-disabled'),
      ('非 wx 前缀', 'ab1234567890'),
      ('wx 后过短', 'wx'),
    ]) {
      test('$label → isConfigured = false，initialize/authorize 均 notConfigured', () async {
        final sdk = _FakeWechatSdk();
        final service = WechatLoginService(sdk: sdk, wechatAppId: appId);
        expect(service.isConfigured, isFalse);
        await expectLater(
          service.initialize(),
          throwsA(isA<WechatLoginException>().having(
            (e) => e.kind, 'kind', WechatLoginFailureKind.notConfigured)),
        );
        await expectLater(
          service.authorize(),
          throwsA(isA<WechatLoginException>().having(
            (e) => e.kind, 'kind', WechatLoginFailureKind.notConfigured)),
        );
        expect(sdk.lastAppId, isNull, reason: '未配置时不得触达 SDK');
      });
    }

    test('合法 AppID（wx + 16 位）→ isConfigured = true', () {
      final service = WechatLoginService(
        sdk: _FakeWechatSdk(),
        wechatAppId: 'wxd9ce5b90974d7c2a',
      );
      expect(service.isConfigured, isTrue);
    });
  });

  group('authorize 全链路', () {
    test('成功：注册 AppID/UL → snsapi_userinfo → state 严格匹配 → 返回 code+lang', () async {
      final sdk = _FakeWechatSdk();
      final service = WechatLoginService(sdk: sdk, wechatAppId: 'wx1234567890abcdef');

      final future = service.authorize();
      // requestAuth 已发出（listener 已挂、state 已生成）
      await Future<void>.delayed(Duration.zero);
      expect(sdk.lastAppId, 'wx1234567890abcdef');
      expect(sdk.lastUniversalLink, 'https://app.cn.reai.com/link/');
      expect(sdk.lastScope, 'snsapi_userinfo');
      expect(sdk.lastState, hasLength(64));
      expect(sdk.lastState, matches(RegExp(r'^[0-9a-f]{64}$')));

      sdk.emit(_okResponse(sdk.lastState!, lang: 'zh_CN'));
      final code = await future;
      expect(code.code, 'wx-code-1');
      expect(code.lang, 'zh_CN');
      expect(sdk.listeners, isEmpty, reason: '结束后必须摘掉监听');
      expect(service.cachedIsInstalled, isTrue);
    });

    test('迟到旧 state 的成功回调被忽略，随后正确 state 才收尾', () async {
      final sdk = _FakeWechatSdk();
      final service = WechatLoginService(sdk: sdk, wechatAppId: 'wx1234567890abcdef');

      final future = service.authorize();
      await Future<void>.delayed(Duration.zero);
      sdk.emit(_okResponse('stale-state-from-previous-run'));
      await Future<void>.delayed(Duration.zero);
      expect(sdk.listeners, isNotEmpty, reason: '旧 state 不应消费授权');

      sdk.emit(_okResponse(sdk.lastState!));
      final code = await future;
      expect(code.code, 'wx-code-1');
    });

    test('用户取消（-2）→ cancelled', () async {
      final sdk = _FakeWechatSdk();
      final service = WechatLoginService(sdk: sdk, wechatAppId: 'wx1234567890abcdef');
      final future = service.authorize();
      await Future<void>.delayed(Duration.zero);
      sdk.emit(const WechatSdkAuthResponse(errorCode: -2));
      await expectLater(
        future,
        throwsA(isA<WechatLoginException>().having(
          (e) => e.kind, 'kind', WechatLoginFailureKind.cancelled)),
      );
    });

    test('拒绝（-4）→ denied；其他错误码 → invalidResponse', () async {
      final sdk = _FakeWechatSdk();
      final service = WechatLoginService(sdk: sdk, wechatAppId: 'wx1234567890abcdef');
      final future = service.authorize();
      await Future<void>.delayed(Duration.zero);
      sdk.emit(const WechatSdkAuthResponse(errorCode: -4));
      await expectLater(
        future,
        throwsA(isA<WechatLoginException>().having(
          (e) => e.kind, 'kind', WechatLoginFailureKind.denied)),
      );

      final future2 = service.authorize();
      await Future<void>.delayed(Duration.zero);
      sdk.emit(const WechatSdkAuthResponse(errorCode: -99, errorMessage: 'boom'));
      await expectLater(
        future2,
        throwsA(isA<WechatLoginException>()
            .having((e) => e.kind, 'kind', WechatLoginFailureKind.invalidResponse)
            .having((e) => e.details, 'details', 'boom')),
      );
    });

    test('微信侧无回调 → 超时（timedOut）', () async {
      final sdk = _FakeWechatSdk();
      final service = WechatLoginService(
        sdk: sdk,
        wechatAppId: 'wx1234567890abcdef',
        timeout: const Duration(milliseconds: 30),
      );
      await expectLater(
        service.authorize(),
        throwsA(isA<WechatLoginException>().having(
          (e) => e.kind, 'kind', WechatLoginFailureKind.timedOut)),
      );
    });

    test('拉起失败（launchOk=false）→ launchFailed', () async {
      final sdk = _FakeWechatSdk(launchOk: false);
      final service = WechatLoginService(sdk: sdk, wechatAppId: 'wx1234567890abcdef');
      await expectLater(
        service.authorize(),
        throwsA(isA<WechatLoginException>().having(
          (e) => e.kind, 'kind', WechatLoginFailureKind.launchFailed)),
      );
    });

    test('在途期间第二发 authorize → 直接拒绝（单飞）', () async {
      final sdk = _FakeWechatSdk();
      final service = WechatLoginService(
        sdk: sdk,
        wechatAppId: 'wx1234567890abcdef',
        timeout: const Duration(seconds: 5),
      );
      final first = service.authorize();
      await Future<void>.delayed(Duration.zero);
      await expectLater(
        service.authorize(),
        throwsA(isA<WechatLoginException>().having(
          (e) => e.kind, 'kind', WechatLoginFailureKind.launchFailed)),
      );
      sdk.emit(_okResponse(sdk.lastState!));
      expect((await first).code, 'wx-code-1');
    });

    test('cancelPendingAuthorization 中止挂起授权、摘除监听并立即释放单飞锁供下次重试', () async {
      final sdk = _FakeWechatSdk();
      final service = WechatLoginService(
        sdk: sdk,
        wechatAppId: 'wx1234567890abcdef',
        timeout: const Duration(minutes: 2),
      );

      final first = service.authorize();
      await Future<void>.delayed(Duration.zero);
      expect(sdk.listeners, hasLength(1));

      service.cancelPendingAuthorization();
      await expectLater(
        first,
        throwsA(isA<WechatLoginException>().having(
          (e) => e.kind, 'kind', WechatLoginFailureKind.cancelled)),
      );
      expect(sdk.listeners, isEmpty, reason: '中止后必须立即摘掉响应监听');

      // 单飞锁必须已释放，无需等 2 分钟超时即可发起新一轮授权
      final second = service.authorize();
      await Future<void>.delayed(Duration.zero);
      expect(sdk.listeners, hasLength(1));
      sdk.emit(_okResponse(sdk.lastState!));
      expect((await second).code, 'wx-code-1');
    });
  });

  group('安装探测与注册', () {
    test('未安装微信 → notInstalled，且缓存为 false（登录页据此隐藏按钮）', () async {
      final sdk = _FakeWechatSdk(installed: false);
      final service = WechatLoginService(sdk: sdk, wechatAppId: 'wx1234567890abcdef');
      expect(service.cachedIsInstalled, isNull, reason: '未探测前是三态 null');
      await expectLater(
        service.authorize(),
        throwsA(isA<WechatLoginException>().having(
          (e) => e.kind, 'kind', WechatLoginFailureKind.notInstalled)),
      );
      expect(service.cachedIsInstalled, isFalse);
    });

    test('initialize 单独调用也会刷新安装缓存（供 prewarm 使用）', () async {
      final sdk = _FakeWechatSdk(installed: true);
      final service = WechatLoginService(sdk: sdk, wechatAppId: 'wx1234567890abcdef');
      await service.initialize();
      expect(service.cachedIsInstalled, isTrue);
      // 幂等：第二次不再注册
      await service.initialize();
      expect(sdk.lastAppId, 'wx1234567890abcdef');
    });

    test('注册失败 → registrationFailed，且 memo 复位可重试', () async {
      final sdk = _FakeWechatSdk(registerOk: false);
      final service = WechatLoginService(sdk: sdk, wechatAppId: 'wx1234567890abcdef');
      await expectLater(
        service.initialize(),
        throwsA(isA<WechatLoginException>().having(
          (e) => e.kind, 'kind', WechatLoginFailureKind.registrationFailed)),
      );
      sdk.registerOk = true;
      await service.initialize();
      expect(sdk.lastAppId, 'wx1234567890abcdef');
    });
  });

  group('平台守卫与懒创建', () {
    test('FluwxWechatSdkAdapter 懒创建：纯 Dart 构造不触发平台通道', () {
      // Fluwx() 构造即订阅平台事件流；若适配器急切创建，这里会因无 Binding 抛错。
      final adapter = FluwxWechatSdkAdapter();
      expect(adapter, isNotNull);
    });

    test('WechatLoginService 默认适配器同样懒创建（构造无 Binding 不炸）', () {
      final service = WechatLoginService(wechatAppId: 'wx1234567890abcdef');
      expect(service.isConfigured, isTrue);
    });
  });
}
