import 'dart:async'; // flag-cctv-e2e: offline auto-retry
import 'package:flutter/material.dart';
import '../../widgets/skeleton.dart';
import '../../ds/ds.dart';
import 'package:provider/provider.dart';

import '../../cashguard/cashguard_source.dart';
import '../../cctvx/cctvx_source.dart';
import '../../l10n/app_localizations.dart';
import '../../phonecam/phonecam_clips.dart';
import '../../state.dart';
import 'cash_guard_clip.dart';
import 'cctvx_actions.dart';
import 'cctv_escalate.dart' show police999Launch; // gap-cctv R1
import '../shop_live_screen.dart'; // gap-cctv R1
import '../../cctvguard/vendor_live_screen.dart'; // gap-cctv R1
import 'watchman_source.dart';
import 'watchman_widgets.dart';
import '../../widgets/app_sheet.dart';
import '../../widgets/cv_empty.dart';
import 'alert_snapshot.dart'; // flag-cctv-e2e

/// cctv1 ALERTS: every alert reads "Suspicious — please check" (never an
/// accusation), with its ONE snapshot, what was seen, how many times
/// (grouped), the confidence, and — for the owner — Correct / Wrong. Each
/// answer tunes that camera a little (bounded). Family viewers read only.
class WatchmanAlertsScreen extends StatefulWidget {
  final WatchmanSource source;
  final int siteId;
  final bool owner;

  /// cashguard: clip envelope + download (tests / gallery inject a fake).
  final CashGuardSource? cash;

  /// cctvx: alert actions (siren, call the shop, share, evidence, 999).
  final CctvxSource? extras;

  /// cctvplay: phone-camera full video on demand (tests inject a fake).
  final PhoneCamClipSource? phoneSource;

  /// cctvveh: does this place have a camera yet (empty-state wording), and
  /// the first real step from an empty list (zones, or add a camera).
  final bool hasCamera;
  final VoidCallback? onSetup;
  const WatchmanAlertsScreen(
      {super.key,
      required this.source,
      required this.siteId,
      required this.owner,
      this.cash,
      this.extras,
      this.phoneSource,
      this.hasCamera = true,
      this.onSetup});

  @override
  State<WatchmanAlertsScreen> createState() => _WatchmanAlertsScreenState();
}

class _WatchmanAlertsScreenState extends State<WatchmanAlertsScreen> {
  bool _loading = true;
  String? _error;
  List<Map<String, dynamic>> _events = const [];
  int _held = 0;
  final Set<int> _busy = {};

  CashGuardSource? _cashSrc() {
    if (widget.cash != null) return widget.cash;
    try {
      return ApiCashGuardSource(context.read<AppState>().api);
    } catch (_) {
      return null;
    }
  }

  PhoneCamClipSource? _phoneSrc() {
    if (widget.phoneSource != null) return widget.phoneSource;
    try {
      return ApiPhoneCamClipSource(context.read<AppState>().api);
    } catch (_) {
      return null;
    }
  }

  CctvxSource? _extras() {
    if (widget.extras != null) return widget.extras;
    try {
      return ApiCctvxSource(context.read<AppState>().api);
    } catch (_) {
      return null;
    }
  }

  Future<void> _openClip(Map<String, dynamic> e) async {
    final src = _cashSrc();
    if (src == null) return;
    final clip = wmMap(e['clip']);
    await CashClipSheet.show(context, src, (e['id'] as num).toInt(), widget.owner,
        extras: widget.owner ? _extras() : null,
        photoUrl: (e['snapshot_url'] ?? '').toString(),
        // cctvplay: a phone camera's alert can fetch the full video
        phoneSource: clip['phonecam'] == true ? _phoneSrc() : null,
        previewStatus: (clip['status'] ?? '').toString());
    if (mounted) await _load();
  }

