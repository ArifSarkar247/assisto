import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../calls/call_native.dart';
import '../l10n/app_localizations.dart';
import '../state.dart';
import '../theme.dart';
import '../widgets/notif_models.dart' show notifLocalizeDigits;
import 'sos_api.dart';
import 'sos_dnd.dart';
import 'sos_sms.dart';
import 'sos_widgets.dart' show showSosSmsPicker;

/// fcsos — "Get SOS ready": the four things that decide whether an SOS
/// reaches the family in the worst moment, each with its honest state and
/// one fix button:
///   1. the 2 people who get an SMS from my SIM when there is no internet
///   2. share blood group + emergency contacts on the family's SOS page
///   3. my phone rings family SOS alarms even in Do Not Disturb (permission)
///   4. full-screen alarms over the lock screen (Android 14+ permission)
class SosSetupCard extends StatefulWidget {
  const SosSetupCard({
    super.key,
    this.api,
    this.dndGranted,
    this.dndEnsure,
    this.dndOpen,
    this.fullScreen,
    this.fixFullScreen,
    this.sms,
  });

  final FcSosApi? api;
  final Future<bool?> Function()? dndGranted;
  final Future<bool> Function(String name, String desc)? dndEnsure;
  final Future<bool> Function()? dndOpen;
  final Future<bool> Function()? fullScreen;
  final Future<bool> Function()? fixFullScreen;
  final List<SosSmsContact>? sms;

  @override
  State<SosSetupCard> createState() => _SosSetupCardState();
}

class _SosSetupCardState extends State<SosSetupCard> with WidgetsBindingObserver {
  List<SosSmsContact> _sms = const [];
  Map<String, dynamic>? _settings;
  bool? _dnd;
  bool? _full;
  bool _saving = false;

  FcSosApi get _api => widget.api ?? HttpFcSosApi(context.read<AppState>().api);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState s) {
    // back from Android settings: re-check the permissions
    if (s == AppLifecycleState.resumed) unawaited(_checkPerms());
  }

  Future<void> _load() async {
    final l = widget.sms ?? await SosSmsStore.load();
    if (mounted) setState(() => _sms = l);
    unawaited(_checkPerms());
    try {
      final s = await _api.settings();
      if (mounted) setState(() => _settings = s);
    } catch (_) {
      if (mounted) setState(() => _settings = const {});
    }
  }

  Future<void> _checkPerms() async {
    final t = AppLocalizations.of(context);
    final g = await (widget.dndGranted ?? SosDnd.granted)();
    var dnd = g;
    if (g == true) {
      dnd = await (widget.dndEnsure ?? SosDnd.ensure)(t.pushChSos, t.fcsDndChannelDesc);
    }
    final full = await (widget.fullScreen ?? CallNative.canFullScreen)();
    if (mounted) {
      setState(() {
        _dnd = dnd;
        _full = full;
      });
    }
  }

  Future<void> _pick() async {
    final l = await showSosSmsPicker(context, current: _sms);
    if (l != null && mounted) setState(() => _sms = l);
  }

  Future<void> _share(bool v) async {
    setState(() => _saving = true);
    try {
      final s = await _api.setShareInfo(v);
      if (mounted) setState(() => _settings = s);
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.maybeOf(context)?.showSnackBar(
            SnackBar(content: Text(AppLocalizations.of(context).fcsSaveFailed)));
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final s = Theme.of(context).colorScheme;
    final share = _settings?['share_info'] == true;
    final blood = '${_settings?['blood_group'] ?? ''}';
    final nContacts = (_settings?['contacts'] as num?)?.toInt() ?? 0;
    return Card(
      key: const ValueKey('fcs-setup'),
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(Gap.md),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(children: [
            const Icon(Icons.health_and_safety_rounded, color: Brand.danger),
            const SizedBox(width: Gap.sm),
            Expanded(
              child: Text(t.fcsSetupTitle,
                  style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
            ),
          ]),
          const SizedBox(height: Gap.xs),
          Text(t.fcsSetupBody, style: TextStyle(color: s.onSurfaceVariant)),
          const SizedBox(height: Gap.sm),
          _row(
            key: 'fcs-setup-sms',
            ok: _sms.isNotEmpty,
            title: t.fcsSetupSmsTitle,
            sub: _sms.isEmpty
                ? t.fcsSetupSmsNone
                : t.fcsSetupSmsSome(_sms
                    .map((c) => c.name.isEmpty ? notifLocalizeDigits(context, c.phone) : c.name)
                    .join(', ')),
            action: _sms.isEmpty ? t.fcsChoose : t.fcsChange,
            onTap: _pick,
          ),
          const Divider(height: Gap.lg),
          SwitchListTile(
            key: const ValueKey('fcs-setup-share'),
            contentPadding: EdgeInsets.zero,
            value: share,
            onChanged: _settings == null || _saving ? null : _share,
            title: Text(t.fcsSetupShareTitle, style: const TextStyle(fontWeight: FontWeight.w700)),
            subtitle: Text(blood.isEmpty && nContacts == 0
                ? t.fcsSetupShareEmpty
                : t.fcsSetupShareSub(blood.isEmpty ? '—' : blood,
                    notifLocalizeDigits(context, '$nContacts'))),
          ),
          const Divider(height: Gap.lg),
          _row(
            key: 'fcs-setup-dnd',
            ok: _dnd == true,
            title: t.fcsSetupDndTitle,
            sub: _dnd == true ? t.fcsSetupDndOn : t.fcsSetupDndOff,
            action: _dnd == true ? null : t.fcsAllow,
            onTap: () async {
              final m = ScaffoldMessenger.maybeOf(context);
              final ok = await (widget.dndOpen ?? SosDnd.openSettings)();
              if (!ok) m?.showSnackBar(SnackBar(content: Text(t.fcsDndManual)));
            },
          ),
          if (_full == false) ...[
            const Divider(height: Gap.lg),
            _row(
              key: 'fcs-setup-full',
              ok: false,
              title: t.fcsSetupFullTitle,
              sub: t.fcsSetupFullOff,
              action: t.fcsAllow,
              onTap: () async {
                final m = ScaffoldMessenger.maybeOf(context);
                final ok = await (widget.fixFullScreen ?? CallNative.openFullScreenSettings)();
                if (!ok) m?.showSnackBar(SnackBar(content: Text(t.fcsFullManual)));
              },
            ),
          ],
        ]),
      ),
    );
  }

  Widget _row(
      {required String key,
      required bool ok,
      required String title,
      required String sub,
      String? action,
      required VoidCallback onTap}) {
    final s = Theme.of(context).colorScheme;
    return Row(key: ValueKey(key), crossAxisAlignment: CrossAxisAlignment.start, children: [
      Icon(ok ? Icons.check_circle_rounded : Icons.error_outline_rounded,
          color: ok ? Brand.success : Brand.warning),
      const SizedBox(width: Gap.sm),
      Expanded(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(title, style: const TextStyle(fontWeight: FontWeight.w700)),
          Text(sub, style: TextStyle(color: s.onSurfaceVariant)),
          if (action != null)
            Padding(
              padding: const EdgeInsets.only(top: Gap.xs),
              child: ConstrainedBox(
                constraints: const BoxConstraints(minHeight: 48),
                child: OutlinedButton(
                  key: ValueKey('$key-btn'),
                  onPressed: onTap,
                  child: Text(action),
                ),
              ),
            ),
        ]),
      ),
    ]);
  }
}
