import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../business_khata_api.dart';
import '../../l10n/app_localizations.dart';
import '../../services/error_kind.dart' show honestFailText;
import '../../services/error_report.dart';
import '../../state.dart';
import '../../theme.dart';

/// tagada2 — "Invite to Assisto" from a khata customer. Reuses the invite-join
/// short codes (server). The message explains that once the customer joins
/// with this number, the shop's reminders reach them in the app for free.
/// Nothing is sent by Assisto: the owner taps WhatsApp / own SMS / Share.
///
/// Returns the final status ('none' | 'invited' | 'joined') or null.
Future<String?> showKhataInviteSheet(BuildContext context,
        {required int businessId,
        required int partyId,
        required String name}) =>
    showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      useSafeArea: true,
      builder: (_) =>
          KhataInviteSheet(businessId: businessId, partyId: partyId, name: name),
    );

class KhataInviteSheet extends StatefulWidget {
  final int businessId;
  final int partyId;
  final String name;
  const KhataInviteSheet(
      {super.key,
      required this.businessId,
      required this.partyId,
      required this.name});

  @override
  State<KhataInviteSheet> createState() => _KhataInviteSheetState();
}

class _KhataInviteSheetState extends State<KhataInviteSheet> {
  bool _busy = false;
  String _status = 'none';
  Map<String, dynamic>? _inv;
  String _error = '';

  @override
  void initState() {
    super.initState();
    _loadStatus();
  }

  Future<void> _loadStatus() async {
    try {
      final r = await context
          .read<AppState>()
          .api
          .khataInviteStatus(widget.businessId, widget.partyId);
      if (mounted) setState(() => _status = '${r['status'] ?? 'none'}');
    } catch (e) {
      reportNonFatal('khata.inviteStatus', e); // best-effort: create still works
    }
  }

  Future<void> _create() async {
    final t = AppLocalizations.of(context);
    setState(() {
      _busy = true;
      _error = '';
    });
    try {
      final r = await context
          .read<AppState>()
          .api
          .khataInvite(widget.businessId, widget.partyId);
      if (!mounted) return;
      final st = (r['_status'] as num?)?.toInt() ?? 200;
      if (st >= 200 && st < 300) {
        setState(() {
          _inv = r;
          _status = '${r['status'] ?? 'invited'}';
        });
      } else {
        setState(() => _error = '${r['detail'] ?? t.tg2InvFailed}');
      }
    } catch (e) {
      reportNonFatal('khata.invite', e);
      if (mounted) setState(() => _error = honestFailText(t, e, otherwise: t.tg2InvFailed));
    }
    if (mounted) setState(() => _busy = false);
  }

  Future<void> _open(String url) async {
    final t = AppLocalizations.of(context);
    var ok = false;
    try {
      ok = await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
    } catch (e) {
      reportNonFatal('khata.inviteOpen', e);
    }
    if (!ok && mounted) {
      ScaffoldMessenger.maybeOf(context)
          ?.showSnackBar(SnackBar(content: Text(t.actionCantOpen)));
    }
  }

  Future<void> _share() async {
    final text = '${_inv?['share_text'] ?? ''}';
    if (text.isEmpty) return;
    try {
      await Share.share(text);
    } catch (e) {
      reportNonFatal('khata.inviteShare', e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final inv = _inv;
    final wa = '${inv?['wa_url'] ?? ''}';
    final sms = '${inv?['sms_uri'] ?? ''}';
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(Gap.lg, 0, Gap.lg, Gap.xl),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Semantics(
            header: true,
            child: Text(t.tg2InvTitle,
                style: Theme.of(context).textTheme.titleLarge),
          ),
          const SizedBox(height: Gap.sm),
          Text(t.tg2InvBody(widget.name), style: AType.bodyMedium),
          const SizedBox(height: Gap.md),
          if (_status == 'joined')
            _note(context, Icons.verified_rounded, t.tg2InvStatusJoined(widget.name),
                AssistoTokens.of(context).success)
          else if (_status == 'invited')
            _note(context, Icons.schedule_send_rounded, t.tg2InvStatusInvited,
                scheme.primary),
          if (_error.isNotEmpty) ...[
            const SizedBox(height: Gap.sm),
            Semantics(
              liveRegion: true,
              child: Text(_error, style: TextStyle(color: scheme.error)),
            ),
          ],
          const SizedBox(height: Gap.md),
          if (_status != 'joined' && inv == null)
            FilledButton.icon(
              key: const ValueKey('tg2-inv-create'),
              style: FilledButton.styleFrom(minimumSize: const Size(48, 48)),
              icon: _busy
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.person_add_alt_1_rounded),
              label: Text(t.tg2InvCreate),
              onPressed: _busy ? null : _create,
            ),
          if (inv != null && _status != 'joined')
            Wrap(spacing: Gap.sm, runSpacing: Gap.sm, children: [
              if (wa.isNotEmpty)
                FilledButton.icon(
                  key: const ValueKey('tg2-inv-wa'),
                  style: FilledButton.styleFrom(minimumSize: const Size(48, 48)),
                  icon: const Icon(Icons.chat_rounded),
                  label: Text(t.tg2InvSendWa),
                  onPressed: () => _open(wa),
                ),
              if (sms.isNotEmpty)
                OutlinedButton.icon(
                  style: OutlinedButton.styleFrom(minimumSize: const Size(48, 48)),
                  icon: const Icon(Icons.sms_rounded),
                  label: Text(t.tg2InvSendSms),
                  onPressed: () => _open(sms),
                ),
              OutlinedButton.icon(
                style: OutlinedButton.styleFrom(minimumSize: const Size(48, 48)),
                icon: const Icon(Icons.ios_share_rounded),
                label: Text(t.tg2InvShare),
                onPressed: _share,
              ),
            ]),
          const SizedBox(height: Gap.sm),
          Align(
            alignment: AlignmentDirectional.centerEnd,
            child: TextButton(
              style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
              onPressed: () => Navigator.pop(context, _status),
              child: Text(t.tg2Done),
            ),
          ),
        ],
      ),
    );
  }

  Widget _note(BuildContext context, IconData icon, String text, Color c) =>
      Semantics(
        liveRegion: true,
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Icon(icon, size: 20, color: c),
          const SizedBox(width: Gap.sm),
          Expanded(child: Text(text, style: AType.bodyMedium)),
        ]),
      );
}
