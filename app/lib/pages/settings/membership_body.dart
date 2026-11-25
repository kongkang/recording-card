/// 会员与订阅（简洁付费墙、月度 3,600 分钟本地额度、永久买断分栏与合规入口）。
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/store/membership_store.dart';
import '../../core/theme/tokens.dart';
import '../../pages/privacy_page.dart';
import '../../services/billing/storekit_service.dart';

class MembershipBody extends StatefulWidget {
  const MembershipBody({super.key, required this.store});

  final MembershipStore store;

  @override
  State<MembershipBody> createState() => _MembershipBodyState();
}

class _MembershipBodyState extends State<MembershipBody> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (widget.store.catalog.isEmpty && !widget.store.loadingCatalog) {
        unawaited(widget.store.refreshStoreKit());
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final store = widget.store;
    return ListenableBuilder(
      listenable: store,
      builder: (context, _) {
        final c = context.rc;
        final cycle = store.selectedCycle;
        final isLifetime = cycle == BillingCycle.lifetime;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _buildQuotaCard(context, c, store),
            const SizedBox(height: 12),
            _buildCycleSelector(c, store, cycle),
            const SizedBox(height: 12),
            _buildLocalProCard(context, c, store, cycle),
            if (isLifetime) ...[
              const SizedBox(height: 12),
              Center(
                child: TextButton(
                  key: const Key('lifetime-switch-cloud-hint'),
                  onPressed: () =>
                      unawaited(store.setSelectedCycle(BillingCycle.yearly)),
                  style: TextButton.styleFrom(
                    foregroundColor: c.sec,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 6,
                    ),
                    minimumSize: Size.zero,
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  child: const Text(
                    '需要云端 AI 总结？切换至按月 / 按年查看',
                    style: TextStyle(fontSize: 12.5),
                  ),
                ),
              ),
            ] else ...[
              const SizedBox(height: 10),
              _buildCloudBasicCard(context, c, store, cycle),
              const SizedBox(height: 10),
              _buildCloudProCard(context, c, store, cycle),
              const SizedBox(height: 18),
              Text(
                '云端积分加量包（按需补充）',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: c.sec,
                ),
              ),
              const SizedBox(height: 8),
              _buildCreditPacksRow(context, c, store),
            ],
            const SizedBox(height: 18),
            _buildComplianceFooter(context, c, store),
          ],
        );
      },
    );
  }

  Widget _buildQuotaCard(
    BuildContext context,
    RCColorScheme c,
    MembershipStore store,
  ) {
    final pillText = store.tierDisplayName;
    final Color pillBg;
    final Color pillBorder;
    final Color pillFg;
    switch (store.tier) {
      case MembershipTier.free:
        pillBg = c.sec.withValues(alpha: 0.12);
        pillBorder = c.sep;
        pillFg = c.label;
      case MembershipTier.localPro:
        pillBg = c.isDark
            ? c.ok.withValues(alpha: 0.16)
            : const Color(0xFFEDF7F0);
        pillBorder = c.isDark
            ? c.ok.withValues(alpha: 0.45)
            : const Color(0xFFBEE5C8);
        pillFg = c.okInk;
      case MembershipTier.cloudBasic:
      case MembershipTier.cloudPro:
        pillBg = c.isDark
            ? c.info.withValues(alpha: 0.18)
            : const Color(0xFFEEF5FF);
        pillBorder = c.isDark
            ? c.info.withValues(alpha: 0.45)
            : const Color(0xFFC2DBFF);
        pillFg = c.isDark ? c.info : const Color(0xFF0F4C81);
    }

    final barColor = store.isLocalQuotaExhausted
        ? c.danger
        : (store.isLocalQuotaWarning ? c.warn : c.label);

    final String rightMeta;
    final String subtitleMeta;
    switch (store.tier) {
      case MembershipTier.free:
        rightMeta =
            '本月已用 ${store.effectiveUsedMinutes} / ${MembershipStore.freeMonthlyLimitMinutes} 分钟';
        subtitleMeta = '每月 1 日自动重置，不限单日；用完后录音仍照常保存';
      case MembershipTier.localPro:
        rightMeta = store.lifetimeLocalPro ? '永久有效' : '不限本地转写';
        subtitleMeta = store.lifetimeLocalPro
            ? '不限时长本地转写与导出'
            : _expiryText(store.subscriptionExpiresAtMs);
      case MembershipTier.cloudBasic:
        rightMeta = '剩余 ${store.cloudCreditsRemaining} 积分';
        subtitleMeta = '含本地解锁版 + 日常模型整理 · ${_expiryText(store.subscriptionExpiresAtMs)}';
      case MembershipTier.cloudPro:
        rightMeta = '高级总结剩 ${store.cloudProSummariesRemaining} 次';
        subtitleMeta = '含本地解锁版 + 高级模型深度整理 · ${_expiryText(store.subscriptionExpiresAtMs)}';
    }

    final noticeText = store.lastNotice;

    return Container(
      key: const Key('membership-quota-card'),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: c.card,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: c.sep),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                key: const Key('membership-tier-pill'),
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 3,
                ),
                decoration: BoxDecoration(
                  color: pillBg,
                  borderRadius: BorderRadius.circular(999),
                  border: Border.all(color: pillBorder),
                ),
                child: Text(
                  pillText,
                  style: TextStyle(
                    fontSize: 11.5,
                    fontWeight: FontWeight.w700,
                    color: pillFg,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  rightMeta,
                  textAlign: TextAlign.end,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: c.label,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
              ),
            ],
          ),
          if (store.tier == MembershipTier.free) ...[
            const SizedBox(height: 10),
            ClipRRect(
              key: const Key('membership-quota-bar'),
              borderRadius: BorderRadius.circular(999),
              child: Container(
                height: 6,
                color: c.sec.withValues(alpha: 0.16),
                alignment: Alignment.centerLeft,
                child: FractionallySizedBox(
                  widthFactor: store.usageRatio,
                  child: Container(
                    decoration: BoxDecoration(
                      color: barColor,
                      borderRadius: BorderRadius.circular(999),
                    ),
                  ),
                ),
              ),
            ),
          ],
          const SizedBox(height: 8),
          Text(
            subtitleMeta,
            style: TextStyle(fontSize: 12, height: 1.45, color: c.sec),
          ),
          if (store.isLocalQuotaExhausted) ...[
            const SizedBox(height: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              decoration: BoxDecoration(
                color: c.isDark
                    ? c.danger.withValues(alpha: 0.15)
                    : const Color(0xFFFEF3F2),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(
                  color: c.isDark
                      ? c.danger.withValues(alpha: 0.45)
                      : const Color(0xFFFECDCA),
                ),
              ),
              child: Text(
                '本月免费转写已用完，录音仍照常保存，升级即可继续转写。',
                style: TextStyle(
                  fontSize: 12,
                  height: 1.45,
                  color: c.isDark ? c.danger : const Color(0xFF912018),
                ),
              ),
            ),
          ],
          if (store.loadingCatalog) ...[
            const SizedBox(height: 8),
            Row(
              children: [
                SizedBox(
                  width: 13,
                  height: 13,
                  child: CircularProgressIndicator(
                    strokeWidth: 1.8,
                    color: c.sec,
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  '正在更新价格…',
                  style: TextStyle(fontSize: 11.5, color: c.sec),
                ),
              ],
            ),
          ] else if (noticeText != null && noticeText.isNotEmpty) ...[
            const SizedBox(height: 8),
            Container(
              key: const Key('membership-storekit-notice'),
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              decoration: BoxDecoration(
                color: c.sec.withValues(alpha: 0.08),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: c.sep),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      noticeText,
                      style: TextStyle(
                        fontSize: 11.5,
                        height: 1.45,
                        color: c.ink,
                      ),
                    ),
                  ),
                  TextButton(
                    key: const Key('membership-refresh-btn'),
                    onPressed: store.purchaseInFlight
                        ? null
                        : () => unawaited(store.refreshStoreKit()),
                    style: TextButton.styleFrom(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 4,
                      ),
                      minimumSize: Size.zero,
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                    child: const Text('刷新价格', style: TextStyle(fontSize: 11.5)),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildCycleSelector(
    RCColorScheme c,
    MembershipStore store,
    BillingCycle active,
  ) {
    Widget segBtn({
      required Key key,
      required BillingCycle value,
      required String label,
    }) {
      final selected = active == value;
      return Expanded(
        child: GestureDetector(
          key: key,
          behavior: HitTestBehavior.opaque,
          onTap: () => unawaited(store.setSelectedCycle(value)),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 160),
            padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 6),
            decoration: BoxDecoration(
              color: selected ? c.card : Colors.transparent,
              borderRadius: BorderRadius.circular(8),
              boxShadow: selected && !c.isDark
                  ? const [
                      BoxShadow(
                        color: Color(0x14000000),
                        blurRadius: 4,
                        offset: Offset(0, 1),
                      ),
                    ]
                  : null,
            ),
            alignment: Alignment.center,
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 12.5,
                fontWeight: selected ? FontWeight.w700 : FontWeight.w600,
                color: selected ? c.label : c.sec,
              ),
            ),
          ),
        ),
      );
    }

    return Container(
      key: const Key('membership-cycle-seg'),
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: c.sec.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(11),
      ),
      child: Row(
        children: [
          segBtn(
            key: const Key('cycle-seg-monthly'),
            value: BillingCycle.monthly,
            label: '按月',
          ),
          segBtn(
            key: const Key('cycle-seg-yearly'),
            value: BillingCycle.yearly,
            label: '按年 · 省 17%',
          ),
          segBtn(
            key: const Key('cycle-seg-lifetime'),
            value: BillingCycle.lifetime,
            label: '永久买断',
          ),
        ],
      ),
    );
  }

  Widget _buildLocalProCard(
    BuildContext context,
    RCColorScheme c,
    MembershipStore store,
    BillingCycle cycle,
  ) {
    final productId = store.localProProductForCycle(cycle);
    final isCurrentTier = store.tier == MembershipTier.localPro;
    final ownsExact = store.ownsExactProduct(productId);
    final price = store.displayPriceFor(productId);
    final ctaText = ownsExact
        ? '当前方案'
        : (cycle == BillingCycle.lifetime
              ? '${price.primaryPrice} 永久买断'
              : '立即开通');
    final cycleLabel = switch (cycle) {
      BillingCycle.monthly => '按月订阅',
      BillingCycle.yearly => '按年订阅',
      BillingCycle.lifetime => '永久买断',
    };

    return _buildPlanCard(
      c: c,
      store: store,
      cardKey: const Key('plan-card-local'),
      buttonKey: const Key('plan-buy-local'),
      title: '本地解锁版',
      tagText: isCurrentTier ? '当前方案' : null,
      tagIsCurrent: isCurrentTier,
      highlighted: isCurrentTier,
      primaryPrice: price.primaryPrice,
      secondaryHint: price.secondaryHint,
      bullets: const [
        '不限时长，随时离线转文字',
        '区分说话人，照片按时间自动匹配',
        '一键导出文档、PDF 与图片',
      ],
      footnote: '仅含本地转写与导出，不含云端 AI 总结',
      productId: productId,
      ctaLabel: ctaText,
      isCurrentOwned: ownsExact,
      onBuyTap: () => unawaited(
        _handlePurchaseTap(
          context,
          store,
          productId: productId,
          planTitle: '本地解锁版',
          cycleLabel: cycleLabel,
          summary: '不限时长本地离线转文字，支持说话人区分与多格式导出；不含云端 AI 总结。',
          isSubscription: cycle != BillingCycle.lifetime,
        ),
      ),
    );
  }

  Widget _buildCloudBasicCard(
    BuildContext context,
    RCColorScheme c,
    MembershipStore store,
    BillingCycle cycle,
  ) {
    final productId = store.cloudBasicProductForCycle(cycle);
    final isCurrentTier = store.tier == MembershipTier.cloudBasic;
    final ownsExact = store.ownsExactProduct(productId);
    final price = store.displayPriceFor(productId);
    final cycleLabel = cycle == BillingCycle.yearly ? '按年订阅' : '按月订阅';

    return _buildPlanCard(
      c: c,
      store: store,
      cardKey: const Key('plan-card-basic'),
      buttonKey: const Key('plan-buy-basic'),
      title: '云端日常版',
      tagText: isCurrentTier ? '当前方案' : '推荐',
      tagIsCurrent: isCurrentTier,
      highlighted: !isCurrentTier,
      primaryPrice: price.primaryPrice,
      secondaryHint: price.secondaryHint,
      bullets: const [
        '包含全部本地解锁版功能',
        '日常模型自动提炼重点、待办与问答',
        '每月 500 积分，满足日常高频使用',
      ],
      productId: productId,
      ctaLabel: ownsExact ? '当前方案' : '立即开通',
      isCurrentOwned: ownsExact,
      onBuyTap: () => unawaited(
        _handlePurchaseTap(
          context,
          store,
          productId: productId,
          planTitle: '云端日常版',
          cycleLabel: cycleLabel,
          summary: '包含全部本地解锁版功能，叠加日常模型智能总结与每月 500 积分。',
          isSubscription: true,
        ),
      ),
    );
  }

  Widget _buildCloudProCard(
    BuildContext context,
    RCColorScheme c,
    MembershipStore store,
    BillingCycle cycle,
  ) {
    final productId = store.cloudProProductForCycle(cycle);
    final isCurrentTier = store.tier == MembershipTier.cloudPro;
    final ownsExact = store.ownsExactProduct(productId);
    final price = store.displayPriceFor(productId);
    final cycleLabel = cycle == BillingCycle.yearly ? '按年订阅' : '按月订阅';

    return _buildPlanCard(
      c: c,
      store: store,
      cardKey: const Key('plan-card-pro'),
      buttonKey: const Key('plan-buy-pro'),
      title: '云端高级版',
      tagText: isCurrentTier ? '当前方案' : null,
      tagIsCurrent: isCurrentTier,
      highlighted: isCurrentTier,
      primaryPrice: price.primaryPrice,
      secondaryHint: price.secondaryHint,
      bullets: const [
        '包含全部本地解锁版功能',
        '高级模型深度总结、睡前日记与问答',
        '高额月享，用完自动切日常模型不断档',
      ],
      productId: productId,
      ctaLabel: ownsExact ? '当前方案' : '立即开通',
      isCurrentOwned: ownsExact,
      onBuyTap: () => unawaited(
        _handlePurchaseTap(
          context,
          store,
          productId: productId,
          planTitle: '云端高级版',
          cycleLabel: cycleLabel,
          summary: '包含全部本地解锁版功能，享高级模型深度总结、睡前日记与问答。',
          isSubscription: true,
        ),
      ),
    );
  }

  Widget _buildPlanCard({
    required RCColorScheme c,
    required MembershipStore store,
    required Key cardKey,
    required Key buttonKey,
    required String title,
    required String? tagText,
    required bool tagIsCurrent,
    required bool highlighted,
    required String primaryPrice,
    required String secondaryHint,
    required List<String> bullets,
    String? footnote,
    required String productId,
    required String ctaLabel,
    required bool isCurrentOwned,
    required VoidCallback onBuyTap,
  }) {
    final borderColor = isCurrentOwned
        ? c.ok
        : (highlighted ? c.info : c.sep);
    final cardBg = isCurrentOwned
        ? (c.isDark
              ? c.ok.withValues(alpha: 0.08)
              : const Color(0xFFFAFDFB))
        : c.card;
    final purchasingThis =
        store.purchaseInFlight && store.purchasingProductId == productId;

    return Container(
      key: cardKey,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: cardBg,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: borderColor,
          width: isCurrentOwned || highlighted ? 1.4 : 1,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Wrap(
                  spacing: 6,
                  runSpacing: 4,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    Text(
                      title,
                      style: TextStyle(
                        fontSize: 15.5,
                        fontWeight: FontWeight.w700,
                        color: c.label,
                      ),
                    ),
                    if (tagText != null)
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 7,
                          vertical: 2,
                        ),
                        decoration: BoxDecoration(
                          color: tagIsCurrent
                              ? c.okInk
                              : (c.isDark ? c.info : const Color(0xFF0F4C81)),
                          borderRadius: BorderRadius.circular(999),
                        ),
                        child: Text(
                          tagText,
                          style: const TextStyle(
                            fontSize: 10,
                            fontWeight: FontWeight.w700,
                            color: Colors.white,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Row(
                crossAxisAlignment: CrossAxisAlignment.baseline,
                textBaseline: TextBaseline.alphabetic,
                children: [
                  Text(
                    primaryPrice,
                    style: TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.w800,
                      color: c.label,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                  if (secondaryHint.isNotEmpty) ...[
                    const SizedBox(width: 3),
                    Text(
                      secondaryHint,
                      style: TextStyle(fontSize: 11.5, color: c.sec),
                    ),
                  ],
                ],
              ),
            ],
          ),
          const SizedBox(height: 10),
          for (final item in bullets)
            Padding(
              padding: const EdgeInsets.only(bottom: 5),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(
                    padding: const EdgeInsets.only(top: 3),
                    child: Icon(
                      Icons.check_circle_outline_rounded,
                      size: 14,
                      color: c.okInk,
                    ),
                  ),
                  const SizedBox(width: 7),
                  Expanded(
                    child: Text(
                      item,
                      style: TextStyle(
                        fontSize: 12.5,
                        height: 1.5,
                        color: c.ink,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          if (footnote != null && footnote.isNotEmpty) ...[
            const SizedBox(height: 2),
            Text(
              footnote,
              style: TextStyle(fontSize: 11.5, height: 1.45, color: c.sec),
            ),
            const SizedBox(height: 10),
          ] else
            const SizedBox(height: 6),
          if (isCurrentOwned)
            OutlinedButton(
              key: buttonKey,
              onPressed: null,
              style: OutlinedButton.styleFrom(
                minimumSize: const Size.fromHeight(40),
                side: BorderSide(color: c.sep),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10),
                ),
              ),
              child: Text(ctaLabel),
            )
          else
            FilledButton(
              key: buttonKey,
              onPressed: store.purchaseInFlight ? null : onBuyTap,
              style: FilledButton.styleFrom(
                backgroundColor: c.label,
                foregroundColor: c.onLabel,
                minimumSize: const Size.fromHeight(40),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10),
                ),
              ),
              child: purchasingThis
                  ? SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: c.onLabel,
                      ),
                    )
                  : Text(
                      ctaLabel,
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
            ),
        ],
      ),
    );
  }

  Widget _buildCreditPacksRow(
    BuildContext context,
    RCColorScheme c,
    MembershipStore store,
  ) {
    final p500 = store.displayPriceFor(MembershipStore.creditsPack500);
    final p1200 = store.displayPriceFor(MembershipStore.creditsPack1200);

    Widget packCard({
      required Key buttonKey,
      required String productId,
      required String title,
      required String priceText,
      required String subtitle,
      required String sheetTitle,
      required String sheetSummary,
    }) {
      final purchasing =
          store.purchaseInFlight && store.purchasingProductId == productId;
      return Expanded(
        child: Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: c.card,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: c.sep),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      title,
                      style: TextStyle(
                        fontSize: 13.5,
                        fontWeight: FontWeight.w700,
                        color: c.label,
                      ),
                    ),
                  ),
                  Text(
                    priceText,
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w800,
                      color: c.label,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              Text(
                subtitle,
                style: TextStyle(fontSize: 11.5, height: 1.4, color: c.sec),
              ),
              const SizedBox(height: 10),
              OutlinedButton(
                key: buttonKey,
                onPressed: store.purchaseInFlight
                    ? null
                    : () => unawaited(
                        _handlePurchaseTap(
                          context,
                          store,
                          productId: productId,
                          planTitle: sheetTitle,
                          cycleLabel: '一次性购买',
                          summary: sheetSummary,
                          isSubscription: false,
                        ),
                      ),
                style: OutlinedButton.styleFrom(
                  foregroundColor: c.label,
                  side: BorderSide(color: c.sep),
                  minimumSize: const Size.fromHeight(34),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(9),
                  ),
                ),
                child: purchasing
                    ? SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: c.label,
                        ),
                      )
                    : const Text(
                        '购买',
                        style: TextStyle(
                          fontSize: 12.5,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
              ),
            ],
          ),
        ),
      );
    }

    return Row(
      key: const Key('credits-pack-section'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        packCard(
          buttonKey: const Key('pack-buy-500'),
          productId: MembershipStore.creditsPack500,
          title: '500 积分',
          priceText: p500.primaryPrice,
          subtitle: '90 天有效',
          sheetTitle: '500 云端积分包',
          sheetSummary: '补充 500 云端 AI 积分，90 天内有效。',
        ),
        const SizedBox(width: 8),
        packCard(
          buttonKey: const Key('pack-buy-1200'),
          productId: MembershipStore.creditsPack1200,
          title: '1,200 积分',
          priceText: p1200.primaryPrice,
          subtitle: '90 天有效 · 更划算',
          sheetTitle: '1,200 云端积分包',
          sheetSummary: '补充 1,200 云端 AI 积分，90 天内有效。',
        ),
      ],
    );
  }

  Future<void> _handlePurchaseTap(
    BuildContext context,
    MembershipStore store, {
    required String productId,
    required String planTitle,
    required String cycleLabel,
    required String summary,
    required bool isSubscription,
  }) async {
    final price = store.displayPriceFor(productId);
    final confirmed = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (sheetCtx) {
        final sc = sheetCtx.rc;
        final bottomPad = MediaQuery.paddingOf(sheetCtx).bottom + 16;
        return Container(
          key: const Key('paywall-purchase-sheet'),
          decoration: BoxDecoration(
            color: sc.bg,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
            border: Border.all(color: sc.sep),
          ),
          child: SingleChildScrollView(
            padding: EdgeInsets.fromLTRB(16, 14, 16, bottomPad),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        isSubscription ? '确认订阅' : '确认购买',
                        style: TextStyle(
                          fontSize: 16.5,
                          fontWeight: FontWeight.w700,
                          color: sc.label,
                        ),
                      ),
                    ),
                    IconButton(
                      key: const Key('paywall-sheet-close'),
                      onPressed: () => Navigator.of(sheetCtx).pop(false),
                      icon: Icon(Icons.close_rounded, size: 20, color: sc.sec),
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(
                        minWidth: 32,
                        minHeight: 32,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                Container(
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: sc.card,
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(color: sc.sep),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Expanded(
                            child: Wrap(
                              spacing: 6,
                              runSpacing: 4,
                              crossAxisAlignment: WrapCrossAlignment.center,
                              children: [
                                Text(
                                  planTitle,
                                  style: TextStyle(
                                    fontSize: 15,
                                    fontWeight: FontWeight.w700,
                                    color: sc.label,
                                  ),
                                ),
                                Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 7,
                                    vertical: 2,
                                  ),
                                  decoration: BoxDecoration(
                                    color: sc.sec.withValues(alpha: 0.14),
                                    borderRadius: BorderRadius.circular(999),
                                  ),
                                  child: Text(
                                    cycleLabel,
                                    style: TextStyle(
                                      fontSize: 10.5,
                                      fontWeight: FontWeight.w600,
                                      color: sc.label,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(width: 8),
                          Row(
                            crossAxisAlignment: CrossAxisAlignment.baseline,
                            textBaseline: TextBaseline.alphabetic,
                            children: [
                              Text(
                                price.primaryPrice,
                                style: TextStyle(
                                  fontSize: 19,
                                  fontWeight: FontWeight.w800,
                                  color: sc.label,
                                  fontFeatures: const [
                                    FontFeature.tabularFigures(),
                                  ],
                                ),
                              ),
                              if (price.secondaryHint.isNotEmpty) ...[
                                const SizedBox(width: 3),
                                Text(
                                  price.secondaryHint,
                                  style: TextStyle(fontSize: 11, color: sc.sec),
                                ),
                              ],
                            ],
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      Text(
                        summary,
                        style: TextStyle(
                          fontSize: 12.5,
                          height: 1.45,
                          color: sc.ink,
                        ),
                      ),
                      const SizedBox(height: 10),
                      Divider(height: 1, thickness: 0.6, color: sc.sep),
                      const SizedBox(height: 10),
                      Row(
                        children: [
                          Text(
                            '支付方式',
                            style: TextStyle(fontSize: 12, color: sc.sec),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Text(
                              'Apple 支付',
                              textAlign: TextAlign.end,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 12.5,
                                fontWeight: FontWeight.w600,
                                color: sc.label,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 10),
                Text(
                  isSubscription
                      ? '确认后通过 Apple 账户扣款，到期前 24 小时自动续订，可随时在系统设置取消。'
                      : '确认后通过 Apple 账户一次性扣款，不会自动续订。',
                  style: TextStyle(fontSize: 11.5, height: 1.45, color: sc.sec),
                ),
                const SizedBox(height: 14),
                FilledButton(
                  key: const Key('paywall-sheet-confirm'),
                  onPressed: () => Navigator.of(sheetCtx).pop(true),
                  style: FilledButton.styleFrom(
                    backgroundColor: sc.label,
                    foregroundColor: sc.onLabel,
                    minimumSize: const Size.fromHeight(44),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(11),
                    ),
                  ),
                  child: Text(
                    '确认支付 · ${price.primaryPrice}',
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                ),
                const SizedBox(height: 8),
                OutlinedButton(
                  key: const Key('paywall-sheet-cancel'),
                  onPressed: () => Navigator.of(sheetCtx).pop(false),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: sc.label,
                    side: BorderSide(color: sc.sep),
                    minimumSize: const Size.fromHeight(40),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(11),
                    ),
                  ),
                  child: const Text('取消'),
                ),
              ],
            ),
          ),
        );
      },
    );

    if (confirmed != true || !mounted) return;

    final res = await store.purchase(productId);
    if (!mounted) return;

    switch (res.status) {
      case StorePurchaseStatus.purchased:
        ScaffoldMessenger.maybeOf(this.context)
          ?..hideCurrentSnackBar()
          ..showSnackBar(SnackBar(content: Text(store.lastNotice ?? '购买成功')));
      case StorePurchaseStatus.cancelled:
        ScaffoldMessenger.maybeOf(this.context)
          ?..hideCurrentSnackBar()
          ..showSnackBar(
            SnackBar(content: Text(store.lastNotice ?? '已取消本次购买')),
          );
      case StorePurchaseStatus.pending:
        ScaffoldMessenger.maybeOf(this.context)
          ?..hideCurrentSnackBar()
          ..showSnackBar(
            SnackBar(content: Text(store.lastNotice ?? '购买正在等待系统批准')),
          );
      case StorePurchaseStatus.unavailable:
      case StorePurchaseStatus.error:
      case StorePurchaseStatus.unverified:
        final isPreviewUnavailable =
            res.status == StorePurchaseStatus.unavailable;
        await showDialog<void>(
          context: this.context,
          builder: (dlgCtx) => AlertDialog(
            key: const Key('paywall-result-dialog'),
            title: Text(isPreviewUnavailable ? '支付示意' : '购买未完成'),
            content: Text(
              isPreviewUnavailable
                  ? '已完成购买确认展示，当前为预览环境，未发起 Apple 扣款，会员状态保持不变。'
                  : '本次购买未能完成，未发起扣款，请稍后重试。',
            ),
            actions: [
              TextButton(
                key: const Key('paywall-result-ok'),
                onPressed: () => Navigator.of(dlgCtx).pop(),
                child: const Text('我知道了'),
              ),
            ],
          ),
        );
    }
  }

  Widget _buildComplianceFooter(
    BuildContext context,
    RCColorScheme c,
    MembershipStore store,
  ) {
    final linkColor = c.isDark ? c.info : const Color(0xFF0F4C81);
    return Column(
      children: [
        Text(
          '通过 Apple 账户扣款，订阅到期前 24 小时自动续订，可随时在「系统设置 → Apple 账户 → 订阅」管理或取消。',
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 11.5, height: 1.55, color: c.sec),
        ),
        const SizedBox(height: 4),
        Text(
          '睡眠记录整理仅供参考，不构成医疗建议。',
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 11.5, height: 1.55, color: c.sec),
        ),
        const SizedBox(height: 8),
        Wrap(
          alignment: WrapAlignment.center,
          spacing: 8,
          runSpacing: 2,
          children: [
            TextButton(
              key: const Key('paywall-restore-btn'),
              onPressed: store.purchaseInFlight
                  ? null
                  : () async {
                      await store.restorePurchases();
                      if (!mounted) return;
                      final msg =
                          store.lastNotice ?? store.lastError ?? '已完成恢复查询';
                      ScaffoldMessenger.maybeOf(this.context)
                        ?..hideCurrentSnackBar()
                        ..showSnackBar(SnackBar(content: Text(msg)));
                    },
              style: TextButton.styleFrom(foregroundColor: linkColor),
              child: const Text('恢复购买', style: TextStyle(fontSize: 12)),
            ),
            TextButton(
              key: const Key('paywall-manage-btn'),
              onPressed: () => unawaited(store.openManageSubscriptions()),
              style: TextButton.styleFrom(foregroundColor: linkColor),
              child: const Text('管理订阅', style: TextStyle(fontSize: 12)),
            ),
            TextButton(
              key: const Key('paywall-privacy-btn'),
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<void>(builder: (_) => const PrivacyPage()),
              ),
              style: TextButton.styleFrom(foregroundColor: linkColor),
              child: const Text('隐私政策', style: TextStyle(fontSize: 12)),
            ),
            TextButton(
              key: const Key('paywall-terms-btn'),
              onPressed: () => showDialog<void>(
                context: context,
                builder: (ctx) => AlertDialog(
                  key: const Key('paywall-terms-dialog'),
                  title: const Text('使用条款'),
                  content: const Text(
                    '服务条款与技术支持请访问：\n'
                    'https://ai-card.app.reai.com/support.html\n\n'
                    '联系邮箱：privacy@reai.chat',
                  ),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.of(ctx).pop(),
                      child: const Text('关闭'),
                    ),
                  ],
                ),
              ),
              style: TextButton.styleFrom(foregroundColor: linkColor),
              child: const Text('使用条款', style: TextStyle(fontSize: 12)),
            ),
          ],
        ),
      ],
    );
  }

  static String _expiryText(int? expMs) {
    if (expMs == null || expMs <= 0) return '到期前可随时在系统设置取消';
    final dt = DateTime.fromMillisecondsSinceEpoch(expMs);
    final mm = dt.month.toString().padLeft(2, '0');
    final dd = dt.day.toString().padLeft(2, '0');
    return '有效期至 ${dt.year}-$mm-$dd · 到期前可随时取消';
  }
}
