import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';
import '../state.dart';
import '../theme.dart';
import '../l10n/app_localizations.dart';
import '../widgets/health_api.dart';
import '../widgets/health_birthday_card.dart';

/// Birthdays & memorable days — pre-reminders (configurable lead days) +
/// wish / greeting-card DRAFTS (bn/en). Benchmarked vs phone built-in
/// reminders: adds lead-day pre-reminders, annual recurrence, turning-age, and
/// ready-to-copy drafts. We NEVER auto-send — the user copies/shares a draft.
class BirthdaysScreen extends StatefulWidget {
  const BirthdaysScreen({super.key});
  @override
  State<BirthdaysScreen> createState() => _BirthdaysScreenState();
}

class _BirthdaysScreenState extends State<BirthdaysScreen> {
  List<Map<String, dynamic>> _upcoming = [];
  List<Map<String, dynamic>> _kinds = [];
  bool _loading = true;
  bool _error = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = false;
    });
    try {
      final r = await context.read<AppState>().api.birthdaysList();
      if (!mounted) return;
      setState(() {
        _upcoming = ((r['upcoming'] ?? []) as List).cast<Map<String, dynamic>>();
        _kinds = ((r['kinds'] ?? []) as List).cast<Map<String, dynamic>>();
      });
    } catch (_) {
      if (mounted) setState(() => _error = true);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _add() async {
    final created = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      builder: (_) => _AddBirthdaySheet(kinds: _kinds),
    );
    if (created == true) _load();
  }

  Future<void> _delete(Map<String, dynamic> occ) async {
    final id = occ['id'];
    if (id is! int) return;
    try {
      await context.read<AppState>().api.birthdayDelete(id);
    } catch (_) {}
    _load();
  }

  Future<void> _draft(Map<String, dynamic> occ) async {
    final t = AppLocalizations.of(context);
    Map<String, dynamic>? data;
    try {
      data = await context.read<AppState>().api.birthdayDrafts({
        'name': occ['name'],
        'kind': occ['kind'] ?? 'birthday',
        if (occ['turning_age'] != null) 'age': occ['turning_age'],
      });
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(t.birthdayDraftError)));
      }
      return;
    }
    if (!mounted || data == null) return;
    final drafts = ((data['drafts'] ?? []) as List).cast<Map<String, dynamic>>();
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (_) => _DraftsSheet(drafts: drafts),
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: Text(t.birthdaysTitle)),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _add,
        icon: const Icon(Icons.add),
        label: Text(t.birthdaysAdd),
      ),
      body: RefreshIndicator(
        onRefresh: _load,
        child: _loading
            ? const Center(child: CircularProgressIndicator())
            : _error
                ? ListView(children: [
                    Padding(
                      padding: const EdgeInsets.all(Gap.xl),
                      child: Column(children: [
                        Text(t.birthdaysLoadError, textAlign: TextAlign.center),
                        const SizedBox(height: Gap.md),
                        OutlinedButton.icon(
                          onPressed: _load,
                          icon: const Icon(Icons.refresh),
                          label: Text(t.retry),
                        ),
                      ]),
                    ),
                  ])
                : _upcoming.isEmpty
                    ? ListView(children: [
                        Padding(
                          padding: const EdgeInsets.only(top: 80),
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
                          ]),
                        ),
                      ])
                    : ListView(
                        padding: const EdgeInsets.all(Gap.lg),
                        children: [
                          for (final occ in _upcoming) ...[
                            HealthBirthdayCard(
                              occasion: occ,
                              onWish: () => _draft(occ),
                              onDelete: () => _delete(occ),
                            ),
                            const SizedBox(height: Gap.md),
                          ],
                          const SizedBox(height: 72),
                        ],
                      ),
      ),
    );
  }
}

/// Bottom sheet to add a new birthday / memorable day.
class _AddBirthdaySheet extends StatefulWidget {
  final List<Map<String, dynamic>> kinds;
  const _AddBirthdaySheet({required this.kinds});
  @override
  State<_AddBirthdaySheet> createState() => _AddBirthdaySheetState();
}

