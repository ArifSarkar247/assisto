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

/// MY CIRCLE HUB ⋮ → Linked devices (SPEC §2).
///
/// Shows the QR/link token minted by the backend (`link-start`) so a web or
/// desktop client can link, lists the already-linked devices with their last
/// active time, and lets the user log each one out. The link payload is
/// NON-SECRET (a short-lived session token, never a private key) — chats stay
/// end-to-end encrypted.
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
  bool _linkBusy = false;
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

  Future<void> _startLink() async {
    setState(() => _linkBusy = true);
    Map<String, dynamic>? payload;
    try {
      payload = await _api.hubLinkStart();
    } catch (_) {
      payload = null;
    }
    if (!mounted) return;
    setState(() => _linkBusy = false);
    if (payload == null) {
      _snack(_t.msgrLinkStartFailed);
      return;
    }
    await _showQrSheet(payload);
    if (mounted) _load();
  }

  Future<void> _showQrSheet(Map<String, dynamic> payload) async {
    final t = _t;
    final token = '${payload['token'] ?? payload['qr'] ?? ''}';
    await showAppSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (ctx) {
        final scheme = Theme.of(ctx).colorScheme;
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(Gap.xl),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Text(t.msgrLinkDevice,
                  style: Theme.of(ctx).textTheme.titleMedium),
              const SizedBox(height: Gap.lg),
              // The server returns the token; we render it as a scannable
              // block. A full QR bitmap is drawn by the web client that reads
              // this token — here we show the code the user confirms.
              Container(
                padding: const EdgeInsets.all(Gap.lg),
                decoration: BoxDecoration(
                  color: scheme.ds.cardHighest,
                  borderRadius: BorderRadius.circular(Radii.md),
                ),
                child: Icon(Icons.qr_code_2_rounded,
                    size: 160, color: scheme.ds.text),
              ),
              const SizedBox(height: Gap.md),
              if (token.isNotEmpty)
                SelectableText(token,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                        fontSize: 13, color: scheme.ds.muted)),
              const SizedBox(height: Gap.md),
              Text(t.msgrLinkScanHint,
                  textAlign: TextAlign.center,
                  style:
                      TextStyle(color: scheme.ds.muted, height: 1.3)),
            ]),
          ),
        );
      },
    );
  }

  Future<void> _logout(Map<String, dynamic> d) async {
    final t = _t;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        scrollable: true, // insets: 200% text / keyboard
        title: Text(t.msgrLinkedLogoutTitle),
        content: Text(t.msgrLinkedLogoutBody),
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
                  leading: DsAvatar(child: Icon(Icons.qr_code_2_rounded,
                      color: Theme.of(context).colorScheme.ds.primaryInk)),
                  title: Text(t.msgrLinkDevice,
                      style: AType.titleMedium.copyWith(fontWeight: FontWeight.w700)),
                  subtitle: Text(t.msgrLinkScanHint),
                  trailing: _linkBusy
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(strokeWidth: 2))
                      : const Icon(Icons.chevron_right_rounded),
                  onTap: _linkBusy ? null : _startLink,
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
    final name = '${d['name'] ?? d['platform'] ?? ''}';
    final last = '${d['last_active'] ?? d['linked_at'] ?? ''}';
    return ListTile(
      leading: DsAvatar(size: 40, child: Icon(Icons.devices_rounded, size: 20,
          color: Theme.of(context).colorScheme.ds.primaryInk)),
      title: Text(name.isEmpty ? '?' : name),
      subtitle: last.isEmpty
          ? null
          : Text('${t.msgrLinkedLastActive}: $last'),
      trailing: TextButton(
        onPressed: () => _logout(d),
        child: Text(t.msgrLinkedLogout),
      ),
    );
  }

  Widget _empty() => _centeredState(
      Icons.devices_rounded, _t.msgrLinkedEmptyTitle, _t.msgrLinkedEmptyBody);

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

  Widget _centeredState(IconData icon, String title, String body) =>
      MsgrEmptyState(icon: icon, title: title, body: body);
}
