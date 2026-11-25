import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:recording_card/core/device/card_gateway.dart';
import 'package:recording_card/core/models/recording.dart';
import 'package:recording_card/core/storage/storage.dart';
import 'package:recording_card/core/store/agent_config_store.dart';
import 'package:recording_card/core/store/app_store.dart';
import 'package:recording_card/core/store/device_store.dart';
import 'package:recording_card/core/store/membership_store.dart';
import 'package:recording_card/core/theme/tokens.dart';
import 'package:recording_card/data/seed.dart';
import 'package:recording_card/pages/app_shell.dart';
import 'package:recording_card/pages/privacy_page.dart';
import 'package:recording_card/pages/settings/setting_sub_page.dart';
import 'package:recording_card/pages/timeline_page.dart';
import 'package:recording_card/services/audio/live_audio_recorder.dart';
import 'package:recording_card/services/audio/recording_status.dart';
import 'package:recording_card/services/billing/storekit_service.dart';
import 'package:recording_card/services/recordings/recording_pipeline.dart';
import 'package:recording_card/services/recordings/recording_store.dart';
import 'package:recording_card/services/transcribe/local_asr_service.dart';
import 'package:recording_card/services/transcribe/slice_planner.dart';
import 'package:recording_card/services/transcribe/speech_engine.dart';
import 'package:recording_card/services/transcribe/speech_models.dart';
import 'package:recording_card/services/transcribe/wav_io.dart';
import 'package:recording_card/widgets/store_scope.dart';

import 'support/fake_gateway.dart';
import 'support/fake_recordings.dart';
import 'support/model_stub.dart';
import 'support/test_transitions.dart';

class _FakeStoreKitGateway implements StoreKitGateway {
  final StreamController<void> _updates = StreamController<void>.broadcast();

  @override
  bool lastEntitlementCheckAuthoritative = true;

  StoreCatalogResult catalogResult = const StoreCatalogResult(
    products: <StoreProductInfo>[
      StoreProductInfo(
        id: MembershipStore.localProMonthly,
        displayName: 'Local Pro 月付',
        description: '无限本地离线转写',
        displayPrice: '¥6.00',
        price: 6.0,
        currencyCode: 'CNY',
        type: 'autoRenewable',
      ),
      StoreProductInfo(
        id: MembershipStore.cloudProYearly,
        displayName: 'Cloud Pro 年付',
        description: '旗舰云端深度总结',
        displayPrice: '¥848.00',
        price: 848.0,
        currencyCode: 'CNY',
        type: 'autoRenewable',
      ),
    ],
  );

  List<StoreEntitlement> entitlements = <StoreEntitlement>[];
  StorePurchaseStatus nextPurchaseStatus = StorePurchaseStatus.purchased;
  String? nextMessage;
  String? lastPurchasedProductId;
  int purchaseCalls = 0;
  int restoreCalls = 0;
  bool manageSubsResult = true;
  int manageSubsCalls = 0;

  @override
  Stream<void> get entitlementUpdates => _updates.stream;

  @override
  Future<StoreCatalogResult> loadProducts(List<String> productIds) async =>
      catalogResult;

  @override
  Future<List<StoreEntitlement>> currentEntitlements() async => entitlements;

  @override
  Future<StorePurchaseResult> purchase(String productId) async {
    purchaseCalls++;
    lastPurchasedProductId = productId;
    if (nextPurchaseStatus != StorePurchaseStatus.purchased) {
      return StorePurchaseResult(
        status: nextPurchaseStatus,
        message: nextMessage,
      );
    }
    if (productId != MembershipStore.creditsPack500 &&
        productId != MembershipStore.creditsPack1200) {
      entitlements = <StoreEntitlement>[
        StoreEntitlement(
          productId: productId,
          transactionId: 'tx-$purchaseCalls',
          originalTransactionId: 'orig-1',
          expirationDateMs: DateTime(2027, 1, 1).millisecondsSinceEpoch,
        ),
      ];
    }
    return StorePurchaseResult(
      status: StorePurchaseStatus.purchased,
      productId: productId,
      transactionId: 'tx-$purchaseCalls',
      originalTransactionId: 'orig-1',
      expirationDateMs: DateTime(2027, 1, 1).millisecondsSinceEpoch,
    );
  }

