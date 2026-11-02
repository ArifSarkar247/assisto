import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import '../l10n/app_localizations.dart';
import '../theme.dart';

/// The runtime permissions we show a reason for before requesting.
///
/// playall (Play "prominent disclosure"): every runtime location / microphone
/// / camera ask in the app is preceded by one of these in-app screens (or a
/// feature's own disclosure: anti-theft [AtDisclosure], contacts
/// [C1Disclosure], Health Connect's connect card). Guarded by
/// test/play_disclosure_guard_test.dart.
///   [location]  one-off location for the action the user just asked for
///   [journey]   Safe Journey live location — continues while the app is
///               closed / screen off until the journey ends (location FGS)
///   [voiceSos]  Voice SOS — microphone listening while the app is closed +
///               location sent with the SOS (microphone|location FGS)
enum PermKind { mic, location, camera, journey, voiceSos }

/// Shows a clear reason (in the user's language) BEFORE a runtime permission is
/// requested, so the user understands why — better grant rate, Play-policy
/// friendly. Returns true if the user chose to continue.
Future<bool> showPermissionReason(BuildContext context, PermKind kind) async {
  final t = AppLocalizations.of(context);
  final (IconData icon, String reason) = switch (kind) {
    PermKind.mic => (Icons.mic_none_rounded, t.permMic),
    PermKind.location => (Icons.location_on_rounded, t.permLocation2),
    PermKind.camera => (Icons.photo_camera_rounded, t.permCamera),
    PermKind.journey => (Icons.route_rounded, t.permJourneyLoc),
    PermKind.voiceSos => (Icons.record_voice_over_rounded, t.permVoiceSos),
  };
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) {
      final scheme = Theme.of(ctx).colorScheme;
      return AlertDialog(
        key: Key('perm-reason-${kind.name}'),
        scrollable: true, // insets: 200% text / keyboard
        icon: Icon(icon, size: 36, color: scheme.primary),
        content: Text(reason,
            textAlign: TextAlign.center, style: const TextStyle(height: 1.4)),
        actionsAlignment: MainAxisAlignment.spaceBetween,
        actions: [
          TextButton(
              key: const Key('perm-reason-no'),
              style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(t.notNow)),
          FilledButton(
              key: const Key('perm-reason-yes'),
              style: FilledButton.styleFrom(minimumSize: const Size(48, 48)),
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(t.continueWord)),
        ],
      );
    },
  );
  return ok == true;
}

/// playall: the ONE way to ask Android for location after the in-app reason.
/// Shows [kind]'s disclosure only when Android would really prompt (never
/// asked yet = `denied`); "Not now" leaves the permission untouched and
/// returns the current state. Never throws (best-effort callers).
/// [check] / [request] are test seams.
Future<LocationPermission> askLocationWithReason(
  BuildContext context, {
  PermKind kind = PermKind.location,
  Future<LocationPermission> Function()? check,
  Future<LocationPermission> Function()? request,
}) async {
  try {
    var perm = await (check ?? Geolocator.checkPermission)();
    if (perm != LocationPermission.denied) return perm;
    if (!context.mounted) return perm;
    if (!await showPermissionReason(context, kind)) return perm;
    perm = await (request ?? Geolocator.requestPermission)();
    return perm;
  } catch (_) {
    return LocationPermission.denied;
  }
}

/// Small helper for a brand-styled empty permission prompt inside a screen.
Widget permissionBlock(BuildContext context,
    {required IconData icon, required String text, required VoidCallback onTap,
    required String button}) {
  final scheme = Theme.of(context).colorScheme;
  return Center(
    child: Padding(
      padding: const EdgeInsets.all(Gap.xxl),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Icon(icon, size: 48, color: scheme.primary),
        const SizedBox(height: Gap.lg),
        Text(text, textAlign: TextAlign.center,
            style: TextStyle(color: scheme.onSurfaceVariant, height: 1.4)),
        const SizedBox(height: Gap.lg),
        FilledButton(onPressed: onTap, child: Text(button)),
      ]),
    ),
  );
}
