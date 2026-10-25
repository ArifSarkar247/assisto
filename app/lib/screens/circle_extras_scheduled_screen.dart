import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../api.dart';
import '../state.dart';
import '../theme.dart';
import '../l10n/app_localizations.dart';

/// Scheduled messages (M2 item 9).
///
/// The client composes + ENCRYPTS the message now, stores the opaque envelope
/// locally with a `send_at`, and flushes it when due (reusing the
/// circle_messaging offline queue). The server only ever receives the ciphertext
/// at/after send_at — it never holds a "future plaintext". If offline at send_at,
/// the message is queued and sent on reconnect (offline-safe), still ciphertext.
///
/// Logic mirrors core/logic/circle_extras: validate_schedule_time,
/// build_scheduled_message, is_scheduled_due, due_scheduled, mark_scheduled.
///
/// Backend seam (integrator wires — see MIGRATION NOTE):
///   GET  /circle/{peer}/scheduled   -> list of ScheduledMessage (opaque env + send_at)
///   POST /circle/{peer}/scheduled   -> persist a build_scheduled_message payload
///   POST /circle/scheduled/{id}/cancel
/// Local-first: the on-device scheduler flushes due items; the server copy is a
/// cross-device mirror.
class CircleExtrasScheduledScreen extends StatefulWidget {
  final Map<String, dynamic> member; // the peer chat
  const CircleExtrasScheduledScreen({super.key, required this.member});

  @override
  State<CircleExtrasScheduledScreen> createState() =>
      _CircleExtrasScheduledScreenState();
}

class _ScheduledItem {
  final String clientMsgId;
  final DateTime sendAt;
  final String preview; // local decrypted preview (never sent to server)
  String status;
  _ScheduledItem(this.clientMsgId, this.sendAt, this.preview, this.status);
}

