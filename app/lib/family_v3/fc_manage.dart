import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:timezone/data/latest.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;
import 'package:url_launcher/url_launcher.dart';

import '../api.dart';
import '../l10n/app_localizations.dart';
import '../l10n/fcrest_zones.dart';
import '../services/action_feedback.dart';
import '../state.dart';
import '../theme.dart';
import '../widgets/app_sheet.dart';
import '../widgets/local_counter.dart';
import 'fc_api.dart';
import 'fc_text.dart';

/// fcrest — Family Care V3 items the server already had but the app could
/// not reach: rename a family (admin), the name a member is shown by, remove
/// a member (admin), Probashi "Where I live" (self only) and the two clocks,
/// and the 15 % battery last place on the card. Never invents data: a clock
/// is shown only for a real zone, a map only for a real shared point.

bool _tzReady = false;

/// "3:15 AM" in [zone] at [now] (Bangla digits in Bangla); null when the
/// zone is unknown on this phone.
String? fcrClockIn(BuildContext context, String zone, DateTime now) {
  try {
    if (!_tzReady) {
      tzdata.initializeTimeZones();
      _tzReady = true;
    }
    final at = tz.TZDateTime.from(now.toUtc(), tz.getLocation(zone));
    final tod = TimeOfDay(hour: at.hour, minute: at.minute);
    return fcDigits(context, MaterialLocalizations.of(context).formatTimeOfDay(tod));
  } catch (_) {
    return null;
  }
}

/// Both clocks for a member who lives abroad: "Their time 3:15 AM · here
/// 6:15 AM". Empty when the member lives in Bangladesh / the zone is unknown.
String fcrBothClocks(BuildContext context, Map member, DateTime now) {
  final zone = '${member['abroad_tz'] ?? ''}'.trim();
  if (zone.isEmpty) return '';
  final theirs = fcrClockIn(context, zone, now);
  if (theirs == null) return '';
  final t = AppLocalizations.of(context);
  final mine = fcDigits(context,
      MaterialLocalizations.of(context).formatTimeOfDay(TimeOfDay.fromDateTime(now.toLocal())));
  final lang = Localizations.localeOf(context).languageCode == 'bn' ? 'bn' : 'en';
  return '${fcrZoneName(zone, lang)} · ${t.fcrTheirTime(theirs)} · ${t.fcrMyTime(mine)}';
}

/// The 15 % battery share (fcbrain BRAIN 3): {lat, lng, at, why} or null.
Map? fcrLastLocation(Map? brain) {
  final l = (brain ?? const {})['last_location'];
  if (l is! Map || l['lat'] is! num || l['lng'] is! num) return null;
  return l;
}

/// Opens the shared point in the phone's own map app (no Google API cost).
Future<void> fcrOpenMap(BuildContext context, Map loc) async {
  final lat = (loc['lat'] as num).toDouble();
  final lng = (loc['lng'] as num).toDouble();
  final geo = Uri.parse('geo:$lat,$lng?q=$lat,$lng');
  try {
    if (await launchUrl(geo, mode: LaunchMode.externalApplication)) return;
  } catch (_) {
    // no map app for geo: — the web map below
  }
  try {
    await launchUrl(Uri.parse('https://www.google.com/maps/search/?api=1&query=$lat,$lng'),
        mode: LaunchMode.externalApplication);
  } catch (e) {
    if (context.mounted) showActionFailed(context, 'fcr.map', e);
  }
}

/// One-line text sheet (family name, member label). Returns the text or null.
/// The sheet owns its controller (disposed with the sheet, never while the
/// closing animation still shows the field).
Future<String?> fcrTextSheet(BuildContext context,
        {required String title, required String hint, String initial = '', int max = 40, Key? fieldKey, String? action}) =>
    showAppSheet<String>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (ctx) => _FcrTextSheet(
          title: title, hint: hint, initial: initial, max: max, fieldKey: fieldKey ?? const ValueKey('fcr-text'),
          action: action),
    );