  @override
  Future<StoreRestoreResult> restorePurchases() async {
    restoreCalls++;
    return StoreRestoreResult(status: 'restored', entitlements: entitlements);
  }

  @override
  Future<bool> manageSubscriptions() async {
    manageSubsCalls++;
    return manageSubsResult;
  }

  @override
  void dispose() {
    unawaited(_updates.close());
  }
}

class _QuotaSpeechEngine implements SpeechEngine {
  int transcribeCalls = 0;

  @override
  Future<void> load({
    required String modelPath,
    required String tokensPath,
    String language = 'auto',
    int numThreads = 2,
  }) async {}

  @override
  Future<AsrResult> transcribe(
    Float32List samples, {
    int sampleRate = 16000,
  }) async {
    transcribeCalls++;
    return AsrResult(
      text: '今天对齐一下正式版会员与额度方案。',
      tokens: const [],
      timestampsMs: const [],
      audioMs: samples.length * 1000 ~/ sampleRate,
    );
  }

  @override
  Future<void> loadVad(String vadPath) async {}

  @override
  Future<List<SpeechSpan>> detectSpeech(
    Float32List samples, {
    int sampleRate = 16000,
  }) async => <SpeechSpan>[SpeechSpan(0, samples.length)];

  @override
  Future<void> loadSpeakerEmbedding(String modelPath) async {}

  @override
  Future<List<double>> embedSpeaker(
    Float32List samples, {
    int sampleRate = 16000,
  }) async => const [1.0, 0.0, 0.0];

  @override
  Future<void> dispose() async {}
}

class _FixedModels implements SpeechModelProvider {
  const _FixedModels(this.paths);
  final SpeechModelPaths paths;

  @override
  Future<SpeechModelPaths?> resolve() async => paths;
}

class _WavFakeGateway extends FakeCardGateway {
  _WavFakeGateway(this.samples);
  final Float32List samples;

  @override
  Future<CardAudio> transcode(String apmPath, String wavPath) async {
    await Directory(File(wavPath).parent.path).create(recursive: true);
    await File(wavPath).writeAsBytes(encodeWav(samples), flush: true);
    return CardAudio(
      path: wavPath,
      samples: samples.length,
      durationSecs: samples.length / 16000.0,
    );
  }
}

Float32List _toneSamples(int durationMs) {
  final n = durationMs * 16;
  final out = Float32List(n);
  for (var i = 0; i < n; i++) {
    out[i] = 0.2 * math.sin(2 * math.pi * 220 * i / 16000);
  }
  return out;
}

