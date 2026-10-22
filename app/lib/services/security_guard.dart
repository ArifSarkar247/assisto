import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:geolocator/geolocator.dart';
import 'package:local_auth/local_auth.dart';
import 'package:provider/provider.dart';

import '../api.dart';
import '../l10n/app_localizations.dart';
import '../widgets/password_field.dart';
import '../state.dart';
import '../theme.dart';
import '../otp_api.dart';
import '../screens/otp/otp_verify_screen.dart';

/// The outcome of gating a sensitive security action through [SecurityGuard].
///
/// HONESTY: none of these states mean Assisto physically blocked a thief. They
/// describe what the SERVER did with the ownership/action request:
///   - [applied]         — took effect immediately (low-risk action).
///   - [pending]         — queued with a delay; owner + trusted contacts
///                         alerted; cancellable until [effectiveAt].
///   - [awaitingApproval]— needs a family approver to approve first.
///   - [blocked]         — refused because of a recent theft signal (freeze).
///   - [badPin]          — wrong Assisto Security PIN.
///   - [locked]          — too many wrong PINs; temporarily locked out.
///   - [cancelled]       — the user backed out of the biometric / PIN prompt.
///   - [error]           — network / server error (nothing changed).
enum SecActionState {
  applied,
  pending,
  awaitingApproval,
  blocked,
  badPin,
  locked,
  cancelled,
  error,
}

/// Result of [SecurityGuard.run]. [effectiveAt] is only set for [pending] /
/// [awaitingApproval]; [id] is the pending-action id (for cancel/approve).
class SecActionResult {
  final SecActionState state;
  final DateTime? effectiveAt;
  final int? id;
  const SecActionResult(this.state, {this.effectiveAt, this.id});

  bool get ok => state == SecActionState.applied;
}

/// Reusable gate for sensitive, hard-to-reverse actions (disarm protection,
/// remove device admin, transfer/sell, change contacts, turn off lost mode,
/// change PIN, export data).
///
/// The gate is: (1) class-3 biometric (lazy, best-effort) → (2) Assisto
/// Security PIN (a SEPARATE secret from the phone screen lock — device
/// credential alone must NEVER substitute for it) → (3) best-effort GPS →
/// (4) POST security/action → (5) interpret + explain the result to the user.
///
/// local_auth is imported but only touched inside [ensureBiometric], and only
/// when gating an action — never at app launch. Every plugin call is wrapped
/// so a device without biometrics still works (it falls back to PIN-only).
class SecurityGuard {
  /// o1-otp: injectable for tests; defaults to the real API.
  final OtpBackend? otpBackend;
  const SecurityGuard({this.otpBackend});

  static final LocalAuthentication _auth = LocalAuthentication();

  /// hc1: MainActivity is now a FlutterFragmentActivity, so local_auth really
  /// shows BiometricPrompt. On Android 8.x (API 26/27) androidx.biometric
  /// draws its own fingerprint dialog, which needs a Theme.AppCompat activity
  /// theme — ours is the plain Flutter launch theme, so that dialog could
  /// crash. There we skip the biometric step and rely on the Security PIN
  /// (always required anyway). Null = unknown (not Android / no answer).
  static const MethodChannel _device = MethodChannel('com.assisto/device_admin');

  static Future<int?> _androidSdkInt() async {
    try {
      final m = await _device.invokeMethod<dynamic>('deviceInfo');
      if (m is Map && m['sdkInt'] is int) return m['sdkInt'] as int;
    } catch (_) {}
    return null;
  }

  /// Try a class-3 (strong) biometric. Returns true if the biometric passed OR
  /// if no biometric is enrolled / available (in which case we rely solely on
  /// the Security PIN). Returns false ONLY when a biometric exists and the user
  /// failed/cancelled it. Never throws.
  Future<bool> ensureBiometric(BuildContext context) async {
    final tr = AppLocalizations.of(context);
    try {
      final supported = await _auth.isDeviceSupported();
      final canCheck = await _auth.canCheckBiometrics;
      if (!supported || !canCheck) return true; // no biometric → rely on PIN
      final enrolled = await _auth.getAvailableBiometrics();
      if (enrolled.isEmpty) return true; // nothing enrolled → rely on PIN
      final sdk = await _androidSdkInt();
      if (sdk != null && sdk < 28) return true; // Android 8.x → PIN only
      final ok = await _auth.authenticate(
        localizedReason: tr.securityBiometricReason,
        options: const AuthenticationOptions(
          biometricOnly: true, // class-3 strong only; NOT device credential
          stickyAuth: true,
          useErrorDialogs: true,
        ),
      );
      return ok;
    } catch (_) {
      // Plugin missing / platform error / no hardware → don't block the owner;
      // the Security PIN is still required below.
      return true;
    }
  }

