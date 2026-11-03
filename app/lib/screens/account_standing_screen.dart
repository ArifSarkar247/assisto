// adminsafe (owner 3 Nov): Account status + appeal.
//
// What the user may see about their OWN account after an Owner Admin
// decision: active / suspended (until a date) / banned, active feature limits
// with the reason, the decisions with their reasons, and an Appeal button per
// decision. Backend: core/views_safety.py + core/admin_safety.standing().
//
// Two modes:
//  * signed in      -> GET account/standing, POST account/appeal
//                      (route 'account_standing' from the notification centre)
//  * blocked        -> the sign-in 403 body {reason: account_blocked, detail,
//                      standing, appeal_token}; no session — refresh / appeal
//                      go through account/*/blocked with the token.
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../api.dart';
import '../l10n/app_localizations.dart';
import '../messaging/date_separators.dart' show localDigits;
import '../state.dart';
import '../widgets/app_sheet.dart';
import '../widgets/local_counter.dart';

const int kAppealMin = 10;
const int kAppealMax = 1000;

class AccountStandingScreen extends StatefulWidget {
  /// The 403 sign-in body of a suspended / banned account (blocked mode).
  final Map<String, dynamic>? blockedBody;

  /// Test / injection seam; defaults to the app's [ApiClient].
  final ApiClient? api;

  const AccountStandingScreen({super.key, this.blockedBody, this.api});

  @override
  State<AccountStandingScreen> createState() => _AccountStandingScreenState();
}

class _AccountStandingScreenState extends State<AccountStandingScreen> {
  Map<String, dynamic>? _data;
  bool _loading = false;
  bool _failed = false;

  bool get _blocked => widget.blockedBody != null;
  String get _token => '${widget.blockedBody?['appeal_token'] ?? ''}';

  ApiClient _api(BuildContext context) =>
      widget.api ?? context.read<AppState>().api;

  @override
  void initState() {
    super.initState();
    final st = widget.blockedBody?['standing'];
    if (st is Map) {
      _data = Map<String, dynamic>.from(st);
    } else {
      WidgetsBinding.instance.addPostFrameCallback((_) => _load());
    }
  }

  Future<void> _load() async {
    if (!mounted) return;
    final api = _api(context);
    setState(() {
      _loading = true;
      _failed = false;
    });
    try {
      Map<String, dynamic> d;
      if (_blocked) {
        d = await api.blockedStanding(_token);
        if (d['_status'] != 200) throw Exception('standing ${d['_status']}');
      } else {
        d = await api.accountStanding();
      }
      if (!mounted) return;
      setState(() {
        _data = Map<String, dynamic>.from(d)..remove('_status');
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _failed = _data == null;
      });
    }
  }

  Future<void> _appeal(Map<String, dynamic> notice) async {
    final t = AppLocalizations.of(context);
    final messenger = ScaffoldMessenger.maybeOf(context);
    final api = _api(context);
    final id = notice['id'] is int ? notice['id'] as int : int.tryParse('${notice['id']}') ?? 0;
    final res = await showAppSheet<Map<String, dynamic>>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => AppealSheet(
        onSend: (text) => _blocked
            ? api.sendBlockedAppeal(_token, id, text)
            : api.sendAppeal(id, text),
      ),
    );
    if (res == null || !mounted) return;
    final st = res['standing'];
    if (st is Map) setState(() => _data = Map<String, dynamic>.from(st));
    messenger?.showSnackBar(SnackBar(content: Text(t.astdAppealSent)));
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final body = _data == null
        ? (_failed ? _Failed(onRetry: _load) : const Center(child: CircularProgressIndicator()))
        : RefreshIndicator(
            onRefresh: _load,
            child: _StandingList(
              data: _data!,
              blockedDetail: _blocked ? '${widget.blockedBody?['detail'] ?? ''}' : null,
              onAppeal: _appeal,
            ),
          );
    return Scaffold(
      appBar: AppBar(title: Text(t.astdTitle)),
      body: Stack(children: [
        Positioned.fill(child: body),
        if (_loading && _data != null)
          const Positioned(top: 0, left: 0, right: 0, child: LinearProgressIndicator()),
      ]),
    );
  }
}

