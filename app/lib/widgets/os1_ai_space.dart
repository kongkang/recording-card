/// OS1 全屏 AI 空间浮层 —— 「沉浸通话」（《Her》声波圆环 + 系统 STT/TTS）与「轻聊」双模式。
///
/// 性能与测试原则：
/// - 声波圆环 Ticker 仅在面板打开且处于 [Os1Mode.her] 时运行，切走或关闭立即停表，
///   不拖垮后台帧率，也不会阻塞 Widget 测试的 `pumpAndSettle`；
/// - 轻聊等待态仅显示极简三点跳动，不暴露冰冷工具链或思考链。
library;

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../core/theme/tokens.dart';
import '../services/agent/agent_chat_controller.dart';
import '../services/agent/agent_models.dart';

class Os1AiSpaceOverlay extends StatelessWidget {
  const Os1AiSpaceOverlay({super.key, required this.controller});

  final AgentChatController controller;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        if (!controller.isOpen) return const SizedBox.shrink();
        final isHer = controller.mode == Os1Mode.her;
        final bg = isHer ? const Color(0xFFD64933) : const Color(0xFFF5F4F0);
        final topPadding = MediaQuery.paddingOf(context).top;
        final bottomPadding = MediaQuery.paddingOf(context).bottom;
        return Positioned.fill(
          child: Material(
            key: const Key('ai-space'),
            color: bg,
            child: Column(
              children: [
                SizedBox(height: topPadding),
                _TopBar(controller: controller, isHer: isHer),
                Expanded(
                  child: isHer
                      ? _HerVoicePane(
                          controller: controller,
                          bottomPadding: bottomPadding,
                        )
                      : _HumanChatPane(
                          controller: controller,
                          bottomPadding: bottomPadding,
                        ),
                ),
              ],
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

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 8),
      child: Row(
        children: [
          TextButton(
            key: const Key('ai-space-close'),
            onPressed: controller.close,
            style: TextButton.styleFrom(
              backgroundColor: isHer
                  ? const Color(0x2EFFFFFF)
                  : const Color(0x0F000000),
              foregroundColor: isHer ? Colors.white : RCColors.label,
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
              minimumSize: Size.zero,
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              shape: const StadiumBorder(),
              textStyle: const TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
              ),
            ),
            child: const Text('收起'),
          ),
          const Spacer(),
          Container(
            padding: const EdgeInsets.all(3),
            decoration: BoxDecoration(
              color: isHer
                  ? const Color(0x26FFFFFF)
                  : const Color(0x0F000000),
              borderRadius: BorderRadius.circular(999),
              border: Border.all(
                color: isHer ? const Color(0x38FFFFFF) : RCColors.sep,
              ),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                _modeBtn(
                  key: const Key('ai-mode-her'),
                  label: '沉浸通话',
                  active: isHer,
                  isHerTheme: isHer,
                  onTap: () => controller.setMode(Os1Mode.her),
                ),
                _modeBtn(
                  key: const Key('ai-mode-chat'),
                  label: '轻聊',
                  active: !isHer,
                  isHerTheme: isHer,
                  onTap: () => controller.setMode(Os1Mode.chat),
                ),
              ],
            ),
          ),
          const Spacer(),
          IconButton(
            key: const Key('ai-chat-clear'),
            tooltip: '清空对话',
            onPressed: controller.isBusy
                ? null
                : () => unawaited(controller.clearHistory()),
            icon: Icon(
              Icons.refresh_rounded,
              size: 20,
              color: isHer ? const Color(0xCCFFFFFF) : RCColors.sec,
            ),
          ),
        ],
      ),
    );
  }

  Widget _modeBtn({
    required Key key,
    required String label,
    required bool active,
    required bool isHerTheme,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      key: key,
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
        decoration: BoxDecoration(
          color: active ? Colors.white : Colors.transparent,
          borderRadius: BorderRadius.circular(999),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 12.5,
            fontWeight: active ? FontWeight.w700 : FontWeight.w500,
            color: active
                ? (isHerTheme ? const Color(0xFFC5361B) : RCColors.label)
                : (isHerTheme ? const Color(0xE6FFFFFF) : RCColors.sec),
          ),
        ),
      ),
    );
  }
}

// ── 沉浸通话（《Her》OS1 声波圆环 + 系统 STT/TTS）──────────────────

