/// OS1 全屏 AI 空间浮层 —— 「沉浸通话」（《Her》声波圆环 + 系统 STT/TTS）与「轻聊」双模式。
///
/// 性能与测试原则：
/// - 声波圆环 Ticker 仅在面板打开且处于 [Os1Mode.her] 时运行，切走或关闭立即停表，
///   不拖垮后台帧率，也不会阻塞 Widget 测试的 `pumpAndSettle`；
/// - 轻聊等待态仅显示极简三点跳动，不暴露冰冷工具链或思考链。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../core/theme/tokens.dart';
import '../services/agent/agent_chat_controller.dart';
import '../services/agent/agent_models.dart';

class Os1AiSpaceOverlay extends StatefulWidget {
  const Os1AiSpaceOverlay({super.key, required this.controller});

  final AgentChatController controller;

  @override
  State<Os1AiSpaceOverlay> createState() => _Os1AiSpaceOverlayState();
}

class _Os1AiSpaceOverlayState extends State<Os1AiSpaceOverlay>
    with SingleTickerProviderStateMixin {
  late final AnimationController _drawerCtrl = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 240),
  );

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_syncOverlayVisibility);
  }

  @override
  void didUpdateWidget(covariant Os1AiSpaceOverlay oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_syncOverlayVisibility);
      widget.controller.addListener(_syncOverlayVisibility);
      _syncOverlayVisibility();
    }
  }

  void _syncOverlayVisibility() {
    if (!widget.controller.isOpen || widget.controller.mode == Os1Mode.her) {
      if (_drawerCtrl.value != 0) _drawerCtrl.value = 0;
    }
  }

  void _openDrawer() {
    FocusManager.instance.primaryFocus?.unfocus();
    unawaited(widget.controller.refreshSessions());
    unawaited(_drawerCtrl.forward());
  }

  void _closeDrawer() {
    unawaited(_drawerCtrl.reverse());
  }

  void _handleDrawerDragUpdate(DragUpdateDetails details, double drawerWidth) {
    _drawerCtrl.value =
        (_drawerCtrl.value - details.delta.dx / drawerWidth).clamp(0.0, 1.0);
  }

  void _handleDrawerDragEnd(
    DragEndDetails details, {
    required bool openingGesture,
  }) {
    final vx = details.primaryVelocity ?? 0;
    final shouldOpen = openingGesture
        ? (vx < -300 || _drawerCtrl.value >= 0.32)
        : !(vx > 300 || _drawerCtrl.value < 0.68);
    if (shouldOpen) {
      _openDrawer();
    } else {
      _closeDrawer();
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(_syncOverlayVisibility);
    _drawerCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.controller,
      builder: (context, _) {
        if (!widget.controller.isOpen) return const SizedBox.shrink();
        final s = context.rcStyle;
        final isHer = widget.controller.mode == Os1Mode.her;
        final isAirCoralChat = !isHer && s.styleId == RCUIStyleId.air;
        final bg = isHer ? s.os1HerGradient[1] : s.os1ChatBg;
        final topPadding = MediaQuery.paddingOf(context).top;
        final bottomPadding = MediaQuery.paddingOf(context).bottom;
        return Positioned.fill(
          child: Material(
            key: const Key('ai-space'),
            color: bg,
            child: DecoratedBox(
              decoration: isAirCoralChat
                  ? const BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [
                          Color(0xFFE85D3F),
                          Color(0xFFC9412C),
                          Color(0xFFA93026),
                        ],
                      ),
                    )
                  : const BoxDecoration(),
              child: LayoutBuilder(
              builder: (context, constraints) {
                final drawerWidth = math.min(
                  constraints.maxWidth * 0.80,
                  320.0,
                );
                return Stack(
                  children: [
                    Column(
                      children: [
                        SizedBox(height: topPadding),
                        _TopBar(controller: widget.controller, isHer: isHer),
                        Expanded(
                          child: isHer
                              ? _HerVoicePane(
                                  controller: widget.controller,
                                  bottomPadding: bottomPadding,
                                )
                              : _HumanChatPane(
                                  controller: widget.controller,
                                  bottomPadding: bottomPadding,
                                  onOpenHistory: _openDrawer,
                                ),
                        ),
                      ],
                    ),
                    if (!isHer)
                      Positioned(
                        top: topPadding + 56,
                        bottom: 108 + bottomPadding,
                        right: 0,
                        width: 36,
                        child: GestureDetector(
                          key: const Key('ai-history-edge-zone'),
                          behavior: HitTestBehavior.translucent,
                          onHorizontalDragStart: (_) {
                            FocusManager.instance.primaryFocus?.unfocus();
                          },
                          onHorizontalDragUpdate: (d) =>
                              _handleDrawerDragUpdate(d, drawerWidth),
                          onHorizontalDragEnd: (d) =>
                              _handleDrawerDragEnd(d, openingGesture: true),
                          onHorizontalDragCancel: () {
                            if (_drawerCtrl.value >= 0.5) {
                              _openDrawer();
                            } else {
                              _closeDrawer();
                            }
                          },
                          child: Align(
                            alignment: Alignment.centerRight,
                            child: Tooltip(
                              message: '左滑查看历史对话',
                              child: GestureDetector(
                                key: const Key('ai-history-edge-handle'),
                                behavior: HitTestBehavior.opaque,
                                onTap: _openDrawer,
                                child: SizedBox(
                                  width: 20,
                                  height: 56,
                                  child: Center(
                                    child: Padding(
                                      padding: const EdgeInsets.only(right: 3),
                                      child: Container(
                                        width: 4,
                                        height: 36,
                                        decoration: BoxDecoration(
                                          color: context.rc.ax.withValues(
                                            alpha: 0.75,
                                          ),
                                          borderRadius: BorderRadius.circular(
                                            999,
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    if (!isHer)
                      Positioned.fill(
                        child: AnimatedBuilder(
                          animation: _drawerCtrl,
                          builder: (context, child) {
                            if (_drawerCtrl.value <= 0.001) {
                              return const IgnorePointer(
                                ignoring: true,
                                child: SizedBox.shrink(),
                              );
                            }
                            final progress = Curves.easeOutCubic.transform(
                              _drawerCtrl.value,
                            );
                            return Stack(
                              children: [
                                Positioned.fill(
                                  child: GestureDetector(
                                    key: const Key('ai-history-scrim'),
                                    behavior: HitTestBehavior.opaque,
                                    onTap: _closeDrawer,
                                    onHorizontalDragUpdate: (d) =>
                                        _handleDrawerDragUpdate(d, drawerWidth),
                                    onHorizontalDragEnd: (d) =>
                                        _handleDrawerDragEnd(
                                          d,
                                          openingGesture: false,
                                        ),
                                    child: ColoredBox(
                                      color: Colors.black.withValues(
                                        alpha: 0.32 * progress,
                                      ),
                                    ),
                                  ),
                                ),
                                Positioned(
                                  top: 0,
                                  bottom: 0,
                                  right: 0,
                                  width: drawerWidth,
                                  child: Transform.translate(
                                    offset: Offset(
                                      drawerWidth * (1.0 - progress),
                                      0,
                                    ),
                                    child: GestureDetector(
                                      behavior: HitTestBehavior.opaque,
                                      onHorizontalDragUpdate: (d) =>
                                          _handleDrawerDragUpdate(
                                            d,
                                            drawerWidth,
                                          ),
                                      onHorizontalDragEnd: (d) =>
                                          _handleDrawerDragEnd(
                                            d,
                                            openingGesture: false,
                                          ),
                                      child: child,
                                    ),
                                  ),
                                ),
                              ],
                            );
                          },
                          child: _ChatHistoryDrawer(
                            controller: widget.controller,
                            topPadding: topPadding,
                            bottomPadding: bottomPadding,
                            onClose: _closeDrawer,
                          ),
                        ),
                      ),
                  ],
                );
              },
            ),
            ),
          ),
        );
      },
    );
  }
}

class _TopBar extends StatelessWidget {
  const _TopBar({required this.controller, required this.isHer});

  final AgentChatController controller;
  final bool isHer;

  ButtonStyle _pillButtonStyle(RCColorScheme c, bool darkChrome) =>
      TextButton.styleFrom(
        backgroundColor: darkChrome
            ? const Color(0x2EFFFFFF)
            : const Color(0x0F000000),
        foregroundColor: darkChrome ? Colors.white : c.label,
        disabledForegroundColor: darkChrome
            ? const Color(0x66FFFFFF)
            : c.sec.withValues(alpha: 0.55),
        disabledBackgroundColor: darkChrome
            ? const Color(0x18FFFFFF)
            : const Color(0x08000000),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
        minimumSize: Size.zero,
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        shape: const StadiumBorder(),
        textStyle: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
      );

  @override
  Widget build(BuildContext context) {
    final c = context.rc;
    final s = context.rcStyle;
    final darkChrome =
        isHer ||
        c.isDark ||
        s.styleId == RCUIStyleId.braunField ||
        s.styleId == RCUIStyleId.air;
    final pillStyle = _pillButtonStyle(c, darkChrome);
    final canStartNew = !controller.isBusy && controller.messages.isNotEmpty;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 8),
      child: Row(
        children: [
          Expanded(
            child: Align(
              alignment: Alignment.centerLeft,
              child: TextButton(
                key: const Key('ai-space-close'),
                onPressed: controller.close,
                style: pillStyle,
                child: const Text('收起'),
              ),
            ),
          ),
          Container(
            padding: const EdgeInsets.all(3),
            decoration: BoxDecoration(
              color: darkChrome
                  ? const Color(0x26FFFFFF)
                  : const Color(0x0F000000),
              borderRadius: BorderRadius.circular(999),
              border: Border.all(
                color: darkChrome ? const Color(0x38FFFFFF) : c.sep,
              ),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                _modeBtn(
                  c: c,
                  s: s,
                  key: const Key('ai-mode-her'),
                  label: '沉浸通话',
                  active: isHer,
                  isHerTheme: isHer,
                  darkChrome: darkChrome,
                  onTap: () => controller.setMode(Os1Mode.her),
                ),
                _modeBtn(
                  c: c,
                  s: s,
                  key: const Key('ai-mode-chat'),
                  label: '轻聊',
                  active: !isHer,
                  isHerTheme: isHer,
                  darkChrome: darkChrome,
                  onTap: () => controller.setMode(Os1Mode.chat),
                ),
              ],
            ),
          ),
          Expanded(
            child: Align(
              alignment: Alignment.centerRight,
              child: Tooltip(
                message: '开启新对话，当前记录将保留在历史中',
                child: TextButton(
                  key: const Key('ai-chat-clear'),
                  onPressed: canStartNew ? controller.startNewSession : null,
                  style: pillStyle,
                  child: const Text('新对话'),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _modeBtn({
    required RCColorScheme c,
    required RCStyleSpec s,
    required Key key,
    required String label,
    required bool active,
    required bool isHerTheme,
    required bool darkChrome,
    required VoidCallback onTap,
  }) {
    final Color activeBg;
    final Color activeFg;
    if (isHerTheme) {
      activeBg = Colors.white;
      activeFg = s.os1HerGradient[1];
    } else if (s.styleId == RCUIStyleId.air) {
      activeBg = Colors.white;
      activeFg = const Color(0xFFC9412C);
    } else if (s.styleId == RCUIStyleId.braunField) {
      activeBg = const Color(0xFFFF5514);
      activeFg = const Color(0xFF121210);
    } else if (s.styleId == RCUIStyleId.nocturne) {
      activeBg = const Color(0xFFF5A623);
      activeFg = const Color(0xFF111214);
    } else {
      activeBg = c.card;
      activeFg = c.label;
    }

    return GestureDetector(
      key: key,
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
        decoration: BoxDecoration(
          color: active ? activeBg : Colors.transparent,
          borderRadius: BorderRadius.circular(999),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 12.5,
            fontWeight: active ? FontWeight.w700 : FontWeight.w500,
            color: active
                ? activeFg
                : (darkChrome ? const Color(0xE6FFFFFF) : c.sec),
          ),
        ),
      ),
    );
  }
}

// ── 沉浸通话（《Her》OS1 声波圆环 + 系统 STT/TTS）──────────────────

class _HerVoicePane extends StatefulWidget {
  const _HerVoicePane({required this.controller, required this.bottomPadding});

  final AgentChatController controller;
  final double bottomPadding;

  @override
  State<_HerVoicePane> createState() => _HerVoicePaneState();
}

class _HerVoicePaneState extends State<_HerVoicePane>
    with SingleTickerProviderStateMixin {
  late final Ticker _ticker;
  double _phase = 0;
  String? _spoken;
  Timer? _spokenTimer;
  var _spokenHoldDone = false;

  @override
  void initState() {
    super.initState();
    _ticker = createTicker((elapsed) {
      if (!mounted) return;
      final listening =
          widget.controller.isListening || widget.controller.isSpeaking;
      // 未通话也要缓慢呼吸；通话/思考再加快，音量只加一点点，避免波纹乱跳。
      final boost = listening
          ? 0.022
          : (widget.controller.isBusy ? 0.016 : 0.009);
      setState(() {
        _phase += boost + widget.controller.voiceEnergy * 0.008;
      });
    });
    _syncTicker();
    widget.controller.addListener(_syncTicker);
  }

  void _syncTicker() {
    // 面板开着就一直转。未通话停表会让圆环完全冻住。
    final shouldAnimate =
        widget.controller.isOpen && widget.controller.mode == Os1Mode.her;
    if (shouldAnimate && !_ticker.isActive) {
      _ticker.start();
    } else if (!shouldAnimate && _ticker.isActive) {
      _ticker.stop();
    }
    _releaseSpoken();
  }

  void _releaseSpoken() {
    if (!_spokenHoldDone || widget.controller.isBusy || _spoken == null) {
      return;
    }
    setState(() => _spoken = null);
  }

  void _onPrompt(String shown, String sent) {
    _spokenTimer?.cancel();
    _spokenHoldDone = false;
    setState(() => _spoken = shown);
    final ms = (shown.length * 180).clamp(2200, 5000);
    _spokenTimer = Timer(Duration(milliseconds: ms), () {
      _spokenHoldDone = true;
      _releaseSpoken();
    });
    unawaited(
      widget.controller.sendMessage(sent, viaVoice: true, speakReply: true),
    );
  }

  @override
  void didUpdateWidget(_HerVoicePane oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_syncTicker);
      widget.controller.addListener(_syncTicker);
      _syncTicker();
    }
  }

  @override
  void dispose() {
    _spokenTimer?.cancel();
    widget.controller.removeListener(_syncTicker);
    _ticker.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.controller;
    final stateLine = c.isListening
        ? '● 正在聆听语音…'
        : c.isBusy
        ? '● 正在思考与查阅…'
        : c.isSpeaking
        ? '● 语音回复中（轻触可打断）'
        : '● 语音同频就绪';

    // 跟设计稿 .ai-her：圆环固定尺寸居中，底部是短句 + 半透明芯片 + 麦克风。
    // 回复再长也不进滚动区，避免把圆环顶出屏幕。
    final showingSpoken = _spoken != null;
    final voice = showingSpoken ? _spoken! : _herVoiceLine(c.herHeadline);
    final live = showingSpoken || c.isSpeaking;
    final hidePrompts =
        showingSpoken || c.isBusy || c.isSpeaking || c.isListening;
    final s = context.rcStyle;
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: RadialGradient(
          center: const Alignment(0, -0.16),
          radius: 1.05,
          colors: s.os1HerGradient,
          stops: const [0, 0.48, 1],
        ),
      ),
      child: Column(
        key: const Key('ai-her-pane'),
        children: [
          Text(
            stateLine,
            style: const TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              letterSpacing: 0.4,
              color: Color(0xD6FFF5EB),
            ),
          ),
          Expanded(
            child: LayoutBuilder(
              builder: (context, constraints) {
                final side = math.min(
                  constraints.maxWidth * 0.74,
                  math.min(constraints.maxHeight * 0.92, 300),
                );
                return Center(
                  child: GestureDetector(
                    key: const Key('ai-her-stage'),
                    onTap: () {
                      if (c.isSpeaking) {
                        unawaited(c.interruptSpeech());
                      } else {
                        unawaited(c.toggleListening());
                      }
                    },
                    child: SizedBox(
                      width: side.toDouble(),
                      height: side.toDouble(),
                      child: CustomPaint(
                        key: const Key('ai-her-canvas'),
                        painter: _HerWavePainter(
                          phase: _phase,
                          energy: c.voiceEnergy,
                          active: c.isListening || c.isSpeaking || c.isBusy,
                        ),
                        child: const SizedBox.expand(),
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
          Padding(
            padding: EdgeInsets.fromLTRB(22, 0, 22, widget.bottomPadding),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                _HerSpokenLine(text: voice, live: live),
                const SizedBox(height: 4),
                Text(
                  c.herSubline,
                  key: const Key('ai-her-sub'),
                  textAlign: TextAlign.center,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 11.5,
                    color: Color(0xB8FFF5EB),
                  ),
                ),
                if (!hidePrompts) ...[
                  const SizedBox(height: 10),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    alignment: WrapAlignment.center,
                    children: [
                      _promptChip(
                        key: const Key('ai-her-prompt-mood'),
                        label: '今天聊了哪些重点',
                        onTap: () => _onPrompt(
                          '今天聊了哪些重点',
                          '帮我梳理一下今天和最近录音里聊到的核心重点与待办',
                        ),
                      ),
                      _promptChip(
                        key: const Key('ai-her-prompt-walk'),
                        label: '看看今天状态',
                        onTap: () => _onPrompt(
                          '看看今天状态',
                          '查一下我今天和最近采集的健康数据与活动状态',
                        ),
                      ),
                      _promptChip(
                        key: const Key('ai-her-prompt-movie'),
                        label: '联网查个资料',
                        onTap: () => _onPrompt(
                          '联网查个资料',
                          '帮我联网查一下今天有哪些值得关注的科技新闻',
                        ),
                      ),
                    ],
                  ),
                ],
                const SizedBox(height: 12),
                GestureDetector(
                  key: const Key('ai-her-talk-btn'),
                  onTap: () => unawaited(c.toggleListening()),
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 150),
                    width: 58,
                    height: 58,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: c.isListening
                          ? const Color(0x52FFFFFF)
                          : const Color(0x2EFFFFFF),
                      border: Border.all(
                        color: c.isListening
                            ? Colors.white
                            : const Color(0x99FFF7EF),
                        width: 2,
                      ),
                    ),
                    child: Icon(
                      c.isListening ? Icons.stop_rounded : Icons.mic_rounded,
                      size: 26,
                      color: Colors.white,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _promptChip({
    required Key key,
    required String label,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      key: key,
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 7),
        decoration: BoxDecoration(
          color: const Color(0x26FFFFFF),
          borderRadius: BorderRadius.circular(999),
          border: Border.all(color: const Color(0x47FFFFFF)),
        ),
        child: Text(
          label,
          style: const TextStyle(
            fontSize: 12.5,
            fontWeight: FontWeight.w600,
            color: Color(0xFFFFF7EF),
          ),
        ),
      ),
    );
  }
}

class _HerSpokenLine extends StatefulWidget {
  const _HerSpokenLine({required this.text, required this.live});

  final String text;
  final bool live;

  @override
  State<_HerSpokenLine> createState() => _HerSpokenLineState();
}

class _HerSpokenLineState extends State<_HerSpokenLine> {
  final ScrollController _scroll = ScrollController();
  int _token = 0;

  static const _style = TextStyle(
    fontSize: 15,
    height: 1.45,
    fontWeight: FontWeight.w500,
    color: Color(0xFFFFF7EF),
  );

  @override
  void initState() {
    super.initState();
    _schedule();
  }

  @override
  void didUpdateWidget(covariant _HerSpokenLine oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.text != widget.text || oldWidget.live != widget.live) {
      _schedule();
    }
  }

  void _schedule() {
    final token = ++_token;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || token != _token || !_scroll.hasClients) return;
      _scroll.jumpTo(0);
      if (!widget.live) return;
      final max = _scroll.position.maxScrollExtent;
      if (max < 4) return;
      final ms = (widget.text.length * 150).clamp(1800, 14000);
      _scroll.animateTo(
        max,
        duration: Duration(milliseconds: ms),
        curve: Curves.linear,
      );
    });
  }

  @override
  void dispose() {
    _token++;
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.live) {
      return Text(
        '“${widget.text}”',
        key: const Key('ai-her-voice'),
        textAlign: TextAlign.center,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: _style,
      );
    }
    return SizedBox(
      key: const Key('ai-her-voice'),
      height: 46,
      child: SingleChildScrollView(
        controller: _scroll,
        physics: const NeverScrollableScrollPhysics(),
        child: Column(
          children: [
            const SizedBox(height: 46),
            Text(
              '“${widget.text}”',
              textAlign: TextAlign.center,
              style: _style,
            ),
            const SizedBox(height: 12),
          ],
        ),
      ),
    );
  }
}

String _herVoiceLine(String raw) {
  var text = raw.trim();
  if (text.startsWith('{') && text.contains('"reply"')) {
    try {
      final decoded = jsonDecode(text);
      if (decoded is Map && decoded['reply'] != null) {
        text = '${decoded['reply']}'.trim();
      }
    } catch (_) {
      final match = RegExp(
        r'"reply"\s*:\s*"((?:\\.|[^"\\])*)"',
      ).firstMatch(text);
      if (match != null) {
        text = match
            .group(1)!
            .replaceAll(r'\n', '\n')
            .replaceAll(r'\"', '"')
            .trim();
      }
    }
  }
  text = text.replaceAll(RegExp(r'[*#`~]'), '');
  text = text.replaceAll(RegExp(r'^\s*[-•·]+\s*', multiLine: true), '');
  final para = text.split(RegExp(r'\n\s*\n')).first.trim();
  if (para.isNotEmpty) text = para;
  text = text.replaceAll(RegExp(r'\s+'), ' ').trim();
  return text;
}

class _HerWavePainter extends CustomPainter {
  const _HerWavePainter({
    required this.phase,
    required this.energy,
    required this.active,
  });

  final double phase;
  final double energy;
  final bool active;

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final baseR = size.width * 0.32;

    final glowPaint = Paint()
      ..shader = RadialGradient(
        colors: [
          const Color(0x33FFE8D0),
          const Color(0x28FFBE91),
          const Color(0x00FF784B),
        ],
      ).createShader(Rect.fromCircle(center: center, radius: baseR * 1.45));
    canvas.drawCircle(center, baseR * 1.45, glowPaint);

    for (var s = 0; s < 5; s++) {
      final path = Path();
      final pOffset = s * 1.15;
      final breathe = 2.6 + 1.4 * math.sin(phase * 0.45);
      final amp = (active ? (3.4 + energy * 8) : breathe) * (1 - s * 0.09);
      const steps = 64;
      for (var i = 0; i <= steps; i++) {
        final a = (i / steps) * math.pi * 2;
        final w1 = math.sin(a * 3 + phase * 1.4 + pOffset) * amp;
        final w2 = math.cos(a * 5 - phase * 1.9 + pOffset * 1.3) * (amp * 0.5);
        final w3 = math.sin(a * 2 + phase * 0.8 - pOffset) * (amp * 0.35);
        final r = baseR + (s - 2) * 3.5 + w1 + w2 + w3;
        final pt = Offset(
          center.dx + math.cos(a) * r,
          center.dy + math.sin(a) * r,
        );
        if (i == 0) {
          path.moveTo(pt.dx, pt.dy);
        } else {
          path.lineTo(pt.dx, pt.dy);
        }
      }
      path.close();
      final ringPaint = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = (10 - s * 1.4).toDouble()
        ..color = Colors.white.withValues(
          alpha: (0.92 - s * 0.14).clamp(0.15, 0.95),
        );
      canvas.drawPath(path, ringPaint);
    }
  }

  @override
  bool shouldRepaint(_HerWavePainter old) =>
      old.phase != phase || old.energy != energy || old.active != active;
}

// ── 轻聊（文本对话 + 快捷语音输入 + TTS 按需播报）───────────────────

class _HumanChatPane extends StatefulWidget {
  const _HumanChatPane({
    required this.controller,
    required this.bottomPadding,
    required this.onOpenHistory,
  });

  final AgentChatController controller;
  final double bottomPadding;
  final VoidCallback onOpenHistory;

  @override
  State<_HumanChatPane> createState() => _HumanChatPaneState();
}

class _HumanChatPaneState extends State<_HumanChatPane> {
  final TextEditingController _inputCtrl = TextEditingController();
  final ScrollController _scrollCtrl = ScrollController();
  String _lastSessionId = '';
  String? _lastTailMessageId;
  bool _wasBusy = false;

  @override
  void initState() {
    super.initState();
    _syncTrackers();
    widget.controller.addListener(_onChanged);
  }

  @override
  void didUpdateWidget(covariant _HumanChatPane oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_onChanged);
      _syncTrackers();
      widget.controller.addListener(_onChanged);
    }
  }

  void _syncTrackers() {
    _lastSessionId = widget.controller.activeSessionId;
    _lastTailMessageId = widget.controller.messages.lastOrNull?.id;
    _wasBusy = widget.controller.isBusy;
  }

  void _onChanged() {
    if (!mounted) return;
    final c = widget.controller;
    if (c.isListening &&
        c.partialSpeech.trim().isNotEmpty &&
        _inputCtrl.text != c.partialSpeech) {
      _inputCtrl.text = c.partialSpeech;
      _inputCtrl.selection = TextSelection.collapsed(
        offset: _inputCtrl.text.length,
      );
    }

    final sessionChanged = _lastSessionId != c.activeSessionId;
    final tailId = c.messages.lastOrNull?.id;
    final newTailAdded = tailId != null && tailId != _lastTailMessageId;
    final becameBusy = !_wasBusy && c.isBusy;

    _lastSessionId = c.activeSessionId;
    _lastTailMessageId = tailId;
    _wasBusy = c.isBusy;

    // 仅在切换会话或底部新增消息/开始回复时滚到底部；向上翻加载更早消息保持当前阅读位置。
    if (sessionChanged) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || !_scrollCtrl.hasClients) return;
        _scrollCtrl.jumpTo(0.0);
      });
    } else if (newTailAdded || becameBusy) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || !_scrollCtrl.hasClients) return;
        unawaited(
          _scrollCtrl.animateTo(
            0.0,
            duration: const Duration(milliseconds: 220),
            curve: Curves.easeOut,
          ),
        );
      });
    }
  }

  bool _handleScrollNotification(
    ScrollNotification notification,
    AgentChatController c,
  ) {
    if (notification.metrics.axis != Axis.vertical) return false;
    if (!c.hasMoreOlderMessages || c.isLoadingOlder) return false;
    if (notification is! ScrollUpdateNotification &&
        notification is! OverscrollNotification) {
      return false;
    }
    final metrics = notification.metrics;
    final nearTop =
        (metrics.maxScrollExtent > 0 &&
            metrics.pixels >= metrics.maxScrollExtent - 120) ||
        (metrics.maxScrollExtent == 0 && metrics.pixels > 24);
    final overscrolledTop =
        notification is OverscrollNotification && notification.overscroll > 0;
    if (nearTop || overscrolledTop) {
      unawaited(c.loadOlderMessages());
    }
    return false;
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onChanged);
    _inputCtrl.dispose();
    _scrollCtrl.dispose();
    super.dispose();
  }

  void _submit() {
    final text = _inputCtrl.text.trim();
    if (text.isEmpty || widget.controller.isBusy) return;
    _inputCtrl.clear();
    unawaited(widget.controller.sendMessage(text));
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.controller;
    final rc = context.rc;
    final s = context.rcStyle;
    final isAirCoral = s.styleId == RCUIStyleId.air;
    final isBraunDark = s.styleId == RCUIStyleId.braunField;
    final isDarkCanvas = rc.isDark || isAirCoral || isBraunDark;
    final feedBg = isAirCoral ? Colors.transparent : s.os1ChatBg;
    final mutedText = isAirCoral
        ? const Color(0xE6FFFFFF)
        : (isBraunDark ? const Color(0xFFA1A098) : rc.sec);
    final composerBg = isAirCoral
        ? Colors.transparent
        : (isBraunDark ? const Color(0xFF141513) : rc.card);
    final composerBorder = isAirCoral
        ? const Color(0x33FFFFFF)
        : (isBraunDark ? const Color(0xFF282824) : rc.sep);
    final inputFill = isAirCoral
        ? Colors.white.withValues(alpha: 0.94)
        : (isBraunDark ? const Color(0xFF22221E) : s.os1ChatBg);
    final inputTextColor = isAirCoral
        ? const Color(0xFF0F172A)
        : (isBraunDark ? Colors.white : rc.label);
    final inputHintColor = isAirCoral
        ? const Color(0xFF64748B)
        : (isBraunDark ? const Color(0xFF8A8980) : rc.sec);
    final sendBg = isAirCoral ? const Color(0xFF0F172A) : s.accent;
    final sendFg = isAirCoral
        ? Colors.white
        : (isBraunDark ? const Color(0xFF121210) : s.accentFg);
    return Column(
      key: const Key('ai-chat-pane'),
      children: [
        Expanded(
          child: Container(
            color: feedBg,
            child: (c.messages.isEmpty && !c.isBusy)
                ? SingleChildScrollView(
                    key: const Key('ai-chat-feed'),
                    physics: const AlwaysScrollableScrollPhysics(),
                    padding: const EdgeInsets.fromLTRB(
                      16,
                      14,
                      16,
                      RCDims.pageBottomPad,
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Center(
                          child: Padding(
                            padding: const EdgeInsets.only(bottom: 14),
                            child: Text(
                              '有事直接问我 · 可检索录音记录、健康状态与联网资料',
                              style: TextStyle(
                                fontSize: 11.5,
                                color: mutedText,
                              ),
                            ),
                          ),
                        ),
                        if (c.justStartedNewSession) _newChatBanner(rc, s),
                        _emptyGuideCard(
                          rc,
                          s,
                          isAirCoral: isAirCoral,
                          isBraunDark: isBraunDark,
                        ),
                        if (c.sessions.isNotEmpty && !c.justStartedNewSession)
                          Padding(
                            padding: const EdgeInsets.only(top: 2),
                            child: Center(
                              child: Text(
                                '已有 ${c.sessions.length} 段历史对话 · 从右边缘左滑可查看并继续聊',
                                style: TextStyle(
                                  fontSize: 11.5,
                                  color: mutedText,
                                ),
                              ),
                            ),
                          ),
                        if (c.errorMessage != null)
                          _buildErrorBox(rc, c.errorMessage!),
                      ],
                    ),
                  )
                : NotificationListener<ScrollNotification>(
                    onNotification: (n) => _handleScrollNotification(n, c),
                    child: ListView.builder(
                      key: const Key('ai-chat-feed'),
                      controller: _scrollCtrl,
                      reverse: true,
                      addAutomaticKeepAlives: false,
                      physics: const AlwaysScrollableScrollPhysics(),
                      padding: const EdgeInsets.fromLTRB(
                        16,
                        14,
                        16,
                        RCDims.pageBottomPad,
                      ),
                      itemCount:
                          (c.errorMessage != null ? 1 : 0) +
                          (c.isBusy ? 1 : 0) +
                          c.messages.length +
                          1,
                      itemBuilder: (context, index) => _buildFeedItem(c, rc, s, index),
                    ),
                  ),
          ),
        ),
        Container(
          height: 44,
          color: feedBg,
          child: ListView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
            children: [
              _quickChip(
                rc,
                s,
                key: const Key('ai-quick-1'),
                label: '查一下最近待办',
                isDarkCanvas: isDarkCanvas,
                isAirCoral: isAirCoral,
                isBraunDark: isBraunDark,
                onTap: () => unawaited(c.sendMessage('帮我查一下最近录音和总结里记了哪些待办事项')),
              ),
              const SizedBox(width: 8),
              _quickChip(
                rc,
                s,
                key: const Key('ai-quick-2'),
                label: '今天聊了什么',
                isDarkCanvas: isDarkCanvas,
                isAirCoral: isAirCoral,
                isBraunDark: isBraunDark,
                onTap: () => unawaited(c.sendMessage('帮我回顾一下今天录音里主要讨论了什么内容')),
              ),
              const SizedBox(width: 8),
              _quickChip(
                rc,
                s,
                key: const Key('ai-quick-3'),
                label: '看看今天状态',
                isDarkCanvas: isDarkCanvas,
                isAirCoral: isAirCoral,
                isBraunDark: isBraunDark,
                onTap: () => unawaited(c.sendMessage('看看我今天和最近采集的健康数据与活动状态')),
              ),
            ],
          ),
        ),
        Container(
          padding: EdgeInsets.fromLTRB(12, 8, 12, 10 + widget.bottomPadding),
          decoration: BoxDecoration(
            color: composerBg,
            border: Border(top: BorderSide(color: composerBorder)),
          ),
          child: Row(
            children: [
              IconButton(
                key: const Key('ai-chat-stt-btn'),
                tooltip: c.isListening ? '停止语音输入' : '语音转文字输入',
                onPressed: c.isBusy
                    ? null
                    : () => unawaited(c.toggleListening()),
                icon: Icon(
                  c.isListening ? Icons.stop_circle : Icons.mic_none_rounded,
                  color: c.isListening ? s.accent : mutedText,
                ),
              ),
              Expanded(
                child: TextField(
                  key: const Key('ai-chat-input'),
                  controller: _inputCtrl,
                  textInputAction: TextInputAction.send,
                  onSubmitted: (_) => _submit(),
                  style: TextStyle(color: inputTextColor),
                  decoration: InputDecoration(
                    isDense: true,
                    filled: true,
                    fillColor: inputFill,
                    hintText: '像发微信一样说一句…',
                    hintStyle: TextStyle(
                      fontSize: 14,
                      color: inputHintColor,
                    ),
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 10,
                    ),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(20),
                      borderSide: BorderSide(
                        color: isAirCoral ? Colors.transparent : composerBorder,
                      ),
                    ),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(20),
                      borderSide: BorderSide(
                        color: isAirCoral ? Colors.transparent : composerBorder,
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              FilledButton(
                key: const Key('ai-chat-send'),
                onPressed: c.isBusy ? null : _submit,
                style: FilledButton.styleFrom(
                  backgroundColor: sendBg,
                  foregroundColor: sendFg,
                  shape: const StadiumBorder(),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 10,
                  ),
                ),
                child: const Text(
                  '发送',
                  style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildFeedItem(
    AgentChatController c,
    RCColorScheme rc,
    RCStyleSpec s,
    int index,
  ) {
    var cursor = index;
    if (c.errorMessage != null) {
      if (cursor == 0) return _buildErrorBox(rc, c.errorMessage!);
      cursor--;
    }
    if (c.isBusy) {
      if (cursor == 0) return const _TypingBubble();
      cursor--;
    }
    if (cursor < c.messages.length) {
      final msgIdx = c.messages.length - 1 - cursor;
      final m = c.messages[msgIdx];
      return _ChatBubble(
        key: ValueKey('bubble-${m.id}'),
        index: msgIdx,
        message: m,
        onSpeak: m.role == 'assistant'
            ? () => unawaited(c.speakText(m.text))
            : null,
      );
    }
    return _buildTopFeedHeader(c, rc);
  }

  Widget _buildTopFeedHeader(AgentChatController c, RCColorScheme rc) {
    if (c.isLoadingOlder) {
      return Padding(
        key: const Key('ai-chat-loading-older'),
        padding: const EdgeInsets.only(bottom: 14),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            SizedBox(
              width: 14,
              height: 14,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: rc.sec,
              ),
            ),
            const SizedBox(width: 8),
            Text(
              '正在加载更早记录…',
              style: TextStyle(fontSize: 11.5, color: rc.sec),
            ),
          ],
        ),
      );
    }
    if (c.hasMoreOlderMessages) {
      return Padding(
        padding: const EdgeInsets.only(bottom: 14),
        child: Center(
          child: InkWell(
            key: const Key('ai-chat-load-more'),
            borderRadius: BorderRadius.circular(999),
            onTap: () => unawaited(c.loadOlderMessages()),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
              decoration: BoxDecoration(
                color: rc.card,
                borderRadius: BorderRadius.circular(999),
                border: Border.all(color: rc.sep),
              ),
              child: Text(
                '向上滑动或轻点加载更早记录',
                style: TextStyle(fontSize: 11.5, color: rc.sec),
              ),
            ),
          ),
        ),
      );
    }
    return Center(
      child: Padding(
        padding: const EdgeInsets.only(bottom: 14),
        child: Text(
          '有事直接问我 · 可检索录音记录、健康状态与联网资料',
          style: TextStyle(fontSize: 11.5, color: rc.sec),
        ),
      ),
    );
  }

  Widget _buildErrorBox(RCColorScheme rc, String message) {
    return Container(
      key: const Key('ai-chat-error'),
      margin: const EdgeInsets.only(top: 8, bottom: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: rc.danger.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: rc.danger.withValues(alpha: 0.32)),
      ),
      child: Text(
        message,
        style: TextStyle(
          fontSize: 13,
          height: 1.45,
          color: rc.danger,
        ),
      ),
    );
  }

  Widget _newChatBanner(RCColorScheme rc, RCStyleSpec s) {
    return Container(
      key: const Key('ai-new-chat-banner'),
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
      decoration: BoxDecoration(
        color: s.accentSoft,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: s.accent.withValues(alpha: 0.3)),
      ),
      child: Row(
        children: [
          Icon(
            Icons.auto_awesome_rounded,
            size: 16,
            color: s.accent,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              '已开启新对话 · 上一段对话已存入历史，从右边缘左滑可查看或继续聊',
              style: TextStyle(
                fontSize: 12.5,
                height: 1.4,
                color: rc.label,
              ),
            ),
          ),
          const SizedBox(width: 8),
          TextButton(
            key: const Key('ai-new-chat-open-history'),
            onPressed: widget.onOpenHistory,
            style: TextButton.styleFrom(
              foregroundColor: s.accent,
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              minimumSize: Size.zero,
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              textStyle: const TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
            ),
            child: const Text('查看历史'),
          ),
        ],
      ),
    );
  }

  Widget _emptyGuideCard(
    RCColorScheme rc,
    RCStyleSpec s, {
    bool isAirCoral = false,
    bool isBraunDark = false,
  }) {
    final bg = isAirCoral
        ? Colors.white.withValues(alpha: 0.20)
        : (isBraunDark ? const Color(0xFF242420) : rc.card);
    final border = isAirCoral
        ? Colors.white.withValues(alpha: 0.35)
        : (isBraunDark ? const Color(0xFF3C3C35) : rc.sep);
    final fg = (isAirCoral || isBraunDark) ? const Color(0xFFF4F3EE) : rc.ink;
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(s.cardRadius + 2),
        border: Border.all(color: border),
      ),
      child: Text(
        '直接问我任何事情：比如“昨天下午那场讨论决定了什么”“查一下最近健康数据”，或者让我顺手帮你联网搜索、沉淀一条常用 Skill。',
        style: TextStyle(fontSize: 13.5, height: 1.55, color: fg),
      ),
    );
  }

  Widget _quickChip(
    RCColorScheme rc,
    RCStyleSpec s, {
    required Key key,
    required String label,
    bool isDarkCanvas = false,
    bool isAirCoral = false,
    bool isBraunDark = false,
    required VoidCallback onTap,
  }) {
    final bg = isAirCoral
        ? Colors.white.withValues(alpha: 0.18)
        : (isBraunDark ? const Color(0xFF22221E) : rc.card);
    final border = isAirCoral
        ? Colors.white.withValues(alpha: 0.45)
        : (isBraunDark ? const Color(0xFF3C3C35) : rc.sep);
    final fg = (isAirCoral || isBraunDark) ? const Color(0xFFF4F3EE) : rc.ink;
    return ActionChip(
      key: key,
      onPressed: onTap,
      backgroundColor: bg,
      side: BorderSide(color: border),
      padding: const EdgeInsets.symmetric(horizontal: 6),
      labelStyle: TextStyle(fontSize: 12, color: fg),
      label: Text(label),
    );
  }
}

