import 'package:flutter/material.dart';
import '../l10n/app_localizations.dart';
import '../services/oem_guide.dart';
import '../theme.dart';
import '../widgets/robo_id.dart';

/// "Background & notifications" — the OEM background guide (tl1).
///
/// Many OEMs (Xiaomi/OPPO/realme/vivo/Samsung/Infinix/Tecno…) stop apps in the
/// background, so calls, messages and SOS alerts may not arrive. The phone is
/// detected natively (Build.MANUFACTURER/BRAND + ROM properties); each step
/// has an "Open" button ONLY when a matching settings screen resolves on this
/// phone (vendor screen → App info fallback); otherwise the step shows honest
/// by-hand instructions and no button. Steps Android can check (battery
/// optimisation, background restriction) show "Already done" when satisfied.
///
/// Shown once after login ([firstRun], via [OemGuideGate]) and always
/// reachable from Settings • Background & notifications. Bangla + English.
class BatteryGuidanceScreen extends StatefulWidget {
  const BatteryGuidanceScreen({super.key, this.firstRun = false, this.native});

  /// First-run mode adds the Done / Later buttons at the bottom.
  final bool firstRun;

  /// Native bridge (tests / gallery pass a fake).
  final OemGuideNative? native;

  @override
  State<BatteryGuidanceScreen> createState() => _BatteryGuidanceScreenState();
}

