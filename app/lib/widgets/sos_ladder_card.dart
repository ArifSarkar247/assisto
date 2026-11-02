import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../family_alerts_api.dart';
import '../l10n/app_localizations.dart';
import '../services/action_feedback.dart';
import '../services/sos_ladder.dart';
import '../sosat_api.dart';
import '../state.dart';
import '../theme.dart';
import 'notif_models.dart' show notifLocalizeDigits;

/// sosat — the SOS escalation ladder, shown right after an SOS is sent (and
/// whenever one is active). Always says honestly WHERE the alert is and WHAT
/// TO DO NEXT:
///   waiting  -> "Sent. Waiting for someone to open it" + each person's state
///   rerung   -> nobody opened it in 2 min: the server rang their phones
///               again; Call / SMS buttons come first
///   call_999 -> still nobody after 5 min: "Call 999" is the big button
///               (the user taps — Assisto never dials by itself)
///   no_one   -> nobody could be alerted: SMS from your own SIM + 999
///   seen     -> someone opened it
///   resolved -> "I'm safe now" was sent
/// Refreshes every 15 s while visible (stops once seen / resolved).
class SosLadderCard extends StatefulWidget {
  const SosLadderCard({
    super.key,
    this.contacts = const [],
    this.smsBody,
    this.load,
    this.resolve,
    this.offline = false,
  });

  /// Emergency contacts (name/phone) for the Call / SMS steps.
  final List<Map<String, dynamic>> contacts;

  /// Message for the SMS step (with the map link when known).
  final String? smsBody;

  /// The server alert failed (no internet): the SMS step is the only way.
  final bool offline;

  /// Test seams (default: GET /family/sos/ladder, POST /family/sos/resolve).
  final Future<Map<String, dynamic>> Function()? load;
  final Future<Map<String, dynamic>> Function()? resolve;

  @override
  State<SosLadderCard> createState() => _SosLadderCardState();
}

class _SosLadderCardState extends State<SosLadderCard> {
  Map<String, dynamic>? _d;
  Timer? _poll;
  bool _resolving = false;

  @override
  void initState() {
    super.initState();
    _refresh();
    _poll = Timer.periodic(const Duration(seconds: 15), (_) => _refresh());
  }

  @override
  void dispose() {
    _poll?.cancel();
    super.dispose();
  }

  Future<void> _refresh() async {
    if (widget.offline) return;
    try {
      final f = widget.load ?? () => context.read<AppState>().api.sosLadder();
      final d = await f();
      if (!mounted) return;
      setState(() => _d = d);
      final st = '${d['stage'] ?? ''}';
      if (st == SosLadder.seen || st == SosLadder.resolved) _poll?.cancel();
    } catch (_) {
      // keep the last known state; the next tick tries again
    }
  }

  String get _stage {
    if (widget.offline) return SosLadder.noOne;
    return '${_d?['stage'] ?? SosLadder.waiting}';
  }

  List<String> get _phones => [
        for (final c in widget.contacts)
          if ('${c['phone'] ?? ''}'.trim().isNotEmpty) '${c['phone']}'.trim()
      ];

  Future<void> _sms() async {
    final nums = _phones.join(';');
    final body = Uri.encodeComponent(
        widget.smsBody ?? AppLocalizations.of(context).emergencySosAlertText);
    await openForUser(context, Uri.parse('sms:$nums?body=$body'), where: 'sos.sms');
  }

  Future<void> _call(String phone) =>
      openForUser(context, Uri.parse('tel:$phone'), where: 'sos.ladder.call');

