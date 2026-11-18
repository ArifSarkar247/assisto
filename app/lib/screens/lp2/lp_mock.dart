/// lpapp — IELTS OWN MOCKS: hub (Academic / General list, weekly free slot,
/// offline download), the mock run (full mock with the real timer, or one
/// section as practice), marking + AI scoring, the RESULT (owner-approved
/// screen 2) and weak-area practice. API: owner_actions/LANGUAGE_PARTNER_API.md.
/// Ads (owner 10 Nov PART B): Free users get one banner on the hub list, a
/// rewarded ad offer when the weekly slot or credits run out, and at most
/// one interstitial when LEAVING a result. NEVER an ad in the timed runner,
/// listening audio or speaking recording (test/lp2_ads_test.dart).
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../ds/ds.dart';
import 'package:provider/provider.dart';

import '../../ads/ad_banner_slot.dart';
import '../../ads/ad_moment.dart' show AdMomentOnShow; // adcontrol
import '../../ads/ad_placements.dart' show AdExitPlacement; // adcontrol
import '../../api.dart' show ApiException;
import '../../widgets/rewarded_ad_sheet.dart';
import '../../l10n/app_localizations.dart';
import '../../services/error_kind.dart' show honestFailText;
import '../../state.dart';
import '../../theme.dart';
import '../../widgets/app_sheet.dart';
import '../../widgets/local_counter.dart';
import '../../widgets/local_digits.dart';
import '../../widgets/skeleton.dart';
import '../../widgets/voice_input.dart';
import '../plans_screen.dart' show PlansScreen;
import 'lp_cert.dart';
import 'lp_companion.dart';
import 'lp_data.dart';
import 'lp_engine.dart';
import 'lp_life.dart' show lpVoice;
import 'lp_listen.dart';
import 'lp_score.dart';
import 'lp_ui.dart';
import 'lp_vocab.dart';

export 'lp_listen.dart' show debugLpPlay, debugLpEngine, LpAudioEngine;

const List<String> kLpSections = ['listening', 'reading', 'writing', 'speaking'];

/// Premium / weekly-slot explanation with a way forward (never a dead end).
/// Returns true when the user chose to open the section with [unlockCredits]
/// credits (earned e.g. with a rewarded ad — owner 10 Nov PART B).
Future<bool> lpGateSheet(BuildContext context, String reason, {String? nextFreeAt, int? unlockCredits}) async {
  final tr = AppLocalizations.of(context);
  final date = (nextFreeAt ?? '').length >= 10 ? ld(context, nextFreeAt!.substring(0, 10)) : '';
  final text = reason == 'week_used' ? tr.lp2WeekUsed(date) : tr.lp2FullIsPremium;
  var pay = false;
  await showAppSheet<void>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (ctx) => SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(Gap.lg, 0, Gap.lg, Gap.lg),
      child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text(text, style: AType.bodyMedium.copyWith(height: 1.4)),
        const SizedBox(height: Gap.lg),
        if (unlockCredits != null && unlockCredits > 0) ...[
          FilledButton.icon(
            key: const Key('lp2-pay-credits'),
            style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(kMinTap)),
            onPressed: () {
              pay = true;
              Navigator.of(ctx).pop();
            },
            icon: const Icon(Icons.lock_open_rounded),
            label: Text(tr.lp2OpenWithCredits(ld(context, unlockCredits))),
          ),
          const SizedBox(height: Gap.sm),
        ],
        OutlinedButton.icon(
          key: const Key('lp2-rewarded'),
          style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(kMinTap)),
          onPressed: () => RewardedAdSheet.show(ctx),
          icon: const Icon(Icons.ondemand_video_rounded),
          label: Text(tr.lp2WatchAdCredits),
        ),
        const SizedBox(height: Gap.sm),
        FilledButton(
          style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(kMinTap)),
          onPressed: () {
            Navigator.of(ctx).pop();
            Navigator.of(context).push(MaterialPageRoute(builder: (_) => const PlansScreen()));
          },
          child: Text(tr.lp2SeePlans),
        ),
        TextButton(
          style: TextButton.styleFrom(minimumSize: const Size.fromHeight(kMinTap)),
          onPressed: () {
            Navigator.of(ctx).pop();
            Navigator.of(context).push(MaterialPageRoute(builder: (_) => const LpVocabScreen()));
          },
          child: Text(tr.lp2FreeMeanwhile),
        ),
      ]),
    ),
  );
  return pay;
}

// ============================================================ hub

class LpIeltsHub extends StatefulWidget {
  const LpIeltsHub({super.key});
  @override
  State<LpIeltsHub> createState() => _LpIeltsHubState();
}

