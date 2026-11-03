import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../api.dart';
import '../calls/fullscreen_call_prompt.dart';
import '../l10n/app_localizations.dart';
import '../screens/circle_call_screen.dart';
import '../screens/journey_watch_screen.dart';
import '../state.dart';
import '../theme.dart';
import '../widgets/app_sheet.dart';
import 'carecall_alarms.dart';
import 'carecall_api.dart';
import 'carecall_new_screen.dart';
import 'carecall_plan.dart';
import 'carecall_ui.dart';

/// carecall — the Care Call home (route `carecall`, flag `care_call`).
/// SCREEN 3 lives at the top: the setter's updates — a normal card "Care
/// Call 9:02 · Ammu confirmed ✓" and an amber-bordered card "Care Call 9:20 ·
/// Ammu did not answer twice" with Call now (our own call) and See location
/// (only when location sharing already exists for that pair). Below: consent
/// requests (accept once / not now), the Care Calls I set (on/off, edit,
/// delete), the Care Calls for me (stop any time), my quiet hours. Empty =
/// benefit line + big button + how-to. Never shows ads.
class CareCallScreen extends StatefulWidget {
  const CareCallScreen({super.key, this.api, this.debugMine});
  final CareCallApi? api;

  /// Gallery / tests: a fixed server answer (no network).
  final Map<String, dynamic>? debugMine;

  @override
  State<CareCallScreen> createState() => _CareCallScreenState();
}

class _CareCallScreenState extends State<CareCallScreen> {
  Map<String, dynamic>? _m;
  bool _failed = false;
  bool _offline = false;
  final Set<String> _busy = {};

  CareCallApi? get _api {
    if (widget.api != null) return widget.api;
    try {
      return HttpCareCallApi(context.read<AppState>().api);
    } catch (_) {
      return null;
    }
  }

