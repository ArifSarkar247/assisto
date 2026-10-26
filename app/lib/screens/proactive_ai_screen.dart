import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../l10n/app_localizations.dart';
import '../state.dart';
import '../theme.dart';
import '../api.dart';
import '../widgets/chatnav.dart';
import '../widgets/ladder_common.dart';
import '../widgets/skeleton.dart';
import '../services/error_kind.dart' show honestFailText; // qa2

/// PROACTIVE AI — ADVANCED (#6, SPEC v2.1 §21).
///
/// A proactive-suggestions digest. DETERMINISTIC rules run over signals the app
/// ALREADY collects (the server cross-module alert builder + reminders +
/// subscription renewals) and surface helpful, grouped nudges — a bill due in
/// two days, an expense not logged this week, a birthday coming. Each nudge is
/// dismissable and carries an honest "why am I seeing this" reason.
///
/// This builds ON TOP of the existing watch logic: the grouping / priority
/// rules mirror backend/core/logic/watch_feed.py, and the proactive reshaping
/// (urgency buckets, stable ids, dismissal epochs, reason keys) mirrors
/// backend/core/logic/proactive_ai.py VERBATIM. Nothing is invented: a source
/// with no real signal contributes nothing (honest empty state).
///
/// AI-personalised proactivity (re-ranking / re-phrasing from the user's own
/// patterns) is a DOCUMENTED key-gated seam (core.ai.generate) — not built
/// here. The current rule path carries ai_required=false and never fabricates.
///
/// Dismissals persist to the generic per-user collection 'proactive/dismissed'
/// as rows {sid (stable id), epoch}. A dismissal only hides the SAME epoch, so
/// a genuinely-new situation (a new due date, a fresh week) re-surfaces.
///
/// Honest states: loading · error · empty (nothing needs you) · digest.
/// ZERO Bangla literals — every string is an AppLocalizations getter.
class ProactiveAiScreen extends StatefulWidget {
  const ProactiveAiScreen({super.key});
  @override
  State<ProactiveAiScreen> createState() => _ProactiveAiScreenState();
}

const String _dismissedPath = 'proactive/dismissed';

// Urgency buckets mirror proactive_ai.URGENCIES.
const List<String> _urgencies = ['now', 'soon', 'fyi'];