class _LpIeltsHubState extends State<LpIeltsHub> {
  String _kind = 'academic';
  Map<String, dynamic>? _data;
  bool _loading = true;
  Object? _fail;
  Set<String> _offline = {};
  String? _downloading;
  List<String> _weak = const [];
  // gap-lp: no internet -> the mocks saved on this phone still open
  List<Map<String, dynamic>> _saved = const [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _fail = null;
    });
    final api = context.read<AppState>().api;
    try {
      _data = await api.getJson('/lp/mocks?kind=$_kind');
      final ids = [for (final m in lpList(_data!['mocks'])) '${m['id']}'];
      final off = <String>{};
      for (final id in ids) {
        if (await LpOffline.has(id)) off.add(id);
      }
      _offline = off;
      _saved = const [];
    } catch (e) {
      _fail = e;
      _saved = [for (final m in await LpOffline.list()) if ('${m['kind']}' == _kind) m];
      _offline = {for (final m in _saved) '${m['id']}'};
    }
    try {
      final res = await api.listItems(kLpResults);
      res.sort((a, b) => ((b['at'] as num?) ?? 0).compareTo((a['at'] as num?) ?? 0));
      _weak = res.isEmpty ? const [] : lpStrs(res.first['weak']);
    } catch (_) {
      // best-effort: weak-area tags only; the mock list above has its own error state
    }
    if (mounted) setState(() => _loading = false);
  }

  void _open(Widget w) async {
    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => w));
    if (mounted) unawaited(_load());
  }

  Future<void> _download(Map<String, dynamic> m) async {
    final tr = AppLocalizations.of(context);
    final id = '${m['id']}';
    if (_offline.contains(id)) {
      await LpOffline.remove(id);
      setState(() => _offline.remove(id));
      if (mounted) lpToast(context, tr.lp2OfflineRemoved);
      return;
    }
    setState(() => _downloading = id);
    try {
      final full = await context.read<AppState>().api.getJson('/lp/mocks/$id');
      await LpOffline.save(id, full);
      _offline.add(id);
      if (mounted) lpToast(context, tr.lp2OfflineSaved);
    } on ApiException catch (e) {
      if (mounted && (e.reason == 'premium' || e.reason == 'week_used')) {
        await lpGateSheet(context, e.reason!, nextFreeAt: '${e.body?['next_free_at'] ?? ''}');
      } else if (mounted) {
        lpToast(context, honestFailText(tr, e, otherwise: tr.lp2DownloadFail));
      }
    } catch (e) {
      if (mounted) lpToast(context, honestFailText(tr, e, otherwise: tr.lp2DownloadFail));
    }
    if (mounted) setState(() => _downloading = null);
  }

  @override
  Widget build(BuildContext context) {
    final tr = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final premium = _data?['premium'] == true;
    final left = (_data?['free_sections_left_week'] as num?)?.toInt();
    final mocks = lpList(_data?['mocks']);
    return Scaffold(
      bottomNavigationBar: const AdBannerSlot(screen: 'lp_hub'),
      appBar: AppBar(title: Text(tr.lp2IeltsTitle)),
      body: RefreshIndicator(
        onRefresh: _load,
        child: ListView(
          padding: withNavBarInset(context, const EdgeInsets.fromLTRB(Gap.lg, Gap.md, Gap.lg, Gap.xxl)),
          children: [
            Wrap(spacing: Gap.sm, runSpacing: Gap.sm, children: [
              ActionChip(
                avatar: const Icon(Icons.menu_book_rounded, size: 18),
                label: Text(tr.lp2BookCompanion),
                materialTapTargetSize: MaterialTapTargetSize.padded,
                onPressed: () => _open(const LpCompanionScreen()),
              ),
              ActionChip(
                avatar: const Icon(Icons.style_rounded, size: 18),
                label: Text(tr.lp2VocabTitle),
                materialTapTargetSize: MaterialTapTargetSize.padded,
                onPressed: () => _open(const LpVocabScreen()),
              ),
              ActionChip(
                key: const Key('lp2-weak-chip'),
                avatar: const Icon(Icons.fitness_center_rounded, size: 18),
                label: Text(tr.lp2WeakAreas),
                materialTapTargetSize: MaterialTapTargetSize.padded,
                onPressed: () => _open(LpWeakPractice(tags: _weak.isEmpty ? const ['reading'] : _weak)),
              ),
            ]),
            const SizedBox(height: Gap.md),
            SegmentedButton<String>(
              segments: [
                ButtonSegment(value: 'academic', label: Text(tr.lp2Academic)),
                ButtonSegment(value: 'general', label: Text(tr.lp2General)),
              ],
              selected: {_kind},
              onSelectionChanged: (s) {
                _kind = s.first;
                _load();
              },
            ),
            const SizedBox(height: Gap.md),
            if (_data != null && !premium)
              DsSurface(color: scheme.ds.primarySoft,
                padding: EdgeInsets.zero,
                child: ListTile(
                  leading: Icon(Icons.card_giftcard_rounded, color: scheme.ds.primaryInk),
                  title: Text(tr.lp2FreeLeft(ld(context, left ?? 0)),
                      style: AType.bodyMedium.copyWith(color: scheme.ds.primaryInk, fontWeight: FontWeight.w600)),
                  subtitle: Text(tr.lp2FreeLeftSub, style: AType.bodyMedium.copyWith(color: scheme.ds.primaryInk)),
                  onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const PlansScreen())),
                ),
              ),
            if (_loading)
              const Padding(padding: EdgeInsets.all(Gap.xl), child: Center(child: CircularProgressIndicator()))
            else if (_fail != null && _saved.isNotEmpty) ...[
              DsCard(
                key: const Key('lp2-saved-offline'),
                padding: EdgeInsets.zero,
                child: ListTile(
                  leading: Icon(Icons.cloud_off_rounded, color: DsTokens.of(context).dangerInk),
                  title: Text(tr.lp2gSavedOffline),
                  trailing: TextButton(onPressed: _load, child: Text(tr.retry)),
                ),
              ),
              const SizedBox(height: Gap.md),
              for (final m in _saved)
                _MockCard(
                  m: m,
                  premium: true,
                  offline: true,
                  downloading: false,
                  onFull: () => _open(LpMockRunner(mock: m, sections: kLpSections, full: true)),
                  onSection: (s) => _open(LpMockRunner(mock: m, sections: [s], full: false)),
                  onDownload: () => _download(m),
                ),
            ] else if (_fail != null)
              StateMessage(
                icon: Icons.cloud_off_rounded,
                tint: scheme.error,
                title: tr.loadFailed,
                message: honestFailText(tr, _fail, otherwise: tr.lp2MocksFail),
                action: FilledButton.tonalIcon(
                    onPressed: _load, icon: const Icon(Icons.refresh_rounded), label: Text(tr.retry)),
              )
            else if (mocks.isEmpty)
              StateMessage(
                icon: Icons.hourglass_top_rounded,
                title: tr.lp2NoMocksNowTitle,
                message: tr.lp2NoMocksNowBody,
                action: FilledButton.icon(
                  onPressed: () => _open(const LpCompanionScreen()),
                  icon: const Icon(Icons.menu_book_rounded),
                  label: Text(tr.lp2BookCompanion),
                ),
              )
            else
              for (final m in mocks)
                _MockCard(
                  m: m,
                  premium: premium,
                  offline: _offline.contains('${m['id']}'),
                  downloading: _downloading == '${m['id']}',
                  onFull: () {
                    if (premium || _offline.contains('${m['id']}')) {
                      _open(LpMockRunner(mock: m, sections: kLpSections, full: true));
                    } else {
                      lpGateSheet(context, 'premium');
                    }
                  },
                  onSection: (s) => _open(LpMockRunner(mock: m, sections: [s], full: false)),
                  onDownload: () => _download(m),
                ),
            LpPracticeFooter(text: tr.lp2MocksOriginal),
          ],
        ),
      ),
    );
  }
}

class _MockCard extends StatelessWidget {
  final Map<String, dynamic> m;
  final bool premium, offline, downloading;
  final VoidCallback onFull, onDownload;
  final ValueChanged<String> onSection;
  const _MockCard(
      {required this.m,
      required this.premium,
      required this.offline,
      required this.downloading,
      required this.onFull,
      required this.onSection,
      required this.onDownload});
  @override
  Widget build(BuildContext context) {
    final tr = AppLocalizations.of(context);
    final sections = lpStrs(m['sections']).isEmpty ? kLpSections : lpStrs(m['sections']);
    return Padding(key: Key('lp2-mock-${m['id']}'), padding: const EdgeInsets.only(bottom: Gap.md), child: DsCard(
        padding: const EdgeInsets.fromLTRB(Gap.lg, Gap.md, Gap.sm, Gap.md),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(children: [
            Expanded(
              child: Text(lpLoc(context, m, 'title'),
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
            ),
            downloading
                ? const Padding(
                    padding: EdgeInsets.all(Gap.md),
                    child: SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2)))
                : IconButton(
                    tooltip: offline ? tr.lp2OfflineRemove : tr.lp2Download,
                    constraints: const BoxConstraints(minWidth: kMinTap, minHeight: kMinTap),
                    onPressed: onDownload,
                    icon: Icon(offline ? Icons.offline_pin_rounded : Icons.download_rounded),
                  ),
          ]),
          Wrap(spacing: Gap.xs, runSpacing: Gap.xs, children: [
            if (m['beta'] == true) LpTag(text: tr.lp2Beta, color: Brand.warning),
            if (offline) LpTag(text: tr.lp2Offline, color: Brand.success),
          ]),
          const SizedBox(height: Gap.sm),
          FilledButton.icon(
            key: Key('lp2-full-${m['id']}'),
            style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(kMinTap)),
            onPressed: onFull,
            icon: Icon(premium || offline ? Icons.timer_rounded : Icons.lock_rounded),
            label: Text(tr.lp2FullMock),
          ),
          const SizedBox(height: Gap.sm),
          Text(tr.lp2PracticeOne, style: AType.bodySmall),
          const SizedBox(height: Gap.xs),
          Wrap(spacing: Gap.sm, runSpacing: Gap.sm, children: [
            for (final s in sections)
              OutlinedButton(
                key: Key('lp2-sec-${m['id']}-$s'),
                style: OutlinedButton.styleFrom(minimumSize: const Size(kMinTap, kMinTap)),
                onPressed: () => onSection(s),
                child: Text(lpSectionName(tr, s)),
              ),
          ]),
        ]),
      ));
  }
}

// ============================================================ runner

class LpMockRunner extends StatefulWidget {
  final Map<String, dynamic> mock;
  final List<String> sections;
  final bool full;
  const LpMockRunner({super.key, required this.mock, required this.sections, required this.full});
  @override
  State<LpMockRunner> createState() => _LpMockRunnerState();
}

