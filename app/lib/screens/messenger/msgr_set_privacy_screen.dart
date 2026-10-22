import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../api.dart';
import '../../l10n/app_localizations.dart';
import '../../messenger_setapi.dart';
import '../../state.dart';
import '../../theme.dart';
import '../../widgets/chat_menu_pickers.dart';
import '../../widgets/msgr_avatar.dart';
import '../../widgets/msgr_set_tiles.dart';
import '../circle_privacy_screen.dart';

/// Privacy hub for the full-spec Settings. The field visibility toggles
/// (last seen / online / profile photo / about / status) plus read receipts and
/// who-can-call ALREADY live in [CirclePrivacyScreen] — this hub links to it
/// for those (no duplication) and EXTENDS it with the MESSAGE-level surfaces it
/// lacks: who-can-message (default = circle only), phone-number-hidden default,
/// the message-requests inbox (accept / decline / block / report), and the
/// BLOCKED list with unblock. Those live in new honest screens backed by
/// [MessengerSettingsApi].
///
/// NO overlap with circle_privacy_screen (which already owns who-can-SEE,
/// read-receipts, typing, who-can-CALL + DND). Everything here is the stranger /
/// message layer those controls don't cover, with conservative defaults enforced
/// server-side (core.logic.msg_contacts).
class MsgrSetPrivacyScreen extends StatelessWidget {
  const MsgrSetPrivacyScreen({super.key});

  void _open(BuildContext context, Widget screen) => Navigator.of(context)
      .push(MaterialPageRoute(builder: (_) => screen));

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(t.msgrSetPrivacy)),
      body: ListView(
        children: [
          MsgrSetSection(t.msgrSetPrivacyVisibilitySection),
          MsgrSetRow(
            icon: Icons.visibility_outlined,
            title: t.msgrSetPrivacyWhoCanSee,
            // last seen / online / profile photo / about / status all live in
            // the existing circle privacy screen — no duplication here.
            subtitle: t.msgrSetPrivacyWhoCanSeeSub,
            onTap: () => _open(context, const CirclePrivacyScreen()),
          ),
          MsgrSetRow(
            icon: Icons.done_all,
            title: t.msgrSetPrivacyReadReceipts,
            subtitle: t.msgrSetPrivacyReadReceiptsSub,
            onTap: () => _open(context, const CirclePrivacyScreen()),
          ),
          MsgrSetRow(
            icon: Icons.call_outlined,
            title: t.msgrSetPrivacyWhoCanCall,
            subtitle: t.msgrSetPrivacyWhoCanCallSub,
            onTap: () => _open(context, const CirclePrivacyScreen()),
          ),
          const Divider(),
          MsgrSetSection(t.msgrSetPrivacyContactsSection),
          // NEW (#96): who-can-message default + phone-number-hidden default.
          MsgrSetRow(
            icon: Icons.forum_outlined,
            title: t.msgrSetPrivacyMessageDefaults,
            subtitle: t.msgrSetPrivacyMessageDefaultsSub,
            onTap: () => _open(context, const MsgrSetMessagePrivacyScreen()),
          ),
          MsgrSetRow(
            icon: Icons.message_outlined,
            title: t.msgrSetPrivacyWhoCanMessage,
            subtitle: t.msgrSetPrivacyWhoCanMessageSub,
            onTap: () => _open(context, const MsgrSetMessageRequestsScreen()),
          ),
          MsgrSetRow(
            icon: Icons.block,
            title: t.msgrSetPrivacyBlocked,
            subtitle: t.msgrSetPrivacyBlockedSub,
            onTap: () => _open(context, const MsgrSetBlockedListScreen()),
          ),
          MsgrSetNote(t.msgrSetPrivacyServerNote,
              icon: Icons.verified_user_outlined),
        ],
      ),
    );
  }
}