class _ProactiveAiScreenState extends State<ProactiveAiScreen> {
  bool _loading = true, _error = false;
  Object? _failCause; // qa2: why it failed (5xx = our server, not the internet)
  List<_Sug> _signals = [];
  // dismissed rows: {id (backend row id), sid, epoch}
  List<Map<String, dynamic>> _dismissed = [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  ApiClient get _api => context.read<AppState>().api;

  void _toast(String m) => ScaffoldMessenger.of(context)
    ..clearSnackBars()
    ..showSnackBar(SnackBar(content: Text(m)));

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = false;
    });
    try {
      final signals = await _compose();
      List<Map<String, dynamic>> dismissed = const [];
      try {
        dismissed = await _api.listItems(_dismissedPath);
      } catch (_) {/* best-effort: dismissals are best-effort; empty is fine */}
      if (!mounted) return;
      setState(() {
        _signals = signals;
        _dismissed = dismissed;
        _loading = false;
      });
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = true;
          _failCause = e;
          _loading = false;
        });
      }
    }
  }

  /// Build the raw signal list from EXISTING read-only endpoints. Every fetch
  /// is best-effort: one failing source must not blank the digest.
  Future<List<_Sug>> _compose() async {
    final today = DateTime.now();
    DateTime dayOnly(DateTime d) => DateTime(d.year, d.month, d.day);
    int? daysFrom(String? iso) {
      if (iso == null) return null;
      final d = DateTime.tryParse(iso);
      if (d == null) return null;
      return dayOnly(d.toLocal()).difference(dayOnly(today)).inDays;
    }

    Future<T?> soft<T>(Future<T> f) async {
      try {
        return await f;
      } catch (_) {
        return null;
      }
    }

    final alerts = await soft(_api.alertsList());
    final reminders = await soft(_api.listItems('reminders'));
    final subs = await soft(_api.listItems('subscriptions'));

    final raw = <Map<String, dynamic>>[];

    // Server cross-module alerts already cover bills/loans/refill/family/
    // journey/budget/birthday. Map each to a generic proactive signal.
    for (final a in (alerts ?? const [])) {
      final type = (a['type'] ?? '').toString();
      final title = (a['title'] ?? a['text'] ?? '').toString();
      if (title.isEmpty) continue;
      raw.add({
        'kind': _normKind(type),
        'ref': 'alert:$type:$title',
        'title': title,
        'text': a['title'] != null ? (a['text']?.toString() ?? '') : '',
        'severity': _sev(a['severity']),
        'days_until': a['days_until'],
        'due': a['due']?.toString() ?? a['date']?.toString(),
        'module': _routeFor(_normKind(type)),
      });
    }

    // Reminders due today / overdue → "now".
    for (final r in (reminders ?? const [])) {
      if (r['done'] == true) continue;
      final days = daysFrom(r['due_at']?.toString());
      if (days == null || days > 0) continue;
      raw.add({
        'kind': 'reminder',
        'ref': 'reminder:${r['id']}',
        'title': (r['title'] ?? '').toString(),
        'severity': days < 0 ? 'high' : 'med',
        'days_until': days,
        'due': r['due_at']?.toString().split('T').first,
        'module': 'reminders',
      });
    }

    // Subscription renewals within the window → "soon"/"fyi".
    for (final s in (subs ?? const [])) {
      final days = daysFrom(s['next_due']?.toString());
      if (days == null || days < 0) continue;
      raw.add({
        'kind': 'subscription',
        'ref': 'sub:${s['id']}',
        'title': (s['name'] ?? '').toString(),
        'severity': 'low',
        'days_until': days,
        'due': s['next_due']?.toString().split('T').first,
        'module': 'subscriptions',
      });
    }

    return [for (final m in raw) _Sug.fromSignal(m)].whereType<_Sug>().toList();
  }

  // Normalise server alert types to proactive_ai reason kinds.
  String _normKind(String type) {
    switch (type) {
      case 'bill':
      case 'bill_due':
        return 'bill_due';
      case 'loan':
      case 'loan_due':
      case 'due':
        return 'loan_due';
      case 'refill':
      case 'medicine':
        return 'refill';
      case 'birthday':
        return 'birthday';
      case 'budget':
      case 'expense':
      case 'expense_gap':
        return 'expense_gap';
      case 'family':
      case 'family_alert':
        return 'family_alert';
      case 'journey':
      case 'safe_journey':
        return 'safe_journey';
      case 'subscription':
        return 'subscription';
      default:
        return type.isEmpty ? 'reminder' : type;
    }
  }

  String _routeFor(String kind) {
    switch (kind) {
      case 'bill_due':
      case 'loan_due':
      case 'expense_gap':
        return 'finance';
      case 'subscription':
        return 'subscriptions';
      case 'birthday':
        return 'birthdays';
      case 'refill':
      case 'family_alert':
        return 'family';
      case 'safe_journey':
        return 'journey_live';
      case 'reminder':
        return 'reminders';
      default:
        return '';
    }
  }

  String _sev(dynamic v) {
    final s = v?.toString() ?? 'med';
    if (s == 'high' || s == 'med' || s == 'low') return s;
    return 'med';
  }

  Future<void> _dismiss(_Sug s) async {
    final tr = AppLocalizations.of(context);
    // optimistic local hide
    setState(() => _dismissed = [
          ..._dismissed,
          {'sid': s.id, 'epoch': s.epoch}
        ]);
    try {
      await _api.createItem(_dismissedPath, {'sid': s.id, 'epoch': s.epoch});
      if (mounted) _toast(tr.proDismissed);
      await _load();
    } catch (_) {
      if (mounted) _toast(tr.saveFailed);
    }
  }

  Future<void> _whyAmISeeingThis(_Sug s) async {
    final tr = AppLocalizations.of(context);
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => Padding(
        padding: const EdgeInsets.fromLTRB(Gap.lg, 0, Gap.lg, Gap.xl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              Icon(Icons.help_outline_rounded, color: Brand.blue),
              const SizedBox(width: Gap.sm),
              Expanded(
                child: Text(tr.proWhyTitle,
                    style: Theme.of(ctx).textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w700)),
              ),
            ]),
            const SizedBox(height: Gap.md),
            Text(_reasonText(tr, s.reason),
                style: TextStyle(
                    height: 1.45,
                    color: Theme.of(ctx).colorScheme.onSurface)),
            const SizedBox(height: Gap.md),
            Text(tr.proWhyRuleNote,
                style: AType.bodySmall.copyWith(fontStyle: FontStyle.italic, color: Theme.of(ctx).colorScheme.onSurfaceVariant)),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final tr = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    if (_loading) {
      return Scaffold(
          appBar: AppBar(title: Text(tr.proTitle)),
          body: const SkeletonList());
    }
    if (_error) {
      return Scaffold(
        appBar: AppBar(title: Text(tr.proTitle)),
        body: StateMessage(
          icon: Icons.cloud_off_rounded,
          tint: scheme.error,
          title: tr.loadFailed,
          message: honestFailText(tr, _failCause, otherwise: tr.proLoadError),
          action: FilledButton.tonalIcon(
              onPressed: _load,
              icon: const Icon(Icons.refresh_rounded),
              label: Text(tr.retry)),
        ),
      );
    }

    final digest = _Pro.digest(_signals, _dismissed);
    if (!digest.hasAny) {
      return Scaffold(
        appBar: AppBar(title: Text(tr.proTitle)),
        body: RefreshIndicator(
          onRefresh: _load,
          child: ListView(children: [
            StateMessage(
              icon: Icons.check_circle_outline_rounded,
              tint: Brand.success,
              title: tr.proEmptyTitle,
              message: digest.dismissedCount > 0
                  ? tr.proEmptyDismissed(fmtInt(context, digest.dismissedCount))
                  : tr.proEmptyBody,
            ),
            const Padding(
              padding: EdgeInsets.fromLTRB(Gap.lg, Gap.xl, Gap.lg, Gap.lg),
              child: _HonestNote(),
            ),
          ]),
        ),
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: Text(tr.proTitle),
        actions: [
          IconButton(
              onPressed: _load,
              icon: const Icon(Icons.refresh_rounded),
              tooltip: tr.retry),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: _load,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(Gap.md, Gap.md, Gap.md, Gap.xl),
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(
                  horizontal: Gap.xs, vertical: Gap.xs),
              child: Text(tr.proIntro,
                  style:
                      AType.bodyMedium.copyWith(color: scheme.onSurfaceVariant)),
            ),
            const SizedBox(height: Gap.sm),
            for (final u in _urgencies)
              if (digest.buckets[u]!.isNotEmpty) ...[
                _GroupHeader(urgency: u, count: digest.buckets[u]!.length),
                for (final s in digest.buckets[u]!)
                  _NudgeCard(
                    sug: s,
                    onOpen: s.module.isEmpty
                        ? null
                        : () => ChatNav.push(context, s.module),
                    onDismiss: () => _dismiss(s),
                    onWhy: () => _whyAmISeeingThis(s),
                  ),
                const SizedBox(height: Gap.md),
              ],
            if (digest.dismissedCount > 0)
              Padding(
                padding: const EdgeInsets.all(Gap.sm),
                child: Text(tr.proHiddenCount(fmtInt(context, digest.dismissedCount)),
                    style: AType.bodySmall.copyWith(color: scheme.onSurfaceVariant)),
              ),
            const SizedBox(height: Gap.sm),
            const _HonestNote(),
          ],
        ),
      ),
    );
  }
}

