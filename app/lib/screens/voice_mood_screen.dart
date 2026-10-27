import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../l10n/app_localizations.dart';
import '../theme.dart';
import '../widgets/health_disclaimer_bar.dart'; // healthfit
import '../widgets/skeleton.dart';
import '../services/action_feedback.dart' show openForUser;
import '../widgets/notif_models.dart' show notifLocalizeDigits;

/// VOICE MOOD SENSING — ADVANCED (#15, SPEC v2.1 §21).
///
/// An OPT-IN, ON-DEVICE wellness check-in. The user self-reports a mood and may
/// OPTIONALLY give themselves a "voice energy" rating after a short recording
/// they make and judge entirely on their own phone. NO audio ever leaves the
/// device, NO server is called, NO AI key is used. We keep a deterministic mood
/// log, draw a 7-day trend and offer gentle, NON-CLINICAL supportive nudges.
///
/// PRIVACY IS THE POINT. Everything is stored in on-device SharedPreferences —
/// a JSON list of rows that hold ONLY {mood, energy, date}. No audio, no
/// transcript. There is an explicit opt-in gate and a one-tap "delete all".
///
/// healthfit (owner decision 27 Oct): a WELLNESS JOURNAL AND RELAXATION feature
/// only — a daily mood + energy check-in with an optional one-line note, a
/// one-minute breathing break and everyday self-care ideas. Never a medical
/// or treatment service, never counselling; it never labels how you feel.
/// The "not medical advice" strip (HealthDisclaimerBar) is always visible.
/// When the recent trend looks persistently low we show ONE neutral line:
/// talk to someone you trust, and call 999 if you ever feel unsafe.
///
/// The on-screen math mirrors backend/core/logic/voice_mood.py VERBATIM
/// (fold-latest-wins, 7-day trend over logged days, persistently-low flag,
/// supportive suggestion keys). `today` is derived once so results are stable.
///
/// Honest states: opt-in gate · loading · welcome (opted-in, no logs) · trend.
/// ZERO Bangla literals — every string is an AppLocalizations getter.
class VoiceMoodScreen extends StatefulWidget {
  const VoiceMoodScreen({super.key});
  @override
  State<VoiceMoodScreen> createState() => _VoiceMoodScreenState();
}

// On-device keys (SharedPreferences). Nothing here is synced to a server.
const String _prefOptIn = 'mood_optin_v1';
const String _prefLogs = 'mood_logs_v1';

// Mood keys mirror voice_mood.MOODS (low→high). Score mirrors _MOOD_SCORE.
const List<String> _moods = ['low', 'down', 'ok', 'good', 'great'];
const Map<String, int> _moodScore = {
  'low': 1,
  'down': 2,
  'ok': 3,
  'good': 4,
  'great': 5,
};

