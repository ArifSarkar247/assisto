/// lpapp — shared widgets for Language Partner V2 (practice-score footer,
/// band bars, exam timer, hold-to-speak, yellow correction card, listen).
library;

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../ads/ad_placements.dart' show AdExit, AdExitPlacement;
import '../../l10n/app_localizations.dart';
import '../../theme.dart';
import '../../widgets/local_digits.dart';
import '../../widgets/voice_input.dart';
import '../language_pack_screen.dart' show speakPackLine;
import 'lp_engine.dart';

bool lpBn(BuildContext context) => Localizations.localeOf(context).languageCode == 'bn';

/// m['<base>_bn'] in Bangla (when present), else m['<base>_en'].
String lpLoc(BuildContext context, Map<String, dynamic> m, String base) {
  final bn = '${m['${base}_bn'] ?? ''}';
  if (lpBn(context) && bn.trim().isNotEmpty) return bn;
  return '${m['${base}_en'] ?? m[base] ?? ''}';
}

void lpToast(BuildContext context, String text) {
  ScaffoldMessenger.of(context)
    ..clearSnackBars()
    ..showSnackBar(SnackBar(content: Text(text)));
}

/// Reads English aloud with the phone's own voice (free, offline when the
/// phone has an English voice).
Future<void> lpSay(BuildContext context, String text) => speakPackLine(context, text, 'en-GB');

class LpListenButton extends StatelessWidget {
  final String text;
  const LpListenButton({super.key, required this.text});
  @override
  Widget build(BuildContext context) => IconButton(
        tooltip: AppLocalizations.of(context).lp2Listen,
        constraints: const BoxConstraints(minWidth: kMinTap, minHeight: kMinTap),
        icon: const Icon(Icons.volume_up_rounded),
        onPressed: () => lpSay(context, text),
      );
}

/// "Practice score — not an official IELTS result" under every band.
class LpPracticeFooter extends StatelessWidget {
  final String? text;
  final IconData icon;
  const LpPracticeFooter({super.key, this.text, this.icon = Icons.info_outline_rounded});
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: Gap.md),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Icon(icon, size: 18, color: scheme.ds.muted),
        const SizedBox(width: Gap.sm),
        Expanded(
          child: Text(text ?? AppLocalizations.of(context).lp2PracticeLabel,
              style: AType.bodySmall.copyWith(color: scheme.ds.muted, height: 1.4)),
        ),
      ]),
    );
  }
}

/// One section row: name, band, a bar out of 9 (or "not scored").
class LpBandBar extends StatelessWidget {
  final String label;
  final double? band;
  final String? note;
  const LpBandBar({super.key, required this.label, required this.band, this.note});
  @override
  Widget build(BuildContext context) {
    final tr = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final b = band;
    final colour = b == null
        ? scheme.ds.muted
        : b >= 7
            ? Brand.success
            : b >= 5.5
                ? Brand.info
                : Brand.warning;
    return Semantics(
      label: '$label ${b == null ? tr.lp2NotScored : ld(context, bandText(b))}',
      excludeSemantics: true,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: Gap.sm),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(children: [
            Expanded(child: Text(label, style: AType.bodyMedium.copyWith(fontWeight: FontWeight.w600))),
            Text(b == null ? tr.lp2NotScored : ld(context, bandText(b)),
                style: AType.bodyMedium.copyWith(fontWeight: FontWeight.w700, color: b == null ? scheme.ds.muted : null)),
          ]),
          const SizedBox(height: Gap.xs),
          ClipRRect(
            borderRadius: BorderRadius.circular(6),
            child: LinearProgressIndicator(
              value: b == null ? 0 : b / 9,
              minHeight: 10,
              color: colour,
              backgroundColor: scheme.ds.cardHighest,
            ),
          ),
          if (note != null && note!.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: Gap.xs),
              child: Text(note!, style: AType.bodySmall.copyWith(color: scheme.ds.muted)),
            ),
        ]),
      ),
    );
  }
}

/// A real exam countdown. Calls [onDone] once at zero. [paused] stops it.
class LpTimer extends StatefulWidget {
  final int seconds;
  final VoidCallback onDone;
  final bool paused;
  final ValueChanged<int>? onTick;
  const LpTimer({super.key, required this.seconds, required this.onDone, this.paused = false, this.onTick});
  @override
  State<LpTimer> createState() => _LpTimerState();
}

class _LpTimerState extends State<LpTimer> {
  late int _left = widget.seconds;
  Timer? _t;
  bool _fired = false;
  // gap-lp: the exam clock follows the real clock too — a phone that froze
  // the app in the background must not hand out extra exam time
  final DateTime _wallStart = DateTime.now();
  DateTime? _pausedAt;
  Duration _pausedFor = Duration.zero;

