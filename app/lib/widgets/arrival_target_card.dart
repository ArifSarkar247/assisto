import '../l10n/app_localizations.dart';
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'arrival_model.dart';

/// The active safe-arrival target card (ADVANCED). Shows the destination + ETA,
/// a LIVE countdown that advances on_time -> grace -> overdue every second, the
/// pre-arrival reminder nudge, and a big one-tap "I've arrived".
///
/// A 1s ticker re-renders while a check-in is active (mirrors the fall-preview
/// timer pattern); it is cancelled when the check-in clears or on dispose.
/// Status + countdown math live in arrival_model (mirror of safety.py).
class ArrivalTargetCard extends StatefulWidget {
  final String? place;
  final DateTime? eta;
  final bool nightMode;
  final bool hasDuressPin;
  final VoidCallback onSet;
  final VoidCallback onArrived;
  final VoidCallback onArrivedWithPin;

  const ArrivalTargetCard({
    super.key,
    required this.place,
    required this.eta,
    required this.nightMode,
    required this.hasDuressPin,
    required this.onSet,
    required this.onArrived,
    required this.onArrivedWithPin,
  });

  @override
  State<ArrivalTargetCard> createState() => _ArrivalTargetCardState();
}

class _ArrivalTargetCardState extends State<ArrivalTargetCard> {
  Timer? _ticker;

  @override
  void initState() {
    super.initState();
    _syncTicker();
  }

  @override
  void didUpdateWidget(covariant ArrivalTargetCard old) {
    super.didUpdateWidget(old);
    if (old.eta != widget.eta) _syncTicker();
  }

  void _syncTicker() {
    _ticker?.cancel();
    _ticker = null;
    if (widget.eta != null) {
      _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
        if (mounted) setState(() {});
      });
    }
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final eta = widget.eta;
    if (eta == null) {
      // Empty hero: stacked icon → title → body → full-width button so the
      // text uses the full card width instead of cramming into a narrow
      // column beside the button (was a Row/ListTile that wrapped badly).
      return Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Icon(Icons.pin_drop_outlined,
                  color: Theme.of(context).colorScheme.primary),
              const SizedBox(width: 10),
              Expanded(
                child: Text(AppLocalizations.of(context).aNoneTitle,
                    style: const TextStyle(
                        fontWeight: FontWeight.w700, fontSize: 16)),
              ),
            ]),
            const SizedBox(height: 8),
            Text(AppLocalizations.of(context).aNoneDesc,
                style: TextStyle(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                    height: 1.4)),
            const SizedBox(height: 14),
            SizedBox(
              width: double.infinity,
              child: FilledButton.tonal(
                  onPressed: widget.onSet,
                  child: Text(AppLocalizations.of(context).aSetButton)),
            ),
          ]),
        ),
      );
    }

    final grace = aEffectiveGrace(eta, nightMode: widget.nightMode);
    final st = aCheckinStatus(eta, grace: grace);
    final cd = aCountdown(eta);
    final reminder = aReminderDue(eta);

    Color color;
    String label;
    switch (st.state) {
      case ArrivalState.onTime:
        color = Colors.green;
        label = AppLocalizations.of(context).aOnTime;
        break;
      case ArrivalState.grace:
        color = Colors.orange;
        label = AppLocalizations.of(context).aGrace;
        break;
      case ArrivalState.overdue:
        color = Colors.red;
        label = AppLocalizations.of(context).aOverdue;
        break;
      default:
        color = Colors.green;
        label = AppLocalizations.of(context).aOnTime;
    }

    final timeStr = DateFormat('h:mm a').format(eta);
    final cdText = aMin(context, cd.overdue ? 'aMinLate' : 'aMinLeft', cd.totalMinutes);

    return Card(
      color: color.withOpacity(0.08),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Icon(Icons.flag, color: color),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                widget.place == null
                    ? '${AppLocalizations.of(context).aByTime}: $timeStr'
                    : '${widget.place} - ${AppLocalizations.of(context).aByTime} $timeStr',
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
            ),
            if (widget.nightMode)
              Semantics(
                label: AppLocalizations.of(context).aNightSafety,
                child: Icon(Icons.nightlight_round, size: 18, color: Colors.indigo.shade300),
              ),
          ]),
          const SizedBox(height: 8),
          // live countdown — number + label, never colour alone
          Row(children: [
            Icon(cd.overdue ? Icons.timelapse : Icons.timer_outlined, size: 18, color: color),
            const SizedBox(width: 6),
            Text(cdText,
                style: TextStyle(color: color, fontWeight: FontWeight.w700, fontSize: 16)),
            const SizedBox(width: 8),
            Text(label, style: TextStyle(color: color, fontWeight: FontWeight.w600)),
          ]),
          if (reminder && st.state != ArrivalState.overdue) ...[
            const SizedBox(height: 6),
            Row(children: [
              const Icon(Icons.notifications_active_outlined, size: 16, color: Colors.orange),
              const SizedBox(width: 6),
              Expanded(child: Text(AppLocalizations.of(context).aReminderNudge,
                  style: const TextStyle(fontSize: 12, color: Colors.orange))),
            ]),
          ],
          if (st.state == ArrivalState.overdue) ...[
            const SizedBox(height: 4),
            Text(AppLocalizations.of(context).aOverdueNote,
                style: const TextStyle(fontSize: 12, color: Colors.grey)),
          ],
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              style: FilledButton.styleFrom(
                  backgroundColor: Colors.green,
                  padding: const EdgeInsets.symmetric(vertical: 14)),
              onPressed: widget.onArrived,
              icon: const Icon(Icons.check),
              label: Text(AppLocalizations.of(context).aArrived,
                  style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
            ),
          ),
          Row(children: [
            if (widget.hasDuressPin)
              TextButton.icon(
                onPressed: widget.onArrivedWithPin,
                icon: const Icon(Icons.lock_outline, size: 16),
                label: Text(AppLocalizations.of(context).aArrivedWithPin),
              ),
            const Spacer(),
            TextButton(onPressed: widget.onSet, child: Text(AppLocalizations.of(context).aEdit)),
          ]),
        ]),
      ),
    );
  }
}
