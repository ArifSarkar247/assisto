import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../api.dart';
import '../../blood_panel_api.dart';
import '../../l10n/app_localizations.dart';
import '../../state.dart';
import '../../theme.dart';
import '../../ds/ds.dart';
import '../../widgets/app_sheet.dart';
import '../../widgets/money_circle_pick.dart' show CirclePickButton;
import 'bp_common.dart';
import '../../widgets/local_counter.dart';
import 'package:assisto/ads/ad_block_context.dart' show AdBlockedState;

/// ownerfix (owner 3 Nov 02:55): "My saved donors" inside the ONE Blood donor
/// panel. It replaces the old personal registry screen (removed): every donor
/// of the old list was copied here by the server (migration 0140_ownerfix +
/// a lazy re-sync), nothing is lost.
///
/// PRIVATE: only this user sees the list; nobody on it is notified. Same
/// owner rules as the panel list: never hide a donor — available first,
/// waiting by exact days left, paused shown — header counts and the
/// "doctor decides" line. NO ads (blood donor is on the ad never-list).
class BloodSavedScreen extends StatefulWidget {
  const BloodSavedScreen({super.key});

  @override
  State<BloodSavedScreen> createState() => _BloodSavedScreenState();
}

class _BloodSavedScreenState extends State<BloodSavedScreen>
    with AdBlockedState<BloodSavedScreen> {
  ApiClient get _api => context.read<AppState>().api;
  bool _loading = true;
  bool _failed = false;
  List<Map<String, dynamic>> _rows = const [];
  Map<String, dynamic> _counts = const {};

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _failed = false;
    });
    try {
      final r = await _api.bpSaved();
      if (!mounted) return;
      setState(() {
        _rows = bpRows(r, 'donors');
        _counts = bpMap(r['counts']);
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _failed = true;
      });
    }
  }

  void _snack(String m) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));

  Future<void> _edit([Map<String, dynamic>? row]) async {
    final body = await showAppSheet<Map<String, dynamic>>(
      context: context,
      isScrollControlled: true,
      builder: (_) => _SavedForm(initial: row),
    );
    if (body == null || !mounted) return;
    final t = AppLocalizations.of(context);
    try {
      final id = row?['id'];
      final r = id is int ? await _api.bpSavedUpdate(id, body) : await _api.bpSavedCreate(body);
      if (!mounted) return;
      if (r['ok'] == true) {
        unawaited(_load());
      } else {
        _snack(bpReason(t, r['reason'] as String?));
      }
    } catch (_) {
      if (mounted) _snack(t.bpErrGeneric);
    }
  }

  Future<void> _delete(Map<String, dynamic> row) async {
    final t = AppLocalizations.of(context);
    final ok = await showAppSheet<bool>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(Gap.lg),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Text(t.bsvDeleteAsk('${row['name'] ?? ''}'),
                style: Theme.of(ctx).textTheme.titleMedium?.copyWith(
                    color: DsTokens.of(ctx).text, fontWeight: FontWeight.w700)),
            const SizedBox(height: Gap.lg),
            DsButton.danger(
              key: const ValueKey('bsv-delete-yes'),
              expand: true,
              icon: Icons.delete_outline_rounded,
              onPressed: () => Navigator.of(ctx).pop(true),
              label: t.delete,
            ),
            const SizedBox(height: Gap.sm),
            DsButton.secondary(
              expand: true,
              onPressed: () => Navigator.of(ctx).pop(false),
              label: t.cancel,
            ),
          ]),
        ),
      ),
    );
    if (ok != true || !mounted) return;
    try {
      await _api.bpSavedDelete(row['id'] as int);
      if (mounted) unawaited(_load());
    } catch (_) {
      if (mounted) _snack(t.bpErrGeneric);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final text = Theme.of(context).textTheme;
    return Scaffold(
      appBar: AppBar(title: Text(t.bsvTitle)),
      floatingActionButton: _loading || _failed || _rows.isEmpty
          ? null
          : FloatingActionButton.extended(
              key: const ValueKey('bsv-add'),
              onPressed: () => _edit(),
              icon: const Icon(Icons.person_add_alt_1_rounded),
              label: Text(t.bsvAdd),
            ),
      body: _loading
          ? ListView(
              padding: const EdgeInsets.all(Gap.lg),
              children: [for (var i = 0; i < 3; i++) Padding(
                  padding: const EdgeInsets.only(bottom: Gap.sm), child: DsSkeleton.card(lines: 3))])
          : _failed
              ? Center(child: BpError(onRetry: _load))
              : RefreshIndicator(
                  onRefresh: _load,
                  child: ListView(
                    padding: withNavBarInset(
                        context, const EdgeInsets.fromLTRB(Gap.lg, Gap.md, Gap.lg, 96)),
                    children: [
                      Row(key: const ValueKey('bsv-private'), crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Icon(Icons.lock_rounded, size: 18, color: DsTokens.of(context).muted),
                        const SizedBox(width: Gap.sm),
                        Expanded(child: Text(t.bsvPrivate,
                            style: text.bodyMedium?.copyWith(color: DsTokens.of(context).muted))),
                      ]),
                      const SizedBox(height: Gap.md),
                      if (_rows.isEmpty)
                        BpEmpty(
                          icon: Icons.contacts_rounded,
                          title: t.bsvEmptyTitle,
                          steps: [t.bsvStep1, t.bsvStep2, t.bsvStep3],
                          cta: t.bsvAdd,
                          ctaKey: const ValueKey('bsv-empty-add'),
                          onCta: () => _edit(),
                        )
                      else ...[
                        Semantics(
                          key: const ValueKey('bsv-counts'),
                          liveRegion: true,
                          child: Text(
                              bpD(context, t.bpListCounts(
                                  (_counts['total'] as num?)?.toInt() ?? _rows.length,
                                  (_counts['available'] as num?)?.toInt() ?? 0,
                                  (_counts['soon'] as num?)?.toInt() ?? 0)),
                              style: text.titleSmall?.copyWith(
                                  color: DsTokens.of(context).text, fontWeight: FontWeight.w700)),
                        ),
                        const SizedBox(height: Gap.sm),
                        for (final d in _rows) _card(context, d),
                        Text(t.bpDoctorDecides,
                            key: const ValueKey('bsv-doctor-decides'),
                            style: text.bodySmall?.copyWith(
                                fontStyle: FontStyle.italic, color: DsTokens.of(context).muted)),
                      ],
                    ],
                  ),
                ),
    );
  }

  Widget _card(BuildContext context, Map<String, dynamic> d) {
    final t = AppLocalizations.of(context);
    final ds = DsTokens.of(context);
    final text = Theme.of(context).textTheme;
    final phone = '${d['phone'] ?? ''}';
    final area = '${d['area_text'] ?? ''}';
    final group = '${d['blood_group'] ?? ''}';
    // designv2: who + status on top, one row of round actions (call first)
    return Padding(
      key: ValueKey('bsv-donor-${d['id']}'),
      padding: const EdgeInsets.only(bottom: Gap.md),
      child: DsCard(
        padding: const EdgeInsets.all(Gap.md),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            BpGroupBadge(group.isEmpty ? '?' : group),
            const SizedBox(width: Gap.md),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('${d['name'] ?? ''}',
                    style: text.titleMedium?.copyWith(color: ds.text, fontWeight: FontWeight.w700)),
                if (area.isNotEmpty) Text(area, style: text.bodyMedium?.copyWith(color: ds.muted)),
                if (d['from_old_list'] == true)
                  Text(t.bsvFromOld, style: text.bodySmall?.copyWith(color: ds.muted)),
                const SizedBox(height: Gap.xs),
                BpDonorStatus(donor: d),
              ]),
            ),
          ]),
          const SizedBox(height: Gap.sm),
          Row(children: [
            if (phone.isNotEmpty) ...[
              DsIconAction(
                key: ValueKey('bsv-call-${d['id']}'),
                tooltip: t.bpCall,
                color: ds.successInk,
                onPressed: () => bpLaunch(context, 'tel', phone),
                icon: Icons.call_rounded,
              ),
              const SizedBox(width: Gap.sm),
              DsIconAction(
                key: ValueKey('bsv-sms-${d['id']}'),
                tooltip: t.bpSms,
                onPressed: () => bpLaunch(context, 'sms', phone),
                icon: Icons.sms_outlined,
              ),
            ],
            const Spacer(),
            DsIconAction(
              key: ValueKey('bsv-edit-${d['id']}'),
              tooltip: t.edit,
              color: ds.muted,
              onPressed: () => _edit(d),
              icon: Icons.edit_outlined,
            ),
            const SizedBox(width: Gap.sm),
            DsIconAction(
              key: ValueKey('bsv-del-${d['id']}'),
              tooltip: t.delete,
              color: ds.dangerInk,
              onPressed: () => _delete(d),
              icon: Icons.delete_outline_rounded,
            ),
          ]),
        ]),
      ),
    );
  }
}