class _CircleExtrasScheduledScreenState
    extends State<CircleExtrasScheduledScreen> {
  // Lead-time window mirrors circle_extras SCHEDULE_MIN/MAX_LEAD_SEC.
  static const _minLead = Duration(minutes: 1);
  static const _maxLead = Duration(days: 365);

  final _items = <_ScheduledItem>[];
  final _compose = TextEditingController();
  DateTime? _when;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _compose.dispose();
    super.dispose();
  }

  ApiClient get _api => context.read<AppState>().api;
  int get _peer => widget.member['id'] as int;

  Future<void> _load() async {
    try {
      final r = await _api.getJson('/circle/$_peer/scheduled');
      final raw = ((r['results'] ?? r['scheduled'] ?? []) as List)
          .cast<Map<String, dynamic>>();
      for (final s in raw) {
        final at = DateTime.tryParse('${s['send_at'] ?? ''}')?.toLocal();
        if (at == null) continue;
        _items.add(_ScheduledItem(
          '${s['client_msg_id'] ?? ''}',
          at,
          '${s['preview'] ?? ''}', // server never has plaintext; preview is a local echo
          '${s['status'] ?? 'pending'}',
        ));
      }
    } catch (_) {}
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _pickWhen() async {
    final now = DateTime.now();
    final d = await showDatePicker(
      context: context,
      initialDate: now.add(const Duration(hours: 1)),
      firstDate: now,
      lastDate: now.add(_maxLead),
    );
    if (d == null || !mounted) return;
    final tod = await showTimePicker(
        context: context, initialTime: TimeOfDay.fromDateTime(now));
    if (tod == null) return;
    setState(() => _when =
        DateTime(d.year, d.month, d.day, tod.hour, tod.minute));
  }

  String? _validate(AppLocalizations t) {
    final w = _when;
    if (w == null) return null;
    final lead = w.difference(DateTime.now());
    if (lead < _minLead) return t.circleExtrasScheduleTooSoon;
    if (lead > _maxLead) return t.circleExtrasScheduleTooFar;
    return null;
  }

  Future<void> _save(AppLocalizations t) async {
    final text = _compose.text.trim();
    final w = _when;
    if (text.isEmpty || w == null) return;
    final err = _validate(t);
    if (err != null) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(err)));
      return;
    }
    final cid = 'sch-${DateTime.now().microsecondsSinceEpoch}';
    // The caller encrypts `text` -> opaque envelope (crypto/e2e.dart) and POSTs
    // the build_scheduled_message payload. Here we optimistically add the item.
    try {
      await _api.postJson('/circle/$_peer/scheduled', {
        'client_msg_id': cid,
        'send_at': w.toUtc().toIso8601String(),
        // envelope is attached by the chat screen (it holds the e2e session);
        // this screen carries only the schedule intent.
      });
    } catch (_) {
      // q1-seams: never "Message scheduled." when the server refused it.
      // (This screen is not reachable from the extras hub until a real
      // envelope + dispatcher exist — see REALITY_AUDIT "Seam audit 22 Oct".)
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(t.grpActionFailed)));
      }
      return;
    }
    if (!mounted) return;
    setState(() {
      _items.add(_ScheduledItem(cid, w, text, 'pending'));
      _compose.clear();
      _when = null;
    });
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(t.circleExtrasScheduledSaved)));
  }

  Future<void> _cancel(_ScheduledItem it) async {
    try {
      await _api.postJson('/circle/scheduled/${it.clientMsgId}/cancel', {});
    } catch (_) {
      // m3-circle: a failed cancel used to show "cancelled" anyway.
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(AppLocalizations.of(context).grpActionFailed)));
      }
      return;
    }
    if (mounted) setState(() => it.status = 'cancelled');
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final pending =
        _items.where((i) => i.status == 'pending').toList()
          ..sort((a, b) => a.sendAt.compareTo(b.sendAt));
    return Scaffold(
      appBar: AppBar(title: Text(t.circleExtrasScheduled)),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : Column(
              children: [
                Expanded(
                  child: pending.isEmpty
                      ? Center(
                          child: Text(t.circleExtrasNoScheduled,
                              style:
                                  TextStyle(color: scheme.onSurfaceVariant)))
                      : ListView.builder(
                          itemCount: pending.length,
                          itemBuilder: (_, i) {
                            final it = pending[i];
                            return ListTile(
                              leading:
                                  const Icon(Icons.schedule_send_rounded),
                              title: Text(it.preview,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis),
                              subtitle: Text(
                                  t.circleExtrasStatusPending(_fmt(it.sendAt))),
                              trailing: IconButton(
                                icon: const Icon(Icons.close_rounded),
                                tooltip: t.cancel,
                                onPressed: () => _cancel(it),
                              ),
                            );
                          },
                        ),
                ),
                const Divider(height: 1),
                _composer(t, scheme),
              ],
            ),
    );
  }

  Widget _composer(AppLocalizations t, ColorScheme scheme) => Padding(
        padding: EdgeInsets.only(
          left: Gap.md,
          right: Gap.md,
          top: Gap.sm,
          bottom: MediaQuery.of(context).viewInsets.bottom + Gap.md,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(t.circleExtrasScheduleHint,
                style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant)),
            const SizedBox(height: Gap.xs),
            TextField(
              controller: _compose,
              minLines: 1,
              maxLines: 4,
              decoration: InputDecoration(
                hintText: t.circleExtrasScheduleTitle,
                border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(Radii.md)),
                isDense: true,
              ),
            ),
            const SizedBox(height: Gap.sm),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    icon: const Icon(Icons.event_rounded, size: 18),
                    label: Text(_when == null
                        ? t.circleExtrasPickDateTime
                        : _fmt(_when!)),
                    onPressed: _pickWhen,
                  ),
                ),
                const SizedBox(width: Gap.sm),
                FilledButton(
                  onPressed: () => _save(t),
                  child: Text(t.circleExtrasSave),
                ),
              ],
            ),
          ],
        ),
      );

  String _fmt(DateTime d) {
    String two(int n) => n.toString().padLeft(2, '0');
    return '${d.year}-${two(d.month)}-${two(d.day)} ${two(d.hour)}:${two(d.minute)}';
  }
}