// ===========================================================================
// MESSAGE-LEVEL PRIVACY DEFAULTS (#96) — who-can-message + phone hidden.
// Conservative defaults; honest load/error/retry; confirm gate when LOOSENING.
// These are server-enforced (core.logic.msg_contacts): the screen only edits
// the stored policy and POSTs it; the stranger gate runs on every inbound
// message regardless of what the client claims.
// ===========================================================================

/// The three who-can-message policies, mirroring
/// msg_contacts.WHO_MSG_* (server is authoritative, client just labels them).
class _WhoMsg {
  static const circle = 'my_circle';
  static const everyone = 'everyone';
  static const nobody = 'nobody';
  // Two real choices: the server REFUSES strangers under my_circle (and the
  // legacy 'nobody'), and holds one first message in Requests under everyone.
  static const all = [circle, everyone];

  /// Looseness rank — a higher rank is more open (more strangers can reach me).
  static int rank(String v) => switch (v) {
        nobody => 0,
        everyone => 2,
        _ => 1, // circle (the safe default)
      };

  /// True when moving from [from] to [to] OPENS the owner up to more people.
  static bool loosening(String from, String to) => rank(to) > rank(from);
}

class MsgrSetMessagePrivacyScreen extends StatefulWidget {
  const MsgrSetMessagePrivacyScreen({super.key});

  @override
  State<MsgrSetMessagePrivacyScreen> createState() =>
      _MsgrSetMessagePrivacyScreenState();
}

class _MsgrSetMessagePrivacyScreenState
    extends State<MsgrSetMessagePrivacyScreen> {
  bool _loading = true;
  bool _errored = false; // honest: a load failure is NOT shown as saved policy
  bool _dirty = false;

  // Conservative defaults mirror the server (my_circle, phone hidden). These are
  // ONLY shown as live values once a load succeeds; on error we show a retry.
  String _whoCanMessage = _WhoMsg.circle;
  bool _phoneHidden = true;

  ApiClient get _api => context.read<AppState>().api;
  AppLocalizations get _t => AppLocalizations.of(context);

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _errored = false;
    });
    try {
      final r = await _api.messagePrivacy();
      final w = '${r['who_can_message'] ?? _WhoMsg.circle}';
      _whoCanMessage = _WhoMsg.all.contains(w) ? w : _WhoMsg.circle;
      _phoneHidden = r['phone_hidden'] != false; // default hidden (conservative)
    } catch (_) {
      // HONEST state (§21): never present the safe defaults as the owner's real
      // saved choice — that could make them think a stricter policy is active.
      _errored = true;
    }
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _save() async {
    try {
      await _api.setMessagePrivacy({
        'who_can_message': _whoCanMessage,
        'phone_hidden': _phoneHidden,
      });
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(_t.msgrMsgPrivacySaveFailed)));
      }
      return; // keep dirty so the owner can retry
    }
    if (mounted) {
      setState(() => _dirty = false);
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(_t.msgrMsgPrivacySaved)));
    }
  }

  /// Confirm-gate (§21) before LOOSENING who-can-message (opening up to more
  /// strangers). Tightening needs no gate.
  Future<void> _onWhoChanged(String v) async {
    if (v == _whoCanMessage) return;
    if (_WhoMsg.loosening(_whoCanMessage, v)) {
      final body = v == _WhoMsg.everyone
          ? _t.msgrMsgPrivacyLoosenConfirmEveryone
          : _t.msgrMsgPrivacyLoosenConfirmCircle;
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text(_t.msgrMsgPrivacyConfirmTitle),
          content: Text(body),
          actions: [
            TextButton(
                onPressed: () => Navigator.of(ctx).pop(false),
                child: Text(_t.cancel)),
            FilledButton(
                onPressed: () => Navigator.of(ctx).pop(true),
                child: Text(_t.circlePrivacyConfirm)),
          ],
        ),
      );
      if (ok != true) return;
    }
    setState(() {
      _whoCanMessage = v;
      _dirty = true;
    });
  }

  String _whoLabel(String v) => switch (v) {
        _WhoMsg.everyone => _t.msgrMsgWhoEveryone,
        _WhoMsg.nobody => _t.msgrMsgWhoNobody,
        _ => _t.msgrMsgWhoCircle,
      };

  String _whoHint(String v) => switch (v) {
        // mr1: strangers who have my number land in Message requests.
        _WhoMsg.everyone => _t.mr1WhoEveryoneHint,
        _WhoMsg.nobody => _t.msgrMsgWhoNobodyHint,
        _ => _t.mr1WhoCircleHint,
      };

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final t = _t;
    return Scaffold(
      appBar: AppBar(
        title: Text(t.msgrMsgPrivacyTitle),
        actions: [
          if (_dirty && !_errored)
            TextButton(onPressed: _save, child: Text(t.save)),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _errored
              ? _ErrorRetry(message: t.msgrMsgPrivacyLoadFailed, onRetry: _load)
              : ListView(
                  padding: const EdgeInsets.only(bottom: Gap.xxl),
                  children: [
                    MsgrSetSection(t.msgrMsgPrivacyWhoSection),
                    for (final v in _WhoMsg.all)
                      RadioListTile<String>(
                        value: v,
                        groupValue: _whoCanMessage,
                        // No clipping: the policy label + its explanation must
                        // read in full (longest at 360dp wraps to 2 / 4 lines).
                        title: Text(_whoLabel(v), maxLines: 2),
                        subtitle: Text(_whoHint(v), maxLines: 4),
                        isThreeLine: true,
                        onChanged: (nv) {
                          if (nv != null) _onWhoChanged(nv);
                        },
                      ),
                    const Divider(),
                    MsgrSetSection(t.msgrMsgPrivacyPhoneSection),
                    SwitchListTile(
                      secondary: const Icon(Icons.phone_disabled_outlined),
                      title: Text(t.msgrMsgPrivacyPhoneHidden,
                          maxLines: 2, overflow: TextOverflow.ellipsis),
                      subtitle: Text(t.msgrMsgPrivacyPhoneHiddenHint,
                          maxLines: 3, overflow: TextOverflow.ellipsis),
                      value: _phoneHidden,
                      onChanged: (v) => setState(() {
                        _phoneHidden = v;
                        _dirty = true;
                      }),
                    ),
                    const Divider(),
                    MsgrSetNote(t.msgrMsgPrivacyServerNote,
                        icon: Icons.verified_user_outlined),
                  ],
                ),
    );
  }
}

