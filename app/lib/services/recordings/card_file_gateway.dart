/// 录音卡文件接缝 —— 真实实现由 card_bridge 的 BLE/AP 传输提供；
/// 测试注入内存网关，不触发蓝牙。
library;

import 'dart:typed_data';

class RemoteRecordingFile {
  const RemoteRecordingFile({
    required this.id,
    required this.name,
    required this.sizeBytes,
    required this.recordedAt,
    this.mark,
  });

  final String id;
  final String name;
  final int sizeBytes;
  final DateTime recordedAt;
  final String? mark;
}

abstract class CardFileGateway {
  Future<List<RemoteRecordingFile>> listFiles();

  Future<Uint8List> download(String fileId);

  Future<void> upload(String fileId, Uint8List bytes);
}
