/// 录音处理管线 —— 把设备文件变成「切片 + 原始句 + 润色 turn + 分段」的本地数据。
///
/// 一条文件的处理顺序（每一步都可重入/续跑）：
///   download(.apm) → transcode(.wav) → VAD 切片 → 逐片 ASR → 声纹聚类 → ready
///
/// 失败语义：
/// - 单个文件失败不影响其它文件；失败原因写进 `RecordingFile.error`，下次同步重试；
/// - 模型未就绪时只下载/转码，音频入库排队，不丢文件、不上传音频；
/// - 每片转写完成立即落盘，杀进程后从第一片未完成的继续。
library;

import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import '../../core/device/card_gateway.dart';
import '../../core/models/recording.dart';
import '../../core/models/summary.dart';
import '../../core/store/agent_config_store.dart';
import '../../core/store/settings_store.dart';
import '../../core/store/voiceprint_library_store.dart';
import '../audio/live_audio_recorder.dart';
import '../polish/slice_polish_service.dart';
import '../segment/fast_topic_segment_agent.dart';
import '../segment/rolling_clean_segment_service.dart';
import '../segment/segment_build_service.dart';
import '../transcribe/local_asr_service.dart';
import '../transcribe/slice_planner.dart';
import '../transcribe/speaker_clusterer.dart';
import '../transcribe/speech_engine.dart';
import '../transcribe/speech_models.dart';
import '../transcribe/system_speech_client.dart';
import '../transcribe/utterance_builder.dart';
import '../transcribe/wav_io.dart';
import '../voiceprint/joint_speaker_resolver.dart';
import 'multi_track_reconciler.dart';
import 'network_policy.dart';
import 'recording_store.dart';
import 'speaker_profile_store.dart';

/// 管线阶段（用于状态块与进度条文案）。
enum PipelineStage {
  listing,
  downloading,
  transcoding,
  slicing,
  transcribing,
  labeling,
  polishing,
  summarizing,
  done,
}

class PipelineProgress {
  const PipelineProgress({
    required this.stage,
    required this.fileIndex,
    required this.fileTotal,
    this.fileName,
    this.sliceIndex,
    this.sliceTotal,
    this.text = '',
  });

  final PipelineStage stage;
  final int fileIndex;
  final int fileTotal;
  final String? fileName;
  final int? sliceIndex;
  final int? sliceTotal;
  final String text;

  double get progress {
    if (fileTotal <= 0) return 0;
    if (stage == PipelineStage.done) {
      return ((fileIndex + 1) / fileTotal).clamp(0.0, 1.0);
    }
    final base = fileIndex / fileTotal;
    final step = 1 / fileTotal;
    final slicePart = (sliceTotal ?? 0) <= 0
        ? 0.0
        : (sliceIndex ?? 0) / sliceTotal!;
    return (base + step * (0.2 + 0.8 * slicePart)).clamp(0, 1);
  }
}

class PipelineSyncResult {
  const PipelineSyncResult({
    required this.downloaded,
    required this.ready,
    required this.skipped,
    required this.failed,
    required this.failures,
    this.error,
    this.pausedForLiveRecording = false,
  });

  final int downloaded;
  final int ready;
  final int skipped;
  final int failed;
  final List<String> failures;
  final String? error;
  final bool pausedForLiveRecording;

  bool get hasFailure => failed > 0 || error != null;
}

class PipelineException implements Exception {
  const PipelineException(this.message);
  final String message;
  @override
  String toString() => message;
}


/// 顶部同步状态用的人类可读时间标签（不暴露设备文件名）。
String pipelineTimeLabel(RecordingFile file) {
  final ms = file.startAtMs;
  if (ms > 0) {
    final dt = DateTime.fromMillisecondsSinceEpoch(ms);
    final hh = dt.hour.toString().padLeft(2, '0');
    final mm = dt.minute.toString().padLeft(2, '0');
    return '$hh:$mm';
  }
  // watch_watch-202611161430… 等长文件名兜底：抽出 YYYYMMDDHHmm
  final m = RegExp(r'(20\d{10,12})').firstMatch(file.deviceName);
  final raw = m?.group(1);
  if (raw != null && raw.length >= 12) {
    return '${raw.substring(8, 10)}:${raw.substring(10, 12)}';
  }
  return '这段录音';
}

class RecordingPipeline {
  RecordingPipeline({
    required this.gateway,
    required this.store,
    required this.engine,
    required this.models,
    this.settings,
    this.agentConfig,
    this.language = 'auto',
    this.slicePlanner = const SlicePlanner(),
    this.clusterer = const SpeakerClusterer(),
    this.polish,
    this.segments,
    this.topicAgent,
    this.rollingCleaner,
    TopicSegmentationStore? topicStore,
    this.voiceprintStore,
    this.multiTrackReconciler,
    MultiTrackReconciliationStore? reconciliationStore,
    this.bleDeviceLabelResolver,
    this.network = const NetworkPolicy(),
    this.liveAudioBaseDir,
    this.skipLegacyCloudPolishWhenRollingActive = true,
    this.localQuotaAllowTranscribe,
    this.onLocalTranscribed,
    this.apmSourceSampleRateResolver,
  }) : _topicStore = topicStore,
       _reconciliationStore = reconciliationStore;

  static const String quotaExhaustedMessage =
      '本月 3,600 分钟免费本地转写额度已用完，录音已安全保存在本机队列；次月 1 日恢复免费转写或升级 Local Pro 立即继续';

  final bool skipLegacyCloudPolishWhenRollingActive;
  final bool Function()? localQuotaAllowTranscribe;
  final void Function(int durationMs)? onLocalTranscribed;
  final double? Function(RecordingFile file)? apmSourceSampleRateResolver;

  final CardGateway gateway;
  final RecordingStore store;
  final SpeechEngine engine;
  final SpeechModelProvider models;
  final AgentConfigStore? agentConfig;
  final FastTopicSegmentAgent? topicAgent;
  final RollingCleanSegmentService? rollingCleaner;
  final VoiceprintLibraryStore? voiceprintStore;
  final MultiTrackReconciler? multiTrackReconciler;
  final String? Function()? bleDeviceLabelResolver;
  TopicSegmentationStore? _topicStore;
  MultiTrackReconciliationStore? _reconciliationStore;

  TopicSegmentationStore get topicStore =>
      _topicStore ??= TopicSegmentationStore(resolveRoot: store.root);

  MultiTrackReconciliationStore get reconciliationStore =>
      _reconciliationStore ??= MultiTrackReconciliationStore(
        resolveRoot: store.root,
      );

  /// 清理本地存量“仅孤立标点幻觉（如 `。`）”与历史 `实时切片 #N` 标题，一次性幂等清洗落盘。
  Future<int> sanitizeLegacyDirtyRecordings() async {
    final files = await store.loadAll(refresh: true);
    final legacyTitlePattern = RegExp(r'^实时切片\s*#\d+(?:（未识别到人声）)?$');
    var fixed = 0;

    for (final file in files) {
      if (file.isExternalImported) continue;
      var changed = false;
      final cleanUtterances = [
        for (final u in file.utterances)
          if (isMeaningfulSpeechText(u.text)) u,
      ];
      if (cleanUtterances.length != file.utterances.length) {
        file.utterances = cleanUtterances;
        changed = true;
      }

      final cleanTurns = [
        for (final t in file.turns)
          if (isMeaningfulSpeechText(t.text)) t,
      ];
      if (cleanTurns.length != file.turns.length) {
        file.turns = cleanTurns;
        changed = true;
      }

      final nextSegments = <SegmentRecord>[];
      for (final seg in file.segments) {
        final hasSpeech = cleanUtterances.isNotEmpty || cleanTurns.isNotEmpty;
        final badTitle =
            legacyTitlePattern.hasMatch(seg.title.trim()) ||
            !isMeaningfulSpeechText(seg.title);
        final badBrief =
            !isMeaningfulSpeechText(seg.brief) ||
            legacyTitlePattern.hasMatch(seg.brief.trim());
        final badLong =
            !isMeaningfulSpeechText(seg.longText) ||
            legacyTitlePattern.hasMatch(seg.longText.trim());
        final shouldSilent = !hasSpeech && seg.status != SegmentStatus.live;

        if (shouldSilent &&
            (seg.title.trim() != '未识别到语音' ||
                seg.turnIds.isNotEmpty ||
                badTitle ||
                badBrief)) {
          changed = true;
          nextSegments.add(
            SegmentRecord(
              id: seg.id,
              sessionId: seg.sessionId,
              index: seg.index,
              startAtMs: seg.startAtMs,
              endAtMs: seg.endAtMs,
              title: '未识别到语音',
              brief: '本段未检测到有效人声，原始录音已保存在本机。',
              longText: '本段未检测到有效人声，原始录音已保存在本机，可在详情「原始数据」回听。',
              tags: seg.tags,
              status: seg.status,
              sliceIds: seg.sliceIds,
              turnIds: const [],
              mark: seg.mark,
              polishStale: false,
              fallback: false,
            ),
          );
          continue;
        }

        if (hasSpeech && (badTitle || badBrief || badLong)) {
          changed = true;
          final seedText = cleanTurns.isNotEmpty
              ? cleanTurns.map((t) => t.text.trim()).join(' ')
              : cleanUtterances.map((u) => u.text.trim()).join(' ');
          final fallbackBrief = seedText.length <= 68
              ? seedText
              : '${seedText.substring(0, 68)}…';
          final fallbackLong = seedText.length <= 120
              ? seedText
              : '${seedText.substring(0, 120)}…';
          nextSegments.add(
            SegmentRecord(
              id: seg.id,
              sessionId: seg.sessionId,
              index: seg.index,
              startAtMs: seg.startAtMs,
              endAtMs: seg.endAtMs,
              title: badTitle
                  ? buildReadableFallbackTitle(seedText, fallback: '语音片段')
                  : seg.title,
              brief: badBrief ? fallbackBrief : seg.brief,
              longText: badLong ? fallbackLong : seg.longText,
              speakerLabels: seg.speakerLabels,
              speakerCount: seg.speakerCount,
              tags: seg.tags,
              status: seg.status,
              sliceIds: seg.sliceIds,
              turnIds: [for (final t in cleanTurns) t.id],
              mark: seg.mark,
              polishStale: seg.polishStale,
              fallback: seg.fallback,
            ),
          );
          continue;
        }

        nextSegments.add(seg);
      }
      file.segments = nextSegments;

      if (changed) {
        await store.save(file);
        fixed++;
      }
    }
    return fixed;
  }

  /// 检查当前是否存在到达清洗周期或静音停顿门槛的未清洗语料。
  Future<bool> hasReadyRollingCleanTrigger({int? wallClockNowMs}) async {
    final cleaner = rollingCleaner;
    if (cleaner == null || !cleaner.isReady) return false;
    final files = await store.loadAll(refresh: false);
    final state = await topicStore.load();
    return cleaner.hasReadyTrigger(
      files,
      state,
      wallClockNowMs: wallClockNowMs,
    );
  }

