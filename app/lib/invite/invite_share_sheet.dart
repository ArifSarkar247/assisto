import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import '../l10n/app_localizations.dart';
import '../state.dart';
import '../theme.dart';
import 'invite_api.dart';

/// invite-join — the INVITER side: one sheet that makes a short link and
/// sends it the way people in Bangladesh actually send things.
///
///   WhatsApp (wa.me, the user presses send) · SMS (own SIM composer) ·
///   imo / Messenger / more (the system share sheet — imo has no public
///   "send text" link, so we never pretend) · QR · Copy
///
/// The message is short Bangla (or English) from the server, with the link.
/// Nothing is ever sent automatically.
Future<void> showInviteShareSheet(BuildContext context,
    {InviteBackend? backend, String relation = 'friend'}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (_) => InviteShareSheet(backend: backend, relation: relation),
  );
}

String _bnDigits(String s, bool bn) {
  if (!bn) return s;
  return String.fromCharCodes(
      s.codeUnits.map((c) => (c >= 0x30 && c <= 0x39) ? 0x09E6 + (c - 0x30) : c));
}

class InviteShareSheet extends StatefulWidget {
  final InviteBackend? backend;
  final String relation;

  /// Tests: capture what would be launched / shared instead of the platform.
  final Future<bool> Function(Uri uri)? launcher;
  final Future<void> Function(String text)? sharer;

  const InviteShareSheet(
      {super.key, this.backend, this.relation = 'friend', this.launcher, this.sharer});

  @override
  State<InviteShareSheet> createState() => _InviteShareSheetState();
}

class _InviteShareSheetState extends State<InviteShareSheet> {
  final _label = TextEditingController();
  bool _group = false;
  bool _busy = false;
  String? _error;
  Map<String, dynamic>? _inv; // the created invite (made on first send)

  InviteBackend get _b =>
      widget.backend ?? ApiInviteBackend(context.read<AppState>().api);

  @override
  void dispose() {
    _label.dispose();
    super.dispose();
  }

