// flag-itag (W7, server switch itag_tags, OFF): "Bluetooth tag" — a cheap
// open iTag on keys / bag: pair, ring it, battery, "left behind" while
// "watch my bag" is on, the tag's button rings this phone, last-seen place
// (this phone only), unpair. Plain Design System V2, bn/en.
import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:intl/intl.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../ds/ds.dart';
import '../../itag/itag_controller.dart';
import '../../itag/itag_platform.dart';
import '../../itag/itag_store.dart';
import '../../l10n/app_localizations.dart';
import '../../widgets/app_sheet.dart' show withNavBarInset;
import '../../widgets/local_digits.dart';
import '../../widgets/permission_reason.dart';
import 'itag_alert.dart';
import 'itag_permission.dart';

class ItagScreen extends StatefulWidget {
  const ItagScreen({super.key, this.controller, this.ask, this.locationAllowed});

  /// Test seams (the app uses ItagController.instance + the real prompts).
  final ItagController? controller;
  final ItagAskFn? ask;
  final Future<bool> Function()? locationAllowed;

  @override
  State<ItagScreen> createState() => _ItagScreenState();
}

class _ItagScreenState extends State<ItagScreen> with WidgetsBindingObserver {
  late final ItagController c = widget.controller ?? ItagController.instance;
  ItagRadio? _radio;
  bool _locOk = true;
  late bool _seenRadioOff = c.radioOff;

  bool get _bn => Localizations.localeOf(context).languageCode == 'bn';

  @override
  void initState() {
    super.initState();
    itagInstallAlertHook(c);
    c.addListener(_changed);
    WidgetsBinding.instance.addObserver(this);
    _start();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    c.removeListener(_changed);
    super.dispose();
  }

  void _changed() {
    if (!mounted) return;
    if (c.radioOff != _seenRadioOff) {
      // itag-proof: Bluetooth turned off / on while the screen is open
      _seenRadioOff = c.radioOff;
      _refreshRadio();
    }
    setState(() {});
  }