void main() {
  group('MembershipStore 额度与 StoreKit 2 状态机', () {
    test('每月 3,600 分钟总池：预警、满额阻断及跨月 1 日自动清零重置', () async {
      var now = DateTime(2026, 11, 24, 10, 0);
      final kv = InMemoryStore();
      final mem = MembershipStore(store: kv, now: () => now);
      addTearDown(mem.dispose);
      await mem.load();

      expect(mem.tier, MembershipTier.free);
      expect(mem.canTranscribeLocally, isTrue);
      expect(mem.isLocalQuotaWarning, isFalse);
      expect(mem.remainingFreeMinutes, 3600);

      // 短时录音（5 秒）立即计为 1 分钟反馈
      await mem.recordLocalTranscriptionMs(5000);
      expect(mem.effectiveUsedMinutes, 1);
      expect(mem.isLocalQuotaWarning, isFalse);

      // 累加到 3,240 分钟（90%）触发预警但不断流
      await mem.recordLocalTranscriptionMs((3240 * 60000) - 5000);
      expect(mem.effectiveUsedMinutes, 3240);
      expect(mem.isLocalQuotaWarning, isTrue);
      expect(mem.isLocalQuotaExhausted, isFalse);
      expect(mem.canTranscribeLocally, isTrue);

      // 达到 3,600 分钟进入柔和排队态
      await mem.recordLocalTranscriptionMs(360 * 60000);
      expect(mem.effectiveUsedMinutes, 3600);
      expect(mem.isLocalQuotaExhausted, isTrue);
      expect(mem.canTranscribeLocally, isFalse);
      expect(mem.settingRowSummary(), '免费版 · 本月已满');

      // 持久化重开保留状态
      final reloaded = MembershipStore(store: kv, now: () => now);
      addTearDown(reloaded.dispose);
      await reloaded.load();
      expect(reloaded.isLocalQuotaExhausted, isTrue);
      expect(reloaded.effectiveUsedMinutes, 3600);

      // 进入下个月 1 日：自动清零并恢复转写
      now = DateTime(2026, 12, 1, 0, 5);
      expect(reloaded.effectiveUsedMinutes, 0);
      expect(reloaded.canTranscribeLocally, isTrue);
      await reloaded.load();
      expect(reloaded.quotaMonthKey, '2026-12');
      expect(reloaded.remainingFreeMinutes, 3600);
    });

    test('历史录音仅回填当月本机已就绪非外部导入记录', () async {
      final now = DateTime(2026, 11, 24, 12, 0);
      final mem = MembershipStore(store: InMemoryStore(), now: () => now);
      addTearDown(mem.dispose);
      await mem.load();

      final thisMonthStart = DateTime(2026, 11, 20, 9, 0).millisecondsSinceEpoch;
      final lastMonthStart = DateTime(2026, 10, 20, 9, 0).millisecondsSinceEpoch;

      await mem.backfillCurrentMonthUsage([
        RecordingFile(
          deviceName: 'REC1.APM',
          session: 'S1',
          seq: 1,
          startAtMs: thisMonthStart,
          apmPath: '/tmp/1.apm',
          createdAtMs: thisMonthStart,
          durationMs: 45 * 60000,
          stage: RecordingStage.ready,
          utterances: const [
            RawUtterance(
              id: 'u1',
              sliceId: 's1',
              startMs: 0,
              endMs: 1000,
              text: '你好',
            ),
          ],
        ),
        // 上个月不计入
        RecordingFile(
          deviceName: 'REC2.APM',
          session: 'S2',
          seq: 1,
          startAtMs: lastMonthStart,
          apmPath: '/tmp/2.apm',
          createdAtMs: lastMonthStart,
          durationMs: 120 * 60000,
          stage: RecordingStage.ready,
          utterances: const [
            RawUtterance(
              id: 'u2',
              sliceId: 's1',
              startMs: 0,
              endMs: 1000,
              text: '上月',
            ),
          ],
        ),
        // 外部第三方导入不计入本地录音转写分钟
        RecordingFile(
          deviceName: 'EXT_GETNOTE_1',
          session: 'EXT',
          seq: 1,
          startAtMs: thisMonthStart,
          apmPath: '',
          createdAtMs: thisMonthStart,
          durationMs: 200 * 60000,
          stage: RecordingStage.ready,
          utterances: const [
            RawUtterance(
              id: 'u3',
              sliceId: 's1',
              startMs: 0,
              endMs: 1000,
              text: '笔记',
            ),
          ],
        ),
      ]);

      expect(mem.effectiveUsedMinutes, 45);
    });

    test('StoreKit 2 购买、加量包 90 天过期与失败绝不伪造权益', () async {
      var now = DateTime(2026, 11, 24, 15, 0);
      final gw = _FakeStoreKitGateway();
      final mem = MembershipStore(
        store: InMemoryStore(),
        gateway: gw,
        now: () => now,
      );
      addTearDown(gw.dispose);
      addTearDown(mem.dispose);
      await mem.load();

      var unlockedCalls = 0;
      mem.onLocalQuotaUnlocked = () => unlockedCalls++;

      await mem.recordLocalTranscriptionMs(3600 * 60000);
      expect(mem.isLocalQuotaExhausted, isTrue);

      // 1) 失败/取消不授予权益
      gw.nextPurchaseStatus = StorePurchaseStatus.cancelled;
      await mem.purchase(MembershipStore.localProMonthly);
      expect(mem.tier, MembershipTier.free);
      expect(mem.lastNotice, contains('已取消'));
      expect(unlockedCalls, 0);

      gw.nextPurchaseStatus = StorePurchaseStatus.unavailable;
      gw.nextMessage = 'App Store 暂未返回该商品';
      await mem.purchase(MembershipStore.localProMonthly);
      expect(mem.tier, MembershipTier.free);
      expect(mem.lastError, contains('暂未返回该商品'));

      // 2) 购买 Local Pro 成功 -> 立即解锁本机转写并唤醒排队回调
      gw.nextPurchaseStatus = StorePurchaseStatus.purchased;
      await mem.purchase(MembershipStore.localProMonthly);
      expect(mem.tier, MembershipTier.localPro);
      expect(mem.isUnlimitedLocal, isTrue);
      expect(mem.canTranscribeLocally, isTrue);
      expect(unlockedCalls, 1);

      // 3) 购买 Cloud Basic + 积分加量包
      await mem.purchase(MembershipStore.cloudBasicMonthly);
      expect(mem.tier, MembershipTier.cloudBasic);
      expect(mem.cloudCreditsRemaining, 500);

      await mem.purchase(MembershipStore.creditsPack500);
      expect(mem.bonusCredits, 500);
      expect(mem.cloudCreditsRemaining, 1000);

      // 超过 90 天后加量包自动过期
      now = now.add(const Duration(days: 91));
      expect(mem.bonusCredits, 0);

      // 4) 购买 Cloud Pro 年付
      await mem.purchase(MembershipStore.cloudProYearly);
      expect(mem.tier, MembershipTier.cloudPro);
      expect(mem.cloudProSummariesRemaining, 50);
      expect(mem.cloudProQaRemaining, 50);

      // 5) 恢复购买同步权威权益
      gw.entitlements = <StoreEntitlement>[
        const StoreEntitlement(
          productId: MembershipStore.localProLifetime,
          transactionId: 'tx-restore',
          originalTransactionId: 'orig-restore',
        ),
      ];
      await mem.restorePurchases();
      expect(gw.restoreCalls, 1);
      expect(mem.tier, MembershipTier.localPro);
      expect(mem.lifetimeLocalPro, isTrue);
      expect(mem.settingRowSummary(), 'Local Pro · 永久版');
    });
  });

  group('RecordingPipeline 月度 3,600 分钟柔和队列保护', () {
    test('超额时不丢弃录音也不报错，安全滞留本机队列，解锁后立即完成转写并计费', () async {
      final tmp = await Directory.systemTemp.createTemp('rc-mem-quota-');
      addTearDown(() => tmp.delete(recursive: true));

      final samples = _toneSamples(4000);
      final liveWav = '${tmp.path}/live_slice_0.wav';
      await File(liveWav).writeAsBytes(encodeWav(samples), flush: true);

      final gw = _WavFakeGateway(samples)
        ..writeDownload = true
        ..deviceFiles = const [
          CardFile(
            name: 'BLE001.APM',
            size: 32000,
            startAtSec: 1795400000,
            session: 'SES_BLE',
            seq: 1,
            synced: true,
          ),
        ];
      final store = RecordingStore(
        root: Directory('${tmp.path}/store'),
        jsonStore: JsonStore(store: InMemoryStore()),
      );
      final engine = _QuotaSpeechEngine();
      var allowTranscribe = false;
      var recordedMs = 0;

      final pipeline = RecordingPipeline(
        gateway: gw,
        store: store,
        engine: engine,
        models: const _FixedModels(
          SpeechModelPaths(
            asrModelPath: '/m/model.int8.onnx',
            tokensPath: '/m/tokens.txt',
            vadPath: '/m/vad.onnx',
          ),
        ),
        localQuotaAllowTranscribe: () => allowTranscribe,
        onLocalTranscribed: (ms) => recordedMs += ms,
      );

      // 1) 实时流切片在额度耗尽时仅落盘切片，不调 ASR
      final savedLive = await pipeline.ingestLiveSlice(
        LiveAudioSlice(
          sessionId: 'SES_LIVE',
          deviceSessionId: 'SES_LIVE',
          sliceIndex: 0,
          startAtMs: 1795400000000,
          durationMs: 4000,
          wavPath: liveWav,
          sliceKeyOverride: 'LIVE_CARD_0',
        ),
      );
      expect(savedLive.stage, RecordingStage.transcribing);
      expect(savedLive.error, RecordingPipeline.quotaExhaustedMessage);
      expect(File(liveWav).existsSync(), isTrue);
      expect(engine.transcribeCalls, 0);

      // 2) 硬件文件同步也在转码/切片后安全入队等待
      final syncRes = await pipeline.sync();
      expect(syncRes.downloaded, 1);
      expect(syncRes.ready, 0);
      final queuedBle = (await store.load('BLE001.APM'))!;
      expect(queuedBle.stage, RecordingStage.transcribing);
      expect(queuedBle.error, RecordingPipeline.quotaExhaustedMessage);
      expect(queuedBle.slices, isNotEmpty);
      expect(engine.transcribeCalls, 0);

      // 3) 购买 Local Pro 或到次月 1 日恢复额度后，pending 自动补转写并记录用量
      allowTranscribe = true;
      final resumeRes = await pipeline.transcribeLocalPendingOnly();
      expect(resumeRes.ready, 2);
      expect(resumeRes.failed, 0);
      expect(engine.transcribeCalls, 2);
      expect(recordedMs, greaterThanOrEqualTo(8000));

      final doneLive = (await store.load('LIVE_CARD_0'))!;
      final doneBle = (await store.load('BLE001.APM'))!;
      expect(doneLive.stage, RecordingStage.ready);
      expect(doneBle.stage, RecordingStage.ready);
    });
  });

  group('会员界面与 Timeline 柔和提醒条 Widget 测试', () {
    testWidgets('Setting 入口、会员子页完整交互、深色模式及合规链接可用', (tester) async {
      final gw = _FakeStoreKitGateway();
      final mem = MembershipStore(store: InMemoryStore(), gateway: gw);
      addTearDown(gw.dispose);
      addTearDown(mem.dispose);
      await mem.load();
      await mem.recordLocalTranscriptionMs(420 * 60000);

      final appStore = AppStore(events: seedEvents, loadPersistedState: false);
      final dev = DeviceStore(gateway: FakeCardGateway());
      final gen = await SummaryModel().generator();
      appStore.attachServices(
        recordings: await FakeRecordingSync.create(),
        generator: gen,
      );
      addTearDown(appStore.dispose);
      addTearDown(dev.dispose);

      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
        MembershipScope(
          store: mem,
          child: StoreScope(
            store: appStore,
            child: MaterialApp(
              theme: testTheme(),
              darkTheme: buildRCDarkTheme(),
              themeMode: ThemeMode.dark,
              scrollBehavior: const RCScrollBehavior(),
              home: AppShell(store: appStore, device: dev, membership: mem),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('nav-setting')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('set-membership')), findsOneWidget);
      expect(
        tester.widget<Text>(find.byKey(const Key('sv-membership'))).data,
        '免费版 · 已用 420/3600 分',
      );

      await tester.tap(find.byKey(const Key('set-membership')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('membership-quota-card')), findsOneWidget);
      expect(find.byKey(const Key('plan-card-local')), findsOneWidget);
      expect(find.byKey(const Key('plan-card-basic')), findsOneWidget);
      expect(find.byKey(const Key('plan-card-pro')), findsOneWidget);
      expect(find.byKey(const Key('credits-pack-section')), findsOneWidget);

      // 切换按年 / 永久买断 / 按月
      await tester.tap(find.byKey(const Key('cycle-seg-yearly')));
      await tester.pumpAndSettle();
      expect(find.text('¥68'), findsOneWidget);
      expect(find.text('¥848.00'), findsOneWidget);

      await tester.tap(find.byKey(const Key('cycle-seg-lifetime')));
      await tester.pumpAndSettle();
      expect(find.text('¥198'), findsOneWidget);

      await tester.tap(find.byKey(const Key('cycle-seg-monthly')));
      await tester.pumpAndSettle();
      expect(find.text('¥6.00'), findsOneWidget);

      // 点击购买 Local Pro：先出现确认支付弹窗，再点确认发起购买
      final buyLocal = find.byKey(const Key('plan-buy-local'));
      await tester.ensureVisible(buyLocal);
      await tester.tap(buyLocal);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('paywall-purchase-sheet')), findsOneWidget);
      await tester.tap(find.byKey(const Key('paywall-sheet-confirm')));
      await tester.pumpAndSettle();
      expect(mem.tier, MembershipTier.localPro);
      expect(find.text('当前方案'), findsOneWidget);

      // 滚到底部检查恢复购买、管理订阅、隐私政策与使用条款
      final memScroll = find
          .descendant(
            of: find.byKey(const Key('setsub-scroll-membership')),
            matching: find.byType(Scrollable),
          )
          .first;
      final restoreBtn = find.byKey(const Key('paywall-restore-btn'));
      await tester.scrollUntilVisible(restoreBtn, 200, scrollable: memScroll);
      await tester.ensureVisible(restoreBtn);
      await tester.pumpAndSettle();
      await tester.tap(restoreBtn);
      await tester.pumpAndSettle();
      expect(gw.restoreCalls, 1);

      final manageBtn = find.byKey(const Key('paywall-manage-btn'));
      await tester.ensureVisible(manageBtn);
      await tester.tap(manageBtn);
      await tester.pumpAndSettle();
      expect(gw.manageSubsCalls, 1);

      final termsBtn = find.byKey(const Key('paywall-terms-btn'));
      await tester.ensureVisible(termsBtn);
      await tester.tap(termsBtn);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('paywall-terms-dialog')), findsOneWidget);
      await tester.tap(find.text('关闭'));
      await tester.pumpAndSettle();

      final privacyBtn = find.byKey(const Key('paywall-privacy-btn'));
      await tester.ensureVisible(privacyBtn);
      await tester.tap(privacyBtn);
      await tester.pumpAndSettle();
      expect(find.byType(PrivacyPage), findsOneWidget);
    });

    testWidgets('Timeline 90% 预警条 / 100% 满额柔和提示条与开发者调试覆盖联动', (
      tester,
    ) async {
      final mem = MembershipStore(store: InMemoryStore());
      addTearDown(mem.dispose);
      await mem.load();

      final cfg = AgentConfigStore(store: InMemoryStore());
      await cfg.load();
      addTearDown(cfg.dispose);

      final appStore = AppStore(events: seedEvents, loadPersistedState: false);
      addTearDown(appStore.dispose);
      final recStatus = RecordingStatusController();
      addTearDown(recStatus.dispose);

      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
        MembershipScope(
          store: mem,
          child: StoreScope(
            store: appStore,
            child: MaterialApp(
              theme: testTheme(),
              home: Scaffold(body: TimelinePage(recordingStatus: recStatus)),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // 正常用量隐藏条幅
      await mem.setDevQuotaOverrideMinutes(420);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('quota-soft-banner')), findsNothing);

      // 90%+ 出现预警提示
      await mem.setDevQuotaOverrideMinutes(3360);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('quota-soft-banner')), findsOneWidget);
      expect(find.textContaining('3360'), findsOneWidget);
      expect(find.text('查看会员'), findsOneWidget);

      // 100% 满额出现队列保护提醒，点按钮跳会员页
      await mem.setDevQuotaOverrideMinutes(3600);
      await tester.pumpAndSettle();
      expect(find.textContaining('新录音仍继续保存至本机队列'), findsOneWidget);
      await tester.tap(find.byKey(const Key('quota-banner-upgrade')));
      await tester.pumpAndSettle();
      expect(appStore.stackTop?.type, 'setsub');
      expect(appStore.stackTop?.id, 'membership');

      // 开发者设置：仅在 developerMode=true 时显示额度调试芯片
      await tester.pumpWidget(
        MembershipScope(
          store: mem,
          child: MaterialApp(
            theme: testTheme(),
            home: SettingSubPage(
              subId: 'dev',
              agentConfig: cfg,
              membership: mem,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('dev-membership-quota-debug')), findsNothing);

      await cfg.setDeveloperMode(true);
      await tester.pumpAndSettle();
      final devScroll = find
          .descendant(
            of: find.byKey(const Key('setsub-scroll-dev')),
            matching: find.byType(Scrollable),
          )
          .first;
      final realChip = find.byKey(const Key('dev-quota-real'));
      await tester.scrollUntilVisible(realChip, 200, scrollable: devScroll);
      await tester.ensureVisible(realChip);
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('dev-membership-quota-debug')),
        findsOneWidget,
      );
      await tester.tap(realChip);
      await tester.pumpAndSettle();
      expect(mem.devQuotaOverrideMinutes, isNull);
    });

    testWidgets('点击套餐先弹确认支付弹窗：取消不触发扣款，StoreKit 不可用时弹真实结果提示且不伪造权益', (
      tester,
    ) async {
      final gw = _FakeStoreKitGateway();
      final mem = MembershipStore(store: InMemoryStore(), gateway: gw);
      addTearDown(gw.dispose);
      addTearDown(mem.dispose);
      await mem.load();

      final appStore = AppStore(events: seedEvents, loadPersistedState: false);
      final dev = DeviceStore(gateway: FakeCardGateway());
      final gen = await SummaryModel().generator();
      appStore.attachServices(
        recordings: await FakeRecordingSync.create(),
        generator: gen,
      );
      addTearDown(appStore.dispose);
      addTearDown(dev.dispose);

      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
        MembershipScope(
          store: mem,
          child: StoreScope(
            store: appStore,
            child: MaterialApp(
              theme: testTheme(),
              scrollBehavior: const RCScrollBehavior(),
              home: AppShell(store: appStore, device: dev, membership: mem),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('nav-setting')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('set-membership')));
      await tester.pumpAndSettle();

      final memScroll = find
          .descendant(
            of: find.byKey(const Key('setsub-scroll-membership')),
            matching: find.byType(Scrollable),
          )
          .first;
      final buyBasic = find.byKey(const Key('plan-buy-basic'));
      await tester.scrollUntilVisible(buyBasic, 200, scrollable: memScroll);
      await tester.ensureVisible(buyBasic);
      await tester.pumpAndSettle();
      await tester.tap(buyBasic);
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('paywall-purchase-sheet')), findsOneWidget);
      expect(find.text('确认订阅'), findsOneWidget);
      expect(find.text('Apple App Store（StoreKit 2）'), findsOneWidget);

      await tester.tap(find.byKey(const Key('paywall-sheet-cancel')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('paywall-purchase-sheet')), findsNothing);
      expect(gw.purchaseCalls, 0);
      expect(mem.tier, MembershipTier.free);

      gw.nextPurchaseStatus = StorePurchaseStatus.unavailable;
      gw.nextMessage = 'App Store 暂未返回该商品';

      await tester.scrollUntilVisible(buyBasic, 200, scrollable: memScroll);
      await tester.ensureVisible(buyBasic);
      await tester.pumpAndSettle();
      await tester.tap(buyBasic);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('paywall-sheet-confirm')));
      await tester.pumpAndSettle();

      expect(gw.purchaseCalls, 1);
      final resultDialog = find.byKey(const Key('paywall-result-dialog'));
      expect(resultDialog, findsOneWidget);
      expect(
        find.descendant(
          of: resultDialog,
          matching: find.textContaining('未发起真实扣款'),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: resultDialog,
          matching: find.textContaining('App Store 暂未返回该商品'),
        ),
        findsOneWidget,
      );
      expect(mem.tier, MembershipTier.free);

      await tester.tap(find.byKey(const Key('paywall-result-ok')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('paywall-result-dialog')), findsNothing);
    });
  });
}
