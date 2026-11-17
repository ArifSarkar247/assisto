import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../api.dart';
import '../calls/call_avatar.dart';
import '../l10n/app_localizations.dart';
import '../state.dart';
import '../theme.dart';
import '../ds/ds.dart';
import '../widgets/circle_relation.dart';
import '../widgets/circle_badges.dart';
import '../crypto/identity_vault.dart';
import 'circle_call_info_screen.dart';
import 'circle_call_screen.dart';
import 'circle_chat_screen.dart';
import '../widgets/a11y_prefs.dart' show a11yMaxLines; // a11ysweep
import 'messenger/contacts_screen.dart'; // circle2

/// Connected Circle call history (M1 item 5): voice/video log with missed
/// calls, outgoing/incoming direction, duration and one-tap call-back.
///
/// Rows are built server-side from CallRecord (core/logic/circle_calls:
/// call_outcome_label / format_duration / is_missed). This screen reads
/// GET /circle/calls and renders them; call-back re-opens CircleCallScreen,
/// which re-runs the SERVER-SIDE gate (so a free user still can't video-call
/// back on a video entry — they get the upgrade prompt).
class CircleCallHistoryScreen extends StatefulWidget {
  /// home-circle: true when pushed on its own (missed-call notification,
  /// Settings) — opening it clears the home missed-call dot. Inside the
  /// My Circle hub the Calls TAB clears it instead (all tabs build at once).
  final bool standalone;
  const CircleCallHistoryScreen({super.key, this.standalone = true});

  @override
  State<CircleCallHistoryScreen> createState() =>
      _CircleCallHistoryScreenState();
}

class _CircleCallHistoryScreenState extends State<CircleCallHistoryScreen> {
  bool _loading = true;
  bool _backendReady = true;
  List<Map<String, dynamic>> _calls = [];
  // wa-polish2: the individual calls behind each grouped row (Call info)
  Map<String, Map<String, dynamic>> _byId = {};
  bool _missedOnly = false; // wa-polish: All / Missed filter

  @override
  void initState() {
    super.initState();
    _load();
  }

  ApiClient get _api => context.read<AppState>().api;
  AppLocalizations get _t => AppLocalizations.of(context);

  Future<void> _load() async {
    try {
      final r = await _api.getJson('/circle/calls');
      // x1-calls A1-g: the server's WhatsApp-style groups ("Name (6)");
      // an older server without them -> grouped here the same way.
      final raw = ((r['groups'] ?? r['results'] ?? r['calls'] ?? []) as List)
          .whereType<Map>()
          .map((e) => e.cast<String, dynamic>())
          .toList();
      _calls = r['groups'] is List ? raw : groupCallRows(raw);
      final singles = ((r['calls'] ?? r['results'] ?? []) as List)
          .whereType<Map>()
          .map((e) => e.cast<String, dynamic>());
      _byId = {for (final c in singles) '${c['id']}': c};
      _backendReady = true;
      if (widget.standalone) {
        CircleBadges.instance.markCallsSeen(_byId.values.toList());
      }
    } catch (_) {
      _backendReady = false;
      _calls = [];
    }
    if (mounted) setState(() => _loading = false);
  }

  Map<String, dynamic> _memberOf(Map<String, dynamic> call) =>
      (call['member'] as Map?)?.cast<String, dynamic>() ??
      {
        'id': call['member_id'],
        'name': call['name'],
        'relation': call['relation'],
        'photo_url': call['photo_url'],
        'photo_v': call['photo_v'],
      };