  /// itag-proof: back from Settings (Bluetooth / location / permission) —
  /// re-check and reconnect, so the card never stays stale (no dead end).
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) return;
    () async {
      await _refreshRadio();
      _locOk = await (widget.locationAllowed ?? _locationAllowed)();
      if (!mounted) return;
      setState(() {});
      final r = _radio;
      if (r != null) await c.radioChecked(r);
      if (r == ItagRadio.ready) await c.connectAll();
    }();
  }

  Future<void> _start() async {
    await c.load();
    await _refreshRadio();
    _locOk = await (widget.locationAllowed ?? _locationAllowed)();
    if (mounted) setState(() {});
    if (_radio == ItagRadio.ready) await c.connectAll();
  }

  static Future<bool> _locationAllowed() async {
    try {
      final p = await Geolocator.checkPermission();
      return p == LocationPermission.whileInUse || p == LocationPermission.always;
    } catch (_) {
      return false;
    }
  }

  Future<void> _refreshRadio() async {
    final s = await c.platform.state();
    if (mounted) setState(() => _radio = s.radio);
  }

  /// Every action that needs Bluetooth goes through here (reason first).
  Future<bool> _ready() async {
    final t = AppLocalizations.of(context);
    final r = await itagEnsureReady(context, c.platform, ask: widget.ask);
    await _refreshRadio();
    if (!mounted) return false;
    switch (r) {
      case ItagReady.ready:
        return true;
      case ItagReady.notNow:
        return false;
      case ItagReady.blocked:
        showDsToast(context, t.itgPermBlocked,
            actionLabel: t.itgOpenSettings, onAction: () => openAppSettingsSafe());
      case ItagReady.off:
        showDsToast(context, t.itgBtOff,
            actionLabel: t.itgTurnOn, onAction: () => c.platform.openSettings());
      case ItagReady.locationOff:
        showDsToast(context, t.itgLocationOff,
            actionLabel: t.itgTurnOnLocation, onAction: () => openLocationSettingsSafe());
      case ItagReady.unsupported:
        showDsToast(context, t.itgUnsupported, tone: DsToastTone.danger);
    }
    return false;
  }

  Future<void> _add() async {
    if (!await _ready() || !mounted) return;
    final f = await showAppSheet<ItagFound>(
      context: context,
      isScrollControlled: true,
      builder: (_) => _PairSheet(controller: c),
    );
    if (f == null || !mounted) return;
    final t = AppLocalizations.of(context);
    final name = await _askName(t.itgDefaultName);
    if (name == null || !mounted) return;
    final ok = await c.pair(f, name);
    if (!mounted) return;
    showDsToast(context, ok ? t.itgPaired(name) : t.itgPairFailed,
        tone: ok ? DsToastTone.success : DsToastTone.danger);
  }

  Future<String?> _askName(String initial) async {
    final r = await showDialog<String>(
      context: context,
      builder: (_) => _NameDialog(initial: initial),
    );
    final v = r?.trim();
    return (v == null || v.isEmpty) ? null : v;
  }

  Future<void> _ring(ItagTag tag) async {
    final t = AppLocalizations.of(context);
    if (c.tagRinging.contains(tag.address)) {
      await c.stopTag(tag.address);
      return;
    }
    if (!await _ready()) return;
    final ok = await c.ringTag(tag.address);
    if (!ok && mounted) {
      showDsToast(context, t.itgOutOfReachToast, tone: DsToastTone.danger);
    }
  }

  Future<void> _unpair(ItagTag tag) async {
    final t = AppLocalizations.of(context);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(t.itgUnpairTitle(tag.name)),
        content: Text(t.itgUnpairBody),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(t.cancel)),
          FilledButton(
              key: const Key('itag-unpair-ok'),
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(t.itgUnpair)),
        ],
      ),
    );
    if (ok == true) await c.unpair(tag.address);
  }

  Future<void> _watch(bool on) async {
    if (on && !await _ready()) return;
    await c.setWatching(on);
  }

  Future<void> _allowLocation() async {
    final p = await askLocationWithReason(context);
    _locOk = p == LocationPermission.whileInUse || p == LocationPermission.always;
    if (mounted) setState(() {});
  }

  String _when(int ms) {
    final d = DateTime.fromMillisecondsSinceEpoch(ms);
    final loc = Localizations.localeOf(context).toLanguageTag();
    String s;
    try {
      s = DateFormat('d MMM, h:mm a', loc).format(d);
    } catch (_) {
      s = DateFormat('d MMM, h:mm a').format(d);
    }
    return toLocalDigits(s, _bn);
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final tags = c.tags;
    return Scaffold(
      key: const Key('itag-screen'),
      appBar: AppBar(title: Text(t.itgTitle)),
      body: ListView(
        padding: withNavBarInset(context, const EdgeInsets.all(Gap.lg)),
        children: [
          if (c.watching) ...[
            DsCard(
              key: const Key('itag-watch-banner'),
              tone: DsTone.success,
              child: Row(children: [
                const Icon(Icons.visibility_rounded),
                const SizedBox(width: Gap.md),
                Expanded(child: Text(t.itgWatchBanner)),
              ]),
            ),
            const SizedBox(height: Gap.md),
          ],
          ..._radioCard(t),
          if (tags.isEmpty)
            DsEmptyState(
              icon: Icons.key_rounded,
              title: t.itgEmptyTitle,
              benefit: t.itgEmptyBenefit,
              actionLabel: t.itgAddTag,
              actionKey: const Key('itag-add-empty'),
              onAction: _add,
              howTo: [t.itgHow1, t.itgHow2, t.itgHow3],
            )
          else ...[
            for (final tag in tags) ...[
              _tagCard(t, tag),
              const SizedBox(height: Gap.md),
            ],
            DsButton.secondary(
              buttonKey: const Key('itag-add'),
              label: t.itgAddTag,
              icon: Icons.add_rounded,
              expand: true,
              onPressed: _add,
            ),
            const SizedBox(height: Gap.lg),
            DsSectionHeader(t.itgSettings),
            SwitchListTile(
              key: const Key('itag-watch'),
              value: c.watching,
              onChanged: _watch,
              title: Text(t.itgWatch),
              subtitle: Text(t.itgWatchSub),
            ),
            SwitchListTile(
              key: const Key('itag-button-rings'),
              value: c.buttonRingsPhone,
              onChanged: (v) => c.setButtonRingsPhone(v),
              title: Text(t.itgButtonRings),
              subtitle: Text(t.itgButtonRingsSub),
            ),
            if (!_locOk)
              DsListRow(
                key: const Key('itag-allow-location'),
                leading: const Icon(Icons.place_rounded),
                title: t.itgSavePlace,
                subtitle: t.itgSavePlaceSub,
                onTap: _allowLocation,
              ),
          ],
          const SizedBox(height: Gap.lg),
          Text(t.itgHonest, style: Theme.of(context).textTheme.bodySmall),
        ],
      ),
    );
  }

  List<Widget> _radioCard(AppLocalizations t) {
    final r = c.radioOff ? ItagRadio.off : _radio;
    if (r == null || r == ItagRadio.ready) return const [];
    final (String msg, String? action, VoidCallback? onTap) = switch (r) {
      ItagRadio.off => (
          c.watching && c.tags.isNotEmpty ? t.itgBtOffWatching : t.itgBtOff,
          t.itgTurnOn,
          () => c.platform.openSettings()
        ),
      ItagRadio.noPermission => (t.itgNeedPermission, t.itgAllow, () => _ready().then((ok) {
            if (ok) c.connectAll();
          })),
      ItagRadio.locationOff => (
          t.itgLocationOff,
          t.itgTurnOnLocation,
          () => openLocationSettingsSafe()
        ),
      _ => (t.itgUnsupported, null, null),
    };
    return [
      DsCard(
        key: const Key('itag-radio'),
        tone: r == ItagRadio.unsupported ? DsTone.danger : DsTone.normal,
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text(msg),
          if (action != null && onTap != null) ...[
            const SizedBox(height: Gap.md),
            DsButton(
                buttonKey: const Key('itag-radio-action'), label: action, onPressed: onTap),
          ],
        ]),
      ),
      const SizedBox(height: Gap.md),
    ];
  }

  Widget _tagCard(AppLocalizations t, ItagTag tag) {
    final d = DsTokens.of(context);
    final text = Theme.of(context).textTheme;
    final on = c.connected.contains(tag.address);
    final busy = c.connecting.contains(tag.address);
    final ringing = c.tagRinging.contains(tag.address);
    final status = on ? t.itgNear : (busy ? t.itgConnecting : t.itgOutOfReach);
    final seen = tag.lastSeen;
    return DsCard(
      key: Key('itag-tag-${tag.address}'),
      tone: c.leftBehind == tag.address ? DsTone.danger : DsTone.normal,
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          Icon(on ? Icons.bluetooth_connected_rounded : Icons.bluetooth_disabled_rounded,
              color: on ? d.successInk : d.muted),
          const SizedBox(width: Gap.md),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(tag.name, style: text.titleMedium),
              Text(status, style: text.bodyMedium?.copyWith(color: d.muted)),
            ]),
          ),
          PopupMenuButton<String>(
            key: Key('itag-menu-${tag.address}'),
            tooltip: t.itgMore,
            onSelected: (v) async {
              if (v == 'rename') {
                final n = await _askName(tag.name);
                if (n != null) await c.rename(tag.address, n);
              } else if (v == 'unpair') {
                await _unpair(tag);
              }
            },
            itemBuilder: (_) => [
              PopupMenuItem(value: 'rename', child: Text(t.itgRename)),
              PopupMenuItem(
                  key: const Key('itag-unpair'), value: 'unpair', child: Text(t.itgUnpair)),
            ],
          ),
        ]),
        const SizedBox(height: Gap.sm),
        if (tag.battery != null)
          Text(t.itgBattery(toLocalDigits('${tag.battery}', _bn)),
              key: Key('itag-battery-${tag.address}'), style: text.bodyMedium)
        else
          Text(t.itgBatteryUnknown, style: text.bodyMedium?.copyWith(color: d.muted)),
        if (seen != null) ...[
          const SizedBox(height: Gap.xs),
          Text(t.itgLastSeen(_when(seen.atMs)), style: text.bodyMedium),
        ],
        const SizedBox(height: Gap.md),
        Wrap(spacing: Gap.sm, runSpacing: Gap.sm, children: [
          DsButton(
            buttonKey: Key('itag-ring-${tag.address}'),
            label: ringing ? t.itgStopRing : t.itgRing,
            icon: ringing ? Icons.volume_off_rounded : Icons.volume_up_rounded,
            onPressed: () => _ring(tag),
          ),
          if (on)
            DsButton.secondary(
              buttonKey: Key('itag-batt-${tag.address}'),
              label: t.itgCheckBattery,
              icon: Icons.battery_std_rounded,
              onPressed: () => c.refreshBattery(tag.address),
            ),
          if (seen != null)
            DsButton.secondary(
              buttonKey: Key('itag-map-${tag.address}'),
              label: t.itgOpenMap,
              icon: Icons.map_rounded,
              onPressed: () => launchUrl(
                  Uri.parse('https://www.google.com/maps/search/?api=1&query='
                      '${seen.lat},${seen.lng}'),
                  mode: LaunchMode.externalApplication),
            ),
        ]),
      ]),
    );
  }
}

