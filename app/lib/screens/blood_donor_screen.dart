import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../l10n/app_localizations.dart';
import '../state.dart';
import '../theme.dart';
import '../widgets/skeleton.dart';

/// BLOOD-DONOR NETWORK — ADVANCED (#188, SPEC v2.1 §20).
///
/// A personal / community blood-donor registry: the user's own circle of
/// donors (blood group, area, last-donation date, availability). Register a
/// donor, search by blood group + area (or by compatibility for a recipient),
/// see donation eligibility (next-eligible date from the last donation using
/// the standard 90-day interval), and an honest "none found" state.
///
/// PRIVACY: a donor's phone is shown ONLY when that donor explicitly opted in
/// (share_contact). The default is NOT to share; search never leaks a number.
/// This is NOT a public directory and needs NO external key.
///
/// The on-screen math mirrors backend/core/logic/blood_donor.py VERBATIM
/// (90-day eligibility, ABO/Rh compatibility, privacy-safe cards) so results
/// are deterministic online or offline.
///
/// Honest states: welcome (first use) · loading · error · empty-search. ZERO
/// Bangla literals — every string is an AppLocalizations getter.
///
/// Persistence (generic api helpers, no api.dart edit):
///   listItems('blood/donors') → [{id, name, blood_group, area, phone,
///       availability, last_donation, share_contact}]
///   create/update/deleteItem on the same path; each row round-trips as
///   {id, ...data} through one flexible per-user JSON collection.
class BloodDonorScreen extends StatefulWidget {
  const BloodDonorScreen({super.key});
  @override
  State<BloodDonorScreen> createState() => _BloodDonorScreenState();
}

const String _donorsPath = 'blood/donors';

const List<String> _groups = ['A+', 'A-', 'B+', 'B-', 'AB+', 'AB-', 'O+', 'O-'];
const List<String> _availability = ['available', 'paused', 'unavailable'];

class _BloodDonorScreenState extends State<BloodDonorScreen> {
  List<Map<String, dynamic>> _donors = [];
  bool _loading = true, _error = false;

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
    final api = context.read<AppState>().api;
    try {
      _donors = await api.listItems(_donorsPath);
    } catch (_) {
      _error = true;
    }
    if (mounted) setState(() => _loading = false);
  }

  void _toast(String m) => ScaffoldMessenger.of(context)
    ..clearSnackBars()
    ..showSnackBar(SnackBar(content: Text(m)));

  @override
  Widget build(BuildContext context) {
    final tr = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    if (_loading) {
      return Scaffold(
          appBar: AppBar(title: Text(tr.bloodTitle)),
          body: const SkeletonList());
    }
    if (_error) {
      return Scaffold(
        appBar: AppBar(title: Text(tr.bloodTitle)),
        body: StateMessage(
          icon: Icons.cloud_off,
          tint: scheme.error,
          title: tr.loadFailed,
          message: tr.bloodLoadError,
          action: FilledButton.tonalIcon(
              onPressed: _load,
              icon: const Icon(Icons.refresh),
              label: Text(tr.retry)),
        ),
      );
    }
    if (_donors.isEmpty) {
      return Scaffold(
        appBar: AppBar(title: Text(tr.bloodTitle)),
        body: StateMessage(
          icon: Icons.bloodtype_outlined,
          tint: Brand.blue,
          title: tr.bloodWelcomeTitle,
          message: tr.bloodWelcomeBody,
          action: FilledButton.icon(
            onPressed: _addOrEdit,
            icon: const Icon(Icons.person_add_alt_1),
            label: Text(tr.bloodRegisterDonor),
          ),
        ),
      );
    }
    return DefaultTabController(
      length: 2,
      child: Scaffold(
        appBar: AppBar(
          title: Text(tr.bloodTitle),
          bottom: TabBar(tabs: [
            Tab(text: tr.bloodTabRegistry),
            Tab(text: tr.bloodTabSearch),
          ]),
        ),
        floatingActionButton: FloatingActionButton.extended(
          onPressed: _addOrEdit,
          icon: const Icon(Icons.person_add_alt_1),
          label: Text(tr.bloodRegisterDonor),
        ),
        body: TabBarView(children: [
          _RegistryTab(donors: _donors, onChanged: _load, onEdit: _addOrEdit),
          _SearchTab(donors: _donors),
        ]),
      ),
    );
  }

  Future<void> _addOrEdit([Map<String, dynamic>? existing]) async {
    final tr = AppLocalizations.of(context);
    final api = context.read<AppState>().api;
    final result = await showModalBottomSheet<Map<String, dynamic>>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (ctx) => _DonorForm(existing: existing),
    );
    if (result == null) return;
    try {
      if (existing != null && existing['id'] is int) {
        await api.updateItem(_donorsPath, existing['id'] as int, result);
      } else {
        await api.createItem(_donorsPath, result);
      }
      await _load();
      if (mounted) _toast(tr.bloodSaved);
    } catch (_) {
      if (mounted) _toast(tr.saveFailed);
    }
  }
}

