import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart' show LaunchMode;

import '../../l10n/app_localizations.dart';
import '../../services/action_feedback.dart' show openForUser;
import '../../services/error_kind.dart' show honestFailText;
import '../../state.dart';
import '../../theme.dart';
import '../../widgets/app_sheet.dart';
import '../../widgets/cv_empty.dart' show pickCirclePerson;
import '../../widgets/local_counter.dart';
import '../../widgets/local_digits.dart';
import '../../widgets/skeleton.dart';
import '../travel_planner_screen.dart' show tvNiceDate;
import 'life_logic.dart';

/// p3life — shared pieces for Travel planner, Wedding & events and Ride &
/// food (owner PART 3, 3 Nov):
///   * [LifeCache]          offline copy of each list (last good load)
///   * [LifeOfflineBanner]  honest "showing the saved copy" line
///   * [LifeCollectionView] one generic list (load / add / edit / delete /
///                          empty state with benefit + big button + how-to)
///   * [showLifeForm]       one generic form sheet (text, money, date, time,
///                          choice, switch) — every maxLength field uses
///                          localCounter
///   * [shareLifeLink]      read-only link / guest RSVP link → a My Circle
///                          person by SMS, or any app, and "turn link off"
///   * [openOfficial]       opens an official source (cited by name)

String _ck(String path) => 'life_cache_v1:$path';

/// Offline copy of a collection: every good load is saved on the phone; when
/// the network fails the saved copy is returned with offline=true. Nothing
/// is ever invented — no saved copy means the honest error state.
class LifeCache {
  LifeCache._();

  /// Tests: force the network to fail.
  static bool forceOffline = false;

  static Future<({List<Map<String, dynamic>> rows, bool offline})> list(
      BuildContext context, String path) async {
    final api = context.read<AppState>().api;
    try {
      if (forceOffline) throw StateError('offline (test)');
      final rows = await api.listItems(path);
      try {
        await Settings.setString(_ck(path), jsonEncode(rows));
      } catch (_) {}
      return (rows: rows, offline: false);
    } catch (e) {
      final raw = await Settings.getString(_ck(path));
      if (raw == null || raw.isEmpty) rethrow;
      try {
        final rows = (jsonDecode(raw) as List)
            .whereType<Map>()
            .map((m) => m.cast<String, dynamic>())
            .toList();
        return (rows: rows, offline: true);
      } catch (_) {
        rethrow;
      }
    }
  }
}

class LifeOfflineBanner extends StatelessWidget {
  const LifeOfflineBanner({super.key});
  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final s = Theme.of(context).colorScheme;
    return Semantics(
      liveRegion: true,
      child: Container(
        key: const ValueKey('life-offline'),
        width: double.infinity,
        color: s.tertiaryContainer,
        padding: const EdgeInsets.symmetric(horizontal: Gap.lg, vertical: Gap.sm),
        child: Row(children: [
          Icon(Icons.cloud_off_rounded, color: s.onTertiaryContainer),
          const SizedBox(width: Gap.sm),
          Expanded(
              child: Text(t.p3lOfflineCopy,
                  style: TextStyle(color: s.onTertiaryContainer))),
        ]),
      ),
    );
  }
}

// ---------------------------------------------------------------- forms
enum LifeFieldKind { text, multiline, phone, money, number, date, time, choice, toggle }

class LifeField {
  final String key;
  final String label;
  final LifeFieldKind kind;
  final int maxLength;
  final bool required;
  final List<(String, String)> options; // (value, label) for choice
  final bool circlePick; // show "Pick from My Circle" (fills this + 'phone')
  const LifeField(this.key, this.label,
      {this.kind = LifeFieldKind.text,
      this.maxLength = 80,
      this.required = false,
      this.options = const [],
      this.circlePick = false});
}

/// Generic form sheet. Returns the row body (money as poisha, dates ISO,
/// time HH:MM) or null when cancelled.
Future<Map<String, dynamic>?> showLifeForm(BuildContext context,
    {required String title,
    required List<LifeField> fields,
    Map<String, dynamic>? existing}) {
  return showAppSheet<Map<String, dynamic>>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (_) => _LifeForm(title: title, fields: fields, existing: existing),
  );
}

