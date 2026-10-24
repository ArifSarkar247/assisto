import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../api.dart';
import '../config.dart';
import '../l10n/app_localizations.dart';
import '../shop_api.dart';
import '../state.dart';
import '../theme.dart';
import 'shop_live_screen.dart';

/// "Offline since …" / "Online" for a camera or site row (`online`,
/// `last_seen` come from the server: heartbeat or camera webhook).
String shopSeenLabel(AppLocalizations t, BuildContext context, Map<String, dynamic> row) {
  if (row['online'] == true) return t.shopCamOnline;
  final iso = (row['last_seen'] ?? '').toString();
  final dt = DateTime.tryParse(iso)?.toLocal();
  if (dt == null) return t.shopCamNeverSeen;
  final loc = MaterialLocalizations.of(context);
  final now = DateTime.now();
  final sameDay = dt.year == now.year && dt.month == now.month && dt.day == now.day;
  final time = loc.formatTimeOfDay(TimeOfDay.fromDateTime(dt));
  return t.shopCamOfflineSince(sameDay ? time : '${loc.formatShortDate(dt)} $time');
}

/// A small online/offline pill.
class ShopSeenPill extends StatelessWidget {
  final Map<String, dynamic> row;
  const ShopSeenPill({super.key, required this.row});
  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final on = row['online'] == true;
    final c = on ? AssistoTokens.of(context).success : Theme.of(context).colorScheme.onSurfaceVariant;
    return Row(mainAxisSize: MainAxisSize.min, children: [
      Icon(Icons.circle, size: 9, color: c),
      const SizedBox(width: Gap.xs),
      Flexible(
        child: Text(shopSeenLabel(t, context, row),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: AType.labelMedium.copyWith(color: c, fontWeight: FontWeight.w600)),
      ),
    ]);
  }
}

String _hhmm(TimeOfDay t) =>
    '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

TimeOfDay? _parse(Object? v) {
  final p = (v ?? '').toString().split(':');
  if (p.length != 2) return null;
  final h = int.tryParse(p[0]), m = int.tryParse(p[1]);
  if (h == null || m == null) return null;
  return TimeOfDay(hour: h, minute: m);
}

/// Open/close time pickers + a "no hours" state. [value] is {open, close} or null.
class ShopHoursField extends StatelessWidget {
  final Map<String, dynamic>? value;
  final String emptyLabel;
  final ValueChanged<Map<String, dynamic>?> onChanged;
  const ShopHoursField(
      {super.key, required this.value, required this.emptyLabel, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final open = _parse(value?['open']);
    final close = _parse(value?['close']);
    Future<void> pick(bool isOpen) async {
      final init = (isOpen ? open : close) ??
          (isOpen ? const TimeOfDay(hour: 9, minute: 0) : const TimeOfDay(hour: 22, minute: 0));
      final got = await showTimePicker(context: context, initialTime: init);
      if (got == null) return;
      final o = isOpen ? got : (open ?? const TimeOfDay(hour: 9, minute: 0));
      final c = isOpen ? (close ?? const TimeOfDay(hour: 22, minute: 0)) : got;
      onChanged({'open': _hhmm(o), 'close': _hhmm(c)});
    }

    final loc = MaterialLocalizations.of(context);
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Wrap(spacing: Gap.sm, runSpacing: Gap.sm, children: [
        OutlinedButton.icon(
          onPressed: () => pick(true),
          icon: const Icon(Icons.wb_sunny_outlined, size: 18),
          label: Text(open == null ? t.shopCamOpens : t.shopCamOpensAt(loc.formatTimeOfDay(open))),
        ),
        OutlinedButton.icon(
          onPressed: () => pick(false),
          icon: const Icon(Icons.nightlight_outlined, size: 18),
          label: Text(
              close == null ? t.shopCamCloses : t.shopCamClosesAt(loc.formatTimeOfDay(close))),
        ),
        if (value != null)
          TextButton(onPressed: () => onChanged(null), child: Text(t.shopCamClearHours)),
      ]),
      if (value == null)
        Padding(
          padding: const EdgeInsets.only(top: Gap.xs),
          child: Text(emptyLabel,
              style: AType.bodySmall.copyWith(color: scheme.onSurfaceVariant)),
        ),
    ]);
  }
}

