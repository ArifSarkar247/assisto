import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../feature_flags.dart';
import '../l10n/app_localizations.dart';
import '../screens/business/bizagent/seller_agent_screen.dart' show baErrorText, bd;
import '../state.dart';
import '../theme.dart';
import '../widgets/app_sheet.dart' show withNavBarInset;
import '../widgets/local_counter.dart';
import '../widgets/skeleton.dart';
import 'bizai_source.dart';
import 'shop_chat_screen.dart';

/// bizai: https://lifeassisto.com/shop/<code> (Android App Link) opens the
/// shop chat; any other route name returns null exactly as before.
class ShopChatLink {
  ShopChatLink._();

  static bool get _on => FeatureFlags.instance.isOn('business_agent');

  static Route<dynamic>? route(RouteSettings s) {
    final n = s.name ?? '';
    if (!n.contains('/shop/')) return null;
    final c = shopCodeFrom(n);
    if (c == null || !_on) return null;
    return MaterialPageRoute<void>(settings: s, builder: (_) => ShopChatScreen(code: c));
  }

  static bool _coldDone = false;

  static void maybeOpenColdStart(BuildContext context, String defaultRouteName) {
    if (_coldDone) return;
    _coldDone = true;
    if (!defaultRouteName.contains('/shop/')) return;
    final c = shopCodeFrom(defaultRouteName);
    if (c == null || !_on) return;
    try {
      Navigator.of(context)
          .push(MaterialPageRoute<void>(builder: (_) => ShopChatScreen(code: c)));
    } catch (_) {}
  }
}

/// bizai — the customer's shop chats: shops they already talk to + shops run
/// by their My Circle contacts (one tap), and "open a shop link".
class MyShopsScreen extends StatefulWidget {
  final BizaiSource? source;
  const MyShopsScreen({super.key, this.source});
  @override
  State<MyShopsScreen> createState() => _MyShopsScreenState();
}

class _MyShopsScreenState extends State<MyShopsScreen> {
  late final BizaiSource _src = widget.source ?? ApiBizaiSource(context.read<AppState>().api);
  List<Map<String, dynamic>> _rows = const [];
  bool _loading = true;
  Object? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final r = await _src.myShops();
      if (mounted) setState(() => _rows = r);
    } catch (e) {
      if (mounted) setState(() => _error = e);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _open(String code) async {
    await Navigator.of(context)
        .push(MaterialPageRoute<void>(builder: (_) => ShopChatScreen(code: code, source: widget.source)));
    if (mounted) _load();
  }

  Future<void> _enterLink() async {
    final t = AppLocalizations.of(context);
    final c = TextEditingController();
    final code = await showDialog<String>(
      context: context,
      builder: (ctx) {
        String? err;
        return StatefulBuilder(builder: (ctx, set) => AlertDialog(
              title: Text(t.bizaiOpenLink),
              content: TextField(
                key: const ValueKey('bizai-link-input'),
                controller: c,
                autofocus: true,
                maxLength: 200,
                buildCounter: localCounter,
                decoration: InputDecoration(hintText: t.bizaiPasteLinkHint, errorText: err),
              ),
              actions: [
                TextButton(onPressed: () => Navigator.pop(ctx), child: Text(t.bizaiCancel)),
                FilledButton(
                  onPressed: () {
                    final v = shopCodeFrom(c.text);
                    if (v == null) {
                      set(() => err = t.bizaiBadLink);
                    } else {
                      Navigator.pop(ctx, v);
                    }
                  },
                  child: Text(t.bizaiOpen),
                ),
              ],
            ));
      },
    );
    c.dispose();
    if (code != null && mounted) _open(code);
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(t.bizaiMyShopsTitle)),
      body: _body(t),
    );
  }

  Widget _body(AppLocalizations t) {
    if (_loading) return const SkeletonList();
    if (_error != null) {
      return StateMessage(
        icon: Icons.cloud_off_rounded,
        title: t.bizaiShopLoadFailed,
        message: baErrorText(t, _error!),
        action: FilledButton(onPressed: _load, child: Text(t.bizRetry)),
      );
    }
    if (_rows.isEmpty) {
      return ListView(padding: withNavBarInset(context, const EdgeInsets.all(Gap.lg)), children: [
        Icon(Icons.storefront_rounded, size: 56, color: Theme.of(context).colorScheme.primary),
        const SizedBox(height: Gap.md),
        Text(t.bizaiMyShopsEmpty,
            textAlign: TextAlign.center, style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: Gap.sm),
        Text(t.bizaiMyShopsHow, textAlign: TextAlign.center),
        const SizedBox(height: Gap.lg),
        FilledButton.icon(
          key: const ValueKey('bizai-open-link'),
          style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
          onPressed: _enterLink,
          icon: const Icon(Icons.link_rounded),
          label: Text(t.bizaiOpenLink),
        ),
      ]);
    }
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(padding: withNavBarInset(context, const EdgeInsets.all(Gap.md)), children: [
        for (final r in _rows)
          Card(
            child: ListTile(
              minVerticalPadding: Gap.md,
              leading: const CircleAvatar(child: Icon(Icons.storefront_rounded)),
              title: Text('${r['shop'] ?? ''}', maxLines: 2, overflow: TextOverflow.ellipsis),
              subtitle: Text(r['circle'] == true ? t.bizaiFromCircle : bd(context, r['last']),
                  maxLines: 2, overflow: TextOverflow.ellipsis),
              trailing: const Icon(Icons.chevron_right_rounded),
              onTap: () => _open('${r['code']}'),
            ),
          ),
        const SizedBox(height: Gap.md),
        OutlinedButton.icon(
          key: const ValueKey('bizai-open-link'),
          style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(48)),
          onPressed: _enterLink,
          icon: const Icon(Icons.link_rounded),
          label: Text(t.bizaiOpenLink),
        ),
      ]),
    );
  }
}