// ===========================================================================
// BLOCKED LIST — people the owner blocked; each can be unblocked (confirm gate).
// Honest loading / error-retry / empty states.
// ===========================================================================

class MsgrSetBlockedListScreen extends StatefulWidget {
  const MsgrSetBlockedListScreen({super.key});

  @override
  State<MsgrSetBlockedListScreen> createState() =>
      _MsgrSetBlockedListScreenState();
}

class _MsgrSetBlockedListScreenState extends State<MsgrSetBlockedListScreen> {
  bool _loading = true;
  bool _failed = false;
  List<Map<String, dynamic>> _items = [];

  ApiClient get _api => context.read<AppState>().api;
  AppLocalizations get _t => AppLocalizations.of(context);

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _failed = false;
    });
    try {
      final r = await _api.blockedList();
      final list = (r['blocked'] as List?) ?? const [];
      _items = list.map((e) => (e as Map).cast<String, dynamic>()).toList();
    } catch (_) {
      _failed = true;
    }
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _unblock(Map<String, dynamic> m) async {
    final id = int.tryParse('${m['id']}');
    if (id == null) return;
    final name = '${m['name'] ?? m['phone'] ?? ''}';
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(_t.msgrSetUnblockConfirmTitle),
        content: Text(_t.msgrSetUnblockConfirm(name)),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: Text(_t.cancel)),
          FilledButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              child: Text(_t.msgrSetUnblock)),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await _api.unblock(id);
      setState(() => _items.remove(m));
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(_t.msgrSetUnblockedToast)));
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(_t.msgrSetUnblockFailed)));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = _t;
    return Scaffold(
      appBar: AppBar(title: Text(t.msgrSetPrivacyBlocked)),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _failed
              ? _ErrorRetry(message: t.msgrSetBlockedLoadFailed, onRetry: _load)
              : (_items.isEmpty
                  ? _EmptyState(
                      icon: Icons.block,
                      text: t.msgrSetBlockedEmpty,
                    )
                  : ListView.separated(
                      itemCount: _items.length,
                      separatorBuilder: (_, __) => const Divider(height: 1),
                      itemBuilder: (_, i) {
                        final m = _items[i];
                        return ListTile(
                          leading: MsgrAvatar(
                              name: '${m['name'] ?? ''}',
                              photoUrl: '${m['photo'] ?? ''}',
                              radius: 20),
                          title: Text('${m['name'] ?? m['phone'] ?? ''}',
                              maxLines: 1, overflow: TextOverflow.ellipsis),
                          subtitle: Text('${m['phone'] ?? ''}',
                              maxLines: 1, overflow: TextOverflow.ellipsis),
                          trailing: TextButton(
                              onPressed: () => _unblock(m),
                              child: Text(t.msgrSetUnblock)),
                        );
                      },
                    )),
    );
  }
}