class _VoiceMoodScreenState extends State<VoiceMoodScreen> {
  bool _loading = true;
  bool _optedIn = false;
  List<Map<String, dynamic>> _logs = [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  String get _todayIso => DateTime.now().toIso8601String().split('T').first;

  Future<void> _load() async {
    setState(() => _loading = true);
    final prefs = await SharedPreferences.getInstance();
    _optedIn = prefs.getBool(_prefOptIn) ?? false;
    _logs = _readLogs(prefs);
    if (mounted) setState(() => _loading = false);
  }

  List<Map<String, dynamic>> _readLogs(SharedPreferences prefs) {
    final raw = prefs.getString(_prefLogs);
    if (raw == null || raw.isEmpty) return [];
    try {
      final data = jsonDecode(raw);
      if (data is List) {
        return [
          for (final e in data)
            if (e is Map) Map<String, dynamic>.from(e),
        ];
      }
    } catch (_) {}
    return [];
  }

  Future<void> _saveLogs() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefLogs, jsonEncode(_logs));
  }

  void _toast(String m) => ScaffoldMessenger.of(context)
    ..clearSnackBars()
    ..showSnackBar(SnackBar(content: Text(m)));

  Future<void> _optIn() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_prefOptIn, true);
    if (mounted) setState(() => _optedIn = true);
  }

  Future<void> _turnOff() async {
    final tr = AppLocalizations.of(context);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(tr.moodTurnOffTitle),
        content: Text(tr.moodTurnOffBody),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(tr.cancel)),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(tr.moodTurnOffConfirm)),
        ],
      ),
    );
    if (ok != true) return;
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_prefOptIn);
    await prefs.remove(_prefLogs);
    if (mounted) {
      setState(() {
        _optedIn = false;
        _logs = [];
      });
      _toast(tr.moodDeletedAll);
    }
  }

  Future<void> _deleteAll() async {
    final tr = AppLocalizations.of(context);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(tr.moodDeleteTitle),
        content: Text(tr.moodDeleteBody),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(tr.cancel)),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(tr.delete)),
        ],
      ),
    );
    if (ok != true) return;
    setState(() => _logs = []);
    await _saveLogs();
    if (mounted) _toast(tr.moodDeletedAll);
  }

  Future<void> _checkIn() async {
    final tr = AppLocalizations.of(context);
    final result = await showModalBottomSheet<Map<String, dynamic>>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (ctx) => const _CheckInSheet(),
    );
    if (result == null) return;
    // One row per day: replace today's row if present (latest wins — mirrors
    // the backend fold). Keep a monotone client id for deterministic ordering.
    _logs.removeWhere(
        (r) => (r['date']?.toString().split('T').first) == _todayIso);
    _logs.add({
      'id': DateTime.now().millisecondsSinceEpoch,
      'mood': result['mood'],
      'energy': result['energy'],
      if ((result['note']?.toString() ?? '').isNotEmpty) 'note': result['note'],
      'date': _todayIso,
    });
    setState(() {});
    await _saveLogs();
    if (mounted) _toast(tr.moodSaved);
  }

  @override
  Widget build(BuildContext context) {
    final tr = AppLocalizations.of(context);
    if (_loading) {
      return Scaffold(
        bottomNavigationBar: const HealthDisclaimerBar(), // healthfit
          appBar: AppBar(title: Text(tr.moodJournalTitle)),
          body: const SkeletonList());
    }
    if (!_optedIn) return _OptInGate(onOptIn: _optIn);

    final trend = _Mood.trend(_logs, _todayIso);
    final todayRow = _todayRow();
    final suggestions = _Mood.suggestions(
        todayRow?['mood']?.toString() ?? (trend.lastMood ?? 'ok'),
        trend.persistentlyLow);

    return Scaffold(
        bottomNavigationBar: const HealthDisclaimerBar(), // healthfit
      appBar: AppBar(
        title: Text(tr.moodJournalTitle),
        actions: [
          PopupMenuButton<String>(
            onSelected: (v) {
              if (v == 'delete') _deleteAll();
              if (v == 'off') _turnOff();
            },
            itemBuilder: (ctx) => [
              PopupMenuItem(value: 'delete', child: Text(tr.moodDeleteAll)),
              PopupMenuItem(value: 'off', child: Text(tr.moodTurnOff)),
            ],
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _checkIn,
        icon: Icon(todayRow != null ? Icons.edit_rounded : Icons.mood_rounded),
        label: Text(
            todayRow != null ? tr.moodEditToday : tr.moodCheckIn),
      ),
      body: _logs.isEmpty
          ? ListView(children: [
              StateMessage(
                icon: Icons.self_improvement_rounded,
                tint: Brand.purple,
                title: tr.moodWelcomeTitle,
                message: tr.moodWelcomeBody,
                action: FilledButton.icon(
                  onPressed: _checkIn,
                  icon: const Icon(Icons.mood_rounded),
                  label: Text(tr.moodCheckIn),
                ),
              ),
              const Padding(
                padding: EdgeInsets.fromLTRB(Gap.lg, Gap.xl, Gap.lg, Gap.lg),
                child: Column(children: [_PrivacyNote(), _SafetyNote()]),
              ),
              const Padding(
                padding: EdgeInsets.fromLTRB(Gap.lg, 0, Gap.lg, 96),
                child: _BreathingCard(),
              ),
            ])
          : ListView(
              padding: const EdgeInsets.fromLTRB(Gap.md, Gap.md, Gap.md, 96),
              children: [
                _TodayCard(row: todayRow),
                const SizedBox(height: Gap.md),
                _TrendCard(trend: trend),
                const SizedBox(height: Gap.md),
                _SuggestionsCard(keys: suggestions),
                const SizedBox(height: Gap.md),
                const _BreathingCard(),
                if (trend.persistentlyLow) ...[
                  const SizedBox(height: Gap.md),
                  const _SupportCard(),
                ],
                const SizedBox(height: Gap.md),
                const _PrivacyNote(),
                const SizedBox(height: Gap.sm),
                const _SafetyNote(),
              ],
            ),
    );
  }

  Map<String, dynamic>? _todayRow() {
    for (final r in _logs) {
      if ((r['date']?.toString().split('T').first) == _todayIso) return r;
    }
    return null;
  }
}

// ======================= OPT-IN GATE =======================
class _OptInGate extends StatelessWidget {
  final VoidCallback onOptIn;
  const _OptInGate({required this.onOptIn});
  @override
  Widget build(BuildContext context) {
    final tr = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
        bottomNavigationBar: const HealthDisclaimerBar(), // healthfit
      appBar: AppBar(title: Text(tr.moodJournalTitle)),
      body: ListView(
        padding: const EdgeInsets.all(Gap.lg),
        children: [
          const SizedBox(height: Gap.sm),
          Icon(Icons.self_improvement_rounded, size: 56, color: Brand.purple),
          const SizedBox(height: Gap.md),
          Text(tr.moodOptInTitle,
              textAlign: TextAlign.center,
              style: Theme.of(context)
                  .textTheme
                  .titleLarge
                  ?.copyWith(fontWeight: FontWeight.w700)),
          const SizedBox(height: Gap.sm),
          Text(tr.moodOptInBody2,
              textAlign: TextAlign.center,
              style: TextStyle(color: scheme.onSurfaceVariant, height: 1.45)),
          const SizedBox(height: Gap.lg),
          _Bullet(icon: Icons.phonelink_lock_rounded, text: tr.moodOptInPoint1),
          _Bullet(icon: Icons.mic_off_rounded, text: tr.moodOptInPoint2),
          _Bullet(icon: Icons.delete_outline_rounded, text: tr.moodOptInPoint3),
          _Bullet(icon: Icons.spa_rounded, text: tr.moodOptInPoint4b),
          const SizedBox(height: Gap.lg),
          FilledButton.icon(
            onPressed: onOptIn,
            icon: const Icon(Icons.check_rounded),
            label: Text(tr.moodOptInButton),
          ),
          const SizedBox(height: Gap.md),
          const _SafetyNote(),
        ],
      ),
    );
  }
}

