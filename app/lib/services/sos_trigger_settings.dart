import '../l10n/app_localizations.dart';
import '../state.dart';
import 'antitheft_service.dart';
import 'safety_triggers_logic.dart';

/// sosat — the three opt-in SOS triggers that run inside the Always-on
/// protection service. Stored on this phone (Settings) and mirrored to the
/// native side together with the notification texts in the ACTIVE language
/// only (never "bn / en").
class SosTriggerSettings {
  static const kLock = 'sosat_lock_on';
  static const kPower = 'sosat_power_on';
  static const kFall = 'safety_fall_on'; // the old local fall key, reused
  static const kFallWin = 'safety_fall_win';

  bool lockOn;
  bool powerOn;
  bool fallOn;
  int fallWindowS;

  SosTriggerSettings({
    this.lockOn = false,
    this.powerOn = false,
    this.fallOn = false,
    this.fallWindowS = FallPolicy.windowDefaultS,
  });

  static Future<SosTriggerSettings> load() async => SosTriggerSettings(
        lockOn: await Settings.getBool(kLock, false),
        powerOn: await Settings.getBool(kPower, false),
        fallOn: await Settings.getBool(kFall, false),
        fallWindowS: FallPolicy.clampWindow(
            int.tryParse(await Settings.getString(kFallWin) ?? '') ??
                FallPolicy.windowDefaultS),
      );

  /// Native notification texts (active language).
  static Map<String, Object> texts(AppLocalizations t) => {
        'sosAction': t.saNotifSosAction,
        'sosArmTitle': t.saNotifArmTitle,
        'sosArmBody': t.saNotifArmBody,
        'sosCancel': t.saNotifCancel,
        'sosSentTitle': t.saNotifSentTitle,
        'sosSentBody': t.saNotifSentBody,
        'fallTitle': t.saNotifFallTitle,
        'fallBody': t.saNotifFallBody,
        'fallOk': t.saNotifFallOk,
      };

  /// Test seam for the native push (default: AntiTheftService).
  static Future<bool> Function(Map<String, Object>) push =
      AntiTheftService.setSosTriggers;

  Future<void> save(AppLocalizations t) async {
    await Settings.setBool(kLock, lockOn);
    await Settings.setBool(kPower, powerOn);
    await Settings.setBool(kFall, fallOn);
    await Settings.setString(kFallWin, '$fallWindowS');
    await push({
      'lock_on': lockOn,
      'power_on': powerOn,
      'fall_on': fallOn,
      'fall_window_s': fallWindowS,
      ...texts(t),
    });
  }
}
