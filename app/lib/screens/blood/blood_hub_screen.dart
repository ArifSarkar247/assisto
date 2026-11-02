import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../api.dart';
import '../../blood_panel_api.dart';
import '../../l10n/app_localizations.dart';
import '../../state.dart';
import '../../theme.dart';
import '../../widgets/app_sheet.dart';
import 'blood_banks_screen.dart';
import 'blood_donor_setup_screen.dart';
import 'blood_request_detail_screen.dart';
import 'blood_request_form_screen.dart';
import 'blood_thread_screen.dart';
import 'blood_threads_screen.dart';
import 'blood_verify_screen.dart';
import 'bp_common.dart';

/// blood (owner 2 Nov) — Blood donor panel hub (route `blood_panel`, flag
/// `blood_donors`). Three tabs:
///   * Find donors — group chips, radius (default 5 km), "can donate now";
///     cards show first name, group, AREA + rounded km, eligibility, the
///     verified badge; contact = in-app message (number never shown unless
///     the donor made it public: then Call / SMS from the user's own phone);
///   * Requests — my urgent requests (responders inside) + requests near me
///     that I can answer ("I can donate");
///   * Me — become a donor (separate consent), eligibility + "available
///     again on", I donated today, pause, verify, leave.
/// FAB: urgent blood request. App bar: messages, blood banks.
class BloodHubScreen extends StatefulWidget {
  const BloodHubScreen({super.key, this.initialTab = 0, this.locate});
  final int initialTab;

  /// Test seam for the approximate location.
  final Future<({double lat, double lng})?> Function()? locate;

  @override
  State<BloodHubScreen> createState() => _BloodHubScreenState();
}

class _BloodHubScreenState extends State<BloodHubScreen> with SingleTickerProviderStateMixin {
  ApiClient get _api => context.read<AppState>().api;
  late final TabController _tabs =
      TabController(length: 3, vsync: this, initialIndex: widget.initialTab.clamp(0, 2));

  bool _loading = true;
  bool _failed = false;
  Map<String, dynamic> _cfg = const {};
  Map<String, dynamic> _reqs = const {};

  // search
  String _group = '';
  int _radius = 5;
  bool _nowOnly = false;
  String _district = '';
  ({double lat, double lng})? _here;
  bool _searching = false;
  bool _searched = false;
  String? _searchErr;
  List<Map<String, dynamic>> _donors = const [];