  /// Make the invite once (label / group choice fixed at that moment).
  Future<Map<String, dynamic>?> _ensure() async {
    if (_inv != null) return _inv;
    final t = AppLocalizations.of(context);
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final r = await _b
          .create(
              relation: widget.relation,
              label: _label.text.trim(),
              maxUses: _group ? 10 : 1)
          .timeout(const Duration(seconds: 15));
      if (!mounted) return null;
      if (!inviteOk(r)) {
        setState(() => _error = '${r['detail'] ?? t.ijOffline}');
        return null;
      }
      setState(() => _inv = r);
      return r;
    } catch (_) {
      if (mounted) setState(() => _error = t.ijOffline);
      return null;
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<bool> _launch(Uri u) => widget.launcher != null
      ? widget.launcher!(u)
      : launchUrl(u, mode: LaunchMode.externalApplication);

  Future<void> _share(String text) =>
      widget.sharer != null ? widget.sharer!(text) : Share.share(text);

  Future<void> _via(String how) async {
    final inv = await _ensure();
    if (inv == null || !mounted) return;
    final t = AppLocalizations.of(context);
    final text = '${inv['share_text'] ?? ''}';
    final link = '${inv['link'] ?? ''}';
    try {
      switch (how) {
        case 'whatsapp':
          final ok = await _launch(
              Uri.parse('https://wa.me/?text=${Uri.encodeComponent(text)}'));
          if (!ok) await _share(text);
        case 'sms':
          final ok = await _launch(Uri.parse('sms:?body=${Uri.encodeComponent(text)}'));
          if (!ok) await _share(text);
        case 'copy':
          await Clipboard.setData(ClipboardData(text: link));
          if (mounted) {
            ScaffoldMessenger.maybeOf(context)
                ?.showSnackBar(SnackBar(content: Text(t.ijCopied)));
          }
        case 'qr':
          if (!mounted) return;
          await showDialog<void>(
            context: context,
            builder: (ctx) => AlertDialog(
              title: Text(t.ijShowQr),
              content: Column(mainAxisSize: MainAxisSize.min, children: [
                Container(
                  key: const Key('ij-qr'),
                  padding: const EdgeInsets.all(Gap.md),
                  decoration: BoxDecoration(
                      color: Colors.white, // dark-on-white: every scanner reads it
                      borderRadius: BorderRadius.circular(Radii.md)),
                  child: SizedBox.square(
                      dimension: 200, child: QrImageView(data: link, size: 200)),
                ),
                const SizedBox(height: Gap.sm),
                SelectableText(link, textAlign: TextAlign.center),
              ]),
              actions: [
                TextButton(
                    onPressed: () => Navigator.pop(ctx), child: Text(t.close)),
              ],
            ),
          );
        default:
          await _share(text);
      }
    } catch (_) {
      if (mounted) setState(() => _error = t.ijShareFailed);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final bn = Localizations.localeOf(context).languageCode == 'bn';
    final inv = _inv;
    return Padding(
      padding: EdgeInsets.only(
          left: Gap.lg,
          right: Gap.lg,
          bottom: MediaQuery.of(context).viewInsets.bottom + Gap.lg),
      child: SingleChildScrollView(
        child: Column(
          key: const Key('ij-share-sheet'),
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(t.ijShareTitle, style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: Gap.xs),
            Text(t.ijShareLead,
                style: TextStyle(color: scheme.onSurfaceVariant, height: 1.4)),
            const SizedBox(height: Gap.md),
            TextField(
              key: const Key('ij-label'),
              controller: _label,
              enabled: inv == null,
              maxLength: 60,
              decoration: InputDecoration(
                  labelText: t.ijForWhom,
                  hintText: t.ijForWhomHint,
                  prefixIcon: const Icon(Icons.person_add_alt_1_rounded)),
            ),
            SwitchListTile(
              key: const Key('ij-group'),
              contentPadding: EdgeInsets.zero,
              value: _group,
              onChanged: inv == null ? (v) => setState(() => _group = v) : null,
              title: Text(t.ijGroupLink),
              subtitle: Text(t.ijGroupLinkSub),
            ),
            if (inv != null) ...[
              Card(
                key: const Key('ij-preview'),
                child: Padding(
                  padding: const EdgeInsets.all(Gap.md),
                  child: Text('${inv['share_text'] ?? ''}',
                      style: const TextStyle(height: 1.4)),
                ),
              ),
              Text(t.ijExpiresIn(_bnDigits('7', bn)),
                  style: TextStyle(color: scheme.onSurfaceVariant)),
              const SizedBox(height: Gap.sm),
            ],
            if (_busy) const LinearProgressIndicator(),
            const SizedBox(height: Gap.sm),
            Wrap(
              spacing: Gap.sm,
              runSpacing: Gap.sm,
              alignment: WrapAlignment.center,
              children: [
                _btn('whatsapp', Icons.chat_rounded, t.ijViaWhatsApp, primary: true),
                _btn('sms', Icons.sms_rounded, t.ijViaSms),
                _btn('more', Icons.share_rounded, t.ijViaMore),
                _btn('qr', Icons.qr_code_2_rounded, t.ijShowQr),
                _btn('copy', Icons.copy_rounded, t.ijCopyLink),
              ],
            ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(top: Gap.sm),
                child: Text(_error!,
                    key: const Key('ij-share-error'),
                    style: TextStyle(color: scheme.error)),
              ),
          ],
        ),
      ),
    );
  }

  Widget _btn(String how, IconData icon, String label, {bool primary = false}) {
    final style = FilledButton.styleFrom(minimumSize: const Size(48, 48));
    final child = primary
        ? FilledButton.icon(
            key: Key('ij-via-$how'),
            style: style,
            onPressed: _busy ? null : () => _via(how),
            icon: Icon(icon),
            label: Text(label))
        : FilledButton.tonalIcon(
            key: Key('ij-via-$how'),
            style: style,
            onPressed: _busy ? null : () => _via(how),
            icon: Icon(icon),
            label: Text(label));
    return child;
  }
}

/// "Invited, not joined yet" — every link I sent, who joined, resend/cancel.
class InviteSentScreen extends StatefulWidget {
  final InviteBackend? backend;
  const InviteSentScreen({super.key, this.backend});

  @override
  State<InviteSentScreen> createState() => _InviteSentScreenState();
}

class _InviteSentScreenState extends State<InviteSentScreen> {
  List<Map<String, dynamic>>? _rows;
  bool _offline = false;

  InviteBackend get _b =>
      widget.backend ?? ApiInviteBackend(context.read<AppState>().api);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  Future<void> _load() async {
    setState(() => _offline = false);
    try {
      final r = await _b.sent().timeout(const Duration(seconds: 15));
      if (mounted) setState(() => _rows = r);
    } catch (_) {
      if (mounted) setState(() => _offline = true);
    }
  }