class _FcrTextSheet extends StatefulWidget {
  final String title, hint, initial;
  final int max;
  final Key fieldKey;
  final String? action;
  const _FcrTextSheet(
      {required this.title,
      required this.hint,
      required this.initial,
      required this.max,
      required this.fieldKey,
      this.action});
  @override
  State<_FcrTextSheet> createState() => _FcrTextSheetState();
}

class _FcrTextSheetState extends State<_FcrTextSheet> {
  late final TextEditingController _ctrl = TextEditingController(text: widget.initial);

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    return Padding(
      padding: EdgeInsets.fromLTRB(Gap.lg, 0, Gap.lg, Gap.lg + MediaQuery.of(context).viewInsets.bottom),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(widget.title,
              style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700)),
          const SizedBox(height: Gap.sm),
          TextField(
            key: widget.fieldKey,
            controller: _ctrl,
            autofocus: true,
            maxLength: widget.max,
            buildCounter: localCounter,
            decoration: InputDecoration(labelText: widget.hint),
            onSubmitted: (s) => Navigator.pop(context, s),
          ),
          const SizedBox(height: Gap.sm),
          FilledButton(
            key: const ValueKey('fcr-text-save'),
            style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(48)),
            onPressed: () => Navigator.pop(context, _ctrl.text),
            child: Text(widget.action ?? t.save),
          ),
        ],
      ),
    );
  }
}

/// Admin: rename the family. true when the server took it.
Future<bool> fcrRenameFamily(BuildContext context, int familyId, String current) async {
  final t = AppLocalizations.of(context);
  final name = await fcrTextSheet(context,
      title: t.fcrRename, hint: t.fcrRenameHint, initial: current, max: 60,
      fieldKey: const ValueKey('fcr-rename-field'));
  if (name == null || name.trim().isEmpty || name.trim() == current || !context.mounted) return false;
  return _post(context, () => context.read<AppState>().api.fcRename(familyId, name.trim()),
      t.fcrRenamed, 'fcr.rename');
}

Future<bool> _post(BuildContext context, Future<Object?> Function() call, String done, String tag) async {
  final m = ScaffoldMessenger.maybeOf(context);
  try {
    await call();
    m?.showSnackBar(SnackBar(content: Text(done)));
    return true;
  } on ApiException catch (e) {
    m?.showSnackBar(SnackBar(content: Text(e.message)));
  } catch (e) {
    if (context.mounted) showActionFailed(context, tag, e);
  }
  return false;
}

/// "Where I live" picker: Bangladesh (clears) or a country abroad.
/// Returns '' for Bangladesh, the zone, or null when dismissed.
Future<String?> fcrPickZone(BuildContext context, String current) {
  final t = AppLocalizations.of(context);
  final lang = Localizations.localeOf(context).languageCode == 'bn' ? 'bn' : 'en';
  Widget row(BuildContext ctx, String zone, String title) => ListTile(
        key: ValueKey('fcr-zone-${zone.isEmpty ? 'bd' : zone}'),
        minTileHeight: 52,
        title: Text(title),
        trailing: zone == current ? const Icon(Icons.check_rounded) : null,
        onTap: () => Navigator.pop(ctx, zone),
      );
  return showAppSheet<String>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (ctx) => SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: MediaQuery.of(ctx).size.height * 0.8),
        child: ListView(
          key: const ValueKey('fcr-zone-list'),
          shrinkWrap: true,
          padding: const EdgeInsets.only(bottom: Gap.lg),
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(Gap.lg, 0, Gap.lg, Gap.xs),
              child: Text(t.fcrLiveTitle,
                  style: Theme.of(ctx).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700)),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(Gap.lg, 0, Gap.lg, Gap.sm),
              child: Text(t.fcrLiveSub),
            ),
            row(ctx, '', t.fcrLiveBd),
            for (final z in kFcrZones) row(ctx, z[0], lang == 'bn' ? z[2] : z[1]),
          ],
        ),
      ),
    ),
  );
}

