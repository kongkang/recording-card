/// 端侧大小双模型规格、设备能力分级（Jetsam 安全档位）与本地 GGUF 定位器。
///
/// 针对手机端两个核心任务分别配型：
/// 1. 极小极快模型（`Qwen3.5-0.8B-Q4_K_M`，~555MB）：用于短文本实时润色（如语音输入法上屏前去口癖/加标点）。
/// 2. 较大较强模型（`Qwen3.5-2B-Q4_K_M`，~1.38GB）：用于前台流式长内容总结（`nCtx = 2048` + Q8 KV Cache）。
///
/// 分级原则（实机标定基准：iPhone 13 mini 4GB vs iPhone 16 Pro 8GB）：
/// - `legacyCloudOnly`（物理内存 < 3.5 GiB，或可用 Jetsam 余量 < 900 MiB，或严重过热）：全程走云端，不加载端侧大模型；
/// - `compactLocal`（物理内存 3.5 ~ 5.5 GiB，如 iPhone 13 mini 4GB）：仅允许端侧小模型润色（`nCtx = 1024`），总结默认走云端（支持开发/压测强开）；
/// - `fullLocal`（物理内存 >= 5.5 GiB，如 iPhone 16 Pro 8GB）：端侧小模型润色 + 端侧大模型前台流式总结均可启用（若无本地 GGUF 且系统支持 iOS 26 Foundation Models，可走系统内置模型）。
library;

import 'dart:io';

import 'package:path_provider/path_provider.dart';

/// 端侧 LLM 规格档位。
enum LocalLlmTier {
  smallFast('small_fast', '轻量极速润色模型'),
  largeQuality('large_quality', '高质量总结模型');

  const LocalLlmTier(this.code, this.label);
  final String code;
  final String label;
}

/// 手机端运行能力分级。
enum DeviceLlmCapabilityTier {
  legacyCloudOnly('legacy_cloud_only', '老旧/低余量机型（自动切云端）'),
  compactLocal('compact_local', '紧凑端侧档（4GB 级：仅小模型润色）'),
  fullLocal('full_local', '完整端侧档（6GB+：大小双模型可用）');

  const DeviceLlmCapabilityTier(this.code, this.label);
  final String code;
  final String label;
}

/// 路由覆盖策略（用于设置页或 iPhone 13 mini / 16 Pro 双机对比压测）。
enum LocalLlmRoutingOverride {
  auto('auto', '自动按设备能力切换'),
  forceLocalSmall('force_local_small', '强制使用端侧小模型'),
  forceLocalLarge('force_local_large', '强制使用端侧大模型'),
  forceCloud('force_cloud', '强制使用云端模型');

  const LocalLlmRoutingOverride(this.code, this.label);
  final String code;
  final String label;

  static LocalLlmRoutingOverride fromCode(String? raw) {
    final trimmed = raw?.trim();
    for (final v in values) {
      if (v.code == trimmed) return v;
    }
    return LocalLlmRoutingOverride.auto;
  }
}

/// 最终选定的推理路由。
enum LlmExecutionRoute {
  localSmall('local_small', '端侧小模型'),
  localLarge('local_large', '端侧大模型'),
  appleFoundation('apple_foundation', '系统内置模型'),
  cloud('cloud', '云端模型'),
  unavailable('unavailable', '暂不可用');

  const LlmExecutionRoute(this.code, this.label);
  final String code;
  final String label;

  bool get isLocal =>
      this == localSmall || this == localLarge || this == appleFoundation;
}

class LlmRouteDecision {
  const LlmRouteDecision({
    required this.route,
    required this.deviceTier,
    required this.reason,
    this.spec,
    this.recommendedCtx = 1024,
  });

  final LlmExecutionRoute route;
  final DeviceLlmCapabilityTier deviceTier;
  final String reason;
  final LocalLlmModelSpec? spec;
  final int recommendedCtx;
}

