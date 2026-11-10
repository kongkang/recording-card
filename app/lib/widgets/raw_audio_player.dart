/// 原始录音回听 —— 只播手机上**已经实收**的那段音频。
///
/// 刻意不在这里"从设备临时拉一份完整文件来播"：那样听着完整，却恰好掩盖了
/// 实时流漏数据的问题。这个播放器的职责是**验证数据完整性**，所以：
/// - 有断档就显式提示「中间有 N 处中断」，让缺口感官上能听出来；
/// - 本地音频被清理后，只留一行「原始录音已清理」，不做任何假播放。
library;

import 'dart:async';
import 'dart:io';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';

import '../core/theme/tokens.dart';
import '../services/audio/live_audio_recorder.dart';

class RawAudioPlayer extends StatefulWidget {
  const RawAudioPlayer({
    super.key,
    required this.fileKey,
    this.baseDir,
    this.allowDelete = true,
  });

  /// 记录对应的设备文件名（绑定表的主键）。
  final String fileKey;
  final Directory? baseDir;
  final bool allowDelete;

  @override
  State<RawAudioPlayer> createState() => _RawAudioPlayerState();
}

class _RawAudioPlayerState extends State<RawAudioPlayer> {
  final _player = AudioPlayer();
  StreamSubscription<Duration>? _posSub;
  StreamSubscription<Duration>? _durSub;
  StreamSubscription<void>? _completeSub;

  LiveSession? _session;
  String? _audioPath;
  bool _loading = true;
  bool _playing = false;
  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;
  String? _error;

  @override
  void initState() {
    super.initState();
    _posSub = _player.onPositionChanged.listen((p) {
      if (mounted) setState(() => _position = p);
    });
    _durSub = _player.onDurationChanged.listen((d) {
      if (mounted) setState(() => _duration = d);
    });
    _completeSub = _player.onPlayerComplete.listen((_) {
      if (mounted) {
        setState(() {
          _playing = false;
          _position = Duration.zero;
        });
      }
      unawaited(_player.seek(Duration.zero));
    });
    unawaited(_load());
  }

  Future<void> _load() async {
    final session = await LiveAudioRecorder.sessionForFile(
      widget.fileKey,
      baseDir: widget.baseDir,
    );
    final path = session == null
        ? null
        : await LiveAudioRecorder.audioPathOf(
            session.id,
            baseDir: widget.baseDir,
          );
    if (!mounted) return;
    setState(() {
      _session = session;
      _audioPath = path;
      _loading = false;
    });
  }

  Future<void> _toggle() async {
    final path = _audioPath;
    if (path == null) return;
    try {
      if (_playing) {
        await _player.pause();
        if (mounted) setState(() => _playing = false);
        return;
      }
      await _player.play(DeviceFileSource(path));
      if (mounted) setState(() => _playing = true);
    } catch (e) {
      if (mounted) setState(() => _error = '播放失败：$e');
    }
  }

  Future<void> _deleteLocal() async {
    final session = _session;
    if (session == null) return;
    await _player.stop();
    await LiveAudioRecorder.deleteSession(session.id, baseDir: widget.baseDir);
    if (!mounted) return;
    setState(() {
      _session = null;
      _audioPath = null;
      _playing = false;
      _position = Duration.zero;
      _duration = Duration.zero;
    });
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
    _player.dispose();
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
        padding: const EdgeInsets.only(bottom: 16),
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

    final session = _session;
    final gaps = session?.gapCount ?? 0;
    final total = _duration > Duration.zero
        ? _duration
        : Duration(milliseconds: session?.receivedSamples ?? 0);

    return Padding(
      key: const Key('raw-audio-player'),
      padding: const EdgeInsets.only(bottom: 18),
      // 触控目标不低于 44pt：整行高度按 44 起
      child: Container(
        constraints: const BoxConstraints(minHeight: 44),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: RCColors.card,
          border: Border.all(color: RCColors.sep),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
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
                        '${_mmss(_position)} / ${_mmss(total)}',
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
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(top: 6),
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