  /// 执行滚动语意+声纹联合清洗与话题分段（按配置周期或停顿/停录/手动强制重洗）。
  Future<RollingCleanResult?> runRollingClean({
    bool forceRecleanAll = false,
    bool sessionJustEnded = false,
    int? wallClockNowMs,
    void Function(String status)? onProgress,
  }) async {
    await sanitizeLegacyDirtyRecordings();
    final cleaner = rollingCleaner;
    if (cleaner == null) return null;
    final all = await store.loadAll(refresh: true);
    return cleaner.run(
      all,
      topicStore: topicStore,
      forceRecleanAll: forceRecleanAll,
      sessionJustEnded: sessionJustEnded,
      wallClockNowMs: wallClockNowMs,
      onProgress: onProgress,
    );
  }

  /// 在录音出现 `>= 1 分钟` 空白或录音停止时，触发快速话题分段 Agent 并写入幂等水位锁。
  Future<TopicSegmentEvaluationResult?> evaluateTopicSegmentation({
    bool sessionJustEnded = false,
    int? wallClockNowMs,
  }) async {
    final agent = topicAgent;
    if (agent == null) return null;
    final all = await store.loadAll(refresh: true);
    return agent.evaluateRuns(
      all,
      store: topicStore,
      sessionJustEnded: sessionJustEnded,
      wallClockNowMs: wallClockNowMs,
    );
  }

  /// 实时音频存储根目录（测试注入；生产为 null 默认走 ApplicationSupport）。
  final Directory? liveAudioBaseDir;

  /// 设置开关；null 时按默认全开（测试/旧调用）。
  final SettingsStore? settings;

  /// 网络策略：让「仅使用 Wi-Fi 同步」真正生效。
  final NetworkPolicy network;

  /// 「仅使用 Wi-Fi 同步」开关的存储键（与 SettingsStore 定义一致）。
  static const wifiOnlyKey = 'rc.set.sync.wifiOnly';

  bool get _wifiOnly => settings?.value(wifiOnlyKey) ?? false;

  static const autoTranscribeKey = 'rc.set.trans.auto';
  static const cleanSpeechKey = 'rc.set.trans.clean';
  static const speakerLabelKey = 'rc.set.trans.speaker';

  bool get _autoTranscribe => settings?.value(autoTranscribeKey) ?? true;
  bool get _cleanSpeech => settings?.value(cleanSpeechKey) ?? true;
  bool get _speakerLabel => settings?.value(speakerLabelKey) ?? true;

  final String language;
  final SlicePlanner slicePlanner;
  final SpeakerClusterer clusterer;

  /// 云端窗口润色；null 或未配置时只保留本地原始数据。
  final SlicePolishService? polish;

  /// 阶段总结/话题分段；null 时只留下 turn，不产出 Timeline 分段。
  final SegmentBuildService? segments;

  bool _busy = false;
  bool _syncYieldRequested = false;
  Completer<void>? _busyDone;
  Future<void> _liveSerial = Future<void>.value();

  bool get isBusy => _busy;

  /// 当现场开录/保底切片抢占同一蓝牙链路时，通知进行中的离线 [sync] 在当前文件落盘后礼让暂停。
  bool requestSyncPauseForLiveRecording() {
    if (!_busy) return false;
    _syncYieldRequested = true;
    return true;
  }

  void _enterBusy() {
    _busy = true;
    _busyDone = Completer<void>();
  }

  void _exitBusy() {
    _busy = false;
    final done = _busyDone;
    _busyDone = null;
    if (done != null && !done.isCompleted) done.complete();
  }

  Future<void> _waitUntilIdle() async {
    while (_busy) {
      final done = _busyDone;
      if (done == null) break;
      await done.future;
    }
  }

  /// 硬件侧 Wi-Fi 模块上电期间会独占 SD 卡总线，导致蓝牙 `FILE_LIST` / `FILE_UPLOAD`
  /// 报 `SD card is owned by the WiFi module`。读卡文件前先尝试关闭 Wi-Fi 归还总线。
  Future<void> _ensureSdCardOnMcu() async {
    try {
      await gateway.closeWifi();
    } on Object {
      // 未开启或固件不支持时静默放行
    }
  }

  /// 判断卡端 `.APM` 是否已被本机无断档实时流切片覆盖并落库（避免慢速蓝牙重复拉取）。
  ///
  /// 注意：仅 `ble` 路实时流可以覆盖卡端 `.APM` 文件；手表（`watch_`）或手机兜底（`LIVE_PHONE_`）
  /// 切片**绝不允许**跳过蓝牙卡离线文件的拉取，确保断连回连后仍拉回完整数据参与比对合并。
  bool _isCoveredByLiveSlices(
    CardFile source,
    List<LiveSession> liveSessions,
    List<RecordingFile> localFiles,
  ) {
    for (final session in liveSessions) {
      if (!session.coversCardFile(source)) continue;
      final hasLocalSlice = localFiles.any((f) {
        if (f.resolvedSourceLane != RecordingSourceLane.ble) return false;
        final hasLocalWav =
            f.stage == RecordingStage.ready ||
            (f.wavPath != null &&
                f.wavPath!.isNotEmpty &&
                File(f.wavPath!).existsSync());
        if (!hasLocalWav) return false;
        if (session.sliceKeys.contains(f.deviceName)) return true;
        if (session.deviceSessionId != null &&
            session.deviceSessionId!.isNotEmpty &&
            f.session == session.deviceSessionId &&
            f.deviceName.startsWith('LIVE_') &&
            !f.deviceName.startsWith('LIVE_PHONE_')) {
          return true;
        }
        return f.session == session.id;
      });
      if (hasLocalSlice) return true;
    }
    return false;
  }

  /// 录音开启期间静默落盘：仅把刚封口的 WAV 切片登记进本地存储等待批量/按需转写，
  /// 不立即触发 VAD / ASR / 声纹与时间轴碎片生成。
  Future<RecordingFile> storeLiveSlicePending(LiveAudioSlice slice) {
    final completer = Completer<RecordingFile>();
    _liveSerial = _liveSerial.then((_) async {
      await _waitUntilIdle();
      _enterBusy();
      try {
        final existing = await store.load(slice.sliceKey);
        final sessionKey = (slice.deviceSessionId != null &&
                slice.deviceSessionId!.trim().isNotEmpty)
            ? slice.deviceSessionId!.trim()
            : slice.sessionId;
        final resolvedLane = slice.sourceLane ??
            (slice.sliceKey.toUpperCase().startsWith('LIVE_PHONE_')
                ? RecordingSourceLane.phone.code
                : (slice.sliceKey.toUpperCase().startsWith('WATCH_')
                      ? RecordingSourceLane.watch.code
                      : RecordingSourceLane.ble.code));
        final resolvedLabel = slice.sourceDeviceLabel?.trim().isNotEmpty == true
            ? slice.sourceDeviceLabel!.trim()
            : (resolvedLane == RecordingSourceLane.phone.code
                  ? '手机本机'
                  : (resolvedLane == RecordingSourceLane.watch.code
                        ? 'Apple Watch'
                        : (bleDeviceLabelResolver?.call()?.trim().isNotEmpty ==
                                  true
                              ? bleDeviceLabelResolver!.call()!.trim()
                              : '蓝牙设备')));
        final file = existing ??
            RecordingFile(
              deviceName: slice.sliceKey,
              session: sessionKey,
              seq: slice.sliceIndex + 1,
              startAtMs: slice.startAtMs,
              timeSynced: true,
              apmPath: slice.wavPath,
              wavPath: slice.wavPath,
              durationMs: slice.durationMs,
              createdAtMs: DateTime.now().millisecondsSinceEpoch,
              stage: RecordingStage.transcribing,
              sourceLane: resolvedLane,
              sourceDeviceLabel: resolvedLabel,
            );
        if (file.stage != RecordingStage.ready) {
          file
            ..apmPath = slice.wavPath
            ..wavPath = slice.wavPath
            ..durationMs = slice.durationMs
            ..stage = RecordingStage.transcribing
            ..sourceLane = resolvedLane
            ..sourceDeviceLabel = resolvedLabel
            ..segments = const []
            ..error = null;
          await store.save(file);
        }
        completer.complete(file);
      } on Object catch (e, st) {
        completer.completeError(e, st);
      } finally {
        _exitBusy();
      }
    });
    return completer.future;
  }

  /// 对本地所有已落盘的多路录音执行时间重叠对齐、去重合并与语义分叉判定，并落盘决策表。
  Future<MultiTrackReconciliationState> reconcileMultiTrack({
    List<RecordingFile>? files,
  }) async {
    final loadedFiles = files ?? await store.loadAll(refresh: true);
    final prev = await reconciliationStore.load();
    final reconciler = multiTrackReconciler ?? MultiTrackReconciler();
    final next = await reconciler.reconcile(
      loadedFiles,
      previous: prev.needsReconcile ? null : prev,
    );
    await reconciliationStore.save(next);
    return next;
  }

  /// 录音开启期间：把刚封口的一份实时流 WAV 切片直接送入本地 VAD + SenseVoice 转写并落库。
  ///
  /// 关键特性：
  /// - 不访问蓝牙文件接口（不打断正在进行的 `realtime.open` 音频推流）；
  /// - 内部按 FIFO 排队串行推理，多片到达或刚巧遇到前序任务收尾时等待执行，绝不丢片；
  /// - 本阶段只做本地转写与本地声纹推测并保存原始信息，**不调用云端文本润色与云端分段总结**。
  Future<RecordingFile> ingestLiveSlice(
    LiveAudioSlice slice, {
    void Function(PipelineProgress progress)? onProgress,
  }) {
    final completer = Completer<RecordingFile>();
    _liveSerial = _liveSerial.then((_) async {
      await _waitUntilIdle();
      _enterBusy();
      try {
        final result = await _ingestLiveSliceUnlocked(
          slice,
          onProgress: onProgress,
        );
        completer.complete(result);
      } on Object catch (e, st) {
        completer.completeError(e, st);
      } finally {
        _exitBusy();
      }
    });
    return completer.future;
  }