class _AddBirthdaySheetState extends State<_AddBirthdaySheet> {
  final _name = TextEditingController();
  String _kind = 'birthday';
  DateTime? _date;
  int _leadDays = 1;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    if (widget.kinds.isNotEmpty) _kind = widget.kinds.first['id'].toString();
  }

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Future<void> _pickDate() async {
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: _date ?? now,
      firstDate: DateTime(now.year - 120),
      lastDate: DateTime(now.year + 1, 12, 31),
    );
    if (picked != null) setState(() => _date = picked);
  }

  Future<void> _save() async {
    final t = AppLocalizations.of(context);
    if (_name.text.trim().isEmpty || _date == null) return;
    setState(() => _saving = true);
    final d = _date!;
    final iso = '${d.year.toString().padLeft(4, '0')}-'
        '${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
    final navigator = Navigator.of(context);
    final messenger = ScaffoldMessenger.of(context);
    try {
      await context.read<AppState>().api.birthdayCreate({
        'name': _name.text.trim(),
        'date': iso,
        'kind': _kind,
        'lead_days': _leadDays,
      });
      if (mounted) navigator.pop(true);
    } catch (_) {
      if (mounted) {
        setState(() => _saving = false);
        messenger.showSnackBar(SnackBar(content: Text(t.birthdaySaveError)));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final bottom = MediaQuery.of(context).viewInsets.bottom;
    return Padding(
      padding: EdgeInsets.fromLTRB(Gap.lg, Gap.lg, Gap.lg, Gap.lg + bottom),
      child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(t.birthdaysAdd, style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: Gap.lg),
        TextField(
          controller: _name,
          decoration: InputDecoration(labelText: t.birthdayNameLabel),
          textCapitalization: TextCapitalization.words,
        ),
        const SizedBox(height: Gap.md),
        // kind
        if (widget.kinds.isNotEmpty)
          Wrap(spacing: Gap.sm, children: [
            for (final k in widget.kinds)
              ChoiceChip(
                label: Text(k['label'].toString()),
                selected: _kind == k['id'],
                onSelected: (_) => setState(() => _kind = k['id'].toString()),
              ),
          ]),
        const SizedBox(height: Gap.md),
        OutlinedButton.icon(
          icon: const Icon(Icons.calendar_today, size: 18),
          label: Text(_date == null
              ? t.birthdayPickDate
              : t.birthdayDateChosen(
                  '${_date!.year}-${_date!.month.toString().padLeft(2, '0')}-${_date!.day.toString().padLeft(2, '0')}')),
          onPressed: _pickDate,
        ),
        const SizedBox(height: Gap.md),
        Text(t.birthdayLeadDaysLabel(_leadDays)),
        Slider(
          value: _leadDays.toDouble(),
          min: 0, max: 30, divisions: 30,
          label: '$_leadDays',
          onChanged: (v) => setState(() => _leadDays = v.round()),
        ),
        const SizedBox(height: Gap.md),
        SizedBox(
          width: double.infinity,
          child: FilledButton(
            onPressed: (_saving || _name.text.trim().isEmpty || _date == null) ? null : _save,
            child: _saving
                ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                : Text(t.save),
          ),
        ),
      ]),
    );
  }
}

/// Bottom sheet showing wish DRAFTS — copy or share (never auto-sent).
class _DraftsSheet extends StatelessWidget {
  final List<Map<String, dynamic>> drafts;
  const _DraftsSheet({required this.drafts});
  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.all(Gap.lg),
      child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(t.birthdayDraftsTitle, style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: Gap.xs),
        Text(t.birthdayDraftsSubtitle,
            style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant)),
        const SizedBox(height: Gap.md),
        for (final d in drafts) ...[
          Card(
            child: Padding(
              padding: const EdgeInsets.all(Gap.md),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(d['text'].toString(), style: const TextStyle(height: 1.4)),
                const SizedBox(height: Gap.sm),
                Row(mainAxisAlignment: MainAxisAlignment.end, children: [
                  TextButton.icon(
                    icon: const Icon(Icons.copy, size: 16),
                    label: Text(t.copy),
                    onPressed: () {
                      Clipboard.setData(ClipboardData(text: d['text'].toString()));
                      ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(content: Text(t.copied)));
                    },
                  ),
                  TextButton.icon(
                    icon: const Icon(Icons.share, size: 16),
                    label: Text(t.birthdayShare),
                    onPressed: () => Share.share(d['text'].toString()),
                  ),
                ]),
              ]),
            ),
          ),
          const SizedBox(height: Gap.sm),
        ],
      ]),
    );
  }
}
