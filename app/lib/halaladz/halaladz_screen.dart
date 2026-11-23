import 'dart:async';
import 'dart:io' show SocketException;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../api.dart';
import '../invite/space_link.dart';
import '../l10n/app_localizations.dart';
import '../screens/messenger/communities_home_screen.dart' show SpaceLinkScreen;
import '../state.dart';
import '../widgets/app_sheet.dart';
import '../widgets/local_counter.dart';
import '../widgets/local_digits.dart';
import '../widgets/space_invite_sheet.dart';
import 'halaladz_api.dart';
import 'halaladz_link.dart';
import 'halaladz_support_screen.dart';

/// halaladz — Settings > "Link HalalAdz account".
///
/// One screen: link (8-character code, or filled in from the deep link
/// assisto://link-halaladz?code=CODE) / the linked account name + Unlink,
/// the HalalAdz support chat (unread count) and the official HalalAdz
/// channel + community (open, or share link + QR). Linking is optional —
/// HalalAdz works without Assisto and nothing here says otherwise.
class HalalAdzScreen extends StatefulWidget {
  const HalalAdzScreen({super.key, this.initialCode = '', this.api});

  /// Code from the deep link ('' = type it).
  final String initialCode;

  /// Tests inject a client; the app uses AppState.api.
  final ApiClient? api;

  @override
  State<HalalAdzScreen> createState() => _HalalAdzScreenState();
}

class _HalalAdzScreenState extends State<HalalAdzScreen> {
  late final TextEditingController _code =
      TextEditingController(text: widget.initialCode);
  Map<String, dynamic>? _st;
  bool _loading = true;
  bool _error = false;
  bool _busy = false;
  String? _formError;

  ApiClient get _api => widget.api ?? context.read<AppState>().api;

