import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../api.dart';
import '../ds/ds.dart';
import '../l10n/app_localizations.dart';
import '../maps/place_search.dart' show showPlaceSearchSheet;
import '../offline/offline_store.dart';
import '../services/action_feedback.dart';
import '../services/error_report.dart' show reportNonFatal;
import '../state.dart';
import '../theme.dart';
import '../widgets/app_sheet.dart';
import '../widgets/journey_ride.dart' show jDigits;
import '../widgets/local_counter.dart';
import 'package:assisto/safety/ad_block_context.dart' show AdBlockedState;

/// safety-plan (board row 49) — the FAMILY SAFETY PLAN: where we meet, who to
/// call first, the emergency numbers. Written once, shared with chosen My
/// Circle members, and kept on this phone (encrypted OfflineStore) so it
/// opens with NO internet — exactly when it is needed. A safety screen: no
/// ads (AdBlockedState), never paywalled, never flag-gated.
///
/// Server: GET/POST/DELETE /safety-plan (core/safety_plan.py).

/// Tests / gallery: replace the network ({mine, shared, members, defaults}).
Future<Map<String, dynamic>> Function()? safetyPlanLoaderOverride;
Future<Map<String, dynamic>> Function(Map<String, dynamic> body)? safetyPlanSaveOverride;

const kSafetyPlanSlot = 'safety_plan';

List<Map<String, dynamic>> splRows(Object? v) => [
      for (final x in (v is List ? v : const []))
        if (x is Map) x.cast<String, dynamic>()
    ];

/// Body for POST /safety-plan from an overview's `mine` (pure; tests).
Map<String, dynamic> splBodyFrom(Map<String, dynamic>? mine) => {
      'meeting_point': mine?['meeting_point'],
      'meeting_point_far': mine?['meeting_point_far'],
      'numbers': [
        for (final n in splRows(mine?['numbers'])) {'number': n['number'], 'label': n['label']}
      ],
      'call_order': [for (final c in splRows(mine?['call_order'])) c['member_id']],
      'shared_with': [for (final s in splRows(mine?['shared_with'])) s['member_id']],
      'note': mine?['note'] ?? '',
    };

/// True when a plan holds anything useful (pure).
bool splHasContent(Map<String, dynamic> body) =>
    body['meeting_point'] != null ||
    body['meeting_point_far'] != null ||
    (body['numbers'] as List? ?? const []).isNotEmpty ||
    (body['call_order'] as List? ?? const []).isNotEmpty;

class SafetyPlanScreen extends StatefulWidget {
  const SafetyPlanScreen({super.key});
  @override
  State<SafetyPlanScreen> createState() => _SafetyPlanScreenState();
}

