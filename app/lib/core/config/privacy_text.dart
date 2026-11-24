/// 隐私政策正文（App 内展示的精要版）。
///
/// 为什么内联而不读 assets：`pubspec.yaml` 的 assets 声明不归本模块维护，
/// 内联常量可以保证「关于 → 隐私政策」在任何构建下都能展示，不会因为漏声明而白屏。
/// 完整条款维护在仓库 `docs/PRIVACY.md`；改动时两边同步，并更新 [privacyUpdatedAt]。
library;

/// 政策生效日期（App Store Connect / Play Console 里填写的隐私政策日期需一致）。
const String privacyUpdatedAt = '2026-11-24';

/// 隐私问题联系邮箱（与商店后台填写的支持邮箱保持一致）。
const String privacyContactEmail = 'privacy@reai.chat';

/// 一个政策小节：标题 + 若干段落（以 `- ` 开头的段落按条列渲染）。
class PrivacySection {
  const PrivacySection(this.title, this.paragraphs);

  final String title;
  final List<String> paragraphs;
}

/// 政策开头（生效日期之后、第一节之前）。
const String privacyIntro =
    '「录音卡」是配合硬件录音卡使用的手机应用。我们把「录音只属于你」当作默认设置：'
    '录音文件与转写文本默认只保存在你的手机上，云端处理只在你主动操作时发生。';

/// 政策正文各节。
const List<PrivacySection> privacySections = [
  PrivacySection('一、我们处理哪些信息', [
    '录音与转写内容：从录音卡同步到手机的音频、时间标记，以及设备侧生成的转写文本。',
    '设备信息：录音卡的蓝牙名称、电量、固件版本、Wi-Fi 配置状态。这些信息只用于连接设备与展示状态。',
    '配网信息：你输入的 Wi-Fi 名称与口令。它们只保存在本机与被配置的录音卡上，不上传服务器。',
    '账号信息（仅在你登录时）：账号标识与登录令牌（支持通过外脑账号及外脑授权页提供的 Apple / Google 方式完成登录；App 不接触或保存你的密码）。令牌保存在系统密钥库（iOS Keychain / Android Keystore），不落明文文件。',
    '微信登录（仅在你选择时）：点击「微信登录」后，App 通过微信 OpenSDK 拉起微信授权页，仅获取一次性授权码用于登录，不读取你在微信的其他信息。',
    '健康与位置（默认关闭）：只有你打开「定位与健康采集」并在系统授权页允许后，才会把已授权的健康样本和粗略位置记在本机，用来和录音时间对齐。未允许的类型不会读取，这些数据不上传。',
  ]),
  PrivacySection('二、录音内容存在哪里', [
    '默认只存本机沙盒目录，不自动上传。卸载 App 即随沙盒一起清除。',
    '本地语音引擎在手机上转写。整理、总结和 Agent 对话所需的内容按你选用的模型服务发送。',
    '健康样本与位置同样只进本机数据库，不发给云端模型。',
    'App 不读取通讯录和短信。相册只在你开启照片对齐时读取录音时段内的照片。麦克风只在本机录音或硬件断连接力时使用。',
  ]),
  PrivacySection('三、蓝牙权限的用途', [
    '用于发现并连接你的录音卡、同步录音、读取电量与录音状态、下发录音与打点命令。',
    '蓝牙扫描结果只用于识别录音卡设备，不用于推断你的地理位置，也不与其他数据关联做画像。',
  ]),
  PrivacySection('四、Wi-Fi 与本地网络的用途', [
    '用于给录音卡配网：列出附近的 2.4GHz 网络、把名称与口令写入设备、确认设备是否联网成功。',
    'App 不会借该权限访问你局域网内的其他设备，也不会抓取网络流量。',
  ]),
  PrivacySection('五、模型服务', [
    '使用外脑时，模型请求经外脑网关处理。使用其他服务时，相关请求直接发给你选择的服务地址，内容处理方式以该服务的条款为准。',
    '外脑服务端处理结果保留 30 天，用于失败重试与问题排查，之后自动删除。',
    '你在 App 内删除记录后，对应的外脑服务端副本会在 15 天内清除。',
  ]),
  PrivacySection('六、我们不做的事', [
    '- 不收集广告标识（IDFA / OAID / IMEI）用于广告投放；',
    '- 不做跨 App 追踪，不出售、不出租你的个人信息；',
    '- 不在你没有主动操作时上传录音内容。',
  ]),
  PrivacySection('七、你的控制权', [
    '删除数据：在时间轴删除单条记录，或在「设置 → 数据管理」中清空全部本机数据。',
    '切换模型服务：在「设置 → 云端模型」选择处理后续模型请求的服务。',
    '注销账号：在「设置 → 关于录音卡 → 注销账号」中操作。注销后本机数据即时清空，服务端数据在 15 天内删除且不可恢复。',
    '关闭权限：随时可在系统设置中收回蓝牙、本地网络、健康或定位权限。关闭「定位与健康采集」后不再继续采集。',
  ]),
  PrivacySection('八、未成年人保护', [
    '本 App 面向成年用户，不面向 14 周岁以下儿童。若发现儿童在未获监护人同意的情况下使用，我们会删除相关数据。',
  ]),
  PrivacySection('九、联系我们', [
    '如对隐私政策有疑问，或需要行使查阅、更正、删除、注销等权利，请联系 $privacyContactEmail，我们会在 15 个工作日内答复。',
  ]),
];

/// 纯文本形态（复制、分享、旧版页面兜底用）。
String buildPrivacyPlainText() {
  final buffer = StringBuffer()
    ..writeln('录音卡隐私政策')
    ..writeln('生效日期：$privacyUpdatedAt')
    ..writeln()
    ..writeln(privacyIntro);
  for (final section in privacySections) {
    buffer
      ..writeln()
      ..writeln(section.title);
    for (final paragraph in section.paragraphs) {
      buffer.writeln(paragraph.startsWith('- ') ? paragraph : '  $paragraph');
    }
  }
  return buffer.toString().trimRight();
}