/// Member page block: Where I live (me), name shown (me or admin), remove
/// (admin, not me). [onChanged] reloads; [onRemoved] leaves the page.
class FcrMemberManage extends StatelessWidget {
  final int familyId;
  final Map member;
  final String myRole;
  final VoidCallback onChanged;
  final VoidCallback onRemoved;
  const FcrMemberManage(
      {super.key,
      required this.familyId,
      required this.member,
      required this.myRole,
      required this.onChanged,
      required this.onRemoved});

  int get _uid => (member['user_id'] as num).toInt();

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final me = member['me'] == true;
    final admin = myRole == 'admin';
    if (!me && !admin) return const SizedBox.shrink();
    final lang = Localizations.localeOf(context).languageCode == 'bn' ? 'bn' : 'en';
    final zone = '${member['abroad_tz'] ?? ''}'.trim();
    final label = '${member['label'] ?? ''}'.trim();
    final api = context.read<AppState>().api;
    return Column(
      key: const ValueKey('fcr-manage'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(t.fcrManageTitle,
            style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
        if (me)
          ListTile(
            key: const ValueKey('fcr-live'),
            contentPadding: EdgeInsets.zero,
            minTileHeight: 56,
            leading: const Icon(Icons.public_rounded),
            title: Text(t.fcrLiveTitle),
            subtitle: Text(zone.isEmpty ? t.fcrLiveBd : fcrZoneName(zone, lang)),
            trailing: const Icon(Icons.chevron_right_rounded),
            onTap: () async {
              final z = await fcrPickZone(context, zone);
              if (z == null || z == zone || !context.mounted) return;
              if (await _post(context, () => api.fcUpdateMember(familyId, _uid, {'abroad_tz': z}),
                  t.fcrLiveSaved, 'fcr.zone')) {
                onChanged();
              }
            },
          ),
        ListTile(
          key: const ValueKey('fcr-label'),
          contentPadding: EdgeInsets.zero,
          minTileHeight: 56,
          leading: const Icon(Icons.badge_outlined),
          title: Text(t.fcrLabelTitle),
          subtitle: label.isEmpty ? null : Text(label),
          trailing: const Icon(Icons.edit_rounded),
          onTap: () async {
            final v = await fcrTextSheet(context,
                title: t.fcrLabelTitle, hint: t.fcrLabelHint, initial: label,
                fieldKey: const ValueKey('fcr-label-field'));
            if (v == null || v.trim() == label || !context.mounted) return;
            if (await _post(context, () => api.fcUpdateMember(familyId, _uid, {'label': v.trim()}),
                t.fcrLabelSaved, 'fcr.label')) {
              onChanged();
            }
          },
        ),
        if (admin && !me)
          ListTile(
            key: const ValueKey('fcr-remove'),
            contentPadding: EdgeInsets.zero,
            minTileHeight: 56,
            leading: Icon(Icons.person_remove_rounded, color: fcInk(context, 'sos')),
            title: Text(t.fcrRemove, style: TextStyle(color: fcInk(context, 'sos'))),
            onTap: () async {
              final name = label.isNotEmpty ? label : '${member['name'] ?? ''}';
              final ok = await showDialog<bool>(
                context: context,
                builder: (ctx) => AlertDialog(
                  scrollable: true,
                  title: Text(t.fcrRemove),
                  content: Text(t.fcrRemoveConfirm(name)),
                  actions: [
                    TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(t.cancel)),
                    FilledButton(
                      key: const ValueKey('fcr-remove-yes'),
                      style: FilledButton.styleFrom(backgroundColor: Brand.danger, foregroundColor: Colors.white),
                      onPressed: () => Navigator.pop(ctx, true),
                      child: Text(t.fcrRemove),
                    ),
                  ],
                ),
              );
              if (ok != true || !context.mounted) return;
              if (await _post(context, () => api.fcRemoveMember(familyId, _uid), t.fcrRemoved, 'fcr.remove')) {
                onRemoved();
              }
            },
          ),
      ],
    );
  }
}
