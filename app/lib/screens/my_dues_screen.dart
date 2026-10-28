import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../dues_api.dart';
import '../l10n/app_localizations.dart';
import '../messaging/date_separators.dart' show fmtDate, localDigits;
import '../services/error_kind.dart' show FailKind, failKindOf, honestFailText;
import '../services/error_report.dart';
import '../state.dart';
import '../theme.dart';
import '../widgets/skeleton.dart';
import 'business/business_common.dart' show pair;
import 'my_dues_shop_screen.dart';
import 'messenger/msgr_set_change_number_screen.dart'; // tagada2

/// tagada2 — "My Dues" (customer side of the digital khata). Every shop that
/// keeps an Assisto khata for MY VERIFIED phone number, with what I owe there.
/// Only what each shop recorded for me — never their private notes. Works
/// offline from the last saved copy. No ads on this screen.
class MyDuesScreen extends StatefulWidget {
  const MyDuesScreen({super.key});

  /// Saved-copy key (offline). Exposed for tests.
  static const cacheKey = 'my_dues_v1';

  @override
  State<MyDuesScreen> createState() => _MyDuesScreenState();
}

class _MyDuesScreenState extends State<MyDuesScreen> {
  Map<String, dynamic>? _data;
  bool _loading = true;
  Object? _fail;
  bool _saved = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = _data == null;
      _fail = null;
    });
    try {
      final r = await context
          .read<AppState>()
          .api
          .myDues()
          .timeout(const Duration(seconds: 15));
      _data = r;
      _saved = false;
      _store(r);
    } catch (e) {
      final cached =
          failKindOf(e) == FailKind.network ? await _cached() : null;
      if (cached != null) {
        _data = cached;
        _saved = true;
      } else if (_data == null) {
        _fail = e;
        reportNonFatal('dues.list', e);
      }
    }
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _store(Map<String, dynamic> r) async {
    try {
      final sp = await SharedPreferences.getInstance();
      await sp.setString(MyDuesScreen.cacheKey, jsonEncode(r));
    } catch (_) {/* best-effort: only the offline copy */}
  }

  Future<Map<String, dynamic>?> _cached() async {
    try {
      final sp = await SharedPreferences.getInstance();
      final s = sp.getString(MyDuesScreen.cacheKey);
      if (s == null) return null;
      final j = jsonDecode(s);
      return j is Map<String, dynamic> ? j : null;
    } catch (_) {
      return null; // a broken copy is the same as none
    }
  }

  String _d(Object v) =>
      localDigits('$v', Localizations.localeOf(context).languageCode);

  Future<void> _open(Map<String, dynamic> shop) async {
    final id = (shop['business_id'] as num?)?.toInt() ?? 0;
    await Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => MyDuesShopScreen(
            businessId: id, shopName: '${shop['shop_name'] ?? ''}')));
    if (mounted) _load();
  }

  /// tagada2: verify the account's own number (change-number flow in
  /// verify mode), then reload — dues appear once it is verified.
  Future<void> _verify() async {
    await Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => const MsgrSetChangeNumberScreen(verifyOwn: true)));
    if (mounted) _load();
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    return Scaffold(
      appBar: AppBar(
          title: Text(t.tg2DuesTitle,
              maxLines: 1, overflow: TextOverflow.ellipsis)),
      body: _body(t),
    );
  }

  Widget _body(AppLocalizations t) {
    if (_loading) return const SkeletonList();
    if (_fail != null || _data == null) {
      return StateMessage(
        icon: Icons.cloud_off_rounded,
        title: t.tg2DuesTitle,
        message: honestFailText(t, _fail),
        action: FilledButton(onPressed: _load, child: Text(t.retry)),
      );
    }
    final d = _data!;
    if (d['verified'] != true) {
      return StateMessage(
        key: const ValueKey('tg2-dues-unverified'),
        icon: Icons.verified_user_outlined,
        title: t.tg2DuesUnverifiedTitle,
        message: t.tg2DuesUnverifiedBody,
        action: FilledButton.icon(
          key: const ValueKey('tg2-dues-verify'),
          style: FilledButton.styleFrom(minimumSize: const Size(48, 48)),
          icon: const Icon(Icons.verified_user_rounded),
          label: Text(t.tg2VerifyButton),
          onPressed: _verify,
        ),
      );
    }
    final shops = ((d['shops'] ?? const []) as List)
        .whereType<Map>()
        .map((m) => m.cast<String, dynamic>())
        .toList();
    final scheme = Theme.of(context).colorScheme;
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        padding: const EdgeInsets.all(Gap.lg),
        children: [
          if (_saved) ...[
            Container(
              key: const ValueKey('tg2-dues-saved'),
              padding: const EdgeInsets.all(Gap.md),
              decoration: BoxDecoration(
                  color: scheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(Radii.md)),
              child: Row(children: [
                const Icon(Icons.cloud_off_rounded, size: 20),
                const SizedBox(width: Gap.sm),
                Expanded(child: Text(t.tg2DuesSavedCopy)),
              ]),
            ),
            const SizedBox(height: Gap.md),
          ],
          Text(t.tg2DuesIntro(_d('${d['phone_masked'] ?? ''}')),
              style: AType.bodyMedium.copyWith(color: scheme.onSurfaceVariant)),
          const SizedBox(height: Gap.md),
          if (shops.isEmpty)
            Padding(
              key: const ValueKey('tg2-dues-empty'),
              padding: const EdgeInsets.symmetric(vertical: Gap.xl),
              child: Column(children: [
                Icon(Icons.check_circle_outline_rounded,
                    size: 48, color: scheme.primary),
                const SizedBox(height: Gap.md),
                Semantics(
                  header: true,
                  child: Text(t.tg2DuesEmptyTitle,
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.titleMedium),
                ),
                const SizedBox(height: Gap.sm),
                Text(t.tg2DuesEmptyBody,
                    textAlign: TextAlign.center, style: AType.bodyMedium),
              ]),
            )
          else ...[
            if (d['total_display'] != null)
              Card(
                margin: EdgeInsets.zero,
                child: Padding(
                  padding: const EdgeInsets.all(Gap.lg),
                  child: Semantics(
                    container: true,
                    child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(t.tg2DuesTotal, style: AType.bodyMedium),
                          const SizedBox(height: Gap.xs),
                          Text(pair(context, d['total_display']),
                              key: const ValueKey('tg2-dues-total'),
                              style: Theme.of(context)
                                  .textTheme
                                  .headlineSmall
                                  ?.copyWith(
                                      fontFeatures: AFonts.tabular,
                                      fontWeight: FontWeight.w700)),
                        ]),
                  ),
                ),
              ),
            const SizedBox(height: Gap.md),
            for (final s in shops) _tile(t, s),
          ],
        ],
      ),
    );
  }

  Widget _tile(AppLocalizations t, Map<String, dynamic> s) {
    final scheme = Theme.of(context).colorScheme;
    final unread = (s['unread'] as num?)?.toInt() ?? 0;
    final owes = s['owes'] == true;
    final lang = Localizations.localeOf(context).languageCode;
    final last = DateTime.tryParse('${s['last_entry_at'] ?? ''}')?.toLocal();
    final sub = <String>[
      pair(context, s['status']),
      if (last != null) t.tg2DuesLast(fmtDate('d MMM yyyy', last, lang)),
      if (s['blocked'] == true) t.tg2Blocked else if (s['muted'] == true) t.tg2DuesMuted,
    ].where((x) => x.isNotEmpty).join(' · ');
    return Card(
      key: ValueKey('tg2-dues-${s['business_id']}'),
      margin: const EdgeInsets.only(bottom: Gap.sm),
      child: ListTile(
        minVerticalPadding: Gap.md,
        leading: CircleAvatar(
          backgroundColor: scheme.primaryContainer,
          child: Icon(Icons.storefront_rounded, color: scheme.onPrimaryContainer),
        ),
        title: Text('${s['shop_name'] ?? ''}',
            maxLines: 2, overflow: TextOverflow.ellipsis),
        subtitle: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(sub),
              if (unread > 0)
                Padding(
                  padding: const EdgeInsets.only(top: Gap.xs),
                  child: Text(t.tg2DuesUnread(_d(unread)),
                      style: TextStyle(
                          color: scheme.primary, fontWeight: FontWeight.w700)),
                ),
            ]),
        trailing: Text(pair(context, s['balance_display']),
            style: TextStyle(
                fontFeatures: AFonts.tabular,
                fontWeight: FontWeight.w700,
                color: owes ? scheme.error : AssistoTokens.of(context).success)),
        onTap: () => _open(s),
      ),
    );
  }
}