class _Bullet extends StatelessWidget {
  final IconData icon;
  final String text;
  const _Bullet({required this.icon, required this.text});
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: Gap.xs),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Icon(icon, size: 20, color: Brand.blue),
        const SizedBox(width: Gap.sm),
        Expanded(
          child: Text(text,
              style: TextStyle(color: scheme.onSurface, height: 1.4)),
        ),
      ]),
    );
  }
}

// ======================= TODAY =======================
class _TodayCard extends StatelessWidget {
  final Map<String, dynamic>? row;
  const _TodayCard({required this.row});
  @override
  Widget build(BuildContext context) {
    final tr = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final mood = row?['mood']?.toString();
    final energy = _Mood.intOf(row?['energy'], 0);
    final note = row?['note']?.toString() ?? '';
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(Gap.lg),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(tr.moodTodayTitle,
              style: Theme.of(context)
                  .textTheme
                  .titleMedium
                  ?.copyWith(fontWeight: FontWeight.w700)),
          const SizedBox(height: Gap.md),
          if (mood == null)
            Text(tr.moodNotLoggedYet,
                style: TextStyle(color: scheme.onSurfaceVariant))
          else
            Row(children: [
              Text(_Mood.emoji(mood), style: AType.displayLarge),
              const SizedBox(width: Gap.md),
              Expanded(
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(_moodLabel(tr, mood),
                          style: AType.titleLarge.copyWith(fontWeight: FontWeight.w700)),
                      if (energy > 0)
                        Text(tr.moodEnergyValue(/* (max, value) */ 5, energy),
                            style: AType.bodyMedium.copyWith(color: scheme.onSurfaceVariant)),
                      if (note.isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.only(top: Gap.xs),
                          child: Text(note,
                              style: AType.bodyMedium.copyWith(
                                  fontStyle: FontStyle.italic,
                                  color: scheme.onSurface)),
                        ),
                    ]),
              ),
            ]),
        ]),
      ),
    );
  }
}