// ===========================================================================
// MESSAGE REQUESTS (#95) — a stranger's first message lands here, never in the
// normal inbox and never with a notification. Per-request accept / decline /
// block / report (with a reason). Honest loading / error-retry / empty states.
// The server resolves each action (silent decline, harsh-reason auto-block).
// ===========================================================================

class MsgrSetMessageRequestsScreen extends StatefulWidget {
  const MsgrSetMessageRequestsScreen({super.key});

  @override
  State<MsgrSetMessageRequestsScreen> createState() =>
      _MsgrSetMessageRequestsScreenState();
}

class _MsgrSetMessageRequestsScreenState
    extends State<MsgrSetMessageRequestsScreen> {
  bool _loading = true;
  bool _failed = false;
  List<Map<String, dynamic>> _items = [];

  ApiClient get _api => context.read<AppState>().api;
  AppLocalizations get _t => AppLocalizations.of(context);

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _failed = false;
    });
    try {
      final r = await _api.messageRequests();
      final list = (r['requests'] as List?) ?? const [];
      _items = list.map((e) => (e as Map).cast<String, dynamic>()).toList();
    } catch (_) {
      _failed = true;
    }
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _act(Map<String, dynamic> m, String action,
      {String? reason, bool? alsoBlock}) async {
    try {
      await _api.messageRequestAct('${m['id']}', action,
          reason: reason, alsoBlock: alsoBlock);
      if (mounted) setState(() => _items.remove(m));
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(_t.msgrSetRequestActionFailed)));
      }
    }
  }

  /// Block confirm-gate (§21) — a silent, permanent block is destructive.
  Future<void> _block(Map<String, dynamic> m) async {
    final name = '${m['name'] ?? m['phone'] ?? ''}';
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(_t.msgrSetRequestBlockConfirmTitle),
        content: Text(_t.msgrSetRequestBlockConfirm(name)),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: Text(_t.cancel)),
          FilledButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              child: Text(_t.circleBlock)),
        ],
      ),
    );
    if (ok == true) _act(m, 'block');
  }

  /// Report (with a reason) — reuses the existing shared report picker so the
  /// reason taxonomy + copy stay in one place. May also block in the same step.
  Future<void> _report(Map<String, dynamic> m) async {
    final res = await showChatReportPicker(context);
    if (res == null) return;
    await _act(m, 'report', reason: res.reason, alsoBlock: res.alsoBlock);
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(_t.msgrSetRequestReportedToast)));
    }
  }

  Future<void> _more(Map<String, dynamic> m) async {
    final choice = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.block),
              title: Text(_t.msgrSetRequestBlock),
              onTap: () => Navigator.pop(ctx, 'block'),
            ),
            ListTile(
              leading: const Icon(Icons.flag_outlined),
              title: Text(_t.msgrSetRequestReport),
              onTap: () => Navigator.pop(ctx, 'report'),
            ),
          ],
        ),
      ),
    );
    if (choice == 'block') {
      await _block(m);
    } else if (choice == 'report') {
      await _report(m);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = _t;
    return Scaffold(
      appBar: AppBar(title: Text(t.msgrSetPrivacyWhoCanMessage)),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _failed
              ? _ErrorRetry(message: t.msgrSetRequestsLoadFailed, onRetry: _load)
              : (_items.isEmpty
                  ? _EmptyState(
                      icon: Icons.mark_email_read_outlined,
                      text: t.msgrSetRequestsEmpty,
                      hint: t.msgrSetRequestsEmptyHint,
                    )
                  : ListView.separated(
                      itemCount: _items.length,
                      separatorBuilder: (_, __) => const Divider(height: 1),
                      itemBuilder: (_, i) {
                        final m = _items[i];
                        return ListTile(
                          leading: MsgrAvatar(
                              name: '${m['name'] ?? ''}',
                              photoUrl: '${m['photo'] ?? ''}',
                              radius: 20),
                          title: Text('${m['name'] ?? m['phone'] ?? ''}',
                              maxLines: 1, overflow: TextOverflow.ellipsis),
                          subtitle: Text(
                              '${m['preview'] ?? m['phone'] ?? ''}',
                              maxLines: 2, overflow: TextOverflow.ellipsis),
                          trailing: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              IconButton(
                                icon: const Icon(Icons.check),
                                tooltip: t.msgrSetRequestAccept,
                                onPressed: () => _act(m, 'accept'),
                              ),
                              IconButton(
                                icon: const Icon(Icons.close),
                                tooltip: t.msgrSetRequestDecline,
                                onPressed: () => _act(m, 'decline'),
                              ),
                              IconButton(
                                icon: const Icon(Icons.more_vert),
                                tooltip: t.msgrSetRequestMore,
                                onPressed: () => _more(m),
                              ),
                            ],
                          ),
                        );
                      },
                    )),
    );
  }
}