  /// Full gate for [action]. See [SecActionResult]. Shows the user a clear,
  /// localized message for every terminal state.
  Future<SecActionResult> run(BuildContext context, String action) async {
    final tr = AppLocalizations.of(context);

    // (a) class-3 biometric (best-effort; passes if none enrolled).
    final bio = await ensureBiometric(context);
    if (!context.mounted) return const SecActionResult(SecActionState.cancelled);
    if (!bio) {
      _snack(context, tr.securityBiometricFailed);
      return const SecActionResult(SecActionState.cancelled);
    }

    // (b) Assisto Security PIN — a SEPARATE secret; device credential alone
    // never substitutes for it.
    final pin = await _askPin(context, tr);
    if (!context.mounted) return const SecActionResult(SecActionState.cancelled);
    if (pin == null || pin.isEmpty) {
      return const SecActionResult(SecActionState.cancelled);
    }

    // (c) best-effort GPS (null if unavailable/denied — never blocks).
    final pos = await _position();

    // (d) POST security/action.
    final api = context.read<AppState>().api;
    Map<String, dynamic> resp;
    try {
      resp = await api.securityAction(action, pin,
          lat: pos?.latitude, lng: pos?.longitude);
    } on ApiException {
      if (context.mounted) _snack(context, tr.securityActionError);
      return const SecActionResult(SecActionState.error);
    } catch (_) {
      if (context.mounted) _snack(context, tr.securityActionError);
      return const SecActionResult(SecActionState.error);
    }
    if (!context.mounted) return const SecActionResult(SecActionState.error);

    // (d2) o1-otp: Section-8 SMS confirmation — the server asks for it only
    // when an SMS gateway is connected. Code step, then ONE retry with proof.
    if ('${resp['reason'] ?? ''}' == 'otp_required') {
      final proof = await OtpVerifyScreen.run(context,
          backend: otpBackend ?? ApiOtpBackend(api),
          purpose: 'section8',
          title: tr.otpSection8Title,
          intro: tr.otpSection8Intro);
      if (!context.mounted || proof == null) {
        return const SecActionResult(SecActionState.cancelled);
      }
      try {
        resp = await api.securityAction(action, pin,
            lat: pos?.latitude, lng: pos?.longitude, otpProof: proof);
      } catch (_) {
        if (context.mounted) _snack(context, tr.securityActionError);
        return const SecActionResult(SecActionState.error);
      }
      if (!context.mounted) return const SecActionResult(SecActionState.error);
      if ('${resp['reason'] ?? ''}' == 'bad_otp') {
        _snack(context, tr.otpErrExpired);
        return const SecActionResult(SecActionState.error);
      }
    }

    // (e) interpret.
    return _interpret(context, tr, resp);
  }

  SecActionResult _interpret(
      BuildContext context, AppLocalizations tr, Map<String, dynamic> resp) {
    final status = resp['_status'] as int?;
    final state = '${resp['state'] ?? ''}';
    final locked = resp['locked'] == true;
    final reason = '${resp['reason'] ?? ''}';

    // Lockout (too many wrong PINs).
    if (locked) {
      _snack(context, tr.securityLockedOut);
      return const SecActionResult(SecActionState.locked);
    }
    // Bad PIN (HTTP 403).
    if (status == 403 ||
        reason == 'bad_pin' ||
        (resp['ok'] == false && state.isEmpty)) {
      _snack(context, tr.securityBadPin);
      return const SecActionResult(SecActionState.badPin);
    }
    // Frozen (HTTP 423) — recent theft signal.
    if (status == 423 || state == 'blocked') {
      _snack(context, tr.securityBlockedFrozen);
      return const SecActionResult(SecActionState.blocked);
    }

    final eff = _parseDate(resp['effective_at']);
    final id = _asInt(resp['id']);

    if (state == 'applied') {
      _snack(context, tr.securityActionApplied);
      return const SecActionResult(SecActionState.applied);
    }
    if (state == 'awaiting_approval') {
      _dialog(context, tr.securityAwaitingTitle, tr.securityAwaitingBody);
      return SecActionResult(SecActionState.awaitingApproval,
          effectiveAt: eff, id: id);
    }
    if (state == 'pending') {
      _dialog(context, tr.securityPendingTitle, tr.securityPendingBody);
      return SecActionResult(SecActionState.pending, effectiveAt: eff, id: id);
    }
    // Unknown shape — treat as applied only if the server clearly said ok.
    if (resp['ok'] == true) {
      _snack(context, tr.securityActionApplied);
      return const SecActionResult(SecActionState.applied);
    }
    _snack(context, tr.securityActionError);
    return const SecActionResult(SecActionState.error);
  }

  // ---- helpers -----------------------------------------------------------