class _SafetyPlanScreenState extends State<SafetyPlanScreen>
    with AdBlockedState<SafetyPlanScreen> {
  Map<String, dynamic>? _data;
  bool _loading = true;
  bool _offline = false; // showing the copy saved on this phone
  DateTime? _savedAt;

  ApiClient get _api => context.read<AppState>().api;
  Object? get _uid => OfflineStore.instance.currentUid;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final r = safetyPlanLoaderOverride != null
          ? await safetyPlanLoaderOverride!()
          : await _api.getJson('/safety-plan');
      _data = r;
      _offline = false;
      await OfflineStore.instance.write(
          _uid, kSafetyPlanSlot, {'at': DateTime.now().toIso8601String(), 'data': r});
    } catch (_) {
      // no internet: the last copy on this phone (that is the point of a plan)
      final c = await OfflineStore.instance.read(_uid, kSafetyPlanSlot);
      if (c is Map && c['data'] is Map) {
        _data = (c['data'] as Map).cast<String, dynamic>();
        _savedAt = DateTime.tryParse('${c['at'] ?? ''}')?.toLocal();
      }
      _offline = true;
    }
    if (mounted) setState(() => _loading = false);
  }

  Map<String, dynamic>? get _mine =>
      (_data?['mine'] is Map) ? (_data!['mine'] as Map).cast<String, dynamic>() : null;

  Future<void> _edit() async {
    final t = AppLocalizations.of(context);
    if (_offline) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(t.splOfflineEdit)));
      return;
    }
    final saved = await Navigator.of(context).push<Map<String, dynamic>>(MaterialPageRoute(
        builder: (_) => SafetyPlanEditScreen(
            initial: splBodyFrom(_mine),
            members: splRows(_data?['members']),
            defaults: splRows(_data?['defaults']))));
    if (saved != null && mounted) {
      _data = saved;
      await OfflineStore.instance.write(
          _uid, kSafetyPlanSlot, {'at': DateTime.now().toIso8601String(), 'data': saved});
      if (!mounted) return;
      setState(() {});
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(t.splSaved)));
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final shared = splRows(_data?['shared']);
    return Scaffold(
      appBar: AppBar(title: Text(t.splTitle)),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: _load,
              child: ListView(
                padding: withNavBarInset(context, const EdgeInsets.all(Gap.lg)),
                children: [
                  if (_offline) _offlineBanner(t),
                  if (_data == null)
                    _noCopy(t)
                  else ...[
                    if (_mine == null) _empty(t) else SafetyPlanCard(
                        key: const ValueKey('spl_mine'),
                        title: t.splMine,
                        plan: _mine!,
                        onEdit: _edit),
                    for (final s in shared) ...[
                      const SizedBox(height: Gap.lg),
                      SafetyPlanCard(
                          key: ValueKey('spl_shared_${s['owner_id']}'),
                          title: t.splFrom('${s['owner_name'] ?? ''}'),
                          plan: (s['plan'] as Map? ?? const {}).cast<String, dynamic>()),
                    ],
                  ],
                ],
              ),
            ),
    );
  }

  Widget _offlineBanner(AppLocalizations t) {
    final ds = DsTokens.of(context);
    final at = _savedAt;
    return Padding(
      padding: const EdgeInsets.only(bottom: Gap.md),
      child: Semantics(
        liveRegion: true,
        child: Container(
          key: const ValueKey('spl_offline'),
          padding: const EdgeInsets.all(Gap.md),
          decoration: BoxDecoration(
              color: Brand.warnInk(context).withValues(alpha: 0.10),
              borderRadius: BorderRadius.circular(Radii.md)),
          child: Row(children: [
            Icon(Icons.cloud_off_rounded, color: Brand.warnInk(context)),
            const SizedBox(width: Gap.sm),
            Expanded(
                child: Text(
                    at == null
                        ? t.splOfflineNoTime
                        : t.splOffline(jDigits(context, TimeOfDay.fromDateTime(at).format(context))),
                    style: AType.bodyMedium.copyWith(color: ds.text))),
          ]),
        ),
      ),
    );
  }

  Widget _noCopy(AppLocalizations t) => Column(
        key: const ValueKey('spl_nocopy'),
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(t.splNoCopy, style: AType.bodyLarge),
          const SizedBox(height: Gap.md),
          DsButton(
              key: const ValueKey('spl_retry'),
              expand: true,
              icon: Icons.refresh_rounded,
              label: t.retry,
              onPressed: _load),
        ],
      );

  Widget _empty(AppLocalizations t) {
    final ds = DsTokens.of(context);
    return DsCard(
      key: const ValueKey('spl_empty'),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Icon(Icons.family_restroom_rounded, size: 40, color: ds.primaryInk),
        const SizedBox(height: Gap.sm),
        Text(t.splEmptyTitle,
            style: AType.titleMedium.copyWith(fontWeight: FontWeight.w700, color: ds.text)),
        const SizedBox(height: Gap.xs),
        Text(t.splEmptyBody, style: AType.bodyMedium.copyWith(color: ds.muted)),
        const SizedBox(height: Gap.md),
        for (final s in [t.splHow1, t.splHow2, t.splHow3])
          Padding(
              padding: const EdgeInsets.only(bottom: Gap.xs),
              child: Text(s, style: AType.bodyMedium.copyWith(color: ds.text))),
        const SizedBox(height: Gap.md),
        DsButton(
            key: const ValueKey('spl_make'),
            expand: true,
            icon: Icons.edit_note_rounded,
            label: t.splMake,
            onPressed: _edit),
      ]),
    );
  }
}

/// One plan, read view (mine with Edit, or one shared with me).
class SafetyPlanCard extends StatelessWidget {
  const SafetyPlanCard({super.key, required this.title, required this.plan, this.onEdit});
  final String title;
  final Map<String, dynamic> plan;
  final VoidCallback? onEdit;