class _Failed extends StatelessWidget {
  final VoidCallback onRetry;
  const _Failed({required this.onRetry});

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    return ListView(
      padding: withNavBarInset(context, const EdgeInsets.all(24)),
      children: [
        const Icon(Icons.cloud_off_outlined, size: 48),
        const SizedBox(height: 12),
        Text(t.astdLoadFailed, textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 16),
        Center(
          child: FilledButton.icon(
            style: FilledButton.styleFrom(minimumSize: const Size(48, 48)),
            onPressed: onRetry,
            icon: const Icon(Icons.refresh),
            label: Text(t.astdRetry),
          ),
        ),
      ],
    );
  }
}

String _date(BuildContext context, Object? iso) {
  final d = DateTime.tryParse('${iso ?? ''}');
  if (d == null) return '';
  final l = d.toLocal();
  return localDigits('${l.day}/${l.month}/${l.year}',
      Localizations.localeOf(context).languageCode);
}

String _kindLabel(AppLocalizations t, String kind) {
  switch (kind) {
    case 'stranger_msg':
      return t.astdLimitStrangerMsg;
    case 'channel_post':
      return t.astdLimitChannelPost;
    case 'community_join':
      return t.astdLimitCommunityJoin;
    case 'warn':
      return t.astdActWarn;
    case 'restrict':
      return t.astdActRestrict;
    case 'suspend':
      return t.astdActSuspend;
    case 'ban':
      return t.astdActBan;
    case 'remove_content':
      return t.astdActRemoveContent;
    case 'force_logout':
      return t.astdActForceLogout;
    case 'unblock':
      return t.astdActUnblock;
  }
  return t.astdActOther;
}

class _StandingList extends StatelessWidget {
  final Map<String, dynamic> data;
  final String? blockedDetail;
  final void Function(Map<String, dynamic>) onAppeal;
  const _StandingList({required this.data, required this.blockedDetail, required this.onAppeal});

  List<Map<String, dynamic>> _list(Object? v) => v is List
      ? v.whereType<Map>().map((m) => Map<String, dynamic>.from(m)).toList()
      : const [];

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final tt = Theme.of(context).textTheme;
    final cs = Theme.of(context).colorScheme;
    final status = '${data['status'] ?? 'active'}';
    final limits = _list(data['restrictions']);
    final notices = _list(data['notices']);
    final until = _date(context, data['until']);

    late final IconData icon;
    late final String title;
    late final String sub;
    Color tone = cs.primary;
    if (status == 'banned') {
      icon = Icons.block;
      title = t.astdBannedTitle;
      sub = t.astdBannedBody;
      tone = cs.error;
    } else if (status == 'suspended') {
      icon = Icons.pause_circle_outline;
      title = until.isEmpty ? t.astdSuspendedTitle : t.astdSuspendedUntil(until);
      sub = t.astdSuspendedBody;
      tone = cs.error;
    } else if (limits.isNotEmpty) {
      icon = Icons.do_not_disturb_on_outlined;
      title = t.astdLimitedTitle;
      sub = t.astdLimitedBody;
      tone = cs.tertiary;
    } else {
      icon = Icons.verified_user_outlined;
      title = t.astdGoodTitle;
      sub = t.astdGoodBody;
    }

    final children = <Widget>[
      Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Icon(icon, size: 36, color: tone),
            const SizedBox(width: 12),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Semantics(header: true, child: Text(title, style: tt.titleMedium)),
                const SizedBox(height: 4),
                Text(sub, style: tt.bodyMedium),
                if (blockedDetail != null) ...[
                  const SizedBox(height: 8),
                  Text(t.astdBlockedNote, style: tt.bodySmall),
                ],
              ]),
            ),
          ]),
        ),
      ),
    ];

    if (limits.isNotEmpty) {
      children.add(_Head(t.astdLimitsHead));
      for (final r in limits) {
        final u = _date(context, r['until']);
        children.add(Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(_kindLabel(t, '${r['kind']}'), style: tt.titleSmall),
              const SizedBox(height: 4),
              if ('${r['reason'] ?? ''}'.isNotEmpty) Text(t.astdReason('${r['reason']}')),
              Text(u.isEmpty ? t.astdNoEnd : t.astdUntil(u), style: tt.bodySmall),
            ]),
          ),
        ));
      }
    }

    if (notices.isNotEmpty) {
      children.add(_Head(t.astdHistoryHead));
      for (final n in notices) {
        children.add(_NoticeCard(notice: n, onAppeal: () => onAppeal(n)));
      }
    }

    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: withNavBarInset(context, const EdgeInsets.all(16)),
      children: children,
    );
  }
}