class _LifeForm extends StatefulWidget {
  final String title;
  final List<LifeField> fields;
  final Map<String, dynamic>? existing;
  const _LifeForm({required this.title, required this.fields, this.existing});
  @override
  State<_LifeForm> createState() => _LifeFormState();
}

class _LifeFormState extends State<_LifeForm> {
  final Map<String, TextEditingController> _c = {};
  final Map<String, dynamic> _v = {};
  String? _err;

  @override
  void initState() {
    super.initState();
    final e = widget.existing ?? const {};
    for (final f in widget.fields) {
      switch (f.kind) {
        case LifeFieldKind.money:
          final p = poishaOf(e[f.key]);
          _c[f.key] = TextEditingController(
              text: e[f.key] == null ? '' : (p % 100 == 0 ? '${p ~/ 100}' : (p / 100).toStringAsFixed(2)));
        case LifeFieldKind.date:
        case LifeFieldKind.time:
        case LifeFieldKind.choice:
          _v[f.key] = e[f.key] ?? (f.kind == LifeFieldKind.choice && f.options.isNotEmpty ? f.options.first.$1 : null);
        case LifeFieldKind.toggle:
          _v[f.key] = e[f.key] == true;
        default:
          _c[f.key] = TextEditingController(text: '${e[f.key] ?? ''}');
      }
    }
    if (widget.fields.any((f) => f.circlePick) && !_c.containsKey('phone')) {
      _c['phone'] = TextEditingController(text: '${e['phone'] ?? ''}');
    }
  }

  @override
  void dispose() {
    for (final c in _c.values) {
      c.dispose();
    }
    super.dispose();
  }

