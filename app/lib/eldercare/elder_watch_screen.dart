import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../api.dart' show ApiException;
import '../l10n/app_localizations.dart';
import '../ds/ds.dart';
import '../theme.dart';
import '../widgets/app_sheet.dart';
import 'elder_common.dart';
import 'elder_join_screen.dart';
import 'elder_setup_screen.dart';
import 'package:assisto/ads/ad_block_context.dart' show AdBlockedState;

/// fcelder — the FAMILY's view of Silent Watch (push "Check on Ammu" opens
/// it): every parent whose phone is watched, an alert first. HONEST: with no
/// alert it says "No alert" — never "OK" — because the server deliberately
/// knows nothing else (no tracking stream). Buttons: Call, I AM CHECKING
/// (stops the ladder waking more people), Test (the setter), and set up
/// another parent's phone.
class ElderWatchScreen extends StatefulWidget {
  const ElderWatchScreen({super.key, this.debugStatus});

  final Map<String, dynamic>? debugStatus;

  @override
  State<ElderWatchScreen> createState() => _ElderWatchScreenState();
}

class _ElderWatchScreenState extends State<ElderWatchScreen>
    with AdBlockedState<ElderWatchScreen> {
  Map<String, dynamic>? _s;
  String? _error;
  final Set<int> _busy = {};

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    if (widget.debugStatus != null) {
      setState(() => _s = widget.debugStatus);
      return;
    }
    final api = ElderHooks.api(context);
    if (api == null) return;
    try {
      final r = await api.status();
      if (mounted) {
        setState(() {
          _s = r;
          _error = null;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _error = AppLocalizations.of(context).fceOffline);
    }
  }

  Future<void> _act(int key, Future<Object?> Function() f, String done) async {
    setState(() => _busy.add(key));
    try {
      await f();
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(done)));
      await _load();
    } on ApiException catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(AppLocalizations.of(context).fceOffline)));
      }
    } finally {
      if (mounted) setState(() => _busy.remove(key));
    }
  }

  String? _phoneOf(int elderId) {
    for (final f in (_s?['family'] as List?) ?? const []) {
      if (f is Map && f['user_id'] == elderId && '${f['phone'] ?? ''}'.isNotEmpty) return '${f['phone']}';
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final watching = ((_s?['watching'] as List?) ?? const []).whereType<Map>().toList();
    return Scaffold(
      appBar: AppBar(title: Text(t.fceWatchTitle)),
      body: RefreshIndicator(
        onRefresh: _load,
        child: ListView(
          padding: withNavBarInset(context, const EdgeInsets.fromLTRB(Gap.lg, Gap.md, Gap.lg, Gap.xxl)),
          children: [
            if (_s == null && _error == null)
              DsSkeleton.card(lines: 3),
            if (_error != null)
              Text(_error!, style: AType.titleMedium.copyWith(color: DsTokens.of(context).dangerInk)),
            if (_s != null && watching.isEmpty) _empty(t),
            for (final w in watching)
              Padding(
                padding: const EdgeInsets.only(bottom: Gap.md),
                child: _card(t, Map<String, dynamic>.from(w)),
              ),
            if (_s != null) ...[
              const SizedBox(height: Gap.sm),
              DsGroup(margin: EdgeInsets.zero, children: [
                DsListRow(
                  key: const Key('fce-watch-setup'),
                  leading: DsAvatar(child: Icon(Icons.qr_code_2_rounded, color: DsTokens.of(context).primaryInk)),
                  title: t.fceMoreSetupParent,
                  subtitle: t.fceSetupBenefit,
                  trailing: Icon(Icons.chevron_right_rounded, color: DsTokens.of(context).muted),
                  onTap: () => Navigator.of(context)
                      .push(MaterialPageRoute<void>(builder: (_) => const ElderSetupScreen()))
                      .then((_) => _load()),
                ),
                DsListRow(
                  key: const Key('fce-watch-join'),
                  leading: DsAvatar(child: Icon(Icons.phone_android_rounded, color: DsTokens.of(context).primaryInk)),
                  title: t.fceMoreSetupMine,
                  trailing: Icon(Icons.chevron_right_rounded, color: DsTokens.of(context).muted),
                  onTap: () => Navigator.of(context)
                      .push(MaterialPageRoute<void>(builder: (_) => const ElderJoinScreen())),
                ),
              ]),
            ],
          ],
        ),
      ),
    );
  }

  Widget _empty(AppLocalizations t) {
    return DsEmptyState(
      icon: Icons.shield_moon_rounded,
      title: t.fceWatchEmptyTitle,
      benefit: t.fceWatchEmptyBody,
      actionLabel: t.fceMoreSetupParent,
      actionKey: const Key('fce-watch-empty-cta'),
      onAction: () => Navigator.of(context)
          .push(MaterialPageRoute<void>(builder: (_) => const ElderSetupScreen()))
          .then((_) => _load()),
    );
  }

  Widget _card(AppLocalizations t, Map<String, dynamic> w) {
    final ds = DsTokens.of(context);
    final name = '${w['elder_name'] ?? ''}';
    final id = (w['elder_id'] as num?)?.toInt() ?? 0;
    final a = (w['alert'] as Map?)?.cast<String, dynamic>();
    final st = '${a?['status'] ?? ''}';
    final live = st == 'open' || st == 'asking' || st == 'checking';
    String line;
    switch (st) {
      case 'open':
        line = t.fceWatchAlertOpen(name);
      case 'asking':
        line = t.fceWatchAsking(name);
      case 'checking':
        line = t.fceWatchChecking('${a?['checking_name'] ?? ''}');
      case 'resolved':
        line = t.fceWatchResolved(name);
      default:
        line = t.fceWatchNoAlert;
    }
    final phone = _phoneOf(id);
    // designv2: an open alert is the red card with the "I'm checking" action
    // first; otherwise a calm card with a pulsing green dot.
    return DsCard(
      key: Key('fce-watch-card-$id'),
      tone: live ? DsTone.danger : DsTone.normal,
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(children: [
            if (live)
              Icon(Icons.warning_amber_rounded, color: ds.dangerInk, size: 32)
            else
              DsAvatar(name: name, size: 44),
            const SizedBox(width: Gap.md),
            Expanded(child: Text(name,
                style: AType.titleLarge.copyWith(fontWeight: FontWeight.w700, color: ds.text))),
            if (!live) DsStatusDot(color: ds.success),
          ]),
          const SizedBox(height: Gap.sm),
          Text(line, style: AType.titleMedium.copyWith(color: live ? ds.dangerInk : ds.text)),
          if (!live)
            Text(t.fceWatchNoAlertWhy, style: AType.bodyMedium.copyWith(color: ds.muted)),
          const SizedBox(height: Gap.md),
          Wrap(spacing: Gap.sm, runSpacing: Gap.sm, children: [
            if (st == 'open' || st == 'asking')
              DsButton.danger(
                key: Key('fce-watch-ack-$id'),
                busy: _busy.contains(id),
                onPressed: () => _act(id, () => ElderHooks.api(context)!.ack((a?['id'] as num).toInt()),
                    t.fceWatchAckDone(name)),
                icon: Icons.directions_run_rounded,
                label: t.fceWatchIChecking,
              ),
            if (phone != null)
              DsButton(
                kind: live ? DsButtonKind.secondary : DsButtonKind.primary,
                onPressed: () => launchUrl(Uri(scheme: 'tel', path: phone)),
                icon: Icons.call_rounded,
                label: t.fceWatchCall,
              ),
            if (w['i_set_it_up'] == true && !live)
              DsButton.secondary(
                key: Key('fce-watch-test-$id'),
                busy: _busy.contains(id),
                onPressed: () => _act(id, () => ElderHooks.api(context)!.test(id), t.fceWatchTestSent(name)),
                icon: Icons.science_outlined,
                label: t.fceWatchTest,
              ),
          ]),
      ]),
    );
  }
}