// ======================= 7-DAY TREND =======================
class _TrendCard extends StatelessWidget {
  final _Trend trend;
  const _TrendCard({required this.trend});
  @override
  Widget build(BuildContext context) {
    final tr = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(Gap.lg),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(tr.moodTrend7d,
              style: Theme.of(context)
                  .textTheme
                  .titleMedium
                  ?.copyWith(fontWeight: FontWeight.w700)),
          const SizedBox(height: Gap.xs),
          Text(
            trend.loggedDays == 0
                ? tr.moodTrendEmpty
                : tr.moodTrendSummary(/* (days, logged) */ trend.days, trend.loggedDays),
            style: AType.bodySmall.copyWith(color: scheme.onSurfaceVariant),
          ),
          const SizedBox(height: Gap.md),
          SizedBox(
            height: 92,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                for (final d in trend.series)
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 3),
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.end,
                        children: [
                          if (d.logged)
                            Text(_Mood.emoji(d.mood!),
                                style: AType.bodyMedium),
                          const SizedBox(height: Gap.xxs),
                          Expanded(
                            child: Align(
                              alignment: Alignment.bottomCenter,
                              child: FractionallySizedBox(
                                heightFactor: d.logged
                                    ? (0.18 + 0.82 * (d.score / 5.0))
                                    : 0.06,
                                child: Container(
                                  decoration: BoxDecoration(
                                    color: d.logged
                                        ? _Mood.colorFor(d.score)
                                        : scheme.outlineVariant
                                            .withValues(alpha: 0.4),
                                    borderRadius: const BorderRadius.vertical(
                                        top: Radius.circular(Radii.xs)),
                                  ),
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(height: Gap.xs),
                          Text(_dayLetter(context, d.date),
                              style: AType.labelSmall.copyWith(color: scheme.onSurfaceVariant)),
                        ],
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ]),
      ),
    );
  }

  String _dayLetter(BuildContext context, String iso) {
    final d = DateTime.tryParse(iso);
    if (d == null) return '';
    final names = MaterialLocalizations.of(context).narrowWeekdays;
    return names[d.weekday % 7];
  }
}

// ======================= SUGGESTIONS =======================
class _SuggestionsCard extends StatelessWidget {
  final List<String> keys;
  const _SuggestionsCard({required this.keys});
  @override
  Widget build(BuildContext context) {
    final tr = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final visible = keys.where((k) => k != 'support').toList();
    if (visible.isEmpty) return const SizedBox.shrink();
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(Gap.lg),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Icon(Icons.favorite_outline_rounded, size: 18, color: Brand.purple),
            const SizedBox(width: Gap.sm),
            Text(tr.moodSuggestionsTitle,
                style: const TextStyle(fontWeight: FontWeight.w700)),
          ]),
          const SizedBox(height: Gap.sm),
          for (final k in visible)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 3),
              child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(Icons.circle_rounded, size: 7, color: scheme.onSurfaceVariant),
                    const SizedBox(width: Gap.sm),
                    Expanded(
                        child: Text(_suggestionText(tr, k),
                            style: TextStyle(
                                color: scheme.onSurface, height: 1.4))),
                  ]),
            ),
          const SizedBox(height: Gap.xs),
          Text(tr.moodSuggestionsNote,
              style: AType.bodySmall.copyWith(fontStyle: FontStyle.italic, color: scheme.onSurfaceVariant)),
        ]),
      ),
    );
  }
}

// ======================= SUPPORT (persistently-low only) =======================
// healthfit: a wellness journal never offers counselling or treatment. When
// the recent check-ins are persistently low it shows ONE neutral line: talk to
// someone you trust, and the national emergency number 999 if you feel unsafe
// (a safety resource, not a service we provide).
class _SupportCard extends StatelessWidget {
  const _SupportCard();
  @override
  Widget build(BuildContext context) {
    final tr = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    return Card(
      key: const Key('mood-support-card'),
      margin: EdgeInsets.zero,
      color: scheme.secondaryContainer,
      child: Padding(
        padding: const EdgeInsets.all(Gap.lg),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Icon(Icons.volunteer_activism_rounded, color: scheme.onSecondaryContainer),
          const SizedBox(width: Gap.md),
          Expanded(
            child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(tr.moodSupportTitle,
                      style: TextStyle(
                          fontWeight: FontWeight.w700,
                          color: scheme.onSecondaryContainer)),
                  const SizedBox(height: Gap.xs),
                  Text(tr.moodSupportBody,
                      style: TextStyle(
                          color: scheme.onSecondaryContainer, height: 1.4)),
                  const SizedBox(height: Gap.sm),
                  FilledButton.tonalIcon(
                    onPressed: () => openForUser(context, Uri.parse('tel:999'),
                        where: 'mood.call999'),
                    icon: const Icon(Icons.call_rounded),
                    label: Text(tr.moodCall999),
                  ),
                ]),
          ),
        ]),
      ),
    );
  }
}