  Widget _field(BuildContext context, LifeField f) {
    final t = AppLocalizations.of(context);
    switch (f.kind) {
      case LifeFieldKind.date:
        final v = '${_v[f.key] ?? ''}';
        return SizedBox(
          width: double.infinity,
          child: OutlinedButton.icon(
            key: ValueKey('life-date-${f.key}'),
            style: OutlinedButton.styleFrom(minimumSize: const Size(48, 48), alignment: Alignment.centerLeft),
            icon: const Icon(Icons.calendar_today_rounded, size: 18),
            label: Text(v.isEmpty ? f.label : '${f.label}: ${tvNiceDate(context, v)}'),
            onPressed: () async {
              final now = DateTime.now();
              final d = await showDatePicker(
                context: context,
                initialDate: parseIsoDate(v) ?? now,
                firstDate: DateTime(now.year - 5),
                lastDate: DateTime(now.year + 15),
              );
              if (d != null && mounted) setState(() => _v[f.key] = isoDate(d));
            },
          ),
        );
      case LifeFieldKind.time:
        final v = '${_v[f.key] ?? ''}';
        return SizedBox(
          width: double.infinity,
          child: OutlinedButton.icon(
            key: ValueKey('life-time-${f.key}'),
            style: OutlinedButton.styleFrom(minimumSize: const Size(48, 48), alignment: Alignment.centerLeft),
            icon: const Icon(Icons.schedule_rounded, size: 18),
            label: Text(v.isEmpty ? f.label : '${f.label}: ${ld(context, v)}'),
            onPressed: () async {
              final p = v.split(':');
              final tod = await showTimePicker(
                context: context,
                initialTime: p.length == 2
                    ? TimeOfDay(hour: int.tryParse(p[0]) ?? 9, minute: int.tryParse(p[1]) ?? 0)
                    : TimeOfDay.now(),
              );
              if (tod != null && mounted) {
                setState(() => _v[f.key] =
                    '${tod.hour.toString().padLeft(2, '0')}:${tod.minute.toString().padLeft(2, '0')}');
              }
            },
          ),
        );
      case LifeFieldKind.choice:
        return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(f.label, style: Theme.of(context).textTheme.labelLarge),
          const SizedBox(height: Gap.xs),
          Wrap(spacing: Gap.sm, runSpacing: Gap.xs, children: [
            for (final o in f.options)
              ChoiceChip(
                key: ValueKey('life-choice-${f.key}-${o.$1}'),
                label: Text(o.$2),
                selected: _v[f.key] == o.$1,
                materialTapTargetSize: MaterialTapTargetSize.padded,
                onSelected: (_) => setState(() => _v[f.key] = o.$1),
              ),
          ]),
        ]);
      case LifeFieldKind.toggle:
        return SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: Text(f.label),
          value: _v[f.key] == true,
          onChanged: (b) => setState(() => _v[f.key] = b),
        );
      default:
        final kb = switch (f.kind) {
          LifeFieldKind.phone => TextInputType.phone,
          LifeFieldKind.money => const TextInputType.numberWithOptions(decimal: true),
          LifeFieldKind.number => TextInputType.number,
          LifeFieldKind.multiline => TextInputType.multiline,
          _ => TextInputType.text,
        };
        final tf = TextField(
          key: ValueKey('life-field-${f.key}'),
          controller: _c[f.key],
          keyboardType: kb,
          maxLength: f.maxLength,
          buildCounter: localCounter,
          minLines: f.kind == LifeFieldKind.multiline ? 2 : 1,
          maxLines: f.kind == LifeFieldKind.multiline ? 4 : 1,
          textCapitalization: f.kind == LifeFieldKind.text
              ? TextCapitalization.sentences
              : TextCapitalization.none,
          decoration: InputDecoration(
            labelText: f.required ? '${f.label} *' : f.label,
            prefixText: f.kind == LifeFieldKind.money ? '৳ ' : null,
            border: const OutlineInputBorder(),
          ),
        );
        if (!f.circlePick) return tf;
        return Column(children: [
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              key: const ValueKey('life-circle-pick'),
              style: OutlinedButton.styleFrom(minimumSize: const Size(48, 48)),
              icon: const Icon(Icons.diversity_1_rounded),
              label: Text(t.p3lPickFromCircle),
              onPressed: () async {
                final r = await pickCirclePerson(context, title: t.p3lPickFromCircle);
                if (r == null || !mounted) return;
                final n = '${r['name'] ?? ''}'.trim();
                final p = '${r['phone'] ?? ''}'.trim();
                setState(() {
                  if (n.isNotEmpty) _c[f.key]!.text = n;
                  if (p.isNotEmpty) _c['phone']?.text = p;
                });
              },
            ),
          ),
          const SizedBox(height: Gap.sm),
          tf,
        ]);
    }
  }

  void _save() {
    final t = AppLocalizations.of(context);
    final out = <String, dynamic>{};
    for (final f in widget.fields) {
      switch (f.kind) {
        case LifeFieldKind.money:
          final raw = _c[f.key]!.text;
          if (raw.trim().isEmpty) {
            if (f.required) return setState(() => _err = t.p3lRequired(f.label));
            out[f.key] = 0;
          } else {
            final p = parsePoisha(raw);
            if (p == null) return setState(() => _err = t.p3lBadAmount(f.label));
            out[f.key] = p;
          }
        case LifeFieldKind.number:
          final raw = asciiDigits(_c[f.key]!.text.trim());
          out[f.key] = int.tryParse(raw) ?? 0;
        case LifeFieldKind.date:
        case LifeFieldKind.time:
        case LifeFieldKind.choice:
          final v = _v[f.key];
          if (f.required && (v == null || '$v'.isEmpty)) {
            return setState(() => _err = t.p3lRequired(f.label));
          }
          out[f.key] = v;
        case LifeFieldKind.toggle:
          out[f.key] = _v[f.key] == true;
        default:
          final v = _c[f.key]!.text.trim();
          if (f.required && v.isEmpty) return setState(() => _err = t.p3lRequired(f.label));
          out[f.key] = v;
      }
    }
    if (_c.containsKey('phone') && !widget.fields.any((f) => f.key == 'phone')) {
      out['phone'] = _c['phone']!.text.trim();
    }
    Navigator.pop(context, out);
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    return SingleChildScrollView(
      padding: EdgeInsets.fromLTRB(Gap.lg, 0, Gap.lg,
          Gap.lg + MediaQuery.of(context).viewInsets.bottom),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text(widget.title, style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: Gap.md),
        for (final f in widget.fields) ...[
          _field(context, f),
          const SizedBox(height: Gap.sm),
        ],
        if (_err != null)
          Padding(
            padding: const EdgeInsets.only(bottom: Gap.sm),
            child: Text(_err!,
                style: TextStyle(color: Theme.of(context).colorScheme.error)),
          ),
        FilledButton(
          key: const ValueKey('life-form-save'),
          style: FilledButton.styleFrom(minimumSize: const Size(48, 48)),
          onPressed: _save,
          child: Text(t.save),
        ),
      ]),
    );
  }
}