/// Per-camera settings sheet: name, on/off, hours, restricted zone, live view,
/// webhook setup (Hikvision / Dahua), rotate token, delete. Owner only (the
/// server re-checks every call).
class ShopCameraSettingsSheet extends StatefulWidget {
  final Map<String, dynamic> camera;
  const ShopCameraSettingsSheet({super.key, required this.camera});

  @override
  State<ShopCameraSettingsSheet> createState() => _ShopCameraSettingsSheetState();
}

class _ShopCameraSettingsSheetState extends State<ShopCameraSettingsSheet> {
  late final TextEditingController _name;
  late bool _enabled;
  late bool _restricted;
  Map<String, dynamic>? _hours;
  String _token = '';
  bool _busy = false;

  int get _id => (widget.camera['id'] as num).toInt();

  @override
  void initState() {
    super.initState();
    final c = widget.camera;
    _name = TextEditingController(text: (c['name'] ?? '').toString());
    _enabled = c['enabled'] == true;
    _restricted = c['restricted_zone'] != false;
    final h = c['hours'];
    _hours = h is Map ? h.cast<String, dynamic>() : null;
    _token = (c['camera_token'] ?? '').toString();
    if (_token.isEmpty) _loadToken();
  }

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Future<void> _loadToken() async {
    try {
      final r = await context.read<AppState>().api.shopCamera(_id);
      if (mounted) setState(() => _token = (r['camera_token'] ?? '').toString());
    } catch (_) {}
  }

  void _toast(String m) =>
      ScaffoldMessenger.of(context)..clearSnackBars()..showSnackBar(SnackBar(content: Text(m)));

  Future<void> _patch(Map<String, dynamic> body, {String? ok}) async {
    final t = AppLocalizations.of(context);
    setState(() => _busy = true);
    try {
      final r = await context.read<AppState>().api.shopPatchCamera(_id, body);
      if ((r['camera_token'] ?? '').toString().isNotEmpty) {
        _token = r['camera_token'].toString();
      }
      _enabled = r['enabled'] == true;
      if (ok != null) _toast(ok);
    } on ApiException catch (e) {
      _toast(e.message); // e.g. honest "needs N credits" on re-enable
    } catch (_) {
      _toast(t.shopCamSaveFailed);
    }
    if (mounted) setState(() => _busy = false);
  }

  Future<void> _save() async {
    final t = AppLocalizations.of(context);
    await _patch({
      'name': _name.text.trim(),
      'hours': _hours,
      'restricted_zone': _restricted,
    }, ok: t.shopCamSaved);
  }