// ======================= BREATHING / RELAXATION =======================
// healthfit: a one-minute paced-breathing break (4 s in, 4 s out). Pure
// relaxation — no measurement, nothing stored, nothing sent.
class _BreathingCard extends StatefulWidget {
  const _BreathingCard();
  @override
  State<_BreathingCard> createState() => _BreathingCardState();
}

class _BreathingCardState extends State<_BreathingCard> {
  static const int _total = 60; // seconds
  static const int _phase = 4; // seconds per in / out
  Timer? _timer;
  int _elapsed = 0;
  bool _done = false;

  bool get _running => _timer != null;

  void _start() {
    _timer?.cancel();
    setState(() {
      _elapsed = 0;
      _done = false;
    });
    _timer = Timer.periodic(const Duration(seconds: 1), (t) {
      if (!mounted) return t.cancel();
      setState(() {
        _elapsed++;
        if (_elapsed >= _total) {
          t.cancel();
          _timer = null;
          _done = true;
        }
      });
    });
  }

  void _stop() {
    _timer?.cancel();
    setState(() {
      _timer = null;
      _elapsed = 0;
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final tr = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final inhale = (_elapsed ~/ _phase).isEven;
    final left = _total - _elapsed;
    return Card(
      key: const Key('mood-breathing-card'),
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(Gap.lg),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Icon(Icons.air_rounded, size: 20, color: Brand.blue),
            const SizedBox(width: Gap.sm),
            Expanded(
              child: Text(tr.moodBreathTitle,
                  style: const TextStyle(fontWeight: FontWeight.w700)),
            ),
          ]),
          const SizedBox(height: Gap.xs),
          Text(_done ? tr.moodBreathDone : tr.moodBreathBody,
              style: TextStyle(color: scheme.onSurfaceVariant, height: 1.4)),
          if (_running) ...[
            const SizedBox(height: Gap.md),
            Center(
              child: AnimatedContainer(
                duration: const Duration(seconds: _phase),
                curve: Curves.easeInOut,
                width: inhale ? 120 : 64,
                height: inhale ? 120 : 64,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: Brand.blue.withValues(alpha: 0.18),
                  border: Border.all(color: Brand.blue, width: 2),
                ),
              ),
            ),
            const SizedBox(height: Gap.sm),
            Center(
              child: Text(inhale ? tr.moodBreathIn : tr.moodBreathOut,
                  textAlign: TextAlign.center,
                  style: AType.titleMedium.copyWith(fontWeight: FontWeight.w700)),
            ),
            Center(
              child: Text(tr.moodBreathLeft(notifLocalizeDigits(context, '$left')),
                  style: AType.bodySmall.copyWith(color: scheme.onSurfaceVariant)),
            ),
          ],
          const SizedBox(height: Gap.md),
          _running
              ? OutlinedButton.icon(
                  onPressed: _stop,
                  icon: const Icon(Icons.stop_rounded),
                  label: Text(tr.moodBreathStop))
              : FilledButton.tonalIcon(
                  onPressed: _start,
                  icon: const Icon(Icons.play_arrow_rounded),
                  label: Text(tr.moodBreathStart)),
        ]),
      ),
    );
  }
}

// ======================= PRIVACY + SAFETY NOTES =======================
class _PrivacyNote extends StatelessWidget {
  const _PrivacyNote();
  @override
  Widget build(BuildContext context) {
    final tr = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    return Card(
      margin: EdgeInsets.zero,
      color: scheme.surfaceContainerHighest,
      child: Padding(
        padding: const EdgeInsets.all(Gap.md),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Icon(Icons.phonelink_lock_rounded, size: 18, color: Brand.blue),
          const SizedBox(width: Gap.sm),
          Expanded(
            child: Text(tr.moodPrivacyNote,
                style:
                    AType.bodySmall.copyWith(color: scheme.onSurfaceVariant)),
          ),
        ]),
      ),
    );
  }
}

