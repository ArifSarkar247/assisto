import 'dart:io' show File;

import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';

import '../feature_flags.dart';
import '../l10n/app_localizations.dart';
import '../services/antitheft_service.dart';
import '../services/sos_trigger_settings.dart';
import '../ds/ds.dart';
import '../widgets/skeleton.dart' show SkeletonList;
import '../theme.dart';
import '../widgets/app_sheet.dart';
import 'always_on_protection_screen.dart';
import 'fall_detect_screen.dart';
import 'package:assisto/safety/ad_block_context.dart' show AdBlockedState;

/// sosat — "More ways to send SOS": the lock-screen SOS button, power button
/// x5, and the EXPERIMENTAL fall detection. All three run inside the
/// already-running, opt-in Always-on protection service (no new background
/// service). Each row says honestly when it works; when protection is off
/// the screen leads with ONE big button to turn it on, not dead switches.
class SosTriggersScreen extends StatefulWidget {
  const SosTriggersScreen({super.key, this.isRunning, this.fallFlagOn});

  /// Test seams.
  final Future<bool> Function()? isRunning;
  final bool? fallFlagOn;

  @override
  State<SosTriggersScreen> createState() => _SosTriggersScreenState();
}

class _SosTriggersScreenState extends State<SosTriggersScreen>
    with AdBlockedState<SosTriggersScreen> {
  SosTriggerSettings? _s;
  bool _running = false;
  bool _recording = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final s = await SosTriggerSettings.load();
    final run = await (widget.isRunning ?? AntiTheftService.isRunning)();
    if (!mounted) return;
    setState(() {
      _s = s;
      _running = run;
    });
  }

  bool get _fallVisible =>
      widget.fallFlagOn ?? FeatureFlags.instance.isOn('fall_detect');

  Future<void> _set(void Function(SosTriggerSettings s) f) async {
    final s = _s!;
    setState(() => f(s));
    await s.save(AppLocalizations.of(context));
  }

  Future<void> _openProtection() async {
    await Navigator.of(context).push(MaterialPageRoute<void>(
        builder: (_) => const AlwaysOnProtectionScreen()));
    await _load();
  }

  Future<void> _record() async {
    final t = AppLocalizations.of(context);
    final label = await showAppSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => AppSheetBody(
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text(t.saRecTitle, style: AType.titleLarge.copyWith(fontWeight: FontWeight.w700)),
          const SizedBox(height: Gap.xs),
          Text(t.saRecWhat, style: AType.bodyMedium),
          const SizedBox(height: Gap.md),
          for (final (k, l) in [
            ('fall:nofall', t.saRecNormal),
            ('fall:fall', t.saRecFallSoft),
            ('snatch:nosnatch', t.saRecPickUp),
            ('snatch:snatch', t.saRecGrab),
          ])
            ListTile(
              key: ValueKey('sosat-rec-$k'),
              contentPadding: EdgeInsets.zero,
              minTileHeight: 52,
              title: Text(l),
              trailing: const Icon(Icons.fiber_manual_record_rounded, color: Brand.danger),
              onTap: () => Navigator.pop(ctx, k),
            ),
        ]),
      ),
    );
    if (label == null || !mounted) return;
    final parts = label.split(':');
    final ok = await AntiTheftService.recordTrace(
        30, {'detector': parts[0], 'label': parts[1], 'note': 'recorded in app'});
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(ok ? t.saRecStarted : t.saRecNeedsProtection)));
    if (!ok) return;
    setState(() => _recording = true);
    await Future<void>.delayed(const Duration(seconds: 33));
    if (!mounted) return;
    setState(() => _recording = false);
    final path = await AntiTheftService.lastTrace();
    if (path.isEmpty || !File(path).existsSync()) return;
    try {
      await Share.shareXFiles([XFile(path)], text: t.saRecShareText);
    } catch (_) {} // best-effort: the file stays on the phone; sharing can be retried
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final s = _s;
    return Scaffold(
      appBar: AppBar(title: Text(t.saMoreWaysTitle)),
      body: s == null
          ? const SkeletonList(count: 3)
          : ListView(
              padding: withNavBarInset(context, const EdgeInsets.all(Gap.lg)),
              children: [
                Text(t.saMoreWaysBenefit,
                    style: AType.titleMedium.copyWith(color: scheme.ds.text, fontWeight: FontWeight.w600)),
                const SizedBox(height: Gap.md),
                if (!_running) ...[
                  // designv2: the one thing to do first — the soft hero
                  DsHeroCard(
                    key: const ValueKey('sosat-needs-protection'),
                    child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                      Text(t.saNeedsProtectionTitle,
                          style: AType.titleMedium.copyWith(fontWeight: FontWeight.w700, color: scheme.ds.text)),
                      const SizedBox(height: Gap.xs),
                      Text(t.saNeedsProtectionBody, style: AType.bodyMedium.copyWith(color: scheme.ds.muted)),
                      const SizedBox(height: Gap.md),
                      FilledButton.icon(
                        key: const ValueKey('sosat-turn-on-protection'),
                        style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
                        onPressed: _openProtection,
                        icon: const Icon(Icons.shield_rounded),
                        label: Text(t.saTurnOnProtection),
                      ),
                    ]),
                  ),
                  const SizedBox(height: Gap.lg),
                ],
                _row(
                  key: 'sosat-lock',
                  icon: Icons.lock_open_rounded,
                  title: t.saLockTitle,
                  body: t.saLockBody,
                  value: s.lockOn,
                  onChanged: _running ? (v) => _set((x) => x.lockOn = v) : null,
                ),
                _row(
                  key: 'sosat-power',
                  icon: Icons.power_settings_new_rounded,
                  title: t.saPowerTitle,
                  body: t.saPowerBody,
                  value: s.powerOn,
                  onChanged: _running ? (v) => _set((x) => x.powerOn = v) : null,
                ),
                if (_fallVisible)
                  DsCard(
                    padding: EdgeInsets.zero,
                    child: ListTile(
                      key: const ValueKey('sosat-fall'),
                      minTileHeight: 64,
                      leading: const Icon(Icons.personal_injury_rounded),
                      title: Text(t.saFallRowTitle),
                      subtitle: Text(s.fallOn ? t.saOn : t.saFallRowSub),
                      trailing: const Icon(Icons.chevron_right_rounded),
                      onTap: () async {
                        await Navigator.of(context).push(MaterialPageRoute<void>(
                            builder: (_) => const FallDetectScreen()));
                        await _load();
                      },
                    ),
                  ),
                const SizedBox(height: Gap.md),
                Text(t.saHonestFooter,
                    style: AType.bodySmall.copyWith(color: scheme.ds.muted)),
                if (_running) ...[
                  const SizedBox(height: Gap.lg),
                  OutlinedButton.icon(
                    key: const ValueKey('sosat-record'),
                    style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(48)),
                    onPressed: _recording ? null : _record,
                    icon: const Icon(Icons.sensors_rounded),
                    label: Text(_recording ? t.saRecRunning : t.saRecButton),
                  ),
                ],
              ],
            ),
    );
  }

  Widget _row({
    required String key,
    required IconData icon,
    required String title,
    required String body,
    required bool value,
    required ValueChanged<bool>? onChanged,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: Gap.sm),
      child: DsCard(
      padding: const EdgeInsets.symmetric(vertical: Gap.xs),
      child: SwitchListTile(
        key: ValueKey(key),
        secondary: Icon(icon),
        title: Text(title, style: AType.bodyLarge.copyWith(fontWeight: FontWeight.w700)),
        subtitle: Text(body),
        value: value && onChanged != null,
        onChanged: onChanged,
      ),
      ),
    );
  }
}