  Future<RecordingFile> _ingestLiveSliceUnlocked(
    LiveAudioSlice slice, {
    void Function(PipelineProgress progress)? onProgress,
  }) async {
    final existing = await store.load(slice.sliceKey);
    final sessionKey = (slice.deviceSessionId != null &&
            slice.deviceSessionId!.trim().isNotEmpty)
        ? slice.deviceSessionId!.trim()
        : slice.sessionId;
    final resolvedLane = slice.sourceLane ??
        (slice.sliceKey.toUpperCase().startsWith('LIVE_PHONE_')
            ? RecordingSourceLane.phone.code
            : (slice.sliceKey.toUpperCase().startsWith('WATCH_')
                  ? RecordingSourceLane.watch.code
                  : RecordingSourceLane.ble.code));
    final resolvedLabel = slice.sourceDeviceLabel?.trim().isNotEmpty == true
        ? slice.sourceDeviceLabel!.trim()
        : (resolvedLane == RecordingSourceLane.phone.code
              ? '手机本机'
              : (resolvedLane == RecordingSourceLane.watch.code
                    ? 'Apple Watch'
                    : (bleDeviceLabelResolver?.call()?.trim().isNotEmpty == true
                          ? bleDeviceLabelResolver!.call()!.trim()
                          : '蓝牙设备')));
    final file = existing ??
        RecordingFile(
          deviceName: slice.sliceKey,
          session: sessionKey,
          seq: slice.sliceIndex + 1,
          startAtMs: slice.startAtMs,
          timeSynced: true,
          apmPath: slice.wavPath,
          wavPath: slice.wavPath,
          durationMs: slice.durationMs,
          createdAtMs: DateTime.now().millisecondsSinceEpoch,
          stage: RecordingStage.transcribing,
          sourceLane: resolvedLane,
          sourceDeviceLabel: resolvedLabel,
        );
    file
      ..apmPath = slice.wavPath
      ..wavPath = slice.wavPath
      ..durationMs = slice.durationMs
      ..sourceLane ??= resolvedLane
      ..sourceDeviceLabel ??= resolvedLabel
      ..error = null;
    await store.save(file);

    void report(PipelineStage stage, String text) {
      onProgress?.call(
        PipelineProgress(
          stage: stage,
          fileIndex: 0,
          fileTotal: 1,
          fileName: file.deviceName,
          sliceIndex: 0,
          sliceTotal: 1,
          text: text,
        ),
      );
    }

    final dir = await store.dirFor(file.deviceName);
    if (!await dir.exists()) await dir.create(recursive: true);

    SpeechModelPaths? paths;
    try {
      paths = await models.resolve();
    } on Object catch (e) {
      file
        ..stage = RecordingStage.transcoding
        ..error = '本地模型未就绪：$e';
      await store.save(file);
      return file;
    }
    if (paths == null || !paths.canTranscribe) {
      file
        ..stage = RecordingStage.transcoding
        ..error = '本地转写模型未就绪';
      await store.save(file);
      return file;
    }

    final wavFile = File(slice.wavPath);
    if (!await wavFile.exists()) {
      file
        ..stage = RecordingStage.failed
        ..error = '实时切片音频不存在：${slice.wavPath}';
      await store.save(file);
      return file;
    }

    final wav = readWavFile(slice.wavPath);
    Float32List? rawSamples;
    Float32List? conditionedFull;
    bool? needsConditioning;
    Float32List ensureRaw() => rawSamples ??= wav.toFloat32();
    Float32List ensureConditioned() =>
        conditionedFull ??= conditionSpeechSamples(
          ensureRaw(),
          sampleRate: wav.sampleRate,
        );
    bool canReuseSliceWavDirectly() =>
        !(needsConditioning ??= needsSignalConditioning(
          ensureRaw(),
          sampleRate: wav.sampleRate,
        ));
    final sliceSamplesById = <String, Float32List>{};

    var usedAcousticFallback = false;
    if (wav.frames > 0 && file.slices.isEmpty) {
      report(PipelineStage.slicing, '正在切分第 ${slice.sliceIndex + 1} 片实时录音');
      await engine.loadVad(paths.vadPath);
      final conditioned = ensureConditioned();
      final spans = await engine.detectSpeech(conditioned);
      var planned = slicePlanner.plan(
        speech: spans,
        totalSamples: wav.frames,
        sampleRate: wav.sampleRate,
      );
      // 兜底：若 VAD 未检出区间，但去直流后存在明显高于底噪的声学能量，
      // 按 30 秒窗口直接送入 SenseVoice 由 ASR 模型自身判定是否有人声。
      if (planned.isEmpty &&
          hasAcousticSpeechCandidate(ensureRaw(), sampleRate: wav.sampleRate)) {
        usedAcousticFallback = true;
        final chunkSamples = wav.sampleRate * 30;
        final fallback = <PlannedSlice>[];
        var idx = 0;
        for (var s = 0; s < wav.frames; s += chunkSamples) {
          final e = (s + chunkSamples < wav.frames)
              ? s + chunkSamples
              : wav.frames;
          if (e > s) {
            fallback.add(
              PlannedSlice(
                index: idx++,
                startSample: s,
                endSample: e,
                silenceAfterSamples: 0,
              ),
            );
          }
        }
        planned = fallback;
      }
      final sliceDir = Directory('${dir.path}/slices');
      if (!await sliceDir.exists()) await sliceDir.create(recursive: true);
      final slices = <AudioSlice>[];
      for (final plan in planned) {
        final id = plan.index.toString().padLeft(4, '0');
        final path = '${sliceDir.path}/$id.wav';
        await File(path).writeAsBytes(
          wav.sliceWav(plan.startSample, plan.endSample),
          flush: true,
        );
        final cs = plan.startSample.clamp(0, conditioned.length);
        final ce = plan.endSample.clamp(cs, conditioned.length);
        sliceSamplesById[id] = Float32List.sublistView(conditioned, cs, ce);
        slices.add(
          AudioSlice(
            id: id,
            index: plan.index,
            startMs: plan.startMs(wav.sampleRate),
            endMs: plan.endMs(wav.sampleRate),
            wavPath: path,
            silenceAfterMs: plan.silenceAfterMs(wav.sampleRate),
          ),
        );
      }
      file
        ..slices = slices
        ..stage = RecordingStage.transcribing;
      await store.save(file);
    }

    if (!_autoTranscribe) {
      file
        ..segments = [_buildLocalSliceSegment(file, slice)]
        ..stage = RecordingStage.ready
        ..error = null;
      await store.save(file);
      return file;
    }

    if (localQuotaAllowTranscribe != null && !localQuotaAllowTranscribe!()) {
      file
        ..stage = RecordingStage.transcribing
        ..error = quotaExhaustedMessage;
      await store.save(file);
      report(
        PipelineStage.transcribing,
        '本月免费转写额度已满，录音已安全保存在本机队列',
      );
      return file;
    }

    if (file.slices.isNotEmpty) {
      await engine.load(
        modelPath: paths.asrModelPath,
        tokensPath: paths.tokensPath,
        language: language,
      );
      final conditioned = ensureConditioned();
      final total = file.slices.length;
      var newlyTranscribedMs = 0;
      for (var i = 0; i < total; i++) {
        final sub = file.slices[i];
        if (sub.stage == SliceStage.transcribed ||
            sub.stage == SliceStage.polished) {
          continue;
        }
        report(
          PipelineStage.transcribing,
          '正在本地转写第 ${slice.sliceIndex + 1} 片（${i + 1}/$total）',
        );
        final subSamples =
            sliceSamplesById[sub.id] ??
            _sliceConditionedView(conditioned, sub, wav.sampleRate);
        final result = await _transcribeSliceAudio(
          subSamples,
          sampleRate: wav.sampleRate,
          directWavPath: canReuseSliceWavDirectly() ? sub.wavPath : null,
        );
        final utterances = buildUtterancesFromAsr(
          sliceId: sub.id,
          sliceStartMs: sub.startMs,
          sliceEndMs: sub.endMs,
          text: result.text,
          tokens: result.tokens,
          tokenTimestampsMs: result.timestampsMs,
          lang: result.lang,
          emotion: result.emotion,
        );
        file.utterances = [
          ...file.utterances.where((u) => u.sliceId != sub.id),
          ...utterances,
        ]..sort((a, b) => a.startMs.compareTo(b.startMs));
        file.slices[i] = sub.copyWith(
          stage: SliceStage.transcribed,
          clearError: true,
        );
        await store.save(file);
        final sliceDurMs = (sub.endMs - sub.startMs).clamp(
          0,
          file.durationMs > 0 ? file.durationMs : 600000,
        );
        newlyTranscribedMs += sliceDurMs > 0
            ? sliceDurMs
            : (total == 1 ? file.durationMs : 0);
      }
      if (newlyTranscribedMs > 0) {
        onLocalTranscribed?.call(newlyTranscribedMs);
      }
      if (usedAcousticFallback && file.utterances.isEmpty) {
        file.slices = [];
        await store.save(file);
      }
    }

    if (file.utterances.isNotEmpty) {
      report(PipelineStage.labeling, '正在推测说话人');
      if (_speakerLabel && paths.canLabelSpeakers) {
        await _labelSpeakers(
          file,
          paths.speakerEmbeddingPath!,
          conditionedFull: conditionedFull,
          fullSampleRate: wav.sampleRate,
        );
      } else {
        file.utterances = [
          for (final u in file.utterances) u.copyWith(speakerLabel: '未区分'),
        ];
      }
      await store.save(file);
    }

    // 本阶段不做云端文本润色：直接用本地原始转写构建切片记录进入 Timeline
    file
      ..segments = [_buildLocalSliceSegment(file, slice)]
      ..stage = RecordingStage.ready
      ..error = null;
    await store.save(file);
    report(PipelineStage.done, '第 ${slice.sliceIndex + 1} 片已转写保存');
    return file;
  }

  Future<AsrResult> _transcribeSliceAudio(
    Float32List conditionedSamples, {
    required int sampleRate,
    String? directWavPath,
  }) {
    final activeEngine = engine;
    if (activeEngine is RoutingSpeechEngine && directWavPath != null) {
      return activeEngine.transcribe(
        conditionedSamples,
        sampleRate: sampleRate,
        wavPath: directWavPath,
      );
    }
    return activeEngine.transcribe(conditionedSamples, sampleRate: sampleRate);
  }

  static Float32List _sliceConditionedView(
    Float32List conditionedFull,
    AudioSlice sub,
    int sampleRate,
  ) {
    final s = (sub.startMs * sampleRate ~/ 1000).clamp(
      0,
      conditionedFull.length,
    );
    final e = (sub.endMs * sampleRate ~/ 1000).clamp(s, conditionedFull.length);
    if (e > s) {
      return Float32List.sublistView(conditionedFull, s, e);
    }
    if (sub.wavPath.isNotEmpty && File(sub.wavPath).existsSync()) {
      return readWavFile(sub.wavPath).toSpeechFloat32();
    }
    return Float32List(0);
  }

  static String? _resolveSliceMark(RecordingFile file, LiveAudioSlice slice) {
    final parts = <String>[];
    if (slice.marksMs.isNotEmpty) {
      final timeLabels = <String>[];
      for (final m in slice.marksMs) {
        final absMs = m >= 1000000000000
            ? m
            : (file.startAtMs + m.clamp(0, 86400000));
        if (absMs > 0) {
          final dt = DateTime.fromMillisecondsSinceEpoch(absMs);
          final hh = dt.hour.toString().padLeft(2, '0');
          final mm = dt.minute.toString().padLeft(2, '0');
          final label = '$hh:$mm';
          if (!timeLabels.contains(label)) timeLabels.add(label);
        }
      }
      if (timeLabels.isEmpty) {
        parts.add('重点打点');
      } else if (slice.marksMs.length > 1) {
        parts.add('重点打点 ${slice.marksMs.length} 处 · ${timeLabels.join(' / ')}');
      } else {
        parts.add('重点打点 · ${timeLabels.single}');
      }
    }
    if (slice.gapCount > 0) {
      parts.add('流中断 ${slice.gapCount} 次');
    }
    if (parts.isNotEmpty) {
      return parts.join(' · ');
    }
    final existingMark = file.segments.isNotEmpty
        ? (file.segments.first.mark ?? '').trim()
        : '';
    return existingMark.isNotEmpty ? existingMark : null;
  }