class _SafetyNote extends StatelessWidget {
  const _SafetyNote();
  @override
  Widget build(BuildContext context) {
    final tr = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    return Card(
      margin: EdgeInsets.zero,
      color: scheme.surfaceContainerHighest,
      child: Padding(
        padding: const EdgeInsets.all(Gap.md),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Icon(Icons.info_outline_rounded, size: 18, color: scheme.onSurfaceVariant),
          const SizedBox(width: Gap.sm),
          Expanded(
            child: Text(tr.moodSafetyNote2,
                style:
                    AType.bodySmall.copyWith(color: scheme.onSurfaceVariant)),
          ),
        ]),
      ),
    );
  }
}

// ======================= CHECK-IN SHEET =======================
class _CheckInSheet extends StatefulWidget {
  const _CheckInSheet();
  @override
  State<_CheckInSheet> createState() => _CheckInSheetState();
}

class _CheckInSheetState extends State<_CheckInSheet> {
  String? _mood;
  int _energy = 0; // 0 = not rated
  bool _voiceExpanded = false;
  // healthfit: an optional one-line journal note (kept on this phone only).
  final TextEditingController _note = TextEditingController();

  @override
  void dispose() {
    _note.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final tr = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final insets = MediaQuery.of(context).viewInsets.bottom;
    return Padding(
      padding: EdgeInsets.fromLTRB(Gap.lg, 0, Gap.lg, Gap.lg + insets),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(tr.moodCheckInTitle,
                style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: Gap.xs),
            Text(tr.moodPickPrompt,
                style: TextStyle(color: scheme.onSurfaceVariant)),
            const SizedBox(height: Gap.md),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                for (final m in _moods)
                  _MoodChoice(
                    emoji: _Mood.emoji(m),
                    label: _moodLabel(tr, m),
                    selected: _mood == m,
                    onTap: () => setState(() => _mood = m),
                  ),
              ],
            ),
            const SizedBox(height: Gap.lg),
            TextField(
              key: const Key('mood-note-field'),
              controller: _note,
              maxLength: 200,
              maxLines: 2,
              minLines: 1,
              textCapitalization: TextCapitalization.sentences,
              decoration: InputDecoration(
                labelText: tr.moodNoteLabel,
                hintText: tr.moodNoteHint,
                border: const OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: Gap.md),
            // Optional on-device voice-energy self-rating (collapsed by default).
            InkWell(
              onTap: () => setState(() => _voiceExpanded = !_voiceExpanded),
              child: Row(children: [
                Icon(Icons.mic_none_rounded, size: 20, color: Brand.blue),
                const SizedBox(width: Gap.sm),
                Expanded(
                  child: Text(tr.moodVoiceToggle,
                      style: const TextStyle(fontWeight: FontWeight.w600)),
                ),
                Icon(_voiceExpanded
                    ? Icons.expand_less_rounded
                    : Icons.expand_more_rounded),
              ]),
            ),
            if (_voiceExpanded) ...[
              const SizedBox(height: Gap.xs),
              Text(tr.moodVoiceExplain,
                  style: AType.bodySmall.copyWith(color: scheme.onSurfaceVariant)),
              const SizedBox(height: Gap.sm),
              Row(children: [
                Expanded(
                  child: Text(tr.moodEnergyLabel,
                      style: const TextStyle(fontWeight: FontWeight.w600)),
                ),
                Text(
                    _energy == 0
                        ? tr.moodEnergyUnrated
                        : tr.moodEnergyValue(/* (max, value) */ 5, _energy),
                    style:
                        AType.bodyMedium.copyWith(color: scheme.onSurfaceVariant)),
              ]),
              Slider(
                value: _energy.toDouble(),
                min: 0,
                max: 5,
                divisions: 5,
                label: _energy == 0
                    ? tr.moodEnergyUnrated
                    : _energy.toString(),
                onChanged: (v) => setState(() => _energy = v.round()),
              ),
              Text(tr.moodVoicePrivacy,
                  style: AType.bodySmall.copyWith(fontStyle: FontStyle.italic, color: scheme.onSurfaceVariant)),
            ],
            const SizedBox(height: Gap.lg),
            Row(children: [
              Expanded(
                child: OutlinedButton(
                    onPressed: () => Navigator.pop(context),
                    child: Text(tr.cancel)),
              ),
              const SizedBox(width: Gap.md),
              Expanded(
                child: FilledButton(
                  onPressed: _mood == null
                      ? null
                      : () => Navigator.pop(context,
                          {'mood': _mood, 'energy': _energy,
                           'note': _note.text.trim()}),
                  child: Text(tr.save),
                ),
              ),
            ]),
          ],
        ),
      ),
    );
  }
}