class _HerVoicePane extends StatefulWidget {
  const _HerVoicePane({
    required this.controller,
    required this.bottomPadding,
  });

  final AgentChatController controller;
  final double bottomPadding;

  @override
  State<_HerVoicePane> createState() => _HerVoicePaneState();
}

class _HerVoicePaneState extends State<_HerVoicePane>
    with SingleTickerProviderStateMixin {
  late final Ticker _ticker;
  double _phase = 0;

  @override
  void initState() {
    super.initState();
    _ticker = createTicker((elapsed) {
      if (!mounted) return;
      final boost = widget.controller.isListening || widget.controller.isSpeaking
          ? 0.055
          : (widget.controller.isBusy ? 0.04 : 0.02);
      setState(() {
        _phase += boost + widget.controller.voiceEnergy * 0.025;
      });
    });
    _syncTicker();
    widget.controller.addListener(_syncTicker);
  }

  void _syncTicker() {
    final shouldAnimate =
        widget.controller.isOpen &&
        widget.controller.mode == Os1Mode.her &&
        (widget.controller.isListening ||
            widget.controller.isSpeaking ||
            widget.controller.isBusy);
    if (shouldAnimate && !_ticker.isActive) {
      _ticker.start();
    } else if (!shouldAnimate && _ticker.isActive) {
      _ticker.stop();
    }
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

    return SingleChildScrollView(
      key: const Key('ai-her-pane'),
      padding: EdgeInsets.fromLTRB(
        22,
        8,
        22,
        RCDims.pageBottomPad + widget.bottomPadding,
      ),
      child: Column(
        children: [
          Text(
            stateLine,
            style: const TextStyle(
              fontSize: 12.5,
              fontWeight: FontWeight.w600,
              color: Color(0xE6FFF7EF),
            ),
          ),
          const SizedBox(height: 18),
          GestureDetector(
            key: const Key('ai-her-stage'),
            onTap: () {
              if (c.isSpeaking) {
                unawaited(c.interruptSpeech());
              } else {
                unawaited(c.toggleListening());
              }
            },
            child: SizedBox(
              width: 240,
              height: 240,
              child: CustomPaint(
                key: const Key('ai-her-canvas'),
                painter: _HerWavePainter(
                  phase: _phase,
                  energy: c.voiceEnergy,
                  active: c.isListening || c.isSpeaking || c.isBusy,
                ),
              ),
            ),
          ),
          const SizedBox(height: 18),
          Text(
            '“${c.herHeadline}”',
            key: const Key('ai-her-voice'),
            textAlign: TextAlign.center,
            style: const TextStyle(
              fontSize: 17,
              height: 1.5,
              fontWeight: FontWeight.w600,
              color: Colors.white,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            c.herSubline,
            key: const Key('ai-her-sub'),
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 12.5, color: Color(0xCCFFF7EF)),
          ),
          const SizedBox(height: 22),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            alignment: WrapAlignment.center,
            children: [
              _promptChip(
                key: const Key('ai-her-prompt-mood'),
                label: '今天聊了哪些重点',
                onTap: () => unawaited(
                  c.sendMessage(
                    '帮我梳理一下今天和最近录音里聊到的核心重点与待办',
                    speakReply: true,
                  ),
                ),
              ),
              _promptChip(
                key: const Key('ai-her-prompt-walk'),
                label: '看看今天状态',
                onTap: () => unawaited(
                  c.sendMessage(
                    '查一下我今天和最近采集的健康数据与活动状态',
                    speakReply: true,
                  ),
                ),
              ),
              _promptChip(
                key: const Key('ai-her-prompt-movie'),
                label: '联网查个资料',
                onTap: () => unawaited(
                  c.sendMessage(
                    '帮我联网查一下今天有哪些值得关注的科技新闻',
                    speakReply: true,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 26),
          GestureDetector(
            key: const Key('ai-her-talk-btn'),
            onTap: () => unawaited(c.toggleListening()),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 180),
              width: 68,
              height: 68,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: c.isListening
                    ? Colors.white
                    : const Color(0x38FFFFFF),
                border: Border.all(
                  color: Colors.white,
                  width: c.isListening ? 3 : 2,
                ),
                boxShadow: c.isListening
                    ? const [
                        BoxShadow(
                          color: Color(0x55FFFFFF),
                          blurRadius: 18,
                          spreadRadius: 2,
                        ),
                      ]
                    : null,
              ),
              child: Icon(
                c.isListening ? Icons.stop_rounded : Icons.mic_rounded,
                size: 30,
                color: c.isListening ? const Color(0xFFD64933) : Colors.white,
              ),
            ),
          ),
          const SizedBox(height: 10),
          Text(
            c.isListening ? '轻点停止并发送' : '轻点说话（本地 STT + TTS）',
            style: const TextStyle(fontSize: 12, color: Color(0xCCFFF7EF)),
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
    return ActionChip(
      key: key,
      onPressed: onTap,
      backgroundColor: const Color(0x28FFFFFF),
      side: const BorderSide(color: Color(0x4DFFFFFF)),
      labelStyle: const TextStyle(
        fontSize: 12.5,
        fontWeight: FontWeight.w500,
        color: Colors.white,
      ),
      label: Text(label),
    );
  }
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
      final amp = (active ? (4.5 + energy * 12) : 2.8) * (1 - s * 0.09);
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
        ..color = Colors.white.withValues(alpha: (0.92 - s * 0.14).clamp(0.15, 0.95));
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
  });

  final AgentChatController controller;
  final double bottomPadding;

  @override
  State<_HumanChatPane> createState() => _HumanChatPaneState();
}

class _HumanChatPaneState extends State<_HumanChatPane> {
  final TextEditingController _inputCtrl = TextEditingController();
  final ScrollController _scrollCtrl = ScrollController();
  int _lastCount = 0;

  @override
  void initState() {
    super.initState();
    _lastCount = widget.controller.messages.length;
    widget.controller.addListener(_onChanged);
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
    if (c.messages.length != _lastCount) {
      _lastCount = c.messages.length;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || !_scrollCtrl.hasClients) return;
        _scrollCtrl.animateTo(
          _scrollCtrl.position.maxScrollExtent,
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
        );
      });
    }
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
    return Column(
      key: const Key('ai-chat-pane'),
      children: [
        Expanded(
          child: Container(
            color: const Color(0xFFF3F2EE),
            child: ListView(
              key: const Key('ai-chat-feed'),
              controller: _scrollCtrl,
              padding: const EdgeInsets.fromLTRB(
                16,
                14,
                16,
                RCDims.pageBottomPad,
              ),
              children: [
                const Center(
                  child: Padding(
                    padding: EdgeInsets.only(bottom: 14),
                    child: Text(
                      '有事直接问我 · 可检索录音记录、健康状态与联网资料',
                      style: TextStyle(fontSize: 11.5, color: RCColors.sec),
                    ),
                  ),
                ),
                if (c.messages.isEmpty && !c.isBusy)
                  _emptyGuideCard(),
                for (var i = 0; i < c.messages.length; i++)
                  _ChatBubble(
                    index: i,
                    message: c.messages[i],
                    onSpeak: c.messages[i].role == 'assistant'
                        ? () => unawaited(c.speakText(c.messages[i].text))
                        : null,
                  ),
                if (c.isBusy) const _TypingBubble(),
                if (c.errorMessage != null)
                  Container(
                    key: const Key('ai-chat-error'),
                    margin: const EdgeInsets.only(top: 8),
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: const Color(0xFFFFF1F0),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: const Color(0xFFFFCCC7)),
                    ),
                    child: Text(
                      c.errorMessage!,
                      style: const TextStyle(
                        fontSize: 13,
                        height: 1.45,
                        color: RCColors.danger,
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
        Container(
          height: 44,
          color: const Color(0xFFF3F2EE),
          child: ListView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
            children: [
              _quickChip(
                key: const Key('ai-quick-1'),
                label: '查一下最近待办',
                onTap: () => unawaited(
                  c.sendMessage('帮我查一下最近录音和总结里记了哪些待办事项'),
                ),
              ),
              const SizedBox(width: 8),
              _quickChip(
                key: const Key('ai-quick-2'),
                label: '今天聊了什么',
                onTap: () => unawaited(
                  c.sendMessage('帮我回顾一下今天录音里主要讨论了什么内容'),
                ),
              ),
              const SizedBox(width: 8),
              _quickChip(
                key: const Key('ai-quick-3'),
                label: '看看今天状态',
                onTap: () => unawaited(
                  c.sendMessage('看看我今天和最近采集的健康数据与活动状态'),
                ),
              ),
            ],
          ),
        ),
        Container(
          padding: EdgeInsets.fromLTRB(12, 8, 12, 10 + widget.bottomPadding),
          decoration: const BoxDecoration(
            color: Colors.white,
            border: Border(top: BorderSide(color: RCColors.sep)),
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
                  color: c.isListening ? const Color(0xFFD64933) : RCColors.sec,
                ),
              ),
              Expanded(
                child: TextField(
                  key: const Key('ai-chat-input'),
                  controller: _inputCtrl,
                  textInputAction: TextInputAction.send,
                  onSubmitted: (_) => _submit(),
                  decoration: InputDecoration(
                    isDense: true,
                    filled: true,
                    fillColor: const Color(0xFFF8F7F4),
                    hintText: '像发微信一样说一句…',
                    hintStyle: const TextStyle(
                      fontSize: 14,
                      color: RCColors.sec,
                    ),
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 10,
                    ),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(20),
                      borderSide: const BorderSide(color: RCColors.sep),
                    ),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(20),
                      borderSide: const BorderSide(color: RCColors.sep),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              FilledButton(
                key: const Key('ai-chat-send'),
                onPressed: c.isBusy ? null : _submit,
                style: FilledButton.styleFrom(
                  backgroundColor: const Color(0xFFEF653F),
                  foregroundColor: Colors.white,
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

  Widget _emptyGuideCard() {
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: RCColors.sep),
      ),
      child: const Text(
        '直接问我任何事情：比如“昨天下午那场讨论决定了什么”“查一下最近健康数据”，或者让我顺手帮你联网搜索、沉淀一条常用 Skill。',
        style: TextStyle(fontSize: 13.5, height: 1.55, color: RCColors.ink),
      ),
    );
  }

  Widget _quickChip({
    required Key key,
    required String label,
    required VoidCallback onTap,
  }) {
    return ActionChip(
      key: key,
      onPressed: onTap,
      backgroundColor: Colors.white,
      side: const BorderSide(color: RCColors.sep),
      padding: const EdgeInsets.symmetric(horizontal: 6),
      labelStyle: const TextStyle(fontSize: 12, color: RCColors.ink),
      label: Text(label),
    );
  }
}

class _ChatBubble extends StatelessWidget {
  const _ChatBubble({
    required this.index,
    required this.message,
    this.onSpeak,
  });

  final int index;
  final AgentChatMessage message;
  final VoidCallback? onSpeak;

  @override
  Widget build(BuildContext context) {
    final isMe = message.role == 'user';
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
                color: isMe ? const Color(0xFF1D1D1F) : Colors.white,
                borderRadius: BorderRadius.only(
                  topLeft: const Radius.circular(16),
                  topRight: const Radius.circular(16),
                  bottomLeft: Radius.circular(isMe ? 16 : 5),
                  bottomRight: Radius.circular(isMe ? 5 : 16),
                ),
                border: isMe ? null : Border.all(color: RCColors.sep),
              ),
              child: SelectableText(
                message.text,
                style: TextStyle(
                  fontSize: 14.5,
                  height: 1.5,
                  color: isMe ? Colors.white : RCColors.label,
                ),
              ),
            ),
            if (message.reaction != null && message.reaction!.isNotEmpty)
              Container(
                key: Key('ai-react-badge-$index'),
                margin: const EdgeInsets.only(top: 4),
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(999),
                  border: Border.all(color: RCColors.sep),
                ),
                child: Text(
                  message.reaction!,
                  style: const TextStyle(fontSize: 11, color: RCColors.sec),
                ),
              ),
            if (!isMe && onSpeak != null)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: InkWell(
                  key: Key('ai-speak-btn-$index'),
                  onTap: onSpeak,
                  borderRadius: BorderRadius.circular(999),
                  child: const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Icons.volume_up_outlined,
                          size: 14,
                          color: RCColors.sec,
                        ),
                        SizedBox(width: 3),
                        Text(
                          '朗读',
                          style: TextStyle(fontSize: 11, color: RCColors.sec),
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
    return Align(
      key: const Key('ai-typing-bubble'),
      alignment: Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.only(bottom: 12),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: RCColors.sep),
        ),
        child: const Text(
          '• • •',
          style: TextStyle(
            fontSize: 15,
            letterSpacing: 2,
            color: RCColors.sec,
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
    );
  }
}