  /// gap-cctv R1: Live straight from the card (the right player per brand).
  void _openLive(Map<String, dynamic> e) {
    final cam = (e['camera'] as num?)?.toInt();
    if (cam == null) return;
    final name = (e['camera_name'] ?? '').toString();
    Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => e['live_path'] == 'vendor'
            ? VendorLiveScreen(cameraId: cam, cameraName: name)
            : ShopLiveScreen(cameraId: cam, cameraName: name)));
  }

  /// gap-cctv R1: 999 asks first, then only opens the dialer (never calls).
  Future<void> _call999() async {
    final t = AppLocalizations.of(context);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(t.cx999),
        content: Text(t.cx999Sub),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(t.wmCancel)),
          FilledButton(
              key: const ValueKey('wm-alert-999-yes'),
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(t.cx999Call)),
        ],
      ),
    );
    if (ok == true) await police999Launch(Uri.parse('tel:999'));
  }

  Future<void> _actions(Map<String, dynamic> e) async {
    final x = _extras();
    if (x == null) return;
    await AlertActionsSheet.show(context, x, (e['id'] as num).toInt(), cash: _cashSrc());
    // gap-cctv: a "Wrong alert" marked in the sheet shows on the card at once
    if (mounted) await _load();
  }

  @override
  void initState() {
    super.initState();
    _load();
  }

  /// flag-cctv-e2e: offline when the alert came -> the list retries BY
  /// ITSELF (5 s, 10 s, 20 s, then every 30 s) until the network is back;
  /// the Try again button still works at once.
  static List<int> autoRetryS = const [5, 10, 20, 30];
  Timer? _retryTimer;
  int _fails = 0;

  @override
  void dispose() {
    _retryTimer?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    _retryTimer?.cancel();
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final r = await widget.source.events(widget.siteId);
      _events = wmList(r['events']);
      _held = (r['held_today'] as num?)?.toInt() ?? 0;
      _fails = 0;
    } catch (e) {
      _error = wmError(e) ?? '';
      final wait = autoRetryS[_fails < autoRetryS.length ? _fails : autoRetryS.length - 1];
      _fails++;
      _retryTimer = Timer(Duration(seconds: wait), () {
        if (mounted && _error != null) _load();
      });
    }
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _mark(Map<String, dynamic> e, String verdict) async {
    final t = AppLocalizations.of(context);
    final id = (e['id'] as num).toInt();
    setState(() => _busy.add(id));
    try {
      final r = await widget.source.mark(id, verdict);
      e['status'] = r['status'];
      e['verdict'] = r['verdict'];
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(verdict == 'wrong' ? t.wmMarkedWrong : t.wmMarkedCorrect)));
      }
    } catch (err) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(wmError(err) ?? t.wmGenericError)));
      }
    }
    if (mounted) setState(() => _busy.remove(id));
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final lang = wmLang(context);
    Widget body;
    if (_loading) {
      body = const SkeletonList();
    } else if (_error != null) {
      body = ListView(padding: const EdgeInsets.all(Gap.lg), children: [
        // design2: DS error state (drawn illustration + one big retry)
        DsEmptyState(
          icon: Icons.cloud_off_rounded,
          title: t.wmLoadErrorTitle,
          benefit: _error!.isEmpty ? t.wmLoadErrorBody : _error!,
          actionLabel: t.wmRetry,
          onAction: _load,
        ),
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Text(t.caeAutoRetry,
              key: const ValueKey('wm-alerts-autoretry'),
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodySmall),
        ),
      ]);
    } else {
      body = RefreshIndicator(
        onRefresh: _load,
        child: ListView(padding: withNavBarInset(context, const EdgeInsets.fromLTRB(16, 8, 16, 32)), children: [
          if (!widget.owner)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text(t.wmViewerReadOnly, style: Theme.of(context).textTheme.bodySmall),
            ),
          if (_held > 0)
            DsCard(
              padding: const EdgeInsets.all(12),
              child: Text(t.wmHeldToday(wmDigits(lang, _held))),
            ),
          // cctvveh: benefit + the first real step + how-to (owner)
          if (_events.isEmpty)
            CvEmptyBlock(
              icon: Icons.verified_user_outlined,
              title: t.wmNoAlertsTitle,
              benefit: widget.hasCamera ? t.wmNoAlertsBody : t.cvvAlertsEmptyNoCam,
              primaryIcon: widget.hasCamera ? Icons.draw_rounded : Icons.add_a_photo_outlined,
              primaryLabel: widget.hasCamera ? t.cvvAlertsPrimaryZones : t.wmAddCamera,
              onPrimary: widget.owner ? widget.onSetup : null,
              steps: widget.owner ? [t.cvvAlertsStep1, t.cvvAlertsStep2, t.cvvAlertsStep3] : const [],
            ),
          for (final e in _events) _alertCard(t, lang, e),
        ]),
      );
    }
    return Scaffold(appBar: AppBar(title: Text(t.wmAlerts)), body: body);
  }

  String _aiText(Map<String, dynamic> e) => (wmMap(e['ai_check'])['text'] ?? '').toString();

  Widget _aiPill(Map<String, dynamic> e) {
    final ai = wmMap(e['ai_check']);
    final done = ai['state'] == 'done';
    final likelyFalse = ai['likely_false'] == true;
    final seen = done && ai['cls'] != null && ai['cls'] != 'none';
    return Semantics(
      container: true,
      child: WmPill(
        label: _aiText(e),
        icon: likelyFalse
            ? Icons.help_outline_rounded
            : (done ? Icons.auto_awesome_rounded : Icons.hourglass_empty_rounded),
        color: seen
            ? wmOk()
            : likelyFalse
                ? wmWarn()
                : Theme.of(context).colorScheme.onSurfaceVariant,
      ),
    );
  }

  List<Widget> _detectLines(AppLocalizations t, Map<String, dynamic> e) {
    final d = wmMap(e['detect']);
    if (d.isEmpty) return const [];
    final small = Theme.of(context).textTheme.bodySmall;
    final detail = (d['detail'] ?? '').toString();
    final desc = (d['desc'] ?? '').toString();
    final measured = (d['measured_text'] ?? '').toString();
    return [
      if (detail.isNotEmpty) Text(detail),
      if (desc.isNotEmpty)
        Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Text(d['desc_src'] == 'ai' ? t.cdetDescAi(desc) : t.cdetDescTemplate(desc)),
        ),
      if (d['review_only'] == true) Text(t.cdetReviewOnly, style: small),
      if (measured.isNotEmpty)
        Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Text(measured, style: small),
        ),
    ];
  }

  Widget _alertCard(AppLocalizations t, String lang, Map<String, dynamic> e) {
    final loc = MaterialLocalizations.of(context);
    final dt = DateTime.tryParse((e['last_at'] ?? e['created'] ?? '').toString())?.toLocal();
    final when = dt == null
        ? ''
        : '${loc.formatShortDate(dt)} ${loc.formatTimeOfDay(TimeOfDay.fromDateTime(dt))}';
    final count = (e['count'] as num?)?.toInt() ?? 1;
    final pct = (((e['confidence'] as num?) ?? 0) * 100).round();
    final verdict = e['verdict'];
    final id = (e['id'] as num).toInt();
    final snap = (e['snapshot_url'] ?? '').toString();
    final cash = e['cash'] == true;
    final clip = wmMap(e['clip']);
    final clipSt = (clip['status'] ?? '').toString();
    return Card(
      margin: const EdgeInsets.only(top: 12),
      clipBehavior: Clip.antiAlias,
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        if (snap.isNotEmpty)
          AspectRatio(
            aspectRatio: 16 / 9,
            // flag-cctv-e2e: loading / slow 2G / retry / really-gone states
            child: AlertSnapshot(key: ValueKey('wm-snap-$id'), url: snap),
          ),
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 12, 14, 10),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Wrap(spacing: 6, runSpacing: 6, children: [
              WmPill(
                  label: e['nosale'] == true
                      ? t.cxNoSalePill
                      : (cash ? t.cgPossibleCashRemoval : t.wmSuspiciousLabel),
                  icon: cash ? Icons.point_of_sale_rounded : Icons.visibility_rounded,
                  color: wmWarn()),
              if (e['away'] == true)
                WmPill(label: t.cgAwayPill, icon: Icons.directions_walk_rounded, color: wmBad()),
            ]),
            const SizedBox(height: 8),
            Text(wmEventWhatOf(t, e),
                style: Theme.of(context).textTheme.titleMedium),
            if (cash)
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Text(t.cgDecideHint, style: Theme.of(context).textTheme.bodySmall),
              ),
            const SizedBox(height: 2),
            Text([
              if ((e['camera_name'] ?? '').toString().isNotEmpty) e['camera_name'].toString(),
              when,
            ].join(' · ')),
            const SizedBox(height: 2),
            // cctvdet: zone name / minutes, the photo described in words
            // (Claude's, or the plain template — labelled) and the accuracy
            // MEASURED in tests instead of a guessed confidence
            ..._detectLines(t, e),
            Text(
              [
                if (wmMap(e['detect'])['measured_text'] == null) t.wmConfidence(wmDigits(lang, pct)),
                if (count > 1) t.wmSeenTimes(wmDigits(lang, count)),
              ].join(' · '),
              style: Theme.of(context).textTheme.bodySmall,
            ),
            if (snap.isEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(t.wmNoSnapshot,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(color: DsTokens.of(context).muted)),
              ),
            // cctvaicheck: the AI label of the photo (server words, viewer's
            // language) — never hides the alert, only helps the owner tune
            if (_aiText(e).isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: _aiPill(e),
              ),
            if (clip.isNotEmpty) ...[
              const SizedBox(height: 8),
              if (clipSt == 'ready' || clipSt == 'pending' || clip['phonecam'] == true)
                FilledButton.tonalIcon(
                  style: FilledButton.styleFrom(minimumSize: const Size(48, 48)),
                  icon: const Icon(Icons.play_circle_outline_rounded),
                  label: Text(clip['phonecam'] == true
                      ? t.pcpWatchVideo
                      : clipSt == 'pending'
                          ? t.cgClipComing
                          : t.cgWatchClip),
                  onPressed: () => _openClip(e),
                )
              else
                Text(clipSt == 'viewed' ? t.cgClipWatchedGone : t.gcvClipExpiredGone, // gap-cctv: not always 24 h
                    style: Theme.of(context).textTheme.bodySmall),
            ],
            const SizedBox(height: 8),
            if (verdict != null)
              WmPill(
                label: verdict == 'wrong' ? t.wmVerdictWrong : t.wmVerdictCorrect,
                icon: verdict == 'wrong' ? Icons.thumb_down_alt_outlined : Icons.thumb_up_alt_outlined,
                color: verdict == 'wrong' ? wmBad() : wmOk(),
              ),
            if (widget.owner) ...[
              const SizedBox(height: 8),
              // gap-cctv R1: the first moves on the card itself — Live and
              // Call 999 — the rest (siren, own-voice warning, thana,
              // evidence, wrong alert) one tap away in "More actions"
              Wrap(spacing: 8, runSpacing: 8, children: [
                if (e['live_path'] == 'webrtc' || e['live_path'] == 'vendor')
                  FilledButton.icon(
                    key: ValueKey('wm-alert-live-$id'),
                    style: FilledButton.styleFrom(minimumSize: const Size(48, 48)),
                    icon: const Icon(Icons.live_tv_rounded),
                    label: Text(t.cv3Live),
                    onPressed: () => _openLive(e),
                  ),
                OutlinedButton.icon(
                  key: ValueKey('wm-alert-999-$id'),
                  style: OutlinedButton.styleFrom(
                      minimumSize: const Size(48, 48),
                      foregroundColor: Theme.of(context).colorScheme.error),
                  icon: const Icon(Icons.local_police_rounded),
                  label: Text(t.cx999),
                  onPressed: _call999,
                ),
                OutlinedButton.icon(
                  key: ValueKey('wm-alert-more-$id'),
                  style: OutlinedButton.styleFrom(minimumSize: const Size(48, 48)),
                  icon: const Icon(Icons.bolt_rounded),
                  label: Text(t.gcvMoreActions),
                  onPressed: () => _actions(e),
                ),
              ]),
              // design3 (flagship): the right/wrong feedback is a light row
              // under a hairline — the alert's own actions above stay the
              // visual weight (it was three equal outlined boxes)
              const Divider(height: Gap.lg),
              Wrap(spacing: Gap.sm, runSpacing: Gap.xs, children: [
                TextButton.icon(
                  style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
                  icon: const Icon(Icons.thumb_up_alt_outlined),
                  label: Text(t.wmCorrect),
                  onPressed: _busy.contains(id) || verdict == 'correct' ? null : () => _mark(e, 'correct'),
                ),
                TextButton.icon(
                  style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
                  icon: const Icon(Icons.thumb_down_alt_outlined),
                  label: Text(t.wmWrong),
                  onPressed: _busy.contains(id) || verdict == 'wrong' ? null : () => _mark(e, 'wrong'),
                ),
              ]),
            ],
          ]),
        ),
      ]),
    );
  }
}
