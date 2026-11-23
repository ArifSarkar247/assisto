import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../api.dart';
import '../l10n/app_localizations.dart';
import '../state.dart';
import '../widgets/local_digits.dart';
import 'halaladz_api.dart';
import 'halaladz_screen.dart';

/// halaladz — the Settings tile "Link HalalAdz account". Draws NOTHING until
/// the server says the feature is on (no secret on the server = no tile, never
/// a dead button). Shows the linked account name and unread support replies.
class HalalAdzSettingsTile extends StatefulWidget {
  const HalalAdzSettingsTile({super.key, this.api});

  final ApiClient? api;

  @override
  State<HalalAdzSettingsTile> createState() => _HalalAdzSettingsTileState();
}

class _HalalAdzSettingsTileState extends State<HalalAdzSettingsTile> {
  Map<String, dynamic>? _st;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final api = widget.api ?? context.read<AppState>().api;
      final j = await api.hzStatus();
      if (mounted) setState(() => _st = j);
    } catch (_) {/* offline / old server: no tile */}
  }

  @override
  Widget build(BuildContext context) {
    final st = _st;
    if (st == null || st['enabled'] != true) return const SizedBox.shrink();
    final t = AppLocalizations.of(context);
    final name = '${((st['account'] as Map?) ?? const {})['display_name'] ?? ''}'.trim();
    final linked = st['linked'] == true;
    final unread = (st['support_unread'] as num?)?.toInt() ?? 0;
    return ListTile(
      key: const Key('settings-halaladz'),
      leading: const Icon(Icons.link_rounded),
      title: Text(t.hzTile),
      subtitle: Text(linked
          ? (name.isEmpty ? t.hzLinkedNoName : t.hzLinkedAs(name))
          : t.hzTileSub),
      trailing: unread > 0 ? Badge(label: Text(ld(context, unread))) : null,
      onTap: () async {
        await Navigator.push(context,
            MaterialPageRoute(builder: (_) => HalalAdzScreen(api: widget.api)));
        if (mounted) _load();
      },
    );
  }
}