/// The name dialog owns its text controller (disposed with the dialog,
/// after the closing animation — never while the field is still drawn).
class _NameDialog extends StatefulWidget {
  const _NameDialog({required this.initial});
  final String initial;

  @override
  State<_NameDialog> createState() => _NameDialogState();
}

class _NameDialogState extends State<_NameDialog> {
  late final TextEditingController _ctl = TextEditingController(text: widget.initial);

  @override
  void dispose() {
    _ctl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    return AlertDialog(
      title: Text(t.itgNameTitle),
      scrollable: true,
      content: TextField(
        key: const Key('itag-name'),
        controller: _ctl,
        autofocus: true,
        textInputAction: TextInputAction.done,
        onSubmitted: (v) => Navigator.pop(context, v),
        decoration: InputDecoration(hintText: t.itgNameHint),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: Text(t.cancel)),
        FilledButton(
            key: const Key('itag-name-ok'),
            onPressed: () => Navigator.pop(context, _ctl.text),
            child: Text(t.save)),
      ],
    );
  }
}

/// itag-proof: Android 8–11 scan only with Location on — one tap to its switch.
Future<void> openLocationSettingsSafe() async {
  try {
    await Geolocator.openLocationSettings();
  } catch (_) {} // best-effort: the card text already says where to turn it on
}

