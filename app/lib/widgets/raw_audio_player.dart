/// 原始录音回听 —— 只播手机上**已经实收**的那段音频。
///
/// 刻意不在这里"从设备临时拉一份完整文件来播"：那样听着完整，却恰好掩盖了
/// 实时流漏数据的问题。这个播放器的职责是**验证数据完整性**，所以：
/// - 优先按当前切片/分段自身的 [wavPath] 与 `[clipStartMs, clipEndMs]` 区间回放，不串用整场长录音时长；
/// - 底部带可拖拽快进进度条，并支持外部点击句子卡片按时间戳联动跳转（[seekToFileMs]）；
/// - 有断档就显式提示「中间有 N 处中断」，本地音频被清理后只留「原始录音已清理」。
library;

import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/theme/tokens.dart';
import '../services/audio/live_audio_recorder.dart';
import '../services/recordings/recording_store.dart';
import '../services/transcribe/wav_io.dart';

class RawAudioPlayer extends StatefulWidget {
  const RawAudioPlayer({
    super.key,
    required this.fileKey,
    this.wavPath,
    this.durationHintMs,
    this.clipStartMs,
    this.clipEndMs,
    this.gapCountOverride,
    this.baseDir,
    this.allowDelete = true,
    this.padding = const EdgeInsets.only(bottom: 18),
    this.onFilePositionChanged,
  });

  /// 记录对应的设备文件名（绑定表的主键）。
  final String fileKey;

  /// 记录自身已落盘的 WAV 路径（如 1 分钟实时流切片或已转码录音）；存在时优先按本段回放。
  final String? wavPath;

  /// 元数据记录的时长兜底（毫秒）。
  final int? durationHintMs;

  /// 当前分段在 [wavPath] 内的起始毫秒偏移（多话题共用单个设备文件时限定本段起点；默认 0）。
  final int? clipStartMs;

  /// 当前分段在 [wavPath] 内的结束毫秒偏移（默认播到当前 WAV 文件末尾）。
  final int? clipEndMs;

  /// 当前切片自身的断档次数（为空时仅在回退会话级录音时读取会话 gapCount）。
  final int? gapCountOverride;

  final Directory? baseDir;
  final bool allowDelete;
  final EdgeInsetsGeometry padding;

  /// 播放位置变化回调（相对 WAV 文件起点的毫秒数；停止归零时传 null）。
  final ValueChanged<int?>? onFilePositionChanged;

  @override
  State<RawAudioPlayer> createState() => RawAudioPlayerState();
}

class RawAudioPlayerState extends State<RawAudioPlayer> {
  AudioPlayer? _player;
  StreamSubscription<Duration>? _posSub;
  StreamSubscription<Duration>? _durSub;
  StreamSubscription<void>? _completeSub;

  LiveSession? _session;
  String? _audioPath;
  bool _usingDirectFile = false;
  bool _loading = true;
  bool _playing = false;
  int _fileDurationMs = 0;
  int _playerDurationMs = 0;
  int _filePositionMs = 0;
  double? _dragRelMs;
  String? _error;

  int get _effectiveFileTotalMs {
    if (_fileDurationMs > 0) return _fileDurationMs;
    if (_playerDurationMs > 0) return _playerDurationMs;
    if ((widget.durationHintMs ?? 0) > 0) return widget.durationHintMs!;
    if (!_usingDirectFile) {
      return _session?.receivedSamples ?? 0;
    }
    return 0;
  }

  int get _clipStart {
    final raw = widget.clipStartMs ?? 0;
    if (raw <= 0) return 0;
    final total = _effectiveFileTotalMs;
    return total > 0 ? raw.clamp(0, total) : raw;
  }

  int get _clipEnd {
    final start = _clipStart;
    final total = _effectiveFileTotalMs;
    final rawEnd = widget.clipEndMs;
    if (rawEnd != null && rawEnd > start) {
      return total > 0 ? rawEnd.clamp(start, total) : rawEnd;
    }
    return total > start ? total : start;
  }

