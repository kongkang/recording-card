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
import '../transcribe/slice_planner.dart';
import '../transcribe/speaker_clusterer.dart';
import '../transcribe/speech_engine.dart';
import '../transcribe/speech_models.dart';
import '../transcribe/utterance_builder.dart';
import '../transcribe/wav_io.dart';
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
  });

  final int downloaded;
  final int ready;
  final int skipped;
  final int failed;
  final List<String> failures;
  final String? error;

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
    this.language = 'zh',
    this.slicePlanner = const SlicePlanner(),
    this.clusterer = const SpeakerClusterer(),
    this.polish,
    this.segments,
    this.topicAgent,
    this.rollingCleaner,
    TopicSegmentationStore? topicStore,
    this.voiceprintStore,
    this.network = const NetworkPolicy(),
    this.liveAudioBaseDir,
  }) : _topicStore = topicStore;

  final CardGateway gateway;
  final RecordingStore store;
  final SpeechEngine engine;
  final SpeechModelProvider models;
  final AgentConfigStore? agentConfig;
  final FastTopicSegmentAgent? topicAgent;
  final RollingCleanSegmentService? rollingCleaner;
  final VoiceprintLibraryStore? voiceprintStore;
  TopicSegmentationStore? _topicStore;

  TopicSegmentationStore get topicStore =>
      _topicStore ??= TopicSegmentationStore(resolveRoot: store.root);

  /// 清理本地存量“仅孤立标点幻觉（如 `。`）”与历史 `实时切片 #N` 标题，一次性幂等清洗落盘。
  Future<int> sanitizeLegacyDirtyRecordings() async {
    final files = await store.loadAll(refresh: true);
    final legacyTitlePattern = RegExp(r'^实时切片\s*#\d+(?:（未识别到人声）)?$');
    var fixed = 0;

    for (final file in files) {
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
  Completer<void>? _busyDone;
  Future<void> _liveSerial = Future<void>.value();

  bool get isBusy => _busy;

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
  bool _isCoveredByLiveSlices(
    CardFile source,
    List<LiveSession> liveSessions,
    List<RecordingFile> localFiles,
  ) {
    for (final session in liveSessions) {
      if (!session.coversCardFile(source)) continue;
      final hasLocalSlice = localFiles.any((f) {
        if (f.stage != RecordingStage.ready) return false;
        if (session.sliceKeys.contains(f.deviceName)) return true;
        if (session.deviceSessionId != null &&
            session.deviceSessionId!.isNotEmpty &&
            f.session == session.deviceSessionId &&
            f.deviceName.startsWith('LIVE_')) {
          return true;
        }
        return f.session == session.id;
      });
      if (hasLocalSlice) return true;
    }
    return false;
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
        );
    file
      ..apmPath = slice.wavPath
      ..wavPath = slice.wavPath
      ..durationMs = slice.durationMs
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
    var usedAcousticFallback = false;
    if (wav.frames > 0 && file.slices.isEmpty) {
      report(PipelineStage.slicing, '正在切分第 ${slice.sliceIndex + 1} 片实时录音');
      await engine.loadVad(paths.vadPath);
      final rawSamples = wav.toFloat32();
      final conditioned = conditionSpeechSamples(
        rawSamples,
        sampleRate: wav.sampleRate,
      );
      final spans = await engine.detectSpeech(conditioned);
      var planned = slicePlanner.plan(
        speech: spans,
        totalSamples: wav.frames,
        sampleRate: wav.sampleRate,
      );
      // 兜底：若 VAD 未检出区间，但去直流后存在明显高于底噪的声学能量，
      // 按 30 秒窗口直接送入 SenseVoice 由 ASR 模型自身判定是否有人声。
      if (planned.isEmpty &&
          hasAcousticSpeechCandidate(rawSamples, sampleRate: wav.sampleRate)) {
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

    if (file.slices.isNotEmpty) {
      await engine.load(
        modelPath: paths.asrModelPath,
        tokensPath: paths.tokensPath,
        language: language,
      );
      final total = file.slices.length;
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
        final subWav = readWavFile(sub.wavPath);
        final result = await engine.transcribe(subWav.toSpeechFloat32());
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
      }
      if (usedAcousticFallback && file.utterances.isEmpty) {
        file.slices = [];
        await store.save(file);
      }
    }

    if (file.utterances.isNotEmpty) {
      report(PipelineStage.labeling, '正在推测说话人');
      if (_speakerLabel && paths.canLabelSpeakers) {
        await _labelSpeakers(file, paths.speakerEmbeddingPath!);
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

  SegmentRecord _buildLocalSliceSegment(
    RecordingFile file,
    LiveAudioSlice slice,
  ) {
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
        mark: slice.gapCount > 0 ? '流中断 ${slice.gapCount} 次' : null,
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
        mark: slice.gapCount > 0 ? '流中断 ${slice.gapCount} 次' : null,
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
      mark: slice.gapCount > 0 ? '流中断 ${slice.gapCount} 次' : null,
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
    int? maxFiles,
    bool smallestFirst = false,
    int minFileSize = 0,
  }) async {
    if (_busy) {
      throw const PipelineException('同步已在进行中');
    }
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
        apms.sort((a, b) => _startSecond(b).compareTo(_startSecond(a)));
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
      final failures = <String>[];

      for (var i = 0; i < apms.length; i++) {
        final source = apms[i];
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
        try {
          final didDownload = await _processFile(
            file,
            source: source,
            fileIndex: i,
            fileTotal: apms.length,
            onProgress: onProgress,
          );
          if (didDownload) downloaded++;
          if (file.stage == RecordingStage.ready) ready++;
        } on Object catch (e) {
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
      );
    } finally {
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
        text: '正在取回 ${pipelineTimeLabel(file)} 这段（${fileIndex + 1}/$fileTotal）',
      );
      file
        ..stage = RecordingStage.downloading
        ..error = null;
      await store.save(file);
      final download = await gateway.download(file.deviceName, dir.path);
      file.apmPath = download.path.isEmpty
          ? '${dir.path}/${file.deviceName}'
          : download.path;
      didDownload = true;
      await store.save(file);
    }

    // 2) 转码（16k/16bit/mono）
    final wavPath = file.wavPath ?? '${file.apmPath}.wav';
    if (!await File(wavPath).exists()) {
      report(PipelineStage.transcoding, text: '正在转换 ${pipelineTimeLabel(file)} 这段');
      file
        ..stage = RecordingStage.transcoding
        ..error = null
        ..wavPath = wavPath;
      await store.save(file);
      final audio = await gateway.transcode(file.apmPath, wavPath);
      file.durationMs = (audio.durationSecs * 1000).round();
      // start_at 缺失时，created_at 是结束时间，反推起点
      if (source != null && source.startAtSec == null) {
        final endSec = source.createdAtSec;
        file.startAtMs = endSec != null
            ? endSec * 1000 - file.durationMs
            : DateTime.now().millisecondsSinceEpoch - file.durationMs;
        file.timeSynced = false;
      }
      await store.save(file);
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
      return didDownload;
    }
    if (paths == null || !paths.canTranscribe) {
      file
        ..stage = RecordingStage.transcoding
        ..error = '本地转写模型未就绪';
      await store.save(file);
      return didDownload;
    }

    final wav = readWavFile(wavPath);
    if (wav.frames == 0) {
      file
        ..stage = RecordingStage.ready
        ..error = null;
      await store.save(file);
      return didDownload;
    }

    // 4) VAD 切片
    if (file.slices.isEmpty) {
      report(PipelineStage.slicing, text: '正在切分 ${pipelineTimeLabel(file)} 这段');
      await engine.loadVad(paths.vadPath);
      final spans = await engine.detectSpeech(wav.toSpeechFloat32());
      final planned = slicePlanner.plan(
        speech: spans,
        totalSamples: wav.frames,
        sampleRate: wav.sampleRate,
      );
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
        return didDownload;
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
        text: '${pipelineTimeLabel(file)} 这段已取回；自动转录已关闭',
      );
      return didDownload;
    }

    // 5) 逐片本地转写（每片完成立即落盘）
    await engine.load(
      modelPath: paths.asrModelPath,
      tokensPath: paths.tokensPath,
      language: language,
    );
    final total = file.slices.length;
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
        text: '正在转写 ${pipelineTimeLabel(file)} 这段（${i + 1}/$total）',
      );
      try {
        final sliceWav = readWavFile(slice.wavPath);
        final result = await engine.transcribe(sliceWav.toSpeechFloat32());
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
      } on Object catch (e) {
        file.slices[i] = slice.copyWith(
          stage: SliceStage.failed,
          error: '$e',
        );
        await store.save(file);
        throw PipelineException('切片 ${slice.id} 转写失败：$e');
      }
    }

    // 6) 声纹聚类（关闭开关或模型缺失则统一「未区分」）
    if (file.utterances.isNotEmpty) {
      report(PipelineStage.labeling, text: '正在整理 ${pipelineTimeLabel(file)} 说话人');
      if (_speakerLabel && paths.canLabelSpeakers) {
        await _labelSpeakers(file, paths.speakerEmbeddingPath!);
      } else {
        file.utterances = [
          for (final u in file.utterances)
            u.copyWith(speakerLabel: '未区分'),
        ];
      }
      await store.save(file);
    }

    // 7) 云端窗口润色：失败不推翻本地数据，只标 stale 供界面提示
    final polisher = polish;
    if (_cleanSpeech &&
        polisher != null &&
        polisher.configured &&
        file.utterances.isNotEmpty) {
      report(PipelineStage.polishing, text: '正在润色 ${pipelineTimeLabel(file)} 这段');
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
      report(PipelineStage.summarizing, text: '正在整理 ${pipelineTimeLabel(file)} 分段');
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
    report(PipelineStage.done, text: '${pipelineTimeLabel(file)} 这段处理完成');
    return didDownload;
  }

  Future<void> _labelSpeakers(RecordingFile file, String embeddingPath) async {
    await engine.loadSpeakerEmbedding(embeddingPath);
    String? lastSliceId;
    WavPcm? lastWav;
    Float32List? lastPcm;
    final samples = <SpeakerSample>[];
    for (final utterance in file.utterances) {
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

    final cluster = clusterer.cluster(samples);
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
        );
        clusterToSpeaker = match.clusterToSpeaker;
        await profileStore.save(match.profiles);
      } on Object {
        // 只保留单文件编号：声纹表不可写不是转写失败
      }
    }

    int sessionIndexOf(int cluster) => clusterToSpeaker[cluster] ?? cluster;

    // 仅对照 5 常用自动识别槽位（1..5）匹配声纹；高分直接落真实姓名，次高区间记录弱提示
    final vpStore = voiceprintStore;
    final resolvedLabelByCluster = <int, String>{};
    for (final entry in cluster.centroids.entries) {
      final cIdx = entry.key;
      final defaultSlot = '说话人 ${sessionIndexOf(cIdx) + 1}';
      if (vpStore != null) {
        final match = vpStore.matchFrequentOnly(entry.value);
        if (match.confirmed != null) {
          resolvedLabelByCluster[cIdx] = match.confirmed!.name;
          continue;
        }
        if (match.fuzzyHint != null) {
          vpStore.recordFuzzyHint(
            session: file.session.isEmpty ? file.id : file.session,
            speakerSlot: defaultSlot,
            candidateName: match.fuzzyHint!.name,
          );
        }
      }
      resolvedLabelByCluster[cIdx] = defaultSlot;
    }

    file.utterances = [
      for (final u in file.utterances)
        if (byId[u.id] != null && byId[u.id]!.known)
          u.copyWith(
            speakerCluster: sessionIndexOf(byId[u.id]!.cluster),
            speakerLabel:
                resolvedLabelByCluster[byId[u.id]!.cluster] ??
                '说话人 ${sessionIndexOf(byId[u.id]!.cluster) + 1}',
            spkConfidence: byId[u.id]!.confidence,
          )
        else
          u.copyWith(speakerLabel: '未区分', spkConfidence: 0),
    ];
  }

  RecordingFile _newFile(CardFile source) {
    final nowSec = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final startSec = source.startAtSec;
    final endSec = source.createdAtSec ?? nowSec;
    return RecordingFile(
      deviceName: source.name,
      session: source.session ?? source.name,
      seq: source.seq ?? 1,
      startAtMs: (startSec ?? endSec) * 1000,
      timeSynced: startSec != null && (source.synced ?? true),
      apmPath: '',
      createdAtMs: DateTime.now().millisecondsSinceEpoch,
      stage: RecordingStage.queued,
    );
  }

  static int _startSecond(CardFile file) =>
      file.startAtSec ?? file.createdAtSec ?? 0;
}
