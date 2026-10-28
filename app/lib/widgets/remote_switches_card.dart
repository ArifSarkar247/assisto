import 'dart:async';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../antitheft_api.dart';
import '../l10n/app_localizations.dart';
import '../services/antitheft_logic.dart';
import '../services/error_kind.dart' show honestFailText;
import '../state.dart';
import '../theme.dart';

typedef RemoteLoad = Future<Map<String, dynamic>> Function();
typedef RemoteSend = Future<Map<String, dynamic>> Function(String kind,
    {String? message, String? contact});
typedef RemoteCancel = Future<Map<String, dynamic>> Function(int id);

/// at100 — REMOTE SWITCHES for a protected phone: lost mode, loud alarm,
/// lock, lock-screen message, stop alarm. Used by the owner (from any phone
/// signed in to their account; [phoneId] null = their own protected phone)
/// and by a trusted contact ([phoneId] = the phone they help protect).
///
/// Everything goes through the server (authenticated, rate-limited, audited).
/// The state of each switch is shown HONESTLY: waiting (phone offline or
/// switched off — it runs when the phone is back), sent, reached the phone,
/// done / did not work (+ why), expired, cancelled. The card always says
/// that a switched-off phone cannot receive anything — from any app.
class RemoteSwitchesCard extends StatefulWidget {
  final int? phoneId;
  final RemoteLoad? load;
  final RemoteSend? send;
  final RemoteCancel? cancel;

  /// Poll interval while a switch is on its way (tests pass a short one).
  final Duration poll;

  const RemoteSwitchesCard({
    super.key,
    this.phoneId,
    this.load,
    this.send,
    this.cancel,
    this.poll = const Duration(seconds: 4),
  });

  @override
  State<RemoteSwitchesCard> createState() => _RemoteSwitchesCardState();
}

class _RemoteSwitchesCardState extends State<RemoteSwitchesCard> {
  bool _loading = true;
  bool _busy = false;
  Object? _failCause;
  bool _failed = false;
  Map<String, dynamic> _d = const {};
  Timer? _timer;
  int _polls = 0;
  static const _maxPolls = 45; // ~3 minutes at 4 s

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<Map<String, dynamic>> _doLoad() {
    final f = widget.load;
    if (f != null) return f();
    return context.read<AppState>().api.engineCommands(phoneId: widget.phoneId);
  }

  Future<Map<String, dynamic>> _doSend(String kind,
      {String? message, String? contact}) {
    final f = widget.send;
    if (f != null) return f(kind, message: message, contact: contact);
    return context.read<AppState>().api.engineCommand(kind,
        phoneId: widget.phoneId, message: message, contact: contact);
  }

  Future<Map<String, dynamic>> _doCancel(int id) {
    final f = widget.cancel;
    if (f != null) return f(id);
    return context.read<AppState>().api.engineCommandCancel(id);
  }

