import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../state.dart';
import '../theme.dart';
import '../l10n/app_localizations.dart';
import '../notifications.dart';
import '../widgets/health_api.dart';
import '../widgets/bday_model.dart';
import '../widgets/bday_upcoming_card.dart';
import '../widgets/bday_add_sheet.dart';
import '../widgets/bday_wish_sheet.dart';

/// Birthdays & memorable days — ADVANCED (SPEC v2.1 §21).
///
/// Benchmarked vs the phone's built-in reminders, this adds: relation + notes +
/// yearly recurrence, CONFIGURABLE pre-reminders (1 week / 3 days / 1 day /
/// on-the-day), an upcoming list sorted by next occurrence with turning-age, a
/// "this week" highlight strip, wish + greeting-card DRAFTS with an AI wish that
/// is MOCK + KEY-GATED (honest marker), one-tap send (WhatsApp-share / SMS /
/// call), link-to-Circle + import-from-contacts, and honest empty / loading /
/// error / OFFLINE states. We NEVER auto-send — every wish is a draft the user
/// sends themselves.
///
/// Offline-first: the last good list is cached (SharedPreferences) and shown
/// instantly; a failed refresh keeps the cache + shows an offline banner rather
/// than a dead error page.
class BirthdaysScreen extends StatefulWidget {
  const BirthdaysScreen({super.key});
  @override
  State<BirthdaysScreen> createState() => _BirthdaysScreenState();
}

class _BirthdaysScreenState extends State<BirthdaysScreen> {
  static const _cacheKey = 'birthdays_cache_v1';