  @override
  void initState() {
    super.initState();
    _m = widget.debugMine ?? CareCallSync.lastMine;
    if (widget.debugMine == null) WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  Future<void> _load() async {
    final api = _api;
    if (api == null) return;
    setState(() => _failed = false);
    try {
      await CareCallDrafts.flush(api);
      await CareCallActions.flush(api: api);
      final m = await api.mine();
      CareCallSync.lastMine = m;
      if (!mounted) return;
      setState(() {
        _m = m;
        _offline = false;
      });
      unawaited(CareCallSync.apply(api, m, lang: ccLang(context)));
    } on ApiException {
      if (mounted) setState(() => _failed = _m == null);
    } catch (_) {
      if (mounted) setState(() {
        _offline = _m != null;
        _failed = _m == null;
      });
    }
  }

  List<Map<String, dynamic>> _list(String k) =>
      [for (final x in (_m?[k] as List? ?? const [])) Map<String, dynamic>.from(x as Map)];

  Future<void> _openNew({Map<String, dynamic>? edit}) async {
    final ok = await Navigator.of(context).push<bool>(MaterialPageRoute(
        builder: (_) => CareCallNewScreen(api: widget.api, edit: edit,
            limits: (_m?['limits'] as Map?)?.cast<String, dynamic>())));
    if (ok == true && mounted) await _load();
  }

  Future<void> _run(String key, Future<void> Function() f) async {
    final t = AppLocalizations.of(context);
    setState(() => _busy.add(key));
    try {
      await f();
      await _load();
    } on ApiException catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(e.message.isNotEmpty ? e.message : t.ccFailed)));
      }
    } catch (_) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(t.ccFailed)));
    } finally {
      if (mounted) setState(() => _busy.remove(key));
    }
  }

  Future<void> _consent(Map<String, dynamic> inv, bool accept) => _run('inv${inv['setter_id']}', () async {
        await _api!.consent((inv['setter_id'] as num).toInt(), accept);
        if (accept && mounted) unawaited(FullScreenCallPrompt.maybeShow(context));
      });

  Future<bool> _confirm(String title, String body, String yes) async {
    final t = AppLocalizations.of(context);
    final r = await showAppSheet<bool>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => Padding(
        padding: withNavBarInset(ctx, const EdgeInsets.fromLTRB(Gap.lg, 0, Gap.lg, Gap.lg)),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text(title, style: Theme.of(ctx).textTheme.titleLarge),
          const SizedBox(height: Gap.sm),
          Text(body),
          const SizedBox(height: Gap.lg),
          FilledButton(style: Brand.dangerButton(), onPressed: () => Navigator.pop(ctx, true), child: Text(yes)),
          const SizedBox(height: Gap.sm),
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(t.ccNotNow)),
        ]),
      ),
    );
    return r == true;
  }

  Future<void> _editQuiet() async {
    final t = AppLocalizations.of(context);
    String qs = '${_m?['quiet_start'] ?? ''}', qe = '${_m?['quiet_end'] ?? ''}';
    var on = qs.isNotEmpty && qe.isNotEmpty;
    if (!on) {
      qs = '22:00';
      qe = '07:00';
    }
    final saved = await showAppSheet<bool>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => StatefulBuilder(builder: (ctx, set) {
        Future<void> pick(bool start) async {
          final m = ccMinutes(start ? qs : qe) ?? 0;
          final v = await showTimePicker(context: ctx, initialTime: TimeOfDay(hour: m ~/ 60, minute: m % 60));
          if (v != null) set(() => start ? qs = ccHhmm(v.hour, v.minute) : qe = ccHhmm(v.hour, v.minute));
        }
        return Padding(
          padding: withNavBarInset(ctx, const EdgeInsets.fromLTRB(Gap.lg, 0, Gap.lg, Gap.lg)),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Text(t.ccQuietTitle, style: Theme.of(ctx).textTheme.titleLarge),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(t.ccQuietUse),
              value: on,
              onChanged: (v) => set(() => on = v),
            ),
            if (on)
              Row(children: [
                Expanded(child: CcField(label: t.ccQuietFrom, onTap: () => pick(true),
                    semantics: ccTimeText(ctx, qs), child: Text(ccTimeText(ctx, qs)))),
                const SizedBox(width: Gap.md),
                Expanded(child: CcField(label: t.ccQuietTo, onTap: () => pick(false),
                    semantics: ccTimeText(ctx, qe), child: Text(ccTimeText(ctx, qe)))),
              ]),
            const SizedBox(height: Gap.lg),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(t.ccSaveBtn)),
          ]),
        );
      }),
    );
    if (saved == true) {
      await _run('quiet', () => _api!.quiet(on ? qs : '', on ? qe : ''));
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final m = _m;
    Widget body;
    if (m == null && _failed) {
      body = Center(
        child: Padding(
          padding: const EdgeInsets.all(Gap.xl),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Text(t.loadFailed, textAlign: TextAlign.center),
            const SizedBox(height: Gap.md),
            FilledButton.icon(onPressed: _load, icon: const Icon(Icons.refresh_rounded), label: Text(t.retry)),
          ]),
        ),
      );
    } else if (m == null) {
      body = const Center(child: CircularProgressIndicator());
    } else {
      body = RefreshIndicator(onRefresh: _load, child: _content(t));
    }
    final empty = m != null && _isEmpty;
    return Scaffold(
      appBar: AppBar(title: Text(t.ccTitle)),
      body: body,
      bottomNavigationBar: m == null || empty
          ? null
          : SafeArea(
              child: Padding(
                padding: withNavBarInset(context, const EdgeInsets.fromLTRB(Gap.lg, Gap.sm, Gap.lg, Gap.md)),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(minHeight: 56),
                  child: FilledButton.icon(
                    onPressed: () => _openNew(),
                    icon: const Icon(Icons.add_call),
                    label: Text(t.ccNew, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
                  ),
                ),
              ),
            ),
    );
  }

  bool get _isEmpty =>
      _list('sent').isEmpty && _list('received').isEmpty && _list('links').isEmpty && _list('feed').isEmpty;

  Widget _content(AppLocalizations t) {
    final s = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    final invites = _list('invites');
    final feed = _list('feed');
    final sent = _list('sent');
    final received = _list('received');
    final links = _list('links').where((l) => l['status'] != 'pending').toList();
    final lim = (_m?['limits'] as Map?) ?? const {};
    final children = <Widget>[
      if (_offline)
        Padding(
          padding: const EdgeInsets.only(bottom: Gap.md),
          child: Text(t.ccOfflineBanner, style: tt.bodySmall?.copyWith(color: Brand.warnInk(context))),
        ),
      for (final inv in invites) _inviteCard(t, inv),
      if (_isEmpty && invites.isEmpty) _empty(t),
      if (feed.isNotEmpty) ...[
        _header(t.ccUpdates),
        for (final f in feed) _feedCard(t, f),
      ],
      if (sent.isNotEmpty) ...[
        _header(t.ccSetByYou),
        if (lim['active_per_setter'] != null)
          Padding(
            padding: const EdgeInsets.only(bottom: Gap.sm),
            child: Text(
                t.ccLimitLine(ccNum(context, lim['active_used'] ?? 0), ccNum(context, lim['active_per_setter'])),
                style: tt.bodySmall?.copyWith(color: s.onSurfaceVariant)),
          ),
        for (final c in sent) _sentTile(t, c),
      ],
      if (received.isNotEmpty || links.isNotEmpty) ...[
        _header(t.ccForYou),
        for (final c in received) _receivedTile(t, c),
        for (final l in links) _linkTile(t, l),
        _quietTile(t),
      ],
    ];
    return ListView(
      padding: const EdgeInsets.fromLTRB(Gap.lg, Gap.md, Gap.lg, Gap.xl),
      children: children,
    );
  }

  Widget _header(String text) => Padding(
        padding: const EdgeInsets.only(top: Gap.md, bottom: Gap.sm),
        child: Semantics(
          header: true,
          child: Text(text, style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
        ),
      );

  Widget _empty(AppLocalizations t) {
    final s = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.only(top: Gap.xl),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Icon(Icons.phone_callback_rounded, size: 64, color: s.primary),
        const SizedBox(height: Gap.md),
        Text(t.ccEmptyBenefit, textAlign: TextAlign.center, style: tt.titleMedium),
        const SizedBox(height: Gap.lg),
        ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 56),
          child: FilledButton.icon(
            onPressed: () => _openNew(),
            icon: const Icon(Icons.add_call),
            label: Text(t.ccNew, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
          ),
        ),
        const SizedBox(height: Gap.md),
        Text(t.ccEmptyHow, textAlign: TextAlign.center, style: tt.bodyMedium?.copyWith(color: s.onSurfaceVariant)),
      ]),
    );
  }

  Widget _inviteCard(AppLocalizations t, Map<String, dynamic> inv) {
    final tt = Theme.of(context).textTheme;
    final busy = _busy.contains('inv${inv['setter_id']}');
    return Card(
      margin: const EdgeInsets.only(bottom: Gap.md),
      child: Padding(
        padding: const EdgeInsets.all(Gap.lg),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(children: [
            CcAvatar(initial: '${inv['initial'] ?? ''}', size: 48),
            const SizedBox(width: Gap.md),
            Expanded(child: Text(t.ccInviteTitle('${inv['name'] ?? ''}'), style: tt.titleMedium?.copyWith(fontWeight: FontWeight.w700))),
          ]),
          const SizedBox(height: Gap.sm),
          Text(t.ccInviteBody, style: tt.bodyMedium),
          const SizedBox(height: Gap.md),
          Row(children: [
            Expanded(
              child: ConstrainedBox(
                constraints: const BoxConstraints(minHeight: 52),
                child: FilledButton.icon(
                  onPressed: busy ? null : () => _consent(inv, true),
                  icon: const Icon(Icons.check_rounded),
                  label: Text(t.ccAccept),
                ),
              ),
            ),
            const SizedBox(width: Gap.md),
            Expanded(
              child: ConstrainedBox(
                constraints: const BoxConstraints(minHeight: 52),
                child: OutlinedButton(onPressed: busy ? null : () => _consent(inv, false), child: Text(t.ccNotNow)),
              ),
            ),
          ]),
        ]),
      ),
    );
  }

  /// SCREEN 3 cards.
  Widget _feedCard(AppLocalizations t, Map<String, dynamic> f) {
    final s = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    final missed = f['kind'] == 'missed';
    final name = '${f['receiver_name'] ?? ''}';
    final time = ccIsoTimeText(context, '${f['at'] ?? f['scheduled_at']}');
    final amber = Brand.warning;
    final good = Brand.onTint(context, Brand.success);
    final text = '${f['text'] ?? ''}';
    return Card(
      margin: const EdgeInsets.only(bottom: Gap.md),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: missed ? BorderSide(color: amber, width: 2) : BorderSide(color: s.outlineVariant),
      ),
      color: missed ? Color.alphaBlend(amber.withValues(alpha: 0.08), s.surface) : null,
      child: Padding(
        padding: const EdgeInsets.all(Gap.lg),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            CcAvatar(initial: '${f['receiver_initial'] ?? ''}'),
            const SizedBox(width: Gap.md),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(t.ccCardTitle(time), style: tt.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
                const SizedBox(height: Gap.xs),
                Row(children: [
                  Icon(missed ? Icons.warning_amber_rounded : Icons.check_circle_rounded,
                      size: 22, color: missed ? Brand.warnInk(context) : good),
                  const SizedBox(width: Gap.xs),
                  Flexible(
                    child: Text(
                        missed
                            ? t.ccMissedTwice(name)
                            : (f['kind'] == 'late' ? t.ccConfirmedLate(name) : t.ccConfirmed(name)),
                        style: tt.bodyLarge?.copyWith(
                            color: missed ? Brand.warnInk(context) : good, fontWeight: FontWeight.w600)),
                  ),
                ]),
                if (text.isNotEmpty) ...[
                  const SizedBox(height: Gap.xs),
                  Text('“$text”', style: tt.bodyMedium?.copyWith(color: s.onSurfaceVariant)),
                ],
              ]),
            ),
          ]),
          if (missed) ...[
            const SizedBox(height: Gap.md),
            Wrap(spacing: Gap.sm, runSpacing: Gap.sm, children: [
              if (f['edge_id'] != null)
                ConstrainedBox(
                  constraints: const BoxConstraints(minHeight: 48),
                  child: FilledButton.icon(
                    onPressed: () => Navigator.of(context).push(MaterialPageRoute(
                        builder: (_) => CircleCallScreen(
                            member: {'id': f['edge_id'], 'name': name}, kind: 'voice', outgoing: true))),
                    icon: const Icon(Icons.call_rounded),
                    label: Text(t.ccCallNow),
                  ),
                ),
              if (f['can_see_location'] == true)
                ConstrainedBox(
                  constraints: const BoxConstraints(minHeight: 48),
                  child: OutlinedButton.icon(
                    onPressed: () => Navigator.of(context)
                        .push(MaterialPageRoute(builder: (_) => const JourneyWatchScreen())),
                    icon: const Icon(Icons.location_on_outlined),
                    label: Text(t.ccSeeLocation),
                  ),
                ),
            ]),
          ],
        ]),
      ),
    );
  }

  String _when(Map<String, dynamic> c) =>
      '${ccTimeText(context, '${c['time']}')} · ${ccRepeatText(context, '${c['repeat']}', [for (final d in (c['days'] as List? ?? const [])) (d as num).toInt()], '${c['date'] ?? ''}')}';

  Widget _sentTile(AppLocalizations t, Map<String, dynamic> c) {
    final s = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    final id = (c['id'] as num).toInt();
    final link = '${c['link']}';
    final active = c['active'] == true;
    final status = link == 'pending'
        ? t.ccLinkPending
        : (link == 'stopped' || link == 'declined')
            ? t.ccLinkStopped
            : (active ? t.ccStatusOn : t.ccStatusOff);
    return Card(
      margin: const EdgeInsets.only(bottom: Gap.sm),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(Gap.md, Gap.sm, Gap.xs, Gap.sm),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Padding(
            padding: const EdgeInsets.only(top: Gap.xs),
            child: CcAvatar(initial: '${c['other_initial'] ?? ''}'),
          ),
          const SizedBox(width: Gap.md),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('${c['other_name'] ?? ''}', style: tt.titleMedium?.copyWith(fontWeight: FontWeight.w600)),
              Text(_when(c), style: tt.bodyMedium),
              if ('${c['text'] ?? ''}'.isNotEmpty)
                Text('“${c['text']}”', style: tt.bodySmall?.copyWith(color: s.onSurfaceVariant)),
              const SizedBox(height: Gap.xs),
              Row(children: [
                if (c['has_voice'] == true) ...[
                  Icon(Icons.mic_rounded, size: 16, color: s.primary),
                  const SizedBox(width: Gap.xxs),
                ],
                Flexible(child: Text(status, style: tt.labelMedium?.copyWith(color: s.primary))),
              ]),
            ]),
          ),
          Switch(
            value: active,
            onChanged: _busy.contains('cc$id') || link == 'stopped' || link == 'declined'
                ? null
                : (v) => _run('cc$id', () async {
                      await _api!.update(id, {
                        'text': c['text'], 'time': c['time'], 'repeat': c['repeat'],
                        'days': c['days'], 'date': c['date'], 'active': v,
                      });
                    }),
          ),
          PopupMenuButton<String>(
            tooltip: t.ccEdit,
            onSelected: (v) async {
              if (v == 'edit') {
                await _openNew(edit: c);
              } else if (await _confirm(t.ccDeleteConfirm, _when(c), t.ccDelete)) {
                await _run('cc$id', () => _api!.delete(id));
              }
            },
            itemBuilder: (_) => [
              PopupMenuItem(value: 'edit', child: Text(t.ccEdit)),
              PopupMenuItem(value: 'delete', child: Text(t.ccDelete)),
            ],
          ),
        ]),
      ),
    );
  }

  Widget _receivedTile(AppLocalizations t, Map<String, dynamic> c) {
    final s = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    return Card(
      margin: const EdgeInsets.only(bottom: Gap.sm),
      child: ListTile(
        minTileHeight: 64,
        leading: CcAvatar(initial: '${c['other_initial'] ?? ''}'),
        title: Text(t.ccFrom('${c['other_name'] ?? ''}'), style: tt.titleMedium),
        subtitle: Text(
            '${_when(c)}${'${c['text'] ?? ''}'.isNotEmpty ? '\n“${c['text']}”' : ''}',
            style: tt.bodyMedium?.copyWith(color: s.onSurfaceVariant)),
        isThreeLine: '${c['text'] ?? ''}'.isNotEmpty,
        trailing: c['has_voice'] == true ? Icon(Icons.mic_rounded, color: s.primary) : null,
      ),
    );
  }

  Widget _linkTile(AppLocalizations t, Map<String, dynamic> l) {
    final sid = (l['setter_id'] as num).toInt();
    final name = '${l['name'] ?? ''}';
    final on = l['status'] == 'accepted';
    final busy = _busy.contains('inv$sid');
    return Padding(
      padding: const EdgeInsets.only(bottom: Gap.sm),
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 48),
        child: on
            ? OutlinedButton.icon(
                onPressed: busy
                    ? null
                    : () async {
                        if (await _confirm(t.ccStopFrom(name), t.ccStopConfirm(name), t.ccStopYes)) {
                          await _consent(l, false);
                        }
                      },
                icon: const Icon(Icons.phone_disabled_rounded),
                label: Text(t.ccStopFrom(name)),
              )
            : FilledButton.tonalIcon(
                onPressed: busy ? null : () => _consent(l, true),
                icon: const Icon(Icons.phone_callback_rounded),
                label: Text(t.ccAllowAgain(name)),
              ),
      ),
    );
  }

  Widget _quietTile(AppLocalizations t) {
    final qs = '${_m?['quiet_start'] ?? ''}', qe = '${_m?['quiet_end'] ?? ''}';
    final on = qs.isNotEmpty && qe.isNotEmpty;
    return Card(
      margin: const EdgeInsets.only(top: Gap.sm),
      child: ListTile(
        minTileHeight: 64,
        leading: const Icon(Icons.bedtime_rounded),
        title: Text(t.ccQuietTitle),
        subtitle: Text(on ? t.ccQuietValue(ccTimeText(context, qs), ccTimeText(context, qe)) : t.ccQuietOff),
        trailing: const Icon(Icons.chevron_right_rounded),
        onTap: _busy.contains('quiet') ? null : _editQuiet,
      ),
    );
  }
}

/// App open / resume: flush queues + keep the phone's alarms in step
/// (main.dart). Flag-gated and throttled; never throws.
Future<void> careCallResume(AppState app, {required bool enabled}) async {
  if (!enabled || !app.loggedIn) return;
  try {
    final api = HttpCareCallApi(app.api);
    await CareCallDrafts.flush(api);
    await CareCallSync.run(api, lang: app.locale?.languageCode == 'en' ? 'en' : 'bn');
  } catch (_) {}
}

/// The same data as a [CcItem] list (tests).
List<CcItem> ccReceivedOf(Map<String, dynamic> m) => [
      for (final x in (m['received'] as List? ?? const []))
        CcItem.fromJson(Map<String, dynamic>.from(x as Map))
    ];