  Future<Position?> _position() async {
    // Identical best-effort GPS flow to the SOS path; null on any denial/error.
    try {
      if (!await Geolocator.isLocationServiceEnabled()) return null;
      var perm = await Geolocator.checkPermission();
      if (perm == LocationPermission.denied) {
        perm = await Geolocator.requestPermission();
      }
      if (perm == LocationPermission.denied ||
          perm == LocationPermission.deniedForever) {
        return null;
      }
      return await Geolocator.getCurrentPosition();
    } catch (_) {
      return null;
    }
  }

  /// Public so lightweight PIN-gated calls (e.g. Arm) can reuse the same modal.
  Future<String?> askPin(BuildContext context, AppLocalizations tr) =>
      _askPin(context, tr);

  Future<String?> _askPin(BuildContext context, AppLocalizations tr) {
    final c = TextEditingController();
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(tr.securityPinPromptTitle),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(tr.securityPinPromptBody,
                style: Theme.of(ctx).textTheme.bodySmall),
            const SizedBox(height: Gap.sm),
            ObscureTextField(
              controller: c,
              keyboardType: TextInputType.number,
              autofocus: true,
              maxLength: 8,
              decoration: InputDecoration(labelText: tr.securityPinLabel),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(tr.cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, c.text.trim()),
            child: Text(tr.securityContinue),
          ),
        ],
      ),
    );
  }

  void _snack(BuildContext context, String msg) {
    if (!context.mounted) return;
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(SnackBar(content: Text(msg)));
  }

  void _dialog(BuildContext context, String title, String body) {
    if (!context.mounted) return;
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: Text(body),
        actions: [
          FilledButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(AppLocalizations.of(ctx).ok),
          ),
        ],
      ),
    );
  }

  static DateTime? _parseDate(dynamic v) {
    if (v == null) return null;
    return DateTime.tryParse('$v')?.toLocal();
  }

  static int? _asInt(dynamic v) {
    if (v is int) return v;
    if (v is String) return int.tryParse(v);
    return null;
  }
}

/// Best-effort FOREGROUND heartbeat (Anti-theft Batch 5).
///
/// HONESTY: this is a STOPGAP, not the always-on engine. Assisto can only see
/// the phone while the app is in the foreground and online; this sends ONE
/// best-effort "I'm online (+ coarse location)" ping when the owner opens or
/// resumes the app, so a lost-but-still-online phone can report a recent
/// position. It does nothing for an offline / powered-off / flashed phone. The
/// native always-on reporter ships in the next batch.
///
/// Contract: lazy (no plugin touched at launch), fully crash-guarded, never
/// blocks startup, and only fires AFTER protection is confirmed armed. Battery
/// is omitted (no battery plugin is a dependency); network is omitted too (no
/// connectivity plugin) — the server treats both as optional.
class SecurityHeartbeat {
  SecurityHeartbeat._();

  static bool _busy = false;
  static DateTime? _lastSent;

  /// Call from the SAME on-resume hook that polls alerts (see main.dart).
  /// Fire-and-forget: await-free at the call site via `unawaited`.
  ///
  /// Flow: (1) skip if not logged in / already in flight / sent very recently;
  /// (2) GET security/lost-phone to learn if protection is ARMED (the server is
  /// the only source of truth — we never trust a cached flag); (3) if armed,
  /// best-effort GPS (null on any denial — never prompts aggressively, never
  /// blocks); (4) POST one heartbeat. Any error is swallowed.
  static Future<void> maybeSend(ApiClient api) async {
    if (api.token == null || _busy) return;
    // Light throttle so rapid resume/pause cycles don't spam the server.
    final now = DateTime.now();
    if (_lastSent != null && now.difference(_lastSent!) < const Duration(minutes: 2)) {
      return;
    }
    _busy = true;
    try {
      // Is protection actually armed? Only ping if so.
      final info = await api.securityLostPhone();
      final armed = info['armed'] == true;
      if (!armed) return;

      // Best-effort GPS — identical denial-safe flow to the SOS path. Never
      // force a permission dialog loop; if denied/unavailable we still send a
      // location-less "I'm online" ping (useful on its own).
      double? lat, lng;
      try {
        if (await Geolocator.isLocationServiceEnabled()) {
          var perm = await Geolocator.checkPermission();
          // Do NOT aggressively request here (foreground stopgap) — only use an
          // already-granted permission so opening the app never nags.
          if (perm == LocationPermission.always ||
              perm == LocationPermission.whileInUse) {
            final pos = await Geolocator.getCurrentPosition();
            lat = pos.latitude;
            lng = pos.longitude;
          }
        }
      } catch (_) {
        // GPS unavailable — send the ping without a location.
      }

      await api.securityHeartbeat(lat: lat, lng: lng);
      _lastSent = DateTime.now();
    } catch (_) {
      // Offline / server down / plugin missing — try again next resume.
    } finally {
      _busy = false;
    }
  }
}