// ---------------------------------------------------------- collection view
typedef LifeItemBuilder = Widget Function(BuildContext context,
    Map<String, dynamic> row, VoidCallback onEdit, VoidCallback onDelete);

/// One generic list over a generic collection (`travel/legs`, `wedding/gifts`
/// …): offline copy, pull-to-refresh, add/edit/delete with a confirm, and an
/// empty state with a benefit line + big button + how-to.
class LifeCollectionView extends StatefulWidget {
  final String path;
  final bool Function(Map<String, dynamic> row)? filter;
  final Map<String, dynamic> extra; // stamped on every create (e.g. trip_id)
  final IconData emptyIcon;
  final String emptyTitle, emptyBody, emptyHowTo, addLabel, formTitle, deleteBody;
  final List<LifeField> fields;
  final LifeItemBuilder item;
  final Widget Function(BuildContext, List<Map<String, dynamic>>)? header;
  final List<Map<String, dynamic>> Function(List<Map<String, dynamic>>)? sort;
  const LifeCollectionView({
    super.key,
    required this.path,
    this.filter,
    this.extra = const {},
    required this.emptyIcon,
    required this.emptyTitle,
    required this.emptyBody,
    required this.emptyHowTo,
    required this.addLabel,
    required this.formTitle,
    required this.deleteBody,
    required this.fields,
    required this.item,
    this.header,
    this.sort,
  });
  @override
  State<LifeCollectionView> createState() => _LifeCollectionViewState();
}