class _LpMockRunnerState extends State<LpMockRunner> with WidgetsBindingObserver {
  Map<String, dynamic>? _m;
  bool _loading = true;
  Object? _fail;
  int _i = 0;
  bool _paused = false, _scoring = false;
  final DateTime _start = DateTime.now();
  final Map<String, Map<int, String>> _ans = {'listening': {}, 'reading': {}};
  final Map<int, TextEditingController> _writing = {};
  final Map<int, TextEditingController> _speaking = {};
  final Map<int, Duration> _spoken = {};
  final List<String> _progress = [];
  // gap-lp: what the server already marked / scored in THIS attempt — a retry
  // after a network failure never marks or charges a part twice
  final Map<String, Map<String, dynamic>> _done = {};
  // gap-lp: time left per section + the unfinished answers on the phone, so a
  // call, a low-RAM kill or a crash does not lose an hour of writing
  final Map<String, int> _left = {};
  int _ticks = 0;

  String get _draftKey => 'lp2_draft_${_id}_${widget.full ? 'full' : widget.sections.join('_')}';

  String get _id => '${widget.mock['id']}';
  String get _kind => '${widget.mock['kind'] ?? 'academic'}';
  String get _section => widget.sections[_i];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _load();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) unawaited(_saveDraft());
  }

  Future<void> _saveDraft() async {
    if (_m == null || _scoring) return;
    final d = {
      'at': DateTime.now().millisecondsSinceEpoch,
      'i': _i,
      'left': _left,
      'ans': {for (final e in _ans.entries) e.key: {for (final a in e.value.entries) '${a.key}': a.value}},
      'w': {for (final e in _writing.entries) '${e.key}': e.value.text},
      'sp': {for (final e in _speaking.entries) '${e.key}': e.value.text},
      'spoken': {for (final e in _spoken.entries) '${e.key}': e.value.inSeconds},
    };
    try {
      await (await SharedPreferences.getInstance()).setString(_draftKey, jsonEncode(d));
    } catch (_) {
      // best-effort: the answers are still on screen
    }
  }

  Future<void> _clearDraft() async {
    try {
      await (await SharedPreferences.getInstance()).remove(_draftKey);
    } catch (_) {
      // best-effort: an old draft is dropped after 12 h anyway
    }
  }

  /// true when unfinished answers (< 12 h old) were put back.
  Future<bool> _restoreDraft() async {
    try {
      final p = await SharedPreferences.getInstance();
      final raw = p.getString(_draftKey);
      if (raw == null) return false;
      final d = Map<String, dynamic>.from(jsonDecode(raw) as Map);
      final at = (d['at'] as num?)?.toInt() ?? 0;
      if (DateTime.now().millisecondsSinceEpoch - at > const Duration(hours: 12).inMilliseconds) {
        await p.remove(_draftKey);
        return false;
      }
      int? n(Object? k) => int.tryParse('$k');
      _i = ((d['i'] as num?)?.toInt() ?? 0).clamp(0, widget.sections.length - 1);
      (d['left'] as Map?)?.forEach((k, v) {
        if (v is num) _left['$k'] = v.toInt().clamp(1, 4 * 3600);
      });
      (d['ans'] as Map?)?.forEach((s, m) {
        if (_ans[s] != null && m is Map) {
          m.forEach((k, v) {
            if (n(k) != null) _ans[s]![n(k)!] = '$v';
          });
        }
      });
      for (final (key, ctrl) in [('w', _writing), ('sp', _speaking)]) {
        (d[key] as Map?)?.forEach((k, v) {
          if (n(k) != null) ctrl.putIfAbsent(n(k)!, TextEditingController.new).text = '$v';
        });
      }
      (d['spoken'] as Map?)?.forEach((k, v) {
        if (n(k) != null && v is num) _spoken[n(k)!] = Duration(seconds: v.toInt());
      });
      return true;
    } catch (_) {
      return false;
    }
  }

  void _onTick(String s, int left) {
    _left[s] = left;
    if (++_ticks % 15 == 0) unawaited(_saveDraft());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    for (final c in [..._writing.values, ..._speaking.values]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _load({bool pay = false}) async {
    setState(() {
      _loading = true;
      _fail = null;
    });
    final off = await LpOffline.read(_id);
    if (off != null && widget.sections.every((s) => off[s] is Map)) {
      _m = off;
    } else {
      try {
        _m = await context.read<AppState>().api.getJson(widget.full
            ? '/lp/mocks/$_id'
            : '/lp/mocks/$_id?section=${widget.sections.first}${pay ? '&pay=credits' : ''}');
      } on ApiException catch (e) {
        if (e.reason == 'premium' || e.reason == 'week_used') {
          if (mounted) {
            final payNow = await lpGateSheet(context, e.reason!,
                nextFreeAt: '${e.body?['next_free_at'] ?? ''}',
                unlockCredits: widget.full || pay ? null : (e.body?['unlock_credits'] as num?)?.toInt());
            if (!mounted) return;
            if (payNow) return _load(pay: true);
            Navigator.of(context).pop();
          }
          return;
        }
        _fail = e;
      } catch (e) {
        _fail = e;
      }
    }
    final restored = _m != null && _fail == null && await _restoreDraft();
    if (!mounted) return;
    setState(() => _loading = false);
    if (restored) lpToast(context, AppLocalizations.of(context).lp2gDraftBack);
  }

  int _duration(String s) =>
      ((_m?[s] as Map?)?['duration_sec'] as num?)?.toInt() ??
      switch (s) { 'listening' => 1800, 'reading' => 3600, 'writing' => 3600, _ => 840 };

  Future<bool> _confirmLeave() async {
    final tr = AppLocalizations.of(context);
    var leave = false;
    await showAppSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => Padding(
        padding: const EdgeInsets.fromLTRB(Gap.lg, 0, Gap.lg, Gap.lg),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text(tr.lp2LeaveTitle, style: Theme.of(ctx).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700)),
          const SizedBox(height: Gap.sm),
          Text(tr.lp2LeaveBody),
          const SizedBox(height: Gap.lg),
          FilledButton(
            style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(kMinTap)),
            onPressed: () => Navigator.of(ctx).pop(),
            child: Text(tr.lp2KeepGoing),
          ),
          TextButton(
            style: TextButton.styleFrom(minimumSize: const Size.fromHeight(kMinTap)),
            onPressed: () {
              leave = true;
              unawaited(_clearDraft()); // the sheet says the answers are lost
              Navigator.of(ctx).pop();
            },
            child: Text(tr.lp2LeaveTest),
          ),
        ]),
      ),
    );
    return leave;
  }

  void _next() {
    if (_i + 1 < widget.sections.length) {
      setState(() {
        _i++;
        _paused = false;
      });
      unawaited(_saveDraft());
    } else {
      _finish();
    }
  }

  /// gap-lp: questions / tasks of the current section still empty.
  int _unanswered() {
    final s = _section;
    final data = (_m?[s] as Map?) ?? const {};
    if (s == 'listening' || s == 'reading') {
      final parts = lpList(s == 'listening' ? data['parts'] : data['passages']);
      final total = parts.fold<int>(0, (a, p) => a + lpList(p['questions']).length);
      final done = _ans[s]!.values.where((v) => v.trim().isNotEmpty).length;
      return (total - done).clamp(0, total);
    }
    if (s == 'writing') {
      return lpList(data['tasks'])
          .where((t) => (_writing[(t['n'] as num?)?.toInt() ?? 1]?.text.trim() ?? '').isEmpty)
          .length;
    }
    return lpList(data['parts'])
        .where((p) => (_speaking[(p['n'] as num?)?.toInt() ?? 1]?.text.trim() ?? '').isEmpty)
        .length;
  }

  /// gap-lp: the Submit button asks first when answers are missing or (full
  /// mock) the section can never be opened again — a mis-tap no longer ends
  /// a section. Time-up still submits by itself, like the real exam.
  Future<void> _submitTapped() async {
    final missing = _unanswered();
    if (missing == 0 && !widget.full) {
      _next();
      return;
    }
    final tr = AppLocalizations.of(context);
    var go = false;
    await showAppSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => Padding(
        padding: const EdgeInsets.fromLTRB(Gap.lg, 0, Gap.lg, Gap.lg),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text(tr.lp2gSubmitTitle, style: Theme.of(ctx).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700)),
          const SizedBox(height: Gap.sm),
          if (missing > 0) Text(tr.lp2gUnanswered(ld(ctx, missing))),
          if (widget.full) Text(tr.lp2gNoReturn),
          const SizedBox(height: Gap.lg),
          FilledButton(
            style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(kMinTap)),
            onPressed: () => Navigator.of(ctx).pop(),
            child: Text(tr.lp2KeepGoing),
          ),
          TextButton(
            key: const Key('lp2-submit-confirm'),
            style: TextButton.styleFrom(minimumSize: const Size.fromHeight(kMinTap)),
            onPressed: () {
              go = true;
              Navigator.of(ctx).pop();
            },
            child: Text(tr.lp2gSubmitNow),
          ),
        ]),
      ),
    );
    if (go && mounted) _next();
  }

  Future<void> _finish() async {
    final tr = AppLocalizations.of(context);
    final api = context.read<AppState>().api;
    setState(() {
      _scoring = true;
      _progress.clear();
    });
    final bands = <String, double?>{};
    final details = <String, dynamic>{};
    final notes = <String, String>{};
    final weak = <String>{};
    try {
      for (final s in widget.sections) {
        setState(() => _progress.add(tr.lp2Marking(lpSectionName(tr, s))));
        if (s == 'listening' || s == 'reading') {
          final r = _done[s] ??= await api.postJson('/lp/mocks/$_id/mark', {
            'section': s,
            'answers': {for (final e in _ans[s]!.entries) '${e.key}': e.value},
          });
          details[s] = r;
          bands[s] = (r['band'] as num?)?.toDouble() ?? rawToBand(s, _kind, (r['raw'] as num?)?.toInt() ?? 0, (r['total'] as num?)?.toInt() ?? 40);
          weak.addAll(lpStrs(r['weak']));
        } else if (s == 'writing') {
          final tasks = lpList((_m?['writing'] as Map?)?['tasks']);
          final out = <Map<String, dynamic>>[];
          final tb = <int, double>{};
          for (final t in tasks) {
            final n = (t['n'] as num?)?.toInt() ?? 1;
            final text = _writing[n]?.text.trim() ?? '';
            if (text.isEmpty) continue;
            final r = _done['w$n|$text'] ?? await api.postJson('/lp/score/writing', {
              'mock_id': _id,
              'task': n,
              'variant': _kind,
              'prompt': '${t['prompt']}',
              'text': text,
            });
            if (r['ai_state'] == 'used') _done['w$n|$text'] = r;
            out.add({...r, 'n': n});
            final b = lpScoreBand(r);
            if (b != null) tb[n] = b;
          }
          details[s] = out;
          if (tb.containsKey(1) && tb.containsKey(2)) {
            bands[s] = lpHalf((tb[1]! + 2 * tb[2]!) / 3); // Task 2 counts double
          } else if (tb.isNotEmpty) {
            bands[s] = tb.values.first;
            notes[s] = tr.lp2OnlyOneTask;
          } else {
            bands[s] = null;
            notes[s] = out.isEmpty ? tr.lp2NotAnswered : (lpAiStateText(tr, '${out.first['ai_state']}') ?? '');
          }
        } else {
          final parts = lpList((_m?['speaking'] as Map?)?['parts']);
          final out = <Map<String, dynamic>>[];
          final pb = <double>[];
          for (final p in parts) {
            final n = (p['n'] as num?)?.toInt() ?? 1;
            final text = _speaking[n]?.text.trim() ?? '';
            if (text.isEmpty) continue;
            final prompt = n == 2 ? '${p['cue_card']}' : lpStrs(p['questions']).join('\n');
            final r = _done['s$n|$text'] ?? await api.postJson('/lp/score/speaking', {
              'mock_id': _id,
              'part': n,
              'prompt': prompt,
              'transcript': text,
              'seconds': (_spoken[n] ?? Duration.zero).inSeconds,
            });
            if (r['ai_state'] == 'used') _done['s$n|$text'] = r;
            out.add({...r, 'n': n});
            final b = lpScoreBand(r);
            if (b != null) pb.add(b);
          }
          details[s] = out;
          bands[s] = pb.isEmpty ? null : lpHalf(pb.reduce((a, b) => a + b) / pb.length);
          if (pb.isEmpty) {
            notes[s] = out.isEmpty ? tr.lp2NotAnswered : (lpAiStateText(tr, '${out.first['ai_state']}') ?? '');
          }
        }
      }
    } catch (e) {
      if (mounted) {
        setState(() => _scoring = false);
        lpToast(context, honestFailText(tr, e, otherwise: tr.lp2MarkFail));
      }
      return;
    }
    var overall = overallBand(bands);
    Map<String, dynamic> fin = const {};
    if (widget.full) {
      try {
        setState(() => _progress.add(tr.lp2Summary));
        fin = await api.postJson('/lp/mocks/$_id/finish', {
          'bands': {for (final e in bands.entries) if (e.value != null) e.key: e.value},
          'weak': weak.toList(),
        });
        if (fin['overall'] is num && overall != null) overall = (fin['overall'] as num).toDouble();
      } catch (_) {
        // the comment is optional; the phone already has every band
      }
    }
    unawaited(_clearDraft());
    final mins = DateTime.now().difference(_start).inMinutes.clamp(1, 180);
    unawaited(lpLogPractice(api, 'mock', mins));
    unawaited(lpSaveResult(api, {
      'kind': widget.full ? 'mock' : 'section',
      'mock_id': _id,
      'overall': overall,
      'bands': bands,
      'weak': weak.toList(),
    }));
    if (!mounted) return;
    await Navigator.of(context).pushReplacement(MaterialPageRoute(
      builder: (_) => LpMockResultScreen(
        title: lpLoc(context, widget.mock, 'title'),
        bands: bands,
        sections: widget.sections,
        overall: overall,
        notes: notes,
        details: details,
        finish: fin,
        weakTags: weak.toList(),
      ),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final tr = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final title = lpLoc(context, widget.mock, 'title');
    if (_loading) return Scaffold(appBar: AppBar(title: Text(title)), body: const SkeletonList());
    if (_fail != null || _m == null) {
      return Scaffold(
        appBar: AppBar(title: Text(title)),
        body: StateMessage(
          icon: Icons.cloud_off_rounded,
          tint: scheme.error,
          title: tr.loadFailed,
          message: honestFailText(tr, _fail, otherwise: tr.lp2MocksFail),
          action: FilledButton.tonalIcon(onPressed: _load, icon: const Icon(Icons.refresh_rounded), label: Text(tr.retry)),
        ),
      );
    }
    if (_scoring) {
      return Scaffold(
        appBar: AppBar(title: Text(title), automaticallyImplyLeading: false),
        body: ListView(padding: const EdgeInsets.all(Gap.xl), children: [
          const Center(child: CircularProgressIndicator()),
          const SizedBox(height: Gap.lg),
          for (final p in _progress) Text(p, textAlign: TextAlign.center),
          const SizedBox(height: Gap.md),
          Text(tr.lp2ScoringWait, textAlign: TextAlign.center, style: AType.bodyMedium.copyWith(color: scheme.ds.muted)),
        ]),
      );
    }
    final s = _section;
    final last = _i + 1 >= widget.sections.length;
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (did, _) async {
        if (did) return;
        if (await _confirmLeave() && context.mounted) Navigator.of(context).pop();
      },
      child: Scaffold(
        appBar: AppBar(
          title: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(lpSectionName(tr, s)),
            Text(widget.full ? tr.lp2FullStep(ld(context, _i + 1), ld(context, widget.sections.length)) : tr.lp2PracticeMode,
                style: AType.bodySmall),
          ]),
          actions: [
            if (s != 'speaking')
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: Gap.xs),
                child: Center(
                  child: LpTimer(
                    key: ValueKey('timer-$s'),
                    seconds: _left[s] ?? _duration(s),
                    paused: _paused,
                    onTick: (v) => _onTick(s, v),
                    onDone: () {
                      lpToast(context, tr.lp2TimeUp);
                      _next();
                    },
                  ),
                ),
              ),
            if (!widget.full && s != 'speaking')
              IconButton(
                tooltip: _paused ? tr.lp2Resume : tr.lp2Pause,
                onPressed: () => setState(() => _paused = !_paused),
                icon: Icon(_paused ? Icons.play_arrow_rounded : Icons.pause_rounded),
              ),
          ],
        ),
        body: _paused
            ? StateMessage(
                icon: Icons.pause_circle_rounded,
                title: tr.lp2Paused,
                action: FilledButton(onPressed: () => setState(() => _paused = false), child: Text(tr.lp2Resume)))
            : switch (s) {
                'listening' => _LrSection(
                    key: const ValueKey('L'),
                    section: 'listening',
                    data: (_m!['listening'] as Map?)?.cast<String, dynamic>() ?? const {},
                    answers: _ans['listening']!,
                    replay: !widget.full),
                'reading' => _LrSection(
                    key: const ValueKey('R'),
                    section: 'reading',
                    data: (_m!['reading'] as Map?)?.cast<String, dynamic>() ?? const {},
                    answers: _ans['reading']!,
                    replay: true),
                'writing' => _WritingSection(
                    data: (_m!['writing'] as Map?)?.cast<String, dynamic>() ?? const {}, ctrl: _writing),
                _ => _SpeakingSection(
                    data: (_m!['speaking'] as Map?)?.cast<String, dynamic>() ?? const {},
                    ctrl: _speaking,
                    spoken: _spoken),
              },
        bottomNavigationBar: SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(Gap.lg, Gap.sm, Gap.lg, Gap.md),
            child: FilledButton.icon(
              key: const Key('lp2-submit'),
              style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
              onPressed: _submitTapped,
              icon: Icon(last ? Icons.done_all_rounded : Icons.arrow_forward_rounded),
              label: Text(last ? tr.lp2SubmitFinish : tr.lp2SubmitNext),
            ),
          ),
        ),
      ),
    );
  }
}