// ======================= REGISTRY =======================
class _RegistryTab extends StatelessWidget {
  final List<Map<String, dynamic>> donors;
  final Future<void> Function() onChanged;
  final Future<void> Function([Map<String, dynamic>? existing]) onEdit;
  const _RegistryTab(
      {required this.donors, required this.onChanged, required this.onEdit});

  @override
  Widget build(BuildContext context) {
    final tr = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final cards = [for (final d in donors) _Blood.card(d)];
    final available =
        cards.where((c) => c.availability == 'available').length;
    final eligible = cards.where((c) => c.eligible).length;
    final sorted = [...cards]..sort(_Blood.registrySort);
    return RefreshIndicator(
      onRefresh: onChanged,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(Gap.md, Gap.md, Gap.md, 96),
        children: [
          Card(
            margin: EdgeInsets.zero,
            color: scheme.surfaceContainerHighest,
            child: Padding(
              padding: const EdgeInsets.all(Gap.md),
              child: Row(children: [
                _stat(context, '${cards.length}', tr.bloodStatTotal),
                _divider(scheme),
                _stat(context, '$available', tr.bloodStatAvailable),
                _divider(scheme),
                _stat(context, '$eligible', tr.bloodStatEligible),
              ]),
            ),
          ),
          const SizedBox(height: Gap.md),
          for (final c in sorted) _DonorCard(card: c, onEdit: onEdit),
          const SizedBox(height: Gap.md),
          _PrivacyNote(),
        ],
      ),
    );
  }

  Widget _stat(BuildContext context, String value, String label) => Expanded(
        child: Column(children: [
          Text(value,
              style: Theme.of(context)
                  .textTheme
                  .headlineSmall
                  ?.copyWith(fontWeight: FontWeight.bold, color: Brand.blue)),
          const SizedBox(height: 2),
          Text(label,
              textAlign: TextAlign.center,
              style: TextStyle(
                  fontSize: 11,
                  color: Theme.of(context).colorScheme.onSurfaceVariant)),
        ]),
      );

  Widget _divider(ColorScheme scheme) => Container(
      width: 1, height: 34, color: scheme.outlineVariant);
}

// ======================= SEARCH =======================
class _SearchTab extends StatefulWidget {
  final List<Map<String, dynamic>> donors;
  const _SearchTab({required this.donors});
  @override
  State<_SearchTab> createState() => _SearchTabState();
}

class _SearchTabState extends State<_SearchTab> {
  String? _group;
  final TextEditingController _area = TextEditingController();
  bool _onlyAvailable = false;
  bool _onlyEligible = false;