class _LifeCollectionViewState extends State<LifeCollectionView> {
  List<Map<String, dynamic>> _rows = [];
  bool _loading = true, _offline = false;
  Object? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final r = await LifeCache.list(context, widget.path);
      var rows = r.rows;
      if (widget.filter != null) rows = rows.where(widget.filter!).toList();
      if (widget.sort != null) rows = widget.sort!(rows);
      _rows = rows;
      _offline = r.offline;
      _error = null;
    } catch (e) {
      _error = e;
    }
    if (mounted) setState(() => _loading = false);
  }

  void _toast(String m) => ScaffoldMessenger.of(context)
    ..clearSnackBars()
    ..showSnackBar(SnackBar(content: Text(m)));

  Future<void> _edit([Map<String, dynamic>? existing]) async {
    final t = AppLocalizations.of(context);
    final body = await showLifeForm(context,
        title: existing == null ? widget.addLabel : widget.formTitle,
        fields: widget.fields,
        existing: existing);
    if (body == null || !mounted) return;
    final api = context.read<AppState>().api;
    try {
      final id = existing?['id'];
      if (id is int) {
        await api.updateItem(widget.path, id, body);
      } else {
        await api.createItem(widget.path, {...body, ...widget.extra});
      }
      await _load();
      if (mounted) _toast(t.p3lSaved);
    } catch (_) {
      if (mounted) _toast(_offline ? t.p3lOfflineNoSave : t.saveFailed);
    }
  }

  Future<void> _delete(Map<String, dynamic> row) async {
    final t = AppLocalizations.of(context);
    final s = Theme.of(context).colorScheme;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        scrollable: true,
        title: Text(t.delete),
        content: Text(widget.deleteBody),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(t.cancel)),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: s.error, foregroundColor: s.onError),
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(t.delete),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    try {
      final id = row['id'];
      if (id is int) await context.read<AppState>().api.deleteItem(widget.path, id);
      await _load();
    } catch (_) {
      if (mounted) _toast(_offline ? t.p3lOfflineNoSave : t.saveFailed);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final s = Theme.of(context).colorScheme;
    if (_loading) return const SkeletonList();
    if (_error != null) {
      return StateMessage(
        icon: Icons.cloud_off_rounded,
        tint: s.error,
        title: t.loadFailed,
        message: honestFailText(t, _error, otherwise: t.p3lLoadFailed),
        action: FilledButton.tonalIcon(
            onPressed: () {
              setState(() => _loading = true);
              _load();
            },
            icon: const Icon(Icons.refresh_rounded),
            label: Text(t.retry)),
      );
    }
    if (_rows.isEmpty) {
      return Column(children: [
        if (_offline) const LifeOfflineBanner(),
        Expanded(
          child: ListView(
            padding: withNavBarInset(context, const EdgeInsets.all(Gap.lg)),
            children: [
              const SizedBox(height: Gap.lg),
              Icon(widget.emptyIcon, size: 56, color: s.primary),
              const SizedBox(height: Gap.md),
              Text(widget.emptyTitle,
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: Gap.sm),
              Text(widget.emptyBody, textAlign: TextAlign.center),
              const SizedBox(height: Gap.lg),
              FilledButton.icon(
                key: const ValueKey('life-empty-add'),
                style: FilledButton.styleFrom(minimumSize: const Size(48, 52)),
                onPressed: () => _edit(),
                icon: const Icon(Icons.add_rounded),
                label: Text(widget.addLabel),
              ),
              const SizedBox(height: Gap.md),
              Text(widget.emptyHowTo,
                  textAlign: TextAlign.center,
                  style: TextStyle(color: s.onSurfaceVariant)),
            ],
          ),
        ),
      ]);
    }
    return Column(children: [
      if (_offline) const LifeOfflineBanner(),
      Expanded(
        child: RefreshIndicator(
          onRefresh: _load,
          child: ListView(
            padding: withNavBarInset(
                context, const EdgeInsets.fromLTRB(Gap.md, Gap.md, Gap.md, Gap.xl)),
            children: [
              if (widget.header != null) widget.header!(context, _rows),
              SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  key: const ValueKey('life-add'),
                  style: OutlinedButton.styleFrom(minimumSize: const Size(48, 48)),
                  onPressed: () => _edit(),
                  icon: const Icon(Icons.add_rounded),
                  label: Text(widget.addLabel),
                ),
              ),
              const SizedBox(height: Gap.sm),
              for (final r in _rows)
                widget.item(context, r, () => _edit(r), () => _delete(r)),
            ],
          ),
        ),
      ),
    ]);
  }
}

/// Edit/delete menu for a row card (48dp, labelled for TalkBack).
class LifeRowMenu extends StatelessWidget {
  final VoidCallback onEdit, onDelete;
  const LifeRowMenu({super.key, required this.onEdit, required this.onDelete});
  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    return PopupMenuButton<String>(
      tooltip: t.p3lMore,
      onSelected: (v) => v == 'e' ? onEdit() : onDelete(),
      itemBuilder: (_) => [
        PopupMenuItem(value: 'e', child: Text(t.edit)),
        PopupMenuItem(value: 'd', child: Text(t.delete)),
      ],
    );
  }
}

// ---------------------------------------------------------------- sharing
/// kind: 'trip' | 'event' | 'guest'. For a guest, [guestPhone]/[guestName]
/// let the sheet send straight to that guest.
Future<void> shareLifeLink(BuildContext context,
    {required String kind,
    required int id,
    required String title,
    String? guestName,
    String? guestPhone}) async {
  final t = AppLocalizations.of(context);
  final api = context.read<AppState>().api;
  String url;
  try {
    final r = await api.postJson('/life/share', {'kind': kind, 'id': id});
    url = '${r['url'] ?? ''}';
    if (url.isEmpty) throw StateError('no url');
  } catch (e) {
    if (context.mounted) {
      ScaffoldMessenger.of(context)
        ..clearSnackBars()
        ..showSnackBar(SnackBar(
            content: Text(honestFailText(t, e, otherwise: t.p3lShareFailed))));
    }
    return;
  }
  if (!context.mounted) return;
  final msg = switch (kind) {
    'trip' => t.p3lShareMsgTrip(title, url),
    'event' => t.p3lShareMsgEvent(title, url),
    _ => t.p3lShareMsgGuest(guestName ?? '', title, url),
  };
  final privacy = switch (kind) {
    'trip' => t.p3lSharePrivacyTrip,
    'event' => t.p3lSharePrivacyEvent,
    _ => t.p3lSharePrivacyGuest,
  };
  await showAppSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (ctx) => _ShareSheet(
        kind: kind, id: id, url: url, msg: msg, privacy: privacy,
        guestName: guestName, guestPhone: guestPhone),
  );
}