Future<void> openAppSettingsSafe() async {
  try {
    await Geolocator.openAppSettings();
  } catch (_) {} // best-effort: Settings could not open; the toast already says what to do
}

/// Scan sheet: likely iTags first (strongest signal first), then other
/// named Bluetooth LE devices; tags already paired are left out.
class _PairSheet extends StatefulWidget {
  const _PairSheet({required this.controller});
  final ItagController controller;

  @override
  State<_PairSheet> createState() => _PairSheetState();
}

class _PairSheetState extends State<_PairSheet> {
  List<ItagFound>? _found;

  @override
  void initState() {
    super.initState();
    _scan();
  }

  Future<void> _scan() async {
    setState(() => _found = null);
    final l = await widget.controller.platform.scan();
    final c = widget.controller;
    final out = [for (final f in l) if (!c.isPaired(f.address)) f]
      ..sort((a, b) {
        if (a.likely != b.likely) return a.likely ? -1 : 1;
        return b.rssi.compareTo(a.rssi);
      });
    if (mounted) setState(() => _found = out);
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final f = _found;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(Gap.lg),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          DsSheetHeader(t.itgPairTitle, subtitle: t.itgPairTip),
          const SizedBox(height: Gap.md),
          if (f == null)
            Padding(
              padding: const EdgeInsets.all(Gap.lg),
              child: Column(children: [
                const CircularProgressIndicator(),
                const SizedBox(height: Gap.md),
                Text(t.itgScanning, key: const Key('itag-scanning')),
              ]),
            )
          else if (f.isEmpty)
            Padding(
              padding: const EdgeInsets.all(Gap.lg),
              child: Text(t.itgNoneFound, key: const Key('itag-none'), textAlign: TextAlign.center),
            )
          else
            Flexible(
              child: ListView(shrinkWrap: true, children: [
                for (final x in f)
                  DsListRow(
                    key: Key('itag-found-${x.address}'),
                    leading: Icon(x.likely ? Icons.key_rounded : Icons.bluetooth_rounded),
                    title: x.name.isEmpty ? t.itgUnnamed : x.name,
                    subtitle: x.likely ? t.itgLikelyTag : t.itgOtherDevice,
                    onTap: () => Navigator.pop(context, x),
                  ),
              ]),
            ),
          const SizedBox(height: Gap.md),
          DsButton.secondary(
            buttonKey: const Key('itag-rescan'),
            label: t.itgScanAgain,
            icon: Icons.refresh_rounded,
            expand: true,
            onPressed: f == null ? null : _scan,
          ),
        ]),
      ),
    );
  }
}
