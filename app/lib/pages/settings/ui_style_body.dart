/// 界面风格模板库 —— 展示与切换默认 + 5 套风格（手机与 Apple Watch 同步生效）。
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/storage/storage.dart';
import '../../core/store/device_store.dart';
import '../../core/store/ui_style_store.dart';
import '../../core/theme/tokens.dart';

class UIStyleBody extends StatefulWidget {
  const UIStyleBody({super.key, this.styleStore, this.device});

  final UIStyleStore? styleStore;
  final DeviceStore? device;

  @override
  State<UIStyleBody> createState() => _UIStyleBodyState();
}

class _UIStyleBodyState extends State<UIStyleBody> {
  UIStyleStore? _fallbackStore;

  UIStyleStore _resolveStore(BuildContext context) {
    final provided = widget.styleStore ?? UIStyleScope.maybeOf(context);
    if (provided != null) return provided;
    return _fallbackStore ??= UIStyleStore(store: InMemoryStore());
  }

  @override
  void dispose() {
    _fallbackStore?.dispose();
    super.dispose();
  }

  Future<void> _applyStyle(UIStyleStore store, UIStyleDescriptor desc) async {
    await store.selectStyle(desc.id);
    if (store.activeStyleId == desc.id) {
      await widget.device?.watchHardware.setUiStyle(desc.id.wireId);
    }
  }

  Future<void> _removeStyle(UIStyleStore store, UIStyleDescriptor desc) async {
    await store.removeStyle(desc.id);
    await widget.device?.watchHardware.setUiStyle(store.activeStyleId.wireId);
  }

  @override
  Widget build(BuildContext context) {
    final store = _resolveStore(context);
    return ListenableBuilder(
      listenable: store,
      builder: (context, _) {
        final c = context.rc;
        final s = context.rcStyle;
        final activeId = store.activeStyleId;
        final busyId = store.installingStyleId;

        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (store.lastError != null && store.lastError!.trim().isNotEmpty)
              Container(
                key: const Key('ui-style-error'),
                margin: const EdgeInsets.only(bottom: 12),
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 10,
                ),
                decoration: BoxDecoration(
                  color: c.danger.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(s.cardRadius),
                  border: Border.all(color: c.danger.withValues(alpha: 0.35)),
                ),
                child: Text(
                  store.lastError!,
                  style: TextStyle(fontSize: 12.5, color: c.danger),
                ),
              ),
            for (final desc in UIStyleDescriptor.catalog)
              _StyleTemplateCard(
                desc: desc,
                active: activeId == desc.id,
                installed: store.isInstalled(desc.id),
                unlocked: store.isUnlocked(desc.id),
                installing: busyId == desc.id,
                busyAny: store.isBusy,
                installProgress: store.installProgress,
                installStatusText: store.installStatusText,
                onApply: () => unawaited(_applyStyle(store, desc)),
                onRemove: () => unawaited(_removeStyle(store, desc)),
              ),
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: c.card,
                borderRadius: BorderRadius.circular(s.cardRadius),
                border: Border.all(color: c.sep),
              ),
              child: Text(
                store.appleHostingAvailable
                    ? '当前支持通过 Apple 托管资源库按需拉取风格模板；现阶段全部 6 套风格免费开放切换，并将实时同步到已配对的 Apple Watch 表端应用与表盘组件。'
                    : '现阶段全部 6 套风格免费开放切换（后续可按模板单独开放会员档位），启用后会同步更新手机与已配对的 Apple Watch（手表主界面及表盘复杂组件）。',
                style: TextStyle(fontSize: 12.5, height: 1.55, color: c.sec),
              ),
            ),
          ],
        );
      },
    );
  }
}

class _StyleTemplateCard extends StatelessWidget {
  const _StyleTemplateCard({
    required this.desc,
    required this.active,
    required this.installed,
    required this.unlocked,
    required this.installing,
    required this.busyAny,
    required this.installProgress,
    required this.installStatusText,
    required this.onApply,
    required this.onRemove,
  });

  final UIStyleDescriptor desc;
  final bool active;
  final bool installed;
  final bool unlocked;
  final bool installing;
  final bool busyAny;
  final double installProgress;
  final String? installStatusText;
  final VoidCallback onApply;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final c = context.rc;
    final s = context.rcStyle;
    final previewScheme = colorSchemeForStyle(desc.id);
    final previewSpec = RCStyleSpec.of(
      desc.id,
      brightness: previewScheme.brightness,
    );

    final badgeText = active
        ? '使用中'
        : desc.builtin
        ? '默认内置'
        : installed
        ? '已安装'
        : desc.tier == UIStyleTier.pro && !unlocked
        ? '会员'
        : '模板包';
    final badgeBg = active ? s.accentSoft : s.surfaceSubtle;
    final badgeFg = active ? s.accent : c.sec;

