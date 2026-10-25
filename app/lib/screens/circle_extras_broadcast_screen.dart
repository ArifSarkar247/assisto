import 'package:flutter/material.dart';

import '../theme.dart';
import '../l10n/app_localizations.dart';

/// Broadcast list (M2 item 9).
///
/// Compose once, send privately to many CHOSEN circle members. Each recipient
/// gets an INDIVIDUAL message in their own 1:1 chat — recipients NEVER see each
/// other and there is NO shared message id (that would be a group). The client
/// re-ENCRYPTS the body per-recipient (each 1:1 chat has its own key).
///
/// Logic mirrors core/logic/circle_extras.validate_broadcast +
/// broadcast_fanout_plan (self excluded; accepted members only; cap). The chat
/// screen owns the per-recipient encryption; this screen builds the recipient
/// set + the compose, then hands the fan-out plan to the sender.
///
/// Backend seam (integrator wires — see MIGRATION NOTE):
///   POST /circle/broadcast  -> accepts N individual sends (one opaque envelope
///                              each, distinct client_msg_id) — the server fans
///                              them out as normal 1:1 messages; it NEVER links
///                              them. (A BroadcastList model may store the chosen
///                              set client-side for reuse.)
class CircleExtrasBroadcastScreen extends StatefulWidget {
  /// Accepted circle members only (the caller filters to accepted).
  final List<Map<String, dynamic>> members;
  /// Called with the chosen recipient ids + text so the chat layer can encrypt
  /// per-recipient and send (broadcast_fanout_plan). Returns when sent.
  final Future<void> Function(List<int> recipientIds, String text)? onSend;
  const CircleExtrasBroadcastScreen(
      {super.key, required this.members, this.onSend});

  @override
  State<CircleExtrasBroadcastScreen> createState() =>
      _CircleExtrasBroadcastScreenState();
}

class _CircleExtrasBroadcastScreenState
    extends State<CircleExtrasBroadcastScreen> {
  static const _maxRecipients = 256; // mirrors BROADCAST_MAX_RECIPIENTS
  final _chosen = <int>{};
  final _compose = TextEditingController();
  bool _sending = false;

  @override
  void dispose() {
    _compose.dispose();
    super.dispose();
  }

  Future<void> _send(AppLocalizations t) async {
    final text = _compose.text.trim();
    if (_chosen.isEmpty) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(t.circleExtrasBroadcastEmpty)));
      return;
    }
    if (text.isEmpty) return;
    setState(() => _sending = true);
    final ids = _chosen.toList();
    try {
      if (widget.onSend != null) {
        // Primary path: the chat layer encrypts the body ONCE PER RECIPIENT
        // (each 1:1 chat has its own key) and posts the per-recipient fan-out.
        await widget.onSend!(ids, text);
      } else {
        // q1-seams: without the chat layer's per-recipient sealing there is
        // nothing real to send — the old fallback posted EMPTY envelopes via
        // /circle/broadcast and then said "Sent". Refuse honestly instead.
        throw StateError('broadcast needs the chat layer to seal envelopes');
      }
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(
              content: Text(t.circleExtrasBroadcastSent('${ids.length}'))));
      Navigator.of(context).maybePop();
    } catch (_) {
      if (mounted) {
        setState(() => _sending = false);
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(t.grpActionFailed)));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: Text(t.circleExtrasBroadcast)),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(Gap.lg),
            child: Row(
              children: [
                Icon(Icons.campaign_rounded, color: scheme.primary),
                const SizedBox(width: Gap.sm),
                Expanded(
                  child: Text(t.circleExtrasBroadcastHint,
                      style: TextStyle(
                          fontSize: 12, color: scheme.onSurfaceVariant)),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(Gap.lg, 0, Gap.lg, Gap.sm),
            child: Row(
              children: [
                Text(t.circleExtrasChooseRecipients,
                    style: Theme.of(context).textTheme.titleSmall),
                const Spacer(),
                if (_chosen.isNotEmpty)
                  Text('${_chosen.length}',
                      style: TextStyle(color: scheme.primary)),
              ],
            ),
          ),
          Expanded(
            child: ListView.builder(
              itemCount: widget.members.length,
              itemBuilder: (_, i) {
                final m = widget.members[i];
                final id = m['id'] as int;
                final name = '${m['name'] ?? ''}';
                final sel = _chosen.contains(id);
                return CheckboxListTile(
                  value: sel,
                  secondary: CircleAvatar(
                    child: Text(name.isEmpty
                        ? '?'
                        : name.characters.first.toUpperCase()),
                  ),
                  title: Text(name),
                  onChanged: (v) => setState(() {
                    if (v == true && _chosen.length < _maxRecipients) {
                      _chosen.add(id);
                    } else {
                      _chosen.remove(id);
                    }
                  }),
                );
              },
            ),
          ),
          const Divider(height: 1),
          Padding(
            padding: EdgeInsets.only(
              left: Gap.md,
              right: Gap.md,
              top: Gap.sm,
              bottom: MediaQuery.of(context).viewInsets.bottom + Gap.md,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(Icons.lock_outline_rounded,
                        size: 13, color: scheme.onSurfaceVariant),
                    const SizedBox(width: Gap.xs),
                    Expanded(
                      child: Text(t.circleExtrasBroadcastNotGroup,
                          style: TextStyle(
                              fontSize: 11, color: scheme.onSurfaceVariant)),
                    ),
                  ],
                ),
                const SizedBox(height: Gap.xs),
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _compose,
                        minLines: 1,
                        maxLines: 4,
                        decoration: InputDecoration(
                          hintText: t.circleExtrasSend,
                          border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(Radii.md)),
                          isDense: true,
                        ),
                      ),
                    ),
                    const SizedBox(width: Gap.sm),
                    FilledButton(
                      onPressed: _sending ? null : () => _send(t),
                      child: _sending
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(strokeWidth: 2))
                          : Text(t.circleExtrasSend),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