// ======================= GROUP HEADER =======================
class _GroupHeader extends StatelessWidget {
  final String urgency;
  final int count;
  const _GroupHeader({required this.urgency, required this.count});
  @override
  Widget build(BuildContext context) {
    final tr = AppLocalizations.of(context);
    final (label, color, icon) = switch (urgency) {
      'now' => (tr.proUrgNow, Brand.danger, Icons.priority_high_rounded),
      'soon' => (tr.proUrgSoon, Brand.warning, Icons.schedule_rounded),
      _ => (tr.proUrgFyi, Brand.blue, Icons.lightbulb_outline_rounded),
    };
    return Padding(
      padding: const EdgeInsets.fromLTRB(Gap.xs, Gap.sm, Gap.xs, Gap.xs),
      child: Row(children: [
        Icon(icon, size: 18, color: color),
        const SizedBox(width: Gap.sm),
        Text(label,
            style: Theme.of(context)
                .textTheme
                .titleSmall
                ?.copyWith(fontWeight: FontWeight.w700, color: color)),
        const SizedBox(width: Gap.sm),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: Gap.sm, vertical: Gap.xxs),
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.14),
            borderRadius: BorderRadius.circular(Radii.pill),
          ),
          child: Text(fmtInt(context, count),
              style: AType.bodySmall.copyWith(fontFeatures: AFonts.tabular, fontWeight: FontWeight.w700, color: color)),
        ),
        const Spacer(),
      ]),
    );
  }
}