  @override
  void dispose() {
    _area.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final tr = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final results = _Blood.search(
      widget.donors,
      group: _group,
      area: _area.text,
      onlyAvailable: _onlyAvailable,
      onlyEligible: _onlyEligible,
    );
    return Column(children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(Gap.md, Gap.md, Gap.md, 0),
        child: Column(children: [
          DropdownButtonFormField<String?>(
            initialValue: _group,
            isExpanded: true,
            decoration: InputDecoration(
                labelText: tr.bloodSearchGroup,
                border: const OutlineInputBorder()),
            items: [
              DropdownMenuItem(value: null, child: Text(tr.bloodAnyGroup)),
              for (final g in _groups)
                DropdownMenuItem(value: g, child: Text(g)),
            ],
            onChanged: (v) => setState(() => _group = v),
          ),
          const SizedBox(height: Gap.sm),
          TextField(
            controller: _area,
            onChanged: (_) => setState(() {}),
            textInputAction: TextInputAction.search,
            decoration: InputDecoration(
              labelText: tr.bloodSearchArea,
              prefixIcon: const Icon(Icons.place_outlined),
              border: const OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: Gap.xs),
          Wrap(spacing: Gap.sm, children: [
            FilterChip(
              label: Text(tr.bloodFilterAvailable),
              selected: _onlyAvailable,
              onSelected: (v) => setState(() => _onlyAvailable = v),
            ),
            FilterChip(
              label: Text(tr.bloodFilterEligible),
              selected: _onlyEligible,
              onSelected: (v) => setState(() => _onlyEligible = v),
            ),
          ]),
        ]),
      ),
      const SizedBox(height: Gap.sm),
      Expanded(
        child: results.isEmpty
            ? StateMessage(
                icon: Icons.search_off,
                tint: scheme.onSurfaceVariant,
                title: tr.bloodNoneFoundTitle,
                message: tr.bloodNoneFoundBody,
              )
            : ListView(
                padding:
                    const EdgeInsets.fromLTRB(Gap.md, 0, Gap.md, 24),
                children: [
                  Padding(
                    padding: const EdgeInsets.only(bottom: Gap.sm),
                    child: Text(tr.bloodResultCount(results.length),
                        style: TextStyle(
                            fontSize: 12, color: scheme.onSurfaceVariant)),
                  ),
                  for (final c in results) _DonorCard(card: c),
                  const SizedBox(height: Gap.sm),
                  _PrivacyNote(),
                ],
              ),
      ),
    ]);
  }
}

// ======================= DONOR CARD =======================
class _DonorCard extends StatelessWidget {
  final _DonorView card;
  final Future<void> Function([Map<String, dynamic>? existing])? onEdit;
  const _DonorCard({required this.card, this.onEdit});

  @override
  Widget build(BuildContext context) {
    final tr = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final Color eligColor = card.eligible ? Brand.success : scheme.error;
    final String eligLabel = switch (card.eligibilityState) {
      'eligible' => tr.bloodEligibleNow,
      'resting' => tr.bloodRestingDays(card.daysLeft),
      _ => tr.bloodHistoryUnknown,
    };
    return Card(
      margin: const EdgeInsets.only(bottom: Gap.sm),
      child: Padding(
        padding: const EdgeInsets.all(Gap.md),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            CircleAvatar(
              backgroundColor: Brand.blue.withValues(alpha: 0.12),
              child: Text(card.group ?? '?',
                  style: const TextStyle(
                      color: Brand.blue,
                      fontWeight: FontWeight.bold,
                      fontSize: 13)),
            ),
            const SizedBox(width: Gap.md),
            Expanded(
              child:
                  Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(card.name.isEmpty ? '—' : card.name,
                    style: const TextStyle(fontWeight: FontWeight.w700),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis),
                if (card.area.isNotEmpty)
                  Text(card.area,
                      style:
                          TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis),
              ]),
            ),
            if (onEdit != null)
              IconButton(
                icon: const Icon(Icons.edit_outlined, size: 20),
                tooltip: tr.edit,
                onPressed: () => onEdit!(card.raw),
              ),
          ]),
          const SizedBox(height: Gap.sm),
          Wrap(spacing: Gap.sm, runSpacing: Gap.xs, children: [
            _chip(context, _availabilityIcon(card.availability),
                _availabilityLabel(tr, card.availability),
                card.availability == 'available'
                    ? Brand.success
                    : scheme.onSurfaceVariant),
            _chip(context, Icons.event_available_outlined, eligLabel,
                eligColor),
            if (card.nextDate != null && !card.eligible)
              _chip(context, Icons.calendar_today_outlined,
                  tr.bloodNextEligible(card.nextDate!), scheme.onSurfaceVariant),
          ]),
          const SizedBox(height: Gap.sm),
          _ContactRow(card: card),
        ]),
      ),
    );
  }

  Widget _chip(BuildContext context, IconData icon, String label, Color c) =>
      Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          color: c.withValues(alpha: 0.10),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(icon, size: 13, color: c),
          const SizedBox(width: 4),
          Text(label, style: TextStyle(fontSize: 11.5, color: c)),
        ]),
      );

  IconData _availabilityIcon(String a) => switch (a) {
        'available' => Icons.check_circle_outline,
        'paused' => Icons.pause_circle_outline,
        _ => Icons.do_not_disturb_on_outlined,
      };

  String _availabilityLabel(AppLocalizations tr, String a) => switch (a) {
        'available' => tr.bloodAvailable,
        'paused' => tr.bloodPaused,
        _ => tr.bloodUnavailable,
      };
}