// ----------------------------------------------------- questions

String _optValue(String option, int i) {
  final m = RegExp(r'^\s*([A-Za-z]{1,4})[.)]\s').firstMatch(option);
  if (m != null) return m.group(1)!;
  final t = option.trim();
  if (t.length <= 4 && !t.contains(' ')) return t;
  return String.fromCharCode(65 + i);
}

/// One question by type: choices (mcq / tfng / ynng / matching / map with
/// options), several choices (mcq_multi) or a short typed answer (gap/short).
class LpQuestion extends StatelessWidget {
  final Map<String, dynamic> q;
  final String value;
  final ValueChanged<String> onChanged;
  final String? result; // null = not marked; 'ok' / mistake type
  const LpQuestion({super.key, required this.q, required this.value, required this.onChanged, this.result});

  @override
  Widget build(BuildContext context) {
    final tr = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final type = '${q['type']}';
    final n = (q['n'] as num?)?.toInt() ?? 0;
    var options = lpStrs(q['options']);
    if (options.isEmpty && type == 'tfng') options = const ['TRUE', 'FALSE', 'NOT GIVEN'];
    if (options.isEmpty && type == 'ynng') options = const ['YES', 'NO', 'NOT GIVEN'];
    final multi = type == 'mcq_multi';
    final picked = value.split(',').where((x) => x.isNotEmpty).toSet();
    final maxW = (q['max_words'] as num?)?.toInt();
    return Padding(
      padding: const EdgeInsets.only(bottom: Gap.md),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          CircleAvatar(radius: 14, child: Text(ld(context, n), style: AType.bodySmall)),
          const SizedBox(width: Gap.sm),
          Expanded(child: Text('${q['prompt'] ?? ''}', style: AType.bodyMedium.copyWith(height: 1.4))),
        ]),
        const SizedBox(height: Gap.xs),
        if (options.isNotEmpty)
          Wrap(spacing: Gap.sm, runSpacing: Gap.xs, children: [
            for (final (i, o) in options.indexed)
              Builder(builder: (context) {
                final v = _optValue(o, i);
                final sel = multi ? picked.contains(v) : value == v || value.toUpperCase() == o.toUpperCase();
                return ChoiceChip(
                  label: Text(o),
                  selected: sel,
                  materialTapTargetSize: MaterialTapTargetSize.padded,
                  onSelected: (_) {
                    if (multi) {
                      final s = {...picked};
                      sel ? s.remove(v) : s.add(v);
                      onChanged((s.toList()..sort()).join(','));
                    } else {
                      onChanged(type == 'tfng' || type == 'ynng' ? o : v);
                    }
                  },
                );
              }),
          ])
        else
          TextFormField(
            initialValue: value,
            maxLength: 40,
            buildCounter: localCounter,
            onChanged: onChanged,
            decoration: InputDecoration(
              isDense: true,
              border: const OutlineInputBorder(),
              helperText: maxW == null ? null : tr.lp2MaxWords(ld(context, maxW)),
            ),
          ),
        if (result != null)
          Text(result == 'ok' ? tr.lp2Right : lpMistakeName(tr, result!),
              style: AType.bodyMedium.copyWith(
                  fontWeight: FontWeight.w700,
                  color: Brand.onTint(context, result == 'ok' ? Brand.success : Brand.danger))),
        if (result == null && type == 'mcq_multi')
          Text(tr.lp2ChooseMany, style: AType.bodySmall.copyWith(color: scheme.ds.muted)),
      ]),
    );
  }
}