class _ChatBubble extends StatelessWidget {
  const _ChatBubble({
    super.key,
    required this.index,
    required this.message,
    this.onSpeak,
  });

  final int index;
  final AgentChatMessage message;
  final VoidCallback? onSpeak;

  @override
  Widget build(BuildContext context) {
    final c = context.rc;
    final s = context.rcStyle;
    final isMe = message.role == 'user';
    final Color bubbleBg;
    final Color bubbleFg;
    final Border? bubbleBorder;
    switch (s.styleId) {
      case RCUIStyleId.braunField:
        bubbleBg = isMe ? const Color(0xFFFF5514) : const Color(0xFF242420);
        bubbleFg = isMe ? const Color(0xFF121210) : const Color(0xFFF4F3EE);
        bubbleBorder = null;
      case RCUIStyleId.chronos:
        bubbleBg = isMe ? const Color(0xFF1D4ED8) : Colors.white;
        bubbleFg = isMe ? Colors.white : const Color(0xFF111318);
        bubbleBorder = isMe ? null : Border.all(color: const Color(0xFFE2E6EE));
      case RCUIStyleId.folio:
        bubbleBg = isMe ? const Color(0xFFA62B21) : Colors.white;
        bubbleFg = isMe ? const Color(0xFFF7F2E8) : const Color(0xFF1C1917);
        bubbleBorder = isMe ? null : Border.all(color: const Color(0xFFDDD4C3));
      case RCUIStyleId.nocturne:
        bubbleBg = isMe ? const Color(0xFFF5A623) : const Color(0xFF12141A);
        bubbleFg = isMe ? const Color(0xFF111214) : const Color(0xFFF3F4F6);
        bubbleBorder = isMe ? null : Border.all(color: const Color(0xFF1E222B));
      case RCUIStyleId.air:
        bubbleBg = isMe ? Colors.white : Colors.white.withValues(alpha: 0.22);
        bubbleFg = isMe ? const Color(0xFF0F172A) : Colors.white;
        bubbleBorder = null;
      case RCUIStyleId.warmPaper:
        bubbleBg = isMe ? c.label : c.card;
        bubbleFg = isMe ? c.onLabel : c.label;
        bubbleBorder = isMe ? null : Border.all(color: c.sep);
    }
    return Align(
      alignment: isMe ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        key: Key('ai-msg-$index'),
        constraints: BoxConstraints(
          maxWidth: MediaQuery.sizeOf(context).width * 0.78,
        ),
        margin: const EdgeInsets.only(bottom: 12),
        child: Column(
          crossAxisAlignment: isMe
              ? CrossAxisAlignment.end
              : CrossAxisAlignment.start,
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              decoration: BoxDecoration(
                color: bubbleBg,
                borderRadius: BorderRadius.only(
                  topLeft: const Radius.circular(16),
                  topRight: const Radius.circular(16),
                  bottomLeft: Radius.circular(isMe ? 16 : 5),
                  bottomRight: Radius.circular(isMe ? 5 : 16),
                ),
                border: bubbleBorder,
              ),
              child: SelectableText(
                message.text,
                style: TextStyle(
                  fontSize: 14.5,
                  height: 1.5,
                  color: bubbleFg,
                ),
              ),
            ),
            if (message.reaction != null && message.reaction!.isNotEmpty)
              Container(
                key: Key('ai-react-badge-$index'),
                margin: const EdgeInsets.only(top: 4),
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                decoration: BoxDecoration(
                  color: c.card,
                  borderRadius: BorderRadius.circular(999),
                  border: Border.all(color: c.sep),
                ),
                child: Text(
                  message.reaction!,
                  style: TextStyle(fontSize: 11, color: c.sec),
                ),
              ),
            if (!isMe && onSpeak != null)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: InkWell(
                  key: Key('ai-speak-btn-$index'),
                  onTap: onSpeak,
                  borderRadius: BorderRadius.circular(999),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 6,
                      vertical: 2,
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Icons.volume_up_outlined,
                          size: 14,
                          color: c.sec,
                        ),
                        const SizedBox(width: 3),
                        Text(
                          '朗读',
                          style: TextStyle(fontSize: 11, color: c.sec),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _TypingBubble extends StatelessWidget {
  const _TypingBubble();

  @override
  Widget build(BuildContext context) {
    final c = context.rc;
    final s = context.rcStyle;
    final (Color bg, Color borderCol, Color dotCol) = switch (s.styleId) {
      RCUIStyleId.air => (
        const Color(0x38FFFFFF),
        const Color(0x45FFFFFF),
        Colors.white,
      ),
      RCUIStyleId.braunField => (
        const Color(0xFF242420),
        const Color(0xFF35352E),
        const Color(0xFF9E9D93),
      ),
      _ => (c.card, c.sep, c.sec),
    };
    return Align(
      key: const Key('ai-typing-bubble'),
      alignment: Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.only(bottom: 12),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: borderCol),
        ),
        child: Text(
          '• • •',
          style: TextStyle(
            fontSize: 15,
            letterSpacing: 2,
            color: dotCol,
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
    );
  }
}

class _ChatHistoryDrawer extends StatelessWidget {
  const _ChatHistoryDrawer({
    required this.controller,
    required this.topPadding,
    required this.bottomPadding,
    required this.onClose,
  });

  final AgentChatController controller;
  final double topPadding;
  final double bottomPadding;
  final VoidCallback onClose;

  Future<void> _confirmDelete(
    BuildContext context,
    AgentChatSession session,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除这条历史对话？'),
        content: Text(
          '删除「${session.title}」后将无法恢复该对话记录。',
          style: const TextStyle(fontSize: 13.5, height: 1.45),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('取消'),
          ),
          TextButton(
            key: const Key('ai-session-delete-confirm'),
            style: TextButton.styleFrom(foregroundColor: context.rc.danger),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await controller.deleteSession(session.id);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.rc;
    final s = context.rcStyle;
    final sessions = controller.sessions;
    final now = controller.now();
    return DecoratedBox(
      key: const Key('ai-history-drawer'),
      decoration: BoxDecoration(
        color: c.bg,
        border: Border(left: BorderSide(color: c.sep)),
        boxShadow: const [
          BoxShadow(
            color: Color(0x22000000),
            blurRadius: 24,
            offset: Offset(-6, 0),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: EdgeInsets.fromLTRB(16, topPadding + 12, 12, 12),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '历史对话',
                        style: TextStyle(
                          fontSize: 17,
                          fontWeight: FontWeight.w700,
                          color: c.label,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        '点击可回看并继续聊',
                        style: TextStyle(fontSize: 11.5, color: c.sec),
                      ),
                    ],
                  ),
                ),
                TextButton(
                  key: const Key('ai-history-new-chat'),
                  onPressed: controller.isBusy
                      ? null
                      : () {
                          controller.startNewSession();
                          onClose();
                        },
                  style: TextButton.styleFrom(
                    backgroundColor: s.accentSoft,
                    foregroundColor: s.accent,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 7,
                    ),
                    minimumSize: Size.zero,
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    shape: const StadiumBorder(),
                    textStyle: const TextStyle(
                      fontSize: 12.5,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  child: const Text('+ 新对话'),
                ),
              ],
            ),
          ),
          Divider(height: 1, thickness: 1, color: c.sep),
          Expanded(
            child: sessions.isEmpty
                ? SingleChildScrollView(
                    key: const Key('ai-history-list'),
                    padding: EdgeInsets.fromLTRB(
                      16,
                      28,
                      16,
                      RCDims.pageBottomPad + bottomPadding,
                    ),
                    child: Column(
                      children: [
                        Icon(
                          Icons.chat_bubble_outline_rounded,
                          size: 28,
                          color: c.ax,
                        ),
                        const SizedBox(height: 10),
                        Text(
                          '暂无历史对话',
                          style: TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                            color: c.label,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          '每段轻聊都会自动保存在这里，随时可切换回来继续聊',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            fontSize: 12,
                            height: 1.5,
                            color: c.sec,
                          ),
                        ),
                      ],
                    ),
                  )
                : ListView.separated(
                    key: const Key('ai-history-list'),
                    padding: EdgeInsets.fromLTRB(
                      12,
                      12,
                      12,
                      RCDims.pageBottomPad + bottomPadding,
                    ),
                    itemCount: sessions.length,
                    separatorBuilder: (_, _) => const SizedBox(height: 8),
                    itemBuilder: (context, index) {
                      final s = sessions[index];
                      final isCurrent = s.id == controller.activeSessionId;
                      return _SessionHistoryCard(
                        session: s,
                        isCurrent: isCurrent,
                        timeLabel: _formatSessionTime(s.updatedAtMs, now),
                        canSwitch: !controller.isBusy,
                        canDelete: !(controller.isBusy && isCurrent),
                        onTap: () {
                          unawaited(controller.switchSession(s.id));
                          onClose();
                        },
                        onDelete: () => unawaited(_confirmDelete(context, s)),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}

class _SessionHistoryCard extends StatelessWidget {
  const _SessionHistoryCard({
    required this.session,
    required this.isCurrent,
    required this.timeLabel,
    required this.canSwitch,
    required this.canDelete,
    required this.onTap,
    required this.onDelete,
  });

  final AgentChatSession session;
  final bool isCurrent;
  final String timeLabel;
  final bool canSwitch;
  final bool canDelete;
  final VoidCallback onTap;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final c = context.rc;
    final s = context.rcStyle;
    return Material(
      color: isCurrent ? s.accentSoft : c.card,
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        key: Key('ai-session-item-${session.id}'),
        onTap: canSwitch ? onTap : null,
        borderRadius: BorderRadius.circular(14),
        child: Container(
          padding: const EdgeInsets.fromLTRB(12, 11, 10, 9),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
              color: isCurrent ? s.accent.withValues(alpha: 0.45) : c.sep,
              width: isCurrent ? 1.2 : 1.0,
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  if (isCurrent) ...[
                    Container(
                      margin: const EdgeInsets.only(right: 6),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 6,
                        vertical: 2,
                      ),
                      decoration: BoxDecoration(
                        color: s.accentSoft,
                        borderRadius: BorderRadius.circular(999),
                      ),
                      child: Text(
                        '当前',
                        style: TextStyle(
                          fontSize: 10.5,
                          fontWeight: FontWeight.w600,
                          color: s.accent,
                        ),
                      ),
                    ),
                  ],
                  Expanded(
                    child: Text(
                      session.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        color: c.label,
                      ),
                    ),
                  ),
                  if (timeLabel.isNotEmpty) ...[
                    const SizedBox(width: 8),
                    Text(
                      timeLabel,
                      style: TextStyle(fontSize: 11, color: c.sec),
                    ),
                  ],
                ],
              ),
              if (session.preview.isNotEmpty) ...[
                const SizedBox(height: 5),
                Text(
                  session.preview,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 12.5,
                    height: 1.4,
                    color: c.ink,
                  ),
                ),
              ],
              const SizedBox(height: 6),
              Row(
                children: [
                  Text(
                    '共 ${session.messageCount} 条消息',
                    style: TextStyle(fontSize: 11, color: c.sec),
                  ),
                  const Spacer(),
                  IconButton(
                    key: Key('ai-session-delete-${session.id}'),
                    tooltip: '删除对话',
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(
                      minWidth: 28,
                      minHeight: 28,
                    ),
                    onPressed: canDelete ? onDelete : null,
                    icon: Icon(
                      Icons.delete_outline_rounded,
                      size: 17,
                      color: c.sec,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

String _formatSessionTime(int updatedAtMs, DateTime now) {
  if (updatedAtMs <= 0) return '';
  final dt = DateTime.fromMillisecondsSinceEpoch(updatedAtMs);
  final diff = now.difference(dt);
  if (diff.inSeconds < 60 && diff.inSeconds >= -60) return '刚刚';
  final today = DateTime(now.year, now.month, now.day);
  final targetDay = DateTime(dt.year, dt.month, dt.day);
  final dayDiff = today.difference(targetDay).inDays;
  final hh = dt.hour.toString().padLeft(2, '0');
  final mm = dt.minute.toString().padLeft(2, '0');
  if (dayDiff == 0) return '今天 $hh:$mm';
  if (dayDiff == 1) return '昨天 $hh:$mm';
  if (dt.year == now.year) return '${dt.month}月${dt.day}日';
  return '${dt.year}/${dt.month}/${dt.day}';
}