class _BatteryGuidanceScreenState extends State<BatteryGuidanceScreen>
    with WidgetsBindingObserver {
  late final OemGuideNative _native = widget.native ?? const ChannelOemGuideNative();
  OemInfo? _info;
  bool _loading = true;
  OemFamily? _picked; // manual brand override
  final Map<String, OemOpen> _avail = {};
  final Map<OemStepId, OemOpen> _result = {};

  OemFamily get _family => _picked ?? _info?.family ?? OemFamily.nearStock;

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
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Back from the phone's settings: re-check what Android can tell us.
    if (state == AppLifecycleState.resumed) _load();
  }

  Future<void> _load() async {
    final info = await _native.info();
    final avail = <String, OemOpen>{};
    if (info != null) {
      final ids = <String>{
        for (final f in OemFamily.values)
          for (final s in oemSteps(f, bgRestricted: true))
            if (s.nativeStep != null) s.nativeStep!,
      };
      for (final id in ids) {
        avail[id] = await _native.available(id);
      }
    }
    if (!mounted) return;
    setState(() {
      _info = info;
      _avail
        ..clear()
        ..addAll(avail);
      _loading = false;
    });
  }

  Future<void> _open(OemStepId step) async {
    final id = step.nativeStep;
    if (id == null) return;
    final r = await _native.open(id);
    if (!mounted) return;
    setState(() => _result[step] = r);
  }

  String _title(AppLocalizations t, OemStepId s, OemFamily f) => switch (s) {
        OemStepId.batteryOpt => t.oemStepBatteryOptTitle,
        OemStepId.bgRestricted => t.oemStepBgRestrictedTitle,
        OemStepId.samsungUnrestricted => t.oemStepUnrestrictedTitle,
        OemStepId.autostart => t.oemStepAutostartTitle,
        OemStepId.oemBattery =>
          f == OemFamily.samsung ? t.oemStepSleepingTitle : t.oemStepOemBatteryTitle,
        OemStepId.lockRecent => t.oemStepLockTitle,
      };

  String _body(AppLocalizations t, OemStepId s, OemFamily f) {
    switch (s) {
      case OemStepId.batteryOpt:
        return t.oemStepBatteryOptBody;
      case OemStepId.bgRestricted:
        return t.oemStepBgRestrictedBody;
      case OemStepId.samsungUnrestricted:
        return t.oemStepUnrestrictedBody;
      case OemStepId.lockRecent:
        return t.oemStepLockBody;
      case OemStepId.autostart:
        return switch (f) {
          OemFamily.xiaomi => t.oemStepAutostartXiaomi,
          OemFamily.realme => t.oemStepAutostartRealme,
          OemFamily.oneplus => t.oemStepAutostartOneplus,
          OemFamily.vivo => t.oemStepAutostartVivo,
          OemFamily.transsion => t.oemStepAutostartTranssion,
          _ => t.oemStepAutostartOppo,
        };
      case OemStepId.oemBattery:
        return switch (f) {
          OemFamily.xiaomi => t.oemStepOemBatteryXiaomi,
          OemFamily.vivo => t.oemStepOemBatteryVivo,
          OemFamily.samsung => t.oemStepOemBatterySamsung,
          OemFamily.transsion => t.oemStepOemBatteryTranssion,
          _ => t.oemStepOemBatteryOppo,
        };
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final info = _info;
    final steps = oemSteps(_family, bgRestricted: info?.bgRestricted);
    final allDone = info != null &&
        steps.every((s) => s.checkable && oemStepDone(s, info));
    final brands = <(OemFamily, String)>[
      (OemFamily.samsung, 'Samsung'),
      (OemFamily.xiaomi, 'Xiaomi / Redmi / POCO'),
      (OemFamily.oppo, 'OPPO'),
      (OemFamily.realme, 'realme'),
      (OemFamily.oneplus, 'OnePlus'),
      (OemFamily.vivo, 'vivo / iQOO'),
      (OemFamily.transsion, 'Infinix / Tecno / itel'),
      (OemFamily.nearStock, t.oemGuideBrandOther),
    ];
    return Scaffold(
      appBar: AppBar(
        title: Text(t.oemGuideTitle),
        automaticallyImplyLeading: !widget.firstRun,
      ),
      body: SafeArea(
        child: ListView(padding: const EdgeInsets.all(Gap.lg), children: [
          Card(
            color: scheme.tertiaryContainer,
            child: Padding(
              padding: const EdgeInsets.all(Gap.lg),
              child: Text(t.oemGuideIntro,
                  style: TextStyle(color: scheme.onTertiaryContainer)),
            ),
          ),
          const SizedBox(height: Gap.md),
          if (info != null && info.label.isNotEmpty)
            Text(t.oemGuideYourPhone(info.label),
                style: const TextStyle(fontWeight: FontWeight.w700)),
          const SizedBox(height: Gap.sm),
          Text(t.oemGuidePickBrand,
              style: TextStyle(color: scheme.onSurfaceVariant)),
          const SizedBox(height: Gap.xs),
          Wrap(spacing: Gap.sm, runSpacing: Gap.xs, children: [
            for (final b in brands)
              // A wrapping pill (not ChoiceChip): chip labels are one line and
              // clip at large text sizes; this one wraps at 360 px x2.0.
              _BrandPill(
                label: b.$2,
                selected: _family == b.$1,
                onTap: () => setState(() => _picked = b.$1),
              ),
          ]),
          const SizedBox(height: Gap.lg),
          if (_loading)
            const Padding(
              padding: EdgeInsets.all(Gap.xl),
              child: Center(child: CircularProgressIndicator()),
            )
          else ...[
            if (allDone)
              Card(
                margin: const EdgeInsets.only(bottom: Gap.md),
                child: ListTile(
                  leading: Icon(Icons.check_circle, color: scheme.primary),
                  title: Text(t.oemGuideAllSet),
                ),
              ),
            for (var i = 0; i < steps.length; i++)
              _StepCard(
                index: i + 1,
                title: _title(t, steps[i], _family),
                body: _body(t, steps[i], _family),
                done: info != null && oemStepDone(steps[i], info),
                checkable: steps[i].checkable && info != null,
                byHandOnly: steps[i].nativeStep == null,
                open: steps[i].nativeStep == null
                    ? OemOpen.none
                    : (_avail[steps[i].nativeStep!] ?? OemOpen.none),
                result: _result[steps[i]],
                onOpen: () => _open(steps[i]),
              ),
          ],
          const SizedBox(height: Gap.sm),
          Text(t.noteExactMenuNamesVary,
              style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant)),
          const SizedBox(height: Gap.xs),
          Text(t.oemGuideReopenHint,
              style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant)),
          if (widget.firstRun) ...[
            const SizedBox(height: Gap.lg),
            RoboId(id: 'tl_oem_done',
              child: FilledButton(
                key: const Key('oem-guide-done'),
                onPressed: () => Navigator.of(context).maybePop(),
                child: Text(t.done),
              ),
            ),
            const SizedBox(height: Gap.xs),
            RoboId(id: 'tl_oem_later',
              child: TextButton(
                key: const Key('oem-guide-later'),
                onPressed: () => Navigator.of(context).maybePop(),
                child: Text(t.oemGuideLater),
              ),
            ),
          ],
        ]),
      ),
    );
  }
}

