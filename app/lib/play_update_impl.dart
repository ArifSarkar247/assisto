// ota1: the ONLY file that imports in_app_update. Loaded as a deferred
// library by play_update.dart, in the Play build only.
import 'package:in_app_update/in_app_update.dart';

/// True when Play already holds a downloaded update waiting to install.
Future<bool> isDownloaded() async {
  final info = await InAppUpdate.checkForUpdate();
  return info.installStatus == InstallStatus.downloaded;
}

/// Shows Play's own flexible-update prompt when a newer version is on the
/// tester's track. Completes true once the download has finished.
Future<bool> startFlexibleIfAvailable() async {
  final info = await InAppUpdate.checkForUpdate();
  if (info.installStatus == InstallStatus.downloaded) return true;
  if (info.updateAvailability != UpdateAvailability.updateAvailable ||
      !info.flexibleUpdateAllowed) {
    return false;
  }
  final r = await InAppUpdate.startFlexibleUpdate();
  return r == AppUpdateResult.success;
}

Future<void> complete() => InAppUpdate.completeFlexibleUpdate();
