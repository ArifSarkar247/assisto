import 'package:flutter/material.dart';
import '../../widgets/msgr_channel_common.dart' show MsgrEmptyState;
import '../../ds/ds.dart';
import '../../widgets/skeleton.dart' show SkeletonList;
import 'package:provider/provider.dart';

import '../../api.dart';
import '../../l10n/app_localizations.dart';
import '../../messenger_hub_api.dart';
import '../../state.dart';
import '../../theme.dart';
import 'package:assisto/widgets/app_sheet.dart';
import '../../services/error_kind.dart' show serverFailText; // qa2
import '../../widgets/notif_models.dart' show notifAgo; // circle-extras
import 'link_phone_sheet.dart'; // circle-extras

/// MY CIRCLE HUB ⋮ → Linked devices (SPEC §2).
///
/// circle-extras (row 50): "Link a phone" shows a real QR + 8-character code
/// for a SECOND PHONE (its sign-in page → "Link to my main phone"); the list
/// shows each linked phone with its last use; "Log out" signs that phone out
/// at once (server revokes its session). Chats stay end-to-end encrypted:
/// the key ring is sealed to the new phone on this phone.
///
/// Degrades to honest loading / empty / error states while the backend agent
/// finishes the endpoints — no dead taps.
class LinkedDevicesScreen extends StatefulWidget {
  const LinkedDevicesScreen({super.key});

  @override
  State<LinkedDevicesScreen> createState() => _LinkedDevicesScreenState();
}

class _LinkedDevicesScreenState extends State<LinkedDevicesScreen> {
  bool _loading = true;
  bool _failed = false;
  Object? _failCause; // qa2: why it failed (5xx = our server, not the internet)
  List<Map<String, dynamic>> _devices = [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  ApiClient get _api => context.read<AppState>().api;
  AppLocalizations get _t => AppLocalizations.of(context);

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _failed = false;
    });
    try {
      _devices = (await _api.hubLinkedDevices())
          .where((d) => d['revoked'] != true)
          .toList();
      _failed = false;
    } catch (e) {
      _devices = [];
      _failed = true;
      _failCause = e;
    }
    if (mounted) setState(() => _loading = false);
  }

  /// circle-extras: the real QR + 8-character code, live status, confirm
  /// with the SAME 6 digits as the new phone, then the key ring is sealed
  /// on this phone to the new phone's one-time key (lib/crypto/device_link).
  Future<void> _startLink() async {
    final linked = await showAppSheet<String>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (_) => LinkPhoneSheet(api: _api),
    );
    if (!mounted) return;
    if (linked != null) _snack(_t.dlkLinkedOk(linked));
    _load();
  }

  Future<void> _logout(Map<String, dynamic> d) async {
    final t = _t;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        scrollable: true, // insets: 200% text / keyboard
        title: Text(t.msgrLinkedLogoutTitle),
        content: Text(t.dlkUnlinkBody),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(MaterialLocalizations.of(ctx).cancelButtonLabel)),
          FilledButton(
            style: FilledButton.styleFrom(
                backgroundColor: Theme.of(ctx).colorScheme.error),
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(t.msgrLinkedLogout),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    final id = '${d['id'] ?? d['device_id'] ?? ''}';
    setState(() => _devices.removeWhere(
        (x) => '${x['id'] ?? x['device_id'] ?? ''}' == id));
    try {
      await _api.hubRevokeDevice(id);
    } catch (_) {
      // Revert on failure so we never silently lie about the state.
      if (mounted) _load();
    }
  }

  void _snack(String m) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));

  @override
  Widget build(BuildContext context) {
    final t = _t;
    return Scaffold(
      appBar: AppBar(title: Text(t.msgrLinkedTitle)),
      body: _loading
          ? const SkeletonList(count: 4)
          : Column(children: [
              // linking a device = the main action, as the soft DS hero
              Padding(
                padding: const EdgeInsets.fromLTRB(Gap.lg, Gap.md, Gap.lg, Gap.sm),
                child: DsHeroCard(
                padding: const EdgeInsets.symmetric(vertical: Gap.sm),
                child: ListTile(
                  key: const Key('dlk-start'),
                  leading: DsAvatar(child: Icon(Icons.qr_code_2_rounded,
                      color: Theme.of(context).colorScheme.ds.primaryInk)),
                  title: Text(t.msgrLinkDevice,
                      style: AType.titleMedium.copyWith(fontWeight: FontWeight.w700)),
                  subtitle: Text(t.dlkHeroSub),
                  trailing: const Icon(Icons.chevron_right_rounded),
                  onTap: _startLink,
                ),
              )),
              Expanded(
                child: _failed
                    ? _error()
                    : _devices.isEmpty
                        ? _empty()
                        : RefreshIndicator(
                            onRefresh: _load,
                            // the linked devices as one DS group
                            child: ListView(children: [
                              DsGroup(children: [for (final d in _devices) _row(d)]),
                            ]),
                          ),
              ),
            ]),
    );
  }

  Widget _row(Map<String, dynamic> d) {
    final t = _t;
    final name = '${d['name'] ?? ''}'.trim();
    final plat = '${d['platform_label'] ?? d['platform'] ?? ''}';
    // circle-extras: "5 min ago" with Bangla digits (was a raw ISO string)
    final last = notifAgo(context, '${d['last_active'] ?? d['linked_at'] ?? ''}');
    final current = d['current'] == true;
    return ListTile(
      key: ValueKey('dlk-row-${d['device_id'] ?? d['id']}'),
      leading: DsAvatar(size: 40, child: Icon(Icons.smartphone_rounded, size: 20,
          color: Theme.of(context).colorScheme.ds.primaryInk)),
      title: Text(name.isEmpty ? (plat.isEmpty ? t.dlkUnnamedPhone : plat) : name),
      subtitle: Text([
        if (current) t.dlkThisPhone,
        if (last.isNotEmpty) '${t.msgrLinkedLastActive}: $last',
      ].join(' · ')),
      trailing: current
          ? null
          : TextButton(
              key: ValueKey('dlk-unlink-${d['device_id'] ?? d['id']}'),
              onPressed: () => _logout(d),
              child: Text(t.msgrLinkedLogout),
            ),
    );
  }

  Widget _empty() => ListView(padding: const EdgeInsets.all(Gap.lg), children: [
        MsgrEmptyState(
          icon: Icons.devices_rounded,
          title: _t.msgrLinkedEmptyTitle,
          body: _t.dlkEmptyBody,
          action: DsButton(
              onPressed: _startLink, icon: Icons.qr_code_2_rounded, label: _t.dlkSheetTitle),
        ),
      ]);

  Widget _error() {
    final t = _t;
    return ListView(padding: const EdgeInsets.all(Gap.lg), children: [
      const SizedBox(height: Gap.xl),
      MsgrEmptyState(
        icon: Icons.cloud_off_rounded,
        title: t.msgrHubLoadFailed,
        body: serverFailText(t, _failCause) ?? '',
        action: DsButton(onPressed: _load, icon: Icons.refresh_rounded, label: t.msgrRetry),
      ),
    ]);
  }

}