  Future<void> _refresh({bool quiet = false}) async {
    if (!quiet && mounted) setState(() => _loading = _d.isEmpty);
    try {
      final d = await _doLoad();
      if (!mounted) return;
      setState(() {
        _d = d;
        _failed = false;
        _loading = false;
      });
      _schedulePoll();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _failed = _d.isEmpty;
        _failCause = e;
        _loading = false;
      });
    }
  }

  void _schedulePoll() {
    _timer?.cancel();
    if (_d['in_flight'] == true && _polls < _maxPolls) {
      _timer = Timer(widget.poll, () {
        _polls++;
        _refresh(quiet: true);
      });
    }
  }

  Map<String, dynamic> get _phone =>
      (_d['phone'] as Map?)?.cast<String, dynamic>() ?? const {};
  bool get _online => _phone['online'] == true;
  bool get _protectionOn => _phone['protection_on'] == true;
  bool get _lostOn => _phone['lost_mode'] == true;
  bool get _isOwner => _d['role'] == 'owner';
  bool _can(String k) => ((_d['can'] as Map?) ?? const {})[k] == true;
  int get _alarmS => (_d['alarm_s'] as num?)?.toInt() ?? 60;

  String _fmt(dynamic iso) {
    final dt = DateTime.tryParse('${iso ?? ''}')?.toLocal();
    if (dt == null) return '';
    final locale = Localizations.localeOf(context).languageCode;
    final now = DateTime.now();
    final sameDay =
        dt.year == now.year && dt.month == now.month && dt.day == now.day;
    return DateFormat(sameDay ? 'h:mm a' : 'd MMM, h:mm a', locale).format(dt);
  }

  // ---- actions -------------------------------------------------------------

  Future<void> _send(String kind) async {
    final tr = AppLocalizations.of(context);
    String? msg;
    String? contact;
    if (kind == 'alarm') {
      final ok = await _confirm(
          tr.at100AlarmConfirmTitle, tr.at100AlarmConfirmBody(_alarmS));
      if (ok != true) return;
    } else if (kind == 'lost_mode' || kind == 'message') {
      final r = await _askMessage(kind);
      if (r == null) return;
      msg = r.$1;
      contact = r.$2;
    } else if (kind == 'lock') {
      final ok = await _confirm(tr.at100LockConfirmTitle, tr.at100LockConfirmBody);
      if (ok != true) return;
    }
    if (!mounted) return;
    setState(() => _busy = true);
    try {
      final r = await _doSend(kind, message: msg, contact: contact);
      if (!mounted) return;
      final st = r['_status'] as int?;
      if (r['ok'] == true) {
        final p = (r['phone'] as Map?) ?? const {};
        _snack(p['online'] == true ? tr.at100SentOnline : tr.at100SentOffline);
        _polls = 0;
      } else if (st == 429 || r['reason'] == 'rate_limited') {
        _snack(tr.at100ErrRate);
      } else if (r['reason'] == 'not_active') {
        _snack(tr.at100NeedActive);
      } else if (r['reason'] == 'protection_off') {
        _snack(tr.at100ProtectionOff);
      } else if (r['reason'] == 'message_required') {
        _snack(tr.at100MsgNeeded);
      } else {
        _snack(honestFailText(tr, null, otherwise: tr.securityActionError));
      }
    } catch (e) {
      if (mounted) _snack(honestFailText(tr, e, otherwise: tr.securityActionError));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
    await _refresh(quiet: true);
  }

  Future<void> _cancelCmd(int id) async {
    final tr = AppLocalizations.of(context);
    try {
      final r = await _doCancel(id);
      if (!mounted) return;
      if (r['ok'] != true) _snack(tr.at100CancelTooLate);
    } catch (e) {
      if (mounted) _snack(honestFailText(tr, e, otherwise: tr.securityActionError));
    }
    await _refresh(quiet: true);
  }

  Future<bool?> _confirm(String title, String body) {
    final tr = AppLocalizations.of(context);
    return showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: SingleChildScrollView(child: Text(body)),
        actions: [
          TextButton(
              style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(tr.cancel)),
          FilledButton(
              key: const Key('at100-confirm'),
              style: FilledButton.styleFrom(minimumSize: const Size(48, 48)),
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(tr.at100Send)),
        ],
      ),
    );
  }

  Future<(String, String)?> _askMessage(String kind) async {
    final tr = AppLocalizations.of(context);
    final msgC = TextEditingController();
    final telC = TextEditingController();
    String? err;
    return showDialog<(String, String)>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setD) => AlertDialog(
          title: Text(kind == 'lost_mode' ? tr.at100LostMode : tr.at100Message),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(kind == 'lost_mode'
                    ? tr.at100LostConfirmBody
                    : tr.at100MsgConfirmBody),
                const SizedBox(height: Gap.sm),
                TextField(
                  key: const Key('at100-msg'),
                  controller: msgC,
                  maxLines: 3,
                  maxLength: 300,
                  decoration: InputDecoration(
                      labelText: tr.at100MsgLabel, hintText: tr.at100MsgHint),
                ),
                TextField(
                  key: const Key('at100-contact'),
                  controller: telC,
                  keyboardType: TextInputType.phone,
                  maxLength: 40,
                  decoration: InputDecoration(labelText: tr.at100ContactLabel),
                ),
                if (err != null)
                  Text(err!,
                      style: TextStyle(color: Theme.of(ctx).colorScheme.error)),
              ],
            ),
          ),
          actions: [
            TextButton(
                style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
                onPressed: () => Navigator.pop(ctx),
                child: Text(tr.cancel)),
            FilledButton(
              key: const Key('at100-msg-send'),
              style: FilledButton.styleFrom(minimumSize: const Size(48, 48)),
              onPressed: () {
                final m = msgC.text.trim();
                if (kind == 'message' && m.isEmpty) {
                  setD(() => err = tr.at100MsgNeeded);
                  return;
                }
                Navigator.pop(ctx, (m, telC.text.trim()));
              },
              child: Text(tr.at100Send),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _openFindHub() async {
    final url = '${((_d['wipe'] as Map?) ?? const {})['use'] ?? ''}';
    final u = Uri.tryParse(url.isEmpty ? 'https://www.google.com/android/find' : url);
    if (u == null) return;
    try {
      await launchUrl(u, mode: LaunchMode.externalApplication);
    } catch (_) {}
  }

  void _snack(String m) {
    if (!mounted) return;
    ScaffoldMessenger.maybeOf(context)
      ?..clearSnackBars()
      ..showSnackBar(SnackBar(content: Text(m)));
  }

  // ---- build ---------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final tr = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    Widget body;
    if (_loading) {
      body = const Padding(
        padding: EdgeInsets.all(Gap.lg),
        child: Center(child: CircularProgressIndicator()),
      );
    } else if (_failed) {
      body = Padding(
        padding: const EdgeInsets.all(Gap.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(honestFailText(tr, _failCause, otherwise: tr.at100LoadFailed)),
            const SizedBox(height: Gap.sm),
            FilledButton(
                key: const Key('at100-retry'),
                style: FilledButton.styleFrom(minimumSize: const Size(48, 48)),
                onPressed: _refresh,
                child: Text(tr.retry)),
          ],
        ),
      );
    } else {
      body = _content(tr, scheme, text);
    }
    return Card(
      key: const Key('at100-card'),
      child: Padding(
        padding: const EdgeInsets.all(Gap.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              const Icon(Icons.settings_remote_rounded),
              const SizedBox(width: Gap.sm),
              Expanded(
                  child: Semantics(
                      header: true,
                      child: Text(tr.at100Title, style: text.titleMedium))),
              IconButton(
                key: const Key('at100-refresh'),
                tooltip: tr.at100Refresh,
                onPressed: _busy ? null : () => _refresh(quiet: true),
                icon: const Icon(Icons.refresh_rounded),
              ),
            ]),
            body,
          ],
        ),
      ),
    );
  }

  Widget _content(AppLocalizations tr, ColorScheme scheme, TextTheme text) {
    final cmds = ((_d['commands'] as List?) ?? const []).whereType<Map>().toList();
    final owner = '${_d['owner'] ?? ''}';
    final lastSeen = _phone['last_seen'];
    final tokens = AssistoTokens.of(context);
    String presence;
    Color pColor;
    IconData pIcon;
    if (!_protectionOn) {
      presence = tr.at100ProtectionOff;
      pColor = Brand.warnInk(context);
      pIcon = Icons.shield_outlined;
    } else if (_online) {
      presence = tr.at100Online(_fmt(lastSeen));
      pColor = tokens.success;
      pIcon = Icons.wifi_tethering_rounded;
    } else if (lastSeen == null) {
      presence = tr.at100NeverSeen;
      pColor = Brand.warnInk(context);
      pIcon = Icons.portable_wifi_off_rounded;
    } else {
      presence = tr.at100Offline(_fmt(lastSeen));
      pColor = Brand.warnInk(context);
      pIcon = Icons.portable_wifi_off_rounded;
    }
    final needActive = !_isOwner && _protectionOn && !_can('alarm');
    Widget btn(String kind, IconData icon, String label, {bool tonal = true}) {
      final enabled = !_busy && _can(kind) && !(kind == 'lost_mode' && _lostOn);
      final child = Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(icon, size: 20),
        const SizedBox(width: Gap.xs),
        Flexible(child: Text(label, softWrap: true)),
      ]);
      final style = FilledButton.styleFrom(minimumSize: const Size(48, 48));
      return tonal
          ? FilledButton.tonal(
              key: Key('at100-$kind'),
              style: style,
              onPressed: enabled ? () => _send(kind) : null,
              child: child)
          : FilledButton(
              key: Key('at100-$kind'),
              style: style,
              onPressed: enabled ? () => _send(kind) : null,
              child: child);
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (owner.isNotEmpty && !_isOwner)
          Text(tr.at100Subtitle(owner), style: text.bodyMedium),
        if (_isOwner) Text(tr.at100OwnerHint, style: text.bodySmall),
        const SizedBox(height: Gap.sm),
        Semantics(
          liveRegion: true,
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Icon(pIcon, color: pColor, size: 20),
            const SizedBox(width: Gap.xs),
            Expanded(
                child: Text(presence,
                    key: const Key('at100-presence'),
                    style: text.bodyMedium?.copyWith(color: pColor))),
          ]),
        ),
        const SizedBox(height: Gap.xs),
        Text(tr.at100OfflineTruth,
            key: const Key('at100-truth'), style: text.bodySmall),
        const SizedBox(height: Gap.md),
        Wrap(spacing: Gap.sm, runSpacing: Gap.sm, children: [
          btn('lost_mode', Icons.travel_explore_rounded,
              _lostOn ? tr.at100LostModeOn : tr.at100LostMode,
              tonal: false),
          btn('alarm', Icons.volume_up_rounded, tr.at100Alarm(_alarmS)),
          btn('lock', Icons.lock_outline_rounded, tr.at100Lock),
          btn('message', Icons.message_rounded, tr.at100Message),
          btn('alarm_stop', Icons.volume_off_rounded, tr.at100AlarmStop),
        ]),
        if (needActive) ...[
          const SizedBox(height: Gap.xs),
          Text(tr.at100NeedActive,
              key: const Key('at100-need-active'), style: text.bodySmall),
        ],
        if (_isOwner && _lostOn) ...[
          const SizedBox(height: Gap.xs),
          Text(tr.at100LostOffHint, style: text.bodySmall),
        ],
        const SizedBox(height: Gap.md),
        Text(tr.at100History, style: text.titleSmall),
        if (cmds.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: Gap.sm),
            child: Text(tr.at100HistoryEmpty,
                key: const Key('at100-empty'), style: text.bodySmall),
          )
        else
          ...cmds.take(8).map((c) => _cmdTile(tr, text, c)),
        const Divider(height: Gap.xl),
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: const Icon(Icons.delete_forever_outlined),
          title: Text(tr.at100WipeTitle),
          subtitle: Text(tr.at100WipeBody),
        ),
        Align(
          alignment: AlignmentDirectional.centerStart,
          child: OutlinedButton.icon(
            key: const Key('at100-findhub'),
            style: OutlinedButton.styleFrom(minimumSize: const Size(48, 48)),
            onPressed: _openFindHub,
            icon: const Icon(Icons.open_in_new_rounded),
            label: Text(tr.at100WipeOpen),
          ),
        ),
      ],
    );
  }

  String _kindLabel(AppLocalizations tr, String k) {
    switch (k) {
      case 'lost_mode':
        return tr.at100LostMode;
      case 'alarm':
        return tr.at100Alarm(_alarmS);
      case 'alarm_stop':
        return tr.at100AlarmStop;
      case 'lock':
        return tr.at100Lock;
      case 'message':
        return tr.at100Message;
      default:
        return k;
    }
  }

  String _failReason(AppLocalizations tr, String d) {
    switch (d) {
      case 'no_admin':
        return tr.at100FailNoAdmin;
      case 'notif_blocked':
        return tr.at100FailNotif;
      case 'no_sound':
        return tr.at100FailSound;
      default:
        return tr.at100FailOther;
    }
  }

  Widget _cmdTile(AppLocalizations tr, TextTheme text, Map c) {
    final state = '${c['state'] ?? ''}';
    final ph = RemoteCommandRules.phase(state, phoneOnline: _online);
    String line;
    IconData icon;
    Color? color;
    final tokens = AssistoTokens.of(context);
    switch (ph) {
      case CmdPhase.waitingOffline:
        line = tr.at100PhWaitingOffline;
        icon = Icons.schedule_rounded;
        color = Brand.warnInk(context);
        break;
      case CmdPhase.waiting:
        line = tr.at100PhWaiting;
        icon = Icons.schedule_rounded;
        break;
      case CmdPhase.sent:
        line = tr.at100PhSent;
        icon = Icons.send_rounded;
        break;
      case CmdPhase.reached:
        line = tr.at100PhReached(_fmt(c['delivered_at']));
        icon = Icons.phone_android_rounded;
        break;
      case CmdPhase.done:
        line = tr.at100PhDone(_fmt(c['done_at']));
        icon = Icons.check_circle_rounded;
        color = tokens.success;
        break;
      case CmdPhase.failed:
        line = tr.at100PhFailed(_failReason(tr, '${c['detail'] ?? ''}'));
        icon = Icons.error_outline_rounded;
        color = Theme.of(context).colorScheme.error;
        break;
      case CmdPhase.expired:
        line = tr.at100PhExpired;
        icon = Icons.timer_off_outlined;
        color = Brand.warnInk(context);
        break;
      case CmdPhase.cancelled:
        line = tr.at100PhCancelled;
        icon = Icons.block_rounded;
        break;
    }
    final who = c['mine'] == true
        ? tr.at100ByYou
        : (c['by_owner'] == true
            ? tr.at100ByOwner
            : tr.at100By('${c['by'] ?? ''}'));
    final id = (c['id'] as num?)?.toInt();
    final canCancel = id != null &&
        (state == 'queued' || state == 'sent') &&
        (c['mine'] == true || _isOwner);
    return Semantics(
      container: true,
      child: ListTile(
        key: id == null ? null : Key('at100-cmd-$id'),
        contentPadding: EdgeInsets.zero,
        leading: Icon(icon, color: color),
        title: Text(_kindLabel(tr, '${c['kind'] ?? ''}')),
        subtitle: Text('$line\n$who · ${_fmt(c['created_at'])}',
            style: text.bodySmall?.copyWith(color: color)),
        isThreeLine: true,
        trailing: canCancel
            ? TextButton(
                key: Key('at100-cancel-$id'),
                style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
                onPressed: () => _cancelCmd(id),
                child: Text(tr.cancel))
            : null,
      ),
    );
  }
}