  @override
  void initState() {
    super.initState();
    if (widget.api == null) {
      final app = context.read<AppState>();
      if (!app.loggedIn) {
        // a deep link that arrived signed out: open again after sign-in
        HalalAdzDeepLink.pending = widget.initialCode;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) Navigator.of(context).maybePop();
        });
        return;
      }
    }
    _load();
  }

  @override
  void dispose() {
    _code.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = false;
    });
    try {
      final j = await _api.hzStatus();
      if (!mounted) return;
      setState(() {
        _st = j;
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = true;
      });
    }
  }

  void _toast(String s) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(s)));

  Future<void> _link() async {
    final t = AppLocalizations.of(context);
    final code = normHzCode(_code.text);
    if (code == null) {
      setState(() => _formError = t.hzCodeBad);
      return;
    }
    setState(() {
      _busy = true;
      _formError = null;
    });
    try {
      final r = await _api.hzLink(code);
      if (!mounted) return;
      if (r['_status'] == 200 && r['linked'] == true) {
        _code.clear();
        _toast(t.hzLinkedNoName);
        await _load();
      } else {
        final m = '${r['message'] ?? ''}';
        setState(() => _formError = m.isNotEmpty ? m : t.hzErrGeneric);
      }
    } on SocketException {
      if (mounted) setState(() => _formError = t.hzErrNetwork);
    } catch (_) {
      if (mounted) setState(() => _formError = t.hzErrNetwork);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _unlink() async {
    final t = AppLocalizations.of(context);
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text(t.hzUnlinkConfirmTitle),
        content: Text(t.hzUnlinkConfirmBody),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(c, false), child: Text(t.hzCancel)),
          FilledButton(
              key: const Key('hz-unlink-confirm'),
              onPressed: () => Navigator.pop(c, true),
              child: Text(t.hzUnlink)),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    setState(() => _busy = true);
    try {
      await _api.hzUnlink();
      if (!mounted) return;
      _toast(t.hzUnlinked);
      await _load();
    } catch (_) {
      if (mounted) _toast(t.hzErrGeneric);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _openSpace(String url) {
    final l = SpaceLink.parse(url);
    if (l == null) return;
    Navigator.push(context,
        MaterialPageRoute(builder: (_) => SpaceLinkScreen(link: l)));
  }

  void _share(String url, String title) {
    showAppSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (_) => SpaceInviteSheet(url: url, title: title),
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(t.hzScreenTitle)),
      body: SafeArea(child: _body(t)),
    );
  }

  Widget _body(AppLocalizations t) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error || _st == null) {
      return _Message(
          key: const Key('hz-error'),
          icon: Icons.wifi_off_rounded,
          text: t.hzErrNetwork,
          button: t.hzRetry,
          onTap: _load);
    }
    final st = _st!;
    if (st['enabled'] != true) {
      return _Message(
          key: const Key('hz-off'),
          icon: Icons.link_off_rounded,
          text: t.hzOff,
          button: t.hzBack,
          onTap: () => Navigator.of(context).maybePop());
    }
    final linked = st['linked'] == true;
    final acc = (st['account'] as Map?) ?? const {};
    final name = '${acc['display_name'] ?? ''}'.trim();
    final unread = (st['support_unread'] as num?)?.toInt() ?? 0;
    final off = (st['official'] as Map?) ?? const {};
    final chUrl = '${off['channel_url'] ?? ''}';
    final cmUrl = '${off['community_url'] ?? ''}';
    return ListView(
      padding: withNavBarInset(context, const EdgeInsets.all(16)),
      children: [
        if (linked)
          Card(
            key: const Key('hz-linked'),
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(children: [
                    Icon(Icons.verified_rounded,
                        color: Theme.of(context).colorScheme.primary),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                          name.isEmpty ? t.hzLinkedNoName : t.hzLinkedAs(name),
                          style: Theme.of(context).textTheme.titleMedium),
                    ),
                  ]),
                  const SizedBox(height: 8),
                  Text(t.hzLinkedBenefit),
                  const SizedBox(height: 8),
                  Align(
                    alignment: AlignmentDirectional.centerEnd,
                    child: TextButton.icon(
                      key: const Key('hz-unlink'),
                      onPressed: _busy ? null : _unlink,
                      icon: const Icon(Icons.link_off_rounded),
                      label: Text(t.hzUnlink),
                    ),
                  ),
                ],
              ),
            ),
          )
        else
          Card(
            key: const Key('hz-link-form'),
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(t.hzLinkIntro),
                  if (widget.initialCode.isNotEmpty) ...[
                    const SizedBox(height: 8),
                    Text(t.hzDeepLinkNote,
                        key: const Key('hz-deeplink-note'),
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                            color: Theme.of(context).colorScheme.primary)),
                  ],
                  const SizedBox(height: 12),
                  TextField(
                    key: const Key('hz-code'),
                    controller: _code,
                    maxLength: 12,
                    buildCounter: localCounter,
                    textCapitalization: TextCapitalization.characters,
                    autocorrect: false,
                    enableSuggestions: false,
                    decoration: InputDecoration(
                      labelText: t.hzCodeLabel,
                      errorText: _formError,
                      errorMaxLines: 4,
                      border: const OutlineInputBorder(),
                    ),
                    onSubmitted: (_) => _busy ? null : _link(),
                  ),
                  const SizedBox(height: 8),
                  FilledButton(
                    key: const Key('hz-link-btn'),
                    style: FilledButton.styleFrom(
                        minimumSize: const Size.fromHeight(48)),
                    onPressed: _busy ? null : _link,
                    child: Text(_busy ? t.hzLinking : t.hzLinkButton),
                  ),
                  const SizedBox(height: 8),
                  Text(t.hzOptionalNote,
                      style: Theme.of(context).textTheme.bodySmall),
                ],
              ),
            ),
          ),
        const SizedBox(height: 12),
        Card(
          child: ListTile(
            key: const Key('hz-support'),
            minVerticalPadding: 12,
            leading: const Icon(Icons.support_agent_rounded),
            title: Text(t.hzSupportTitle),
            subtitle: Text(t.hzSupportTileSub),
            trailing: unread > 0
                ? Badge(label: Text(ld(context, unread)))
                : const Icon(Icons.chevron_right_rounded),
            onTap: () async {
              await Navigator.push(
                  context,
                  MaterialPageRoute(
                      builder: (_) => HalalAdzSupportScreen(api: widget.api)));
              if (mounted) unawaited(_load());
            },
          ),
        ),
        if (chUrl.isNotEmpty || cmUrl.isNotEmpty) ...[
          const SizedBox(height: 12),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
            child: Text(t.hzCommunityTitle,
                style: Theme.of(context).textTheme.titleMedium),
          ),
          if (chUrl.isNotEmpty)
            _SpaceCard(
              key: const Key('hz-channel'),
              icon: Icons.campaign_rounded,
              title: t.hzCommunityChannel,
              share: t.hzCommunityShare,
              onOpen: () => _openSpace(chUrl),
              onShare: () => _share(chUrl, t.hzCommunityChannel),
            ),
          if (cmUrl.isNotEmpty)
            _SpaceCard(
              key: const Key('hz-community'),
              icon: Icons.groups_rounded,
              title: t.hzCommunityGroup,
              share: t.hzCommunityShare,
              onOpen: () => _openSpace(cmUrl),
              onShare: () => _share(cmUrl, t.hzCommunityGroup),
            ),
        ],
      ],
    );
  }
}

class _SpaceCard extends StatelessWidget {
  const _SpaceCard(
      {super.key,
      required this.icon,
      required this.title,
      required this.share,
      required this.onOpen,
      required this.onShare});

  final IconData icon;
  final String title;
  final String share;
  final VoidCallback onOpen;
  final VoidCallback onShare;

  @override
  Widget build(BuildContext context) => Card(
        child: ListTile(
          minVerticalPadding: 12,
          leading: Icon(icon),
          title: Text(title),
          onTap: onOpen,
          trailing: IconButton(
            tooltip: share,
            icon: const Icon(Icons.qr_code_rounded),
            onPressed: onShare,
          ),
        ),
      );
}

class _Message extends StatelessWidget {
  const _Message(
      {super.key,
      required this.icon,
      required this.text,
      required this.button,
      required this.onTap});

  final IconData icon;
  final String text;
  final String button;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Icon(icon, size: 48),
            const SizedBox(height: 12),
            Text(text, textAlign: TextAlign.center),
            const SizedBox(height: 16),
            FilledButton(
                style: FilledButton.styleFrom(minimumSize: const Size(160, 48)),
                onPressed: onTap,
                child: Text(button)),
          ]),
        ),
      );
}
