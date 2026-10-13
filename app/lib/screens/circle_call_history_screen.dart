import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../api.dart';
import '../l10n/app_localizations.dart';
import '../state.dart';
import '../theme.dart';
import '../widgets/circle_relation.dart';
import 'circle_call_screen.dart';

/// Connected Circle call history (M1 item 5): voice/video log with missed
/// calls, outgoing/incoming direction, duration and one-tap call-back.
///
/// Rows are built server-side from CallRecord (core/logic/circle_calls:
/// call_outcome_label / format_duration / is_missed). This screen reads
/// GET /circle/calls and renders them; call-back re-opens CircleCallScreen,
/// which re-runs the SERVER-SIDE gate (so a free user still can't video-call
/// back on a video entry — they get the upgrade prompt).
class CircleCallHistoryScreen extends StatefulWidget {
  const CircleCallHistoryScreen({super.key});

  @override
  State<CircleCallHistoryScreen> createState() =>
      _CircleCallHistoryScreenState();
}

class _CircleCallHistoryScreenState extends State<CircleCallHistoryScreen> {
  bool _loading = true;
  bool _backendReady = true;
  List<Map<String, dynamic>> _calls = [];

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
      _calls = ((r['results'] ?? r['calls'] ?? []) as List)
          .cast<Map<String, dynamic>>();
      _backendReady = true;
    } catch (_) {
      _backendReady = false;
      _calls = [];
    }
    if (mounted) setState(() => _loading = false);
  }

  void _callBack(Map<String, dynamic> call, String kind) {
    final member = (call['member'] as Map?)?.cast<String, dynamic>() ??
        {
          'id': call['member_id'],
          'name': call['name'],
          'relation': call['relation'],
        };
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) =>
          CircleCallScreen(member: member, kind: kind, outgoing: true),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: Text(_t.circleCallHistoryTitle)),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: _load,
              child: _calls.isEmpty
                  ? _empty(scheme)
                  : ListView.separated(
                      itemCount: _calls.length,
                      separatorBuilder: (_, __) => const Divider(height: 1),
                      itemBuilder: (_, i) => _callTile(_calls[i], scheme),
                    ),
            ),
    );
  }

  Widget _empty(ColorScheme scheme) => ListView(
        children: [
          const SizedBox(height: 96),
          Icon(Icons.call_outlined,
              size: 56, color: scheme.primary.withValues(alpha: 0.7)),
          const SizedBox(height: Gap.md),
          Text(
            _backendReady
                ? _t.circleCallHistoryEmpty
                : _t.circleBackendPending,
            textAlign: TextAlign.center,
            style: TextStyle(color: scheme.onSurfaceVariant, height: 1.4),
          ),
        ],
      );

  Widget _callTile(Map<String, dynamic> call, ColorScheme scheme) {
    final name = '${call['name'] ?? call['member_name'] ?? ''}';
    final relation = '${call['relation'] ?? 'friend'}';
    final kind = '${call['kind'] ?? 'voice'}';
    final state = '${call['state'] ?? 'ended'}';
    final outgoing = call['outgoing'] == true;
    final missed = state == 'missed' || state == 'canceled';
    final declined = state == 'declined';
    // Server provides the localized outcome label; fall back to a direction cue.
    final outcome = '${call['outcome'] ?? ''}';
    final duration = '${call['duration'] ?? ''}';
    final atRaw = '${call['started_at'] ?? call['created_at'] ?? ''}';
    final at = DateTime.tryParse(atRaw)?.toLocal();

    final dirColor = missed ? scheme.error : scheme.onSurfaceVariant;

    return ListTile(
      leading: CircleAvatar(
        child: Text(name.isEmpty ? '?' : name.characters.first.toUpperCase()),
      ),
      title: Text(
        name,
        style: TextStyle(color: missed ? scheme.error : scheme.onSurface),
      ),
      subtitle: Row(
        children: [
          Icon(
            declined
                ? Icons.call_end
                : outgoing
                    ? Icons.call_made
                    : missed
                        ? Icons.call_missed
                        : Icons.call_received,
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
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: dirColor, fontSize: 12),
            ),
          ),
          if (duration.isNotEmpty && !missed && !declined) ...[
            const SizedBox(width: Gap.xs),
            Text(duration,
                style:
                    TextStyle(color: scheme.onSurfaceVariant, fontSize: 12)),
          ],
        ],
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (at != null)
            Text(_relativeTime(at),
                style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant)),
          IconButton(
            tooltip: kind == 'video'
                ? _t.circleCallBackVideo
                : _t.circleCallBackVoice,
            icon: Icon(kind == 'video' ? Icons.videocam_outlined : Icons.call),
            onPressed: () => _callBack(call, kind),
          ),
        ],
      ),
    );
  }

  String _relativeTime(DateTime at) {
    final now = DateTime.now();
    final sameDay = at.year == now.year &&
        at.month == now.month &&
        at.day == now.day;
    if (sameDay) return DateFormat.Hm().format(at);
    return DateFormat.MMMd().format(at);
  }
}