  /// wa-polish2: WhatsApp's Call info for a tapped row.
  void _openInfo(Map<String, dynamic> call) {
    final entries = callInfoEntries(call, _byId);
    final reachable = _memberOf(call)['id'] is int;
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => CircleCallInfoScreen(
        call: call,
        entries: entries,
        onCall: reachable ? (kind) => _callBack(call, kind) : null,
        onMessage: reachable ? () => _openChat(call) : null,
      ),
    ));
  }

  Future<void> _openChat(Map<String, dynamic> call) async {
    final identity = await IdentityVault.instance.get();
    if (!mounted) return;
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) =>
          CircleChatScreen(member: _memberOf(call), identity: identity),
    ));
  }

  void _callBack(Map<String, dynamic> call, String kind) {
    final member = _memberOf(call);
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) =>
          CircleCallScreen(member: member, kind: kind, outgoing: true),
    ));
  }

  // ------------------------------------------------------------ gap-circle
  Future<bool> _confirm(String title, String body) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        scrollable: true, // 200% text
        title: Text(title),
        content: Text(body),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(_t.cancel)),
          FilledButton(
              key: const Key('gapc-calls-confirm'),
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(_t.delete)),
        ],
      ),
    );
    return ok == true && mounted;
  }

  Future<void> _hide(Map<String, dynamic> body, bool Function(Map<String, dynamic>) gone) async {
    final beforeCalls = _calls;
    final beforeById = _byId;
    setState(() {
      _calls = _calls.where((c) => !gone(c)).toList();
      _byId = {
        for (final e in _byId.entries)
          if (!gone(e.value)) e.key: e.value
      };
    });
    try {
      await _api.postJson('/circle/calls/hide', body);
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(_t.gapcCallsRemoved)));
      }
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _calls = beforeCalls;
        _byId = beforeById;
      });
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(_t.grpActionFailed)));
    }
  }

  Future<void> _removeRow(Map<String, dynamic> row) async {
    if (!await _confirm(_t.gapcCallRemove, _t.gapcCallRemoveBody)) return;
    final ids = {
      for (final e in callInfoEntries(row, _byId)) '${e['id']}',
      if (row['ids'] is List) for (final i in row['ids'] as List) '$i',
      '${row['id']}',
    }.map(int.tryParse).whereType<int>().toList();
    if (ids.isEmpty) return;
    await _hide({'ids': ids}, (c) => ids.contains(int.tryParse('${c['id']}')));
  }

  Future<void> _clearAll() async {
    if (!await _confirm(_t.gapcCallsClear, _t.gapcCallsClearBody)) return;
    await _hide({'all': true}, (_) => true);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: Text(_t.circleCallHistoryTitle),
        actions: [
          // gap-circle: clear my call history (the other person keeps theirs)
          if (!_loading && _calls.isNotEmpty)
            PopupMenuButton<String>(
              key: const Key('gapc-calls-menu'),
              onSelected: (_) => _clearAll(),
              itemBuilder: (_) => [
                PopupMenuItem(
                    key: const Key('gapc-calls-clear'),
                    value: 'clear',
                    child: Text(_t.gapcCallsClear)),
              ],
            ),
        ],
      ),
      body: _loading
          ? ListView(padding: const EdgeInsets.all(Gap.lg), children: [
              for (var i = 0; i < 4; i++)
                Padding(padding: const EdgeInsets.only(bottom: Gap.sm), child: DsSkeleton.card(lines: 2)),
            ])
          : RefreshIndicator(
              onRefresh: _load,
              child: _calls.isEmpty
                  ? _empty(scheme)
                  : _list(scheme),
            ),
    );
  }

  /// wa-polish: WhatsApp's All / Missed filter over the call log.
  Widget _list(ColorScheme scheme) {
    final rows =
        _missedOnly ? _calls.where(isMissedCallRow).toList() : _calls;
    return ListView.separated(
      key: const Key('call-log-list'),
      itemCount: rows.length + 1 + (rows.isEmpty ? 1 : 0),
      separatorBuilder: (_, i) =>
          i == 0 ? const SizedBox.shrink() : const Divider(height: 1),
      itemBuilder: (_, i) {
        if (i == 0) return _filters();
        if (rows.isEmpty) {
          return Padding(
            padding: const EdgeInsets.symmetric(
                horizontal: Gap.lg, vertical: Gap.xxl),
            child: Text(_t.waCallsNoMissed,
                key: const Key('call-log-no-missed'),
                textAlign: TextAlign.center,
                style: TextStyle(color: DsTokens.of(context).muted, height: 1.4)),
          );
        }
        return _callTile(rows[i - 1], scheme);
      },
    );
  }

  Widget _filters() => Padding(
        padding: const EdgeInsets.fromLTRB(Gap.lg, Gap.sm, Gap.lg, Gap.xs),
        child: Wrap(spacing: Gap.sm, runSpacing: Gap.xs, children: [
          DsChip(
            key: const Key('call-filter-all'),
            label: _t.waCallsFilterAll,
            selected: !_missedOnly,
            onSelected: (_) => setState(() => _missedOnly = false),
          ),
          DsChip(
            key: const Key('call-filter-missed'),
            label: _t.waCallsFilterMissed,
            selected: _missedOnly,
            onSelected: (_) => setState(() => _missedOnly = true),
          ),
        ]),
      );

  /// circle2 (owner checklist): an empty call log is not a dead end — one
  /// line of benefit, a big primary button (pick someone from My Circle and
  /// call), and a 3-step how-to.
  Widget _empty(ColorScheme scheme) => ListView(
        key: const Key('circle2-calls-empty'),
        padding: const EdgeInsets.all(Gap.lg),
        children: [
          // designv2: DS empty state (benefit + big button), how-to under it
          DsEmptyState(
            icon: Icons.call_rounded,
            title: _backendReady ? _t.circleCallHistoryEmpty : _t.circleBackendPending,
            benefit: _backendReady ? _t.circle2CallsEmptyBenefit : null,
            actionLabel: _backendReady ? _t.circle2CallsEmptyCta : _t.retry,
            actionKey: Key(_backendReady ? 'circle2-calls-empty-cta' : 'circle2-calls-retry'),
            onAction: _backendReady
                ? () => Navigator.of(context).push(MaterialPageRoute(
                    builder: (_) => const ContactsScreen()))
                : () {
                    setState(() => _loading = true);
                    _load();
                  },
          ),
          if (_backendReady) ...[
            const SizedBox(height: Gap.lg),
            Text(_t.circle2CallsEmptyHow,
                textAlign: TextAlign.start,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: DsTokens.of(context).muted, height: 1.6)),
          ],
          const SizedBox(height: Gap.xl),
        ],
      );

  Widget _callTile(Map<String, dynamic> call, ColorScheme scheme) {
    final name = '${call['name'] ?? call['member_name'] ?? ''}';
    final count = (call['count'] as num?)?.toInt() ?? 1;
    final relation = '${call['relation'] ?? 'friend'}';
    final kind = '${call['kind'] ?? 'voice'}';
    final state = '${call['state'] ?? 'ended'}';
    final outgoing = call['outgoing'] == true;
    // c2-calls: only an INCOMING call can be "missed" (an outgoing one that
    // rang out is "No answer" / "Busy" / "Offline" — the server label).
    final missed = isMissedCallRow(call);
    final declined = state == 'declined';
    // Server provides the localized outcome label; fall back to a direction cue.
    final outcome = '${call['outcome'] ?? ''}';
    final duration = '${call['duration'] ?? ''}';
    final atRaw = '${call['started_at'] ?? call['created_at'] ?? ''}';
    final at = DateTime.tryParse(atRaw)?.toLocal();

    final dirColor = missed ? DsTokens.of(context).dangerInk : DsTokens.of(context).muted;

    return ListTile(
      key: ValueKey('call-log-row-${call['id']}'),
      // wa-polish2: tap the row -> Call info (the call button still calls)
      onTap: () => _openInfo(call),
      onLongPress: () => _removeRow(call), // gap-circle
      leading: CallAvatar(
          name: name,
          photoUrl: '${call['photo_url'] ?? ''}',
          version: '${call['photo_v'] ?? ''}',
          radius: 22,
          onDark: false),
      title: Text(
        // circle2: the group count in Bangla digits too (bn locale)
        count > 1 ? '$name (${_digits('$count')})' : name,
        key: Key('call-log-title-${call['id']}'),
        maxLines: a11yMaxLines(context, 1),
        overflow: TextOverflow.ellipsis,
        style: TextStyle(color: missed ? DsTokens.of(context).dangerInk : DsTokens.of(context).text),
      ),
      subtitle: Row(
        children: [
          Icon(
            declined
                ? Icons.call_end_rounded
                : outgoing
                    ? Icons.call_made_rounded
                    : missed
                        ? Icons.call_missed_rounded
                        : Icons.call_received_rounded,
            size: 14,
            color: dirColor,
          ),
          const SizedBox(width: Gap.xs),
          Expanded(
            child: Text(
              outcome.isNotEmpty
                  ? outcome
                  : CircleRelation.labelFor(_t, relation,
                      custom: call['custom_label'] as String?),
              maxLines: a11yMaxLines(context, 1),
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: dirColor, fontSize: 12),
            ),
          ),
          if (duration.isNotEmpty && !missed && !declined) ...[
            const SizedBox(width: Gap.xs),
            // qa1: the server sends "01:05"; the row's time already uses
            // Bangla digits, so the duration must too.
            Text(
                _digits(duration),
                style:
                    TextStyle(color: DsTokens.of(context).muted, fontSize: 12)),
          ],
        ],
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (at != null)
            Text(_relativeTime(at),
                style: TextStyle(fontSize: 11, color: DsTokens.of(context).muted)),
          IconButton(
            tooltip: kind == 'video'
                ? _t.circleCallBackVideo
                : _t.circleCallBackVoice,
            icon: Icon(kind == 'video' ? Icons.videocam_rounded : Icons.call_rounded),
            onPressed: () => _callBack(call, kind),
          ),
        ],
      ),
    );
  }

  /// Bangla digits in bn (the server sends "01:05", counts are ints).
  String _digits(String v) => Localizations.localeOf(context).languageCode ==
          'bn'
      ? v.replaceAllMapped(RegExp('[0-9]'),
          (m) => String.fromCharCode(0x09E6 + int.parse(m[0]!)))
      : v;

  String _relativeTime(DateTime at) {
    final now = DateTime.now();
    final sameDay = at.year == now.year &&
        at.month == now.month &&
        at.day == now.day;
    // QA a6: format in the app's language (was always English "Oct 10").
    final loc = Localizations.localeOf(context).languageCode;
    if (sameDay) return DateFormat.Hm(loc).format(at);
    return DateFormat.MMMd(loc).format(at);
  }
}


