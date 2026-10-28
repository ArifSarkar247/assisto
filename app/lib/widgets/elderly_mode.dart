import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../state.dart';
import '../theme.dart';
import '../l10n/app_localizations.dart';

/// SPEC v2.1 feature 29 — ELDERLY SIMPLE-MODE controller + toggle.
///
/// Simple mode is a single on/off preference that, when on, routes the app
/// home to [ElderlyHomeScreen] (a large-text, high-contrast, minimal-depth
/// launcher). The state lives in a local [Settings] flag `elderly_mode` so the
/// runtime can read it synchronously-after-load without touching the profile
/// API; it is ALSO best-effort synced to the backend profile field
/// `elderly_mode` (already modelled: core/models.py User.elderly_mode) so a
/// family member's tooling can see the state. Local flag is authority for
/// routing; the server value is a mirror.
///
/// Respect / consent: a child may turn this ON for a parent ONLY after an
/// explicit parent-permission confirmation. This reuses the exact pattern from
/// the fall-detect screen (see FallDetectScreen._confirmParentPermission) —
/// same two-button "I have their permission / cancel" gate — so consent is
/// handled identically across safety features.
///
/// All strings come from AppLocalizations (bilingual). No Bangla literals live
/// in this file (language gate).
class EldersModeController {
  /// Local-settings key (authority for home routing).
  static const String kFlag = 'elderly_mode';

  /// Read the current simple-mode flag. Defaults OFF.
  static Future<bool> isOn() => Settings.getBool(kFlag, false);

  /// Read the flag once at startup (used by the router). Falls back to the
  /// profile value when a local flag has never been written, so a parent who
  /// had it enabled from another device still lands in simple mode.
  static Future<bool> resolveForRouting(AppState app) async {
    final local = await Settings.getBool(kFlag, false);
    if (local) return true;
    // Never written locally AND the profile says on -> honour the profile.
    final seenLocal = await Settings.getString('${kFlag}_set');
    if (seenLocal == null && (app.user?.elderlyMode ?? false)) return true;
    return local;
  }

  /// Persist the flag locally and best-effort to the profile. Does NOT show any
  /// consent UI — callers that enable it for someone else must gate first with
  /// [confirmParentPermission].
  static Future<void> set(BuildContext context, bool value) async {
    await Settings.setBool(kFlag, value);
    await Settings.setString('${kFlag}_set', '1');
    try {
      // ignore: use_build_context_synchronously
      await context.read<AppState>().saveProfile({'elderly_mode': value});
    } catch (_) {/* offline — local flag already saved; sync later */}
  }

  /// The parent-permission gate (reuses the fall-detect consent pattern).
  /// Returns true only when the person explicitly confirms they have the
  /// parent's permission. ALWAYS call this before enabling simple mode on
  /// someone else's behalf.
  static Future<bool> confirmParentPermission(BuildContext context) async {
    final t = AppLocalizations.of(context);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        scrollable: true, // insets: 200% text / keyboard
        icon: const Icon(Icons.family_restroom_rounded, color: Brand.blue),
        title: Text(t.elderlyPermissionTitle),
        content: Text(t.elderlyPermissionBody),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(t.elderlyPermissionDecline),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(t.elderlyPermissionConfirm),
          ),
        ],
      ),
    );
    return ok == true;
  }
}

/// A prominent, accessible ENTER / EXIT simple-mode toggle.
///
/// Drop this into Settings (SETTINGS WIRING — see note below). When turning ON,
/// it first runs the parent-permission gate (a child enabling it for a parent),
/// then a plain confirm so a self-enabling user isn't surprised by the changed
/// home. When turning OFF from inside simple mode it confirms too (a confused
/// tap shouldn't bounce the user out).
///
/// The toggle is deliberately large (>=56dp row, big switch) so it is usable by
/// the same audience it serves.
class ElderlyModeTile extends StatefulWidget {
  /// Called after the flag changes so the host (e.g. the router/root) can
  /// rebuild and re-route home. Optional.
  final ValueChanged<bool>? onChanged;
  const ElderlyModeTile({super.key, this.onChanged});

  @override
  State<ElderlyModeTile> createState() => _ElderlyModeTileState();
}

class _ElderlyModeTileState extends State<ElderlyModeTile> {
  bool _on = false;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    EldersModeController.isOn().then((v) {
      if (mounted) setState(() {
            _on = v;
            _loading = false;
          });
    });
  }

  Future<void> _toggle(bool value) async {
    final t = AppLocalizations.of(context);
    if (value) {
      // 1) consent gate (child-for-parent) 2) plain confirm.
      if (!await EldersModeController.confirmParentPermission(context)) return;
      if (!mounted) return;
      final go = await _confirm(
          t.elderlyEnterConfirmTitle, t.elderlyEnterConfirmBody,
          t.elderlyEnterConfirmCta);
      if (go != true) return;
    } else {
      final go = await _confirm(
          t.elderlyExitConfirmTitle, t.elderlyExitConfirmBody,
          t.elderlyExitConfirmCta);
      if (go != true) return;
    }
    if (!mounted) return;
    await EldersModeController.set(context, value);
    if (!mounted) return;
    setState(() => _on = value);
    widget.onChanged?.call(value);
  }

  Future<bool?> _confirm(String title, String body, String cta) {
    final t = AppLocalizations.of(context);
    return showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        scrollable: true, // insets: 200% text / keyboard
        icon: const Icon(Icons.elderly_rounded, color: Brand.blue),
        title: Text(title),
        content: Text(body),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(t.cancel)),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true), child: Text(cta)),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    return ConstrainedBox(
      constraints: const BoxConstraints(minHeight: 56),
      child: SwitchListTile(
        secondary: const Icon(Icons.elderly_rounded, size: 28),
        title: Text(t.elderlyToggleTitle,
            style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600)),
        subtitle: Text(t.elderlyToggleSubtitle),
        value: _on,
        onChanged: _loading ? null : _toggle,
      ),
    );
  }
}