  SegmentRecord _buildLocalSliceSegment(
    RecordingFile file,
    LiveAudioSlice slice,
  ) {
    final resolvedMark = _resolveSliceMark(file, slice);
    final utterances = [
      for (final u in file.utterances)
        if (isMeaningfulSpeechText(u.text)) u,
    ]..sort((a, b) => a.startMs.compareTo(b.startMs));
    final startAtMs = file.startAtMs;
    final endAtMs = file.startAtMs +
        (file.durationMs > 0
            ? file.durationMs
            : (utterances.isNotEmpty ? utterances.last.endMs : 1000));
    final speakers = <String>{
      for (final u in utterances)
        if ((u.speakerLabel ?? '').trim().isNotEmpty &&
            u.speakerLabel != '未区分')
          u.speakerLabel!,
    };
    final sliceIds = [for (final s in file.slices) s.id];

    if (utterances.isEmpty) {
      return SegmentRecord(
        id: 'seg-${file.id}-0',
        sessionId: file.session,
        index: slice.sliceIndex,
        startAtMs: startAtMs,
        endAtMs: endAtMs,
        title: '未识别到语音',
        brief: '本段未检测到有效人声，原始录音已保存在本机。',
        longText: '本段未检测到有效人声，原始录音已保存在本机，可在详情「原始数据」回听。',
        status: SegmentStatus.closed,
        sliceIds: sliceIds,
        mark: resolvedMark,
      );
    }

    final cleanTexts = <String>[];
    for (final u in utterances) {
      final clean = cleanSpokenFillers(u.text);
      if (clean.isNotEmpty && isMeaningfulSpeechText(clean)) {
        cleanTexts.add(clean);
      }
    }
    if (cleanTexts.isEmpty) {
      return SegmentRecord(
        id: 'seg-${file.id}-0',
        sessionId: file.session,
        index: slice.sliceIndex,
        startAtMs: startAtMs,
        endAtMs: endAtMs,
        title: '未识别到语音',
        brief: '本段未检测到有效人声，原始录音已保存在本机。',
        longText: '本段未检测到有效人声，原始录音已保存在本机，可在详情「原始数据」回听。',
        status: SegmentStatus.closed,
        sliceIds: sliceIds,
        mark: resolvedMark,
      );
    }

    var mergedParagraph = '';
    for (final line in cleanTexts) {
      mergedParagraph = mergedParagraph.isEmpty
          ? line
          : joinPolishedUtterances(mergedParagraph, line);
    }
    final longText = mergedParagraph.length <= 120
        ? mergedParagraph
        : '${mergedParagraph.substring(0, 120)}…';
    final title = buildReadableFallbackTitle(
      mergedParagraph,
      fallback: '语音片段',
    );
    final brief = mergedParagraph.length <= 68
        ? mergedParagraph
        : '${mergedParagraph.substring(0, 68)}…';

    return SegmentRecord(
      id: 'seg-${file.id}-0',
      sessionId: file.session,
      index: slice.sliceIndex,
      startAtMs: startAtMs,
      endAtMs: endAtMs,
      title: title,
      brief: brief,
      longText: longText,
      speakerLabels: speakers.toList()..sort(),
      speakerCount: speakers.length,
      status: SegmentStatus.closed,
      sliceIds: sliceIds,
      mark: resolvedMark,
    );
  }

  /// 对本地已有 WAV 但此前因直流偏置被误判为「未识别到人声」的 `LIVE_*` 切片做一次性本地重检。
  ///
  /// 纯本机磁盘 + 本地模型推理，不访问蓝牙设备；每条记录通过目录内 `.dc_rechecked_v1` 标记确保最多重检一次。
  Future<int> reprocessSilentLiveSlices({
    void Function(PipelineProgress progress)? onProgress,
  }) async {
    var recovered = 0;
    final initial = await store.loadAll(refresh: true);
    // 先清理同 wavPath 下已被完整转写兄弟条目替代的残留半成品副本
    final readyWavs = <String>{
      for (final f in initial)
        if (f.deviceName.startsWith('LIVE_') &&
            f.stage == RecordingStage.ready &&
            f.utterances.isNotEmpty &&
            f.wavPath != null &&
            f.wavPath!.isNotEmpty)
          f.wavPath!,
    };
    for (final f in initial) {
      if (f.deviceName.startsWith('LIVE_') &&
          f.utterances.isEmpty &&
          f.wavPath != null &&
          readyWavs.contains(f.wavPath)) {
        await store.remove(f.deviceName);
        recovered++;
      }
    }

    final all = await store.loadAll(refresh: true);
    final candidates = all.where((f) {
      if (!f.deviceName.startsWith('LIVE_')) return false;
      if (f.utterances.isNotEmpty) return false;
      final wp = f.wavPath;
      return wp != null && wp.isNotEmpty && File(wp).existsSync();
    }).toList()
      ..sort((a, b) => a.startAtMs.compareTo(b.startAtMs));

    for (final f in candidates) {
      final dir = await store.dirFor(f.deviceName);
      final marker = File('${dir.path}/.dc_rechecked_v1');
      if (await marker.exists()) continue;
      if (!await dir.exists()) await dir.create(recursive: true);
      await marker.writeAsString('1', flush: true);

      // 清空旧空壳分段，重新走带去直流与增益归一化的本地推理
      f
        ..slices = []
        ..utterances = []
        ..segments = []
        ..stage = RecordingStage.transcribing
        ..error = null;
      await store.save(f);
      final updated = await ingestLiveSlice(
        LiveAudioSlice(
          sessionId: f.session,
          deviceSessionId: f.session,
          sliceIndex: (f.seq - 1).clamp(0, 999999),
          startAtMs: f.startAtMs,
          durationMs: f.durationMs,
          wavPath: f.wavPath!,
          sliceKeyOverride: f.deviceName,
        ),
        onProgress: onProgress,
      );
      if (updated.utterances.isNotEmpty) {
        recovered++;
      }
    }
    return recovered;
  }

  /// 从设备同步新录音并处理。已完成的文件跳过；已被实时流无断档覆盖的文件跳过；失败文件重试。
  ///
  /// [maxFiles] / [smallestFirst] 用于真机验证：只取最小的一个文件，避免
  /// 把整卡录音都拉下来（BLE 很慢）。生产不传 = 处理全部新文件。
  Future<PipelineSyncResult> sync({
    void Function(PipelineProgress progress)? onProgress,
    Future<void> Function(RecordingFile file)? onFileReady,
    int? maxFiles,
    bool smallestFirst = false,
    int minFileSize = 0,
  }) async {
    if (_busy) {
      throw const PipelineException('同步已在进行中');
    }
    _syncYieldRequested = false;
    _enterBusy();
    try {
      onProgress?.call(
        const PipelineProgress(
          stage: PipelineStage.listing,
          fileIndex: 0,
          fileTotal: 0,
          text: '正在读取录音卡文件列表…',
        ),
      );
      await _ensureSdCardOnMcu();
      final files = await gateway.files();
      await store.pruneMissingGhosts({for (final f in files) f.name});
      var apms = files
          .where((f) => f.isAudioRecording && f.size >= minFileSize)
          .toList();
      if (smallestFirst) {
        apms.sort((a, b) => a.size.compareTo(b.size));
      } else {
        apms = orderCardFilesForSync(apms);
      }
      if (maxFiles != null && apms.length > maxFiles) {
        apms = apms.take(maxFiles).toList();
      }

      if (apms.isEmpty) {
        return const PipelineSyncResult(
          downloaded: 0,
          ready: 0,
          skipped: 0,
          failed: 0,
          failures: [],
        );
      }

      final liveSessions = await LiveAudioRecorder.listSessions(
        baseDir: liveAudioBaseDir,
      );
      final localFiles = await store.loadAll(refresh: true);

      var downloaded = 0;
      var ready = 0;
      var skipped = 0;
      var failed = 0;
      var pausedForLiveRecording = false;
      var ringAdvancementBlocked = false;
      final failures = <String>[];

      for (var i = 0; i < apms.length; i++) {
        if (_syncYieldRequested) {
          pausedForLiveRecording = true;
          break;
        }
        final source = apms[i];
        final isRingChunk = _omiRingStartSeq(source) != null;
        final existing = await store.load(source.name);
        if (existing != null && existing.stage == RecordingStage.ready) {
          skipped++;
          continue;
        }
        if (_isCoveredByLiveSlices(source, liveSessions, localFiles)) {
          skipped++;
          continue;
        }
        final file = existing ?? _newFile(source);
        await _reconcileStoredSessionForFile(file);
        try {
          final didDownload = await _processFile(
            file,
            source: source,
            fileIndex: i,
            fileTotal: apms.length,
            onProgress: onProgress,
            allowRingDelete: !ringAdvancementBlocked,
            onPartReady: onFileReady,
          );
          if (didDownload) downloaded++;
          if (file.stage == RecordingStage.ready) ready++;
          if (isRingChunk && !didDownload && file.stage == RecordingStage.queued) {
            ringAdvancementBlocked = true;
          }
        } on Object catch (e) {
          if (isRingChunk) {
            ringAdvancementBlocked = true;
          }
          failed++;
          failures.add('${source.name}: $e');
          file
            ..stage = RecordingStage.failed
            ..error = '$e';
          await store.save(file);
        }
      }

      return PipelineSyncResult(
        downloaded: downloaded,
        ready: ready,
        skipped: skipped,
        failed: failed,
        failures: failures,
        pausedForLiveRecording: pausedForLiveRecording,
      );
    } finally {
      _syncYieldRequested = false;
      _exitBusy();
    }
  }

