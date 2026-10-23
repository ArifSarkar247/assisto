import 'package:flutter/material.dart';

import '../api.dart';
import '../l10n/app_localizations.dart';
import '../theme.dart';
import 'call_avatar.dart';

/// b3-group "Add people": pick accepted My Circle contacts (GET
/// /circle/members) to bring into the call. Returns the CircleMember ids,
/// or null when cancelled. [exclude] = member ids already in the call.
Future<List<int>?> pickCirclePeople(
  BuildContext context, {
  required ApiClient api,
  Set<int> exclude = const {},
  int max = 7,
  Future<List<Map<String, dynamic>>> Function()? load,
}) {
  return showModalBottomSheet<List<int>>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    showDragHandle: true,
    builder: (_) => _PickSheet(
      load: load ??
          () async {
            final r = await api.getJson('/circle/members');
            return [
              for (final m in (r['results'] ?? r['members'] ?? const []) as List)
                if (m is Map) m.cast<String, dynamic>()
            ];
          },
      exclude: exclude,
      max: max,
    ),
  );
}

class _PickSheet extends StatefulWidget {
  const _PickSheet(
      {required this.load, required this.exclude, required this.max});
  final Future<List<Map<String, dynamic>>> Function() load;
  final Set<int> exclude;
  final int max;

  @override
  State<_PickSheet> createState() => _PickSheetState();
}

class _PickSheetState extends State<_PickSheet> {
  List<Map<String, dynamic>>? _rows;
  bool _failed = false;
  final Set<int> _picked = {};

  @override
  void initState() {
    super.initState();
    _fetch();
  }

  Future<void> _fetch() async {
    try {
      final all = await widget.load();
      final rows = [
        for (final m in all)
          if (m['id'] is num &&
              !widget.exclude.contains((m['id'] as num).toInt()) &&
              m['blocked'] != true)
            m
      ];
      if (mounted) setState(() => _rows = rows);
    } catch (_) {
      if (mounted) setState(() => _failed = true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final rows = _rows;
    Widget body;
    if (_failed) {
      body = Padding(
        padding: const EdgeInsets.all(Gap.xl),
        child: Text(t.b3PickLoadFailed, textAlign: TextAlign.center),
      );
    } else if (rows == null) {
      body = const Padding(
          padding: EdgeInsets.all(Gap.xl),
          child: Center(child: CircularProgressIndicator()));
    } else if (rows.isEmpty) {
      body = Padding(
        padding: const EdgeInsets.all(Gap.xl),
        child: Text(t.b3PickNone, textAlign: TextAlign.center),
      );
    } else {
      body = Flexible(
        child: ListView.builder(
          shrinkWrap: true,
          itemCount: rows.length,
          itemBuilder: (_, i) {
            final m = rows[i];
            final id = (m['id'] as num).toInt();
            final on = _picked.contains(id);
            final full = !on && _picked.length >= widget.max;
            return CheckboxListTile(
              key: Key('pick-$id'),
              value: on,
              onChanged: full
                  ? null
                  : (v) => setState(() =>
                      v == true ? _picked.add(id) : _picked.remove(id)),
              secondary: CallAvatar(
                  name: '${m['name'] ?? ''}',
                  photoUrl: '${m['photo_url'] ?? m['photo'] ?? ''}',
                  radius: 20,
                  onDark: false),
              title: Text('${m['name'] ?? ''}',
                  maxLines: 1, overflow: TextOverflow.ellipsis),
            );
          },
        ),
      );
    }
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(Gap.lg, 0, Gap.lg, Gap.xs),
          child: Text(t.b3PickTitle,
              style: Theme.of(context).textTheme.titleLarge),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(Gap.lg, 0, Gap.lg, Gap.sm),
          child: Text(t.b3PickHint(widget.max),
              style: TextStyle(color: scheme.onSurfaceVariant)),
        ),
        body,
        Padding(
          padding: const EdgeInsets.fromLTRB(Gap.lg, Gap.sm, Gap.lg, Gap.lg),
          child: FilledButton(
            key: const Key('pick-add'),
            onPressed: _picked.isEmpty
                ? null
                : () => Navigator.pop(context, _picked.toList()),
            child: Text(t.b3PickAdd(_picked.length)),
          ),
        ),
      ],
    );
  }
}