class LocalLlmModelSpec {
  const LocalLlmModelSpec({
    required this.id,
    required this.displayName,
    required this.fileName,
    required this.approxBytes,
    required this.tier,
    required this.recommendedCtx,
    required this.minPhysicalMemoryBytes,
    this.downloadRelPath = '',
    this.sha256 = '',
  });

  final String id;
  final String displayName;
  final String fileName;
  final int approxBytes;
  final LocalLlmTier tier;
  final int recommendedCtx;
  final int minPhysicalMemoryBytes;
  final String downloadRelPath;
  final String sha256;

  String get sizeLabel {
    if (approxBytes >= 1000 * 1000 * 1000) {
      return '${(approxBytes / (1000 * 1000 * 1000)).toStringAsFixed(2)} GB';
    }
    return '${(approxBytes / (1000 * 1000)).round()} MB';
  }
}

/// 极小极快：用于短句/输入法实时润色（关闭 thinking）。
const LocalLlmModelSpec qwen35SmallPolishSpec = LocalLlmModelSpec(
  id: 'qwen3.5-0.8b-q4_k_m',
  displayName: 'Qwen3.5 0.8B（轻量极速润色）',
  fileName: 'Qwen3.5-0.8B-Q4_K_M.gguf',
  approxBytes: 555000000,
  tier: LocalLlmTier.smallFast,
  recommendedCtx: 1024,
  minPhysicalMemoryBytes: 3500000000,
  downloadRelPath: 'llm/qwen3.5-0.8b-q4_k_m/Qwen3.5-0.8B-Q4_K_M.gguf',
);

/// 较大较强：用于前台流式总结（4-bit 量化 + Q8 KV Cache + nCtx<=2048）。
const LocalLlmModelSpec qwen35LargeSummarySpec = LocalLlmModelSpec(
  id: 'qwen3.5-2b-q4_k_m',
  displayName: 'Qwen3.5 2B（高质量流式总结）',
  fileName: 'Qwen3.5-2B-Q4_K_M.gguf',
  approxBytes: 1380000000,
  tier: LocalLlmTier.largeQuality,
  recommendedCtx: 2048,
  minPhysicalMemoryBytes: 5500000000,
  downloadRelPath: 'llm/qwen3.5-2b-q4_k_m/Qwen3.5-2B-Q4_K_M.gguf',
);

const List<LocalLlmModelSpec> localLlmRegistry = [
  qwen35SmallPolishSpec,
  qwen35LargeSummarySpec,
];

/// 设备端硬件与运行时能力快照。
class DeviceLlmCapabilities {
  const DeviceLlmCapabilities({
    required this.platform,
    required this.physicalMemoryBytes,
    this.availableMemoryBytes = 0,
    this.osMajorVersion = 0,
    this.machineModel = '',
    this.supportsFoundationModels = false,
    this.llamaRuntimeLinked = false,
    this.thermalState = 'nominal',
  });

  static const DeviceLlmCapabilities unknown = DeviceLlmCapabilities(
    platform: 'unknown',
    physicalMemoryBytes: 0,
  );

  final String platform;
  final int physicalMemoryBytes;
  final int availableMemoryBytes;
  final int osMajorVersion;
  final String machineModel;
  final bool supportsFoundationModels;
  final bool llamaRuntimeLinked;
  final String thermalState;

  double get physicalMemoryGiB => physicalMemoryBytes / (1024 * 1024 * 1024);
  double get availableMemoryMiB => availableMemoryBytes / (1024 * 1024);

  factory DeviceLlmCapabilities.fromMap(Map<Object?, Object?> raw) =>
      DeviceLlmCapabilities(
        platform: '${raw['platform'] ?? 'unknown'}',
        physicalMemoryBytes:
            (raw['physicalMemoryBytes'] as num?)?.toInt() ?? 0,
        availableMemoryBytes:
            (raw['availableMemoryBytes'] as num?)?.toInt() ?? 0,
        osMajorVersion: (raw['osMajorVersion'] as num?)?.toInt() ?? 0,
        machineModel: '${raw['machineModel'] ?? ''}',
        supportsFoundationModels: raw['supportsFoundationModels'] == true,
        llamaRuntimeLinked: raw['llamaRuntimeLinked'] == true,
        thermalState: '${raw['thermalState'] ?? 'nominal'}',
      );