    final actionLabel = installing
        ? '获取中…'
        : active
        ? '使用中'
        : installed
        ? '切换'
        : unlocked
        ? '获取并使用'
        : '暂未解锁';

    return Container(
      key: Key('style-card-${desc.id.wireId}'),
      margin: const EdgeInsets.only(bottom: 14),
      decoration: BoxDecoration(
        color: c.card,
        borderRadius: BorderRadius.circular(s.cardRadius),
        border: Border.all(
          color: active ? s.accent : c.sep,
          width: active ? 1.6 : 1.0,
        ),
        boxShadow: s.cardShadow,
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _DualDeviceMiniPreview(
            desc: desc,
            scheme: previewScheme,
            spec: previewSpec,
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 13, 16, 14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Row(
                        children: [
                          Flexible(
                            child: Text(
                              desc.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.w700,
                                color: c.label,
                                fontFamilyFallback: previewSpec.serifTitles
                                    ? rcSerifFontFallback
                                    : rcFontFallback,
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Text(
                            desc.enName,
                            style: TextStyle(
                              fontSize: 11.5,
                              color: c.sec,
                              fontFamilyFallback: previewSpec.monoMeta
                                  ? rcMonoFontFallback
                                  : rcFontFallback,
                            ),
                          ),
                        ],
                      ),
                    ),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 3,
                      ),
                      decoration: BoxDecoration(
                        color: badgeBg,
                        borderRadius: BorderRadius.circular(s.pillRadius),
                      ),
                      child: Text(
                        badgeText,
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                          color: badgeFg,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                Text(
                  desc.tagline,
                  style: TextStyle(fontSize: 13, height: 1.45, color: c.ink),
                ),
                const SizedBox(height: 4),
                Text(
                  'Watch：${desc.watchNote}',
                  style: TextStyle(fontSize: 12, color: c.sec),
                ),
                if (installing) ...[
                  const SizedBox(height: 10),
                  LinearProgressIndicator(
                    value: installProgress > 0 ? installProgress : null,
                    backgroundColor: c.sep,
                    color: s.accent,
                    minHeight: 3,
                  ),
                  if (installStatusText != null) ...[
                    const SizedBox(height: 4),
                    Text(
                      installStatusText!,
                      style: TextStyle(fontSize: 11, color: c.sec),
                    ),
                  ],
                ],
                const SizedBox(height: 12),
                Row(
                  children: [
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        for (final swatch in desc.swatchColors)
                          Container(
                            width: 12,
                            height: 12,
                            margin: const EdgeInsets.only(right: 5),
                            decoration: BoxDecoration(
                              color: swatch,
                              shape: BoxShape.circle,
                              border: Border.all(color: c.sep),
                            ),
                          ),
                      ],
                    ),
                    const Spacer(),
                    if (!desc.builtin && installed)
                      TextButton(
                        key: Key('style-remove-${desc.id.wireId}'),
                        onPressed: busyAny ? null : onRemove,
                        style: TextButton.styleFrom(
                          foregroundColor: c.sec,
                          padding: const EdgeInsets.symmetric(
                            horizontal: 10,
                            vertical: 6,
                          ),
                          minimumSize: Size.zero,
                          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        ),
                        child: const Text('移除', style: TextStyle(fontSize: 12.5)),
                      ),
                    const SizedBox(width: 6),
                    FilledButton(
                      key: Key('style-apply-${desc.id.wireId}'),
                      onPressed: (active || busyAny || !unlocked)
                          ? null
                          : onApply,
                      style: FilledButton.styleFrom(
                        backgroundColor: s.accent,
                        foregroundColor: s.accentFg,
                        disabledBackgroundColor: active
                            ? s.accentSoft
                            : s.surfaceSubtle,
                        disabledForegroundColor: active ? s.accent : c.sec,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(s.pillRadius),
                        ),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 8,
                        ),
                        minimumSize: Size.zero,
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      ),
                      child: Text(
                        actionLabel,
                        style: const TextStyle(
                          fontSize: 12.5,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// 卡片顶部缩略双端预览（左侧迷你 iPhone 视图 + 右侧迷你 Apple Watch 表盘）。
class _DualDeviceMiniPreview extends StatelessWidget {
  const _DualDeviceMiniPreview({
    required this.desc,
    required this.scheme,
    required this.spec,
  });

  final UIStyleDescriptor desc;
  final RCColorScheme scheme;
  final RCStyleSpec spec;

  @override
  Widget build(BuildContext context) {
    final bgStrip = scheme.isDark
        ? const Color(0xFF0E1014)
        : spec.surfaceSubtle.withValues(alpha: 0.72);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: bgStrip,
        border: Border(bottom: BorderSide(color: context.rc.sep)),
      ),
      child: Row(
        children: [
          // 迷你 iPhone 预览框
          Expanded(
            child: Container(
              height: 94,
              padding: const EdgeInsets.all(9),
              decoration: BoxDecoration(
                color: scheme.bg,
                borderRadius: BorderRadius.circular(
                  spec.cardRadius.clamp(6, 14),
                ),
                border: Border.all(color: scheme.sep),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Text(
                        '录音卡',
                        style: TextStyle(
                          fontSize: 10,
                          height: 1.1,
                          fontWeight: FontWeight.w700,
                          color: scheme.label,
                          fontFamilyFallback: spec.serifTitles
                              ? rcSerifFontFallback
                              : rcFontFallback,
                        ),
                      ),
                      const Spacer(),
                      Container(
                        width: 24,
                        height: 10,
                        decoration: BoxDecoration(
                          border: Border.all(color: scheme.sep),
                          borderRadius: BorderRadius.circular(999),
                        ),
                        padding: const EdgeInsets.symmetric(horizontal: 4),
                        child: Row(
                          children: [
                            Container(
                              width: 4,
                              height: 4,
                              decoration: BoxDecoration(
                                color: scheme.ok,
                                shape: BoxShape.circle,
                              ),
                            ),
                            const Spacer(),
                            Container(
                              width: 8,
                              height: 4,
                              color: scheme.ok,
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Expanded(
                    child: Container(
                      width: double.infinity,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 7,
                        vertical: 5,
                      ),
                      decoration: spec.eventAsCard
                          ? BoxDecoration(
                              color: scheme.card,
                              borderRadius: BorderRadius.circular(
                                spec.cardRadius.clamp(4, 12),
                              ),
                              border: Border.all(color: scheme.sep),
                            )
                          : BoxDecoration(
                              border: Border(
                                left: BorderSide(color: spec.railNodeColor, width: 2),
                              ),
                            ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Container(
                            width: 82,
                            height: 6,
                            decoration: BoxDecoration(
                              color: scheme.label,
                              borderRadius: BorderRadius.circular(3),
                            ),
                          ),
                          const SizedBox(height: 5),
                          Container(
                            width: 120,
                            height: 4.5,
                            decoration: BoxDecoration(
                              color: scheme.sec.withValues(alpha: 0.55),
                              borderRadius: BorderRadius.circular(2),
                            ),
                          ),
                          const Spacer(),
                          Row(
                            children: [
                              Container(
                                width: 32,
                                height: 4,
                                decoration: BoxDecoration(
                                  color: spec.accent,
                                  borderRadius: BorderRadius.circular(2),
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(width: 10),
          // 迷你 Apple Watch 表盘预览
          Container(
            width: 72,
            height: 94,
            padding: const EdgeInsets.all(7),
            decoration: BoxDecoration(
              color: spec.watchBg,
              borderRadius: BorderRadius.circular(18),
              border: Border.all(color: const Color(0xFF2B2D31), width: 2.2),
            ),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Row(
                  children: [
                    Container(
                      width: 4,
                      height: 4,
                      decoration: BoxDecoration(
                        color: spec.watchBattColor,
                        shape: BoxShape.circle,
                      ),
                    ),
                    const Spacer(),
                    Text(
                      '高',
                      style: TextStyle(
                        fontSize: 7.5,
                        height: 1.05,
                        fontWeight: FontWeight.w700,
                        color: spec.watchBattColor,
                      ),
                    ),
                  ],
                ),
                Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      '00:12',
                      style: TextStyle(
                        fontSize: 12.5,
                        height: 1.05,
                        fontWeight: FontWeight.w700,
                        color: Colors.white,
                        fontFamilyFallback: spec.serifTitles
                            ? rcSerifFontFallback
                            : (spec.monoMeta ? rcMonoFontFallback : rcFontFallback),
                      ),
                    ),
                    Container(
                      width: 24,
                      height: 2,
                      margin: const EdgeInsets.only(top: 2),
                      decoration: BoxDecoration(
                        color: spec.watchAccent,
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  ],
                ),
                Container(
                  height: 14,
                  decoration: BoxDecoration(
                    color: spec.watchStopBg.withValues(alpha: 0.24),
                    borderRadius: BorderRadius.circular(
                      desc.id == RCUIStyleId.braunField ? 4 : 999,
                    ),
                    border: Border.all(
                      color: spec.watchStopBg.withValues(alpha: 0.75),
                      width: 0.8,
                    ),
                  ),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: Container(
                      width: 11,
                      height: 11,
                      margin: const EdgeInsets.only(left: 1.5),
                      decoration: BoxDecoration(
                        color: spec.watchStopBg,
                        borderRadius: BorderRadius.circular(
                          desc.id == RCUIStyleId.braunField ? 3 : 999,
                        ),
                      ),
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
}