/// Add / edit sheet. Returns the request body (or null on cancel).
class _SavedForm extends StatefulWidget {
  const _SavedForm({this.initial});
  final Map<String, dynamic>? initial;

  @override
  State<_SavedForm> createState() => _SavedFormState();
}

class _SavedFormState extends State<_SavedForm> {
  late final _name = TextEditingController(text: '${widget.initial?['name'] ?? ''}');
  late final _phone = TextEditingController(text: '${widget.initial?['phone'] ?? ''}');
  late final _area = TextEditingController(text: '${widget.initial?['area_text'] ?? ''}');
  late String _group = '${widget.initial?['blood_group'] ?? ''}';
  late String? _last = widget.initial?['last_donation'] as String?;
  late bool _paused = widget.initial != null && widget.initial!['available'] == false;
  String? _err;

  @override
  void dispose() {
    _name.dispose();
    _phone.dispose();
    _area.dispose();
    super.dispose();
  }

  Future<void> _pickDate() async {
    final now = DateTime.now();
    final d = await showDatePicker(
      context: context,
      initialDate: DateTime.tryParse(_last ?? '') ?? now,
      firstDate: DateTime(now.year - 10),
      lastDate: now,
    );
    if (d != null) {
      setState(() => _last =
          '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}');
    }
  }