  /// 继续处理本地未完成的录音（启动/切前台时调用）。
  Future<PipelineSyncResult> processPending({
    void Function(PipelineProgress progress)? onProgress,
  }) async {
    if (_busy) {
      throw const PipelineException('处理已在进行中');
    }
    _enterBusy();
    try {
      var all = await store.loadAll(refresh: true);
      var pending = all
          .where((f) => f.stage != RecordingStage.ready)
          .toList()
        ..sort((a, b) => b.startAtMs.compareTo(a.startAtMs));

      // 续跑必须知道设备上还剩哪些文件：否则「本地没有 .apm」会被当成新下载，
      // 而设备上早已被取走（固件取完即删），于是每轮重试都卡在同一处、永远走不完。
      // 只有真存在「缺本地音频」的条目时才去读设备文件清单，避免纯本地切片续跑误触蓝牙。
      final Map<String, CardFile> deviceFiles = {};
      var listingFailed = false;
      final needsDeviceCheck = pending.any((f) {
        final hasApm = f.apmPath.isNotEmpty && File(f.apmPath).existsSync();
        final hasWav =
            f.wavPath != null && f.wavPath!.isNotEmpty && File(f.wavPath!).existsSync();
        return !hasApm && !hasWav;
      });
      if (needsDeviceCheck) {
        try {
          await _ensureSdCardOnMcu();
          final files = await gateway.files();
          for (final f in files) {
            deviceFiles[f.name] = f;
          }
          await store.pruneMissingGhosts(deviceFiles.keys.toSet());
          all = await store.loadAll(refresh: true);
          pending = all
              .where((f) => f.stage != RecordingStage.ready)
              .toList()
            ..sort((a, b) => b.startAtMs.compareTo(a.startAtMs));
        } on Object catch (e) {
          listingFailed = true;
          debugPrint('[pipeline] 续跑读取文件列表失败：$e');
        }
      }

      var ready = 0;
      var failed = 0;
      final failures = <String>[];
      for (var i = 0; i < pending.length; i++) {
        final file = pending[i];
        final hasApm =
            file.apmPath.isNotEmpty && await File(file.apmPath).exists();
        final hasWav = file.wavPath != null &&
            file.wavPath!.isNotEmpty &&
            await File(file.wavPath!).exists();
        final lacksAudio = !hasApm && !hasWav;
        if (lacksAudio && (listingFailed || !deviceFiles.containsKey(file.deviceName))) {
          failed++;
          failures.add('${file.deviceName}: 录音文件不在本机、设备上也不存在');
          file
            ..stage = RecordingStage.failed
            ..error = listingFailed
                ? '未连接到录音卡，无法核对缺失的录音，连上后可重试'
                : '设备上已不存在该录音，无法补取';
          await store.save(file);
          continue;
        }
        if (file.deviceName.startsWith('LIVE_') && hasWav) {
          try {
            await _ingestLiveSliceUnlocked(
              LiveAudioSlice(
                sessionId: file.session,
                deviceSessionId: file.session,
                sliceIndex: (file.seq - 1).clamp(0, 999999),
                startAtMs: file.startAtMs,
                durationMs: file.durationMs,
                wavPath: file.wavPath!,
                sliceKeyOverride: file.deviceName,
              ),
              onProgress: onProgress,
            );
            final refreshed = await store.load(file.deviceName);
            if (refreshed?.stage == RecordingStage.ready) ready++;
          } on Object catch (e) {
            failed++;
            failures.add('${file.deviceName}: $e');
            file
              ..stage = RecordingStage.failed
              ..error = '$e';
            await store.save(file);
          }
          continue;
        }
        try {
          await _processFile(
            file,
            source: deviceFiles[file.deviceName],
            fileIndex: i,
            fileTotal: pending.length,
            onProgress: onProgress,
          );
          if (file.stage == RecordingStage.ready) ready++;
        } on Object catch (e) {
          failed++;
          failures.add('${file.deviceName}: $e');
          file
            ..stage = RecordingStage.failed
            ..error = '$e';
          await store.save(file);
        }
      }
      return PipelineSyncResult(
        downloaded: 0,
        ready: ready,
        skipped: 0,
        failed: failed,
        failures: failures,
      );
    } finally {
      _exitBusy();
    }
  }

  /// 仅处理本机已有音频文件但尚未完成转写的待办条目（不访问蓝牙 `gateway.files()`）。
  ///
  /// 供未连接录音卡时的 Timeline 下拉刷新使用：离线/未连卡时也能把本机排队中的
  /// `LIVE_*` 或已下载 `.APM`/`.WAV` 送进本地 VAD + SenseVoice 完成转写。
  Future<PipelineSyncResult> transcribeLocalPendingOnly({
    void Function(PipelineProgress progress)? onProgress,
  }) {
    final completer = Completer<PipelineSyncResult>();
    _liveSerial = _liveSerial.then((_) async {
      await _waitUntilIdle();
      _enterBusy();
      try {
        final all = await store.loadAll(refresh: true);
        final pending = <RecordingFile>[];
        for (final f in all) {
          if (f.stage == RecordingStage.ready) continue;
          final hasApm =
              f.apmPath.isNotEmpty && await File(f.apmPath).exists();
          final hasWav =
              f.wavPath != null &&
              f.wavPath!.isNotEmpty &&
              await File(f.wavPath!).exists();
          if (hasApm || hasWav) {
            pending.add(f);
          }
        }
        pending.sort((a, b) => a.startAtMs.compareTo(b.startAtMs));

        var ready = 0;
        var failed = 0;
        final failures = <String>[];
        for (var i = 0; i < pending.length; i++) {
          final file = pending[i];
          final hasWav =
              file.wavPath != null &&
              file.wavPath!.isNotEmpty &&
              await File(file.wavPath!).exists();
          if (file.deviceName.startsWith('LIVE_') && hasWav) {
            try {
              final updated = await _ingestLiveSliceUnlocked(
                LiveAudioSlice(
                  sessionId: file.session,
                  deviceSessionId: file.session,
                  sliceIndex: (file.seq - 1).clamp(0, 999999),
                  startAtMs: file.startAtMs,
                  durationMs: file.durationMs,
                  wavPath: file.wavPath!,
                  sliceKeyOverride: file.deviceName,
                ),
                onProgress: onProgress,
              );
              if (updated.stage == RecordingStage.ready) {
                ready++;
              } else {
                failed++;
                final err = updated.error?.trim();
                failures.add(
                  '${file.deviceName}: ${err != null && err.isNotEmpty ? err : '本地转写未完成'}',
                );
              }
            } on Object catch (e) {
              failed++;
              failures.add('${file.deviceName}: $e');
              file
                ..stage = RecordingStage.failed
                ..error = '$e';
              await store.save(file);
            }
            continue;
          }
          try {
            await _processFile(
              file,
              source: null,
              fileIndex: i,
              fileTotal: pending.length,
              onProgress: onProgress,
            );
            if (file.stage == RecordingStage.ready) {
              ready++;
            } else {
              failed++;
              final err = file.error?.trim();
              failures.add(
                '${file.deviceName}: ${err != null && err.isNotEmpty ? err : '本地转写未完成'}',
              );
            }
          } on Object catch (e) {
            failed++;
            failures.add('${file.deviceName}: $e');
            file
              ..stage = RecordingStage.failed
              ..error = '$e';
            await store.save(file);
          }
        }
        completer.complete(
          PipelineSyncResult(
            downloaded: 0,
            ready: ready,
            skipped: 0,
            failed: failed,
            failures: failures,
          ),
        );
      } on Object catch (e, st) {
        completer.completeError(e, st);
      } finally {
        _exitBusy();
      }
    });
    return completer.future;
  }

  /// 处理一条文件；返回是否真的执行了下载（用于统计）。
  Future<bool> _processFile(
    RecordingFile file, {
    CardFile? source,
    required int fileIndex,
    required int fileTotal,
    void Function(PipelineProgress progress)? onProgress,
    bool allowRingDelete = true,
    Future<void> Function(RecordingFile file)? onPartReady,
  }) async {
    void report(
      PipelineStage stage, {
      int? sliceIndex,
      int? sliceTotal,
      String text = '',
    }) {
      onProgress?.call(
        PipelineProgress(
          stage: stage,
          fileIndex: fileIndex,
          fileTotal: fileTotal,
          fileName: file.deviceName,
          sliceIndex: sliceIndex,
          sliceTotal: sliceTotal,
          text: text,
        ),
      );
    }

    var didDownload = false;
    var hasAuthoritativeStartAt = (source?.startAtSec != null) || file.timeSynced;
    final extraChildFiles = <RecordingFile>[];
    final dir = await store.dirFor(file.deviceName);
    if (!await dir.exists()) await dir.create(recursive: true);

    // 1) 取回 .apm（本地已有 .apm 或已有转好的 .wav 则跳过）
    final alreadyHasWav = file.wavPath != null &&
        file.wavPath!.isNotEmpty &&
        await File(file.wavPath!).exists();
    if (!alreadyHasWav &&
        (file.apmPath.isEmpty || !await File(file.apmPath).exists())) {
      // 「仅使用 Wi-Fi 同步」：取录音是整条链路里最贵的一步（BLE 3~8 KB/s），
      // 在真正下载前拦一次，避免用户以为设了却仍走蜂窝流量。
      final decision = await network.check(wifiOnly: _wifiOnly);
      if (!decision.allowed) {
        // 不是失败而是「暂不处理」：保留 queued 让下次联网后自动继续
        report(
          PipelineStage.listing,
          text: decision.reason ?? '当前网络不允许同步',
        );
        file
          ..stage = RecordingStage.queued
          ..error = decision.reason;
        await store.save(file);
        return false;
      }
      report(
        PipelineStage.downloading,
        text: '正在取回（${fileIndex + 1}/$fileTotal）',
      );
      file
        ..stage = RecordingStage.downloading
        ..error = null;
      await store.save(file);
      final download = await gateway.download(file.deviceName, dir.path);
      final firstPart = download.parts.isNotEmpty ? download.parts.first : null;
      final effectivePath = (firstPart != null && firstPart.path.isNotEmpty)
          ? firstPart.path
          : (download.path.isEmpty
                ? '${dir.path}/${file.deviceName}'
                : download.path);
      file.apmPath = effectivePath;
      if (download.session != null && download.session!.isNotEmpty) {
        file.session = download.session!;
      }
      if (download.seq != null && download.seq! > 0) {
        file.seq = download.seq!;
      }
      final resolvedStartAtSec = download.startAtSec ?? firstPart?.startAtSec;
      final resolvedTimeSynced = download.timeSynced ?? firstPart?.timeSynced;
      if (resolvedStartAtSec != null) {
        file.startAtMs = resolvedStartAtSec * 1000;
        file.timeSynced = resolvedTimeSynced ?? true;
        hasAuthoritativeStartAt = true;
      } else if (resolvedTimeSynced == false) {
        file.timeSynced = false;
      }
      if (download.parts.length > 1) {
        for (var k = 1; k < download.parts.length; k++) {
          final part = download.parts[k];
          if (part.path.isEmpty) continue;
          final partName = '${file.deviceName}#p$k';
          final existingChild = await store.load(partName);
          if (existingChild != null &&
              existingChild.stage == RecordingStage.ready) {
            continue;
          }
          final child =
              existingChild ??
              RecordingFile(
                deviceName: partName,
                session: file.session,
                seq: file.seq + k,
                startAtMs: part.startAtSec != null
                    ? part.startAtSec! * 1000
                    : file.startAtMs,
                timeSynced: part.timeSynced ?? (part.startAtSec != null),
                apmPath: part.path,
                createdAtMs: DateTime.now().millisecondsSinceEpoch,
                stage: RecordingStage.downloading,
                sourceLane: file.sourceLane,
                sourceDeviceLabel: file.sourceDeviceLabel,
              );
          child.apmPath = part.path;
          if (part.startAtSec != null) {
            child.startAtMs = part.startAtSec! * 1000;
            child.timeSynced = part.timeSynced ?? true;
          }
          await store.save(child);
          extraChildFiles.add(child);
        }
      }
      didDownload = true;
      await store.save(file);
      if (allowRingDelete &&
          source != null &&
          _omiRingStartSeq(source) != null) {
        try {
          await gateway.deleteFile(source.name);
        } on Object catch (e) {
          debugPrint('[pipeline] 推进 Omi 环形缓存失败：${source.name}: $e');
        }
      }
    }

    await _processLocalFileStages(
      file,
      source: source,
      hasAuthoritativeStartAt: hasAuthoritativeStartAt,
      fileIndex: fileIndex,
      fileTotal: fileTotal,
      onProgress: onProgress,
    );
    if (onPartReady != null &&
        (didDownload || file.stage == RecordingStage.ready)) {
      await onPartReady(file);
    }
    for (final child in extraChildFiles) {
      await _processLocalFileStages(
        child,
        source: null,
        hasAuthoritativeStartAt: child.timeSynced,
        fileIndex: fileIndex,
        fileTotal: fileTotal,
        onProgress: onProgress,
      );
      if (onPartReady != null && child.stage == RecordingStage.ready) {
        await onPartReady(child);
      }
    }
    return didDownload;
  }

