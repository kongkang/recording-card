import 'package:connectivity_plus/connectivity_plus.dart';

import '../settings/app_settings.dart';

enum RecordingNetwork { wifi, mobile, ethernet, offline, unknown }

abstract interface class RecordingNetworkProbe {
  Future<RecordingNetwork> current();
}

class ConnectivityRecordingNetworkProbe implements RecordingNetworkProbe {
  final Connectivity connectivity;
  ConnectivityRecordingNetworkProbe({Connectivity? connectivity})
    : connectivity = connectivity ?? Connectivity();
  @override
  Future<RecordingNetwork> current() async {
    final results = await connectivity.checkConnectivity();
    if (results.contains(ConnectivityResult.wifi)) return RecordingNetwork.wifi;
    if (results.contains(ConnectivityResult.mobile)) {
      return RecordingNetwork.mobile;
    }
    if (results.contains(ConnectivityResult.ethernet)) {
      return RecordingNetwork.ethernet;
    }
    if (results.isEmpty ||
        results.every((result) => result == ConnectivityResult.none)) {
      return RecordingNetwork.offline;
    }
    return RecordingNetwork.unknown;
  }
}

class RecordingNetworkPolicyException implements Exception {
  final String message;
  const RecordingNetworkPolicyException(this.message);
  @override
  String toString() => 'RecordingNetworkPolicyException: $message';
}

class RecordingNetworkPolicy {
  final RecordingNetworkProbe probe;
  RecordingNetworkPolicy({RecordingNetworkProbe? probe})
    : probe = probe ?? ConnectivityRecordingNetworkProbe();
  Future<void> requireTransfer(AppSettings settings) async {
    final network = await probe.current();
    if (settings.wifiOnlySync && network != RecordingNetwork.wifi) {
      throw const RecordingNetworkPolicyException(
        '仅 Wi-Fi 同步已开启，请连接 Wi-Fi 后重试',
      );
    }
    if (network == RecordingNetwork.offline ||
        network == RecordingNetwork.unknown) {
      throw const RecordingNetworkPolicyException('无法确认可用网络，请检查网络后重试');
    }
  }
}