/// c2-calls: only an INCOMING call can be "missed" (an outgoing one that rang
/// out is "No answer" / "Busy" / "Offline" — the server label).
bool isMissedCallRow(Map<String, dynamic> call) {
  final state = '${call['state'] ?? 'ended'}';
  return call['outgoing'] != true && (state == 'missed' || state == 'canceled');
}

/// wa-polish2: the individual calls of a (grouped) log row, newest first —
/// the server's `ids` looked up in the plain `calls` list; the row itself
/// when they are not there (older server / client-side grouping).
List<Map<String, dynamic>> callInfoEntries(
    Map<String, dynamic> row, Map<String, Map<String, dynamic>> byId) {
  final ids = row['ids'];
  if (ids is List) {
    final out = [
      for (final id in ids)
        if (byId['$id'] != null) byId['$id']!
    ];
    if (out.isNotEmpty) return out;
  }
  return [row];
}

/// x1-calls A1-g (fallback for a server without `groups`): consecutive rows
/// (newest first) with the same person, direction, outcome and day collapse
/// into one row carrying `count` — "T Shanto BD (6)".
List<Map<String, dynamic>> groupCallRows(List<Map<String, dynamic>> rows) {
  String key(Map<String, dynamic> r) {
    final at = DateTime.tryParse('${r['started_at'] ?? ''}')?.toLocal();
    final day = at == null ? '' : '${at.year}-${at.month}-${at.day}';
    final who = '${r['peer_id'] ?? r['member_id'] ?? r['name'] ?? ''}';
    return '$who|${r['outgoing'] == true}|${r['state']}|${r['end_reason'] ?? ''}|$day';
  }

  final out = <Map<String, dynamic>>[];
  String? last;
  for (final r in rows) {
    final k = key(r);
    if (k == last && out.isNotEmpty) {
      final g = out.last;
      g['count'] = ((g['count'] as num?)?.toInt() ?? 1) + 1;
      (g['ids'] as List).add(r['id']); // wa-polish2: for Call info
      continue;
    }
    out.add({...r, 'count': 1, 'ids': [r['id']]});
    last = k;
  }
  return out;
}
