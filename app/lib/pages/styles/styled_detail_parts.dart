/// Non-default style structural components for [DetailPage]:
/// - Styled segmented tab bar (`对话详情 / 原始数据 / 被引用总结`)
/// - Nocturne interactive acoustic scrub bar
/// - Authentic per-style dialogue turn layouts (cards, Chronos ledger, Folio marginalia, Nocturne OLED hairline, Air soft card)
/// - Full-width contextual photo card matching `dir-1.html`–`dir-5.html`
library;

import 'package:flutter/material.dart';

import '../../core/models/record.dart';
import '../../core/theme/tokens.dart';
import '../../widgets/photo_thumbnail.dart';

/// 16-bar interactive acoustic scrub bar for Nocturne detail view (`dir-4.html`).
class NocturneDetailScrubBar extends StatelessWidget {
  const NocturneDetailScrubBar({
    super.key,
    required this.bars,
    required this.selectedIdx,
    required this.onSelectIdx,
  });

  final List<double> bars;
  final int selectedIdx;
  final ValueChanged<int> onSelectIdx;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: SizedBox(
        key: const Key('nocturne-detail-scrub'),
        height: 24,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            for (var i = 0; i < bars.length; i++) ...[
              if (i > 0) const SizedBox(width: 4),
              Expanded(
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () => onSelectIdx(i),
                  child: Align(
                    alignment: Alignment.bottomCenter,
                    child: FractionallySizedBox(
                      heightFactor: bars[i].clamp(0.25, 1.0),
                      child: Container(
                        decoration: BoxDecoration(
                          color: i == selectedIdx
                              ? const Color(0xFFF5A623)
                              : const Color(0xFF323846),
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// Non-default style tab bar replacing underlined tabs with pill segments matching `dir-1`–`dir-5`.
class StyledDetailTabBar extends StatelessWidget {
  const StyledDetailTabBar({
    super.key,
    required this.currentTab,
    required this.tabs,
    required this.onSelect,
  });

  final String currentTab;
  final List<(String id, String label)> tabs;
  final ValueChanged<String> onSelect;

  @override
  Widget build(BuildContext context) {
    final s = context.rcStyle;

    if (s.styleId == RCUIStyleId.braunField) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(18, 2, 18, 10),
        child: Container(
          padding: const EdgeInsets.all(3),
          decoration: BoxDecoration(
            color: const Color(0xFFE3E2DA),
            borderRadius: BorderRadius.circular(9),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final (id, label) in tabs)
                GestureDetector(
                  key: Key('det-tab-$id'),
                  onTap: () => onSelect(id),
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 13,
                      vertical: 5,
                    ),
                    decoration: BoxDecoration(
                      color: currentTab == id
                          ? const Color(0xFF161614)
                          : Colors.transparent,
                      borderRadius: BorderRadius.circular(7),
                    ),
                    child: Text(
                      label,
                      style: TextStyle(
                        fontSize: 12.5,
                        fontWeight: FontWeight.w700,
                        color: currentTab == id
                            ? Colors.white
                            : const Color(0xFF5C5B53),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      );
    }

    final (
      Color activeBg,
      Color activeFg,
      Color inactiveBg,
      Color inactiveFg,
      Color? borderCol,
      double radius,
    ) = switch (s.styleId) {
      RCUIStyleId.chronos => (
        const Color(0xFF1D4ED8),
        Colors.white,
        Colors.white,
        const Color(0xFF525968),
        const Color(0xFFE2E6EE),
        999.0,
      ),
      RCUIStyleId.folio => (
        const Color(0xFFA62B21),
        const Color(0xFFF7F2E8),
        Colors.white,
        const Color(0xFF57534E),
        const Color(0xFFC8BDA8),
        6.0,
      ),
      RCUIStyleId.nocturne => (
        const Color(0xFFF5A623),
        const Color(0xFF111214),
        const Color(0xFF12141A),
        const Color(0xFF8B92A1),
        const Color(0xFF282D38),
        999.0,
      ),
      RCUIStyleId.air => (
        const Color(0xFF0F172A),
        Colors.white,
        Colors.white.withValues(alpha: 0.72),
        const Color(0xFF475569),
        null,
        999.0,
      ),
      _ => (
        s.accent,
        s.accentFg,
        context.rc.card,
        context.rc.sec,
        context.rc.sep,
        999.0,
      ),
    };

    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.fromLTRB(18, 2, 18, 10),
      child: Row(
        children: [
          for (var i = 0; i < tabs.length; i++) ...[
            if (i > 0) const SizedBox(width: 8),
            GestureDetector(
              key: Key('det-tab-${tabs[i].$1}'),
              onTap: () => onSelect(tabs[i].$1),
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 13,
                  vertical: 6,
                ),
                decoration: BoxDecoration(
                  color: currentTab == tabs[i].$1 ? activeBg : inactiveBg,
                  borderRadius: BorderRadius.circular(radius),
                  border: borderCol != null
                      ? Border.all(
                          color: currentTab == tabs[i].$1 ? activeBg : borderCol,
                        )
                      : null,
                ),
                child: Text(
                  tabs[i].$2,
                  style: TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w700,
                    color: currentTab == tabs[i].$1 ? activeFg : inactiveFg,
                  ),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// Non-default style dialogue turn layout matching `dir-1`–`dir-5`.
class StyledDetailTurn extends StatelessWidget {
  const StyledDetailTurn({
    super.key,
    required this.eventId,
    required this.firstTurnIndex,
    required this.displaySpk,
    required this.startClock,
    required this.paragraphs,
    required this.canQuickName,
    required this.hasMarkedTag,
    required this.isConfirmedSpeaker,
    required this.onQuickName,
  });

  final String eventId;
  final int firstTurnIndex;
  final String displaySpk;
  final String startClock;
  final List<String> paragraphs;
  final bool canQuickName;
  final bool hasMarkedTag;
  final bool isConfirmedSpeaker;
  final VoidCallback onQuickName;

  @override
  Widget build(BuildContext context) {
    final s = context.rcStyle;
    final bodyWidget = Column(
      key: Key('turn-para-$eventId-$firstTurnIndex'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (var i = 0; i < paragraphs.length; i++) ...[
          if (i > 0) const SizedBox(height: 8),
          Text(
            paragraphs[i],
            key: Key('turn-para-body-$eventId-$firstTurnIndex-$i'),
            style: TextStyle(
              fontSize: 14.5,
              height: s.styleId == RCUIStyleId.folio ? 1.68 : 1.60,
              color: s.styleId == RCUIStyleId.nocturne
                  ? const Color(0xFFECEEF2)
                  : (s.styleId == RCUIStyleId.air
                      ? const Color(0xFF0F172A)
                      : context.rc.label),
            ),
          ),
        ],
      ],
    );

    switch (s.styleId) {
      case RCUIStyleId.braunField:
        return Container(
          key: Key('braun-turn-$eventId-$firstTurnIndex'),
          margin: const EdgeInsets.only(bottom: 12),
          clipBehavior: Clip.antiAlias,
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: const Color(0xFFD2D1C8)),
          ),
          child: Stack(
            children: [
              if (hasMarkedTag)
                const Positioned(
                  left: 0,
                  top: 0,
                  bottom: 0,
                  width: 3,
                  child: ColoredBox(color: Color(0xFFFF5514)),
                ),
              Padding(
                padding: const EdgeInsets.all(14),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        _SpeakerTagChip(
                          whoKey: Key('turn-who-$eventId-$firstTurnIndex'),
                          spkKey: Key('turn-spk-$firstTurnIndex'),
                          label: displaySpk,
                          enabled: canQuickName,
                          onTap: onQuickName,
                          bg: const Color(0xFFF3F2EC),
                          fg: const Color(0xFF161614),
                          borderColor: isConfirmedSpeaker
                              ? const Color(0xFFFF5514)
                              : const Color(0xFFC8C7BE),
                        ),
                        Text(
                          startClock,
                          style: const TextStyle(
                            fontSize: 12,
                            color: Color(0xFF5C5B53),
                            fontFamilyFallback: rcMonoFontFallback,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    bodyWidget,
                  ],
                ),
              ),
            ],
          ),
        );

      case RCUIStyleId.chronos:
        return Container(
          key: Key('chronos-ledger-turn-$eventId-$firstTurnIndex'),
          padding: const EdgeInsets.symmetric(vertical: 13),
          decoration: BoxDecoration(
            color: hasMarkedTag ? const Color(0xFFFEF2F2) : Colors.transparent,
            border: const Border(
              bottom: BorderSide(color: Color(0xFFEFF2F7)),
            ),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: 48,
                child: Padding(
                  padding: const EdgeInsets.only(top: 3),
                  child: Text(
                    startClock,
                    style: const TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                      color: Color(0xFF525968),
                      fontFeatures: [FontFeature.tabularFigures()],
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _SpeakerTagChip(
                      whoKey: Key('turn-who-$eventId-$firstTurnIndex'),
                      spkKey: Key('turn-spk-$firstTurnIndex'),
                      label: displaySpk,
                      enabled: canQuickName,
                      onTap: onQuickName,
                      bg: Colors.white,
                      fg: isConfirmedSpeaker
                          ? const Color(0xFF1D4ED8)
                          : const Color(0xFF111318),
                      borderColor: const Color(0xFFE2E6EE),
                    ),
                    const SizedBox(height: 7),
                    bodyWidget,
                  ],
                ),
              ),
            ],
          ),
        );

      case RCUIStyleId.folio:
        return Container(
          key: Key('folio-marginalia-turn-$eventId-$firstTurnIndex'),
          padding: const EdgeInsets.symmetric(vertical: 13),
          decoration: BoxDecoration(
            color: hasMarkedTag ? const Color(0xFFFCF2EF) : Colors.transparent,
            border: const Border(
              bottom: BorderSide(color: Color(0xFFE6DEC8)),
            ),
          ),
          child: IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(child: bodyWidget),
                const SizedBox(width: 14),
                Container(
                  width: 90,
                  padding: const EdgeInsets.only(left: 10),
                  decoration: const BoxDecoration(
                    border: Border(
                      left: BorderSide(color: Color(0xFFE6DEC8)),
                    ),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _SpeakerTagChip(
                        whoKey: Key('turn-who-$eventId-$firstTurnIndex'),
                        spkKey: Key('turn-spk-$firstTurnIndex'),
                        label: displaySpk,
                        enabled: canQuickName,
                        onTap: onQuickName,
                        bg: isConfirmedSpeaker
                            ? const Color(0xFF1C1917)
                            : Colors.white,
                        fg: isConfirmedSpeaker
                            ? const Color(0xFFF7F2E8)
                            : const Color(0xFF1C1917),
                        borderColor: isConfirmedSpeaker
                            ? const Color(0xFF1C1917)
                            : const Color(0xFFC8BDA8),
                        radius: 4,
                      ),
                      const SizedBox(height: 4),
                      Text(
                        startClock,
                        style: const TextStyle(
                          fontSize: 11.5,
                          color: Color(0xFF57534E),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        );

      case RCUIStyleId.nocturne:
        return Container(
          key: Key('nocturne-turn-$eventId-$firstTurnIndex'),
          padding: const EdgeInsets.symmetric(vertical: 14),
          decoration: BoxDecoration(
            color: hasMarkedTag
                ? const Color(0x14F5A623)
                : Colors.transparent,
            border: const Border(
              bottom: BorderSide(color: Color(0xFF1E222B)),
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  _SpeakerTagChip(
                    whoKey: Key('turn-who-$eventId-$firstTurnIndex'),
                    spkKey: Key('turn-spk-$firstTurnIndex'),
                    label: displaySpk,
                    enabled: canQuickName,
                    onTap: onQuickName,
                    bg: isConfirmedSpeaker
                        ? const Color(0xFFF5A623)
                        : const Color(0xFF12141A),
                    fg: isConfirmedSpeaker
                        ? const Color(0xFF111214)
                        : Colors.white,
                    borderColor: isConfirmedSpeaker
                        ? const Color(0xFFF5A623)
                        : const Color(0xFF1E222B),
                  ),
                  Text(
                    startClock,
                    style: const TextStyle(
                      fontSize: 12,
                      color: Color(0xFF8B92A1),
                      fontFamilyFallback: rcMonoFontFallback,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 7),
              bodyWidget,
            ],
          ),
        );

      case RCUIStyleId.air:
        return Container(
          key: Key('air-turn-$eventId-$firstTurnIndex'),
          margin: const EdgeInsets.only(bottom: 12),
          padding: const EdgeInsets.all(15),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(18),
            boxShadow: const [
              BoxShadow(
                color: Color(0x0D0F172A),
                blurRadius: 18,
                offset: Offset(0, 5),
              ),
            ],
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  _SpeakerTagChip(
                    whoKey: Key('turn-who-$eventId-$firstTurnIndex'),
                    spkKey: Key('turn-spk-$firstTurnIndex'),
                    label: displaySpk,
                    enabled: canQuickName,
                    onTap: onQuickName,
                    bg: const Color(0xFFEAF1F6),
                    fg: isConfirmedSpeaker
                        ? const Color(0xFF115E63)
                        : const Color(0xFF0F172A),
                    borderColor: Colors.transparent,
                    radius: 999,
                  ),
                  Text(
                    startClock,
                    style: const TextStyle(
                      fontSize: 12,
                      color: Color(0xFF475569),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              bodyWidget,
            ],
          ),
        );

      case RCUIStyleId.warmPaper:
        return const SizedBox.shrink();
    }
  }
}

class _SpeakerTagChip extends StatelessWidget {
  const _SpeakerTagChip({
    required this.whoKey,
    required this.spkKey,
    required this.label,
    required this.enabled,
    required this.onTap,
    required this.bg,
    required this.fg,
    required this.borderColor,
    this.radius = 6,
  });

  final Key whoKey;
  final Key spkKey;
  final String label;
  final bool enabled;
  final VoidCallback onTap;
  final Color bg;
  final Color fg;
  final Color borderColor;
  final double radius;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      key: whoKey,
      onTap: enabled ? onTap : null,
      child: KeyedSubtree(
        key: spkKey,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
          decoration: BoxDecoration(
            color: bg,
            borderRadius: BorderRadius.circular(radius),
            border: borderColor.a > 0 ? Border.all(color: borderColor) : null,
          ),
          child: Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w700,
              color: fg,
            ),
          ),
        ),
      ),
    );
  }
}

/// Full-width contextual photo figure card in non-default styles.
class StyledDetailPhotoCard extends StatelessWidget {
  const StyledDetailPhotoCard({
    super.key,
    required this.eventId,
    required this.index,
    required this.photo,
    required this.onPreview,
    required this.onExclude,
  });

  final String eventId;
  final int index;
  final EventPhoto photo;
  final VoidCallback onPreview;
  final VoidCallback onExclude;

  @override
  Widget build(BuildContext context) {
    final c = context.rc;
    final s = context.rcStyle;
    final srcLabel = photo.source == 'dyj_camera' ? '点一机抓拍' : '系统相册';
    final double radius = switch (s.styleId) {
      RCUIStyleId.braunField => 12,
      RCUIStyleId.chronos => 14,
      RCUIStyleId.folio => 6,
      RCUIStyleId.nocturne => 10,
      RCUIStyleId.air => 18,
      RCUIStyleId.warmPaper => 12,
    };
    return Padding(
      key: Key('dphoto-$eventId-$index'),
      padding: const EdgeInsets.only(bottom: 14),
      child: Container(
        decoration: BoxDecoration(
          color: c.card,
          borderRadius: BorderRadius.circular(radius),
          border: s.styleId == RCUIStyleId.air
              ? null
              : Border.all(color: c.sep),
          boxShadow: s.cardShadow,
        ),
        clipBehavior: Clip.antiAlias,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            GestureDetector(
              key: Key('dphoto-thumb-$eventId-$index'),
              onTap: onPreview,
              child: SizedBox(
                height: 146,
                child: PhotoThumbnail(
                  path: photo.path,
                  logicalWidth: 360,
                  source: photo.source,
                  placeholderIconSize: 28,
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Expanded(
                    child: Text(
                      '$srcLabel · ${photo.time}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 12, color: c.sec),
                    ),
                  ),
                  const SizedBox(width: 8),
                  InkWell(
                    key: Key('dphoto-exclude-$eventId-$index'),
                    onTap: onExclude,
                    borderRadius: BorderRadius.circular(6),
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 9,
                        vertical: 4,
                      ),
                      decoration: BoxDecoration(
                        color: c.bg,
                        borderRadius: BorderRadius.circular(6),
                        border: Border.all(color: c.sep),
                      ),
                      child: Text(
                        '不属于本段',
                        style: TextStyle(
                          fontSize: 11.5,
                          fontWeight: FontWeight.w600,
                          color: c.sec,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