class _ShareSheet extends StatelessWidget {
  final String kind, url, msg, privacy;
  final int id;
  final String? guestName, guestPhone;
  const _ShareSheet(
      {required this.kind,
      required this.id,
      required this.url,
      required this.msg,
      required this.privacy,
      this.guestName,
      this.guestPhone});

  Future<void> _sms(BuildContext context, String phone) async {
    final to = phone.replaceAll(RegExp(r'[^0-9+]'), '');
    await openForUser(context, Uri.parse('sms:$to?body=${Uri.encodeComponent(msg)}'),
        where: 'p3life.sms');
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final s = Theme.of(context).colorScheme;
    final gp = (guestPhone ?? '').trim();
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(Gap.lg, 0, Gap.lg, Gap.lg),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text(kind == 'guest' ? t.p3lRsvpSendTitle : t.p3lShareTitle,
            style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: Gap.sm),
        Text(privacy, style: TextStyle(color: s.onSurfaceVariant)),
        const SizedBox(height: Gap.md),
        if (kind == 'guest' && gp.isNotEmpty) ...[
          FilledButton.icon(
            key: const ValueKey('life-share-guest-sms'),
            style: FilledButton.styleFrom(minimumSize: const Size(48, 52)),
            icon: const Icon(Icons.sms_rounded),
            label: Text(t.p3lSmsTo(guestName ?? '')),
            onPressed: () => _sms(context, gp),
          ),
          const SizedBox(height: Gap.sm),
        ],
        if (kind != 'guest')
          FilledButton.icon(
            key: const ValueKey('life-share-circle'),
            style: FilledButton.styleFrom(minimumSize: const Size(48, 52)),
            icon: const Icon(Icons.diversity_1_rounded),
            label: Text(t.p3lShareToCircle),
            onPressed: () async {
              final r = await pickCirclePerson(context, title: t.p3lShareToCircle);
              if (r == null || !context.mounted) return;
              final p = '${r['phone'] ?? ''}'.trim();
              if (p.isEmpty) {
                ScaffoldMessenger.of(context)
                  ..clearSnackBars()
                  ..showSnackBar(SnackBar(content: Text(t.p3lNoPhone)));
                return;
              }
              await _sms(context, p);
            },
          ),
        const SizedBox(height: Gap.sm),
        OutlinedButton.icon(
          key: const ValueKey('life-share-any'),
          style: OutlinedButton.styleFrom(minimumSize: const Size(48, 48)),
          icon: const Icon(Icons.share_rounded),
          label: Text(t.p3lShareOtherApps),
          onPressed: () => Share.share(msg),
        ),
        const SizedBox(height: Gap.sm),
        TextButton.icon(
          key: const ValueKey('life-share-off'),
          style: TextButton.styleFrom(minimumSize: const Size(48, 48), foregroundColor: s.error),
          icon: const Icon(Icons.link_off_rounded),
          label: Text(t.p3lLinkOff),
          onPressed: () async {
            final api = context.read<AppState>().api;
            String m;
            try {
              await api.postJson('/life/share/revoke', {'kind': kind, 'id': id});
              m = t.p3lLinkOffDone;
            } catch (e) {
              m = honestFailText(t, e, otherwise: t.saveFailed);
            }
            if (!context.mounted) return;
            Navigator.pop(context);
            ScaffoldMessenger.of(context)
              ..clearSnackBars()
              ..showSnackBar(SnackBar(content: Text(m)));
          },
        ),
      ]),
    );
  }
}

/// Opens an official source in the browser / its app.
Future<void> openOfficial(BuildContext context, OfficialSource src) =>
    openForUser(context, Uri.parse(src.url),
        where: 'p3life.official.${src.id}', mode: LaunchMode.externalApplication);