  Future<void> _rotate() async {
    final t = AppLocalizations.of(context);
    final yes = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(t.shopCamRotateTitle),
        content: Text(t.shopCamRotateBody),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(t.cancel)),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(t.shopCamRotate)),
        ],
      ),
    );
    if (yes == true) await _patch({'rotate_token': true}, ok: t.shopCamRotated);
  }

  Future<void> _delete() async {
    final t = AppLocalizations.of(context);
    final yes = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(t.shopCamDeleteTitle),
        content: Text(t.shopCamDeleteBody),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(t.cancel)),
          FilledButton(
              style: FilledButton.styleFrom(
                  backgroundColor: Theme.of(ctx).colorScheme.error,
                  foregroundColor: Theme.of(ctx).colorScheme.onError),
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(t.shopCamDelete)),
        ],
      ),
    );
    if (yes != true || !mounted) return;
    try {
      await context.read<AppState>().api.shopDeleteCamera(_id);
      if (mounted) Navigator.pop(context, true);
    } catch (_) {
      _toast(t.shopCamSaveFailed);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    return Padding(
        padding: EdgeInsets.fromLTRB(
            Gap.lg, 0, Gap.lg, Gap.xl + MediaQuery.of(context).viewInsets.bottom),
        child: SingleChildScrollView(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            // qa1: title + status pill shared one row and the title was cut
            // to "Camera…" by a long "Offline since …" pill — stack them.
            Text(t.shopCamSettingsTitle,
                style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: Gap.xs),
            ShopSeenPill(row: widget.camera),
            const SizedBox(height: Gap.md),
            TextField(
              controller: _name,
              textCapitalization: TextCapitalization.words,
              decoration: InputDecoration(
                  labelText: t.shopBoxCameraName, border: const OutlineInputBorder()),
            ),
            const SizedBox(height: Gap.sm),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              value: _enabled,
              title: Text(t.shopCamEnabled),
              subtitle: Text(t.shopCamEnabledHelp),
              onChanged: _busy ? null : (v) => _patch({'enabled': v}),
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              value: _restricted,
              title: Text(t.shopCamRestricted),
              subtitle: Text(t.shopCamRestrictedHelp),
              onChanged: (v) => setState(() => _restricted = v),
            ),
            const SizedBox(height: Gap.xs),
            Text(t.shopCamHours, style: const TextStyle(fontWeight: FontWeight.w600)),
            const SizedBox(height: Gap.xs),
            ShopHoursField(
              value: _hours,
              emptyLabel: t.shopCamHoursUsesSite,
              onChanged: (h) => setState(() => _hours = h),
            ),
            const SizedBox(height: Gap.md),
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                onPressed: _busy ? null : _save,
                child: Text(t.save),
              ),
            ),
            const SizedBox(height: Gap.md),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: !_enabled
                    ? null
                    : () => Navigator.of(context).push(MaterialPageRoute(
                        builder: (_) => ShopLiveScreen(
                            cameraId: _id, cameraName: _name.text.trim()))),
                icon: const Icon(Icons.live_tv_outlined),
                label: Text(t.shopLiveOpen),
              ),
            ),
            const SizedBox(height: Gap.md),
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.phone_android),
              title: Text(t.shopCamTokenLabel),
              subtitle: Text(t.shopCamTokenHelp),
              trailing: IconButton(
                tooltip: t.copy,
                icon: const Icon(Icons.copy),
                onPressed: _token.isEmpty
                    ? null
                    : () async {
                        await Clipboard.setData(ClipboardData(text: _token));
                        _toast(t.shopCamTokenCopied);
                      },
              ),
            ),
            const SizedBox(height: Gap.sm),
            ShopWebhookCard(token: _token),
            const SizedBox(height: Gap.md),
            Wrap(spacing: Gap.sm, runSpacing: Gap.sm, children: [
              TextButton.icon(
                onPressed: _busy ? null : _rotate,
                icon: const Icon(Icons.autorenew),
                label: Text(t.shopCamRotate),
              ),
              TextButton.icon(
                style: TextButton.styleFrom(foregroundColor: scheme.error),
                onPressed: _busy ? null : _delete,
                icon: const Icon(Icons.delete_outline),
                label: Text(t.shopCamDelete),
              ),
            ]),
          ]),
        ),
    );
  }
}

/// Webhook setup for an IP camera's OWN event push (Hikvision "HTTP Listening"
/// / Dahua event push). The token in the URL identifies this camera — treat it
/// like a password.
class ShopWebhookCard extends StatelessWidget {
  final String token;
  const ShopWebhookCard({super.key, required this.token});

