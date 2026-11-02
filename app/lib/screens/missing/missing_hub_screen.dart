import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../api.dart';
import '../../l10n/app_localizations.dart';
import '../../missing_alert_api.dart';
import '../../state.dart';
import '../../theme.dart';
import '../../widgets/app_sheet.dart';
import 'ma_common.dart';
import 'missing_detail_screen.dart';
import 'missing_optin_screen.dart';
import 'missing_post_screen.dart';

/// missing (owner 2 Nov) — Missing person alert hub (route `missing_alert`,
/// flag `missing_alert`). One list, in this order:
///   1. alerts ABOUT ME (the missing person: one big "I am safe" button);
///   2. co-sign requests (a family member asks me to confirm a child alert);
///   3. my alerts (posted by me: state, tips, found / close inside);
///   4. alerts near me (only if I opted in to nearby safety alerts);
/// plus the nearby-alerts switch and the honest "who gets it" card. Contact
/// goes through the app: no phone numbers, no public comments.
class MissingHubScreen extends StatefulWidget {
  const MissingHubScreen({super.key});

  @override
  State<MissingHubScreen> createState() => _MissingHubScreenState();
}

class _MissingHubScreenState extends State<MissingHubScreen> {
  ApiClient get _api => context.read<AppState>().api;
  bool _loading = true;
  bool _failed = false;
  Map<String, dynamic> _data = const {};

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
      final r = await _api.maList();
      if (!mounted) return;
      setState(() {
        _data = r;
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

  Future<void> _open(Map<String, dynamic> a) async {
    final id = a['id'];
    if (id is! int) return;
    await Navigator.of(context)
        .push(MaterialPageRoute(builder: (_) => MissingDetailScreen(alertId: id)));
    if (mounted) unawaited(_load());
  }

  Future<void> _post() async {
    final made = await Navigator.of(context)
        .push<bool>(MaterialPageRoute(builder: (_) => const MissingPostScreen()));
    if (made == true && mounted) unawaited(_load());
  }

  Future<void> _optin() async {
    await Navigator.of(context)
        .push(MaterialPageRoute(builder: (_) => const MissingOptinScreen()));
    if (mounted) unawaited(_load());
  }

  Future<void> _safe(Map<String, dynamic> a) async {
    final t = AppLocalizations.of(context);
    final child = a['is_child'] == true;
    final yes = await showAppSheet<bool>(
      context: context,
      builder: (ctx) => Padding(
        padding: const EdgeInsets.fromLTRB(Gap.lg, Gap.lg, Gap.lg, Gap.md),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text(t.maSafeConfirmTitle, style: Theme.of(ctx).textTheme.titleMedium),
          const SizedBox(height: Gap.sm),
          Text(child ? t.maSafeConfirmChild : t.maSafeConfirmAdult),
          const SizedBox(height: Gap.lg),
          ConstrainedBox(constraints: const BoxConstraints(minHeight: 52),
            child: FilledButton(
              key: const ValueKey('ma-safe-confirm'),
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(t.maIamSafe),
            ),
          ),
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(t.maCancel)),
        ]),
      ),
    );
    if (yes != true || !mounted) return;
    try {
      final r = await _api.maAct(a['id'] as int, 'safe');
      if (!mounted) return;
      _snack(r['ok'] == true ? (child ? t.maSafeSentChild : t.maSafeSent) : maReason(t, r['reason'] as String?));
    } catch (_) {
      if (mounted) _snack(t.maErrGeneric);
    }
    unawaited(_load());
  }

  Future<void> _cosign(Map<String, dynamic> a, bool yes) async {
    final t = AppLocalizations.of(context);
    try {
      final r = await _api.maAct(a['id'] as int, 'cosign', {'confirm': yes});
      if (!mounted) return;
      _snack(r['ok'] == true ? (yes ? t.maCosignDone : t.maCosignDeclined) : maReason(t, r['reason'] as String?));
    } catch (_) {
      if (mounted) _snack(t.maErrGeneric);
    }
    unawaited(_load());
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    return Scaffold(
      appBar: AppBar(
        title: Text(t.maTitle),
        actions: [
          IconButton(
            tooltip: t.maOptinTitle,
            onPressed: _optin,
            icon: const Icon(Icons.tune_rounded),
          ),
        ],
      ),
      floatingActionButton: _loading || _failed
          ? null
          : FloatingActionButton.extended(
              key: const ValueKey('ma-post-fab'),
              onPressed: _post,
              icon: const Icon(Icons.campaign_rounded),
              label: Text(t.maPostCta),
            ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _failed
              ? Center(child: MaError(onRetry: _load))
              : RefreshIndicator(onRefresh: _load, child: _list(context)),
    );
  }

  Widget _list(BuildContext context) {
    final t = AppLocalizations.of(context);
    final about = maRows(_data, 'about_me').where((a) => a['state'] == 'active').toList();
    final cosign = maRows(_data, 'cosign').where((a) => a['state'] == 'pending').toList();
    final mine = maRows(_data, 'mine');
    final near = maRows(_data, 'near');
    final optin = (_data['optin'] is Map) ? Map<String, dynamic>.from(_data['optin'] as Map) : const <String, dynamic>{};
    final text = Theme.of(context).textTheme;
    return ListView(
      padding: withNavBarInset(context, const EdgeInsets.fromLTRB(Gap.lg, Gap.md, Gap.lg, 96)),
      children: [
        for (final a in about) _aboutMe(context, a),
        for (final a in cosign) _cosignCard(context, a),
        _optinCard(context, optin),
        const SizedBox(height: Gap.lg),
        if (mine.isEmpty && near.isEmpty) _empty(context),
        if (mine.isNotEmpty) ...[
          Text(t.maMine, style: text.titleMedium),
          const SizedBox(height: Gap.sm),
          for (final a in mine) _alertTile(context, a, mine: true),
          const SizedBox(height: Gap.lg),
        ],
        if (near.isNotEmpty) ...[
          Text(t.maNear, style: text.titleMedium),
          const SizedBox(height: Gap.sm),
          for (final a in near) _alertTile(context, a),
          const SizedBox(height: Gap.lg),
        ],
        const MaWhoGetsCard(),
        const SizedBox(height: Gap.md),
        const Align(alignment: Alignment.centerLeft, child: Ma999Button()),
      ],
    );
  }

  Widget _aboutMe(BuildContext context, Map<String, dynamic> a) {
    final t = AppLocalizations.of(context);
    final s = Theme.of(context).colorScheme;
    final child = a['is_child'] == true;
    return Card(
      key: ValueKey('ma-about-${a['id']}'),
      color: s.errorContainer,
      margin: const EdgeInsets.only(bottom: Gap.md),
      child: Padding(
        padding: const EdgeInsets.all(Gap.lg),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text(child ? t.maAboutMeTitleChild : t.maAboutMeTitle,
              style: Theme.of(context).textTheme.titleMedium?.copyWith(color: s.onErrorContainer)),
          const SizedBox(height: Gap.sm),
          Text(child ? t.maAboutMeBodyChild : t.maAboutMeBody,
              style: TextStyle(color: s.onErrorContainer)),
          if (a['safe_said'] == true) ...[
            const SizedBox(height: Gap.sm),
            Text(t.maSafeAlreadySaid, style: TextStyle(color: s.onErrorContainer, fontWeight: FontWeight.w600)),
          ],
          const SizedBox(height: Gap.md),
          ConstrainedBox(constraints: const BoxConstraints(minHeight: 56),
            child: FilledButton.icon(
              key: const ValueKey('ma-safe'),
              style: FilledButton.styleFrom(backgroundColor: Brand.successFill, foregroundColor: Colors.white),
              onPressed: () => _safe(a),
              icon: const Icon(Icons.verified_user_rounded),
              label: Text(t.maIamSafe),
            ),
          ),
        ]),
      ),
    );
  }

  Widget _cosignCard(BuildContext context, Map<String, dynamic> a) {
    final t = AppLocalizations.of(context);
    return Card(
      key: ValueKey('ma-cosign-${a['id']}'),
      margin: const EdgeInsets.only(bottom: Gap.md),
      child: Padding(
        padding: const EdgeInsets.all(Gap.lg),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text(t.maCosignTitle, style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: Gap.sm),
          Text(maD(context, t.maCosignBody('${a['poster_name'] ?? ''}', '${a['name'] ?? ''}', '${a['age'] ?? ''}'))),
          const SizedBox(height: Gap.md),
          Wrap(spacing: Gap.sm, runSpacing: Gap.sm, children: [
            FilledButton(
              key: const ValueKey('ma-cosign-yes'),
              onPressed: () => _cosign(a, true),
              child: Text(t.maCosignYes),
            ),
            OutlinedButton(
              onPressed: () => _cosign(a, false),
              child: Text(t.maCosignNo),
            ),
            TextButton(onPressed: () => _open(a), child: Text(t.maOpen)),
          ]),
        ]),
      ),
    );
  }

  Widget _optinCard(BuildContext context, Map<String, dynamic> optin) {
    final t = AppLocalizations.of(context);
    final on = optin['enabled'] == true;
    final area = '${optin['district_name'] ?? ''}';
    return Card(
      margin: EdgeInsets.zero,
      child: ListTile(
        key: const ValueKey('ma-optin-tile'),
        leading: Icon(on ? Icons.notifications_active_rounded : Icons.notifications_off_rounded),
        title: Text(on ? t.maOptinOn : t.maOptinOffTitle),
        subtitle: Text(on ? (area.isEmpty ? t.maOptinOnNoArea : t.maOptinOnArea(area)) : t.maOptinOffBody),
        trailing: Text(on ? t.maChange : t.maTurnOn,
            style: TextStyle(color: Theme.of(context).colorScheme.primary, fontWeight: FontWeight.w600)),
        onTap: _optin,
      ),
    );
  }

  Widget _empty(BuildContext context) {
    final t = AppLocalizations.of(context);
    final text = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: Gap.lg),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Icon(Icons.person_search_rounded, size: 48, color: Theme.of(context).colorScheme.primary),
        const SizedBox(height: Gap.sm),
        Text(t.maEmptyTitle, style: text.titleMedium, textAlign: TextAlign.center),
        const SizedBox(height: Gap.sm),
        Text(t.maEmptyBody, textAlign: TextAlign.center),
        const SizedBox(height: Gap.md),
        ConstrainedBox(constraints: const BoxConstraints(minHeight: 52),
          child: FilledButton.icon(
            key: const ValueKey('ma-empty-post'),
            onPressed: _post,
            icon: const Icon(Icons.campaign_rounded),
            label: Text(t.maPostCta),
          ),
        ),
        const SizedBox(height: Gap.md),
        Text(maD(context, t.maEmptySteps), style: text.bodySmall),
      ]),
    );
  }

  Widget _alertTile(BuildContext context, Map<String, dynamic> a, {bool mine = false}) {
    final t = AppLocalizations.of(context);
    final s = Theme.of(context).colorScheme;
    final state = '${a['state'] ?? ''}';
    final name = '${a['name'] ?? ''}';
    final age = maD(context, '${a['age'] ?? ''}');
    final dist = a['distance_km'];
    final unread = (a['tips_unread'] is int) ? a['tips_unread'] as int : 0;
    final sub = [
      maD(context, t.maLastSeenShort('${a['area_text'] ?? ''}', maAgo(context, a['last_seen_at'] as String?))),
      if (dist is int) maD(context, t.maDistance(dist)),
      if (mine && unread > 0) maD(context, t.maTipsUnread(unread)),
    ].join(' · ');
    return Card(
      key: ValueKey('ma-alert-${a['id']}'),
      margin: const EdgeInsets.only(bottom: Gap.sm),
      child: InkWell(
        borderRadius: BorderRadius.circular(Radii.md),
        onTap: () => _open(a),
        child: Padding(
          padding: const EdgeInsets.all(Gap.md),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            MaPhoto(url: a['photo_url'] as String?, label: name),
            const SizedBox(width: Gap.md),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(t.maNameAge(name, age), style: Theme.of(context).textTheme.titleSmall),
                const SizedBox(height: Gap.xs),
                Text(sub, style: Theme.of(context).textTheme.bodySmall),
                const SizedBox(height: Gap.xs),
                Text(maStateLabel(t, state, safeSaid: a['safe_said'] == true),
                    style: TextStyle(color: maStateColor(s, state), fontWeight: FontWeight.w600)),
              ]),
            ),
            const Icon(Icons.chevron_right_rounded),
          ]),
        ),
      ),
    );
  }
}