  Future<void> _processLocalFileStages(
    RecordingFile file, {
    CardFile? source,
    required bool hasAuthoritativeStartAt,
    required int fileIndex,
    required int fileTotal,
    void Function(PipelineProgress progress)? onProgress,
  }) async {
    void report(
      PipelineStage stage, {
      int? sliceIndex,
      int? sliceTotal,
      String text = '',
    }) {
      onProgress?.call(
        PipelineProgress(
          stage: stage,
          fileIndex: fileIndex,
          fileTotal: fileTotal,
          fileName: file.deviceName,
          sliceIndex: sliceIndex,
          sliceTotal: sliceTotal,
          text: text,
        ),
      );
    }

    final dir = await store.dirFor(file.deviceName);
    if (!await dir.exists()) await dir.create(recursive: true);

    // 2) 转码（16k/16bit/mono）
    final wavPath = file.wavPath ?? '${file.apmPath}.wav';
    if (!await File(wavPath).exists()) {
      report(
        PipelineStage.transcoding,
        text: '正在转换（${fileIndex + 1}/$fileTotal）',
      );
      file
        ..stage = RecordingStage.transcoding
        ..error = null
        ..wavPath = wavPath;
      await store.save(file);
      final audio = await gateway.transcode(
        file.apmPath,
        wavPath,
        sourceSampleRateHz: apmSourceSampleRateResolver?.call(file),
      );
      file.durationMs = (audio.durationSecs * 1000).round();
      // start_at 缺失时，created_at 是结束时间，反推起点；绝不覆盖 download 带回的权威起点
      if (!hasAuthoritativeStartAt &&
          source != null &&
          source.startAtSec == null) {
        final endSec = source.createdAtSec;
        file.startAtMs = endSec != null
            ? endSec * 1000 - file.durationMs
            : DateTime.now().millisecondsSinceEpoch - file.durationMs;
        file.timeSynced = false;
      }
      await store.save(file);
      await _reconcileStoredSessionForFile(file);
    }

    // 3) 模型未就绪：音频已入库，停在转码完成，等下次重试
    SpeechModelPaths? paths;
    try {
      paths = await models.resolve();
    } on Object catch (e) {
      file
        ..stage = RecordingStage.transcoding
        ..error = '本地模型未就绪：$e';
      await store.save(file);
      return;
    }
    if (paths == null || !paths.canTranscribe) {
      file
        ..stage = RecordingStage.transcoding
        ..error = '本地转写模型未就绪';
      await store.save(file);
      return;
    }

    final wav = readWavFile(wavPath);
    if (wav.frames == 0) {
      file
        ..stage = RecordingStage.ready
        ..error = null;
      await store.save(file);
      return;
    }

    Float32List? rawSamples;
    Float32List? conditionedFull;
    bool? needsConditioning;
    Float32List ensureRaw() => rawSamples ??= wav.toFloat32();
    Float32List ensureConditioned() =>
        conditionedFull ??= conditionSpeechSamples(
          ensureRaw(),
          sampleRate: wav.sampleRate,
        );
    bool canReuseSliceWavDirectly() =>
        !(needsConditioning ??= needsSignalConditioning(
          ensureRaw(),
          sampleRate: wav.sampleRate,
        ));
    final sliceSamplesById = <String, Float32List>{};
    var usedAcousticFallback = false;

    // 4) VAD 切片（含 30s 声学能量兜底，对齐 ingestLiveSlice）
    if (file.slices.isEmpty) {
      report(
        PipelineStage.slicing,
        text: '正在切分（${fileIndex + 1}/$fileTotal）',
      );
      await engine.loadVad(paths.vadPath);
      final conditioned = ensureConditioned();
      final spans = await engine.detectSpeech(conditioned);
      var planned = slicePlanner.plan(
        speech: spans,
        totalSamples: wav.frames,
        sampleRate: wav.sampleRate,
      );
      if (planned.isEmpty &&
          hasAcousticSpeechCandidate(ensureRaw(), sampleRate: wav.sampleRate)) {
        usedAcousticFallback = true;
        final chunkSamples = wav.sampleRate * 30;
        final fallback = <PlannedSlice>[];
        var idx = 0;
        for (var s = 0; s < wav.frames; s += chunkSamples) {
          final e = (s + chunkSamples < wav.frames)
              ? s + chunkSamples
              : wav.frames;
          if (e > s) {
            fallback.add(
              PlannedSlice(
                index: idx++,
                startSample: s,
                endSample: e,
                silenceAfterSamples: e < wav.frames ? 0 : (wav.frames - e),
              ),
            );
          }
        }
        planned = fallback;
      }
      final sliceDir = Directory('${dir.path}/slices');
      if (!await sliceDir.exists()) await sliceDir.create(recursive: true);
      final slices = <AudioSlice>[];
      for (final plan in planned) {
        final id = plan.index.toString().padLeft(4, '0');
        final path = '${sliceDir.path}/$id.wav';
        await File(path).writeAsBytes(
          wav.sliceWav(plan.startSample, plan.endSample),
          flush: true,
        );
        final cs = plan.startSample.clamp(0, conditioned.length);
        final ce = plan.endSample.clamp(cs, conditioned.length);
        sliceSamplesById[id] = Float32List.sublistView(conditioned, cs, ce);
        slices.add(
          AudioSlice(
            id: id,
            index: plan.index,
            startMs: plan.startMs(wav.sampleRate),
            endMs: plan.endMs(wav.sampleRate),
            wavPath: path,
            silenceAfterMs: plan.silenceAfterMs(wav.sampleRate),
          ),
        );
      }
      file
        ..slices = slices
        ..stage = RecordingStage.transcribing;
      await store.save(file);
      if (slices.isEmpty) {
        file
          ..stage = RecordingStage.ready
          ..error = null;
        await store.save(file);
        return;
      }
    }

    // 4.5) 自动转录关闭：音频/切片照常落盘，但不跑 ASR；
    // 阶段停在 transcribing，用户重新打开开关后 processPending 会续跑。
    if (!_autoTranscribe) {
      file
        ..stage = RecordingStage.transcribing
        ..error = '自动转录已关闭，未执行本地转写';
      await store.save(file);
      report(
        PipelineStage.transcribing,
        text: '已取回（${fileIndex + 1}/$fileTotal）；自动转录已关闭',
      );
      return;
    }

    if (localQuotaAllowTranscribe != null && !localQuotaAllowTranscribe!()) {
      file
        ..stage = RecordingStage.transcribing
        ..error = quotaExhaustedMessage;
      await store.save(file);
      report(
        PipelineStage.transcribing,
        text: '本月免费转写额度已满，录音已安全保存在本机队列',
      );
      return;
    }

    // 5) 逐片本地转写（单次信号预处理复用，每片完成立即落盘）
    await engine.load(
      modelPath: paths.asrModelPath,
      tokensPath: paths.tokensPath,
      language: language,
    );
    final conditioned = ensureConditioned();
    final total = file.slices.length;
    var newlyTranscribedMs = 0;
    for (var i = 0; i < total; i++) {
      final slice = file.slices[i];
      if (slice.stage == SliceStage.transcribed ||
          slice.stage == SliceStage.polished) {
        continue;
      }
      report(
        PipelineStage.transcribing,
        sliceIndex: i,
        sliceTotal: total,
        text: '正在转写（${i + 1}/$total）',
      );
      try {
        final sliceSamples =
            sliceSamplesById[slice.id] ??
            _sliceConditionedView(conditioned, slice, wav.sampleRate);
        final result = await _transcribeSliceAudio(
          sliceSamples,
          sampleRate: wav.sampleRate,
          directWavPath: canReuseSliceWavDirectly() ? slice.wavPath : null,
        );
        final utterances = buildUtterancesFromAsr(
          sliceId: slice.id,
          sliceStartMs: slice.startMs,
          sliceEndMs: slice.endMs,
          text: result.text,
          tokens: result.tokens,
          tokenTimestampsMs: result.timestampsMs,
          lang: result.lang,
          emotion: result.emotion,
        );
        file.utterances = [
          ...file.utterances.where((u) => u.sliceId != slice.id),
          ...utterances,
        ]..sort((a, b) => a.startMs.compareTo(b.startMs));
        file.slices[i] = slice.copyWith(
          stage: SliceStage.transcribed,
          clearError: true,
        );
        await store.save(file);
        final sliceDurMs = (slice.endMs - slice.startMs).clamp(
          0,
          file.durationMs > 0 ? file.durationMs : 600000,
        );
        newlyTranscribedMs += sliceDurMs > 0
            ? sliceDurMs
            : (total == 1 ? file.durationMs : 0);
      } on Object catch (e) {
        file.slices[i] = slice.copyWith(
          stage: SliceStage.failed,
          error: '$e',
        );
        await store.save(file);
        throw PipelineException('切片 ${slice.id} 转写失败：$e');
      }
    }
    if (newlyTranscribedMs > 0) {
      onLocalTranscribed?.call(newlyTranscribedMs);
    }
    if (usedAcousticFallback && file.utterances.isEmpty) {
      file.slices = [];
      await store.save(file);
      file
        ..stage = RecordingStage.ready
        ..error = null;
      await store.save(file);
      return;
    }

    // 6) 声纹聚类（关闭开关或模型缺失则统一「未区分」）
    if (file.utterances.isNotEmpty) {
      report(PipelineStage.labeling, text: '正在整理说话人');
      if (_speakerLabel && paths.canLabelSpeakers) {
        await _labelSpeakers(
          file,
          paths.speakerEmbeddingPath!,
          conditionedFull: conditionedFull,
          fullSampleRate: wav.sampleRate,
        );
      } else {
        file.utterances = [
          for (final u in file.utterances)
            u.copyWith(speakerLabel: '未区分'),
        ];
      }
      await store.save(file);
    }

    // 当已挂载新一代滚动清洗引擎（rollingCleaner）时，跳过旧版逐文件云端窗口润色与云端分段总结，
    // 直接落地干净的本地确定性分段，消除同一段录音被云端大模型重复处理 3 次！
    final deferCloudToRolling =
        skipLegacyCloudPolishWhenRollingActive && rollingCleaner != null;
    if (deferCloudToRolling) {
      if (file.segments.isEmpty) {
        file.segments = _buildDeterministicFileSegments(file);
      }
      file
        ..stage = RecordingStage.ready
        ..error = null;
      await store.save(file);
      report(PipelineStage.done, text: '处理完成（${fileIndex + 1}/$fileTotal）');
      return;
    }

    // 7) 云端窗口润色：失败不推翻本地数据，只标 stale 供界面提示
    final polisher = polish;
    if (_cleanSpeech &&
        polisher != null &&
        polisher.configured &&
        file.utterances.isNotEmpty) {
      report(PipelineStage.polishing, text: '正在润色整理');
      file
        ..stage = RecordingStage.polishing
        ..error = null;
      await store.save(file);
      try {
        final result = await polisher.polish(
          file,
          save: () => store.save(file),
        );
        file
          ..polishStale = result.stale
          ..polishedThroughSlice = result.polishedThroughSlice;
      } on Object {
        // 本地原文已经完整：润色失败只影响"清洗版"，下次可重试
        file.polishStale = true;
      }
      await store.save(file);
    }

    // 8) 阶段总结/话题分段：云端失败时由协调器用原文兜底，不丢段
    final segmenter = segments;
    if (segmenter != null && file.segments.isEmpty) {
      report(PipelineStage.summarizing, text: '正在整理话题分段');
      file
        ..stage = RecordingStage.summarizing
        ..error = null;
      await store.save(file);
      try {
        final result = await segmenter.build(
          file,
          save: () => store.save(file),
        );
        file.segments = result.segments;
      } on Object catch (e) {
        // 分段失败不推翻本地 turn；保留空 segments，详情页仍可看对话
        file.error = '分段整理失败：$e';
      }
      await store.save(file);
    }

    file
      ..stage = RecordingStage.ready
      ..error = null;
    await store.save(file);
    report(PipelineStage.done, text: '处理完成（${fileIndex + 1}/$fileTotal）');
  }

