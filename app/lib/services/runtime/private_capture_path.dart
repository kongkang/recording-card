import 'dart:io';

/// Native sidecars contain historical absolute paths. iOS may relocate the data
/// container on an update; only the SAME paired WAV in this app's private capture
/// directory is eligible for rebasing. Never follow a stale/external declaration.
Future<File> resolvePrivateCaptureAudio(
  Directory directory,
  File manifest,
  String declaredPath,
) async {
  final root = await directory.resolveSymbolicLinks();
  if (!(await manifest.resolveSymbolicLinks()).startsWith('$root/') ||
      !manifest.path.endsWith('.json')) {
    throw const FormatException('Invalid private capture manifest');
  }
  final paired = File(
    '${manifest.path.substring(0, manifest.path.length - 5)}.wav',
  );
  final expectedName = paired.uri.pathSegments.last;
  if (Uri.file(declaredPath).pathSegments.lastOrNull != expectedName) {
    throw const FormatException('Capture path does not match its sidecar');
  }
  String alias(String path) =>
      path.startsWith('/private/var/') ? path.substring(8) : path;
  final direct = alias(declaredPath) == alias(paired.path);
  const suffix = '/Library/Application Support/recording_card/v1/capture';
  final oldContainer = RegExp(
    r'^/(?:private/)?var/mobile/Containers/Data/Application/[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}/Library/Application Support/recording_card/v1/capture/[A-Za-z0-9_-]+\.wav$',
  ).hasMatch(declaredPath);
  if (!direct && !(oldContainer && directory.path.endsWith(suffix))) {
    throw const FormatException('Invalid private capture path');
  }
  if (!await paired.exists() ||
      !(await paired.resolveSymbolicLinks()).startsWith('$root/')) {
    throw const FormatException('Invalid private capture path');
  }
  return paired;
}
