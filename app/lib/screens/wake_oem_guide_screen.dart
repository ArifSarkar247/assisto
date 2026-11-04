import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../theme.dart';
import '../voice/va_native.dart';

/// k1-wake — keep "Hey Assisto" alive on phones that kill background apps.
/// Shows the steps for the user's maker first, deep-links to the maker's own
/// auto-start / battery screens where Android lets us (component names are
/// tried one by one natively, falling back to the app's own settings page),
/// and is honest when a screen cannot be opened.
class WakeOemGuideScreen extends StatefulWidget {
  /// Gallery/tests: skip native probes and show this maker.
  final String? debugMaker;
  const WakeOemGuideScreen({super.key, this.debugMaker});

  @override
  State<WakeOemGuideScreen> createState() => _WakeOemGuideScreenState();
}

enum OemFamily { xiaomi, oppo, vivo, samsung, other }

OemFamily oemFamilyOf(String maker) {
  final m = maker.toLowerCase();
  if (m.contains('xiaomi') || m.contains('redmi') || m.contains('poco')) {
    return OemFamily.xiaomi;
  }
  if (m.contains('oppo') || m.contains('realme') || m.contains('oneplus')) {
    return OemFamily.oppo;
  }
  if (m.contains('vivo') || m.contains('iqoo')) return OemFamily.vivo;
  if (m.contains('samsung')) return OemFamily.samsung;
  return OemFamily.other;
}

class _WakeOemGuideScreenState extends State<WakeOemGuideScreen>
    with WidgetsBindingObserver {
  String _maker = '';
  bool? _batteryOk;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _load();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState s) {
    if (s == AppLifecycleState.resumed) _load();
  }

  Future<void> _load() async {
    if (widget.debugMaker != null) {
      setState(() => _maker = widget.debugMaker!);
      return;
    }
    final info = await VaNative.deviceInfo();
    if (!mounted) return;
    setState(() {
      _maker = '${info?['manufacturer'] ?? ''}';
      final b = info?['ignoringBattery'];
      _batteryOk = b is bool ? b : null;
    });
  }

  Future<void> _open(String kind) async {
    final t = AppLocalizations.of(context);
    final r = widget.debugMaker != null
        ? null // gallery/tests: no native half -> the honest "not opened" note
        : await VaNative.openOemSettings(kind);
    if (!mounted) return;
    if (r == null || r == 'none') {
      ScaffoldMessenger.maybeOf(context)
          ?.showSnackBar(SnackBar(content: Text(t.vaOemNotOpened)));
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final fam = oemFamilyOf(_maker);
    final steps = <OemFamily, String>{
      OemFamily.xiaomi: t.vaOemXiaomi,
      OemFamily.oppo: t.vaOemOppo,
      OemFamily.vivo: t.vaOemVivo,
      OemFamily.samsung: t.vaOemSamsung,
      OemFamily.other: t.vaOemOther,
    };
    final order = [fam, ...OemFamily.values.where((f) => f != fam)];
    return Scaffold(
      appBar: AppBar(title: Text(t.vaOemTitle)),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(Gap.lg, Gap.sm, Gap.lg, Gap.xxl),
        children: [
          Text(t.vaOemIntro, style: TextStyle(color: scheme.onSurfaceVariant)),
          const SizedBox(height: Gap.md),
          if (_maker.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(bottom: Gap.sm),
              child: Text(t.vaOemYourPhone(_maker),
                  style: const TextStyle(fontWeight: FontWeight.w700)),
            ),
          Card(
            elevation: 0,
            color: scheme.surfaceContainerHigh,
            shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(Radii.lg)),
            child: Padding(
              padding: const EdgeInsets.all(Gap.lg),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _row(scheme, Icons.rocket_launch_rounded, t.vaOemAutostart),
                  const SizedBox(height: Gap.sm),
                  _row(scheme, Icons.battery_charging_full_rounded, t.vaOemBattery),
                  const SizedBox(height: Gap.md),
                  Text(steps[fam]!, style: const TextStyle(height: 1.4)),
                  const SizedBox(height: Gap.md),
                  if (_batteryOk == true)
                    Padding(
                      padding: const EdgeInsets.only(bottom: Gap.sm),
                      child: Row(children: [
                        const Icon(Icons.check_circle_rounded, size: 18, color: Brand.success),
                        const SizedBox(width: Gap.sm),
                        Expanded(child: Text(t.vaOemBatteryOk)),
                      ]),
                    ),
                  Wrap(spacing: Gap.sm, runSpacing: Gap.sm, children: [
                    if (fam != OemFamily.samsung && fam != OemFamily.other)
                      FilledButton.tonalIcon(
                        onPressed: () => _open('autostart'),
                        icon: const Icon(Icons.rocket_launch_rounded),
                        label: Text(t.vaOemOpenAutostart),
                      ),
                    FilledButton.tonalIcon(
                      onPressed: () => _open('battery'),
                      icon: const Icon(Icons.battery_saver_rounded),
                      label: Text(t.vaOemOpenBattery),
                    ),
                  ]),
                ],
              ),
            ),
          ),
          const SizedBox(height: Gap.lg),
          for (final f in order.skip(1))
            Padding(
              padding: const EdgeInsets.only(bottom: Gap.md),
              child: Text(steps[f]!,
                  style: TextStyle(color: scheme.onSurfaceVariant, height: 1.4)),
            ),
          const SizedBox(height: Gap.sm),
          Text(t.vaOemHonest,
              style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 13)),
        ],
      ),
    );
  }

  Widget _row(ColorScheme scheme, IconData icon, String text) =>
      Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Icon(icon, size: 20, color: scheme.primary),
        const SizedBox(width: Gap.sm),
        Expanded(
            child: Text(text, style: const TextStyle(fontWeight: FontWeight.w600))),
      ]);
}
