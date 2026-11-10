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

import 'dart:io';

import 'package:flutter/foundation.dart';

import '../../core/device/card_gateway.dart';
import '../../core/models/recording.dart';
import '../../core/store/settings_store.dart';
import '../polish/slice_polish_service.dart';
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

class RecordingPipeline {
  RecordingPipeline({
    required this.gateway,
    required this.store,
    required this.engine,
    required this.models,
    this.settings,
    this.language = 'zh',
    this.slicePlanner = const SlicePlanner(),
    this.clusterer = const SpeakerClusterer(),
    this.polish,
    this.segments,
    this.network = const NetworkPolicy(),
  });

  final CardGateway gateway;
  final RecordingStore store;
  final SpeechEngine engine;
  final SpeechModelProvider models;

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

  bool get isBusy => _busy;

  /// 从设备同步新录音并处理。已完成的文件跳过；失败文件重试。
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
    _busy = true;
    try {
      onProgress?.call(
        const PipelineProgress(
          stage: PipelineStage.listing,
          fileIndex: 0,
          fileTotal: 0,
          text: '正在读取录音卡文件列表…',
        ),
      );
      final files = await gateway.files();
      var apms = files
          .where((f) => f.isApm && f.size >= minFileSize)
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
      _busy = false;
    }
  }

  /// 继续处理本地未完成的录音（启动/切前台时调用）。
  Future<PipelineSyncResult> processPending({
    void Function(PipelineProgress progress)? onProgress,
  }) async {
    if (_busy) {
      throw const PipelineException('处理已在进行中');
    }
    _busy = true;
    try {
      final all = await store.loadAll(refresh: true);
      final pending = all
          .where((f) => f.stage != RecordingStage.ready)
          .toList()
        ..sort((a, b) => b.startAtMs.compareTo(a.startAtMs));

      // 续跑必须知道设备上还剩哪些文件：否则「本地没有 .apm」会被当成新下载，
      // 而设备上早已被取走（固件取完即删），于是每轮重试都卡在同一处、永远走不完。
      // 拿不到清单（未连接/超时）就把这批标记为可重试的排队态并**立刻收尾**，
      // 不让进度条停在 N/N 上。
      final Map<String, CardFile> deviceFiles = {};
      var listingFailed = false;
      if (pending.isNotEmpty) {
        try {
          final files = await gateway.files();
          for (final f in files) {
            deviceFiles[f.name] = f;
          }
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
        // 本地没有音频、设备上也没这个文件（或清单读不到）：不再重试下载，
        // 明确标成失败并给出原因，避免进度永远停在最后一条。
        final lacksAudio =
            file.apmPath.isEmpty || !await File(file.apmPath).exists();
        if (lacksAudio && (listingFailed || !deviceFiles.containsKey(file.deviceName))) {
          failed++;
          failures.add('${file.deviceName}: 录音文件不在本机、设备上也不存在');
          file
            ..stage = RecordingStage.failed
            ..error = listingFailed
                // 未连卡时谈"读取失败"会误导；如实说是无法核对，让用户知道要做什么
                ? '未连接到录音卡，无法核对缺失的录音，连上后可重试'
                : '设备上已不存在该录音，无法补取';
          await store.save(file);
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
      _busy = false;
    }
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

    // 1) 取回 .apm（本地已有则跳过）
    if (file.apmPath.isEmpty || !await File(file.apmPath).exists()) {
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
        text: '正在取回 ${file.deviceName}（${fileIndex + 1}/$fileTotal）',
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
      report(PipelineStage.transcoding, text: '正在转换 ${file.deviceName}');
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
      report(PipelineStage.slicing, text: '正在切分 ${file.deviceName}');
      await engine.loadVad(paths.vadPath);
      final spans = await engine.detectSpeech(wav.toFloat32());
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
        text: '${file.deviceName} 已取回；自动转录已关闭',
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
        text: '正在转写 ${file.deviceName}（${i + 1}/$total）',
      );
      try {
        final sliceWav = readWavFile(slice.wavPath);
        final result = await engine.transcribe(sliceWav.toFloat32());
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
      report(PipelineStage.labeling, text: '正在整理说话人 ${file.deviceName}');
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
      report(PipelineStage.polishing, text: '正在润色 ${file.deviceName}');
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
      report(PipelineStage.summarizing, text: '正在整理分段 ${file.deviceName}');
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
    report(PipelineStage.done, text: '${file.deviceName} 处理完成');
    return didDownload;
  }

  Future<void> _labelSpeakers(RecordingFile file, String embeddingPath) async {
    await engine.loadSpeakerEmbedding(embeddingPath);
    final cache = <String, WavPcm>{};
    final pcmCache = <String, Float32List>{};
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
      final wav = cache[slice.id] ??= readWavFile(slice.wavPath);
      final startFrame =
          ((utterance.startMs - slice.startMs) * wav.sampleRate / 1000).round();
      final endFrame =
          ((utterance.endMs - slice.startMs) * wav.sampleRate / 1000).round();
      final start = startFrame.clamp(0, wav.frames);
      final end = endFrame.clamp(start, wav.frames);
      if (end - start < wav.sampleRate * 6 ~/ 10) continue; // <0.6s 不做声纹
      final pcm = pcmCache[slice.id] ??= wav.toFloat32();
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

    file.utterances = [
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