  List<SegmentRecord> _buildDeterministicFileSegments(RecordingFile file) {
    final meaningful = [
      for (final u in file.utterances)
        if (isMeaningfulSpeechText(u.text)) u,
    ]..sort((a, b) => a.startMs.compareTo(b.startMs));

    if (meaningful.isEmpty) {
      if (file.slices.isEmpty) return const [];
      final endMs = file.startAtMs + (file.durationMs > 0 ? file.durationMs : 1000);
      return [
        SegmentRecord(
          id: 'seg-${file.id}-0',
          sessionId: file.session,
          index: 0,
          startAtMs: file.startAtMs,
          endAtMs: endMs,
          title: '未识别到语音',
          brief: '本段未检测到有效人声，原始录音已保存在本机。',
          longText: '本段未检测到有效人声，原始录音已保存在本机，可在详情「原始数据」回听。',
          status: SegmentStatus.closed,
          sliceIds: [for (final s in file.slices) s.id],
        ),
      ];
    }

    // 若单文件内部出现 >= 60s 长静音，先按声学边界拆成独立分段，便于 RollingClean 按段承接
    final groups = <List<RawUtterance>>[
      [meaningful.first],
    ];
    for (var i = 1; i < meaningful.length; i++) {
      final prev = groups.last.last;
      final curr = meaningful[i];
      if (curr.startMs - prev.endMs >= 60 * 1000) {
        groups.add([curr]);
      } else {
        groups.last.add(curr);
      }
    }

    final out = <SegmentRecord>[];
    for (var gi = 0; gi < groups.length; gi++) {
      final group = groups[gi];
      var mergedText = '';
      for (final u in group) {
        final clean = cleanSpokenFillers(u.text);
        final piece = (clean.isNotEmpty && isMeaningfulSpeechText(clean))
            ? clean
            : u.text.trim();
        if (!isMeaningfulSpeechText(piece)) continue;
        mergedText = mergedText.isEmpty
            ? piece
            : joinPolishedUtterances(mergedText, piece);
      }
      if (!isMeaningfulSpeechText(mergedText)) continue;
      final speakers = <String>{
        for (final u in group)
          if ((u.speakerLabel ?? '').trim().isNotEmpty &&
              u.speakerLabel != '未区分')
            u.speakerLabel!.trim(),
      }.toList()..sort();
      final sliceIds = <String>{
        for (final u in group)
          if (u.sliceId.isNotEmpty) u.sliceId,
      }.toList();
      final segStart = groups.length == 1
          ? file.startAtMs
          : file.startAtMs + group.first.startMs;
      final segEnd = groups.length == 1
          ? file.startAtMs +
                (file.durationMs > 0 ? file.durationMs : group.last.endMs)
          : file.startAtMs + group.last.endMs;
      final brief = mergedText.length <= 68
          ? mergedText
          : '${mergedText.substring(0, 68)}…';
      final longText = mergedText.length <= 120
          ? mergedText
          : '${mergedText.substring(0, 120)}…';
      out.add(
        SegmentRecord(
          id: 'seg-${file.id}-$gi',
          sessionId: file.session,
          index: gi,
          startAtMs: segStart,
          endAtMs: segEnd > segStart ? segEnd : segStart + 1000,
          title: buildReadableFallbackTitle(mergedText, fallback: '语音片段'),
          brief: brief,
          longText: longText,
          speakerLabels: speakers,
          speakerCount: speakers.length,
          status: SegmentStatus.closed,
          sliceIds: sliceIds.isNotEmpty
              ? sliceIds
              : [for (final s in file.slices) s.id],
          fallback: true,
        ),
      );
    }
    return out;
  }

  Future<void> _labelSpeakers(
    RecordingFile file,
    String embeddingPath, {
    Float32List? conditionedFull,
    int fullSampleRate = 16000,
  }) async {
    await engine.loadSpeakerEmbedding(embeddingPath);
    String? lastSliceId;
    WavPcm? lastWav;
    Float32List? lastPcm;
    final samples = <SpeakerSample>[];
    for (final utterance in file.utterances) {
      if (conditionedFull != null && conditionedFull.isNotEmpty) {
        final startFrame = (utterance.startMs * fullSampleRate / 1000).round();
        final endFrame = (utterance.endMs * fullSampleRate / 1000).round();
        final start = startFrame.clamp(0, conditionedFull.length);
        final end = endFrame.clamp(start, conditionedFull.length);
        if (end - start >= fullSampleRate * 6 ~/ 10) {
          final vector = await engine.embedSpeaker(
            Float32List.sublistView(conditionedFull, start, end),
          );
          if (vector.isNotEmpty) {
            samples.add(
              SpeakerSample(
                id: utterance.id,
                embedding: vector,
                durationMs: utterance.durationMs,
              ),
            );
          }
        }
        continue;
      }
      AudioSlice? slice;
      for (final s in file.slices) {
        if (s.id == utterance.sliceId) {
          slice = s;
          break;
        }
      }
      if (slice == null) continue;
      final WavPcm wav;
      Float32List? cachedPcm;
      if (lastSliceId == slice.id && lastWav != null) {
        wav = lastWav;
        cachedPcm = lastPcm;
      } else {
        wav = readWavFile(slice.wavPath);
        lastSliceId = slice.id;
        lastWav = wav;
        lastPcm = null;
        cachedPcm = null;
      }
      final startFrame =
          ((utterance.startMs - slice.startMs) * wav.sampleRate / 1000).round();
      final endFrame =
          ((utterance.endMs - slice.startMs) * wav.sampleRate / 1000).round();
      final start = startFrame.clamp(0, wav.frames);
      final end = endFrame.clamp(start, wav.frames);
      if (end - start < wav.sampleRate * 6 ~/ 10) continue; // <0.6s 不做声纹
      final pcm = cachedPcm ?? (lastPcm = wav.toSpeechFloat32());
      final vector = await engine.embedSpeaker(pcm.sublist(start, end));
      if (vector.isEmpty) continue;
      samples.add(
        SpeakerSample(
          id: utterance.id,
          embedding: vector,
          durationMs: utterance.durationMs,
        ),
      );
    }

    final cluster = clusterer.cluster(
      samples,
      audioDurationMs: file.durationMs > 0 ? file.durationMs : null,
    );
    final byId = {for (final a in cluster.assignments) a.id: a};

    // 会话级编号：一次连续录音会横跨多个设备文件，同一个人的编号要跨文件稳定。
    // 声纹表读写失败时退化为单文件编号（展示仍是「推测」），不影响转写结果。
    var clusterToSpeaker = <int, int>{
      for (final index in cluster.centroids.keys) index: index,
    };
    if (file.session.isNotEmpty && cluster.centroids.isNotEmpty) {
      try {
        final speechMs = <int, int>{};
        for (final u in file.utterances) {
          final assignment = byId[u.id];
          if (assignment == null || !assignment.known) continue;
          speechMs[assignment.cluster] =
              (speechMs[assignment.cluster] ?? 0) + u.durationMs;
        }
        final profileStore = SpeakerProfileStore(root: await store.root());
        final match = SessionSpeakerMatcher(
          maxSpeakers: clusterer.maxSpeakers,
        ).assign(
          existing: await profileStore.load(file.session),
          fileCentroids: cluster.centroids,
          clusterSpeechMs: speechMs,
          deviceName: file.deviceName,
          deviceLabel: file.resolvedSourceDeviceLabel,
        );
        clusterToSpeaker = match.clusterToSpeaker;
        await profileStore.save(match.profiles);
      } on Object {
        // 只保留单文件编号：声纹表不可写不是转写失败
      }
    }

    int sessionIndexOf(int cluster) => clusterToSpeaker[cluster] ?? cluster;

    // 全量声纹库多质心 + 语义上下文联合匹配：高分直接落实名，擦边/跨设备/纯语义记入待确认建议
    final vpStore = voiceprintStore;
    final resolvedLabelByCluster = <int, String>{};
    final sesKey = file.session.isEmpty ? file.id : file.session;
    final sourceDevice = file.resolvedSourceDeviceLabel;
    final sourceLane = file.resolvedSourceLane.code;

    final preliminaryUtterances = [
      for (final u in file.utterances)
        if (byId[u.id] != null && byId[u.id]!.known)
          u.copyWith(
            speakerCluster: sessionIndexOf(byId[u.id]!.cluster),
            speakerLabel: '说话人 ${sessionIndexOf(byId[u.id]!.cluster) + 1}',
            spkConfidence: byId[u.id]!.confidence,
          )
        else
          u.copyWith(speakerLabel: '未区分', spkConfidence: 0),
    ];

    if (vpStore != null && cluster.centroids.isNotEmpty) {
      final slotCentroids = <String, List<double>>{};
      final slotSpeechMs = <String, int>{};
      final clusterToSlot = <int, String>{};

      for (final u in file.utterances) {
        final assignment = byId[u.id];
        if (assignment == null || !assignment.known) continue;
        final slot = '说话人 ${sessionIndexOf(assignment.cluster) + 1}';
        slotSpeechMs[slot] = (slotSpeechMs[slot] ?? 0) + u.durationMs;
      }

      for (final entry in cluster.centroids.entries) {
        final slot = '说话人 ${sessionIndexOf(entry.key) + 1}';
        clusterToSlot[entry.key] = slot;
        slotCentroids[slot] = entry.value;
        vpStore.observeChannelEmbedding(
          entry.value,
          deviceLabel: sourceDevice,
          sourceLane: sourceLane,
        );
      }

      final clues = SemanticSpeakerClueExtractor.extractFromUtterances(
        preliminaryUtterances,
        knownNames: vpStore.preferredRosterNames(limit: 40).toSet(),
      );

      final resolution = JointSpeakerResolver.resolveSession(
        session: sesKey,
        speakerCentroids: slotCentroids,
        speakerSpeechMs: slotSpeechMs,
        semanticClues: clues,
        voiceprintStore: vpStore,
        deviceLabel: sourceDevice,
        sourceLane: sourceLane,
        nowMs: DateTime.now().millisecondsSinceEpoch,
      );

      for (final outcome in resolution.autoConfirmed.values) {
        vpStore.clearSuggestion(
          session: sesKey,
          speakerSlot: outcome.speakerSlot,
          notify: false,
        );
        if (outcome.shouldEnrollChannelCentroid) {
          final centroid = slotCentroids[outcome.speakerSlot];
          if (centroid != null && centroid.isNotEmpty) {
            vpStore.upsertPersonAndSample(
              name: outcome.personName,
              embedding: centroid,
              deviceLabel: outcome.deviceLabel,
              sourceLane: sourceLane,
              sceneLabel: '跨设备自适应',
            );
          }
        }
      }

      for (final sug in resolution.suggestions.values) {
        vpStore.recordCandidateSuggestion(sug, notify: false);
      }

      for (final entry in clusterToSlot.entries) {
        final slot = entry.value;
        resolvedLabelByCluster[entry.key] =
            resolution.autoConfirmed[slot]?.personName ?? slot;
      }
    } else {
      for (final entry in cluster.centroids.entries) {
        resolvedLabelByCluster[entry.key] =
            '说话人 ${sessionIndexOf(entry.key) + 1}';
      }
    }

    file.utterances = [
      for (final u in preliminaryUtterances)
        if (byId[u.id] != null && byId[u.id]!.known)
          u.copyWith(
            speakerLabel:
                resolvedLabelByCluster[byId[u.id]!.cluster] ??
                u.speakerLabel,
          )
        else
          u,
    ];
  }