  Map<String, dynamic> toJson() => {
    'platform': platform,
    'physicalMemoryBytes': physicalMemoryBytes,
    'availableMemoryBytes': availableMemoryBytes,
    'osMajorVersion': osMajorVersion,
    'machineModel': machineModel,
    'supportsFoundationModels': supportsFoundationModels,
    'llamaRuntimeLinked': llamaRuntimeLinked,
    'thermalState': thermalState,
  };
}

/// 纯函数：依据物理内存、当前 Jetsam 可用余量与温控状态评估设备分级。
DeviceLlmCapabilityTier evaluateDeviceLlmTier(DeviceLlmCapabilities caps) {
  const int minCompactPhysicalBytes = 3758096384; // 3.5 GiB（兼容标称 4GB iPhone 13 mini）
  const int minFullPhysicalBytes = 5905580032; // 5.5 GiB（兼容标称 6GB/8GB 机型）
  const int minCompactAvailableBytes = 943718400; // 900 MiB
  const int minFullAvailableBytes = 2147483648; // 2.0 GiB

  if (caps.thermalState.toLowerCase() == 'critical') {
    return DeviceLlmCapabilityTier.legacyCloudOnly;
  }
  if (caps.physicalMemoryBytes < minCompactPhysicalBytes) {
    return DeviceLlmCapabilityTier.legacyCloudOnly;
  }
  if (caps.availableMemoryBytes > 0 &&
      caps.availableMemoryBytes < minCompactAvailableBytes) {
    return DeviceLlmCapabilityTier.legacyCloudOnly;
  }
  if (caps.physicalMemoryBytes < minFullPhysicalBytes) {
    return DeviceLlmCapabilityTier.compactLocal;
  }
  if (caps.availableMemoryBytes > 0 &&
      caps.availableMemoryBytes < minFullAvailableBytes) {
    return DeviceLlmCapabilityTier.compactLocal;
  }
  return DeviceLlmCapabilityTier.fullLocal;
}

class LocalLlmInstallStatus {
  const LocalLlmInstallStatus({
    required this.spec,
    required this.installed,
    required this.filePath,
    this.actualBytes = 0,
  });

  final LocalLlmModelSpec spec;
  final bool installed;
  final String filePath;
  final int actualBytes;
}

/// 定位本机已放置/已下载的 GGUF 模型文件。
///
/// 路径规范：`<ApplicationSupport>/models/llm/<spec.id>/<spec.fileName>`，
/// 与现有 ASR 模型 `Library/Application Support/models/` 同根，方便 `devicectl` 拷贝实测。
class LocalLlmModelLocator {
  LocalLlmModelLocator({Directory? rootOverride}) : _rootOverride = rootOverride;

  final Directory? _rootOverride;

  Future<Directory> baseDir() async {
    final base =
        _rootOverride ??
        Directory('${(await getApplicationSupportDirectory()).path}/models/llm');
    if (!await base.exists()) {
      await base.create(recursive: true);
    }
    return base;
  }

  Future<String> pathFor(LocalLlmModelSpec spec) async {
    final root = await baseDir();
    return '${root.path}/${spec.id}/${spec.fileName}';
  }

  Future<LocalLlmInstallStatus> statusFor(LocalLlmModelSpec spec) async {
    try {
      final path = await pathFor(spec);
      final f = File(path);
      if (!await f.exists()) {
        return LocalLlmInstallStatus(
          spec: spec,
          installed: false,
          filePath: path,
        );
      }
      final len = await f.length();
      // 防止半截空文件被当作已安装；测试用假 GGUF 只要非空即可时可通过显式路径注入。
      final installed = len > 0;
      return LocalLlmInstallStatus(
        spec: spec,
        installed: installed,
        filePath: path,
        actualBytes: len,
      );
    } on Object {
      return LocalLlmInstallStatus(
        spec: spec,
        installed: false,
        filePath: '',
      );
    }
  }
}
