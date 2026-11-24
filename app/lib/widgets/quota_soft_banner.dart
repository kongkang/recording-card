/// Timeline 顶部 3,600 分钟月度免费本地转写额度预警 / 柔和满额提示条。
///
/// 软保护硬原则：绝不中断录音；满额后明确告知用户新录音继续安全入本机队列，
/// 可等待次月 1 日恢复或点击跳转「会员与订阅」立即解锁。
library;

import 'package:flutter/material.dart';

import '../core/store/membership_store.dart';
import '../core/theme/tokens.dart';

class QuotaSoftBanner extends StatelessWidget {
  const QuotaSoftBanner({
    super.key,
    this.membership,
    required this.onOpenMembership,
    this.margin = const EdgeInsets.only(bottom: 12),
  });

  final MembershipStore? membership;
  final VoidCallback onOpenMembership;
  final EdgeInsetsGeometry margin;

  @override
  Widget build(BuildContext context) {
    final store = membership ?? MembershipScope.maybeOf(context);
    if (store == null) return const SizedBox.shrink();

    return ListenableBuilder(
      listenable: store,
      builder: (context, _) {
        if (!store.isLocalQuotaWarning && !store.isLocalQuotaExhausted) {
          return const SizedBox.shrink();
        }
        final c = context.rc;
        final exhausted = store.isLocalQuotaExhausted;
        final bg = exhausted
            ? (c.isDark
                  ? c.danger.withValues(alpha: 0.16)
                  : const Color(0xFFFEF3F2))
            : (c.isDark
                  ? c.warn.withValues(alpha: 0.14)
                  : const Color(0xFFFFF8EB));
        final border = exhausted
            ? (c.isDark
                  ? c.danger.withValues(alpha: 0.45)
                  : const Color(0xFFFECDCA))
            : (c.isDark
                  ? c.warn.withValues(alpha: 0.45)
                  : const Color(0xFFF2C97D));
        final fg = exhausted
            ? (c.isDark ? c.danger : const Color(0xFF912018))
            : (c.isDark ? c.warn : const Color(0xFF7A3E00));

        final message = exhausted
            ? '本月 3,600 分钟免费本地转写已用完。新录音仍继续保存至本机队列，不中断录音；次月 1 日恢复或升级解锁后自动继续转写。'
            : '本月免费本地转写额度已用 ${store.effectiveUsedMinutes} / ${MembershipStore.freeMonthlyLimitMinutes} 分钟，剩余 ${store.remainingFreeMinutes} 分钟（每月 1 日自动重置）。';

        return Padding(
          padding: margin,
          child: Container(
            key: const Key('quota-soft-banner'),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              color: bg,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: border),
            ),
            child: Row(
              children: [
                Icon(
                  exhausted
                      ? Icons.pause_circle_outline_rounded
                      : Icons.timelapse_rounded,
                  size: 18,
                  color: fg,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    message,
                    style: TextStyle(fontSize: 12, height: 1.45, color: fg),
                  ),
                ),
                const SizedBox(width: 8),
                Material(
                  color: c.label,
                  borderRadius: BorderRadius.circular(999),
                  child: InkWell(
                    key: const Key('quota-banner-upgrade'),
                    borderRadius: BorderRadius.circular(999),
                    onTap: onOpenMembership,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 7,
                      ),
                      child: Text(
                        exhausted ? '立即解锁' : '查看会员',
                        style: TextStyle(
                          fontSize: 11.5,
                          fontWeight: FontWeight.w600,
                          color: c.onLabel,
                        ),
                      ),
                    ),
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