  List<Map<String, dynamic>> _upcoming = [];
  List<Map<String, dynamic>> _kinds = [];
  bool _loading = true;
  bool _error = false;
  bool _offline = false;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    final cached = await _readCache();
    if (cached != null && mounted) {
      setState(() {
        _upcoming = cached['upcoming'] ?? [];
        _kinds = cached['kinds'] ?? [];
        _loading = false;
      });
    }
    await _load(silent: cached != null);
  }

  Future<Map<String, List<Map<String, dynamic>>>?> _readCache() async {
    try {
      final raw = await Settings.getString(_cacheKey);
      if (raw == null || raw.isEmpty) return null;
      final m = jsonDecode(raw) as Map<String, dynamic>;
      return {
        'upcoming':
            ((m['upcoming'] ?? []) as List).cast<Map<String, dynamic>>(),
        'kinds': ((m['kinds'] ?? []) as List).cast<Map<String, dynamic>>(),
      };
    } catch (_) {
      return null;
    }
  }

  Future<void> _writeCache() async {
    try {
      await Settings.setString(
          _cacheKey, jsonEncode({'upcoming': _upcoming, 'kinds': _kinds}));
    } catch (_) {}
  }

  Future<void> _load({bool silent = false}) async {
    if (!silent) {
      setState(() {
        _loading = true;
        _error = false;
      });
    }
    try {
      final r = await context.read<AppState>().api.birthdaysList();
      if (!mounted) return;
      setState(() {
        _upcoming =
            ((r['upcoming'] ?? []) as List).cast<Map<String, dynamic>>();
        _kinds = ((r['kinds'] ?? []) as List).cast<Map<String, dynamic>>();
        _offline = false;
        _error = false;
      });
      await _writeCache();
    } catch (_) {
      if (!mounted) return;
      // Keep whatever we have (cache). Only hard-error if we have NOTHING.
      setState(() {
        if (_upcoming.isEmpty) {
          _error = true;
        } else {
          _offline = true;
        }
      });
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  // ---- add / edit ----

  Future<void> _addOrEdit({Map<String, dynamic>? existing}) async {
    if (_offline) {
      _snack(bStr(context, 'bOfflineAddBlocked'));
      return;
    }
    final api = context.read<AppState>().api;
    final body = await showModalBottomSheet<Map<String, dynamic>>(
      context: context,
      isScrollControlled: true,
      builder: (_) => BdayAddSheet(
        kinds: _kinds,
        existing: existing,
        onImportContacts: existing == null ? _importFromContacts : null,
      ),
    );
    if (body == null) return;
    try {
      if (existing != null) {
        // Clear the old occasion's reminders before re-creating (an edit is a
        // delete + re-create below, so leads/date may have changed).
        _cancelBdayReminders(existing);
        if (existing['id'] is int) {
          // No dedicated update endpoint in the shipped api surface: an edit is
          // a delete + re-create (both existing endpoints). Integrator MAY fold
          // this into a real PATCH later.
          await api.birthdayDelete(existing['id'] as int);
        }
      }
      await api.birthdayCreate(body);
      // Honour the chosen pre-reminders: schedule local notifications against
      // the (next) birthday date. Guarded — never blocks the save.
      if (mounted) _scheduleBdayReminders(body);
    } catch (_) {
      if (mounted) _snack(AppLocalizations.of(context).birthdaySaveError);
    }
    await _load(silent: true);
  }

  Future<void> _delete(Map<String, dynamic> occ) async {
    final id = occ['id'];
    if (id is! int) return;
    _cancelBdayReminders(occ);
    // optimistic
    setState(() => _upcoming.removeWhere((o) => o['id'] == id));
    await _writeCache();
    try {
      await context.read<AppState>().api.birthdayDelete(id);
    } catch (_) {}
    await _load(silent: true);
  }

  // ---- device reminders (pre-reminder lead-days -> local notifications) ----

  /// Stable notification id prefix for an occasion. Based on name+date (which
  /// survive the edit = delete + re-create cycle), so re-saving replaces rather
  /// than duplicates, and a far-future birthday still gets a stable id even
  /// though it may be outside the upcoming-list horizon.
  String _bdayBase(Map<String, dynamic> occ) {
    final name = '${occ['name'] ?? ''}'.trim();
    final dateIso = '${occ['date'] ?? ''}'.trim();
    return 'bday-$name|$dateIso';
  }

  /// Next annual occurrence of a yyyy-MM-dd birthday as a local DateTime at
  /// 09:00 (so the alert lands in the morning, not at midnight). Null on a bad
  /// date. Mirrors bDaysUntil's Feb-29 handling.
  DateTime? _nextBirthdayAt(String? iso) {
    final d = bParseDate(iso);
    if (d == null) return null;
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    DateTime occ(int year) {
      try {
        return DateTime(year, d.month, d.day, 9);
      } catch (_) {
        return DateTime(year, 2, 28, 9);
      }
    }

    var cand = occ(today.year);
    if (DateTime(cand.year, cand.month, cand.day).isBefore(today)) {
      cand = occ(today.year + 1);
    }
    return cand;
  }

  /// Schedule the occasion's chosen pre-reminders. For each lead-day the alert
  /// fires at (next birthday − leadDays) 09:00, with the stable id
  /// 'bday-<name|date>-<offset>'. Past fire-times are skipped. Fully guarded.
  void _scheduleBdayReminders(Map<String, dynamic> occ) {
    try {
      final next = _nextBirthdayAt('${occ['date'] ?? ''}');
      if (next == null) return;
      final name = '${occ['name'] ?? ''}'.trim();
      if (name.isEmpty) return;
      final t = AppLocalizations.of(context);
      final body = t.watchItemBirthday; // "Birthday coming up"
      final base = _bdayBase(occ);
      final now = DateTime.now();
      final raw = occ['lead_days'];
      final leads = <int>[];
      if (raw is List) {
        leads.addAll(raw.whereType<num>().map((x) => x.toInt()));
      } else if (raw is num) {
        leads.add(raw.toInt());
      }
      for (final lead in leads) {
        if (lead < 0) continue;
        final when = next.subtract(Duration(days: lead));
        if (!when.isAfter(now)) continue; // past — nothing to fire
        Notifications.schedule('$base-$lead', name, body, when);
      }
    } catch (_) {
      // best-effort only
    }
  }

  /// Drop every reminder we might have scheduled for an occasion (one per known
  /// pre-reminder option). Guarded — safe on delete and before re-scheduling.
  void _cancelBdayReminders(Map<String, dynamic> occ) {
    try {
      final base = _bdayBase(occ);
      for (final opt in kPreReminderOptions) {
        Notifications.cancel('$base-${opt.leadDays}');
      }
    } catch (_) {}
  }

  // ---- wish drafts (+ key-gated AI mock) ----

  Future<void> _wish(Map<String, dynamic> occ) async {
    final t = AppLocalizations.of(context);
    final api = context.read<AppState>().api;
    final Map<String, dynamic> data;
    try {
      data = await api.birthdayDrafts({
        'name': occ['name'],
        'kind': occ['kind'] ?? 'birthday',
        if (occ['turning_age'] != null) 'age': occ['turning_age'],
        if (occ['relation'] != null) 'relation': occ['relation'],
      });
    } catch (_) {
      if (mounted) _snack(t.birthdayDraftError);
      return;
    }
    if (!mounted) return;
    final drafts =
        ((data['drafts'] ?? []) as List).cast<Map<String, dynamic>>();
    final card = (data['card'] as Map?)?.cast<String, dynamic>();

    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (_) => BdayWishSheet(
        occasion: occ,
        drafts: drafts,
        card: card,
        // AI wish: the server's drafts endpoint already returns mock-safe text.
        // We surface it as the AI preview, honestly flagged mock (is_mock) until
        // a real key+provider is wired server-side (birthdays.ai_wish).
        onAiWish: (style) async {
          try {
            final r = await api.birthdayDrafts({
              'name': occ['name'],
              'kind': occ['kind'] ?? 'birthday',
              if (occ['turning_age'] != null) 'age': occ['turning_age'],
              if (occ['relation'] != null) 'relation': occ['relation'],
              'ai': true,
              'style': style,
            });
            // Prefer an explicit ai field; else pick the matching style draft.
            final ai = (r['ai'] as Map?)?.cast<String, dynamic>();
            if (ai != null) return ai;
            final list =
                ((r['drafts'] ?? []) as List).cast<Map<String, dynamic>>();
            final match = list.firstWhere(
              (d) => d['style'] == style,
              orElse: () => list.isNotEmpty ? list[1 % list.length] : {},
            );
            return {'text': match['text'] ?? '', 'is_mock': true};
          } catch (_) {
            return null;
          }
        },
      ),
    );
  }

  // ---- import from contacts (privacy: on-device) ----

  Future<void> _importFromContacts() async {
    // The actual on-device contact read is owned by the platform contacts
    // plugin / the app's existing hashed importer; here we open a lightweight
    // picker the integrator fills with device birthdays. We show an honest
    // empty state until that source is wired, so there is no dead end.
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (_) => Padding(
        padding: const EdgeInsets.all(Gap.lg),
        child:
            Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(bStr(context, 'bImportTitle'),
              style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: Gap.xs),
          Text(bStr(context, 'bImportSubtitle'),
              style: TextStyle(
                  fontSize: 12,
                  color: Theme.of(context).colorScheme.onSurfaceVariant)),
          const SizedBox(height: Gap.xl),
          Center(
            child: Column(children: [
              Icon(Icons.contacts_outlined,
                  size: 48,
                  color: Theme.of(context).colorScheme.onSurfaceVariant),
              const SizedBox(height: Gap.sm),
              Text(bStr(context, 'bImportNone'), textAlign: TextAlign.center),
            ]),
          ),
          const SizedBox(height: Gap.xl),
        ]),
      ),
    );
  }

  void _snack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(msg)));
  }

  // ---- UI ----

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(t.birthdaysTitle)),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _addOrEdit(),
        icon: const Icon(Icons.add),
        label: Text(t.birthdaysAdd),
      ),
      body: RefreshIndicator(
        onRefresh: () => _load(silent: true),
        child: _body(context),
      ),
    );
  }

  Widget _body(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;

    if (_loading && _upcoming.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error && _upcoming.isEmpty) {
      return ListView(children: [
        Padding(
          padding: const EdgeInsets.all(Gap.xl),
          child: Column(children: [
            const SizedBox(height: 60),
            Icon(Icons.cloud_off, size: 48, color: scheme.onSurfaceVariant),
            const SizedBox(height: Gap.md),
            Text(t.birthdaysLoadError, textAlign: TextAlign.center),
            const SizedBox(height: Gap.md),
            OutlinedButton.icon(
              onPressed: _load,
              icon: const Icon(Icons.refresh),
              label: Text(t.retry),
            ),
          ]),
        ),
      ]);
    }
    if (_upcoming.isEmpty) {
      return ListView(children: [
        Padding(
          padding: const EdgeInsets.only(top: 72),
          child: Column(children: [
            Icon(Icons.cake_outlined, size: 56, color: scheme.primary),
            const SizedBox(height: Gap.md),
            Text(t.birthdaysEmptyTitle,
                style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: Gap.sm),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: Gap.xl),
              child: Text(t.birthdaysEmptyBody,
                  textAlign: TextAlign.center,
                  style: TextStyle(color: scheme.onSurfaceVariant)),
            ),
            const SizedBox(height: Gap.lg),
            OutlinedButton.icon(
              onPressed: _importFromContacts,
              icon: const Icon(Icons.contacts_outlined),
              label: Text(bStr(context, 'bImportContacts')),
            ),
          ]),
        ),
      ]);
    }

    final thisWeek = _upcoming.where((o) => o['this_week'] == true).toList();
    final rest = _upcoming.where((o) => o['this_week'] != true).toList();

    return ListView(
      padding: const EdgeInsets.all(Gap.lg),
      children: [
        if (_offline) _offlineBanner(scheme),
        if (thisWeek.isNotEmpty) ...[
          _sectionHeader(context, bStr(context, 'bThisWeekHighlight'),
              Icons.local_fire_department_outlined),
          for (final occ in thisWeek) ...[
            _card(occ),
            const SizedBox(height: Gap.md),
          ],
          const SizedBox(height: Gap.sm),
        ],
        if (rest.isNotEmpty) ...[
          _sectionHeader(context, bStr(context, 'bUpcoming'),
              Icons.event_outlined),
          for (final occ in rest) ...[
            _card(occ),
            const SizedBox(height: Gap.md),
          ],
        ],
        const SizedBox(height: 72),
      ],
    );
  }

  Widget _card(Map<String, dynamic> occ) => BdayUpcomingCard(
        occasion: occ,
        onWish: () => _wish(occ),
        onEdit: () => _addOrEdit(existing: occ),
        onDelete: () => _delete(occ),
      );

  Widget _offlineBanner(ColorScheme scheme) => Container(
        margin: const EdgeInsets.only(bottom: Gap.md),
        padding: const EdgeInsets.all(Gap.md),
        decoration: BoxDecoration(
          color: scheme.secondaryContainer,
          borderRadius: BorderRadius.circular(10),
        ),
        child: Row(children: [
          Icon(Icons.cloud_off, size: 18, color: scheme.onSecondaryContainer),
          const SizedBox(width: Gap.sm),
          Expanded(
            child: Text(bStr(context, 'bOffline'),
                style: TextStyle(
                    fontSize: 12.5, color: scheme.onSecondaryContainer)),
          ),
        ]),
      );

  Widget _sectionHeader(BuildContext context, String text, IconData icon) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: Gap.sm, left: 2),
      child: Row(children: [
        Icon(icon, size: 16, color: scheme.primary),
        const SizedBox(width: 6),
        Text(text,
            style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w700,
                color: scheme.primary,
                letterSpacing: 0.3)),
      ]),
    );
  }
}