List<Widget> _questionList(List<Map<String, dynamic>> qs, Map<int, String> answers, VoidCallback changed) {
  final out = <Widget>[];
  String? group;
  for (final q in qs) {
    final g = '${q['group'] ?? ''}';
    if (g.isNotEmpty && g != group) {
      out.add(Padding(
        padding: const EdgeInsets.only(bottom: Gap.sm),
        child: Text(g, style: AType.bodyMedium.copyWith(fontWeight: FontWeight.w700, height: 1.4)),
      ));
      group = g;
    }
    final n = (q['n'] as num?)?.toInt() ?? 0;
    out.add(LpQuestion(
      key: ValueKey('q$n'),
      q: q,
      value: answers[n] ?? '',
      onChanged: (v) {
        answers[n] = v;
        changed();
      },
    ));
  }
  return out;
}

class _LrSection extends StatefulWidget {
  final String section;
  final Map<String, dynamic> data;
  final Map<int, String> answers;
  final bool replay;
  const _LrSection(
      {super.key, required this.section, required this.data, required this.answers, required this.replay});
  @override
  State<_LrSection> createState() => _LrSectionState();
}

class _LrSectionState extends State<_LrSection> {
  int _part = 0;
  bool _showText = true;
  bool _running = false; // lpaudio: exam-mode listening in progress