  int get _wallLeft =>
      widget.seconds - (DateTime.now().difference(_wallStart) - _pausedFor - _pausedNow).inSeconds;
  Duration get _pausedNow => _pausedAt == null ? Duration.zero : DateTime.now().difference(_pausedAt!);

  @override
  void didUpdateWidget(LpTimer old) {
    super.didUpdateWidget(old);
    if (widget.paused && !old.paused) _pausedAt = DateTime.now();
    if (!widget.paused && old.paused && _pausedAt != null) {
      _pausedFor += DateTime.now().difference(_pausedAt!);
      _pausedAt = null;
    }
  }

  @override
  void initState() {
    super.initState();
    if (widget.paused) _pausedAt = DateTime.now();
    _t = Timer.periodic(const Duration(seconds: 1), (_) {
      if (widget.paused || _fired) return;
      setState(() => _left = math.min(_left - 1, _wallLeft));
      widget.onTick?.call(_left);
      if (_left <= 0 && !_fired) {
        _fired = true;
        widget.onDone();
      }
    });
  }

  @override
  void dispose() {
    _t?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final tr = AppLocalizations.of(context);
    final low = _left <= 300;
    final fg = low ? Brand.onTint(context, Brand.danger) : Theme.of(context).colorScheme.ds.text;
    return Semantics(
      label: tr.lp2TimeLeft(ld(context, clock(_left))),
      excludeSemantics: true,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: Gap.md, vertical: Gap.xs),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: fg.withValues(alpha: 0.5)),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(widget.paused ? Icons.pause_rounded : Icons.timer_outlined, size: 18, color: fg),
          const SizedBox(width: Gap.xs),
          Text(ld(context, clock(_left)),
              style: AType.bodyMedium.copyWith(fontWeight: FontWeight.w700, color: fg, fontFeatures: const [FontFeature.tabularFigures()])),
        ]),
      ),
    );
  }
}

/// Hold to speak: the microphone opens only while the finger is down (first
/// use shows the app's reason screen). Releasing calls [onDone] with what the
/// phone heard. A short tap explains how to use it.
class LpHoldToSpeak extends StatefulWidget {
  final VoiceDictation voice;
  final TextEditingController heard;
  final ValueChanged<String> onDone;
  final String? label;
  final bool enabled;
  /// How long the finger was held (speaking time for scoring).
  final ValueChanged<Duration>? onHeld;
  const LpHoldToSpeak(
      {super.key,
      required this.voice,
      required this.heard,
      required this.onDone,
      this.label,
      this.enabled = true,
      this.onHeld});
  @override
  State<LpHoldToSpeak> createState() => _LpHoldToSpeakState();
}

class _LpHoldToSpeakState extends State<LpHoldToSpeak> {
  DateTime? _down;

  Future<void> _start() async {
    if (!widget.enabled) return;
    _down = DateTime.now();
    widget.heard.clear();
    HapticFeedback.selectionClick();
    await widget.voice.start(context, widget.heard, pauseFor: const Duration(seconds: 6));
  }

  Future<void> _end() async {
    if (!widget.enabled) return;
    if (_down != null) widget.onHeld?.call(DateTime.now().difference(_down!));
    await widget.voice.stop();
    // the recogniser delivers its last words a moment after stop
    await Future<void>.delayed(const Duration(milliseconds: 350));
    if (!mounted) return;
    final t = widget.heard.text.trim();
    if (t.isEmpty) {
      final short = _down != null && DateTime.now().difference(_down!) < const Duration(milliseconds: 600);
      lpToast(context, short ? AppLocalizations.of(context).lp2HoldHint : AppLocalizations.of(context).lp2NothingHeard);
      return;
    }
    widget.onDone(t);
  }

  @override
  Widget build(BuildContext context) {
    final tr = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    return ListenableBuilder(
      listenable: widget.voice,
      builder: (context, _) {
        final on = widget.voice.listening;
        return Semantics(
          button: true,
          label: widget.label ?? tr.lp2HoldToSpeak,
          hint: tr.lp2HoldHint,
          onTap: () => lpToast(context, tr.lp2HoldHint),
          excludeSemantics: true,
          child: GestureDetector(
            key: const Key('lp2-hold'),
            onLongPressStart: (_) => _start(),
            onLongPressEnd: (_) => _end(),
            onTap: () => lpToast(context, tr.lp2HoldHint),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 150),
              constraints: const BoxConstraints(minHeight: 60),
              padding: const EdgeInsets.symmetric(horizontal: Gap.lg, vertical: Gap.md),
              decoration: BoxDecoration(
                color: !widget.enabled
                    ? scheme.ds.cardHighest
                    : on
                        ? Brand.danger
                        : scheme.primary,
                borderRadius: BorderRadius.circular(32),
              ),
              child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                Icon(on ? Icons.graphic_eq_rounded : Icons.mic_rounded,
                    color: widget.enabled ? scheme.onPrimary : scheme.ds.muted),
                const SizedBox(width: Gap.sm),
                Flexible(
                  child: Text(on ? tr.lp2Listening : (widget.label ?? tr.lp2HoldToSpeak),
                      textAlign: TextAlign.center,
                      style: AType.bodyMedium.copyWith(
                          fontWeight: FontWeight.w700,
                          color: widget.enabled ? scheme.onPrimary : scheme.ds.muted)),
                ),
              ]),
            ),
          ),
        );
      },
    );
  }
}

