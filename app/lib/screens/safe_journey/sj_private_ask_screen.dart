import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../l10n/app_localizations.dart';
import '../../maps/address_resolver.dart';
import '../../state.dart';
import '../../theme.dart';
import '../../widgets/app_sheet.dart' show withNavBarInset;
import '../../widgets/journey_ride.dart' show jDigits;
import 'sj_during_api.dart';

/// sjduring — ROUTE CHANGE AND STOPS (privacy). Shown ONLY on the
/// traveller's phone when the route changed or a stop is long. Nobody in
/// the family knows yet. Buttons in the owner's order:
///   1. Yes, add time (default 40 min) — the family sees only "Time extended"
///   2. Share the stop place
///   3. I am OK
///   4. Danger (red) — opens the SOS screen
/// No answer in 5 minutes -> the family gets "Check on NAME" (server).
///
/// Pops with the chosen action ('extend' | 'share' | 'ok' | 'danger'), or
/// null when closed without answering (the server clock keeps running).
class SjPrivateAskScreen extends StatefulWidget {
  final int journeyId;
  final Map<String, dynamic> ask;
  const SjPrivateAskScreen({super.key, required this.journeyId, required this.ask});

  @override
  State<SjPrivateAskScreen> createState() => _SjPrivateAskScreenState();
}

class _SjPrivateAskScreenState extends State<SjPrivateAskScreen> {
  static const _choices = [20, 40, 60, 90];
  int _minutes = 40;
  bool _busy = false;
  String? _from, _to;

