import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../api.dart' show ApiException;
import '../l10n/app_localizations.dart';
import '../theme.dart';
import '../widgets/app_sheet.dart';
import 'elder_common.dart';
import 'elder_join_screen.dart';
import 'elder_setup_screen.dart';

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

class _ElderWatchScreenState extends State<ElderWatchScreen> {
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
              const Padding(padding: EdgeInsets.all(Gap.xl), child: Center(child: CircularProgressIndicator())),
            if (_error != null)
              Text(_error!, style: AType.titleMedium.copyWith(color: Theme.of(context).colorScheme.error)),
            if (_s != null && watching.isEmpty) _empty(t),
            for (final w in watching) _card(t, Map<String, dynamic>.from(w)),
            if (_s != null) ...[
              const SizedBox(height: Gap.lg),
              ListTile(
                key: const Key('fce-watch-setup'),
                leading: const Icon(Icons.qr_code_2_rounded),
                title: Text(t.fceMoreSetupParent),
                subtitle: Text(t.fceSetupBenefit),
                onTap: () => Navigator.of(context)
                    .push(MaterialPageRoute<void>(builder: (_) => const ElderSetupScreen()))
                    .then((_) => _load()),
              ),
              ListTile(
                key: const Key('fce-watch-join'),
                leading: const Icon(Icons.phone_android_rounded),
                title: Text(t.fceMoreSetupMine),
                onTap: () => Navigator.of(context)
                    .push(MaterialPageRoute<void>(builder: (_) => const ElderJoinScreen())),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _empty(AppLocalizations t) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(Gap.lg),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Icon(Icons.shield_moon_rounded, size: 48, color: scheme.primary),
          const SizedBox(height: Gap.sm),
          Text(t.fceWatchEmptyTitle, style: AType.titleLarge.copyWith(fontWeight: FontWeight.w700)),
          const SizedBox(height: Gap.xs),
          Text(t.fceWatchEmptyBody, style: AType.bodyLarge),
          const SizedBox(height: Gap.md),
          SizedBox(
            height: 52,
            child: FilledButton.icon(
              key: const Key('fce-watch-empty-cta'),
              onPressed: () => Navigator.of(context)
                  .push(MaterialPageRoute<void>(builder: (_) => const ElderSetupScreen()))
                  .then((_) => _load()),
              icon: const Icon(Icons.qr_code_2_rounded),
              label: Text(t.fceMoreSetupParent),
            ),
          ),
        ]),
      ),
    );
  }

  Widget _card(AppLocalizations t, Map<String, dynamic> w) {
    final scheme = Theme.of(context).colorScheme;
    final name = '${w['elder_name'] ?? ''}';
    final id = (w['elder_id'] as num?)?.toInt() ?? 0;
    final a = (w['alert'] as Map?)?.cast<String, dynamic>();
    final st = '${a?['status'] ?? ''}';
    final live = st == 'open' || st == 'asking' || st == 'checking';
    final amber = Brand.warnInk(context);
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
    return Card(
      key: Key('fce-watch-card-$id'),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: live ? amber : scheme.outlineVariant, width: live ? 2 : 1),
      ),
      child: Padding(
        padding: const EdgeInsets.all(Gap.lg),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(children: [
            Icon(live ? Icons.warning_amber_rounded : Icons.shield_moon_rounded,
                color: live ? amber : scheme.primary, size: 32),
            const SizedBox(width: Gap.md),
            Expanded(child: Text(name, style: AType.titleLarge.copyWith(fontWeight: FontWeight.w700))),
          ]),
          const SizedBox(height: Gap.sm),
          Text(line, style: AType.titleMedium.copyWith(color: live ? amber : scheme.onSurface)),
          if (!live)
            Text(t.fceWatchNoAlertWhy, style: AType.bodyMedium.copyWith(color: scheme.onSurfaceVariant)),
          const SizedBox(height: Gap.md),
          Wrap(spacing: Gap.sm, runSpacing: Gap.sm, children: [
            if (phone != null)
              FilledButton.icon(
                style: live ? Brand.successButton() : null,
                onPressed: () => launchUrl(Uri(scheme: 'tel', path: phone)),
                icon: const Icon(Icons.call_rounded),
                label: Text(t.fceWatchCall),
              ),
            if (st == 'open' || st == 'asking')
              FilledButton.icon(
                key: Key('fce-watch-ack-$id'),
                style: Brand.dangerButton(),
                onPressed: _busy.contains(id)
                    ? null
                    : () => _act(id, () => ElderHooks.api(context)!.ack((a?['id'] as num).toInt()),
                        t.fceWatchAckDone(name)),
                icon: const Icon(Icons.directions_run_rounded),
                label: Text(t.fceWatchIChecking),
              ),
            if (w['i_set_it_up'] == true && !live)
              OutlinedButton.icon(
                key: Key('fce-watch-test-$id'),
                onPressed: _busy.contains(id)
                    ? null
                    : () => _act(id, () => ElderHooks.api(context)!.test(id), t.fceWatchTestSent(name)),
                icon: const Icon(Icons.science_outlined),
                label: Text(t.fceWatchTest),
              ),
          ]),
        ]),
      ),
    );
  }
}