/// The yellow correction card: better sentence + why (Bangla first for
/// Bangla users) + optional pronunciation percent and "say it" action.
class LpFixCard extends StatelessWidget {
  final String? wrong;
  final String right;
  final String why;
  final int? pron;
  final Widget? action;
  const LpFixCard({super.key, this.wrong, required this.right, required this.why, this.pron, this.action});
  @override
  Widget build(BuildContext context) {
    final tr = AppLocalizations.of(context);
    final ink = Brand.warnInk(context);
    final dark = Theme.of(context).brightness == Brightness.dark;
    return Card(
      key: const Key('lp2-fix'),
      color: Brand.warning.withValues(alpha: dark ? 0.22 : 0.16),
      shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14), side: BorderSide(color: Brand.warning.withValues(alpha: 0.7))),
      child: Padding(
        padding: const EdgeInsets.all(Gap.md),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Icon(Icons.lightbulb_rounded, color: ink, size: 20),
            const SizedBox(width: Gap.xs),
            Expanded(child: Text(tr.lp2FixTitle, style: AType.bodyMedium.copyWith(fontWeight: FontWeight.w700, color: ink))),
          ]),
          if (pron != null)
            Padding(padding: const EdgeInsets.only(top: Gap.xs), child: LpPronChip(percent: pron!)),
          if (wrong != null && wrong!.trim().isNotEmpty) ...[
            const SizedBox(height: Gap.sm),
            Text(wrong!,
                style: AType.bodyMedium.copyWith(decoration: TextDecoration.lineThrough, color: ink.withValues(alpha: 0.8))),
          ],
          const SizedBox(height: Gap.xs),
          Row(children: [
            Expanded(child: Text(right, style: AType.bodyMedium.copyWith(fontWeight: FontWeight.w700, color: ink, height: 1.35))),
            LpListenButton(text: right),
          ]),
          if (why.trim().isNotEmpty) Text(why, style: AType.bodyMedium.copyWith(color: ink, height: 1.4)),
          if (action != null) ...[const SizedBox(height: Gap.sm), action!],
        ]),
      ),
    );
  }
}

class LpPronChip extends StatelessWidget {
  final int percent;
  const LpPronChip({super.key, required this.percent});
  @override
  Widget build(BuildContext context) {
    final tr = AppLocalizations.of(context);
    final c = percent >= 80
        ? Brand.success
        : percent >= 50
            ? Brand.info
            : Brand.danger;
    return Semantics(
      label: tr.lp2PronPercent(ld(context, percent)),
      excludeSemantics: true,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: Gap.sm, vertical: Gap.xxs),
        decoration: BoxDecoration(color: c.withValues(alpha: 0.15), borderRadius: BorderRadius.circular(12)),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(Icons.record_voice_over_rounded, size: 16, color: Brand.onTint(context, c)),
          const SizedBox(width: Gap.xs),
          Flexible(
            child: Text(tr.lp2PronPercent(ld(context, percent)),
                style: AType.bodyMedium.copyWith(fontWeight: FontWeight.w700, color: Brand.onTint(context, c))),
          ),
        ]),
      ),
    );
  }
}

/// A small coloured tag ("Beta", "Premium", "Offline").
class LpTag extends StatelessWidget {
  final String text;
  final Color color;
  const LpTag({super.key, required this.text, required this.color});
  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: Gap.sm, vertical: Gap.xxs),
        decoration: BoxDecoration(color: color.withValues(alpha: 0.15), borderRadius: BorderRadius.circular(10)),
        child: Text(text, style: AType.bodySmall.copyWith(color: Brand.onTint(context, color), fontWeight: FontWeight.w700)),
      );
}

String lpSectionName(AppLocalizations tr, String s) => switch (s) {
      'listening' => tr.ieltsListening,
      'reading' => tr.ieltsReading,
      'writing' => tr.ieltsWriting,
      _ => tr.ieltsSpeaking,
    };

