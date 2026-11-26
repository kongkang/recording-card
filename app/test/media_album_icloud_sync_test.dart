import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:recording_card/core/device/card_gateway.dart';
import 'package:recording_card/core/models/record.dart';
import 'package:recording_card/core/models/recording.dart';
import 'package:recording_card/core/storage/storage.dart';
import 'package:recording_card/core/store/agent_config_store.dart';
import 'package:recording_card/core/store/app_store.dart';
import 'package:recording_card/core/store/device_store.dart';
import 'package:recording_card/core/store/settings_store.dart';
import 'package:recording_card/core/theme/tokens.dart';
import 'package:recording_card/pages/setting_page.dart';
import 'package:recording_card/pages/settings/setting_sub_page.dart';
import 'package:recording_card/services/agent/agent_chat_controller.dart';
import 'package:recording_card/services/agent/agent_speech_service.dart';
import 'package:recording_card/services/agent/hardware_agent_task_coordinator.dart';
import 'package:recording_card/services/analysis/chat_completion.dart';
import 'package:recording_card/services/audio/live_audio_recorder.dart';
import 'package:recording_card/services/media/icloud_sync_service.dart';
import 'package:recording_card/services/media/media_backup_service.dart';
import 'package:recording_card/services/photos/photo_library_service.dart';

import 'support/fake_gateway.dart';

class _SilentSpeechBackend implements AgentSpeechBackend {
  final _ctrl = StreamController<AgentSpeechEvent>.broadcast();

  @override
  Stream<AgentSpeechEvent> get events => _ctrl.stream;

  @override
  Future<bool> startListening({String locale = 'zh-CN'}) async => true;

  @override
  Future<void> stopListening() async {}

  @override
  Future<void> speak(String text, {String locale = 'zh-CN'}) async {}

  @override
  Future<void> stopSpeaking() async {}

  @override
  void dispose() {
    unawaited(_ctrl.close());
  }
}

class _StubCompletion implements ChatCompletion {
  @override
  Future<String> complete(
    List<ChatMessage> messages, {
    required String model,
    double temperature = 0.1,
    int maxTokens = 2048,
  }) async => jsonEncode({'react': '', 'reply': '画面是一张会议白板。'});
}

Widget _wrapWithTheme(Widget child) {
  return MaterialApp(
    theme: buildRCThemeForStyle(RCUIStyleId.warmPaper, brightness: Brightness.light),
    home: Scaffold(body: child),
  );
}

