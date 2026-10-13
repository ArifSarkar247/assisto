import 'package:flutter/material.dart';
import '../l10n/app_localizations.dart';
import 'package:provider/provider.dart';
import '../state.dart';
import '../theme.dart';
import '../widgets/skeleton.dart';

/// Plans, credits, trial status + rewarded-ad credit. Upgrade/billing shows a
/// clean "Available when ___" state until a payment method is connected.
class PlansScreen extends StatefulWidget {
  const PlansScreen({super.key});
  @override
  State<PlansScreen> createState() => _PlansScreenState();
}

class _PlansScreenState extends State<PlansScreen> {
  Map<String, dynamic>? _p;
  bool _loading = true, _error = false, _busy = false;

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
      _p = await context.read<AppState>().api.plan();
    } catch (_) {
      _error = true;
    }
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _rewarded() async {
    setState(() => _busy = true);
    try {
      final r = await context.read<AppState>().api.rewardedAd();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(r['ok'] == true
                ? AppLocalizations.of(context).plansCreditAdded
                : (r['msg'] ?? AppLocalizations.of(context).plansDailyLimitReached).toString())));
      }
      await _load();
    } catch (_) {} finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: Text(t.planCredits)),
      body: _loading
          ? const SkeletonList()
          : _error
              ? StateMessage(
                  icon: Icons.cloud_off,
                  tint: scheme.error,
                  title: t.loadFailed,
                  action: FilledButton.tonalIcon(
                      onPressed: _load,
                      icon: const Icon(Icons.refresh),
                      label: Text(t.retry)))
              : ListView(padding: const EdgeInsets.all(Gap.lg), children: [
                  _currentCard(t),
                  const SizedBox(height: Gap.lg),
                  Text(t.plans,
                      style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 16)),
                  const SizedBox(height: Gap.sm),
                  _plan('premium', t.premium, '৳149/mo',
                      t.unlimitedAiNoAds),
                  _plan('family', t.moduleFamily, '৳299/mo',
                      t.premium5MembersVoiceCall),
                  _plan('annual', t.annual, '৳1,199/yr',
                      t.premiumOneYear),
                  const SizedBox(height: Gap.md),
                  Text(
                    t.purchasingTurnsOnWhenA,
                    style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
                  ),
                ]),
    );
  }

  Widget _currentCard(AppLocalizations t) {
    final p = _p!;
    final credits = p['credits'] ?? 0;
    final trial = p['trial_active'] == true;
    return Container(
      decoration: BoxDecoration(
          gradient: Brand.gradient, borderRadius: BorderRadius.circular(Radii.lg)),
      padding: const EdgeInsets.all(Gap.xl),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(t.currentPlan,
            style: const TextStyle(color: Colors.white70, fontSize: 12)),
        Text('${p['name'] ?? p['plan']}',
            style: const TextStyle(
                color: Colors.white, fontSize: 26, fontWeight: FontWeight.w800)),
        if (trial)
          Text(t.freeTrialActive,
              style: const TextStyle(color: Colors.white, fontSize: 12)),
        const SizedBox(height: Gap.md),
        Row(children: [
          const Icon(Icons.bolt, color: Colors.white, size: 20),
          const SizedBox(width: 6),
          Text(
              p['unlimited_ai'] == true
                  ? t.unlimitedAi
                  : t.aiCreditsCount(credits),
              style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600)),
        ]),
        if (p['unlimited_ai'] != true) ...[
          const SizedBox(height: Gap.md),
          FilledButton.tonalIcon(
            onPressed: _busy ? null : _rewarded,
            icon: const Icon(Icons.ondemand_video, size: 18),
            label: Text(t.watchAnAd1Credit),
          ),
        ],
      ]),
    );
  }

  Widget _plan(String id, String name, String price, String desc) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      child: ListTile(
        title: Text(name, style: const TextStyle(fontWeight: FontWeight.w700)),
        subtitle: Text(desc),
        trailing: Text(price,
            style: TextStyle(fontWeight: FontWeight.w700, color: scheme.primary)),
      ),
    );
  }
}
