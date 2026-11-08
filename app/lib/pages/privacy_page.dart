/// 隐私政策页（「设置 → 关于录音卡 → 隐私政策」跳转进来）。
///
/// 内容来自 `lib/core/config/privacy_text.dart` 的内联常量（不依赖 assets 声明），
/// 排版沿用 App 的米白底 + 墨黑正文；宽屏（≥720px）限制正文宽度，避免长行难读。
library;

import 'package:flutter/material.dart';

import '../core/config/privacy_text.dart';
import '../core/theme/tokens.dart';

class PrivacyPage extends StatelessWidget {
  const PrivacyPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: RCColors.bg,
      appBar: AppBar(
        backgroundColor: RCColors.bg,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: false,
        titleSpacing: 0,
        leading: IconButton(
          icon: const Icon(Icons.chevron_left, size: 28),
          color: RCColors.label,
          tooltip: '返回',
          onPressed: () => Navigator.of(context).maybePop(),
        ),
        title: const Text(
          '隐私政策',
          style: TextStyle(
            fontSize: 17,
            fontWeight: FontWeight.w600,
            color: RCColors.label,
          ),
        ),
      ),
      body: SafeArea(
        top: false,
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 720),
            child: ListView(
              key: const Key('privacy-page'),
              padding: const EdgeInsets.fromLTRB(22, 8, 22, 40),
              children: [
                Text(
                  '生效日期：$privacyUpdatedAt',
                  style: const TextStyle(
                    fontSize: 13,
                    height: 1.5,
                    color: RCColors.sec,
                  ),
                ),
                const SizedBox(height: 16),
                _paragraph(privacyIntro),
                for (final section in privacySections) ...[
                  const SizedBox(height: 26),
                  Text(
                    section.title,
                    style: const TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w700,
                      height: 1.5,
                      color: RCColors.label,
                    ),
                  ),
                  const SizedBox(height: 8),
                  for (final paragraph in section.paragraphs)
                    _paragraph(paragraph, bullet: paragraph.startsWith('- ')),
                ],
                const SizedBox(height: 32),
                const Text(
                  '本页为精要版说明；如需完整条款或行使数据权利，请通过上方邮箱联系我们。',
                  style: TextStyle(
                    fontSize: 12,
                    height: 1.6,
                    color: RCColors.ax,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// 正文段落：`- ` 开头按条列渲染（去掉前缀，加圆点与缩进）。
  Widget _paragraph(String text, {bool bullet = false}) {
    if (!bullet) {
      return Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: Text(
          text,
          style: const TextStyle(
            fontSize: 15,
            height: 1.75,
            color: RCColors.ink,
          ),
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.only(bottom: 6, left: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Padding(
            padding: EdgeInsets.only(top: 8, right: 8),
            child: _Dot(),
          ),
          Expanded(
            child: Text(
              text.substring(2),
              style: const TextStyle(
                fontSize: 15,
                height: 1.75,
                color: RCColors.ink,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 条列圆点。
class _Dot extends StatelessWidget {
  const _Dot();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 4,
      height: 4,
      decoration: const BoxDecoration(
        color: RCColors.sec,
        shape: BoxShape.circle,
      ),
    );
  }
}