  void _save() {
    final t = AppLocalizations.of(context);
    if (_name.text.trim().isEmpty) {
      setState(() => _err = t.bsvErrName);
      return;
    }
    if (_group.isEmpty) {
      setState(() => _err = t.bsvErrGroup);
      return;
    }
    Navigator.of(context).pop(<String, dynamic>{
      'name': _name.text.trim(),
      'blood_group': _group,
      'area_text': _area.text.trim(),
      'phone': _phone.text.trim(),
      'last_donation': _last ?? '',
      'available': !_paused,
    });
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final text = Theme.of(context).textTheme;
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(Gap.lg),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Text(widget.initial == null ? t.bsvAdd : t.bsvEditTitle,
                style: text.titleLarge?.copyWith(color: DsTokens.of(context).text, fontWeight: FontWeight.w700)),
            const SizedBox(height: Gap.md),
            CirclePickButton(name: _name, phone: _phone, onPicked: () => setState(() {})),
            const SizedBox(height: Gap.md),
            TextField(
              key: const ValueKey('bsv-name'),
              controller: _name,
              maxLength: 80,
              buildCounter: localCounter,
              decoration: InputDecoration(labelText: t.bsvName),
            ),
            Text(t.bsvGroup, style: text.titleSmall),
            const SizedBox(height: Gap.xs),
            BpGroupGrid(
              keyPrefix: 'bsv-g-',
              selected: _group,
              onTap: (g) => setState(() => _group = _group == g ? '' : g),
            ),
            const SizedBox(height: Gap.md),
            TextField(
              key: const ValueKey('bsv-phone'),
              controller: _phone,
              keyboardType: TextInputType.phone,
              maxLength: 20,
              buildCounter: localCounter,
              decoration: InputDecoration(labelText: t.bsvPhone),
            ),
            TextField(
              key: const ValueKey('bsv-area'),
              controller: _area,
              maxLength: 60,
              buildCounter: localCounter,
              decoration: InputDecoration(labelText: t.bsvArea),
            ),
            Text(t.bsvLast, style: text.titleSmall),
            const SizedBox(height: Gap.xs),
            Wrap(spacing: Gap.sm, runSpacing: Gap.sm, children: [
              ConstrainedBox(
                constraints: const BoxConstraints(minHeight: 48),
                child: OutlinedButton.icon(
                  key: const ValueKey('bsv-last'),
                  onPressed: _pickDate,
                  icon: const Icon(Icons.event_rounded),
                  label: Text(_last == null || _last!.isEmpty ? t.bsvLastNone : bpDate(context, _last)),
                ),
              ),
              if (_last != null && _last!.isNotEmpty)
                TextButton(
                  key: const ValueKey('bsv-last-clear'),
                  style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
                  onPressed: () => setState(() => _last = null),
                  child: Text(t.bsvLastNone),
                ),
            ]),
            SwitchListTile(
              key: const ValueKey('bsv-paused'),
              contentPadding: EdgeInsets.zero,
              title: Text(t.bsvPaused),
              value: _paused,
              onChanged: (v) => setState(() => _paused = v),
            ),
            if (_err != null)
              Padding(
                padding: const EdgeInsets.only(bottom: Gap.sm),
                child: Text(_err!, key: const ValueKey('bsv-err'),
                    style: text.bodyMedium?.copyWith(color: DsTokens.of(context).dangerInk)),
              ),
            DsButton(
              key: const ValueKey('bsv-save'),
              expand: true,
              onPressed: _save,
              label: t.save,
            ),
          ]),
        ),
      ),
    );
  }
}