  static String url(String vendor, String token) =>
      '${AppConfig.apiBase}${AppConfig.apiPrefix}/shop/hook/$vendor/$token';

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    Widget row(String label, String vendor) {
      final u = token.isEmpty ? '' : url(vendor, token);
      return Padding(
        padding: const EdgeInsets.only(top: Gap.sm),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(label, style: const TextStyle(fontWeight: FontWeight.w600)),
          const SizedBox(height: Gap.xs),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(Gap.sm),
            decoration: BoxDecoration(
                color: scheme.surface, borderRadius: BorderRadius.circular(Radii.sm)),
            child: Row(children: [
              Expanded(
                child: SelectableText(u.isEmpty ? '…' : u,
                    style: AType.bodySmall.copyWith(fontFamily: 'monospace')),
              ),
              IconButton(
                tooltip: t.copy,
                onPressed: u.isEmpty
                    ? null
                    : () async {
                        await Clipboard.setData(ClipboardData(text: u));
                        if (context.mounted) {
                          ScaffoldMessenger.of(context)
                            ..clearSnackBars()
                            ..showSnackBar(SnackBar(content: Text(t.shopHookCopied)));
                        }
                      },
                icon: const Icon(Icons.copy, size: 18),
              ),
            ]),
          ),
        ]),
      );
    }

    return Card(
      margin: EdgeInsets.zero,
      color: scheme.surfaceContainerHighest,
      child: Padding(
        padding: const EdgeInsets.all(Gap.md),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Icon(Icons.settings_input_antenna, size: 18, color: scheme.primary),
            const SizedBox(width: Gap.sm),
            Expanded(
                child: Text(t.shopHookTitle,
                    style: const TextStyle(fontWeight: FontWeight.w700))),
          ]),
          const SizedBox(height: Gap.xs),
          Text(t.shopHookIntro,
              style: AType.bodySmall.copyWith(color: scheme.onSurfaceVariant, height: 1.4)),
          row(t.shopHookHikvision, 'hikvision'),
          row(t.shopHookDahua, 'dahua'),
          const SizedBox(height: Gap.sm),
          Text(t.shopHookGuideHik,
              style: AType.bodySmall.copyWith(color: scheme.onSurfaceVariant, height: 1.4)),
          const SizedBox(height: Gap.xs),
          Text(t.shopHookGuideDahua,
              style: AType.bodySmall.copyWith(color: scheme.onSurfaceVariant, height: 1.4)),
          const SizedBox(height: Gap.xs),
          Text(t.shopHookSecret,
              style: AType.bodySmall.copyWith(color: scheme.error, height: 1.4)),
        ]),
      ),
    );
  }
}

/// Site-level shop hours + "mirror Assisto POS" switch.
class ShopSiteHoursSheet extends StatefulWidget {
  final Map<String, dynamic> site;
  const ShopSiteHoursSheet({super.key, required this.site});
  @override
  State<ShopSiteHoursSheet> createState() => _ShopSiteHoursSheetState();
}

class _ShopSiteHoursSheetState extends State<ShopSiteHoursSheet> {
  Map<String, dynamic>? _hours;
  late bool _pos;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    final h = widget.site['hours'];
    _hours = (h is Map && h.isNotEmpty) ? h.cast<String, dynamic>() : null;
    _pos = widget.site['pos_link'] != false;
  }

  Future<void> _save() async {
    final t = AppLocalizations.of(context);
    setState(() => _busy = true);
    try {
      await context.read<AppState>().api.patchJson(
          '/shop/sites/${widget.site['id']}', {'hours': _hours ?? {}, 'pos_link': _pos});
      if (mounted) Navigator.pop(context, true);
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(t.shopCamSaveFailed)));
      }
    }
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(Gap.lg, 0, Gap.lg, Gap.xl),
      child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start,
          children: [
        Text(t.shopSiteHoursTitle, style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: Gap.sm),
        Text(t.shopSiteHoursExplain,
            style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant, height: 1.4)),
        const SizedBox(height: Gap.md),
        ShopHoursField(
          value: _hours,
          emptyLabel: t.shopSiteNoHours,
          onChanged: (h) => setState(() => _hours = h),
        ),
        const SizedBox(height: Gap.sm),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          value: _pos,
          title: Text(t.shopSitePosLink),
          subtitle: Text(t.shopSitePosLinkHelp),
          onChanged: (v) => setState(() => _pos = v),
        ),
        const SizedBox(height: Gap.sm),
        SizedBox(
          width: double.infinity,
          child: FilledButton(onPressed: _busy ? null : _save, child: Text(t.save)),
        ),
      ]),
    );
  }
}