  Future<void> _resend(Map<String, dynamic> row) async {
    final t = AppLocalizations.of(context);
    try {
      final r = await _b.resend(row['id'] as int);
      if (!mounted) return;
      if (!inviteOk(r)) {
        ScaffoldMessenger.maybeOf(context)
            ?.showSnackBar(SnackBar(content: Text('${r['detail'] ?? t.ijOffline}')));
        return;
      }
      await Share.share('${r['share_text'] ?? row['share_text'] ?? ''}');
      await _load();
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.maybeOf(context)
            ?.showSnackBar(SnackBar(content: Text(t.ijOffline)));
      }
    }
  }

  Future<void> _revoke(Map<String, dynamic> row) async {
    final t = AppLocalizations.of(context);
    try {
      await _b.revoke(row['id'] as int);
      if (!mounted) return;
      ScaffoldMessenger.maybeOf(context)
          ?.showSnackBar(SnackBar(content: Text(t.ijRevoked)));
      await _load();
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.maybeOf(context)
            ?.showSnackBar(SnackBar(content: Text(t.ijOffline)));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final rows = _rows;
    Widget body;
    if (_offline) {
      body = Center(
        child: Padding(
          padding: const EdgeInsets.all(Gap.lg),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Text(t.ijOffline, textAlign: TextAlign.center),
            const SizedBox(height: Gap.md),
            FilledButton(
                style: FilledButton.styleFrom(minimumSize: const Size(48, 48)),
                onPressed: _load,
                child: Text(t.ijRetry)),
          ]),
        ),
      );
    } else if (rows == null) {
      body = const Center(child: CircularProgressIndicator());
    } else if (rows.isEmpty) {
      body = Center(
          child: Padding(
              padding: const EdgeInsets.all(Gap.lg),
              child: Text(t.ijSentEmpty, textAlign: TextAlign.center)));
    } else {
      body = RefreshIndicator(
        onRefresh: _load,
        child: ListView.separated(
          key: const Key('ij-sent-list'),
          padding: const EdgeInsets.all(Gap.md),
          itemCount: rows.length,
          separatorBuilder: (_, __) => const SizedBox(height: Gap.sm),
          itemBuilder: (_, i) {
            final r = rows[i];
            final status = '${r['status'] ?? ''}';
            final joined = ((r['joined'] as List?) ?? const [])
                .whereType<Map>()
                .map((j) => '${j['name'] ?? ''}'.trim())
                .where((n) => n.isNotEmpty)
                .join(', ');
            final label = '${r['label'] ?? ''}'.trim();
            final (String text, Color color, IconData icon) = switch (status) {
              'joined' => (t.ijStatusJoined(joined.isEmpty ? t.circleSomeone : joined),
                  scheme.primary, Icons.check_circle_rounded),
              'expired' => (t.ijStatusExpired, scheme.error, Icons.timer_off_rounded),
              _ => (joined.isEmpty ? t.ijStatusWaiting : t.ijStatusJoined(joined),
                  scheme.onSurfaceVariant, Icons.hourglass_top_rounded),
            };
            return Card(
              child: Padding(
                padding: const EdgeInsets.all(Gap.md),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Row(children: [
                    Icon(icon, color: color),
                    const SizedBox(width: Gap.sm),
                    Expanded(
                      child: Text(label.isEmpty ? t.ijNoLabel : label,
                          style: const TextStyle(fontWeight: FontWeight.w700)),
                    ),
                  ]),
                  const SizedBox(height: Gap.xs),
                  Text(text, style: TextStyle(color: color)),
                  if (status != 'joined')
                    Wrap(spacing: Gap.sm, children: [
                      TextButton.icon(
                        key: Key('ij-resend-${r['id']}'),
                        style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
                        onPressed: () => _resend(r),
                        icon: const Icon(Icons.send_rounded),
                        label: Text(t.ijResend),
                      ),
                      TextButton.icon(
                        key: Key('ij-revoke-${r['id']}'),
                        style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
                        onPressed: () => _revoke(r),
                        icon: const Icon(Icons.link_off_rounded),
                        label: Text(t.ijRevoke),
                      ),
                    ]),
                ]),
              ),
            );
          },
        ),
      );
    }
    return Scaffold(
      appBar: AppBar(title: Text(t.ijSentTitle)),
      body: body,
      floatingActionButton: FloatingActionButton.extended(
        key: const Key('ij-new-invite'),
        onPressed: () async {
          await showInviteShareSheet(context, backend: widget.backend);
          await _load();
        },
        icon: const Icon(Icons.person_add_alt_1_rounded),
        label: Text(t.ijInviteTile),
      ),
    );
  }
}