String lpMistakeName(AppLocalizations tr, String m) => switch (m) {
      'spelling' => tr.lp2MistakeSpelling,
      'plural' => tr.lp2MistakePlural,
      'word_limit' => tr.lp2MistakeWordLimit,
      'tfng' => tr.lp2MistakeTfng,
      'map' => tr.lp2MistakeMap,
      'matching' => tr.lp2MistakeMatching,
      'blank' => tr.lp2MistakeBlank,
      _ => tr.lp2MistakeOther,
    };

String lpMistakeTip(AppLocalizations tr, String m) => switch (m) {
      'spelling' => tr.lp2TipSpelling,
      'plural' => tr.lp2TipPlural,
      'word_limit' => tr.lp2TipWordLimit,
      'tfng' => tr.lp2TipTfng,
      'map' => tr.lp2TipMap,
      'matching' => tr.lp2TipMatching,
      'blank' => tr.lp2TipBlank,
      _ => tr.lp2TipOther,
    };

/// Icon names used by the Life English scenarios and vocabulary topics
/// (bundled files + lpcontent's extra content). Unknown names -> [fallback].
IconData lpIcon(String? name, IconData fallback) => switch (name) {
      // scenarios
      'flight' => Icons.flight_rounded,
      'assignment_ind' => Icons.assignment_ind_rounded,
      'storefront' => Icons.storefront_rounded,
      'subway' => Icons.subway_rounded,
      'directions_bus' => Icons.directions_bus_rounded,
      'signpost' => Icons.directions_rounded,
      'electric_rickshaw' || 'local_taxi' => Icons.local_taxi_rounded,
      'local_hospital' => Icons.local_hospital_rounded,
      'account_balance' => Icons.account_balance_rounded,
      'work' => Icons.work_rounded,
      'apartment' => Icons.apartment_rounded,
      'business_center' => Icons.business_center_rounded,
      'call' => Icons.call_rounded,
      'construction' => Icons.construction_rounded,
      'currency_exchange' => Icons.currency_exchange_rounded,
      'emergency' => Icons.emergency_rounded,
      'engineering' => Icons.engineering_rounded,
      'groups' => Icons.groups_rounded,
      'hotel' => Icons.hotel_rounded,
      'local_police' => Icons.local_police_rounded,
      'local_shipping' => Icons.local_shipping_rounded,
      'medical_services' => Icons.medical_services_rounded,
      'medication' => Icons.medication_rounded,
      'receipt_long' => Icons.receipt_long_rounded,
      'restaurant' => Icons.restaurant_rounded,
      'school' => Icons.school_rounded,
      'shopping_cart' => Icons.shopping_cart_rounded,
      'sim_card' => Icons.sim_card_rounded,
      'train' => Icons.train_rounded,
      // vocabulary topics
      'eco' => Icons.eco_rounded,
      'devices' => Icons.devices_rounded,
      'health_and_safety' => Icons.health_and_safety_rounded,
      'link' => Icons.link_rounded,
      'show_chart' => Icons.show_chart_rounded,
      'wb_sunny' => Icons.wb_sunny_rounded,
      'payments' => Icons.payments_rounded,
      'account_tree' => Icons.account_tree_rounded,
      'bolt' => Icons.bolt_rounded,
      'edit_note' => Icons.edit_note_rounded,
      'family_restroom' => Icons.family_restroom_rounded,
      'forum' => Icons.forum_rounded,
      'gavel' => Icons.gavel_rounded,
      'home' => Icons.home_rounded,
      'location_city' => Icons.location_city_rounded,
      'luggage' => Icons.luggage_rounded,
      'newspaper' => Icons.newspaper_rounded,
      'room_service' => Icons.room_service_rounded,
      'science' => Icons.science_rounded,
      'theater_comedy' => Icons.theater_comedy_rounded,
      'trending_up' => Icons.trending_up_rounded,
      _ => fallback,
    };

/// A finished result (mock / section): marks the task done when it appears
/// and lets a Free user see at most one interstitial when he LEAVES it —
/// never while a timed section, audio or recording runs (global caps:
/// max 4 a day, >= 800 s apart, never on day one, never on a paid plan).
class LpAdExit extends StatefulWidget {
  final Widget child;
  const LpAdExit({super.key, required this.child});
  @override
  State<LpAdExit> createState() => _LpAdExitState();
}

class _LpAdExitState extends State<LpAdExit> {
  @override
  void initState() {
    super.initState();
    AdExit.taskDone(AdExitPlacement.lessonAfterFinish);
  }

  @override
  void dispose() {
    AdExit.maybeShow(AdExitPlacement.lessonAfterFinish);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