  Future<void> _call(BuildContext c, String n) =>
      openForUser(c, Uri.parse('tel:$n'), where: 'safetyPlan.call');

  Future<void> _map(BuildContext c, Map p) => openForUser(
      c,
      Uri.parse(p['lat'] != null
          ? 'https://www.google.com/maps/search/?api=1&query=${p['lat']},${p['lng']}'
          : 'https://www.google.com/maps/search/?api=1&query=${Uri.encodeComponent('${p['name']}')}'),
      where: 'safetyPlan.map',
      mode: LaunchMode.externalApplication);

  Widget _h(BuildContext c, String s) => Padding(
        padding: const EdgeInsets.only(top: Gap.md, bottom: Gap.xs),
        child: Semantics(
            header: true,
            child: Text(s,
                style: AType.bodyLarge.copyWith(
                    fontWeight: FontWeight.w700, color: DsTokens.of(c).text))),
      );

  Widget _place(BuildContext c, AppLocalizations t, String key, String head, Object? raw) {
    if (raw is! Map) return const SizedBox.shrink();
    final ds = DsTokens.of(c);
    final note = '${raw['note'] ?? ''}'.trim();
    return Column(key: ValueKey(key), crossAxisAlignment: CrossAxisAlignment.start, children: [
      _h(c, head),
      Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Icon(Icons.place_rounded, color: ds.primaryInk),
        const SizedBox(width: Gap.sm),
        Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(jDigits(c, '${raw['name']}'), style: AType.bodyLarge.copyWith(color: ds.text)),
          if (note.isNotEmpty)
            Text(jDigits(c, note), style: AType.bodyMedium.copyWith(color: ds.muted)),
        ])),
      ]),
      Align(
        alignment: AlignmentDirectional.centerStart,
        child: TextButton.icon(
            key: ValueKey('${key}_map'),
            style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
            icon: const Icon(Icons.map_rounded),
            label: Text(t.splOpenMap),
            onPressed: () => _map(c, raw)),
      ),
    ]);
  }

  Widget _callRow(BuildContext c, AppLocalizations t, String key, String title, String? sub,
      String phone) {
    final ds = DsTokens.of(c);
    return Padding(
      key: ValueKey(key),
      padding: const EdgeInsets.only(bottom: Gap.xs),
      child: Row(children: [
        Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(title, style: AType.bodyLarge.copyWith(color: ds.text)),
          if (sub != null && sub.isNotEmpty)
            Text(sub, style: AType.bodySmall.copyWith(color: ds.muted)),
        ])),
        if (phone.isNotEmpty)
          FilledButton.icon(
              key: ValueKey('${key}_call'),
              style: FilledButton.styleFrom(minimumSize: const Size(48, 48)),
              icon: const Icon(Icons.call_rounded),
              label: Text(t.call),
              onPressed: () => _call(c, phone)),
      ]),
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final ds = DsTokens.of(context);
    final calls = splRows(plan['call_order']);
    final nums = splRows(plan['numbers']);
    final shared = plan['shared_with'] is List ? splRows(plan['shared_with']) : null;
    final at = DateTime.tryParse('${plan['updated_at'] ?? ''}')?.toLocal();
    final note = '${plan['note'] ?? ''}'.trim();
    return DsCard(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Expanded(
              child: Semantics(
                  header: true,
                  child: Text(title,
                      style: AType.titleMedium
                          .copyWith(fontWeight: FontWeight.w700, color: ds.text)))),
          if (onEdit != null)
            TextButton.icon(
                key: const ValueKey('spl_edit'),
                style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
                icon: const Icon(Icons.edit_rounded),
                label: Text(t.splEdit),
                onPressed: onEdit),
        ]),
        if (at != null)
          Text(t.splUpdated(jDigits(context, MaterialLocalizations.of(context).formatShortDate(at))),
              style: AType.bodySmall.copyWith(color: ds.muted)),
        _place(context, t, 'spl_meet', t.splMeet, plan['meeting_point']),
        _place(context, t, 'spl_meet_far', t.splMeetFar, plan['meeting_point_far']),
        if (calls.isNotEmpty) ...[
          _h(context, t.splCallOrder),
          for (var i = 0; i < calls.length; i++)
            _callRow(
                context,
                t,
                'spl_call_$i',
                '${jDigits(context, i + 1)}. ${calls[i]['name']}${calls[i]['is_you'] == true ? ' (${t.splYou})' : ''}',
                jDigits(context, '${calls[i]['phone'] ?? ''}'),
                calls[i]['is_you'] == true ? '' : '${calls[i]['phone'] ?? ''}'),
        ],
        if (nums.isNotEmpty) ...[
          _h(context, t.splNumbers),
          for (var i = 0; i < nums.length; i++)
            _callRow(context, t, 'spl_num_$i', jDigits(context, '${nums[i]['number']}'),
                '${nums[i]['label'] ?? ''}', '${nums[i]['number']}'),
        ],
        if (note.isNotEmpty) ...[
          const SizedBox(height: Gap.sm),
          Text(jDigits(context, note), style: AType.bodyMedium.copyWith(color: ds.text)),
        ],
        if (shared != null) ...[
          const SizedBox(height: Gap.md),
          Text(
              shared.isEmpty
                  ? t.splNotShared
                  : t.splSharedWith(shared.map((s) => '${s['name']}').join(', ')),
              key: const ValueKey('spl_shared_line'),
              style: AType.bodyMedium.copyWith(color: ds.muted)),
        ],
      ]),
    );
  }
}

