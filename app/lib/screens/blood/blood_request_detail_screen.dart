import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../api.dart';
import '../../blood_panel_api.dart';
import '../../l10n/app_localizations.dart';
import '../../state.dart';
import '../../theme.dart';
import '../../widgets/app_sheet.dart';
import '../../widgets/success_share.dart';
import 'blood_thread_screen.dart';
import 'bp_common.dart';

/// blood (owner 2 Nov) — one urgent request, by role.
///  * requester: reach (pushed / listed), the donors who said "I can donate"
///    (first name, group, area, rounded km, verified) with in-app message —
///    Call / SMS only for a number the donor made public; "Blood found"
///    (then, ONLY if the family agrees, the reusable thank-you share) and
///    "Close";
///  * donor: "I can donate" (server checks group + the
///    donation interval), "Can't this time", "I donated", message, report.
class BloodRequestDetailScreen extends StatefulWidget {
  const BloodRequestDetailScreen({super.key, required this.requestId});
  final int requestId;

  @override
  State<BloodRequestDetailScreen> createState() => _BloodRequestDetailScreenState();
}

class _BloodRequestDetailScreenState extends State<BloodRequestDetailScreen> {
  ApiClient get _api => context.read<AppState>().api;
  bool _loading = true;
  bool _failed = false;
  bool _busy = false;
  Map<String, dynamic> _r = const {};

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _failed = false;
    });
    try {
      final r = await _api.bpRequest(widget.requestId);
      if (!mounted) return;
      setState(() {
        _r = r;
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _failed = true;
      });
    }
  }

  void _snack(String m) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));

  Future<bool> _act(String action, [Map<String, dynamic> body = const {}, String? okMsg]) async {
    final t = AppLocalizations.of(context);
    setState(() => _busy = true);
    var ok = false;
    try {
      final r = await _api.bpAct(widget.requestId, action, body);
      if (!mounted) return false;
      setState(() => _busy = false);
      ok = r['ok'] == true;
      _snack(ok ? (okMsg ?? t.bpSaved) : bpReason(t, r['reason'] as String?));
    } catch (_) {
      if (!mounted) return false;
      setState(() => _busy = false);
      _snack(t.bpErrGeneric);
    }
    await _load();
    return ok;
  }

  Future<void> _openThread(int? id) async {
    if (id == null) return;
    await Navigator.of(context)
        .push(MaterialPageRoute(builder: (_) => BloodThreadScreen(threadId: id)));
    if (mounted) unawaited(_load());
  }

  Future<void> _found() async {
    final t = AppLocalizations.of(context);
    var share = false;
    final yes = await showAppSheet<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setS) => Padding(
          padding: const EdgeInsets.fromLTRB(Gap.lg, Gap.lg, Gap.lg, Gap.md),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Text(t.bpFoundTitle, style: Theme.of(ctx).textTheme.titleMedium),
            const SizedBox(height: Gap.sm),
            Text(t.bpFoundBody),
            SwitchListTile(
              key: const ValueKey('bp-found-share'),
              contentPadding: EdgeInsets.zero,
              title: Text(t.bpFoundShareAsk),
              subtitle: Text(t.bpFoundShareSub),
              value: share,
              onChanged: (v) => setS(() => share = v),
            ),
            const SizedBox(height: Gap.sm),
            ConstrainedBox(constraints: const BoxConstraints(minHeight: 52),
              child: FilledButton(
                key: const ValueKey('bp-found-confirm'),
                onPressed: () => Navigator.pop(ctx, true),
                child: Text(t.bpFound),
              ),
            ),
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(t.bpCancel)),
          ]),
        ),
      ),
    );
    if (yes != true || !mounted) return;
    final ok = await _act('found', const {}, t.bpFoundDone);
    if (!ok || !share || !mounted) return;
    await Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => SuccessShareScreen(
        title: t.bpShareTitle,
        cardHeadline: t.bpShareHeadline,
        initialText: t.bpShareText('${_r['blood_group'] ?? ''}'),
        allowPhoto: false,
      ),
    ));
  }

  Future<void> _close() async {
    final t = AppLocalizations.of(context);
    final yes = await _confirm(t.bpCloseTitle, t.bpCloseBody, t.bpClose);
    if (yes == true) await _act('close', const {}, t.bpClosed);
  }

  Future<void> _report() async {
    final t = AppLocalizations.of(context);
    String reason = 'fake';
    final note = TextEditingController();
    final yes = await showAppSheet<bool>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setS) => Padding(
          padding: EdgeInsets.fromLTRB(Gap.lg, Gap.lg, Gap.lg, Gap.md + MediaQuery.of(ctx).viewInsets.bottom),
          child: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Text(t.bpReportTitle, style: Theme.of(ctx).textTheme.titleMedium),
              const SizedBox(height: Gap.xs),
              Text(t.bpReportSub),
              for (final o in [
                ('fake', t.bpReportFake),
                ('selling', t.bpReportSelling),
                ('spam', t.bpReportSpam),
                ('harassment', t.bpReportHarass),
                ('other', t.bpReportOther),
              ])
                RadioListTile<String>(
                  key: ValueKey('bp-report-${o.$1}'),
                  contentPadding: EdgeInsets.zero,
                  title: Text(o.$2),
                  value: o.$1,
                  groupValue: reason,
                  onChanged: (v) => setS(() => reason = v ?? 'other'),
                ),
              TextField(
                controller: note,
                maxLength: 300,
                decoration: InputDecoration(labelText: t.bpReportNote, border: const OutlineInputBorder()),
              ),
              ConstrainedBox(constraints: const BoxConstraints(minHeight: 52),
                child: FilledButton(
                  key: const ValueKey('bp-report-send'),
                  onPressed: () => Navigator.pop(ctx, true),
                  child: Text(t.bpReportSend),
                ),
              ),
              TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(t.bpCancel)),
            ]),
          ),
        ),
      ),
    );
    if (yes == true && mounted) {
      await _act('report', {'reason': reason, 'note': note.text.trim()}, t.bpReported);
    }
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

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    return Scaffold(
      appBar: AppBar(
        title: Text(t.bpRequestTitle),
        actions: [
          if (!_loading && !_failed && _r['role'] == 'donor' && _r['reported'] != true)
            IconButton(
              key: const ValueKey('bp-report'),
              tooltip: t.bpReportTitle,
              onPressed: _report,
              icon: const Icon(Icons.flag_outlined),
            ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _failed
              ? Center(child: BpError(onRetry: _load))
              : RefreshIndicator(onRefresh: _load, child: _body(context)),
    );
  }

  Widget _body(BuildContext context) {
    final t = AppLocalizations.of(context);
    final s = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final r = _r;
    final mine = r['role'] == 'requester';
    final live = r['state'] == 'active' || r['state'] == 'hidden';
    final km = r['km'];
    return ListView(
      padding: withNavBarInset(context, const EdgeInsets.fromLTRB(Gap.lg, Gap.md, Gap.lg, Gap.xxl)),
      children: [
        Card(
          margin: EdgeInsets.zero,
          child: Padding(
            padding: const EdgeInsets.all(Gap.lg),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Row(children: [
                BpGroupBadge('${r['blood_group'] ?? ''}', size: 56),
                const SizedBox(width: Gap.md),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(bpD(context, t.bpUnits('${r['blood_group']}', r['units'] as int? ?? 1)),
                        style: text.titleLarge),
                    Text(bpStateLabel(t, '${r['state']}'),
                        style: TextStyle(color: live ? s.error : s.onSurfaceVariant, fontWeight: FontWeight.w600)),
                  ]),
                ),
              ]),
              const SizedBox(height: Gap.md),
              _line(Icons.local_hospital_outlined, '${r['hospital'] ?? ''}'),
              _line(Icons.place_outlined, bpD(context, [
                if ('${r['area_text'] ?? ''}'.isNotEmpty) '${r['area_text']}',
                if ('${r['district_name'] ?? ''}'.isNotEmpty) '${r['district_name']}',
                if (km is int) t.bpAboutKm(km),
              ].join(' · '))),
              _line(Icons.schedule_rounded, t.bpNeededBy(bpWhen(context, r['needed_by'] as String?))),
              if ('${r['note'] ?? ''}'.isNotEmpty) _line(Icons.notes_rounded, '${r['note']}'),
              if (!mine && '${r['requester_name'] ?? ''}'.isNotEmpty)
                _line(Icons.person_outline_rounded, t.bpAskedBy('${r['requester_name']}')),
            ]),
          ),
        ),
        const SizedBox(height: Gap.md),
        if (mine) ..._requesterPart(context, live) else ..._donorPart(context, live),
      ],
    );
  }

  Widget _line(IconData icon, String s) => s.trim().isEmpty
      ? const SizedBox.shrink()
      : Padding(
          padding: const EdgeInsets.only(bottom: Gap.xs),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Icon(icon, size: 20),
            const SizedBox(width: Gap.sm),
            Expanded(child: Text(s)),
          ]),
        );

  List<Widget> _requesterPart(BuildContext context, bool live) {
    final t = AppLocalizations.of(context);
    final text = Theme.of(context).textTheme;
    final resp = bpRows(_r, 'responders');
    return [
      if (_r['state'] == 'hidden')
        Card(
          margin: const EdgeInsets.only(bottom: Gap.md),
          color: Theme.of(context).colorScheme.errorContainer,
          child: Padding(padding: const EdgeInsets.all(Gap.md), child: Text(t.bpHiddenNote)),
        ),
      Text(bpD(context, t.bpReach(_r['pushed'] as int? ?? 0, _r['listed'] as int? ?? 0)), style: text.bodyMedium),
      const SizedBox(height: Gap.md),
      Text(t.bpRespondersTitle, style: text.titleMedium),
      const SizedBox(height: Gap.sm),
      if (resp.isEmpty)
        Text(live ? t.bpNoRespondersYet : t.bpNoResponders),
      for (final d in resp) _responder(context, d),
      const SizedBox(height: Gap.lg),
      if (live) ...[
        ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 56),
          child: FilledButton.icon(
            key: const ValueKey('bp-found'),
            style: FilledButton.styleFrom(backgroundColor: Brand.successFill, foregroundColor: Colors.white),
            onPressed: _busy ? null : _found,
            icon: const Icon(Icons.check_circle_rounded),
            label: Text(t.bpFound),
          ),
        ),
        const SizedBox(height: Gap.sm),
        ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 48),
          child: OutlinedButton(
            key: const ValueKey('bp-close'),
            onPressed: _busy ? null : _close,
            child: Text(t.bpClose),
          ),
        ),
      ],
      if (_r['state'] == 'fulfilled')
        ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 48),
          child: OutlinedButton.icon(
            key: const ValueKey('bp-share-again'),
            onPressed: () => Navigator.of(context).push(MaterialPageRoute(
              builder: (_) => SuccessShareScreen(
                title: t.bpShareTitle,
                cardHeadline: t.bpShareHeadline,
                initialText: t.bpShareText('${_r['blood_group'] ?? ''}'),
                allowPhoto: false,
              ),
            )),
            icon: const Icon(Icons.favorite_border_rounded),
            label: Text(t.bpShareTitle),
          ),
        ),
    ];
  }

  Widget _responder(BuildContext context, Map<String, dynamic> d) {
    final t = AppLocalizations.of(context);
    final phone = d['phone'] as String?;
    final km = d['km'];
    return Card(
      key: ValueKey('bp-resp-${d['id']}'),
      margin: const EdgeInsets.only(bottom: Gap.sm),
      child: Padding(
        padding: const EdgeInsets.all(Gap.md),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(children: [
            BpGroupBadge('${d['blood_group'] ?? ''}', size: 44),
            const SizedBox(width: Gap.md),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('${d['name'] ?? ''}', style: Theme.of(context).textTheme.titleMedium),
                if (d['verified'] == true) const BpVerifiedChip(),
                Text(bpD(context, [
                  if ('${d['area_text'] ?? ''}'.isNotEmpty) '${d['area_text']}',
                  if (km is int) t.bpAboutKm(km),
                  if (d['response'] == 'donated') t.bpDonatedTag,
                ].join(' · '))),
              ]),
            ),
          ]),
          const SizedBox(height: Gap.sm),
          Wrap(spacing: Gap.sm, runSpacing: Gap.sm, children: [
            ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 48),
              child: FilledButton.tonalIcon(
                key: ValueKey('bp-resp-msg-${d['id']}'),
                onPressed: () => _openThread(d['thread_id'] as int?),
                icon: const Icon(Icons.chat_bubble_outline_rounded),
                label: Text(t.bpMessage),
              ),
            ),
            if (phone != null && phone.isNotEmpty) ...[
              ConstrainedBox(
                constraints: const BoxConstraints(minHeight: 48),
                child: OutlinedButton.icon(
                  onPressed: () => bpLaunch(context, 'tel', phone),
                  icon: const Icon(Icons.call_rounded),
                  label: Text(t.bpCall),
                ),
              ),
              ConstrainedBox(
                constraints: const BoxConstraints(minHeight: 48),
                child: OutlinedButton.icon(
                  onPressed: () => bpLaunch(context, 'sms', phone),
                  icon: const Icon(Icons.sms_outlined),
                  label: Text(t.bpSms),
                ),
              ),
            ],
          ]),
        ]),
      ),
    );
  }

  List<Widget> _donorPart(BuildContext context, bool live) {
    final t = AppLocalizations.of(context);
    final text = Theme.of(context).textTheme;
    final said = '${_r['my_response'] ?? ''}';
    final compatible = _r['compatible'];
    final eligible = _r['eligible_by_then'];
    return [
      if (compatible == false) Text(t.bpNotCompatibleNote, style: text.bodyMedium),
      if (compatible != false && eligible == false) Text(t.bpNotEligibleNote, style: text.bodyMedium),
      if (compatible == null) Text(t.bpNotDonorNote, style: text.bodyMedium),
      const SizedBox(height: Gap.sm),
      if (live && said != 'can' && said != 'donated') ...[
        ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 56),
          child: FilledButton.icon(
            key: const ValueKey('bp-can'),
            onPressed: _busy || compatible != true || eligible != true
                ? null
                : () => _act('respond', {'answer': 'can'}, t.bpCanSent),
            icon: const Icon(Icons.volunteer_activism_rounded),
            label: Text(t.bpICan),
          ),
        ),
        const SizedBox(height: Gap.sm),
        if (said != 'cannot')
          ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 48),
            child: OutlinedButton(
              key: const ValueKey('bp-cannot'),
              onPressed: _busy ? null : () => _act('respond', {'answer': 'cannot'}, t.bpCannotSent),
              child: Text(t.bpICannot),
            ),
          ),
      ],
      if (said == 'can' || said == 'donated') ...[
        Card(
          margin: const EdgeInsets.only(bottom: Gap.md),
          child: Padding(
            padding: const EdgeInsets.all(Gap.md),
            child: Text(said == 'donated' ? t.bpDonatedThanks : t.bpYouSaidCanLong),
          ),
        ),
        ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 52),
          child: FilledButton.tonalIcon(
            key: const ValueKey('bp-donor-thread'),
            onPressed: () => _openThread(_r['thread_id'] as int?),
            icon: const Icon(Icons.chat_bubble_outline_rounded),
            label: Text(t.bpMessageRequester),
          ),
        ),
        const SizedBox(height: Gap.sm),
        if (said == 'can') ...[
          ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 48),
            child: OutlinedButton.icon(
              key: const ValueKey('bp-i-donated'),
              onPressed: _busy ? null : () => _act('respond', {'answer': 'donated'}, t.bpDonatedThanks),
              icon: const Icon(Icons.favorite_rounded),
              label: Text(t.bpIDonated),
            ),
          ),
          TextButton(
            key: const ValueKey('bp-withdraw'),
            onPressed: _busy ? null : () => _act('respond', {'answer': 'withdraw'}, t.bpWithdrawn),
            child: Text(t.bpWithdraw),
          ),
        ],
      ],
      if (!live) Text(bpStateLabel(t, '${_r['state']}')),
    ];
  }
}