  String get _kind => '${widget.ask['kind'] ?? ''}';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _areas());
  }

  /// Area names for "From X to Y" — the phone's own Geocoder first (free).
  Future<void> _areas() async {
    if (!mounted) return;
    final app = context.read<AppState>();
    final lang = app.locale?.languageCode == 'en' ? 'en' : 'bn';
    Future<String?> name(Object? p) async {
      if (p is! Map) return null;
      final lat = (p['lat'] as num?)?.toDouble();
      final lng = (p['lng'] as num?)?.toDouble();
      if (lat == null || lng == null) return null;
      try {
        final r = await AddressResolver.resolve(app.api, lat, lng, lang: lang);
        return r.isAddress ? r.text.split(',').first.trim() : null;
      } catch (_) {
        return null; // best-effort: the generic words stay
      }
    }

    final f = await name(widget.ask['from']);
    final to = await name(widget.ask['to']);
    if (mounted) {
      setState(() {
        _from = f;
        _to = to;
      });
    }
  }

  String _title(AppLocalizations t) {
    switch (_kind) {
      case 'off_route':
        return t.sjdAskRouteTitle;
      case 'near_stop':
        return t.sjdAskNearTitle;
      case 'late_stopped':
        return t.sjdAskLateTitle;
      case 'night_checkin':
        return t.sjdAskNightTitle;
      default:
        return t.sjdAskStopTitle;
    }
  }

  Future<void> _send(String action) async {
    if (_busy) return;
    setState(() => _busy = true);
    final t = AppLocalizations.of(context);
    final nav = Navigator.of(context);
    final msg = ScaffoldMessenger.maybeOf(context);
    if (action == 'danger') {
      // the SOS screen sends the SOS itself (countdown, PIN) — and the
      // server notes the answer so the ladder stops asking
      unawaited(context
          .read<AppState>()
          .api
          .sjAnswer(widget.journeyId, 'danger')
          .then((_) {}, onError: (_) {}));
      nav.pop('danger');
      return;
    }
    try {
      await context.read<AppState>().api.sjAnswer(widget.journeyId, action,
          minutes: action == 'extend' ? _minutes : null);
    } catch (_) {
      if (mounted) {
        setState(() => _busy = false);
        msg?.showSnackBar(SnackBar(content: Text(t.grpActionFailed)));
      }
      return;
    }
    msg?.showSnackBar(SnackBar(content: Text(t.sjdAnswerSent)));
    nav.pop(action);
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final cs = Theme.of(context).colorScheme;
    final warn = Brand.warnInk(context);
    final mins = (widget.ask['minutes'] as num?)?.toInt();
    final night = _kind == 'night_checkin';
    final big = const Size.fromHeight(52);
    return Scaffold(
      appBar: AppBar(title: Text(_title(t))),
      body: ListView(
        padding: withNavBarInset(context, const EdgeInsets.all(Gap.lg)),
        children: [
          // 1) privacy note on top
          Container(
            key: const ValueKey('sjd_only_you'),
            padding: const EdgeInsets.all(Gap.md),
            decoration: BoxDecoration(
                color: cs.primary.withValues(alpha: 0.10),
                borderRadius: BorderRadius.circular(Radii.md)),
            child: Row(children: [
              Icon(Icons.lock_rounded, color: cs.primary),
              const SizedBox(width: Gap.sm),
              Expanded(
                  child: Text(t.sjdOnlyYourPhone,
                      style: AType.bodyLarge.copyWith(fontWeight: FontWeight.w700))),
            ]),
          ),
          const SizedBox(height: Gap.md),
          // 2) amber card: what we noticed
          Container(
            key: const ValueKey('sjd_ask_card'),
            padding: const EdgeInsets.all(Gap.md),
            decoration: BoxDecoration(
                color: warn.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(Radii.md),
                border: Border.all(color: warn.withValues(alpha: 0.6))),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Icon(_kind == 'off_route' ? Icons.alt_route_rounded : Icons.pause_circle_rounded,
                    color: warn),
                const SizedBox(width: Gap.sm),
                Expanded(
                    child: Text(_title(t),
                        style: AType.titleMedium.copyWith(fontWeight: FontWeight.w700))),
              ]),
              if (_kind == 'off_route') ...[
                const SizedBox(height: Gap.xs),
                Text(t.sjdAskFromTo(_from ?? t.sjdThere, _to ?? t.sjdHere),
                    key: const ValueKey('sjd_from_to'), style: AType.bodyLarge),
              ] else if (mins != null && mins > 0) ...[
                const SizedBox(height: Gap.xs),
                Text(t.sjdStStopped(jDigits(context, mins)), style: AType.bodyLarge),
              ],
            ]),
          ),
          const SizedBox(height: Gap.lg),
          // 3) Yes, add time (picker, default 40) + the note under it
          if (!night) ...[
            Wrap(spacing: Gap.sm, runSpacing: Gap.xs, children: [
              for (final m in _choices)
                ChoiceChip(
                  key: ValueKey('sjd_min_$m'),
                  label: Text(t.sjdMinutes(jDigits(context, m))),
                  selected: _minutes == m,
                  onSelected: _busy ? null : (_) => setState(() => _minutes = m),
                ),
            ]),
            const SizedBox(height: Gap.sm),
            FilledButton.icon(
              key: const ValueKey('sjd_extend'),
              style: FilledButton.styleFrom(minimumSize: big),
              icon: const Icon(Icons.more_time_rounded),
              label: Text(t.sjdBtnAddTime),
              onPressed: _busy ? null : () => _send('extend'),
            ),
            Padding(
              padding: const EdgeInsets.only(top: Gap.xs, bottom: Gap.md),
              child: Text(t.sjdAddTimeNote,
                  style: AType.bodyMedium.copyWith(color: cs.onSurfaceVariant)),
            ),
            // 4) Share the stop place
            OutlinedButton.icon(
              key: const ValueKey('sjd_share'),
              style: OutlinedButton.styleFrom(minimumSize: big),
              icon: const Icon(Icons.place_rounded),
              label: Text(t.sjdBtnShare),
              onPressed: _busy ? null : () => _send('share'),
            ),
            const SizedBox(height: Gap.sm),
          ],
          // 5) I am OK
          OutlinedButton.icon(
            key: const ValueKey('sjd_ok'),
            style: OutlinedButton.styleFrom(minimumSize: big),
            icon: const Icon(Icons.thumb_up_alt_rounded),
            label: Text(t.sjdBtnOk),
            onPressed: _busy ? null : () => _send('ok'),
          ),
          const SizedBox(height: Gap.sm),
          // 6) Danger (red)
          FilledButton.icon(
            key: const ValueKey('sjd_danger'),
            style: Brand.dangerButton().copyWith(
                minimumSize: WidgetStatePropertyAll(big)),
            icon: const Icon(Icons.sos_rounded),
            label: Text(t.sjdBtnDanger),
            onPressed: _busy ? null : () => _send('danger'),
          ),
          const SizedBox(height: Gap.lg),
          // 7) bottom note
          Text(night ? t.sjdBottomNoteNight : t.sjdBottomNote,
              key: const ValueKey('sjd_bottom_note'),
              style: AType.bodyMedium.copyWith(color: cs.onSurfaceVariant)),
        ],
      ),
    );
  }
}