  @override
  Widget build(BuildContext context) {
    final tr = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final listening = widget.section == 'listening';
    final parts = lpList(listening ? widget.data['parts'] : widget.data['passages']);
    if (parts.isEmpty) {
      return StateMessage(icon: Icons.hourglass_empty_rounded, title: tr.lp2SectionEmpty);
    }
    final p = parts[_part.clamp(0, parts.length - 1)];
    final qs = lpList(p['questions']);
    final answered = widget.answers.values.where((v) => v.trim().isNotEmpty).length;
    final total = parts.fold<int>(0, (a, x) => a + lpList(x['questions']).length);
    return ListView(
      padding: const EdgeInsets.fromLTRB(Gap.lg, Gap.md, Gap.lg, Gap.xxl),
      children: [
        Text(tr.lp2Answered(ld(context, answered), ld(context, total)),
            style: AType.bodySmall.copyWith(color: scheme.ds.muted)),
        const SizedBox(height: Gap.sm),
        Wrap(spacing: Gap.sm, runSpacing: Gap.sm, children: [
          for (var i = 0; i < parts.length; i++)
            ChoiceChip(
              label: Text(listening ? tr.lp2PartN(ld(context, i + 1)) : tr.lp2PassageN(ld(context, i + 1))),
              selected: _part == i,
              // exam mode: the recording leads, parts open as it reaches them
              onSelected: _running ? null : (_) => setState(() => _part = i),
            ),
        ]),
        const SizedBox(height: Gap.md),
        if (listening)
          // lpaudio: recorded audio, real-test flow (question time -> once -> check -> next part)
          LpListenPanel(
              parts: parts,
              part: _part,
              replay: widget.replay,
              onPart: (i) => setState(() => _part = i),
              onRunning: (r) => setState(() => _running = r))
        else ...[
          SegmentedButton<bool>(
            segments: [
              ButtonSegment(value: true, label: Text(tr.lp2Passage)),
              ButtonSegment(value: false, label: Text(tr.lp2Questions)),
            ],
            selected: {_showText},
            onSelectionChanged: (v) => setState(() => _showText = v.first),
          ),
          const SizedBox(height: Gap.md),
        ],
        if (!listening && _showText) ...[
          Text('${p['title'] ?? ''}', style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
          const SizedBox(height: Gap.sm),
          SelectableText('${p['text'] ?? ''}', style: AType.bodyMedium.copyWith(height: 1.6)),
          const SizedBox(height: Gap.md),
          OutlinedButton.icon(
            style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(kMinTap)),
            onPressed: () => setState(() => _showText = false),
            icon: const Icon(Icons.quiz_rounded),
            label: Text(tr.lp2Questions),
          ),
        ] else
          ..._questionList(qs, widget.answers, () => setState(() {})),
      ],
    );
  }
}

class _WritingSection extends StatefulWidget {
  final Map<String, dynamic> data;
  final Map<int, TextEditingController> ctrl;
  const _WritingSection({required this.data, required this.ctrl});
  @override
  State<_WritingSection> createState() => _WritingSectionState();
}

class _WritingSectionState extends State<_WritingSection> {
  @override
  Widget build(BuildContext context) {
    final tr = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final tasks = lpList(widget.data['tasks']);
    if (tasks.isEmpty) return StateMessage(icon: Icons.hourglass_empty_rounded, title: tr.lp2SectionEmpty);
    return ListView(
      padding: const EdgeInsets.fromLTRB(Gap.lg, Gap.md, Gap.lg, Gap.xxl),
      children: [
        Text(tr.lp2WritingHint, style: AType.bodyMedium.copyWith(color: scheme.ds.muted, height: 1.4)),
        for (final t in tasks) ...[
          const SizedBox(height: Gap.lg),
          Builder(builder: (context) {
            final n = (t['n'] as num?)?.toInt() ?? 1;
            final c = widget.ctrl.putIfAbsent(n, TextEditingController.new);
            final min = (t['min_words'] as num?)?.toInt() ?? (n == 1 ? 150 : 250);
            final w = wordCount(c.text);
            final img = '${t['image_url'] ?? ''}';
            return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Text(tr.lp2TaskN(ld(context, n)),
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
              const SizedBox(height: Gap.xs),
              DsCard(
                padding: const EdgeInsets.all(Gap.md),
                child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                    SelectableText('${t['prompt'] ?? ''}', style: AType.bodyMedium.copyWith(height: 1.5)),
                    if (img.startsWith('http'))
                      Padding(
                        padding: const EdgeInsets.only(top: Gap.sm),
                        child: Image.network(img,
                            errorBuilder: (_, __, ___) => Text(tr.lp2ImageFail,
                                style: AType.bodyMedium.copyWith(color: scheme.ds.muted))),
                      ),
                  ]),
              ),
              const SizedBox(height: Gap.sm),
              TextField(
                key: Key('lp2-w$n'),
                controller: c,
                maxLength: 6000,
                buildCounter: localCounter,
                minLines: 8,
                maxLines: 30,
                onChanged: (_) => setState(() {}),
                decoration: InputDecoration(labelText: tr.lp2YourAnswer, border: const OutlineInputBorder()),
              ),
              Text(tr.lp2WordsOfMin(ld(context, w), ld(context, min)),
                  style: AType.bodyMedium.copyWith(
                      fontWeight: FontWeight.w600,
                      color: w >= min ? Brand.onTint(context, Brand.success) : scheme.ds.muted)),
            ]);
          }),
        ],
      ],
    );
  }
}

class _SpeakingSection extends StatefulWidget {
  final Map<String, dynamic> data;
  final Map<int, TextEditingController> ctrl;
  final Map<int, Duration> spoken;
  const _SpeakingSection({required this.data, required this.ctrl, required this.spoken});
  @override
  State<_SpeakingSection> createState() => _SpeakingSectionState();
}

class _SpeakingSectionState extends State<_SpeakingSection> {
  late final VoiceDictation _voice = lpVoice();
  final _heard = TextEditingController();
  int _part = 0;
  final Map<int, int> _q = {}; // part -> current question index
  bool _prep = false, _talk = false;

  @override
  void dispose() {
    _voice.stop();
    _voice.dispose();
    _heard.dispose();
    super.dispose();
  }

  void _add(int part, String t) {
    final c = widget.ctrl.putIfAbsent(part, TextEditingController.new);
    setState(() => c.text = c.text.isEmpty ? t : '${c.text}\n$t');
  }

