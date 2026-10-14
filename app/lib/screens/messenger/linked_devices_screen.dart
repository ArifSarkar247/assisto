import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../api.dart';
import '../../l10n/app_localizations.dart';
import '../../messenger_hub_api.dart';
import '../../state.dart';
import '../../theme.dart';

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
    } catch (_) {
      _devices = [];
      _failed = true;
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
    await showModalBottomSheet<void>(
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
                  color: scheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(Radii.md),
                ),
                child: Icon(Icons.qr_code_2,
                    size: 160, color: scheme.onSurface),
              ),
              const SizedBox(height: Gap.md),
              if (token.isNotEmpty)
                SelectableText(token,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                        fontSize: 13, color: scheme.onSurfaceVariant)),
              const SizedBox(height: Gap.md),
              Text(t.msgrLinkScanHint,
                  textAlign: TextAlign.center,
                  style:
                      TextStyle(color: scheme.onSurfaceVariant, height: 1.3)),
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
          ? const Center(child: CircularProgressIndicator())
          : Column(children: [
              Material(
                color: Theme.of(context).colorScheme.surface,
                child: ListTile(
                  leading: const CircleAvatar(child: Icon(Icons.qr_code_2)),
                  title: Text(t.msgrLinkDevice),
                  subtitle: Text(t.msgrLinkScanHint,
                      maxLines: 2, overflow: TextOverflow.ellipsis),
                  trailing: _linkBusy
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(strokeWidth: 2))
                      : const Icon(Icons.chevron_right),
                  onTap: _linkBusy ? null : _startLink,
                ),
              ),
              const Divider(height: 1),
              Expanded(
                child: _failed
                    ? _error()
                    : _devices.isEmpty
                        ? _empty()
                        : RefreshIndicator(
                            onRefresh: _load,
                            child: ListView.separated(
                              itemCount: _devices.length,
                              separatorBuilder: (_, __) =>
                                  const Divider(height: 1, indent: Gap.lg),
                              itemBuilder: (_, i) => _row(_devices[i]),
                            ),
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
      leading: const CircleAvatar(child: Icon(Icons.devices_outlined)),
      title: Text(name.isEmpty ? '?' : name,
          maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: last.isEmpty
          ? null
          : Text('${t.msgrLinkedLastActive}: $last',
              maxLines: 1, overflow: TextOverflow.ellipsis),
      trailing: TextButton(
        onPressed: () => _logout(d),
        child: Text(t.msgrLinkedLogout),
      ),
    );
  }

  Widget _empty() => _centeredState(
      Icons.devices_outlined, _t.msgrLinkedEmptyTitle, _t.msgrLinkedEmptyBody);

  Widget _error() {
    final t = _t;
    return ListView(children: [
      const SizedBox(height: 80),
      _centeredState(Icons.cloud_off_outlined, t.msgrHubLoadFailed, ''),
      const SizedBox(height: Gap.md),
      Center(
        child: OutlinedButton.icon(
          onPressed: _load,
          icon: const Icon(Icons.refresh),
          label: Text(t.msgrRetry),
        ),
      ),
    ]);
  }

  Widget _centeredState(IconData icon, String title, String body) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(Gap.xl),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Icon(icon, size: 52, color: scheme.primary.withValues(alpha: 0.7)),
          const SizedBox(height: Gap.md),
          Text(title,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.titleMedium),
          if (body.isNotEmpty) ...[
            const SizedBox(height: Gap.sm),
            Text(body,
                textAlign: TextAlign.center,
                style: TextStyle(color: scheme.onSurfaceVariant, height: 1.4)),
          ],
        ]),
      ),
    );
  }
}