class _StepCard extends StatelessWidget {
  const _StepCard({
    required this.index,
    required this.title,
    required this.body,
    required this.done,
    required this.checkable,
    required this.byHandOnly,
    required this.open,
    required this.result,
    required this.onOpen,
  });
  final int index;
  final String title;
  final String body;
  final bool done;
  final bool checkable;
  final bool byHandOnly;
  final OemOpen open;
  final OemOpen? result;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final note = TextStyle(fontSize: 13, color: scheme.onSurfaceVariant);
    return Card(
      margin: const EdgeInsets.only(bottom: Gap.md),
      child: Padding(
        padding: const EdgeInsets.all(Gap.md),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          ExcludeSemantics(
            child: done
                ? Icon(Icons.check_circle, color: scheme.primary, size: 28)
                : CircleAvatar(
                    radius: 14,
                    backgroundColor: scheme.primaryContainer,
                    child: Text('$index',
                        style: TextStyle(
                            color: scheme.onPrimaryContainer, fontSize: 13)),
                  ),
          ),
          const SizedBox(width: Gap.md),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(title,
                  style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15)),
              const SizedBox(height: Gap.xs),
              Text(body),
              const SizedBox(height: Gap.sm),
              if (done)
                Text(t.oemGuideDoneState,
                    style: TextStyle(
                        color: scheme.primary, fontWeight: FontWeight.w700))
              else ...[
                if (!checkable && !byHandOnly) Text(t.oemGuideCantCheck, style: note),
                if (byHandOnly) Text(t.oemGuideByHand, style: note),
                if (!byHandOnly && open == OemOpen.none)
                  Text(t.oemGuideNoScreen, style: note),
                if (!byHandOnly && open != OemOpen.none) ...[
                  const SizedBox(height: Gap.xs),
                  FilledButton.tonalIcon(
                    onPressed: onOpen,
                    icon: const Icon(Icons.open_in_new, size: 18),
                    label: Text(open == OemOpen.oem ? t.open : t.oemGuideOpenAppInfo),
                  ),
                ],
                if (result == OemOpen.details) ...[
                  const SizedBox(height: Gap.xs),
                  Text(t.oemGuideOpenedDetails, style: note),
                ],
                if (result == OemOpen.none) ...[
                  const SizedBox(height: Gap.xs),
                  Text(t.oemGuideNoScreen, style: note),
                ],
              ],
            ]),
          ),
        ]),
      ),
    );
  }
}

class _BrandPill extends StatelessWidget {
  const _BrandPill({required this.label, required this.selected, required this.onTap});
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final fg = selected ? scheme.onSecondaryContainer : scheme.onSurface;
    return Semantics(
      button: true,
      selected: selected,
      inMutuallyExclusiveGroup: true,
      child: Material(
        color: selected ? scheme.secondaryContainer : Colors.transparent,
        // Rounded rectangle, not a stadium: a label that wraps to two lines
        // at large text sizes must not touch the curved ends.
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(20),
            side: BorderSide(color: selected ? scheme.secondaryContainer : scheme.outline)),
        child: InkWell(
          customBorder: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: Gap.lg, vertical: Gap.sm),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              if (selected) ...[
                Icon(Icons.check, size: 18, color: fg),
                const SizedBox(width: Gap.xs),
              ],
              Flexible(child: Text(label, style: TextStyle(color: fg))),
            ]),
          ),
        ),
      ),
    );
  }
}