class _MoodChoice extends StatelessWidget {
  final String emoji;
  final String label;
  final bool selected;
  final VoidCallback onTap;
  const _MoodChoice(
      {required this.emoji,
      required this.label,
      required this.selected,
      required this.onTap});
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Expanded(
      child: InkWell(
        borderRadius: BorderRadius.circular(Radii.md),
        onTap: onTap,
        child: Container(
          margin: const EdgeInsets.symmetric(horizontal: Gap.xxs),
          padding: const EdgeInsets.symmetric(vertical: Gap.sm),
          decoration: BoxDecoration(
            color: selected
                ? Brand.purple.withValues(alpha: 0.16)
                : Colors.transparent,
            borderRadius: BorderRadius.circular(Radii.md),
            border: Border.all(
                color: selected ? Brand.purple : scheme.outlineVariant,
                width: selected ? 2 : 1),
          ),
          child: Column(children: [
            Text(emoji, style: AType.headlineMedium),
            const SizedBox(height: Gap.xxs),
            Text(label,
                textAlign: TextAlign.center,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: AType.labelSmall.copyWith(fontWeight: selected ? FontWeight.w700 : FontWeight.w500, color: selected ? Brand.purple : scheme.onSurfaceVariant)),
          ]),
        ),
      ),
    );
  }
}

// ======================= localised label helpers =======================
String _moodLabel(AppLocalizations tr, String mood) {
  switch (mood) {
    case 'low':
      return tr.moodLow;
    case 'down':
      return tr.moodDown;
    case 'ok':
      return tr.moodOk;
    case 'good':
      return tr.moodGood;
    case 'great':
      return tr.moodGreat;
    default:
      return tr.moodOk;
  }
}

String _suggestionText(AppLocalizations tr, String key) {
  switch (key) {
    case 'rest':
      return tr.moodSugRest;
    case 'reach_out':
      return tr.moodSugReachOut;
    case 'breathe':
      return tr.moodSugBreathe;
    case 'walk':
      return tr.moodSugWalk;
    case 'gratitude':
      return tr.moodSugGratitude;
    case 'keep_going':
      return tr.moodSugKeepGoing;
    case 'celebrate':
      return tr.moodSugCelebrate;
    case 'share':
      return tr.moodSugShare;
    default:
      return tr.moodSugRest;
  }
}

// ===================================================================
// _Mood — deterministic mirror of core/logic/voice_mood.py.
// fold-latest-wins, 7-day trend over logged days, persistently-low flag,
// supportive suggestion keys. No I/O, no live clock (today passed in).
// ===================================================================
class _TrendDay {
  final String date;
  final bool logged;
  final String? mood;
  final int energy;
  final int score;
  const _TrendDay(
      {required this.date,
      required this.logged,
      this.mood,
      required this.energy,
      required this.score});
}

class _Trend {
  final int days;
  final List<_TrendDay> series;
  final int loggedDays;
  final double avgScore;
  final double avgEnergy;
  final int lowStreak;
  final bool persistentlyLow;
  final String? lastMood;
  const _Trend({
    required this.days,
    required this.series,
    required this.loggedDays,
    required this.avgScore,
    required this.avgEnergy,
    required this.lowStreak,
    required this.persistentlyLow,
    required this.lastMood,
  });
}

class _Mood {
  static const int _lowMinLogged = 3;
  static const double _lowAvgThreshold = 2.0;

  static int intOf(dynamic v, int d) {
    final n = int.tryParse(v?.toString().split('.').first ?? '');
    return n ?? d;
  }

  static int _energy(dynamic v) {
    final n = intOf(v, 0);
    if (n < 0) return 0;
    if (n > 5) return 5;
    return n;
  }

  static String emoji(String mood) {
    switch (mood) {
      case 'low':
        return '😢';
      case 'down':
        return '😕';
      case 'ok':
        return '😐';
      case 'good':
        return '🙂';
      case 'great':
        return '😄';
      default:
        return '😐';
    }
  }