// ===========================================================================
// Shared honest-state widgets (local to this file). No Bangla literals.
// ===========================================================================

/// Honest error state with a Retry — never pretends a load succeeded.
class _ErrorRetry extends StatelessWidget {
  final String message;
  final Future<void> Function() onRetry;
  const _ErrorRetry({required this.message, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final t = AppLocalizations.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(Gap.xxl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.cloud_off_outlined, size: 48, color: scheme.outline),
            const SizedBox(height: Gap.md),
            Text(message,
                textAlign: TextAlign.center,
                style: TextStyle(color: scheme.onSurfaceVariant)),
            const SizedBox(height: Gap.lg),
            FilledButton.tonalIcon(
              onPressed: () => onRetry(),
              icon: const Icon(Icons.refresh),
              label: Text(t.retry),
            ),
          ],
        ),
      ),
    );
  }
}

/// Honest empty state (optionally with a reassuring hint line).
class _EmptyState extends StatelessWidget {
  final IconData icon;
  final String text;
  final String? hint;
  const _EmptyState({required this.icon, required this.text, this.hint});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(Gap.xxl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 48, color: scheme.outline),
            const SizedBox(height: Gap.md),
            Text(text,
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.titleMedium),
            if (hint != null) ...[
              const SizedBox(height: Gap.xs),
              Text(hint!,
                  textAlign: TextAlign.center,
                  style: TextStyle(color: scheme.onSurfaceVariant, height: 1.3)),
            ],
          ],
        ),
      ),
    );
  }
}
