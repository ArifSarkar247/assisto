import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:local_auth/local_auth.dart';
import 'package:provider/provider.dart';

import '../api.dart';
import '../l10n/app_localizations.dart';
import '../state.dart';
import '../theme.dart';

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
  const SecurityGuard();

  static final LocalAuthentication _auth = LocalAuthentication();

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
            TextField(
              controller: c,
              keyboardType: TextInputType.number,
              obscureText: true,
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