// Contact row — honest "hidden" state unless the donor opted in.
class _ContactRow extends StatelessWidget {
  final _DonorView card;
  const _ContactRow({required this.card});

  @override
  Widget build(BuildContext context) {
    final tr = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    if (card.phone != null && card.phone!.isNotEmpty) {
      return Row(children: [
        Icon(Icons.phone_outlined, size: 16, color: Brand.blue),
        const SizedBox(width: 6),
        Expanded(
          child: Text(card.phone!,
              style: const TextStyle(
                  color: Brand.blue, fontWeight: FontWeight.w600)),
        ),
      ]);
    }
    return Row(children: [
      Icon(Icons.lock_outline, size: 15, color: scheme.onSurfaceVariant),
      const SizedBox(width: 6),
      Expanded(
        child: Text(tr.bloodContactHidden,
            style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant)),
      ),
    ]);
  }
}

class _PrivacyNote extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final tr = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    return Card(
      margin: EdgeInsets.zero,
      color: scheme.surfaceContainerHighest,
      child: Padding(
        padding: const EdgeInsets.all(Gap.md),
        child: Row(children: [
          Icon(Icons.shield_outlined, size: 18, color: scheme.onSurfaceVariant),
          const SizedBox(width: Gap.sm),
          Expanded(
            child: Text(tr.bloodPrivacyNote,
                style:
                    TextStyle(fontSize: 12.5, color: scheme.onSurfaceVariant)),
          ),
        ]),
      ),
    );
  }
}

// ======================= REGISTER / EDIT FORM =======================
class _DonorForm extends StatefulWidget {
  final Map<String, dynamic>? existing;
  const _DonorForm({this.existing});
  @override
  State<_DonorForm> createState() => _DonorFormState();
}

class _DonorFormState extends State<_DonorForm> {
  late final TextEditingController _name =
      TextEditingController(text: widget.existing?['name']?.toString() ?? '');
  late final TextEditingController _area =
      TextEditingController(text: widget.existing?['area']?.toString() ?? '');
  late final TextEditingController _phone =
      TextEditingController(text: widget.existing?['phone']?.toString() ?? '');
  late String? _group = _Blood.normGroup(widget.existing?['blood_group']);
  late String _avail = _normAvail(widget.existing?['availability']);
  late bool _share = widget.existing?['share_contact'] == true;
  DateTime? _lastDonation;

  static String _normAvail(dynamic v) {
    final s = (v ?? 'available').toString();
    return _availability.contains(s) ? s : 'available';
  }

  @override
  void initState() {
    super.initState();
    final ld = widget.existing?['last_donation'];
    if (ld != null) _lastDonation = DateTime.tryParse(ld.toString());
  }

  @override
  void dispose() {
    _name.dispose();
    _area.dispose();
    _phone.dispose();
    super.dispose();
  }

  bool get _valid {
    if (_name.text.trim().isEmpty) return false;
    if (_group == null) return false;
    if (_share && _phone.text.trim().isEmpty) return false;
    return true;
  }

