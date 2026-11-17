import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../api.dart';
import '../../ds/ds.dart';
import '../../kids_watch_api.dart';
import '../../l10n/app_localizations.dart';
import '../../state.dart';
import '../../theme.dart';
import '../../widgets/num_input.dart' show LatinDigitsFormatter;

/// gap-kidswatch (17 Nov) — "Watch settings" for a paired / pending watch
/// (owner only): who the SOS button calls (at least one number — a watch
/// whose SOS calls nobody is a broken safety device), the watch's own SIM
/// number (so the family can CALL it in one tap: a normal, visible call) and
/// the child's own Assisto account (then the watch SOS reaches the child's
/// whole family). Nothing here can make the watch listen.
class KwWatchSettingsSheet extends StatefulWidget {
  const KwWatchSettingsSheet({super.key, required this.watch});
  final Map<String, dynamic> watch;

  @override
  State<KwWatchSettingsSheet> createState() => _KwWatchSettingsSheetState();
}

class _KwWatchSettingsSheetState extends State<KwWatchSettingsSheet> {
  late final TextEditingController _sos;
  late final TextEditingController _sim;
  List<Map<String, dynamic>> _people = const [];
  int? _child;
  bool _busy = false;
  String _error = '';

  @override
  void initState() {
    super.initState();
    final w = widget.watch;
    final nums = ((w['sos_numbers'] as List?) ?? const []).map((e) => '$e').toList();
    _sos = TextEditingController(
        text: nums.isNotEmpty ? nums.join(', ') : (context.read<AppState>().user?.phone ?? ''));
    _sim = TextEditingController(text: '${w['sim_phone'] ?? ''}');
    _child = (w['child_user_id'] as num?)?.toInt();
    _loadPeople();
  }

  Future<void> _loadPeople() async {
    try {
      final r = await context.read<AppState>().api.smPeople();
      if (mounted) setState(() => _people = kwRows(r, 'people'));
    } catch (_) {
      // best-effort: without the list the child link just is not offered
    }
  }

  @override
  void dispose() {
    _sos.dispose();
    _sim.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final t = AppLocalizations.of(context);
    final sos = kwSplitNumbers(_sos.text);
    final sim = kwLatinDigits(_sim.text);
    if (sos.isEmpty) {
      setState(() => _error = t.kwgSosNeedOne);
      return;
    }
    if (sos.any((n) => !kwPhoneOk(n)) || (sim.isNotEmpty && !kwPhoneOk(sim))) {
      setState(() => _error = t.kwgBadPhone);
      return;
    }
    setState(() {
      _busy = true;
      _error = '';
    });
    try {
      await context.read<AppState>().api.kwUpdate(widget.watch['id'] as int, {
        'sos_numbers': sos,
        'sim_phone': sim,
        if (_people.isNotEmpty || _child == null) 'child_user_id': _child,
      });
      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      if (mounted) {
        setState(() => _error =
            e is ApiException && e.message.isNotEmpty ? e.message : t.kwActionFailed);
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final known = _people.any((p) => p['id'] == _child);
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(Gap.lg, 0, Gap.lg, Gap.lg),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text(t.kwgSettings, style: AType.titleLarge),
        const SizedBox(height: Gap.xs),
        Text('${widget.watch['child_name'] ?? ''}', style: AType.bodyMedium),
        const SizedBox(height: Gap.md),
        TextField(
          key: const ValueKey('kwg-set-sos'),
          controller: _sos,
          keyboardType: TextInputType.phone,
          inputFormatters: const [LatinDigitsFormatter()],
          decoration: InputDecoration(
              labelText: t.kwSosNumbers,
              helperText: t.kwgSosHelpDefault,
              helperMaxLines: 4,
              border: const OutlineInputBorder()),
        ),
        const SizedBox(height: Gap.md),
        TextField(
          key: const ValueKey('kwg-set-sim'),
          controller: _sim,
          keyboardType: TextInputType.phone,
          inputFormatters: const [LatinDigitsFormatter()],
          decoration: InputDecoration(
              labelText: t.kwgSimLabel,
              helperText: t.kwgSimHelp,
              helperMaxLines: 3,
              border: const OutlineInputBorder()),
        ),
        if (_people.isNotEmpty) ...[
          const SizedBox(height: Gap.md),
          DropdownButtonFormField<int?>(
            key: const ValueKey('kwg-set-child'),
            initialValue: known ? _child : null,
            isExpanded: true,
            decoration: InputDecoration(
                labelText: t.kwgChildAccount,
                helperText: t.kwgChildAccountHelp,
                helperMaxLines: 3,
                border: const OutlineInputBorder()),
            items: [
              DropdownMenuItem<int?>(value: null, child: Text(t.kwgChildNone)),
              for (final p in _people)
                DropdownMenuItem<int?>(
                    value: (p['id'] as num).toInt(),
                    child: Text('${p['name']}', overflow: TextOverflow.ellipsis)),
            ],
            onChanged: (v) => setState(() => _child = v),
          ),
        ],
        const SizedBox(height: Gap.sm),
        Text(t.kwgNoListen,
            style: AType.bodySmall.copyWith(color: DsTokens.of(context).muted)),
        if (_error.isNotEmpty) ...[
          const SizedBox(height: Gap.sm),
          Text(_error,
              key: const ValueKey('kwg-set-error'),
              style: AType.bodyMedium.copyWith(color: DsTokens.of(context).dangerInk)),
        ],
        const SizedBox(height: Gap.lg),
        FilledButton(
          key: const ValueKey('kwg-set-save'),
          style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
          onPressed: _busy ? null : _save,
          child: Text(t.kwSave),
        ),
      ]),
    );
  }
}