// ======================= NUDGE CARD =======================
class _NudgeCard extends StatelessWidget {
  final _Sug sug;
  final VoidCallback? onOpen;
  final VoidCallback onDismiss;
  final VoidCallback onWhy;
  const _NudgeCard(
      {required this.sug,
      required this.onOpen,
      required this.onDismiss,
      required this.onWhy});

  @override
  Widget build(BuildContext context) {
    final tr = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    return Card(
      margin: const EdgeInsets.only(bottom: Gap.sm),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(Gap.md, Gap.md, Gap.sm, Gap.sm),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Icon(_Pro.iconFor(sug.kind), size: 22, color: Brand.blue),
            const SizedBox(width: Gap.md),
            Expanded(
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(sug.title,
                        style: const TextStyle(
                            fontWeight: FontWeight.w700, height: 1.3)),
                    if (sug.text.isNotEmpty) ...[
                      const SizedBox(height: Gap.xxs),
                      Text(sug.text,
                          style: AType.bodyMedium.copyWith(color: scheme.onSurfaceVariant)),
                    ],
                    const SizedBox(height: Gap.xs),
                    Text(_whenText(context, tr, sug.daysUntil),
                        style: AType.bodySmall.copyWith(color: scheme.onSurfaceVariant)),
                  ]),
            ),
            IconButton(
              onPressed: onDismiss,
              icon: const Icon(Icons.close_rounded, size: 20),
              tooltip: tr.proDismiss, // a11y1: standard density = 48 dp target
            ),
          ]),
          Row(children: [
            TextButton.icon(
              onPressed: onWhy,
              icon: const Icon(Icons.help_outline_rounded, size: 16),
              label: Text(tr.proWhy),
              style: TextButton.styleFrom(
                  foregroundColor: scheme.onSurfaceVariant), // a11y1: 48 dp
            ),
            const Spacer(),
            if (onOpen != null)
              FilledButton.tonal(
                onPressed: onOpen,
                child: Text(tr.proOpen), // a11y1: theme 48 dp (no compact)
              ),
          ]),
        ]),
      ),
    );
  }

  String _whenText(BuildContext context, AppLocalizations tr, int? days) {
    if (days == null) return tr.proWhenNoDate;
    if (days < 0) return tr.proWhenOverdue(fmtInt(context, -days));
    if (days == 0) return tr.proWhenToday;
    if (days == 1) return tr.proWhenTomorrow;
    return tr.proWhenInDays(fmtInt(context, days));
  }
}