  Map<String, dynamic> _result() => {
        'name': _name.text.trim(),
        'blood_group': _group,
        'area': _area.text.trim(),
        'phone': _phone.text.trim(),
        'availability': _avail,
        'share_contact': _share,
        if (_lastDonation != null)
          'last_donation':
              _lastDonation!.toIso8601String().split('T').first,
      };

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
            Text(
                widget.existing == null
                    ? tr.bloodRegisterDonor
                    : tr.bloodEditDonor,
                style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: Gap.lg),
            TextField(
              controller: _name,
              autofocus: widget.existing == null,
              textCapitalization: TextCapitalization.words,
              onChanged: (_) => setState(() {}),
              decoration: InputDecoration(
                  labelText: tr.bloodDonorName,
                  border: const OutlineInputBorder()),
            ),
            const SizedBox(height: Gap.md),
            Text(tr.bloodGroupLabel,
                style: Theme.of(context).textTheme.labelLarge),
            const SizedBox(height: Gap.xs),
            Wrap(spacing: Gap.sm, children: [
              for (final g in _groups)
                ChoiceChip(
                  label: Text(g),
                  selected: _group == g,
                  onSelected: (_) => setState(() => _group = g),
                ),
            ]),
            const SizedBox(height: Gap.md),
            TextField(
              controller: _area,
              textCapitalization: TextCapitalization.words,
              decoration: InputDecoration(
                  labelText: tr.bloodAreaLabel,
                  hintText: tr.bloodAreaHint,
                  prefixIcon: const Icon(Icons.place_outlined),
                  border: const OutlineInputBorder()),
            ),
            const SizedBox(height: Gap.md),
            // Last donation date (optional)
            InkWell(
              borderRadius: BorderRadius.circular(8),
              onTap: () async {
                final now = DateTime.now();
                final picked = await showDatePicker(
                  context: context,
                  initialDate: _lastDonation ?? now,
                  firstDate: DateTime(now.year - 3),
                  lastDate: now,
                );
                if (picked != null) setState(() => _lastDonation = picked);
              },
              child: InputDecorator(
                decoration: InputDecoration(
                    labelText: tr.bloodLastDonation,
                    prefixIcon: const Icon(Icons.event_outlined),
                    border: const OutlineInputBorder()),
                child: Row(children: [
                  Expanded(
                    child: Text(
                      _lastDonation == null
                          ? tr.bloodLastDonationNone
                          : _lastDonation!
                              .toIso8601String()
                              .split('T')
                              .first,
                    ),
                  ),
                  if (_lastDonation != null)
                    IconButton(
                      icon: const Icon(Icons.clear, size: 18),
                      onPressed: () => setState(() => _lastDonation = null),
                    ),
                ]),
              ),
            ),
            const SizedBox(height: Gap.md),
            Text(tr.bloodAvailabilityLabel,
                style: Theme.of(context).textTheme.labelLarge),
            const SizedBox(height: Gap.xs),
            Wrap(spacing: Gap.sm, children: [
              for (final a in _availability)
                ChoiceChip(
                  label: Text(switch (a) {
                    'available' => tr.bloodAvailable,
                    'paused' => tr.bloodPaused,
                    _ => tr.bloodUnavailable,
                  }),
                  selected: _avail == a,
                  onSelected: (_) => setState(() => _avail = a),
                ),
            ]),
            const SizedBox(height: Gap.md),
            // Privacy opt-in — OFF by default (conservative).
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              value: _share,
              onChanged: (v) => setState(() => _share = v),
              title: Text(tr.bloodShareContact),
              subtitle: Text(tr.bloodShareContactHint,
                  style: TextStyle(
                      fontSize: 12, color: scheme.onSurfaceVariant)),
            ),
            if (_share) ...[
              const SizedBox(height: Gap.xs),
              TextField(
                controller: _phone,
                keyboardType: TextInputType.phone,
                onChanged: (_) => setState(() {}),
                decoration: InputDecoration(
                    labelText: tr.bloodPhone,
                    prefixIcon: const Icon(Icons.phone_outlined),
                    border: const OutlineInputBorder()),
              ),
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
                  onPressed:
                      _valid ? () => Navigator.pop(context, _result()) : null,
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

// ===================================================================
// _Blood — deterministic mirror of backend/core/logic/blood_donor.py.
// 90-day eligibility, privacy-safe cards, search ranking. No I/O.
// ===================================================================
const int _donationIntervalDays = 90;

class _DonorView {
  final Map<String, dynamic> raw;
  final dynamic id;
  final String name;
  final String? group;
  final String area;
  final String availability;
  final bool eligible;
  final String eligibilityState; // eligible | resting | unknown
  final String? nextDate;
  final int daysLeft;
  final String? phone; // null unless opted in
  _DonorView({
    required this.raw,
    required this.id,
    required this.name,
    required this.group,
    required this.area,
    required this.availability,
    required this.eligible,
    required this.eligibilityState,
    required this.nextDate,
    required this.daysLeft,
    required this.phone,
  });
}

class _Blood {
  static String? normGroup(dynamic g) {
    if (g == null) return null;
    var s = g.toString().trim().toUpperCase().replaceAll(' ', '');
    s = s
        .replaceAll('POSITIVE', '+')
        .replaceAll('POS', '+')
        .replaceAll('NEGATIVE', '-')
        .replaceAll('NEG', '-');
    return _groups.contains(s) ? s : null;
  }

  static DateTime? _parse(dynamic v) {
    if (v == null || v == '') return null;
    final s = v.toString().split('T').first.split(' ').first;
    return DateTime.tryParse(s);
  }

  static _DonorView card(Map<String, dynamic> d, {DateTime? today}) {
    today ??= DateTime.now();
    final last = _parse(d['last_donation']);
    bool eligible;
    String state;
    String? nextDate;
    int daysLeft = 0;
    if (last == null) {
      eligible = true;
      state = 'unknown';
    } else {
      final next = last.add(const Duration(days: _donationIntervalDays));
      nextDate = next.toIso8601String().split('T').first;
      final dl = next.difference(DateTime(today.year, today.month, today.day)).inDays;
      if (dl <= 0) {
        eligible = true;
        state = 'eligible';
      } else {
        eligible = false;
        state = 'resting';
        daysLeft = dl;
      }
    }
    var avail = (d['availability'] ?? 'available').toString();
    if (!_availability.contains(avail)) avail = 'available';
    final shared = d['share_contact'] == true;
    return _DonorView(
      raw: d,
      id: d['id'],
      name: (d['name'] ?? '').toString().trim(),
      group: normGroup(d['blood_group']),
      area: (d['area'] ?? '').toString().trim(),
      availability: avail,
      eligible: eligible,
      eligibilityState: state,
      nextDate: nextDate,
      daysLeft: daysLeft,
      phone: shared ? (d['phone'] ?? '').toString().trim() : null,
    );
  }

  static int registrySort(_DonorView a, _DonorView b) {
    int tier(_DonorView c) => c.eligible && c.availability == 'available'
        ? 0
        : (c.eligible ? 1 : 2);
    final t = tier(a).compareTo(tier(b));
    if (t != 0) return t;
    final da = a.eligible ? 0 : a.daysLeft;
    final db = b.eligible ? 0 : b.daysLeft;
    if (da != db) return da.compareTo(db);
    return a.name.toLowerCase().compareTo(b.name.toLowerCase());
  }

  static List<_DonorView> search(
    List<Map<String, dynamic>> donors, {
    String? group,
    String? area,
    bool onlyAvailable = false,
    bool onlyEligible = false,
    DateTime? today,
  }) {
    final wantGroup = normGroup(group);
    final wantArea = (area ?? '').trim().toLowerCase();
    final out = <_DonorView>[];
    for (final d in donors) {
      final c = card(d, today: today);
      if (wantGroup != null && c.group != wantGroup) continue;
      if (wantArea.isNotEmpty && !c.area.toLowerCase().contains(wantArea)) {
        continue;
      }
      if (onlyAvailable && c.availability != 'available') continue;
      if (onlyEligible && !c.eligible) continue;
      out.add(c);
    }
    out.sort(registrySort);
    return out;
  }
}