/// Edit: meeting places (the shared place search), who to call first and who
/// sees it (one tap from My Circle), the emergency numbers (BD national
/// numbers one tap, or add one). Returns the server's new overview.
class SafetyPlanEditScreen extends StatefulWidget {
  const SafetyPlanEditScreen(
      {super.key, required this.initial, required this.members, required this.defaults});
  final Map<String, dynamic> initial;
  final List<Map<String, dynamic>> members;
  final List<Map<String, dynamic>> defaults;
  @override
  State<SafetyPlanEditScreen> createState() => _SafetyPlanEditScreenState();
}

class _SafetyPlanEditScreenState extends State<SafetyPlanEditScreen>
    with AdBlockedState<SafetyPlanEditScreen> {
  Map<String, dynamic>? _meet, _far;
  late final TextEditingController _meetNote;
  final List<Map<String, dynamic>> _nums = [];
  final List<int> _call = [];
  final Set<int> _share = {};
  bool _busy = false;
  bool _tried = false;

  @override
  void initState() {
    super.initState();
    final i = widget.initial;
    _meet = (i['meeting_point'] as Map?)?.cast<String, dynamic>();
    _far = (i['meeting_point_far'] as Map?)?.cast<String, dynamic>();
    _meetNote = TextEditingController(text: '${_meet?['note'] ?? ''}');
    _nums.addAll(splRows(i['numbers']));
    if (_nums.isEmpty && i['meeting_point'] == null && (i['call_order'] as List? ?? []).isEmpty) {
      // a new plan starts with 999 (national emergency) — one tap to drop it
      for (final d in widget.defaults.take(1)) {
        _nums.add({'number': d['number'], 'label': d['label']});
      }
    }
    for (final x in (i['call_order'] as List? ?? const [])) {
      if (x is int) _call.add(x);
    }
    for (final x in (i['shared_with'] as List? ?? const [])) {
      if (x is int) _share.add(x);
    }
  }

  @override
  void dispose() {
    _meetNote.dispose();
    super.dispose();
  }

  Map<String, dynamic>? _member(int id) {
    for (final m in widget.members) {
      if (m['member_id'] == id) return m;
    }
    return null;
  }

  Map<String, dynamic> _body() => {
        'meeting_point': _meet == null
            ? null
            : {..._meet!, 'note': _meetNote.text.trim()},
        'meeting_point_far': _far,
        'numbers': _nums,
        'call_order': _call,
        'shared_with': _share.toList(),
        'note': widget.initial['note'] ?? '',
      };

  Future<void> _pickPlace(bool far) async {
    final api = context.read<AppState>().api;
    final p = await showPlaceSearchSheet(context, api,
        fieldKey: ValueKey(far ? 'spl_far_search' : 'spl_meet_search'));
    if (p == null || !mounted) return;
    setState(() {
      final v = <String, dynamic>{'name': p.name, 'lat': p.lat, 'lng': p.lng, 'note': p.address};
      if (far) {
        _far = v;
      } else {
        _meet = v;
      }
    });
  }

  Future<void> _addNumber() async {
    final t = AppLocalizations.of(context);
    final num = TextEditingController();
    final label = TextEditingController();
    final ok = await showAppSheet<bool>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => Padding(
        padding: EdgeInsets.fromLTRB(
            Gap.lg, Gap.lg, Gap.lg, Gap.lg + MediaQuery.of(ctx).viewInsets.bottom),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text(t.splAddNumber, style: AType.titleMedium.copyWith(fontWeight: FontWeight.w700)),
          const SizedBox(height: Gap.md),
          TextField(
              key: const ValueKey('spl_num_field'),
              controller: num,
              keyboardType: TextInputType.phone,
              maxLength: 20,
              buildCounter: localCounter,
              decoration: InputDecoration(labelText: t.splNumberField)),
          TextField(
              key: const ValueKey('spl_num_label'),
              controller: label,
              maxLength: 80,
              buildCounter: localCounter,
              decoration: InputDecoration(labelText: t.splNumberLabel)),
          const SizedBox(height: Gap.md),
          DsButton(
              key: const ValueKey('spl_num_add'),
              expand: true,
              label: t.save,
              onPressed: () => Navigator.pop(ctx, true)),
        ]),
      ),
    );
    final n = num.text.replaceAll(RegExp(r'[^0-9+]'), '');
    if (ok == true && n.length >= 3 && mounted) {
      setState(() => _nums.add({'number': n, 'label': label.text.trim()}));
    }
    num.dispose();
    label.dispose();
  }

  Future<void> _save() async {
    final t = AppLocalizations.of(context);
    final body = _body();
    setState(() => _tried = true);
    if (!splHasContent(body)) return;
    setState(() => _busy = true);
    try {
      final r = safetyPlanSaveOverride != null
          ? await safetyPlanSaveOverride!(body)
          : await context.read<AppState>().api.postJson('/safety-plan', body);
      if (mounted) Navigator.pop(context, r);
    } catch (e) {
      if (mounted) {
        setState(() => _busy = false);
        reportNonFatal('safetyPlan.save', e);
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(t.splFailed)));
      }
    }
  }

  Widget _h(String s) => Padding(
        padding: const EdgeInsets.only(top: Gap.lg, bottom: Gap.sm),
        child: Semantics(
            header: true,
            child: Text(s,
                style: AType.titleMedium.copyWith(
                    fontWeight: FontWeight.bold, color: DsTokens.of(context).text))),
      );

  Widget _placeTile(AppLocalizations t, bool far) {
    final v = far ? _far : _meet;
    return DsSurface(
      key: ValueKey(far ? 'spl_pick_far' : 'spl_pick_meet'),
      onTap: () => _pickPlace(far),
      padding: const EdgeInsets.all(Gap.md),
      child: Row(children: [
        Icon(v == null ? Icons.add_location_alt_rounded : Icons.place_rounded,
            color: DsTokens.of(context).primaryInk),
        const SizedBox(width: Gap.sm),
        Expanded(
            child: Text(v == null ? t.splChoosePlace : jDigits(context, '${v['name']}'),
                style: AType.bodyLarge)),
        if (v != null)
          IconButton(
              key: ValueKey(far ? 'spl_clear_far' : 'spl_clear_meet'),
              tooltip: t.splRemove,
              icon: const Icon(Icons.close_rounded),
              onPressed: () => setState(() => far ? _far = null : _meet = null)),
      ]),
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final ds = DsTokens.of(context);
    final empty = _tried && !splHasContent(_body());
    final notInCall = [for (final m in widget.members) if (!_call.contains(m['member_id'])) m];
    final canShare = [for (final m in widget.members) if (m['on_assisto'] == true) m];
    return Scaffold(
      appBar: AppBar(title: Text(t.splTitle)),
      body: ListView(
        padding: withNavBarInset(context, const EdgeInsets.all(Gap.lg)),
        children: [
          _h(t.splMeet),
          _placeTile(t, false),
          if (_meet != null)
            TextField(
                key: const ValueKey('spl_meet_note'),
                controller: _meetNote,
                maxLength: 160,
                buildCounter: localCounter,
                decoration: InputDecoration(labelText: t.splNote, hintText: t.splPlaceHint)),
          _h(t.splMeetFar),
          _placeTile(t, true),
          _h(t.splCallOrder),
          for (var i = 0; i < _call.length; i++)
            ListTile(
              key: ValueKey('spl_e_call_$i'),
              contentPadding: EdgeInsets.zero,
              leading: CircleAvatar(child: Text(jDigits(context, i + 1))),
              title: Text('${_member(_call[i])?['name'] ?? ''}'),
              trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                if (i > 0)
                  IconButton(
                      key: ValueKey('spl_up_$i'),
                      tooltip: t.splMoveUp,
                      icon: const Icon(Icons.arrow_upward_rounded),
                      onPressed: () => setState(() {
                            final x = _call.removeAt(i);
                            _call.insert(i - 1, x);
                          })),
                IconButton(
                    key: ValueKey('spl_rm_call_$i'),
                    tooltip: t.splRemove,
                    icon: const Icon(Icons.close_rounded),
                    onPressed: () => setState(() => _call.removeAt(i))),
              ]),
            ),
          if (widget.members.isEmpty)
            Text(t.splNoCircle, style: AType.bodyMedium.copyWith(color: ds.muted))
          else if (notInCall.isNotEmpty && _call.length < 6)
            Wrap(spacing: Gap.sm, runSpacing: Gap.xs, children: [
              for (final m in notInCall)
                ActionChip(
                    key: ValueKey('spl_add_call_${m['member_id']}'),
                    avatar: const Icon(Icons.person_add_alt_1_rounded, size: 18),
                    label: Text('${m['name']}'),
                    onPressed: () => setState(() => _call.add(m['member_id'] as int))),
            ]),
          _h(t.splNumbers),
          Wrap(spacing: Gap.sm, runSpacing: Gap.xs, children: [
            for (final d in widget.defaults)
              FilterChip(
                  key: ValueKey('spl_def_${d['number']}'),
                  label: Text('${jDigits(context, '${d['number']}')} · ${d['label']}'),
                  selected: _nums.any((n) => n['number'] == d['number']),
                  onSelected: (on) => setState(() {
                        _nums.removeWhere((n) => n['number'] == d['number']);
                        if (on) _nums.add({'number': d['number'], 'label': d['label']});
                      })),
          ]),
          for (var i = 0; i < _nums.length; i++)
            if (!widget.defaults.any((d) => d['number'] == _nums[i]['number']))
              ListTile(
                key: ValueKey('spl_e_num_$i'),
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.call_rounded),
                title: Text(jDigits(context, '${_nums[i]['number']}')),
                subtitle: Text('${_nums[i]['label'] ?? ''}'),
                trailing: IconButton(
                    tooltip: t.splRemove,
                    icon: const Icon(Icons.close_rounded),
                    onPressed: () => setState(() => _nums.removeAt(i))),
              ),
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: TextButton.icon(
                key: const ValueKey('spl_add_number'),
                style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
                icon: const Icon(Icons.add_rounded),
                label: Text(t.splAddNumber),
                onPressed: _addNumber),
          ),
          _h(t.splShareWith),
          if (canShare.isEmpty)
            Text(t.splNoCircle, style: AType.bodyMedium.copyWith(color: ds.muted))
          else
            for (final m in canShare)
              CheckboxListTile(
                  key: ValueKey('spl_share_${m['member_id']}'),
                  contentPadding: EdgeInsets.zero,
                  value: _share.contains(m['member_id']),
                  title: Text('${m['name']}'),
                  onChanged: (v) => setState(() => v == true
                      ? _share.add(m['member_id'] as int)
                      : _share.remove(m['member_id']))),
          Text(t.splShareNote, style: AType.bodySmall.copyWith(color: ds.muted)),
          const SizedBox(height: Gap.lg),
          if (empty)
            Padding(
              padding: const EdgeInsets.only(bottom: Gap.sm),
              child: Text(t.splNeedOne,
                  key: const ValueKey('spl_need_one'),
                  style: AType.bodyMedium.copyWith(color: ds.dangerInk)),
            ),
          DsButton(
              key: const ValueKey('spl_save'),
              expand: true,
              busy: _busy,
              icon: Icons.share_rounded,
              label: t.splSave,
              onPressed: _busy ? null : _save),
        ],
      ),
    );
  }
}