// ======================= HONEST NOTE =======================
class _HonestNote extends StatelessWidget {
  const _HonestNote();
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
          Icon(Icons.auto_awesome_rounded, size: 18, color: scheme.onSurfaceVariant),
          const SizedBox(width: Gap.sm),
          Expanded(
            child: Text(tr.proHonestNote,
                style:
                    AType.bodySmall.copyWith(color: scheme.onSurfaceVariant)),
          ),
        ]),
      ),
    );
  }
}

// ======================= reason localisation =======================
String _reasonText(AppLocalizations tr, String key) {
  switch (key) {
    case 'reason_bill_due':
      return tr.proReasonBillDue;
    case 'reason_loan_due':
      return tr.proReasonLoanDue;
    case 'reason_subscription':
      return tr.proReasonSubscription;
    case 'reason_birthday':
      return tr.proReasonBirthday;
    case 'reason_refill':
      return tr.proReasonRefill;
    case 'reason_expense_gap':
      return tr.proReasonExpenseGap;
    case 'reason_safe_journey':
      return tr.proReasonSafeJourney;
    case 'reason_family_alert':
      return tr.proReasonFamilyAlert;
    case 'reason_reminder':
      return tr.proReasonReminder;
    default:
      return tr.proReasonGeneric;
  }
}

// ===================================================================
// _Pro / _Sug — deterministic mirror of core/logic/proactive_ai.py.
// urgency buckets, stable ids, dismissal epochs, reason keys; built on the
// watch_feed grouping/priority rules. No I/O, no live clock (days_until given).
// ===================================================================
const int _upcomingWindowDays = 7;

const Set<String> _needsYouKinds = {
  'family_alert', 'scam', 'checkin_overdue', 'fall', 'sos',
  'business_needs_you', 'budget', 'safe_journey',
};

class _Sug {
  final String id;
  final String epoch;
  final String kind;
  final String title;
  final String text;
  final String module;
  final int? daysUntil;
  final String severity;
  final String group;
  final String urgency;
  final int priorityBase;
  final int priorityDue;
  final String reason;
  const _Sug({
    required this.id,
    required this.epoch,
    required this.kind,
    required this.title,
    required this.text,
    required this.module,
    required this.daysUntil,
    required this.severity,
    required this.group,
    required this.urgency,
    required this.priorityBase,
    required this.priorityDue,
    required this.reason,
  });

  static String _idOf(Map<String, dynamic> s) {
    final kind = (s['kind'] ?? 'info').toString();
    var ref = s['ref']?.toString() ?? '';
    if (ref.isEmpty) ref = (s['title'] ?? s['text'] ?? '').toString();
    return '$kind:$ref';
  }

  static String _epochOf(Map<String, dynamic> s) =>
      (s['due'] ?? s['week'] ?? '').toString();

  static String _group(String kind, int? days, String sev) {
    if (_needsYouKinds.contains(kind)) return 'needs_you';
    if (sev == 'high' && days != null && days <= 0) return 'needs_you';
    if (days == null) return 'today';
    if (days <= 0) return 'today';
    return 'upcoming';
  }

  static bool _inWindow(int? days) {
    if (days == null || days <= 0) return true;
    return days <= _upcomingWindowDays;
  }