  Map<String, dynamic> get _me => bpMap(_cfg['me']);
  bool get _isDonor => _me['enabled'] == true;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void dispose() {
    _tabs.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _failed = false;
    });
    try {
      final c = await _api.bpConfig();
      final r = await _api.bpRequests();
      if (!mounted) return;
      setState(() {
        _cfg = c;
        _reqs = r;
        _loading = false;
        _radius = (c['default_radius'] as int?) ?? 5;
        final me = bpMap(c['me']);
        if (_district.isEmpty) _district = '${me['district'] ?? ''}';
        if (_group.isEmpty) _group = '${me['blood_group'] ?? ''}';
      });
      if (_district.isNotEmpty || _here != null) unawaited(_search());
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _failed = true;
      });
    }
  }

  Future<void> _reloadRequests() async {
    try {
      final r = await _api.bpRequests();
      final c = await _api.bpConfig();
      if (mounted) {
        setState(() {
          _reqs = r;
          _cfg = c;
        });
      }
    } catch (_) {
      if (mounted) _snack(AppLocalizations.of(context).bpLoadFailed);
    }
  }

  void _snack(String m) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));

  Future<void> _search() async {
    setState(() {
      _searching = true;
      _searchErr = null;
    });
    final q = <String, String>{
      if (_group.isNotEmpty) 'group': _group,
      'radius': '$_radius',
      if (_nowOnly) 'eligible_only': '1',
      if (_here != null) ...{'lat': '${bpCoarse(_here!.lat)}', 'lng': '${bpCoarse(_here!.lng)}'},
      if (_here == null && _district.isNotEmpty) 'district': _district,
    };
    try {
      final r = await _api.bpDonors(q);
      if (!mounted) return;
      setState(() {
        _donors = bpRows(r, 'donors');
        _searching = false;
        _searched = true;
      });
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _searching = false;
        _searched = true;
        _donors = const [];
        _searchErr = e.reason;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _searching = false;
        _searched = true;
        _donors = const [];
        _searchErr = 'error';
      });
    }
  }

  Future<void> _useHere() async {
    final t = AppLocalizations.of(context);
    final p = await (widget.locate ?? bpLocate)();
    if (!mounted) return;
    if (p == null) {
      _snack(t.bpLocationFailed);
      return;
    }
    setState(() => _here = p);
    unawaited(_search());
  }

  Future<void> _becomeDonor() async {
    final done = await Navigator.of(context).push<bool>(MaterialPageRoute(
        builder: (_) => BloodDonorSetupScreen(initial: _me, config: _cfg)));
    if (done == true && mounted) unawaited(_load());
  }

  Future<void> _newRequest() async {
    final id = await Navigator.of(context).push<int>(MaterialPageRoute(
        builder: (_) => BloodRequestFormScreen(config: _cfg, initialGroup: _group)));
    if (!mounted) return;
    if (id != null) {
      await Navigator.of(context)
          .push(MaterialPageRoute(builder: (_) => BloodRequestDetailScreen(requestId: id)));
    }
    if (mounted) unawaited(_reloadRequests());
  }

  Future<void> _openRequest(Map<String, dynamic> r) async {
    final id = r['id'];
    if (id is! int) return;
    await Navigator.of(context)
        .push(MaterialPageRoute(builder: (_) => BloodRequestDetailScreen(requestId: id)));
    if (mounted) unawaited(_reloadRequests());
  }

  Future<void> _message(Map<String, dynamic> d) async {
    final t = AppLocalizations.of(context);
    final ctrl = TextEditingController(text: t.bpMsgDefault);
    final text = await showAppSheet<String>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => Padding(
        padding: EdgeInsets.fromLTRB(
            Gap.lg, Gap.lg, Gap.lg, Gap.md + MediaQuery.of(ctx).viewInsets.bottom),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text(t.bpMsgTitle('${d['name'] ?? ''}'), style: Theme.of(ctx).textTheme.titleMedium),
          const SizedBox(height: Gap.xs),
          Text(t.bpMsgPrivacy, style: Theme.of(ctx).textTheme.bodySmall),
          const SizedBox(height: Gap.md),
          TextField(
            key: const ValueKey('bp-msg-field'),
            controller: ctrl,
            minLines: 2,
            maxLines: 5,
            maxLength: 600,
            decoration: InputDecoration(labelText: t.bpMsgLabel, border: const OutlineInputBorder()),
          ),
          const SizedBox(height: Gap.sm),
          ConstrainedBox(constraints: const BoxConstraints(minHeight: 52),
            child: FilledButton.icon(
              key: const ValueKey('bp-msg-send'),
              onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
              icon: const Icon(Icons.send_rounded),
              label: Text(t.bpSend),
            ),
          ),
        ]),
      ),
    );
    if (text == null || text.length < 2 || !mounted) return;
    try {
      final r = await _api.bpMessageDonor(d['id'] as int, text);
      if (!mounted) return;
      final th = bpMap(r['thread']);
      if (th['id'] is int) {
        await Navigator.of(context).push(MaterialPageRoute(
            builder: (_) => BloodThreadScreen(threadId: th['id'] as int)));
      } else {
        _snack(bpReason(t, r['reason'] as String?));
      }
    } catch (_) {
      if (mounted) _snack(t.bpErrGeneric);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    return Scaffold(
      appBar: AppBar(
        title: Text(t.bpTitle),
        actions: [
          IconButton(
            key: const ValueKey('bp-threads'),
            tooltip: t.bpMessages,
            onPressed: () => Navigator.of(context)
                .push(MaterialPageRoute(builder: (_) => const BloodThreadsScreen())),
            icon: const Icon(Icons.forum_outlined),
          ),
          IconButton(
            key: const ValueKey('bp-banks'),
            tooltip: t.bpBanksTitle,
            onPressed: () => Navigator.of(context)
                .push(MaterialPageRoute(builder: (_) => const BloodBanksScreen())),
            icon: const Icon(Icons.local_hospital_outlined),
          ),
        ],
        bottom: TabBar(
          controller: _tabs,
          isScrollable: true,
          tabs: [
            Tab(key: const ValueKey('bp-tab-find'), text: t.bpTabFind),
            Tab(key: const ValueKey('bp-tab-requests'), text: t.bpTabRequests),
            Tab(key: const ValueKey('bp-tab-me'), text: t.bpTabMe),
          ],
        ),
      ),
      floatingActionButton: _loading || _failed
          ? null
          : FloatingActionButton.extended(
              key: const ValueKey('bp-request-fab'),
              onPressed: _newRequest,
              icon: const Icon(Icons.bloodtype_rounded),
              label: Text(t.bpRequestCta),
            ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _failed
              ? Center(child: BpError(onRetry: _load))
              : TabBarView(controller: _tabs, children: [
                  RefreshIndicator(onRefresh: _search, child: _findTab(context)),
                  RefreshIndicator(onRefresh: _reloadRequests, child: _requestsTab(context)),
                  RefreshIndicator(onRefresh: _load, child: _meTab(context)),
                ]),
    );
  }

  EdgeInsets _pad(BuildContext context) =>
      withNavBarInset(context, const EdgeInsets.fromLTRB(Gap.lg, Gap.md, Gap.lg, 96));

  // ------------------------------------------------------------------ find
  Widget _findTab(BuildContext context) {
    final t = AppLocalizations.of(context);
    final text = Theme.of(context).textTheme;
    final districts = bpRows(_cfg, 'districts');
    final radii = ((_cfg['radius_choices'] as List?) ?? const [2, 5, 10, 25]).whereType<int>().toList();
    return ListView(
      padding: _pad(context),
      children: [
        Text(t.bpFindLead, style: text.bodyMedium),
        const SizedBox(height: Gap.md),
        Text(t.bpGroupPick, style: text.titleSmall),
        const SizedBox(height: Gap.xs),
        Wrap(spacing: Gap.sm, runSpacing: Gap.sm, children: [
          for (final g in kBloodGroups)
            ChoiceChip(
              key: ValueKey('bp-g-$g'),
              label: Text(g),
              selected: _group == g,
              onSelected: (on) {
                setState(() => _group = on ? g : '');
                unawaited(_search());
              },
            ),
        ]),
        const SizedBox(height: Gap.md),
        Text(t.bpRadius, style: text.titleSmall),
        const SizedBox(height: Gap.xs),
        Wrap(spacing: Gap.sm, runSpacing: Gap.sm, children: [
          for (final r in radii)
            ChoiceChip(
              key: ValueKey('bp-r-$r'),
              label: Text(bpD(context, t.bpKm(r))),
              selected: _radius == r,
              onSelected: (_) {
                setState(() => _radius = r);
                unawaited(_search());
              },
            ),
        ]),
        const SizedBox(height: Gap.md),
        Text(t.bpWhere, style: text.titleSmall),
        const SizedBox(height: Gap.xs),
        Wrap(spacing: Gap.sm, runSpacing: Gap.sm, crossAxisAlignment: WrapCrossAlignment.center, children: [
          ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 48),
            child: OutlinedButton.icon(
              key: const ValueKey('bp-here'),
              onPressed: _useHere,
              icon: Icon(_here != null ? Icons.my_location_rounded : Icons.location_searching_rounded),
              label: Text(_here != null ? t.bpHereOn : t.bpHere),
            ),
          ),
          DropdownButton<String>(
            key: const ValueKey('bp-district'),
            value: districts.any((d) => d['code'] == _district) ? _district : null,
            hint: Text(t.bpDistrict),
            items: [
              for (final d in districts)
                DropdownMenuItem(value: '${d['code']}', child: Text('${d['name']}')),
            ],
            onChanged: (v) {
              setState(() {
                _district = v ?? '';
                _here = null;
              });
              unawaited(_search());
            },
          ),
        ]),
        SwitchListTile(
          key: const ValueKey('bp-now-only'),
          contentPadding: EdgeInsets.zero,
          title: Text(t.bpNowOnly),
          value: _nowOnly,
          onChanged: (v) {
            setState(() => _nowOnly = v);
            unawaited(_search());
          },
        ),
        const SizedBox(height: Gap.sm),
        if (_searching) const Center(child: Padding(padding: EdgeInsets.all(Gap.lg), child: CircularProgressIndicator())),
        if (!_searching && !_searched)
          BpEmpty(
            icon: Icons.travel_explore_rounded,
            title: t.bpFindEmptyTitle,
            steps: [t.bpFindStep1, t.bpFindStep2, t.bpFindStep3],
            cta: t.bpHere,
            ctaKey: const ValueKey('bp-find-cta'),
            onCta: _useHere,
          ),
        if (!_searching && _searched && _searchErr != null)
          Text(bpReason(t, _searchErr == 'error' ? null : _searchErr)),
        if (!_searching && _searched && _searchErr == null && _donors.isEmpty)
          BpEmpty(
            icon: Icons.bloodtype_outlined,
            title: t.bpNoDonors,
            steps: [t.bpNoDonorsStep1, t.bpNoDonorsStep2, t.bpNoDonorsStep3],
            cta: t.bpRequestCta,
            ctaKey: const ValueKey('bp-nodonor-cta'),
            onCta: _newRequest,
          ),
        if (!_searching && _donors.isNotEmpty) ...[
          Text(bpD(context, t.bpFoundCount(_donors.length)), style: text.titleSmall),
          const SizedBox(height: Gap.sm),
          for (final d in _donors) _donorCard(context, d),
        ],
        const SizedBox(height: Gap.lg),
        const BpPrivacyCard(),
      ],
    );
  }

  Widget _donorCard(BuildContext context, Map<String, dynamic> d) {
    final t = AppLocalizations.of(context);
    final s = Theme.of(context).colorScheme;
    final phone = d['phone'] as String?;
    final km = d['km'];
    final area = [
      if ('${d['area_text'] ?? ''}'.isNotEmpty) '${d['area_text']}',
      if ('${d['district_name'] ?? ''}'.isNotEmpty) '${d['district_name']}',
      if (km is int) t.bpAboutKm(km),
    ].join(' · ');
    return Card(
      key: ValueKey('bp-donor-${d['id']}'),
      margin: const EdgeInsets.only(bottom: Gap.md),
      child: Padding(
        padding: const EdgeInsets.all(Gap.md),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            BpGroupBadge('${d['blood_group'] ?? ''}'),
            const SizedBox(width: Gap.md),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('${d['name'] ?? ''}', style: Theme.of(context).textTheme.titleMedium),
                if (d['verified'] == true) const BpVerifiedChip(),
                Text(bpD(context, area), style: TextStyle(color: s.onSurfaceVariant)),
                const SizedBox(height: Gap.xs),
                BpEligibility(eligible: d['eligible'] == true, nextDate: d['next_date'] as String?),
              ]),
            ),
          ]),
          const SizedBox(height: Gap.sm),
          Wrap(spacing: Gap.sm, runSpacing: Gap.sm, children: [
            ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 48),
              child: FilledButton.tonalIcon(
                key: ValueKey('bp-donor-msg-${d['id']}'),
                onPressed: () => _message(d),
                icon: const Icon(Icons.chat_bubble_outline_rounded),
                label: Text(t.bpMessage),
              ),
            ),
            if (phone != null && phone.isNotEmpty) ...[
              ConstrainedBox(
                constraints: const BoxConstraints(minHeight: 48),
                child: OutlinedButton.icon(
                  key: ValueKey('bp-donor-call-${d['id']}'),
                  onPressed: () => bpLaunch(context, 'tel', phone),
                  icon: const Icon(Icons.call_rounded),
                  label: Text(t.bpCall),
                ),
              ),
              ConstrainedBox(
                constraints: const BoxConstraints(minHeight: 48),
                child: OutlinedButton.icon(
                  key: ValueKey('bp-donor-sms-${d['id']}'),
                  onPressed: () => bpLaunch(context, 'sms', phone),
                  icon: const Icon(Icons.sms_outlined),
                  label: Text(t.bpSms),
                ),
              ),
            ],
          ]),
          if (phone == null || phone.isEmpty)
            Padding(
              padding: const EdgeInsets.only(top: Gap.xs),
              child: Text(t.bpNumberPrivate, style: Theme.of(context).textTheme.bodySmall),
            ),
        ]),
      ),
    );
  }

  // ------------------------------------------------------------------ requests
  Widget _requestsTab(BuildContext context) {
    final t = AppLocalizations.of(context);
    final text = Theme.of(context).textTheme;
    final mine = bpRows(_reqs, 'mine');
    final near = bpRows(_reqs, 'near');
    return ListView(
      padding: _pad(context),
      children: [
        if (mine.isEmpty && near.isEmpty)
          BpEmpty(
            icon: Icons.bloodtype_rounded,
            title: t.bpReqEmptyTitle,
            steps: [t.bpReqStep1, t.bpReqStep2, t.bpReqStep3],
            cta: t.bpRequestCta,
            ctaKey: const ValueKey('bp-req-empty-cta'),
            onCta: _newRequest,
          ),
        if (mine.isNotEmpty) ...[
          Text(t.bpMine, style: text.titleMedium),
          const SizedBox(height: Gap.sm),
          for (final r in mine) _requestTile(context, r, mine: true),
          const SizedBox(height: Gap.lg),
        ],
        if (near.isNotEmpty) ...[
          Text(t.bpNear, style: text.titleMedium),
          const SizedBox(height: Gap.sm),
          for (final r in near) _requestTile(context, r),
          const SizedBox(height: Gap.lg),
        ],
        if (!_isDonor && near.isEmpty)
          Card(
            margin: EdgeInsets.zero,
            child: ListTile(
              key: const ValueKey('bp-req-become'),
              minVerticalPadding: Gap.md,
              leading: const Icon(Icons.volunteer_activism_rounded),
              title: Text(t.bpBecomeTitle),
              subtitle: Text(t.bpNearNeedsDonor),
              trailing: const Icon(Icons.chevron_right_rounded),
              onTap: _becomeDonor,
            ),
          ),
      ],
    );
  }

  Widget _requestTile(BuildContext context, Map<String, dynamic> r, {bool mine = false}) {
    final t = AppLocalizations.of(context);
    final s = Theme.of(context).colorScheme;
    final n = bpRows(r, 'responders').length;
    final km = r['km'];
    final sub = <String>[
      '${r['hospital'] ?? ''}',
      if ('${r['area_text'] ?? ''}'.isNotEmpty) '${r['area_text']}',
      if (km is int) t.bpAboutKm(km),
    ].join(' · ');
    final status = mine
        ? '${bpStateLabel(t, '${r['state']}')} · ${t.bpResponders(n)}'
        : (r['my_response'] == 'can' ? t.bpYouSaidCan : t.bpNeededBy(bpWhen(context, r['needed_by'] as String?)));
    return Card(
      key: ValueKey('bp-req-${r['id']}'),
      margin: const EdgeInsets.only(bottom: Gap.md),
      child: ListTile(
        minVerticalPadding: Gap.md,
        leading: BpGroupBadge('${r['blood_group'] ?? ''}', size: 44),
        title: Text(bpD(context, t.bpUnits('${r['blood_group']}', r['units'] as int? ?? 1))),
        subtitle: Text(bpD(context, '$sub\n$status')),
        isThreeLine: true,
        trailing: Icon(Icons.chevron_right_rounded, color: s.onSurfaceVariant),
        onTap: () => _openRequest(r),
      ),
    );
  }

  // ------------------------------------------------------------------ me
  Widget _meTab(BuildContext context) {
    final t = AppLocalizations.of(context);
    final me = _me;
    if (!_isDonor) {
      return ListView(padding: _pad(context), children: [
        BpEmpty(
          icon: Icons.volunteer_activism_rounded,
          title: t.bpBecomeLead,
          steps: [t.bpBecomeStep1, t.bpBecomeStep2, t.bpBecomeStep3],
          cta: me['consented'] == true ? t.bpResume : t.bpBecomeTitle,
          ctaKey: const ValueKey('bp-become'),
          onCta: _becomeDonor,
        ),
        const SizedBox(height: Gap.lg),
        const BpPrivacyCard(),
      ]);
    }
    final text = Theme.of(context).textTheme;
    final ver = '${me['verification'] ?? ''}';
    return ListView(padding: _pad(context), children: [
      Card(
        margin: EdgeInsets.zero,
        child: Padding(
          padding: const EdgeInsets.all(Gap.lg),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Row(children: [
              BpGroupBadge('${me['blood_group'] ?? ''}', size: 56),
              const SizedBox(width: Gap.md),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(me['available'] == true ? t.bpListed : t.bpPaused, style: text.titleMedium),
                  if (me['verified'] == true) const BpVerifiedChip(),
                  Text(bpD(context, [
                    if ('${me['area_text'] ?? ''}'.isNotEmpty) '${me['area_text']}',
                    if ('${me['district_name'] ?? ''}'.isNotEmpty) '${me['district_name']}',
                  ].join(' · '))),
                ]),
              ),
            ]),
            const SizedBox(height: Gap.md),
            BpEligibility(eligible: me['eligible'] == true, nextDate: me['next_date'] as String?),
            if (me['last_donation'] != null)
              Text(t.bpLastOn(bpDate(context, me['last_donation'] as String?)),
                  style: text.bodySmall),
            const SizedBox(height: Gap.xs),
            Text(bpD(context, t.bpIntervalNote(me['interval_days'] as int? ?? 120)),
                style: text.bodySmall),
          ]),
        ),
      ),
      const SizedBox(height: Gap.md),
      ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 52),
        child: FilledButton.icon(
          key: const ValueKey('bp-donated'),
          onPressed: _donatedToday,
          icon: const Icon(Icons.favorite_rounded),
          label: Text(t.bpDonatedToday),
        ),
      ),
      const SizedBox(height: Gap.sm),
      _tile(Icons.edit_rounded, t.bpEdit, _becomeDonor, 'bp-edit'),
      _tile(me['available'] == true ? Icons.pause_circle_outline_rounded : Icons.play_circle_outline_rounded,
          me['available'] == true ? t.bpPause : t.bpResumeListing, _toggleAvailable, 'bp-pause',
          sub: me['available'] == true ? t.bpPauseSub : null),
      if (me['verified'] != true)
        _tile(Icons.verified_outlined, ver == 'pending' ? t.bpVerifyPending : t.bpVerifyCta,
            ver == 'pending' ? null : _verify, 'bp-verify',
            sub: ver == 'rejected' ? t.bpVerifyRejected : t.bpVerifySub),
      _tile(Icons.logout_rounded, t.bpLeave, _leave, 'bp-leave', sub: t.bpLeaveSub),
      const SizedBox(height: Gap.lg),
      const BpPrivacyCard(),
    ]);
  }

  Widget _tile(IconData icon, String title, VoidCallback? onTap, String key, {String? sub}) => Card(
        margin: const EdgeInsets.only(bottom: Gap.sm),
        child: ListTile(
          key: ValueKey(key),
          minVerticalPadding: Gap.md,
          leading: Icon(icon),
          title: Text(title),
          subtitle: sub == null ? null : Text(sub),
          trailing: onTap == null ? null : const Icon(Icons.chevron_right_rounded),
          onTap: onTap,
        ),
      );

  Future<void> _donatedToday() async {
    final t = AppLocalizations.of(context);
    final yes = await _confirm(t.bpDonatedConfirmTitle, t.bpDonatedConfirmBody, t.bpDonatedToday);
    if (yes != true || !mounted) return;
    try {
      final r = await _api.bpDonated();
      if (!mounted) return;
      _snack(r['ok'] == true ? t.bpDonatedThanks : bpReason(t, r['reason'] as String?));
    } catch (_) {
      if (mounted) _snack(t.bpErrGeneric);
    }
    unawaited(_load());
  }

  Future<void> _toggleAvailable() async {
    final t = AppLocalizations.of(context);
    try {
      final r = await _api.bpSaveMe({'available': _me['available'] != true});
      if (!mounted) return;
      if (r['ok'] != true) _snack(bpReason(t, r['reason'] as String?));
    } catch (_) {
      if (mounted) _snack(t.bpErrGeneric);
    }
    unawaited(_load());
  }

  Future<void> _verify() async {
    final sent = await Navigator.of(context)
        .push<bool>(MaterialPageRoute(builder: (_) => const BloodVerifyScreen()));
    if (sent == true && mounted) unawaited(_load());
  }

  Future<void> _leave() async {
    final t = AppLocalizations.of(context);
    final yes = await _confirm(t.bpLeaveConfirmTitle, t.bpLeaveConfirmBody, t.bpLeave);
    if (yes != true || !mounted) return;
    try {
      await _api.bpLeave();
      if (mounted) _snack(t.bpLeft);
    } catch (_) {
      if (mounted) _snack(t.bpErrGeneric);
    }
    unawaited(_load());
  }

  Future<bool?> _confirm(String title, String body, String ok) => showAppSheet<bool>(
        context: context,
        builder: (ctx) => Padding(
          padding: const EdgeInsets.fromLTRB(Gap.lg, Gap.lg, Gap.lg, Gap.md),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Text(title, style: Theme.of(ctx).textTheme.titleMedium),
            const SizedBox(height: Gap.sm),
            Text(body),
            const SizedBox(height: Gap.lg),
            ConstrainedBox(constraints: const BoxConstraints(minHeight: 52),
              child: FilledButton(
                key: const ValueKey('bp-confirm'),
                onPressed: () => Navigator.pop(ctx, true),
                child: Text(ok),
              ),
            ),
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(AppLocalizations.of(ctx).bpCancel)),
          ]),
        ),
      );
}