  int get _clipDurationMs => math.max(0, _clipEnd - _clipStart);

  AudioPlayer _ensurePlayer() {
    final existing = _player;
    if (existing != null) return existing;
    final created = AudioPlayer();
    _player = created;
    _posSub = created.onPositionChanged.listen((p) {
      if (!mounted) return;
      final ms = p.inMilliseconds;
      final end = _clipEnd;
      if (_playing && end > _clipStart && ms >= end) {
        unawaited(_stopAtClipEnd());
        return;
      }
      setState(() => _filePositionMs = ms);
      widget.onFilePositionChanged?.call(ms);
    });
    _durSub = created.onDurationChanged.listen((d) {
      if (!mounted) return;
      if (d.inMilliseconds > 0) {
        setState(() => _playerDurationMs = d.inMilliseconds);
      }
    });
    _completeSub = created.onPlayerComplete.listen((_) {
      if (mounted) {
        setState(() {
          _playing = false;
          _filePositionMs = _clipStart;
          _dragRelMs = null;
        });
      }
      widget.onFilePositionChanged?.call(null);
      unawaited(created.seek(Duration(milliseconds: _clipStart)));
    });
    return created;
  }

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void didUpdateWidget(covariant RawAudioPlayer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.fileKey != widget.fileKey ||
        oldWidget.wavPath != widget.wavPath ||
        oldWidget.clipStartMs != widget.clipStartMs ||
        oldWidget.clipEndMs != widget.clipEndMs) {
      unawaited(_resetAndReload());
    }
  }

  Future<void> _resetAndReload() async {
    final player = _player;
    if (player != null) {
      try {
        await player.stop();
      } on Object {
        // 忽略旧实例停止异常
      }
    }
    if (!mounted) return;
    setState(() {
      _loading = true;
      _playing = false;
      _fileDurationMs = 0;
      _playerDurationMs = 0;
      _filePositionMs = 0;
      _dragRelMs = null;
      _error = null;
    });
    widget.onFilePositionChanged?.call(null);
    await _load();
  }

  Future<void> _stopAtClipEnd() async {
    final player = _player;
    if (player != null) {
      await player.pause();
      await player.seek(Duration(milliseconds: _clipStart));
    }
    if (!mounted) return;
    setState(() {
      _playing = false;
      _filePositionMs = _clipStart;
      _dragRelMs = null;
    });
    widget.onFilePositionChanged?.call(null);
  }

  Future<void> _load() async {
    String? directPath;
    int wavDurMs = 0;
    final rawWav = widget.wavPath;
    if (rawWav != null && rawWav.isNotEmpty) {
      final rebased = RecordingStore.rebaseAppSupportPath(rawWav);
      if (File(rebased).existsSync()) {
        directPath = rebased;
        wavDurMs = readWavDurationMsSync(rebased) ?? 0;
      }
    }

    if (directPath != null) {
      if (!mounted) return;
      setState(() {
        _session = null;
        _audioPath = directPath;
        _usingDirectFile = true;
        _fileDurationMs = wavDurMs;
        _filePositionMs = widget.clipStartMs ?? 0;
        _loading = false;
      });
      return;
    }

    LiveSession? session;
    String? fallbackSessionPath;
    session = await LiveAudioRecorder.sessionForFile(
      widget.fileKey,
      baseDir: widget.baseDir,
    );
    if (session != null) {
      fallbackSessionPath = await LiveAudioRecorder.audioPathOf(
        session.id,
        baseDir: widget.baseDir,
      );
      if (fallbackSessionPath != null) {
        wavDurMs = readWavDurationMsSync(fallbackSessionPath) ?? 0;
      }
    }

    final resolvedPath = fallbackSessionPath;
    if (!mounted) return;
    setState(() {
      _session = session;
      _audioPath = resolvedPath;
      _usingDirectFile = false;
      _fileDurationMs = wavDurMs;
      _filePositionMs = widget.clipStartMs ?? 0;
      _loading = false;
    });
  }

  /// 供详情页句子卡片点击调用：跳转到相对 WAV 文件起点的 [fileMs] 位置并（默认）立即开始播放。
  Future<void> seekToFileMs(int fileMs, {bool autoPlay = true}) async {
    final path = _audioPath;
    if (path == null) return;
    final start = _clipStart;
    final end = _clipEnd;
    final targetMs = end > start ? fileMs.clamp(start, end) : math.max(0, fileMs);
    setState(() {
      _dragRelMs = null;
      _filePositionMs = targetMs;
      _error = null;
    });
    widget.onFilePositionChanged?.call(targetMs);

    try {
      final pos = Duration(milliseconds: targetMs);
      if (autoPlay) {
        final player = _ensurePlayer();
        if (_playing) {
          await player.seek(pos);
        } else {
          await player.play(DeviceFileSource(path), position: pos);
          if (mounted) setState(() => _playing = true);
        }
      } else if (_playing) {
        await _ensurePlayer().seek(pos);
      } else {
        // 暂停态拖拽进度条：同步底层位置（未加载源时忽略异常，下次点播放会按 _filePositionMs 起播）
        final player = _player;
        if (player != null) {
          try {
            await player.seek(pos);
          } on Object {
            // 首次尚未 setSource 时由下次 _toggle 携带 position 起播
          }
        }
      }
    } on MissingPluginException {
      // 无原生插件环境（Widget 测试）仅更新进度状态，不报错
    } catch (e) {
      if (mounted) setState(() => _error = '播放失败：$e');
    }
  }

  Future<void> _toggle() async {
    final path = _audioPath;
    if (path == null) return;
    try {
      final player = _ensurePlayer();
      if (_playing) {
        await player.pause();
        if (mounted) setState(() => _playing = false);
        return;
      }
      final start = _clipStart;
      final end = _clipEnd;
      var resumeMs = _filePositionMs < start ? start : _filePositionMs;
      if (end > start && resumeMs >= end - 200) {
        resumeMs = start;
      }
      await player.play(
        DeviceFileSource(path),
        position: Duration(milliseconds: resumeMs),
      );
      if (mounted) {
        setState(() {
          _playing = true;
          _filePositionMs = resumeMs;
          _error = null;
        });
      }
      widget.onFilePositionChanged?.call(resumeMs);
    } catch (e) {
      if (mounted) setState(() => _error = '播放失败：$e');
    }
  }

  Future<void> _deleteLocal() async {
    final path = _audioPath;
    final player = _player;
    if (player != null) {
      try {
        await player.stop();
      } on Object {
        // 忽略无原生通道或已释放异常
      }
    }
    if (_usingDirectFile && path != null) {
      final f = File(path);
      if (await f.exists()) {
        await f.delete();
      }
    } else if (_session != null) {
      await LiveAudioRecorder.deleteSession(
        _session!.id,
        baseDir: widget.baseDir,
      );
    }
    if (!mounted) return;
    setState(() {
      _session = null;
      _audioPath = null;
      _usingDirectFile = false;
      _playing = false;
      _filePositionMs = 0;
      _fileDurationMs = 0;
      _playerDurationMs = 0;
      _dragRelMs = null;
    });
    widget.onFilePositionChanged?.call(null);
  }

  String _mmss(Duration d) {
    final m = d.inMinutes.toString().padLeft(2, '0');
    final s = (d.inSeconds % 60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  @override
  void dispose() {
    _posSub?.cancel();
    _durSub?.cancel();
    _completeSub?.cancel();
    _player?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const SizedBox(height: 44);
    }
    // 本地音频不存在（从未收到 / 已被清理）：如实说明，不假装能播
    if (_audioPath == null) {
      return Padding(
        key: const Key('raw-audio-cleared'),
        padding: widget.padding,
        child: Row(
          children: const [
            Icon(Icons.mic_off_outlined, size: 16, color: RCColors.ax),
            SizedBox(width: 8),
            Text(
              '原始录音已清理',
              style: TextStyle(fontSize: 12.5, color: RCColors.sec),
            ),
          ],
        ),
      );
    }

    final gaps = widget.gapCountOverride ??
        (_usingDirectFile ? 0 : (_session?.gapCount ?? 0));
    final totalMs = _clipDurationMs;
    final sliderMax = totalMs > 0 ? totalMs.toDouble() : 1.0;
    final currentRelMs = (_dragRelMs ?? (_filePositionMs - _clipStart).toDouble())
        .clamp(0.0, sliderMax);
    final posDuration = Duration(milliseconds: currentRelMs.round());
    final totalDuration = Duration(milliseconds: totalMs);

    return Padding(
      key: const Key('raw-audio-player'),
      padding: widget.padding,
      // 触控目标不低于 44pt：整行高度按 44 起
      child: Container(
        constraints: const BoxConstraints(minHeight: 44),
        padding: const EdgeInsets.fromLTRB(10, 8, 10, 6),
        decoration: BoxDecoration(
          color: RCColors.card,
          border: Border.all(color: RCColors.sep),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Semantics(
                  button: true,
                  label: _playing ? '暂停原始录音' : '播放原始录音',
                  child: InkWell(
                    key: const Key('raw-audio-toggle'),
                    onTap: _toggle,
                    borderRadius: BorderRadius.circular(20),
                    child: Container(
                      width: 44,
                      height: 44,
                      alignment: Alignment.center,
                      child: Icon(
                        _playing ? Icons.pause : Icons.play_arrow,
                        size: 24,
                        color: RCColors.label,
                      ),
                    ),
                  ),
                ),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '${_mmss(posDuration)} / ${_mmss(totalDuration)}',
                        key: const Key('raw-audio-time'),
                        style: const TextStyle(
                          fontSize: 12,
                          color: RCColors.ink,
                          fontFeatures: [FontFeature.tabularFigures()],
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        gaps > 0
                            ? '本机原始录音 · 中间有 $gaps 处中断'
                            : '本机原始录音 · 完整',
                        key: const Key('raw-audio-state'),
                        style: TextStyle(
                          fontSize: 11.5,
                          color: gaps > 0 ? RCColors.warn : RCColors.sec,
                        ),
                      ),
                    ],
                  ),
                ),
                if (widget.allowDelete)
                  TextButton(
                    key: const Key('raw-audio-delete'),
                    onPressed: _deleteLocal,
                    style: TextButton.styleFrom(
                      foregroundColor: RCColors.sec,
                      minimumSize: const Size(44, 44),
                    ),
                    child: const Text(
                      '清理',
                      style: TextStyle(fontSize: 12),
                    ),
                  ),
              ],
            ),
            SliderTheme(
              data: SliderTheme.of(context).copyWith(
                trackHeight: 3,
                activeTrackColor: RCColors.label,
                inactiveTrackColor: RCColors.sep,
                thumbColor: RCColors.label,
                overlayColor: RCColors.label.withValues(alpha: 0.12),
                thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
                overlayShape: const RoundSliderOverlayShape(overlayRadius: 14),
              ),
              child: SizedBox(
                height: 26,
                child: Slider(
                  key: const Key('raw-audio-slider'),
                  value: currentRelMs,
                  min: 0,
                  max: sliderMax,
                  onChanged: totalMs > 0
                      ? (v) => setState(() => _dragRelMs = v)
                      : null,
                  onChangeEnd: totalMs > 0
                      ? (v) {
                          unawaited(
                            seekToFileMs(
                              _clipStart + v.round(),
                              autoPlay: _playing,
                            ),
                          );
                        }
                      : null,
                ),
              ),
            ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(top: 4, left: 4, right: 4),
                child: Text(
                  _error!,
                  style: const TextStyle(fontSize: 11.5, color: RCColors.danger),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
