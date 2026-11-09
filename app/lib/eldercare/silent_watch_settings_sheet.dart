import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../theme.dart';
import 'elder_common.dart';
import 'silent_watch_brain.dart';
import 'silent_watch_client.dart';

/// fcelder — the ELDER's own view of Silent Watch: what it does, who is told,
/// that nothing about phone use leaves the phone, and a one-tap way to turn
/// it off (the setter is told — no hidden switch-offs, no hidden watching).
class SilentWatchSettingsSheet extends StatefulWidget {
  const SilentWatchSettingsSheet({super.key});

  @override
  State<SilentWatchSettingsSheet> createState() => _SilentWatchSettingsSheetState();
}

class _SilentWatchSettingsSheetState extends State<SilentWatchSettingsSheet> {
  Map<String, dynamic>? _cfg;
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final api = ElderHooks.api(context);
    if (api == null) return;
    try {
      final r = await api.status();
      final m = (r['mine'] as Map?)?['config'];
      if (mounted) setState(() => _cfg = m is Map ? Map<String, dynamic>.from(m) : null);
    } catch (_) {
      if (mounted) setState(() => _error = AppLocalizations.of(context).fceOffline);
    }
  }

  Future<void> _setEnabled(bool on) async {
    final t = AppLocalizations.of(context);
    if (!on) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          scrollable: true,
          title: Text(t.fceWatchTurnOff, style: AType.headlineSmall),
          content: Text(t.fceWatchTurnOffBody('${_cfg?['setter_name'] ?? ''}'), style: AType.titleLarge),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(t.cancel)),
            FilledButton(
                style: Brand.dangerButton(),
                onPressed: () => Navigator.pop(ctx, true),
                child: Text(t.fceWatchTurnOff)),
          ],
        ),
      );
      if (ok != true) return;
    }
    final api = ElderHooks.api(context);
    if (api == null || !mounted) return;
    final lang = ElderHooks.lang(context);
    setState(() => _busy = true);
    try {
      final r = await api.setConfig({'enabled': on});
      final cfg = Map<String, dynamic>.from(r['config'] as Map);
      await SilentWatchClient.configure(api, cfg, lang: lang);
      if (mounted) setState(() => _cfg = cfg);
    } catch (_) {
      if (mounted) setState(() => _error = t.fceOffline);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final bn = ElderHooks.lang(context) == 'bn';
    final c = _cfg;
    final scheme = Theme.of(context).colorScheme;
    final cfg = c == null ? const SwConfig() : SwConfig.fromJson(c);
    final on = c?['enabled'] == true;
    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(Gap.xl, 0, Gap.xl, Gap.xl),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(t.fceWatchTitle, style: AType.headlineMedium.copyWith(fontWeight: FontWeight.w800)),
            const SizedBox(height: Gap.sm),
            Text(t.fceWatchExplain('${c?['setter_name'] ?? ''}'), style: AType.titleLarge),
            const SizedBox(height: Gap.md),
            if (c == null && _error == null)
              const Padding(
                  padding: EdgeInsets.all(Gap.lg), child: Center(child: CircularProgressIndicator()))
            else if (c != null) ...[
              _row(Icons.timer_outlined, t.fceWatchHours(elderDigits(cfg.hours, bn))),
              _row(Icons.wb_sunny_outlined,
                  t.fceWatchDay(elderHhmm(cfg.dayStartMin, bn), elderHhmm(cfg.dayEndMin, bn))),
              _row(Icons.groups_rounded,
                  t.fceWatchWho('${c['setter_name'] ?? ''}', '${c['nearby_name'] ?? ''}'.isEmpty
                      ? t.fceSetupNearbyNone
                      : '${c['nearby_name']}')),
              _row(Icons.lock_outline_rounded, t.fceWatchPrivacy),
              const SizedBox(height: Gap.lg),
              SizedBox(
                height: 56,
                child: on
                    ? OutlinedButton(
                        key: const Key('fce-watch-off'),
                        onPressed: _busy ? null : () => _setEnabled(false),
                        child: Text(t.fceWatchTurnOff, style: AType.titleLarge.copyWith(color: scheme.error)))
                    : FilledButton(
                        key: const Key('fce-watch-on'),
                        style: Brand.successButton(),
                        onPressed: _busy ? null : () => _setEnabled(true),
                        child: Text(t.fceWatchTurnOn, style: AType.titleLarge)),
              ),
            ],
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(top: Gap.md),
                child: Text(_error!, style: AType.titleMedium.copyWith(color: scheme.error)),
              ),
          ],
        ),
      ),
    );
  }

  Widget _row(IconData i, String text) => Padding(
        padding: const EdgeInsets.symmetric(vertical: Gap.sm),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Icon(i, size: 28),
          const SizedBox(width: Gap.md),
          Expanded(child: Text(text, style: AType.titleLarge)),
        ]),
      );
}