  @override
  Widget build(BuildContext context) {
    final tr = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final parts = lpList(widget.data['parts']);
    if (parts.isEmpty) return StateMessage(icon: Icons.hourglass_empty_rounded, title: tr.lp2SectionEmpty);
    final p = parts[_part.clamp(0, parts.length - 1)];
    final n = (p['n'] as num?)?.toInt() ?? _part + 1;
    final c = widget.ctrl.putIfAbsent(n, TextEditingController.new);
    final qs = lpStrs(p['questions']);
    final qi = (_q[n] ?? 0).clamp(0, qs.isEmpty ? 0 : qs.length - 1);
    return ListView(
      padding: const EdgeInsets.fromLTRB(Gap.lg, Gap.md, Gap.lg, Gap.xxl),
      children: [
        Wrap(spacing: Gap.sm, runSpacing: Gap.sm, children: [
          for (var i = 0; i < parts.length; i++)
            ChoiceChip(
              label: Text(tr.lp2PartN(ld(context, i + 1))),
              selected: _part == i,
              onSelected: (_) => setState(() {
                _part = i;
                _prep = _talk = false;
              }),
            ),
        ]),
        const SizedBox(height: Gap.md),
        if (n == 2) ...[
          DsCard(
            padding: const EdgeInsets.all(Gap.md),
            child: Row(children: [
                Expanded(child: SelectableText('${p['cue_card'] ?? ''}', style: AType.bodyMedium.copyWith(height: 1.5))),
                LpListenButton(text: '${p['cue_card'] ?? ''}'),
              ]),
          ),
          const SizedBox(height: Gap.sm),
          if (!_prep && !_talk)
            FilledButton.tonalIcon(
              style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(kMinTap)),
              onPressed: () => setState(() => _prep = true),
              icon: const Icon(Icons.timer_rounded),
              label: Text(tr.lp2StartPrep),
            ),
          if (_prep)
            Row(children: [
              Text(tr.lp2Prep),
              const SizedBox(width: Gap.sm),
              LpTimer(
                seconds: (p['prep_sec'] as num?)?.toInt() ?? 60,
                onDone: () => setState(() {
                  _prep = false;
                  _talk = true;
                }),
              ),
              const Spacer(),
              TextButton(
                  onPressed: () => setState(() {
                        _prep = false;
                        _talk = true;
                      }),
                  child: Text(tr.lp2SkipPrep)),
            ]),
          if (_talk)
            Row(children: [
              Text(tr.lp2TalkNow),
              const SizedBox(width: Gap.sm),
              LpTimer(
                seconds: (p['talk_sec'] as num?)?.toInt() ?? 120,
                onDone: () {
                  _voice.stop();
                  setState(() => _talk = false);
                  lpToast(context, tr.lp2TimeUp);
                },
              ),
            ]),
        ] else if (qs.isNotEmpty) ...[
          Text(tr.lp2QuestionOf(ld(context, qi + 1), ld(context, qs.length)),
              style: AType.bodySmall.copyWith(color: scheme.ds.muted)),
          DsSurface(color: scheme.ds.cardHighest,
            padding: const EdgeInsets.fromLTRB(Gap.md, Gap.sm, Gap.xs, Gap.sm),
            child: Row(children: [
                Expanded(child: Text(qs[qi], style: AType.bodyMedium.copyWith(fontWeight: FontWeight.w600, height: 1.4))),
                LpListenButton(text: qs[qi]),
              ]),
          ),
          Align(
            alignment: AlignmentDirectional.centerEnd,
            child: TextButton.icon(
              onPressed: qi + 1 < qs.length ? () => setState(() => _q[n] = qi + 1) : null,
              icon: const Icon(Icons.skip_next_rounded),
              label: Text(tr.lp2NextQuestion),
            ),
          ),
        ],
        const SizedBox(height: Gap.sm),
        LpHoldToSpeak(
          voice: _voice,
          heard: _heard,
          onHeld: (d) => widget.spoken[n] = (widget.spoken[n] ?? Duration.zero) + d,
          onDone: (t) {
            _add(n, t);
            if (n != 2 && qi + 1 < qs.length) setState(() => _q[n] = qi + 1);
          },
        ),
        const SizedBox(height: Gap.md),
        TextField(
          key: Key('lp2-s$n'),
          controller: c,
          maxLength: 6000,
          buildCounter: localCounter,
          minLines: 3,
          maxLines: 12,
          onChanged: (_) => setState(() {}),
          decoration: InputDecoration(labelText: tr.lp2WhatPhoneHeard, border: const OutlineInputBorder()),
        ),
        Text(tr.lp2SpeakingHow, style: AType.bodySmall.copyWith(color: scheme.ds.muted, height: 1.4)),
      ],
    );
  }
}

// ============================================================ result (screen 2)

class LpMockResultScreen extends StatelessWidget {
  final String title;
  final Map<String, double?> bands;
  final List<String> sections;
  final double? overall;
  final Map<String, String> notes;
  final Map<String, dynamic> details;
  final Map<String, dynamic> finish;
  final List<String> weakTags;
  const LpMockResultScreen(
      {super.key,
      required this.title,
      required this.bands,
      required this.sections,
      required this.overall,
      this.notes = const {},
      this.details = const {},
      this.finish = const {},
      this.weakTags = const []});

  @override
  Widget build(BuildContext context) {
    final tr = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final bn = lpBn(context);
    final aiComment = '${(bn ? finish['comment_bn'] : finish['comment_en']) ?? ''}'.trim();
    final weakest = weakestSection(bands);
    final comment = aiComment.isNotEmpty
        ? aiComment
        : weakest == null
            ? tr.lp2CommentNone
            : tr.lp2RuleComment(lpSectionName(tr, weakest), ld(context, bandText(bands[weakest]!)));
    final tags = weakTags.isNotEmpty ? weakTags : [if (weakest != null) weakest];
    final shownBand = overall ?? (sections.length == 1 ? bands[sections.first] : null);
    final label = finish['practice_label'];
    // adcontrol (owner 10 Nov 03:45): one interstitial after Submit, before the result
    return AdMomentOnShow(placement: AdExitPlacement.examAfterSubmit, child: LpAdExit(
      child: Scaffold(
      appBar: AppBar(title: Text(tr.lp2ResultTitle)),
      body: ListView(
        padding: withNavBarInset(context, const EdgeInsets.fromLTRB(Gap.lg, Gap.md, Gap.lg, Gap.xxl)),
        children: [
          Text(title, textAlign: TextAlign.center, style: AType.bodyMedium.copyWith(color: scheme.ds.muted)),
          const SizedBox(height: Gap.md),
          Center(
            child: Semantics(
              label: shownBand == null ? tr.lp2OverallNeedsAll : tr.lp2OverallBand(ld(context, bandText(shownBand))),
              excludeSemantics: true,
              child: SizedBox(
                width: 150,
                height: 150,
                child: Stack(alignment: Alignment.center, children: [
                  SizedBox.expand(
                    child: CircularProgressIndicator(
                      value: (shownBand ?? 0) / 9,
                      strokeWidth: 12,
                      color: scheme.primary,
                      backgroundColor: scheme.ds.cardHighest,
                    ),
                  ),
                  Column(mainAxisSize: MainAxisSize.min, children: [
                    Text(shownBand == null ? '–' : ld(context, bandText(shownBand)),
                        key: const Key('lp2-overall'),
                        style: Theme.of(context).textTheme.displaySmall?.copyWith(fontWeight: FontWeight.w800)),
                    Text(overall != null || sections.length > 1 ? tr.lp2Overall : lpSectionName(tr, sections.first),
                        style: AType.bodySmall),
                  ]),
                ]),
              ),
            ),
          ),
          if (shownBand == null)
            Padding(
              padding: const EdgeInsets.only(top: Gap.sm),
              child: Text(tr.lp2OverallNeedsAll, textAlign: TextAlign.center),
            ),
          const SizedBox(height: Gap.lg),
          DsCard(
            padding: const EdgeInsets.all(Gap.md),
            child: Column(children: [
                for (final s in kLpSections)
                  LpBandBar(
                    label: lpSectionName(tr, s),
                    band: bands[s],
                    note: sections.contains(s) ? notes[s] : tr.lp2NotTaken,
                  ),
              ]),
          ),
          const SizedBox(height: Gap.md),
          DsSurface(key: const Key('lp2-comment'), color: scheme.ds.primarySoft,
            padding: const EdgeInsets.all(Gap.md),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(children: [
                  Icon(Icons.auto_awesome_rounded, color: scheme.ds.primaryInk),
                  const SizedBox(width: Gap.sm),
                  Text(tr.lp2CoachComment,
                      style: AType.bodyMedium.copyWith(fontWeight: FontWeight.w700, color: scheme.ds.primaryInk)),
                ]),
                const SizedBox(height: Gap.sm),
                Text(comment, style: AType.bodyMedium.copyWith(color: scheme.ds.primaryInk, height: 1.45)),
              ]),
          ),
          const SizedBox(height: Gap.md),
          FilledButton.icon(
            key: const Key('lp2-weak'),
            style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
            onPressed: () => Navigator.of(context)
                .push(MaterialPageRoute(builder: (_) => LpWeakPractice(tags: tags.isEmpty ? const ['reading'] : tags))),
            icon: const Icon(Icons.fitness_center_rounded),
            label: Text(tr.lp2PracticeWeak),
          ),
          const SizedBox(height: Gap.md),
          if (lpCertFor(finish) != null) ...[lpCertFor(finish)!, const SizedBox(height: Gap.md)],
          for (final s in ['listening', 'reading'])
            if (details[s] is Map)
              ExpansionTile(
                tilePadding: EdgeInsets.zero,
                title: Text(tr.lp2ReviewAnswers(lpSectionName(tr, s)), style: AType.titleMedium.copyWith(fontWeight: FontWeight.w700)),
                children: [for (final it in lpList((details[s] as Map)['items'])) LpItemReview(it: it)],
              ),
          for (final s in ['writing', 'speaking'])
            for (final r in lpList(details[s]))
              Padding(
                padding: const EdgeInsets.only(bottom: Gap.sm),
                child: LpScoreView(
                    r: r,
                    title: '${lpSectionName(tr, s)} · ${s == 'writing' ? tr.lp2TaskN(ld(context, r['n'])) : tr.lp2PartN(ld(context, r['n']))}'),
              ),
          LpPracticeFooter(text: label is Map ? '${(bn ? label['bn'] : label['en']) ?? ''}' : null),
        ],
      ),
    )));
  }
}