  static Color colorFor(int score) {
    if (score <= 1) return Brand.danger;
    if (score == 2) return Brand.warning;
    if (score == 3) return Brand.blue;
    if (score == 4) return Brand.cyan;
    return Brand.success;
  }

  /// Fold raw rows → one record per day, latest (highest id, then order) wins.
  static Map<String, Map<String, dynamic>> _foldByDay(
      List<Map<String, dynamic>> rows) {
    final indexed = [
      for (var i = 0; i < rows.length; i++) MapEntry(i, rows[i])
    ];
    indexed.sort((a, b) {
      final ia = a.value['id'] is int ? a.value['id'] as int : 1 << 52;
      final ib = b.value['id'] is int ? b.value['id'] as int : 1 << 52;
      if (ia != ib) return ia.compareTo(ib);
      return a.key.compareTo(b.key);
    });
    final days = <String, Map<String, dynamic>>{};
    for (final e in indexed) {
      final r = e.value;
      final mood = r['mood']?.toString();
      if (mood == null || !_moodScore.containsKey(mood)) continue;
      final iso = r['date']?.toString().split('T').first;
      if (iso == null || DateTime.tryParse(iso) == null) continue;
      days[iso] = {
        'mood': mood,
        'energy': _energy(r['energy']),
        'score': _moodScore[mood]!,
      };
    }
    return days;
  }

  static _Trend trend(List<Map<String, dynamic>> rows, String todayIso,
      {int days = 7}) {
    final t = DateTime.tryParse(todayIso);
    if (t == null) {
      return const _Trend(
          days: 7,
          series: [],
          loggedDays: 0,
          avgScore: 0,
          avgEnergy: 0,
          lowStreak: 0,
          persistentlyLow: false,
          lastMood: null);
    }
    final folded = _foldByDay(rows);
    final end = DateTime(t.year, t.month, t.day);
    final start = end.subtract(Duration(days: days - 1));
    final series = <_TrendDay>[];
    int logged = 0, sumScore = 0, sumEnergy = 0, energyDays = 0;
    String? lastMood;
    for (var i = 0; i < days; i++) {
      final d = start.add(Duration(days: i));
      final iso = d.toIso8601String().split('T').first;
      final rec = folded[iso];
      if (rec == null) {
        series.add(_TrendDay(date: iso, logged: false, energy: 0, score: 0));
      } else {
        final score = rec['score'] as int;
        final energy = rec['energy'] as int;
        series.add(_TrendDay(
            date: iso,
            logged: true,
            mood: rec['mood'] as String,
            energy: energy,
            score: score));
        logged++;
        sumScore += score;
        lastMood = rec['mood'] as String;
        if (energy > 0) {
          sumEnergy += energy;
          energyDays++;
        }
      }
    }
    // trailing low streak (newest backwards, consecutive logged days ≤ "down").
    int lowStreak = 0;
    for (final item in series.reversed) {
      if (!item.logged) break;
      if (item.score <= _moodScore['down']!) {
        lowStreak++;
      } else {
        break;
      }
    }
    final avgScore = logged == 0
        ? 0.0
        : double.parse((sumScore / logged).toStringAsFixed(2));
    final avgEnergy = energyDays == 0
        ? 0.0
        : double.parse((sumEnergy / energyDays).toStringAsFixed(2));
    final persistentlyLow =
        logged >= _lowMinLogged && avgScore <= _lowAvgThreshold;
    return _Trend(
      days: days,
      series: series,
      loggedDays: logged,
      avgScore: avgScore,
      avgEnergy: avgEnergy,
      lowStreak: lowStreak,
      persistentlyLow: persistentlyLow,
      lastMood: lastMood,
    );
  }

  static const Map<String, List<String>> _suggestionKeys = {
    'low': ['rest', 'reach_out', 'breathe', 'support'],
    'down': ['walk', 'reach_out', 'breathe'],
    'ok': ['walk', 'gratitude'],
    'good': ['keep_going', 'gratitude'],
    'great': ['celebrate', 'share'],
  };

  static List<String> suggestions(String mood, bool persistentlyLow) {
    final keys = List<String>.from(_suggestionKeys[mood] ?? _suggestionKeys['ok']!);
    if (persistentlyLow && !keys.contains('support')) keys.add('support');
    final seen = <String>{};
    return [
      for (final k in keys)
        if (seen.add(k)) k,
    ];
  }
}
