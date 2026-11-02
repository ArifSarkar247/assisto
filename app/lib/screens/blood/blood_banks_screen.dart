import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../blood_panel_api.dart';
import '../../l10n/app_localizations.dart';
import '../../messaging/link_open.dart';
import '../../state.dart';
import '../../theme.dart';
import '../../widgets/app_sheet.dart';
import 'bp_common.dart';

/// Test seam: replaces the server call (gallery / widget tests).
Future<Map<String, dynamic>> Function(Map<String, String> q)? bloodBanksLoaderOverride;

/// blood (owner 2 Nov) — blood banks: ONLY from an official / verified
/// published list, shown with its source + date. finish1: the owner imports
/// that list on the server (`manage.py import_blood_banks`, a named, linked,
/// dated source is mandatory); until then this is the honest "source
/// pending" state (no invented entries) with what the person can do now.
/// With a list: district filter, search, "near me" (a ~1 km point, only
/// after the in-app reason), the source link, and a call button per bank.
class BloodBanksScreen extends StatefulWidget {
  const BloodBanksScreen({super.key});

  @override
  State<BloodBanksScreen> createState() => _BloodBanksScreenState();
}

class _BloodBanksScreenState extends State<BloodBanksScreen> {
  bool _loading = true;
  bool _failed = false;
  Map<String, dynamic> _d = const {};
  String _district = '';
  String _q = '';
  ({double lat, double lng})? _here;
  Timer? _debounce;
  final _search = TextEditingController();

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _search.dispose();
    super.dispose();
  }

  Map<String, String> get _query => {
        if (_district.isNotEmpty) 'district': _district,
        if (_q.isNotEmpty) 'q': _q,
        if (_here != null) ...{
          // rounded to ~1 km on the phone before it leaves
          'lat': _here!.lat.toStringAsFixed(2),
          'lng': _here!.lng.toStringAsFixed(2),
        },
      };

  Future<void> _load() async {
    try {
      final q = _query;
      final r = bloodBanksLoaderOverride != null
          ? await bloodBanksLoaderOverride!(q)
          : await context.read<AppState>().api.bpBanks(q);
      if (!mounted) return;
      setState(() {
        _d = r;
        _loading = false;
        _failed = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _failed = true;
      });
    }
  }

  void _onSearch(String v) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 400), () {
      _q = v.trim();
      unawaited(_load());
    });
  }

  Future<void> _nearMe() async {
    if (_here != null) {
      setState(() => _here = null);
      unawaited(_load());
      return;
    }
    final p = await bpLocate(context);
    if (!mounted) return;
    if (p == null) {
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
          SnackBar(content: Text(AppLocalizations.of(context).bpLocationFailed)));
      return;
    }
    setState(() => _here = p);
    unawaited(_load());
  }

  void _showAll() {
    _search.clear();
    setState(() {
      _district = '';
      _q = '';
    });
    unawaited(_load());
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final pending = _d['source_pending'] != false;
    return Scaffold(
      appBar: AppBar(title: Text(t.bpBanksTitle)),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _failed
              ? Center(child: BpError(onRetry: _load))
              : ListView(
                  padding: withNavBarInset(context, const EdgeInsets.all(Gap.lg)),
                  children: pending ? _pending(t) : _list(context, t),
                ),
    );
  }

  List<Widget> _pending(AppLocalizations t) => [
        BpEmpty(
          icon: Icons.local_hospital_outlined,
          title: t.bpBanksPending,
          steps: [t.bpBanksStep1, t.bpBanksStep2, t.bpBanksStep3],
          cta: t.bpBanksFindDonors,
          ctaKey: const ValueKey('bp-banks-find'),
          onCta: () => Navigator.of(context).maybePop(),
        ),
      ];

  List<Widget> _list(BuildContext context, AppLocalizations t) {
    final text = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    final banks = bpRows(_d, 'banks');
    final src = bpMap(_d['source']);
    final districts = bpRows(_d, 'districts');
    final url = '${src['url'] ?? ''}';
    return [
      // where the list comes from — always above the list
      Card(
        key: const ValueKey('bp-banks-source'),
        margin: EdgeInsets.zero,
        child: Padding(
          padding: const EdgeInsets.all(Gap.md),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Text(bpD(context, t.bpBanksSource('${src['name'] ?? ''}', bpDate(context, src['date'] as String?))),
                style: text.titleSmall),
            const SizedBox(height: Gap.xs),
            Text(t.bpBanksCallFirst, style: text.bodySmall?.copyWith(color: scheme.onSurfaceVariant)),
            if (url.isNotEmpty)
              Align(
                alignment: AlignmentDirectional.centerStart,
                child: TextButton.icon(
                  key: const ValueKey('bp-banks-open-source'),
                  style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
                  onPressed: () => openLinkSafely(context, url),
                  icon: const Icon(Icons.open_in_new_rounded),
                  label: Text(t.bpBanksOpenSource),
                ),
              ),
          ]),
        ),
      ),
      const SizedBox(height: Gap.md),
      // filters: district, search, near me
      if (districts.isNotEmpty)
        KeyedSubtree(
          key: const ValueKey('bp-banks-district'),
          child: DropdownButtonFormField<String>(
          key: ValueKey('bp-banks-district-$_district'), // re-seeded by "show all"
          initialValue: _district,
          isExpanded: true,
          decoration: InputDecoration(labelText: t.bpDistrict),
          items: [
            DropdownMenuItem(value: '', child: Text(t.bpBanksAllDistricts)),
            for (final d in districts)
              DropdownMenuItem(value: '${d['code']}', child: Text('${d['name']}')),
          ],
          onChanged: (v) {
            setState(() => _district = v ?? '');
            unawaited(_load());
          },
        ),
        ),
      const SizedBox(height: Gap.sm),
      TextField(
        key: const ValueKey('bp-banks-search'),
        controller: _search,
        onChanged: _onSearch,
        textInputAction: TextInputAction.search,
        decoration: InputDecoration(
          prefixIcon: const Icon(Icons.search_rounded),
          labelText: t.bpBanksSearch,
        ),
      ),
      const SizedBox(height: Gap.sm),
      Align(
        alignment: AlignmentDirectional.centerStart,
        child: FilterChip(
          key: const ValueKey('bp-banks-near'),
          materialTapTargetSize: MaterialTapTargetSize.padded,
          selected: _here != null,
          avatar: const Icon(Icons.near_me_rounded, size: 18),
          label: Text(t.bpBanksNearMe),
          onSelected: (_) => unawaited(_nearMe()),
        ),
      ),
      const SizedBox(height: Gap.sm),
      Semantics(
        liveRegion: true,
        child: Text(bpD(context, t.bpBanksCount((_d['total'] as num?)?.toInt() ?? banks.length)),
            style: text.bodySmall),
      ),
      const SizedBox(height: Gap.sm),
      if (banks.isEmpty)
        Card(
          margin: EdgeInsets.zero,
          child: Padding(
            padding: const EdgeInsets.all(Gap.lg),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Text(t.bpBanksNoMatch, style: text.titleSmall, textAlign: TextAlign.center),
              const SizedBox(height: Gap.md),
              ConstrainedBox(
                constraints: const BoxConstraints(minHeight: 52),
                child: FilledButton(
                    key: const ValueKey('bp-banks-show-all'),
                    onPressed: _showAll,
                    child: Text(t.bpBanksShowAll)),
              ),
            ]),
          ),
        ),
      for (final b in banks) _bank(context, t, b),
    ];
  }

  Widget _bank(BuildContext context, AppLocalizations t, Map<String, dynamic> b) {
    final phone = '${b['phone'] ?? ''}';
    final first = phone.split(RegExp(r'[,/]')).first.trim();
    final km = (b['km'] as num?)?.toDouble();
    final lines = [
      [
        if ('${b['area'] ?? ''}'.isNotEmpty) '${b['area']}',
        if ('${b['district_name'] ?? ''}'.isNotEmpty) '${b['district_name']}',
      ].join(' · '),
      if ('${b['address'] ?? ''}'.isNotEmpty) '${b['address']}',
      if ('${b['hours'] ?? ''}'.isNotEmpty) '${b['hours']}',
      if (phone.isNotEmpty) phone,
      if (km != null)
        b['km_from_district'] == true
            ? t.bpBanksKmDistrict(km.toStringAsFixed(km < 10 ? 1 : 0))
            : t.bpBanksKm(km.toStringAsFixed(km < 10 ? 1 : 0)),
    ].where((x) => x.isNotEmpty).toList();
    return Card(
      margin: const EdgeInsets.only(bottom: Gap.sm),
      child: ListTile(
        minVerticalPadding: Gap.md,
        leading: const Icon(Icons.local_hospital_rounded),
        title: Text('${b['name'] ?? ''}'),
        subtitle: Text(bpD(context, lines.join('\n'))),
        trailing: first.isEmpty
            ? null
            : IconButton(
                tooltip: t.bpCall,
                constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
                onPressed: () => bpLaunch(context, 'tel', first),
                icon: const Icon(Icons.call_rounded),
              ),
      ),
    );
  }
}