/// One marked answer: your answer, the key, the mistake type and why.
class LpItemReview extends StatelessWidget {
  final Map<String, dynamic> it;
  const LpItemReview({super.key, required this.it});
  @override
  Widget build(BuildContext context) {
    final tr = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final ok = it['correct'] == true;
    final why = '${(lpBn(context) ? it['explain_bn'] : it['explain_en']) ?? ''}';
    final m = '${it['mistake'] ?? ''}';
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: Icon(ok ? Icons.check_circle_rounded : Icons.cancel_rounded,
          color: Brand.onTint(context, ok ? Brand.success : Brand.danger)),
      title: Text(tr.lp2ItemLine(ld(context, it['n'] ?? it['id'] ?? ''), '${it['your'] ?? ''}', '${it['key'] ?? ''}')),
      subtitle: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        if (!ok && m.isNotEmpty && m != 'null')
          Text(lpMistakeName(tr, m), style: AType.bodyMedium.copyWith(fontWeight: FontWeight.w600)),
        if (why.isNotEmpty) Text(why, style: AType.bodyMedium.copyWith(color: scheme.ds.muted, height: 1.4)),
      ]),
    );
  }
}

// ============================================================ weak areas

class LpWeakPractice extends StatefulWidget {
  final List<String> tags;
  const LpWeakPractice({super.key, required this.tags});
  @override
  State<LpWeakPractice> createState() => _LpWeakPracticeState();
}

class _LpWeakPracticeState extends State<LpWeakPractice> {
  List<Map<String, dynamic>> _items = const [];
  final Map<int, String> _ans = {};
  Map<String, Map<String, dynamic>> _marked = const {};
  bool _loading = true, _busy = false;
  Object? _fail;
  final DateTime _start = DateTime.now();

  @override
  void initState() {
    super.initState();
    _load();
  }

  String _qid(Map<String, dynamic> q) => '${q['id'] ?? q['n']}';

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _fail = null;
      _marked = const {};
      _ans.clear();
    });
    try {
      final r = await context.read<AppState>().api.postJson('/lp/weak/practice', {'tags': widget.tags, 'n': 10});
      _items = lpList(r['items']);
    } on ApiException catch (e) {
      if (e.reason == 'premium' && mounted) {
        await lpGateSheet(context, 'premium');
        if (mounted) Navigator.of(context).pop();
        return;
      }
      _fail = e;
    } catch (e) {
      _fail = e;
    }
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _mark() async {
    final tr = AppLocalizations.of(context);
    setState(() => _busy = true);
    try {
      final api = context.read<AppState>().api;
      final r = await api.postJson('/lp/practice/mark', {
        'answers': {
          for (var i = 0; i < _items.length; i++) _qid(_items[i]): _ans[i] ?? '',
        },
      });
      setState(() => _marked = {for (final it in lpList(r['items'])) '${it['id'] ?? it['n']}': it});
      unawaited(lpLogPractice(api, 'weak', DateTime.now().difference(_start).inMinutes.clamp(1, 60)));
    } catch (e) {
      if (mounted) lpToast(context, honestFailText(tr, e, otherwise: tr.lp2MarkFail));
    }
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    final tr = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    if (_loading) return Scaffold(appBar: AppBar(title: Text(tr.lp2WeakAreas)), body: const SkeletonList());
    if (_fail != null || _items.isEmpty) {
      return Scaffold(
        appBar: AppBar(title: Text(tr.lp2WeakAreas)),
        body: StateMessage(
          icon: _fail != null ? Icons.cloud_off_rounded : Icons.hourglass_empty_rounded,
          title: _fail != null ? tr.loadFailed : tr.lp2WeakEmpty,
          message: _fail != null ? honestFailText(tr, _fail, otherwise: tr.lp2MocksFail) : tr.lp2WeakEmptyBody,
          action: FilledButton.tonalIcon(onPressed: _load, icon: const Icon(Icons.refresh_rounded), label: Text(tr.retry)),
        ),
      );
    }
    final done = _marked.isNotEmpty;
    final right = _marked.values.where((m) => m['correct'] == true).length;
    return Scaffold(
      appBar: AppBar(title: Text(tr.lp2WeakAreas)),
      body: ListView(
        padding: withNavBarInset(context, const EdgeInsets.fromLTRB(Gap.lg, Gap.md, Gap.lg, Gap.xxl)),
        children: [
          Text(tr.lp2WeakIntro, style: AType.bodyMedium.copyWith(color: scheme.ds.muted, height: 1.4)),
          const SizedBox(height: Gap.md),
          if (done)
            DsSurface(color: scheme.ds.primarySoft,
              padding: EdgeInsets.zero,
              child: ListTile(
                title: Text(tr.lp2WeakScore(ld(context, right), ld(context, _items.length)),
                    style: AType.bodyMedium.copyWith(fontWeight: FontWeight.w700, color: scheme.ds.primaryInk)),
              ),
            ),
          for (var i = 0; i < _items.length; i++) ...[
            if ('${_items[i]['passage'] ?? ''}'.isNotEmpty)
              DsCard(
                padding: const EdgeInsets.all(Gap.md),
                child: SelectableText('${_items[i]['passage']}', style: AType.bodyMedium.copyWith(height: 1.5)),
              ),
            LpQuestion(
              q: {..._items[i], 'n': i + 1},
              value: _ans[i] ?? '',
              onChanged: done ? (_) {} : (v) => setState(() => _ans[i] = v),
              result: _marked[_qid(_items[i])] == null
                  ? null
                  : (_marked[_qid(_items[i])]!['correct'] == true
                      ? 'ok'
                      : '${_marked[_qid(_items[i])]!['mistake'] ?? 'other'}'),
            ),
            if (_marked[_qid(_items[i])] != null) LpItemReview(it: {..._marked[_qid(_items[i])]!, 'n': i + 1}),
          ],
          const SizedBox(height: Gap.md),
          if (!done)
            FilledButton.icon(
              style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
              onPressed: _busy ? null : _mark,
              icon: const Icon(Icons.fact_check_rounded),
              label: Text(tr.lp2CheckAnswers),
            )
          else
            FilledButton.tonalIcon(
              style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
              onPressed: _load,
              icon: const Icon(Icons.refresh_rounded),
              label: Text(tr.lp2MoreQuestions),
            ),
          const LpPracticeFooter(),
        ],
      ),
    );
  }
}