  static _Sug? fromSignal(Map<String, dynamic> s) {
    final kind = (s['kind'] ?? 'info').toString();
    var sev = (s['severity'] ?? 'med').toString();
    if (sev != 'high' && sev != 'med' && sev != 'low') sev = 'med';
    int? days;
    final dv = s['days_until'];
    if (dv != null) days = int.tryParse(dv.toString().split('.').first);
    if (!_inWindow(days)) return null;
    final group = _group(kind, days, sev);
    const groupRank = {'needs_you': 0, 'today': 100, 'upcoming': 200};
    const sevRank = {'high': 0, 'med': 10, 'low': 20};
    final base = (groupRank[group] ?? 300) + (sevRank[sev] ?? 10);
    final du = days ?? 0;
    // group → urgency; low-severity upcoming is a gentle FYI.
    var urgency = switch (group) {
      'needs_you' => 'now',
      'today' => 'now',
      _ => 'soon',
    };
    if (urgency == 'soon' && sev == 'low') urgency = 'fyi';
    const reasonKeys = {
      'bill_due': 'reason_bill_due',
      'loan_due': 'reason_loan_due',
      'subscription': 'reason_subscription',
      'birthday': 'reason_birthday',
      'refill': 'reason_refill',
      'expense_gap': 'reason_expense_gap',
      'safe_journey': 'reason_safe_journey',
      'family_alert': 'reason_family_alert',
      'reminder': 'reason_reminder',
    };
    return _Sug(
      id: _idOf(s),
      epoch: _epochOf(s),
      kind: kind,
      title: (s['title'] ?? '').toString(),
      text: (s['text'] ?? '').toString(),
      module: (s['module'] ?? '').toString(),
      daysUntil: days,
      severity: sev,
      group: group,
      urgency: urgency,
      priorityBase: base,
      priorityDue: du,
      reason: reasonKeys[kind] ?? 'reason_generic',
    );
  }
}

class _Digest {
  final Map<String, List<_Sug>> buckets;
  final Map<String, int> counts;
  final int dismissedCount;
  final bool hasAny;
  const _Digest(
      {required this.buckets,
      required this.counts,
      required this.dismissedCount,
      required this.hasAny});
}

class _Pro {
  static bool _isDismissed(_Sug s, List<Map<String, dynamic>> dismissed) {
    for (final d in dismissed) {
      if (d['sid']?.toString() == s.id &&
          (d['epoch']?.toString() ?? '') == s.epoch) {
        return true;
      }
    }
    return false;
  }

  static _Digest digest(List<_Sug> signals, List<Map<String, dynamic>> dismissed) {
    final buckets = {for (final u in _urgencies) u: <_Sug>[]};
    var hidden = 0;
    for (final s in signals) {
      if (_isDismissed(s, dismissed)) {
        hidden++;
        continue;
      }
      buckets[s.urgency]!.add(s);
    }
    for (final u in buckets.keys) {
      buckets[u]!.sort((a, b) {
        if (a.priorityBase != b.priorityBase) {
          return a.priorityBase.compareTo(b.priorityBase);
        }
        if (a.priorityDue != b.priorityDue) {
          return a.priorityDue.compareTo(b.priorityDue);
        }
        return a.id.compareTo(b.id);
      });
    }
    final counts = {for (final u in _urgencies) u: buckets[u]!.length};
    final total = counts.values.fold(0, (a, b) => a + b);
    return _Digest(
      buckets: buckets,
      counts: {...counts, 'total': total},
      dismissedCount: hidden,
      hasAny: total > 0,
    );
  }

  static IconData iconFor(String kind) {
    switch (kind) {
      case 'bill_due':
      case 'loan_due':
        return Icons.receipt_long_rounded;
      case 'subscription':
        return Icons.autorenew_rounded;
      case 'birthday':
        return Icons.cake_rounded;
      case 'refill':
        return Icons.medication_rounded;
      case 'expense_gap':
        return Icons.account_balance_wallet_rounded;
      case 'family_alert':
        return Icons.family_restroom_rounded;
      case 'safe_journey':
        return Icons.directions_walk_rounded;
      case 'reminder':
        return Icons.alarm_rounded;
      default:
        return Icons.notifications_none_rounded;
    }
  }
}