  RecordingFile _newFile(CardFile source) {
    final nowSec = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final startSec = source.startAtSec;
    final endSec = source.createdAtSec ?? nowSec;
    final bleLabel = bleDeviceLabelResolver?.call()?.trim();
    return RecordingFile(
      deviceName: source.name,
      session: source.session ?? source.name,
      seq: source.seq ?? 1,
      startAtMs: (startSec ?? endSec) * 1000,
      timeSynced: startSec != null && (source.synced ?? true),
      apmPath: '',
      createdAtMs: DateTime.now().millisecondsSinceEpoch,
      stage: RecordingStage.queued,
      sourceLane: RecordingSourceLane.ble.code,
      sourceDeviceLabel: (bleLabel != null && bleLabel.isNotEmpty)
          ? bleLabel
          : '蓝牙设备',
    );
  }

  static final RegExp _omiRingNameRe = RegExp(
    r'^OMI_RING_(\d+)_(\d+)\.WAV$',
    caseSensitive: false,
  );

  static int? _omiRingStartSeq(CardFile file) {
    final m = _omiRingNameRe.firstMatch(file.name);
    if (m == null) return null;
    return int.tryParse(m.group(1)!);
  }

  static int _startSecond(CardFile file) =>
      file.startAtSec ?? file.createdAtSec ?? 0;

  static final RegExp _validHexSessionRe = RegExp(r'^[0-9A-Fa-f]{8}$');

  static bool isValidHexSession(String? session) =>
      session != null && _validHexSessionRe.hasMatch(session.trim());

  /// 排序待同步设备文件：
  /// - Omi Ring Buffer 保持 FIFO 起始偏移升序；
  /// - 同 8 位十六进制 `session` 内按 `seq` 升序（避免 1024s 阈值回绕后倒序拉取）；
  /// - 不同会话/散段仍按时间由新到旧排序，优先呈现最新内容。
  static List<CardFile> orderCardFilesForSync(List<CardFile> input) {
    final ringFiles = <CardFile>[];
    final sessionBuckets = <String, List<CardFile>>{};
    final looseFiles = <CardFile>[];

    for (final f in input) {
      if (_omiRingStartSeq(f) != null) {
        ringFiles.add(f);
      } else if (isValidHexSession(f.session) && f.seq != null) {
        final key = f.session!.trim().toUpperCase();
        sessionBuckets.putIfAbsent(key, () => []).add(f);
      } else {
        looseFiles.add(f);
      }
    }

    ringFiles.sort((a, b) => _omiRingStartSeq(a)!.compareTo(_omiRingStartSeq(b)!));
    final groups = <({int sortSec, List<CardFile> items})>[];
    for (final entry in sessionBuckets.values) {
      entry.sort((a, b) {
        final c = a.seq!.compareTo(b.seq!);
        return c != 0 ? c : a.name.compareTo(b.name);
      });
      var maxSec = 0;
      for (final f in entry) {
        final s = _startSecond(f);
        if (s > maxSec) maxSec = s;
      }
      groups.add((sortSec: maxSec, items: entry));
    }
    for (final f in looseFiles) {
      groups.add((sortSec: _startSecond(f), items: [f]));
    }
    groups.sort((a, b) => b.sortSec.compareTo(a.sortSec));

    return [
      ...ringFiles,
      for (final g in groups) ...g.items,
    ];
  }

  /// 同会话 RTC1 每 1024s 回绕与 `nosync` 顺序失真自愈：
  /// 对共享 8 位十六进制 `session` 的多段录音按 `seq` 升序串联；
  /// 若发现后段 `startAtMs` 倒流或相对 `prevStartMs + prevDurationMs` 偏差 > 90s（或未校时），
  /// 按累计时长顺推并标记 `timeSynced = false`（诚实表达估算来源）。返回被修复的文件列表。
  static List<RecordingFile> reconcileSessionTimestamps(
    List<RecordingFile> files, {
    double defaultApmSampleRateHz = 15578.0,
    int? fallbackAnchorNowMs,
  }) {
    final bySession = <String, List<RecordingFile>>{};
    for (final f in files) {
      if (!isValidHexSession(f.session) || f.seq <= 0) continue;
      final key = f.session.trim().toUpperCase();
      bySession.putIfAbsent(key, () => []).add(f);
    }

    final repaired = <RecordingFile>[];
    for (final group in bySession.values) {
      if (group.length < 2) continue;
      group.sort((a, b) {
        final c = a.seq.compareTo(b.seq);
        return c != 0 ? c : a.deviceName.compareTo(b.deviceName);
      });

      int estimateDurationMs(RecordingFile seg) {
        if (seg.durationMs > 0) return seg.durationMs;
        if (seg.apmPath.isNotEmpty) {
          try {
            final f = File(seg.apmPath);
            if (f.existsSync()) {
              final bytes = f.lengthSync();
              if (bytes > 0) {
                return ((bytes * 2 * 1000) / defaultApmSampleRateHz).round();
              }
            }
          } on Object {
            // 文件不可读时退回分段默认步长估算
          }
        }
        return 600 * 1000;
      }

      // 若首段明显未校时或落盘早于 2020 年，先从合理时间或末段落盘时间倒推锚点
      final anchor = group.first;
      const minPlausibleEpochMs = 1577836800 * 1000;
      if (anchor.startAtMs < minPlausibleEpochMs) {
        var totalEstimatedMs = 0;
        for (var i = 0; i < group.length; i++) {
          totalEstimatedMs += estimateDurationMs(group[i]);
        }
        final tailAnchor = group.last.createdAtMs >= minPlausibleEpochMs
            ? group.last.createdAtMs
            : (fallbackAnchorNowMs ?? DateTime.now().millisecondsSinceEpoch);
        anchor
          ..startAtMs = tailAnchor - totalEstimatedMs
          ..timeSynced = false;
        repaired.add(anchor);
      }

      var sessionOverflowed = !anchor.timeSynced;
      for (var i = 1; i < group.length; i++) {
        final prev = group[i - 1];
        final cur = group[i];
        final int seqGap = math.max(1, cur.seq - prev.seq);
        final int prevDurMs = prev.durationMs > 0
            ? prev.durationMs
            : (seqGap == 1 ? estimateDurationMs(prev) : seqGap * 600 * 1000);
        final int expectedStartMs = prev.startAtMs + prevDurMs;
        final driftMs = (cur.startAtMs - expectedStartMs).abs();
        final wentBackwards = cur.startAtMs <= prev.startAtMs + 1000;
        final clockWrapped =
            sessionOverflowed ||
            wentBackwards ||
            !cur.timeSynced ||
            (cur.startAtMs < minPlausibleEpochMs) ||
            (seqGap == 1 && prevDurMs > 0 && driftMs > 60 * 1000);
        if (clockWrapped) {
          sessionOverflowed = true;
          if (cur.startAtMs != expectedStartMs || cur.timeSynced != false) {
            cur
              ..startAtMs = expectedStartMs
              ..timeSynced = false;
            repaired.add(cur);
          }
        }
      }
    }
    return repaired;
  }

  Future<void> _reconcileStoredSessionForFile(RecordingFile file) async {
    if (!isValidHexSession(file.session)) return;
    final key = file.session.trim().toUpperCase();
    final all = await store.loadAll(refresh: true);
    final cohort = [
      for (final f in all)
        if (f.deviceName == file.deviceName)
          file
        else if (f.session.trim().toUpperCase() == key)
          f,
    ];
    if (cohort.length < 2) return;
    final sampleRateHz = apmSourceSampleRateResolver?.call(file) ?? 15578.0;
    final changed = reconcileSessionTimestamps(
      cohort,
      defaultApmSampleRateHz: sampleRateHz,
    );
    for (final fixed in changed) {
      await store.save(fixed);
    }
  }
}