void main() {
  test('1. AgentConfigStore 默认相册存图开、iCloud 关、范围默认音频+文本并可持久化', () async {
    final backing = InMemoryStore();
    final cfg = AgentConfigStore(store: backing);
    await cfg.load();

    expect(cfg.saveHardwareMediaToAlbum, isTrue);
    expect(cfg.icloudSyncEnabled, isFalse);
    expect(cfg.icloudSyncScope, ICloudSyncScope.audioAndText);
    expect(cfg.icloudSyncSummary, '已关闭');

    await cfg.setSaveHardwareMediaToAlbum(false);
    await cfg.setICloudSyncEnabled(true);
    await cfg.setICloudSyncScope(ICloudSyncScope.textOnly);
    expect(cfg.icloudSyncSummary, '已开启 · 仅转录文本');

    final reloaded = AgentConfigStore(store: backing);
    await reloaded.load();
    expect(reloaded.saveHardwareMediaToAlbum, isFalse);
    expect(reloaded.icloudSyncEnabled, isTrue);
    expect(reloaded.icloudSyncScope, ICloudSyncScope.textOnly);
    cfg.dispose();
    reloaded.dispose();
  });

  test('2. 硬件照片与视频默认写入系统相册且幂等去重；关掉相册关联或无录音时仍落相册', () async {
    final root = await Directory.systemTemp.createTemp('rc_media_album_');
    addTearDown(() async {
      if (await root.exists()) await root.delete(recursive: true);
    });

    final photosDir = Directory('${root.path}/photos')..createSync(recursive: true);
    final docsDir = Directory('${root.path}/docs')..createSync(recursive: true);
    final indexDir = Directory('${root.path}/support')..createSync(recursive: true);

    final photoFile = File('${photosDir.path}/DYJ_SHOT_1.jpg')
      ..writeAsBytesSync([0xFF, 0xD8, 0xFF, 0xE0]);
    final videoFile = File('${photosDir.path}/video_20261126-100000_S1_01.mp4')
      ..writeAsBytesSync([0x00, 0x00, 0x00, 0x18, 0x66, 0x74, 0x79, 0x70]);

    final savedCalls = <({String path, String mediaType, int? capturedAtMs})>[];
    final photoLib = PhotoLibraryService(
      directoryOverride: () async => photosDir,
      saveMediaOverride: ({
        required String path,
        required String mediaType,
        int? capturedAtMs,
        bool promptIfNeeded = true,
      }) async {
        savedCalls.add((
          path: path,
          mediaType: mediaType,
          capturedAtMs: capturedAtMs,
        ));
        final id = mediaType == 'video' ? 'VID/1:A' : 'IMG/1:A';
        return MediaAlbumSaveResult(
          saved: true,
          authorized: true,
          localIdentifier: id,
        );
      },
      importOverride: (windows, {bool promptIfNeeded = false}) async =>
          const PhotoImportReport(authorized: true, photos: []),
    );

    final cfg = AgentConfigStore(store: InMemoryStore());
    await cfg.load();
    await cfg.setPhotoLinkEnabled(false); // 即使关闭「从相册读取关联照片」，硬件抓拍仍要保底存相册

    final backup = MediaBackupService(
      agentConfig: cfg,
      photoLibrary: photoLib,
      transcriptExporter: LocalTranscriptExporter(
        directoryOverride: () async => docsDir,
      ),
      indexDirOverride: () async => indexDir,
    );

    final gateway = FakeCardGateway(
      cameraPhotos: [
        CameraSyncItem(
          name: 'DYJ_SHOT_1.jpg',
          path: photoFile.path,
          bytesWritten: 4,
          capturedAtSec: 1795658400,
        ),
      ],
      cameraVideos: [
        CameraSyncItem(
          name: 'video_20261126-100000_S1_01.mp4',
          path: videoFile.path,
          bytesWritten: 8,
          capturedAtSec: 1795658410,
          mediaType: 'video',
        ),
      ],
    );

    final store = AppStore(loadPersistedState: false);
    store.photoLibrary = photoLib;
    store.mediaBackup = backup;
    store.deviceConnected = () => true;
    store.deviceHasCameraMedia = () => true;
    store.photoSyncEnabled = () => cfg.photoLinkEnabled;
    store.hardwareMediaBackupEnabled = () =>
        cfg.saveHardwareMediaToAlbum || cfg.icloudSyncEnabled;

    // 无任何录音事件 + photoLinkEnabled=false 时，syncPhotosAutomatically 依然拉取硬件媒体并写入系统相册
    await store.syncPhotosAutomatically(gatewayOverride: gateway);
    expect(savedCalls.length, 2);
    expect(savedCalls.map((c) => c.mediaType).toSet(), {'photo', 'video'});
    expect(savedCalls.first.capturedAtMs, 1795658400 * 1000);

    // 再次同步幂等去重，不再重复写入系统相册
    await store.syncPhotosAutomatically(gatewayOverride: gateway);
    expect(savedCalls.length, 2);

    // 3. 系统相册回读时，过滤自己刚刚写入相册的硬件照片，避免重复入时间线
    await cfg.setPhotoLinkEnabled(true);
    store.events = [
      const RecordEvent(
        id: 'ev-1',
        dayOffset: 0,
        title: '会议',
        brief: '讨论',
        longText: '讨论内容',
        time: '10:00',
        dur: '5 分钟',
        speakers: '说话人 1',
        mark: '',
        srcMap: '',
        dialog: [],
        raw: [],
      ),
    ];
    final dupPhotoLib = PhotoLibraryService(
      directoryOverride: () async => photosDir,
      importOverride: (windows, {bool promptIfNeeded = false}) async =>
          PhotoImportReport(
            authorized: true,
            photos: [
              ImportedAlbumPhoto(
                id: 'alb_IMG_1_A',
                eventId: 'ev-1',
                path: photoFile.path,
                capturedAtMs: 1795658400 * 1000,
              ),
              ImportedAlbumPhoto(
                id: 'alb_EXTERNAL_PHONE_PIC',
                eventId: 'ev-1',
                path: photoFile.path,
                capturedAtMs: 1795658400 * 1000,
              ),
            ],
          ),
    );
    await store.importSystemAlbumPhotos(service: dupPhotoLib);
    final attachedIds = store
        .activePhotosForEvent(store.events.single)
        .map((p) => p.id)
        .toList();
    expect(attachedIds, isNot(contains('alb_IMG_1_A')));
    expect(attachedIds, contains('alb_EXTERNAL_PHONE_PIC'));

    // 关闭写入相册开关后，新硬件照片不再写入相册
    await cfg.setSaveHardwareMediaToAlbum(false);
    final photo2 = File('${photosDir.path}/DYJ_SHOT_2.jpg')
      ..writeAsBytesSync([0xFF, 0xD8, 0xFF, 0xE1]);
    await backup.backupHardwareMediaItem(
      name: 'DYJ_SHOT_2.jpg',
      path: photo2.path,
      mediaType: 'photo',
      capturedAtMs: 1795658500 * 1000,
    );
    expect(savedCalls.length, 2);

    store.dispose();
    backup.dispose();
    cfg.dispose();
  });

  test('4~6. 未开 iCloud 仅文本入「文件」；开启 iCloud 后按 3 档范围及仅本机模式精确控流', () async {
    final root = await Directory.systemTemp.createTemp('rc_icloud_sync_');
    addTearDown(() async {
      if (await root.exists()) await root.delete(recursive: true);
    });

    final docsDir = Directory('${root.path}/Documents')..createSync(recursive: true);
    final photosDir = Directory('${root.path}/photos')..createSync(recursive: true);
    final indexDir = Directory('${root.path}/support')..createSync(recursive: true);
    final wavFile = File('${root.path}/rec1.wav')
      ..writeAsBytesSync([0x52, 0x49, 0x46, 0x46, 1, 2, 3, 4]);
    File('${photosDir.path}/CAM_1.jpg')
        .writeAsBytesSync([0xFF, 0xD8, 0xFF, 0xD9]);
    File('${photosDir.path}/VID_1.mp4')
        .writeAsBytesSync([0x00, 0x00, 0x00, 0x18]);

    final uploadedFiles = <String>[];
    final uploadedTexts = <String>[];
    final icloud = ICloudSyncService(
      statusOverride: () async =>
          const ICloudStatus(available: true, signedIn: true, containerPath: '/icloud'),
      syncFileOverride: (src, rel) async {
        uploadedFiles.add(rel);
        return ICloudSyncResult(ok: true, available: true, path: '/icloud/$rel');
      },
      syncTextOverride: (content, rel) async {
        uploadedTexts.add(rel);
        return ICloudSyncResult(ok: true, available: true, path: '/icloud/$rel');
      },
      statsOverride: () async => ICloudStats(
        available: true,
        signedIn: true,
        audio: uploadedFiles.where((e) => e.startsWith('Audio/')).length,
        transcripts: uploadedTexts.length,
        photos: uploadedFiles.where((e) => e.startsWith('Photos/')).length,
        videos: uploadedFiles.where((e) => e.startsWith('Videos/')).length,
        total: uploadedFiles.length + uploadedTexts.length,
      ),
    );

    final cfg = AgentConfigStore(store: InMemoryStore());
    await cfg.load();
    await cfg.setSaveHardwareMediaToAlbum(false);

    final backup = MediaBackupService(
      agentConfig: cfg,
      photoLibrary: PhotoLibraryService(directoryOverride: () async => photosDir),
      icloudSync: icloud,
      transcriptExporter: LocalTranscriptExporter(
        directoryOverride: () async => docsDir,
      ),
      indexDirOverride: () async => indexDir,
    );

    final rec = RecordingFile(
      deviceName: 'DYJ_001.amr',
      session: 'S001',
      seq: 1,
      startAtMs: DateTime(2026, 11, 26, 10, 30, 0).millisecondsSinceEpoch,
      apmPath: '',
      wavPath: wavFile.path,
      durationMs: 120000,
      stage: RecordingStage.ready,
      turns: const [
        PolishedTurn(
          id: 't1',
          startMs: 0,
          endMs: 5000,
          speakerLabel: '说话人 1（推测）',
          text: '今天测试点一机拍照与 iCloud 同步。',
          srcUtteranceIds: ['u1'],
        ),
      ],
      segments: [
        SegmentRecord(
          id: 'seg-1',
          sessionId: 'S001',
          index: 0,
          startAtMs: 0,
          endAtMs: 5000,
          title: '同步设计讨论',
          brief: '讨论点一机同步方案',
          longText: '确认默认只存文本到文件 App 与照片视频到相册。',
          status: SegmentStatus.closed,
          turnIds: ['t1'],
        ),
      ],
      createdAtMs: DateTime(2026, 11, 26, 10, 30, 0).millisecondsSinceEpoch,
    );

    // 4) 未开 iCloud：只把 .md 文本存到 Documents/，不放音频/视频/图片到 Documents/，也不上传 iCloud
    final offRes = await backup.backupRecording(rec);
    expect(offRes.localExported, isTrue);
    expect(offRes.icloudAudioSynced, isFalse);
    expect(offRes.icloudTextSynced, isFalse);
    expect(uploadedFiles, isEmpty);
    expect(uploadedTexts, isEmpty);
    final docFiles = docsDir
        .listSync(recursive: true)
        .whereType<File>()
        .map((f) => f.path)
        .toList();
    expect(docFiles.length, 1);
    expect(docFiles.single.endsWith('.md'), isTrue);
    expect(File(docFiles.single).readAsStringSync(), contains('同步设计讨论'));

    // 5a) 开启 iCloud + 仅音频
    await cfg.setICloudSyncEnabled(true);
    await cfg.setICloudSyncScope(ICloudSyncScope.audioOnly);
    await backup.syncAllNow(recordings: [rec], photosDirPath: photosDir.path);
    expect(uploadedFiles.any((e) => e.startsWith('Audio/2026-11-26/')), isTrue);
    expect(uploadedFiles.any((e) => e.startsWith('Photos/') && e.endsWith('CAM_1.jpg')), isTrue);
    expect(uploadedFiles.any((e) => e.startsWith('Videos/') && e.endsWith('VID_1.mp4')), isTrue);
    expect(uploadedTexts, isEmpty);

    // 5b) 切换「仅转录文本」（重置测试备份以验证仅文本模式不会上传音频）
    uploadedFiles.clear();
    uploadedTexts.clear();
    await backup.clearLocalExports();
    await cfg.setICloudSyncScope(ICloudSyncScope.textOnly);
    await backup.syncAllNow(recordings: [rec], photosDirPath: photosDir.path);
    expect(uploadedFiles.any((e) => e.startsWith('Audio/')), isFalse);
    expect(uploadedTexts.any((e) => e.startsWith('Transcripts/2026-11-26/')), isTrue);
    expect(uploadedFiles.any((e) => e.startsWith('Photos/')), isTrue);
    expect(uploadedFiles.any((e) => e.startsWith('Videos/')), isTrue);

    // 5c) 切换「音频 + 转录文本」
    uploadedFiles.clear();
    uploadedTexts.clear();
    await backup.clearLocalExports();
    await cfg.setICloudSyncScope(ICloudSyncScope.audioAndText);
    await backup.syncAllNow(recordings: [rec], photosDirPath: photosDir.path);
    expect(uploadedFiles.any((e) => e.startsWith('Audio/2026-11-26/')), isTrue);
    expect(uploadedTexts.any((e) => e.startsWith('Transcripts/2026-11-26/')), isTrue);

    // 6) 开启「仅本机模式」暂停 iCloud 上传
    uploadedFiles.clear();
    uploadedTexts.clear();
    await backup.clearLocalExports();
    await cfg.setLocalOnlyMode(true);
    await backup.syncAllNow(recordings: [rec], photosDirPath: photosDir.path);
    expect(uploadedFiles, isEmpty);
    expect(uploadedTexts, isEmpty);

    backup.dispose();
    cfg.dispose();
  });

  test('7. 双击拍照识别落盘到持久化目录并自动触发相册/iCloud备份', () async {
    final root = await Directory.systemTemp.createTemp('rc_photo_recog_');
    addTearDown(() async {
      if (await root.exists()) await root.delete(recursive: true);
    });
    final photosDir = Directory('${root.path}/photos')..createSync(recursive: true);
    final docsDir = Directory('${root.path}/docs')..createSync(recursive: true);
    final indexDir = Directory('${root.path}/support')..createSync(recursive: true);

    final savedPaths = <String>[];
    final photoLib = PhotoLibraryService(
      directoryOverride: () async => photosDir,
      saveMediaOverride: ({
        required String path,
        required String mediaType,
        int? capturedAtMs,
        bool promptIfNeeded = true,
      }) async {
        savedPaths.add(path);
        return const MediaAlbumSaveResult(
          saved: true,
          authorized: true,
          localIdentifier: 'RECOG/1',
        );
      },
    );

    final gw = FakeCardGateway(
      initialSnapshot: const CardSnapshot(
        batteryLevel: 90,
        isCharging: false,
        wifiOpen: false,
        recording: false,
        fwVersion: '0.8.15',
        fwVersionCode: 815,
        wifiVersion: '',
        wifiVersionCode: 0,
        deviceName: 'DYJ_01',
        deviceId: 'dyj-1',
        deviceKind: DeviceKind.dyjV1,
        capabilities: HardwareCapabilities.dyjV1,
      ),
      fakeCapturedPhotoBytes: Uint8List.fromList([0xFF, 0xD8, 0xFF, 0xE0, 1, 2]),
    );
    final device = DeviceStore(gateway: gw);
    await device.restoreLink();
    final cfg = AgentConfigStore(store: InMemoryStore());
    await cfg.load();
    final backup = MediaBackupService(
      agentConfig: cfg,
      photoLibrary: photoLib,
      transcriptExporter: LocalTranscriptExporter(
        directoryOverride: () async => docsDir,
      ),
      indexDirOverride: () async => indexDir,
    );
    final appStore = AppStore(loadPersistedState: false);
    final speech = _SilentSpeechBackend();
    final chat = AgentChatController(
      appStore: appStore,
      agentConfig: cfg,
      completion: _StubCompletion(),
      speech: speech,
      agentDirResolver: () async => '',
    );
    final liveAudio = LiveAudioRecorder(gateway: gw);
    final coord = HardwareAgentTaskCoordinator(
      device: device,
      agentConfig: cfg,
      agentChat: chat,
      liveAudio: liveAudio,
      postSettleDelay: Duration.zero,
      transientStatusDuration: Duration.zero,
      maxVoiceTaskDuration: Duration.zero,
      transcribeSamples: (s, {int sampleRate = 16000}) async => '',
      photoLibrary: photoLib,
      mediaBackup: backup,
    );

    gw.pushButtonEvent(gesture: 'double_click', receivedAtMs: 10000);
    await device.pollEventsNow();
    await coord.idle;
    await Future<void>.delayed(const Duration(milliseconds: 80));

    expect(savedPaths.length, 1);
    expect(savedPaths.single.startsWith(photosDir.path), isTrue);
    expect(File(savedPaths.single).existsSync(), isTrue);

    coord.dispose();
    liveAudio.dispose();
    chat.dispose();
    speech.dispose();
    appStore.dispose();
    backup.dispose();
    cfg.dispose();
    device.dispose();
  });

  testWidgets('8. 设置页与 iCloud 二级页：相册写入开关、iCloud 未开通提示与三档范围切换', (
    tester,
  ) async {
    final root = Directory.systemTemp.createTempSync('rc_icloud_widget_');
    addTearDown(() {
      if (root.existsSync()) root.deleteSync(recursive: true);
    });
    final docsDir = Directory('${root.path}/docs')..createSync(recursive: true);
    final photosDir = Directory('${root.path}/photos')..createSync(recursive: true);
    final indexDir = Directory('${root.path}/support')..createSync(recursive: true);

    var addPerm = PhotoPermissionState.notDetermined;
    final photoLib = PhotoLibraryService(
      directoryOverride: () async => photosDir,
      addStatusOverride: () async => addPerm,
      requestAddOverride: () async {
        addPerm = PhotoPermissionState.granted;
        return addPerm;
      },
    );

    var icloudAvailable = false;
    final icloud = ICloudSyncService(
      statusOverride: () async => ICloudStatus(
        available: icloudAvailable,
        signedIn: icloudAvailable,
        error: icloudAvailable ? null : '请先登录 Apple 账户并开启 iCloud 云盘',
      ),
      statsOverride: () async => ICloudStats(
        available: icloudAvailable,
        signedIn: icloudAvailable,
      ),
    );

    final settings = SettingsStore(store: InMemoryStore());
    await settings.load();
    final cfg = AgentConfigStore(store: InMemoryStore());
    await cfg.load();
    final backup = MediaBackupService(
      agentConfig: cfg,
      photoLibrary: photoLib,
      icloudSync: icloud,
      transcriptExporter: LocalTranscriptExporter(
        directoryOverride: () async => docsDir,
      ),
      indexDirOverride: () async => indexDir,
    );
    await tester.runAsync(() => backup.ensureLoaded());

    Future<void> waitForBackupSync() async {
      await tester.pump();
      for (var i = 0; i < 100 && backup.isSyncRunning; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
        await tester.pump();
      }
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump();
      await tester.pumpAndSettle();
    }

    // 8a) SettingPage 同步组开关
    await tester.pumpWidget(
      _wrapWithTheme(
        SettingPage(
          settings: settings,
          agentConfig: cfg,
          photoLibrary: photoLib,
          mediaBackup: backup,
        ),
      ),
    );
    await tester.pump();

    await tester.scrollUntilVisible(
      find.byKey(const Key('set-hw-album-save')),
      180,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.byKey(const Key('set-hw-album-save')), findsOneWidget);
    expect(find.byKey(const Key('set-icloud-sync')), findsOneWidget);

    await tester.tap(find.byKey(const Key('set-hw-album-save')));
    await tester.pumpAndSettle();
    expect(cfg.saveHardwareMediaToAlbum, isFalse);

    // 重开：因 notDetermined 先弹授权确认框
    await tester.tap(find.byKey(const Key('set-hw-album-save')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('hw-album-perm-dialog')), findsOneWidget);
    await tester.tap(find.byKey(const Key('hw-album-perm-grant')));
    await tester.pumpAndSettle();
    expect(cfg.saveHardwareMediaToAlbum, isTrue);

    // 8b) iCloud 二级页：系统未开 iCloud 时如实提示并保持关闭；可用后开启并切换三档范围
    await tester.pumpWidget(
      _wrapWithTheme(
        SettingSubPage(
          subId: 'icloud',
          agentConfig: cfg,
          mediaBackup: backup,
          standalone: true,
        ),
      ),
    );
    await tester.pump();
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('icloud-sync-toggle')));
    await tester.pumpAndSettle();
    expect(cfg.icloudSyncEnabled, isFalse);
    expect(find.textContaining('请先登录 Apple 账户'), findsOneWidget);

    icloudAvailable = true;
    await tester.tap(find.byKey(const Key('icloud-sync-toggle')));
    await waitForBackupSync();
    expect(cfg.icloudSyncEnabled, isTrue);

    await tester.tap(find.byKey(const Key('icloud-scope-audio')));
    await waitForBackupSync();
    expect(cfg.icloudSyncScope, ICloudSyncScope.audioOnly);

    await tester.tap(find.byKey(const Key('icloud-scope-text')));
    await waitForBackupSync();
    expect(cfg.icloudSyncScope, ICloudSyncScope.textOnly);

    await tester.tap(find.byKey(const Key('icloud-scope-audio-text')));
    await waitForBackupSync();
    expect(cfg.icloudSyncScope, ICloudSyncScope.audioAndText);

    backup.dispose();
    cfg.dispose();
    settings.dispose();
  });
}