class _Head extends StatelessWidget {
  final String text;
  const _Head(this.text);
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(4, 20, 4, 8),
        child: Semantics(
            header: true, child: Text(text, style: Theme.of(context).textTheme.titleSmall)),
      );
}

class _NoticeCard extends StatelessWidget {
  final Map<String, dynamic> notice;
  final VoidCallback onAppeal;
  const _NoticeCard({required this.notice, required this.onAppeal});

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final tt = Theme.of(context).textTheme;
    final at = _date(context, notice['at']);
    final until = _date(context, notice['until']);
    final ap = notice['appeal'] is Map ? Map<String, dynamic>.from(notice['appeal'] as Map) : null;
    final apState = '${ap?['state'] ?? ''}';
    final apNote = '${ap?['decision_note'] ?? ''}';
    String? apText;
    if (apState == 'open') apText = t.astdAppealOpen;
    if (apState == 'upheld') apText = t.astdAppealUpheld;
    if (apState == 'lifted') apText = t.astdAppealLifted;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(_kindLabel(t, '${notice['kind']}'), style: tt.titleSmall),
          if (at.isNotEmpty) Text(at, style: tt.bodySmall),
          const SizedBox(height: 6),
          Text(t.astdReason('${notice['reason'] ?? ''}')),
          if (until.isNotEmpty) Text(t.astdUntil(until), style: tt.bodySmall),
          if (apText != null) ...[
            const SizedBox(height: 8),
            Text(apText, style: tt.bodyMedium?.copyWith(fontWeight: FontWeight.w600)),
            if (apNote.isNotEmpty) Text(t.astdAppealAnswer(apNote)),
          ],
          if (notice['appealable'] == true) ...[
            const SizedBox(height: 8),
            FilledButton.tonalIcon(
              style: FilledButton.styleFrom(minimumSize: const Size(48, 48)),
              onPressed: onAppeal,
              icon: const Icon(Icons.gavel_outlined),
              label: Text(t.astdAppealBtn),
            ),
          ],
        ]),
      ),
    );
  }
}

/// The appeal form (opened with showAppSheet). Pops with the server answer
/// on success; shows the error in place otherwise.
class AppealSheet extends StatefulWidget {
  final Future<Map<String, dynamic>> Function(String text) onSend;
  const AppealSheet({super.key, required this.onSend});

  @override
  State<AppealSheet> createState() => _AppealSheetState();
}

class _AppealSheetState extends State<AppealSheet> {
  final _c = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    final t = AppLocalizations.of(context);
    final text = _c.text.trim();
    if (text.length < kAppealMin) {
      setState(() => _error = t.astdAppealTooShort);
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final r = await widget.onSend(text);
      if (!mounted) return;
      final code = r['_status'];
      if (code == 201 || code == 200 || r['ok'] == true) {
        Navigator.of(context).pop(r);
        return;
      }
      setState(() {
        _busy = false;
        _error = '${r['detail'] ?? ''}'.isNotEmpty ? '${r['detail']}' : t.astdAppealFailed;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = t.astdAppealFailed;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Semantics(
              header: true,
              child: Text(t.astdAppealTitle, style: Theme.of(context).textTheme.titleMedium)),
          const SizedBox(height: 6),
          Text(t.astdAppealHelp),
          const SizedBox(height: 12),
          TextField(
            controller: _c,
            minLines: 3,
            maxLines: 6,
            maxLength: kAppealMax,
            buildCounter: localCounter,
            enabled: !_busy,
            decoration: InputDecoration(
              labelText: t.astdAppealField,
              border: const OutlineInputBorder(),
              errorText: _error,
              errorMaxLines: 3,
            ),
          ),
          const SizedBox(height: 12),
          FilledButton(
            style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(48)),
            onPressed: _busy ? null : _send,
            child: _busy
                ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                : Text(t.astdAppealSend),
          ),
        ],
      ),
    );
  }
}
