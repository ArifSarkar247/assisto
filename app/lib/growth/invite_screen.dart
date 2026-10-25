import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';

import '../l10n/app_localizations.dart';
import '../state.dart';
import '../widgets/founder_badge.dart' show FounderBadge;
import 'branded_share.dart';
import 'growth_api.dart';
import 'install_ping.dart';

/// p5-growth: Invite friends (referral) + Founding Members.
///
/// Honest by construction: every amount, cap, day count and seat number is
/// what /growth/me returned (admin-editable on the server). Credits are AI
/// credits, never cash. Nothing here is a countdown or a fake "only N left".
class InviteScreen extends StatefulWidget {
  /// Test/gallery hook: replaces the /growth/me call.
  final Future<Map<String, dynamic>> Function()? loader;

  const InviteScreen({super.key, this.loader});

  @override
  State<InviteScreen> createState() => _InviteScreenState();
}

String localDigits(Object? v, bool bn) {
  final s = '${v ?? 0}';
  if (!bn) return s;
  const zero = 0x09E6;
  return String.fromCharCodes(s.codeUnits
      .map((c) => (c >= 0x30 && c <= 0x39) ? zero + (c - 0x30) : c));
}

class _InviteScreenState extends State<InviteScreen> {
  Map<String, dynamic>? _d;
  bool _loading = true, _error = false, _claiming = false;
  String? _claimMsg;
  final _codeCtl = TextEditingController();

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _codeCtl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = false;
    });
    try {
      final f = widget.loader ?? () => context.read<AppState>().api.growthMe();
      _d = await f();
    } catch (_) {
      _error = true;
    }
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _claim() async {
    final code = _codeCtl.text.trim();
    if (code.isEmpty || _claiming) return;
    setState(() {
      _claiming = true;
      _claimMsg = null;
    });
    try {
      final api = context.read<AppState>().api;
      String dev = '';
      try {
        dev = await InstallPing.installId();
      } catch (_) {} // best-effort: the claim still works without a device id
      final r = await api.growthClaim(code, deviceId: dev);
      _claimMsg = (r['detail'] ?? '').toString();
      if (r['ok'] == true && r['me'] is Map) {
        _d = Map<String, dynamic>.from(r['me'] as Map);
        _codeCtl.clear();
      }
    } catch (_) {
      if (mounted) _claimMsg = AppLocalizations.of(context).loadFailed;
    }
    if (mounted) setState(() => _claiming = false);
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(t.p5InviteTitle)),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error || _d == null
              ? _errorView(t)
              : RefreshIndicator(onRefresh: _load, child: _body(t)),
    );
  }

  Widget _errorView(AppLocalizations t) => Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Text(t.loadFailed, textAlign: TextAlign.center),
            const SizedBox(height: 12),
            FilledButton(onPressed: _load, child: Text(t.retry)),
          ]),
        ),
      );

  Widget _body(AppLocalizations t) {
    final d = _d!;
    final bn = Localizations.localeOf(context).languageCode == 'bn';
    String n(Object? v) => localDigits(v, bn);
    final rules = Map<String, dynamic>.from((d['rules'] ?? {}) as Map);
    final stats = Map<String, dynamic>.from((d['stats'] ?? {}) as Map);
    final founding = Map<String, dynamic>.from((d['founding'] ?? {}) as Map);
    final mine = d['my_claim'] is Map
        ? Map<String, dynamic>.from(d['my_claim'] as Map)
        : null;
    final scheme = Theme.of(context).colorScheme;
    final code = (d['code'] ?? '').toString();
    final shareText = (d['share_text'] ?? '').toString();
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
      children: [
        // ---- code card (brand gradient, white text) ----
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(20),
            gradient: const LinearGradient(
                colors: [kBrandBlue, Color(0xFF0B8F6A)],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight),
          ),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(t.p5YourCode,
                style: const TextStyle(
                    color: Colors.white,
                    fontSize: 15,
                    fontWeight: FontWeight.w600)),
            const SizedBox(height: 6),
            SelectableText(code,
                key: const ValueKey('p5_code'),
                style: const TextStyle(
                    color: Colors.white,
                    fontSize: 32,
                    letterSpacing: 4,
                    fontWeight: FontWeight.w800)),
            const SizedBox(height: 12),
            Wrap(spacing: 8, runSpacing: 8, children: [
              _whiteButton(Icons.copy_rounded, t.p5Copy, () {
                Clipboard.setData(ClipboardData(text: code));
                ScaffoldMessenger.of(context)
                    .showSnackBar(SnackBar(content: Text(t.p5Copied)));
              }),
              _whiteButton(Icons.share_rounded, t.p5ShareInvite,
                  () => Share.share(shareText)),
              _whiteButton(Icons.image_rounded, t.p5ShareAsImage,
                  () => showBrandedShare(context,
                      body: shareText, label: t.p5InviteTitle)),
            ]),
          ]),
        ),
        const SizedBox(height: 16),
        // ---- how it works (honest rules from the server) ----
        _section(t.p5HowTitle, [
          _bullet(Icons.download_rounded,
              t.p5HowStep1(n(rules['claim_days']))),
          _bullet(Icons.event_available_rounded,
              t.p5HowStep2(n(rules['activation_days']), n(rules['inviter_credits']),
                  n(rules['invitee_credits']))),
          _bullet(Icons.phone_android_rounded,
              rules['phone_otp'] == true ? t.p5HowPhoneOtp : t.p5HowPhone),
          _bullet(Icons.calendar_month_rounded,
              t.p5HowCap(n(rules['monthly_cap']))),
          _bullet(Icons.info_outline_rounded, t.p5CreditsNotCash),
        ]),
        const SizedBox(height: 12),
        // ---- my invites ----
        _section(t.p5StatsTitle, [
          LayoutBuilder(builder: (ctx, c) {
            // two equal columns at any width / language (no orphan tile)
            final w = ((c.maxWidth - 8) / 2).floorToDouble();
            return Wrap(spacing: 8, runSpacing: 8, children: [
              _stat(t.p5StatJoined, n(stats['joined']), w),
              _stat(t.p5StatWaiting, n(stats['pending']), w),
              _stat(t.p5StatRewarded, n(stats['rewarded']), w),
              _stat(t.p5StatCredits, n(stats['credits_earned']), w),
            ]);
          }),
        ]),
        // ---- my own claim / enter a friend's code ----
        if (mine != null) ...[
          const SizedBox(height: 12),
          _section(t.p5EnterTitle, [_claimStatus(t, mine, rules, n)]),
        ] else if (d['can_claim'] == true) ...[
          const SizedBox(height: 12),
          _section(t.p5EnterTitle, [
            Row(children: [
              Expanded(
                child: TextField(
                  key: const ValueKey('p5_code_field'),
                  controller: _codeCtl,
                  textCapitalization: TextCapitalization.characters,
                  decoration: InputDecoration(
                      labelText: t.p5EnterHint,
                      border: const OutlineInputBorder()),
                  onSubmitted: (_) => _claim(),
                ),
              ),
              const SizedBox(width: 8),
              // disabled until a code is typed (never a dead tap)
              ValueListenableBuilder<TextEditingValue>(
                valueListenable: _codeCtl,
                builder: (_, v, __) => FilledButton(
                    onPressed:
                        (_claiming || v.text.trim().isEmpty) ? null : _claim,
                    child: Text(t.p5EnterButton)),
              ),
            ]),
            if (_claimMsg != null && _claimMsg!.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(_claimMsg!,
                    style: TextStyle(color: scheme.onSurfaceVariant)),
              ),
          ]),
        ],
        // ---- Founding Members (real seat numbers) ----
        if (founding['enabled'] == true || founding['number'] != null) ...[
          const SizedBox(height: 12),
          _section(t.p5FoundingTitle, _founding(t, founding, n)),
        ],
      ],
    );
  }

  List<Widget> _founding(AppLocalizations t, Map<String, dynamic> f,
      String Function(Object?) n) {
    final number = f['number'];
    if (number != null) {
      return [
        Row(children: [
          const FounderBadge(),
          const SizedBox(width: 8),
          Expanded(
              child: Text(t.p5FoundingYou(n(number)),
                  style: const TextStyle(fontWeight: FontWeight.w700))),
        ]),
        if ((f['my_credits'] ?? 0) is num && (f['my_credits'] as num) > 0)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(t.p5FoundingYouCredits(n(f['my_credits']))),
          ),
      ];
    }
    final taken = (f['taken'] ?? 0) as num;
    final seats = (f['seats'] ?? 0) as num;
    final act = Map<String, dynamic>.from((f['activation'] ?? {}) as Map);
    if (taken >= seats) return [Text(t.p5FoundingFull)];
    return [
      Text(t.p5FoundingOpen(n(taken), n(seats), n(act['need']), n(f['credits']))),
      const SizedBox(height: 6),
      Text(t.p5FoundingProgress(n(act['days']), n(act['need'])),
          style: const TextStyle(fontWeight: FontWeight.w600)),
    ];
  }

  Widget _claimStatus(AppLocalizations t, Map<String, dynamic> mine,
      Map<String, dynamic> rules, String Function(Object?) n) {
    final state = mine['state'];
    if (state == 'rewarded') {
      return Text(t.p5ClaimRewarded(n(mine['credits'])));
    }
    if (state == 'rejected') return Text(t.p5ClaimRejected);
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(t.p5ClaimPending(n(mine['need']), n(mine['days']))),
      if (mine['phone_ok'] != true)
        Padding(
          padding: const EdgeInsets.only(top: 6),
          child: Text(
              rules['phone_otp'] == true
                  ? t.p5ClaimNeedPhoneOtp
                  : t.p5ClaimNeedPhone,
              style: const TextStyle(fontWeight: FontWeight.w600)),
        ),
    ]);
  }

  Widget _whiteButton(IconData icon, String label, VoidCallback onTap) =>
      FilledButton.icon(
        style: FilledButton.styleFrom(
            backgroundColor: Colors.white,
            foregroundColor: const Color(0xFF0057B8)),
        onPressed: onTap,
        icon: Icon(icon, size: 18),
        label: Text(label),
      );

  Widget _section(String title, List<Widget> children) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(title,
              style: Theme.of(context)
                  .textTheme
                  .titleMedium
                  ?.copyWith(fontWeight: FontWeight.w700, color: scheme.onSurface)),
          const SizedBox(height: 10),
          ...children,
        ]),
      ),
    );
  }

  Widget _bullet(IconData icon, String text) => Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Icon(icon, size: 20, color: Theme.of(context).colorScheme.primary),
          const SizedBox(width: 10),
          Expanded(child: Text(text)),
        ]),
      );

  Widget _stat(String label, String value, double width) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: width,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(value,
            style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800)),
        Text(label, style: TextStyle(color: scheme.onSurfaceVariant)),
      ]),
    );
  }
}