  Future<void> _safe() async {
    final t = AppLocalizations.of(context);
    final m = ScaffoldMessenger.of(context);
    setState(() => _resolving = true);
    try {
      final f = widget.resolve ??
          () => context.read<AppState>().api.familySosResolve();
      await f();
      m.showSnackBar(SnackBar(content: Text(t.fa100SafeSent)));
      await _refresh();
    } catch (_) {
      m.showSnackBar(SnackBar(content: Text(t.fa100SafeFailed)));
    } finally {
      if (mounted) setState(() => _resolving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final st = _stage;
    final rows = ((_d?['recipients'] as List?) ?? const [])
        .whereType<Map>()
        .map((e) => e.cast<String, dynamic>())
        .toList();
    final n = (int v) => notifLocalizeDigits(context, '$v');
    final seen = (_d?['seen'] as num?)?.toInt() ?? 0;
    final total = (_d?['total'] as num?)?.toInt() ?? rows.length;

    final (IconData icon, Color color, String title, String body) = switch (st) {
      SosLadder.seen => (
          Icons.mark_email_read_rounded,
          Brand.success,
          t.saLadderSeenTitle(n(seen), n(total)),
          t.saLadderSeenBody
        ),
      SosLadder.resolved => (
          Icons.verified_user_rounded,
          Brand.success,
          t.saLadderResolvedTitle,
          t.saLadderResolvedBody
        ),
      SosLadder.noOne => (
          Icons.sms_failed_rounded,
          scheme.error,
          widget.offline ? t.saLadderOfflineTitle : t.saLadderNoOneTitle,
          t.saLadderNoOneBody
        ),
      SosLadder.rerung => (
          Icons.notifications_active_rounded,
          scheme.error,
          t.saLadderRerungTitle,
          t.saLadderRerungBody
        ),
      SosLadder.call999 => (
          Icons.local_police_rounded,
          scheme.error,
          t.saLadder999Title,
          t.saLadder999Body
        ),
      _ => (
          Icons.schedule_send_rounded,
          scheme.error,
          t.saLadderWaitingTitle(n(total)),
          t.saLadderWaitingBody
        ),
    };

    final urgent = st == SosLadder.noOne ||
        st == SosLadder.rerung ||
        st == SosLadder.call999;
    final firstPhone = _phones.isEmpty ? null : _phones.first;
    final firstName = widget.contacts
        .firstWhere((c) => '${c['phone'] ?? ''}'.trim().isNotEmpty,
            orElse: () => const {})['name'];

    return Semantics(
      container: true,
      liveRegion: true,
      child: Container(
        key: const ValueKey('sosat-ladder'),
        padding: const EdgeInsets.all(Gap.lg),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(Radii.md),
          border: Border.all(color: color.withValues(alpha: 0.4)),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(children: [
            Icon(icon, color: color),
            const SizedBox(width: Gap.sm),
            Expanded(
                child: Text(title,
                    key: ValueKey('sosat-ladder-$st'),
                    style: AType.titleMedium.copyWith(fontWeight: FontWeight.w800))),
          ]),
          const SizedBox(height: Gap.xs),
          Text(body, style: AType.bodyMedium),
          if (rows.isNotEmpty) ...[
            const SizedBox(height: Gap.sm),
            for (final r in rows) _person(t, r, scheme),
          ],
          // ---- the next steps (the user taps; nothing is dialled for them)
          if (st != SosLadder.resolved) ...[
            const SizedBox(height: Gap.md),
            // the 3 steps, in ladder order: family -> SMS -> 999
            Text(t.saLadderStepsTitle,
                style: AType.labelLarge.copyWith(fontWeight: FontWeight.w700)),
            const SizedBox(height: Gap.xs),
            if (firstPhone != null)
              _step(
                key: 'sosat-call-family',
                icon: Icons.call_rounded,
                label: t.saLadderCallPerson('${firstName ?? firstPhone}'),
                filled: urgent && st != SosLadder.call999,
                onTap: () => _call(firstPhone),
              ),
            if (_phones.isNotEmpty)
              _step(
                key: 'sosat-sms',
                icon: Icons.sms_rounded,
                label: t.saLadderSms(n(_phones.length)),
                filled: widget.offline,
                onTap: _sms,
              ),
            _step(
              key: 'sosat-999',
              icon: Icons.local_police_rounded,
              label: t.saLadderCall999,
              filled: st == SosLadder.call999 || (st == SosLadder.noOne && _phones.isEmpty),
              danger: true,
              onTap: () => _call('999'),
            ),
            if (!widget.offline && st != SosLadder.noOne) ...[
              const SizedBox(height: Gap.sm),
              OutlinedButton.icon(
                key: const ValueKey('sosat-safe'),
                style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(48)),
                onPressed: _resolving ? null : _safe,
                icon: const Icon(Icons.verified_user_rounded),
                label: Text(t.fa100SafeNow),
              ),
            ],
          ],
        ]),
      ),
    );
  }

  Widget _person(AppLocalizations t, Map<String, dynamic> r, ColorScheme scheme) {
    final seen = r['seen'] == true;
    final got = r['received'] == true;
    final status = '${r['status'] ?? ''}';
    final (IconData ic, String label) = seen
        ? (Icons.done_all_rounded, t.fa100StSeen)
        : got
            ? (Icons.done_rounded, t.fa100StReceived)
            : status == 'sent' || status == 'held'
                ? (Icons.schedule_rounded, t.fa100StSent)
                : (Icons.phonelink_off_rounded, t.fa100StNoDevice);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(children: [
        Icon(ic, size: 18, color: seen ? Brand.success : scheme.onSurfaceVariant),
        const SizedBox(width: Gap.xs),
        Expanded(child: Text('${r['name'] ?? ''}', maxLines: 1, overflow: TextOverflow.ellipsis)),
        const SizedBox(width: Gap.xs),
        Flexible(
            child: Text(label,
                textAlign: TextAlign.end,
                style: AType.bodySmall.copyWith(color: scheme.onSurfaceVariant))),
      ]),
    );
  }

  Widget _step({
    required String key,
    required IconData icon,
    required String label,
    required bool filled,
    required VoidCallback onTap,
    bool danger = false,
  }) {
    final style = filled
        ? FilledButton.styleFrom(
            minimumSize: const Size.fromHeight(52),
            backgroundColor: danger ? Brand.danger : null,
            foregroundColor: danger ? Colors.white : null)
        : OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(48));
    final child = Text(label, textAlign: TextAlign.center);
    return Padding(
      padding: const EdgeInsets.only(top: Gap.xs),
      child: filled
          ? FilledButton.icon(
              key: ValueKey(key), style: style, onPressed: onTap, icon: Icon(icon), label: child)
          : OutlinedButton.icon(
              key: ValueKey(key), style: style, onPressed: onTap, icon: Icon(icon), label: child),
    );
  }
}
