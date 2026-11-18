import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../account_security_api.dart';
import '../ds/ds.dart';
import '../l10n/app_localizations.dart';
import '../state.dart';
import '../theme.dart';
import '../widgets/app_sheet.dart' show withNavBarInset;
import 'account_security_screen.dart' show recDigits, recWhen;

/// gap-recovery (board row 52) — "Is your old phone lost?"
///
/// Shown once, right after a sign-in with a one-time code (the way people
/// get back in after losing a phone), and only while OTHER phones are still
/// signed in. Before this the lost phone simply stayed signed in: whoever
/// held it kept the chats, money and family pages, and the owner had to
/// find Settings → Account & security alone. One tap signs every other
/// phone out (the same server call as that page); "No" keeps them.
class LostPhoneCheckScreen extends StatefulWidget {
  final AccountSecurityBackend? backend;
  final List<SignedInDevice> others;
  const LostPhoneCheckScreen({super.key, this.backend, required this.others});

  /// Loads the device list and pushes the screen only when another phone is
  /// still signed in. Never throws; a slow / failed load shows nothing.
  static Future<void> maybeShow(NavigatorState nav, AccountSecurityBackend backend) async {
    List<SignedInDevice> others = const [];
    try {
      final s = await backend.load().timeout(const Duration(seconds: 8));
      others = (s?.devices ?? const <SignedInDevice>[]).where((d) => !d.current).toList();
    } catch (_) {
      return;
    }
    if (others.isEmpty || !nav.mounted) return;
    await nav.push(MaterialPageRoute<void>(
        builder: (_) => LostPhoneCheckScreen(backend: backend, others: others)));
  }

  @override
  State<LostPhoneCheckScreen> createState() => _LostPhoneCheckScreenState();
}

class _LostPhoneCheckScreenState extends State<LostPhoneCheckScreen> {
  bool _busy = false;
  String? _error;

  AccountSecurityBackend get _b =>
      widget.backend ?? ApiAccountSecurityBackend(context.read<AppState>().api);

  Future<void> _signOutAll() async {
    final t = AppLocalizations.of(context);
    setState(() {
      _busy = true;
      _error = null;
    });
    final r = await _b.signOutOthers();
    if (!mounted) return;
    if (!r.ok) {
      setState(() {
        _busy = false;
        _error = r.message.isNotEmpty ? r.message : t.recovLostFailed;
      });
      return;
    }
    final tok = r.data['token'];
    if (tok is String && tok.isNotEmpty) {
      try {
        context.read<AppState>().replaceToken(tok);
      } catch (_) {}
    }
    final n = (r.data['signed_out'] as num?)?.toInt() ?? widget.others.length;
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        SnackBar(content: Text(t.recovLostDone(recDigits(context, '$n')))));
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final ds = DsTokens.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(t.recovLostTitle)),
      body: SafeArea(
        child: ListView(
          key: const Key('lost-check'),
          padding: withNavBarInset(context, const EdgeInsets.all(Gap.lg)),
          children: [
            Icon(Icons.phonelink_lock_rounded, size: 48, color: ds.dangerInk),
            const SizedBox(height: Gap.md),
            Text(t.recovLostBody, style: AType.bodyLarge.copyWith(color: ds.text)),
            const SizedBox(height: Gap.lg),
            for (final d in widget.others)
              Card(
                margin: const EdgeInsets.only(bottom: Gap.sm),
                child: ListTile(
                  key: Key('lost-device-${d.id}'),
                  leading: const Icon(Icons.phone_android_rounded),
                  title: Text(
                      d.kind == 'legacy'
                          ? t.acsecOlderApp
                          : (d.name.isEmpty ? t.acsecAndroidPhone : d.name),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis),
                  subtitle: Text(d.lastSeen != null
                      ? t.acsecLastActive(recWhen(context, d.lastSeen))
                      : t.acsecSince(recWhen(context, d.created))),
                ),
              ),
            if (_error != null) ...[
              const SizedBox(height: Gap.sm),
              Text(_error!,
                  key: const Key('lost-error'),
                  style: AType.bodyMedium.copyWith(color: ds.dangerInk)),
            ],
            const SizedBox(height: Gap.lg),
            FilledButton.icon(
              key: const Key('lost-signout-all'),
              style: FilledButton.styleFrom(
                  minimumSize: const Size(48, 52),
                  backgroundColor: ds.dangerFill,
                  foregroundColor: ds.onDangerFill),
              onPressed: _busy ? null : _signOutAll,
              icon: _busy
                  ? const SizedBox(
                      width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.logout_rounded),
              label: Text(t.recovLostSignOutAll, textAlign: TextAlign.center),
            ),
            const SizedBox(height: Gap.sm),
            OutlinedButton(
              key: const Key('lost-keep'),
              style: OutlinedButton.styleFrom(minimumSize: const Size(48, 48)),
              onPressed: _busy ? null : () => Navigator.of(context).pop(),
              child: Text(t.recovLostKeep, textAlign: TextAlign.center),
            ),
            const SizedBox(height: Gap.lg),
            Text(t.recovLostNext, style: AType.bodyMedium.copyWith(color: ds.muted)),
          ],
        ),
      ),
    );
  }
}
