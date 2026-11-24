/// 会员与订阅（StoreKit 2 付费墙、月度 3,600 分钟额度状态、积分加量包与合规声明）。
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/store/membership_store.dart';
import '../../core/theme/tokens.dart';
import '../../pages/privacy_page.dart';

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
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _buildQuotaCard(context, c, store),
            const SizedBox(height: 12),
            _buildCycleSelector(c, store, cycle),
            const SizedBox(height: 12),
            _buildLocalProCard(context, c, store, cycle),
            const SizedBox(height: 10),
            _buildCloudBasicCard(context, c, store, cycle),
            const SizedBox(height: 10),
            _buildCloudProCard(context, c, store, cycle),
            const SizedBox(height: 18),
            Text(
              '云端 AI 积分加量包（按需补充 · 90 天有效）',
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: c.sec,
              ),
            ),
            const SizedBox(height: 8),
            _buildCreditPacksRow(c, store),
            const SizedBox(height: 16),
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

    final barColor = store.isUnlimitedLocal
        ? c.ok
        : (store.isLocalQuotaExhausted
              ? c.danger
              : (store.isLocalQuotaWarning ? c.warn : c.label));

    final String primaryMeta;
    final String secondaryMeta;
    switch (store.tier) {
      case MembershipTier.free:
        primaryMeta =
            '本月已转写 ${store.effectiveUsedMinutes} / ${MembershipStore.freeMonthlyLimitMinutes} 分钟 · 剩余 ${store.remainingFreeMinutes} 分钟';
        secondaryMeta = '每月 1 日重置 · 不限单日 · 满额后新录音仍安全入队';
      case MembershipTier.localPro:
        primaryMeta = '无限本地离线转写 · 声纹区分 · 多格式导出';
        secondaryMeta = store.lifetimeLocalPro
            ? '永久有效（不含官方云端额度）'
            : _expiryText(store.subscriptionExpiresAtMs);
      case MembershipTier.cloudBasic:
        primaryMeta =
            '已含 Local Pro + 剩余 ${store.cloudCreditsRemaining} 云端 AI 积分';
        secondaryMeta = _expiryText(store.subscriptionExpiresAtMs);
      case MembershipTier.cloudPro:
        primaryMeta =
            '已含 Local Pro + 120h 清洗 + Pro 总结剩 ${store.cloudProSummariesRemaining} 次 / 问答 ${store.cloudProQaRemaining} 次';
        secondaryMeta = '超额自动无缝切 Flash · ${_expiryText(store.subscriptionExpiresAtMs)}';
    }

    final noticeText = store.lastError ?? store.lastNotice;
    final hasError = store.lastError != null && store.lastError!.isNotEmpty;

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
              Expanded(
                child: Text(
                  '当前方案与本月额度',
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                    color: c.label,
                  ),
                ),
              ),
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
            ],
          ),
          const SizedBox(height: 10),
          ClipRRect(
            key: const Key('membership-quota-bar'),
            borderRadius: BorderRadius.circular(999),
            child: Container(
              height: 8,
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
          const SizedBox(height: 8),
          Text(
            primaryMeta,
            style: TextStyle(
              fontSize: 12.5,
              fontWeight: FontWeight.w600,
              color: c.label,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            secondaryMeta,
            style: TextStyle(fontSize: 11.5, height: 1.45, color: c.sec),
          ),
          if (store.isLocalQuotaExhausted) ...[
            const SizedBox(height: 10),
            Container(
              padding: const EdgeInsets.all(10),
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
                '本月 3,600 分钟免费转写已满：新录音继续正常保存于本机队列，等待次月 1 日恢复或升级下方方案即刻转写。',
                style: TextStyle(
                  fontSize: 12,
                  height: 1.45,
                  color: c.isDark ? c.danger : const Color(0xFF912018),
                ),
              ),
            ),
          ],
          if (store.loadingCatalog) ...[
            const SizedBox(height: 10),
            Row(
              children: [
                SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: c.sec,
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  '正在从 App Store 拉取最新商品价格与已购权益…',
                  style: TextStyle(fontSize: 11.5, color: c.sec),
                ),
              ],
            ),
          ] else if (noticeText != null && noticeText.isNotEmpty) ...[
            const SizedBox(height: 10),
            Container(
              key: const Key('membership-storekit-notice'),
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              decoration: BoxDecoration(
                color: hasError
                    ? c.danger.withValues(alpha: 0.08)
                    : c.sec.withValues(alpha: 0.08),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(
                  color: hasError
                      ? c.danger.withValues(alpha: 0.35)
                      : c.sep,
                ),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      noticeText,
                      style: TextStyle(
                        fontSize: 11.5,
                        height: 1.45,
                        color: hasError ? c.danger : c.ink,
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
        ? '当前正在使用 Local Pro'
        : (cycle == BillingCycle.lifetime
              ? '永久买断 Local Pro'
              : '选择 Local Pro');

    return _buildPlanCard(
      c: c,
      store: store,
      cardKey: const Key('plan-card-local'),
      buttonKey: const Key('plan-buy-local'),
      title: '本地解锁版 Local Pro',
      tagText: isCurrentTier ? '当前方案' : null,
      tagIsCurrent: isCurrentTier,
      highlighted: isCurrentTier,
      primaryPrice: price.primaryPrice,
      secondaryHint: price.secondaryHint,
      bullets: const [
        '解除每月 3,600 分钟限制，无限本地离线转写',
        '完整声纹聚类命名、相册按时刻对齐、Word/PDF/Markdown/图片导出',
        '支持自接入第三方大模型（BYOK）与未来桌面端本地推理',
      ],
      extraBanner: Container(
        margin: const EdgeInsets.only(bottom: 10),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
        decoration: BoxDecoration(
          color: c.isDark
              ? c.warn.withValues(alpha: 0.14)
              : const Color(0xFFFFF7E8),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: c.isDark
                ? c.warn.withValues(alpha: 0.4)
                : const Color(0xFFF2D399),
          ),
        ),
        child: Text(
          '说明：仅解锁本机离线与 BYOK 能力，不包含官方云端 AI 清洗与总结额度。',
          style: TextStyle(
            fontSize: 11.5,
            height: 1.45,
            color: c.isDark ? c.warn : const Color(0xFF8A4300),
          ),
        ),
      ),
      productId: productId,
      ctaLabel: ctaText,
      isCurrentOwned: ownsExact,
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
    final hint = cycle == BillingCycle.lifetime
        ? '${price.secondaryHint}（云端支持按月/按年）'
        : price.secondaryHint;

    return _buildPlanCard(
      c: c,
      store: store,
      cardKey: const Key('plan-card-basic'),
      buttonKey: const Key('plan-buy-basic'),
      title: '云端基础版 Cloud Basic',
      tagText: isCurrentTier ? '当前方案' : '推荐 · 性价比',
      tagIsCurrent: isCurrentTier,
      highlighted: !isCurrentTier,
      primaryPrice: price.primaryPrice,
      secondaryHint: hint,
      bullets: const [
        '完整包含 Local Pro 全部本地转写与导出权益',
        '每月 500 云端 AI 积分（约 100 小时 DeepSeek V4.1 Flash 清洗 + 150 次总结问答）',
        '每日夜间端侧鼾声与呼吸节律特征趋势整理',
      ],
      productId: productId,
      ctaLabel: ownsExact ? '当前正在使用 Cloud 基础版' : '选择 Cloud 基础版',
      isCurrentOwned: ownsExact,
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
    final hint = cycle == BillingCycle.lifetime
        ? '${price.secondaryHint}（云端支持按月/按年）'
        : price.secondaryHint;

    return _buildPlanCard(
      c: c,
      store: store,
      cardKey: const Key('plan-card-pro'),
      buttonKey: const Key('plan-buy-pro'),
      title: '云端专业版 Cloud Pro',
      tagText: isCurrentTier ? '当前方案' : null,
      tagIsCurrent: isCurrentTier,
      highlighted: isCurrentTier,
      primaryPrice: price.primaryPrice,
      secondaryHint: hint,
      bullets: const [
        '完整包含 Local Pro 权益 + 120 小时 Flash 后台清洗分段',
        '每月 50 次 Gemini 3.1 Pro 旗舰深度总结/睡前日记 + 50 次 Pro 记忆问答',
        '旗舰次数用尽后自动无缝切换 Flash 继续使用，关键时刻不突然断档',
      ],
      productId: productId,
      ctaLabel: ownsExact ? '当前正在使用 Cloud 专业版' : '选择 Cloud 专业版',
      isCurrentOwned: ownsExact,
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
    Widget? extraBanner,
    required String productId,
    required String ctaLabel,
    required bool isCurrentOwned,
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
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
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
                  if (secondaryHint.isNotEmpty)
                    Text(
                      secondaryHint,
                      style: TextStyle(fontSize: 11, color: c.sec),
                    ),
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
          if (extraBanner != null) ...[
            const SizedBox(height: 4),
            extraBanner,
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
              onPressed: store.purchaseInFlight
                  ? null
                  : () => unawaited(store.purchase(productId)),
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

  Widget _buildCreditPacksRow(RCColorScheme c, MembershipStore store) {
    final p500 = store.displayPriceFor(MembershipStore.creditsPack500);
    final p1200 = store.displayPriceFor(MembershipStore.creditsPack1200);

    Widget packCard({
      required Key buttonKey,
      required String productId,
      required String title,
      required String subtitle,
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
              Text(
                title,
                style: TextStyle(
                  fontSize: 13.5,
                  fontWeight: FontWeight.w700,
                  color: c.label,
                ),
              ),
              const SizedBox(height: 3),
              Text(
                subtitle,
                style: TextStyle(fontSize: 11.5, height: 1.4, color: c.sec),
              ),
              const SizedBox(height: 10),
              OutlinedButton(
                key: buttonKey,
                onPressed: store.purchaseInFlight
                    ? null
                    : () => unawaited(store.purchase(productId)),
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
                        '立即购买',
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
          title: '500 积分 · ${p500.primaryPrice}',
          subtitle: '${p500.secondaryHint} · 约 +100h 清洗或 50 次 Pro',
        ),
        const SizedBox(width: 8),
        packCard(
          buttonKey: const Key('pack-buy-1200'),
          productId: MembershipStore.creditsPack1200,
          title: '1,200 积分 · ${p1200.primaryPrice}',
          subtitle: '${p1200.secondaryHint} · 约 +240h 清洗或 120 次 Pro',
        ),
      ],
    );
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
          'Apple StoreKit 2 安全支付 · 确认购买时从 Apple 账户扣款；订阅将于到期前 24 小时自动续订，可随时在「系统设置 → Apple 账户 → 订阅」管理或取消。',
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 11.5, height: 1.55, color: c.sec),
        ),
        const SizedBox(height: 6),
        Text(
          '睡眠鼾声与呼吸节律整理仅作个人健康趋势参考，不构成医疗诊断建议。',
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
                  : () => unawaited(store.restorePurchases()),
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
                  title: const Text('使用条款与技术支持'),
                  content: const Text(
                    '完整服务条款、自动续订说明与售后支持请访问：\n'
                    'https://ai-card.app.reai.com/support.html\n\n'
                    '隐私与合规咨询邮箱：privacy@reai.chat',
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
              child: const Text('使用条款与支持', style: TextStyle(fontSize: 12)),
            ),
          ],
        ),
      ],
    );
  }

  static String _expiryText(int? expMs) {
    if (expMs == null || expMs <= 0) return '有效期内自动续订 · 随时可在系统设置取消';
    final dt = DateTime.fromMillisecondsSinceEpoch(expMs);
    final mm = dt.month.toString().padLeft(2, '0');
    final dd = dt.day.toString().padLeft(2, '0');
    return '当前周期有效期至 ${dt.year}-$mm-$dd · 到期前 24 小时可随时取消';
  }
}
