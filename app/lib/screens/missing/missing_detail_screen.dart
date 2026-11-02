import 'dart:async';

import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:provider/provider.dart';

import '../../api.dart';
import '../../l10n/app_localizations.dart';
import '../../missing_alert_api.dart';
import '../../photo_studio/ps_engines.dart' show ChannelSecureScreen, SecureScreen;
import '../../state.dart';
import '../../theme.dart';
import '../../widgets/app_sheet.dart';
import '../../widgets/success_share.dart';
import '../../widgets/permission_reason.dart';
import 'ma_common.dart';
import 'missing_thread_screen.dart';

/// missing (owner 2 Nov) — one alert. What each side sees:
///  * a nearby user: photo, name, age, last seen + AREA, description, the GD
///    line with "not verified — contact the police", "I have information"
///    (a PRIVATE tip to the family), "Call 999" (own dialer), "Report fake";
///  * the family: who it reached, tips, Found / Close / Renew / Add GD;
///  * the missing person: "I am safe" (no location ever sent);
///  * a co-signer: confirm / not true.
/// A child's photo is shown with screenshots blocked (FLAG_SECURE) and every
/// photo carries the "please don't screenshot or repost" line.
class MissingDetailScreen extends StatefulWidget {
  const MissingDetailScreen({super.key, required this.alertId, this.secure, this.locate});

  final int alertId;
  final SecureScreen? secure;
  final Future<({double lat, double lng})?> Function()? locate;

  @override
  State<MissingDetailScreen> createState() => _MissingDetailScreenState();
}

class _MissingDetailScreenState extends State<MissingDetailScreen> {
  ApiClient get _api => context.read<AppState>().api;
  bool _loading = true;
  bool _failed = false;
  bool _busy = false;
  Map<String, dynamic> _a = const {};
  bool _secureOn = false;
  late final SecureScreen _secure = widget.secure ?? const ChannelSecureScreen();

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void dispose() {
    if (_secureOn) unawaited(_secure.disable().catchError((_) {}));
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _failed = false;
    });
    try {
      final r = await _api.maDetail(widget.alertId);
      if (!mounted) return;
      final a = (r['alert'] is Map) ? Map<String, dynamic>.from(r['alert'] as Map) : <String, dynamic>{};
      setState(() {
        _a = a;
        _loading = false;
      });
      final wantSecure = a['is_child'] == true && (a['photo_url'] ?? '') != '';
      if (wantSecure && !_secureOn) {
        _secureOn = true;
        unawaited(_secure.enable().catchError((_) => false));
      }
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _failed = true;
      });
    }
  }

  void _snack(String m) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));

  int get _id => widget.alertId;
  String get _role => '${_a['role'] ?? ''}';
  String get _state => '${_a['state'] ?? ''}';

  Future<bool> _act(String action, [Map<String, dynamic> body = const {}, String? okMsg]) async {
    final t = AppLocalizations.of(context);
    setState(() => _busy = true);
    try {
      final r = await _api.maAct(_id, action, body);
      if (!mounted) return false;
      setState(() => _busy = false);
      if (r['ok'] == true) {
        if (okMsg != null) _snack(okMsg);
        if (r['alert'] is Map) {
          setState(() => _a = Map<String, dynamic>.from(r['alert'] as Map));
        } else {
          unawaited(_load());
        }
        return true;
      }
      _snack(maReason(t, r['reason'] as String?));
    } catch (_) {
      if (mounted) {
        setState(() => _busy = false);
        _snack(t.maErrGeneric);
      }
    }
    return false;
  }

  Future<bool?> _confirm(String title, String body, String yes, {Key? yesKey}) {
    final t = AppLocalizations.of(context);
    return showAppSheet<bool>(
      context: context,
      builder: (ctx) => Padding(
        padding: const EdgeInsets.fromLTRB(Gap.lg, Gap.lg, Gap.lg, Gap.md),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text(title, style: Theme.of(ctx).textTheme.titleMedium),
          const SizedBox(height: Gap.sm),
          Text(body),
          const SizedBox(height: Gap.lg),
          ConstrainedBox(constraints: const BoxConstraints(minHeight: 52),
            child: FilledButton(key: yesKey, onPressed: () => Navigator.pop(ctx, true), child: Text(yes)),
          ),
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(t.maCancel)),
        ]),
      ),
    );
  }

  // ------------------------------------------------------------ family
  Future<void> _found() async {
    final t = AppLocalizations.of(context);
    var share = false;
    final yes = await showAppSheet<bool>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setS) => SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(Gap.lg, Gap.lg, Gap.lg, Gap.md),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Text(t.maFoundConfirmTitle, style: Theme.of(ctx).textTheme.titleMedium),
            const SizedBox(height: Gap.sm),
            Text(t.maFoundConfirmBody),
            const SizedBox(height: Gap.sm),
            CheckboxListTile(
              key: const ValueKey('ma-found-share'),
              contentPadding: EdgeInsets.zero,
              value: share,
              onChanged: (v) => setS(() => share = v == true),
              title: Text(t.maFoundShareAsk),
              subtitle: Text(t.maFoundShareSub),
            ),
            const SizedBox(height: Gap.md),
            ConstrainedBox(constraints: const BoxConstraints(minHeight: 52),
              child: FilledButton(
                key: const ValueKey('ma-found-confirm'),
                onPressed: () => Navigator.pop(ctx, true),
                child: Text(t.maFound),
              ),
            ),
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(t.maCancel)),
          ]),
        ),
      ),
    );
    if (yes != true || !mounted) return;
    final ok = await _act('found', {'share_ok': share}, t.maFoundDone);
    if (ok && share && mounted) await _openShare();
  }

  Future<void> _openShare() async {
    final t = AppLocalizations.of(context);
    final name = '${_a['name'] ?? ''}';
    final area = '${_a['area_text'] ?? ''}';
    final child = _a['is_child'] == true;
    await Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => SuccessShareScreen(
        title: t.maShareTitle,
        cardHeadline: t.maShareHeadline,
        initialText: child ? t.maShareTextChild(area) : t.maShareText(name, area),
        allowPhoto: true,
        photoWarning: child ? t.maSharePhotoChild : null,
      ),
    ));
  }

  Future<void> _close() async {
    final t = AppLocalizations.of(context);
    final yes = await _confirm(t.maCloseTitle, t.maCloseBody, t.maClose,
        yesKey: const ValueKey('ma-close-confirm'));
    if (yes == true && mounted) await _act('close', const {}, t.maClosed);
  }

  Future<void> _renew() async {
    final t = AppLocalizations.of(context);
    final adult = _a['is_child'] != true;
    final gd = TextEditingController();
    var still = false;
    final body = await showAppSheet<Map<String, dynamic>>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setS) => SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(Gap.lg, Gap.lg, Gap.lg, Gap.md),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Text(t.maRenewTitle, style: Theme.of(ctx).textTheme.titleMedium),
            const SizedBox(height: Gap.sm),
            Text(maD(ctx, t.maRenewBody(7))),
            if (adult) ...[
              const SizedBox(height: Gap.md),
              TextField(
                key: const ValueKey('ma-renew-gd'),
                controller: gd,
                decoration: InputDecoration(labelText: t.maGdNumberV2, border: const OutlineInputBorder()),
              ),
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                value: still,
                onChanged: (v) => setS(() => still = v == true),
                title: Text(t.maRenewGdStillV2),
              ),
            ],
            const SizedBox(height: Gap.md),
            ConstrainedBox(constraints: const BoxConstraints(minHeight: 52),
              child: FilledButton(
                key: const ValueKey('ma-renew-confirm'),
                onPressed: () => Navigator.pop(ctx, {
                  if (adult) 'gd_number': maCleanGd(gd.text) ?? gd.text.trim(),
                  if (adult) 'gd_still_open': still,
                }),
                child: Text(t.maRenew),
              ),
            ),
          ]),
        ),
      ),
    );
    if (body == null || !mounted) return;
    await _act('renew', body, t.maRenewed);
  }

  Future<void> _addGd() async {
    final t = AppLocalizations.of(context);
    final res = await showAppSheet<Map<String, dynamic>>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => _GdSheet(),
    );
    if (res == null || !mounted) return;
    await _act('gd', res, t.maGdAddedV2);
  }

  Future<void> _tips() async {
    final t = AppLocalizations.of(context);
    Map<String, dynamic> r;
    try {
      r = await _api.maTips(_id);
    } catch (_) {
      if (mounted) _snack(t.maErrGeneric);
      return;
    }
    if (!mounted) return;
    final threads = maRows(r, 'threads');
    await showAppSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          padding: const EdgeInsets.all(Gap.lg),
          children: [
            Text(t.maTipsTitle, style: Theme.of(ctx).textTheme.titleMedium),
            const SizedBox(height: Gap.xs),
            Text(t.maTipsPrivateNote, style: Theme.of(ctx).textTheme.bodySmall),
            const SizedBox(height: Gap.md),
            if (threads.isEmpty) Text(t.maTipsNone),
            for (final th in threads)
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: Icon(th['share_identity'] == true ? Icons.person_rounded : Icons.person_off_rounded),
                title: Text('${th['tipster'] ?? ''}'),
                subtitle: Text(_lastText(th), maxLines: 2, overflow: TextOverflow.ellipsis),
                trailing: const Icon(Icons.chevron_right_rounded),
                onTap: () {
                  Navigator.pop(ctx);
                  _openThread(th['id'] as int);
                },
              ),
          ],
        ),
      ),
    );
    if (mounted) unawaited(_load());
  }

  String _lastText(Map<String, dynamic> th) {
    final m = maRows(th, 'messages');
    return m.isEmpty ? '' : '${m.last['text'] ?? ''}';
  }

  Future<void> _openThread(int id) async {
    await Navigator.of(context)
        .push(MaterialPageRoute(builder: (_) => MissingThreadScreen(threadId: id)));
    if (mounted) unawaited(_load());
  }

  // ------------------------------------------------------------ recipient
  Future<({double lat, double lng})?> _locate() async {
    if (widget.locate != null) return widget.locate!();
    try {
      if (!await Geolocator.isLocationServiceEnabled()) return null;
      // Play: in-app disclosure before Android's prompt (play_disclosure_guard)
      final perm = await askLocationWithReason(context);
      if (perm == LocationPermission.denied || perm == LocationPermission.deniedForever) return null;
      final p = await Geolocator.getCurrentPosition().timeout(const Duration(seconds: 10));
      return (lat: p.latitude, lng: p.longitude);
    } catch (_) {
      return null;
    }
  }

  Future<void> _tip() async {
    final t = AppLocalizations.of(context);
    final text = TextEditingController();
    var share = false;
    var withLoc = false;
    final go = await showAppSheet<bool>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setS) => SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(Gap.lg, Gap.lg, Gap.lg, Gap.md),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Text(t.maTipTitle, style: Theme.of(ctx).textTheme.titleMedium),
            const SizedBox(height: Gap.xs),
            Text(t.maTipPrivate, style: Theme.of(ctx).textTheme.bodySmall),
            const SizedBox(height: Gap.md),
            TextField(
              key: const ValueKey('ma-tip-text'),
              controller: text,
              minLines: 3,
              maxLines: 6,
              maxLength: 600,
              decoration: InputDecoration(
                labelText: t.maTipHint,
                border: const OutlineInputBorder(),
              ),
            ),
            SwitchListTile(
              key: const ValueKey('ma-tip-loc'),
              contentPadding: EdgeInsets.zero,
              value: withLoc,
              onChanged: (v) => setS(() => withLoc = v),
              title: Text(t.maTipAddLocation),
              subtitle: Text(t.maTipAddLocationSub),
            ),
            SwitchListTile(
              key: const ValueKey('ma-tip-share'),
              contentPadding: EdgeInsets.zero,
              value: share,
              onChanged: (v) => setS(() => share = v),
              title: Text(t.maTipShareMe),
              subtitle: Text(share ? t.maTipShareMeOn : t.maTipShareMeOff),
            ),
            const SizedBox(height: Gap.sm),
            Text(t.maTipUrgent999, style: Theme.of(ctx).textTheme.bodySmall),
            const SizedBox(height: Gap.md),
            ConstrainedBox(constraints: const BoxConstraints(minHeight: 52),
              child: FilledButton(
                key: const ValueKey('ma-tip-send'),
                onPressed: () => Navigator.pop(ctx, true),
                child: Text(t.maTipSend),
              ),
            ),
          ]),
        ),
      ),
    );
    if (go != true || !mounted) return;
    if (text.text.trim().length < 2) {
      _snack(t.maTipTooShort);
      return;
    }
    final loc = withLoc ? await _locate() : null;
    if (!mounted) return;
    try {
      final r = await _api.maSendTip(_id, {
        'text': text.text.trim(),
        'share_identity': share,
        if (loc != null) 'lat': maCoarse(loc.lat),
        if (loc != null) 'lng': maCoarse(loc.lng),
      });
      if (!mounted) return;
      if (r['ok'] == true) {
        _snack(t.maTipSent);
        unawaited(_load());
      } else {
        _snack(maReason(t, r['reason'] as String?));
      }
    } catch (_) {
      if (mounted) _snack(t.maErrGeneric);
    }
  }

  Future<void> _report() async {
    final t = AppLocalizations.of(context);
    final reasons = <String, String>{
      'fake': t.maRepFake,
      'not_missing': t.maRepNotMissing,
      'wrong_photo': t.maRepWrongPhoto,
      'harassment': t.maRepHarassment,
      'spam': t.maRepSpam,
      'other': t.maRepOther,
    };
    var pick = 'fake';
    final note = TextEditingController();
    final go = await showAppSheet<bool>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setS) => SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(Gap.lg, Gap.lg, Gap.lg, Gap.md),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Text(t.maReportTitle, style: Theme.of(ctx).textTheme.titleMedium),
            const SizedBox(height: Gap.xs),
            Text(maD(ctx, t.maReportBody(3)), style: Theme.of(ctx).textTheme.bodySmall),
            for (final e in reasons.entries)
              RadioListTile<String>(
                contentPadding: EdgeInsets.zero,
                value: e.key,
                groupValue: pick,
                onChanged: (v) => setS(() => pick = v ?? 'fake'),
                title: Text(e.value),
              ),
            TextField(
              controller: note,
              maxLength: 300,
              decoration: InputDecoration(labelText: t.maReportNote, border: const OutlineInputBorder()),
            ),
            const SizedBox(height: Gap.md),
            ConstrainedBox(constraints: const BoxConstraints(minHeight: 52),
              child: FilledButton(
                key: const ValueKey('ma-report-send'),
                onPressed: () => Navigator.pop(ctx, true),
                child: Text(t.maReportSend),
              ),
            ),
          ]),
        ),
      ),
    );
    if (go != true || !mounted) return;
    await _act('report', {'reason': pick, 'note': note.text.trim()}, t.maReportSent);
  }

  // ------------------------------------------------------------ build
  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(t.maDetailTitle)),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _failed
              ? Center(child: MaError(onRetry: _load))
              : ListView(
                  padding: withNavBarInset(context, const EdgeInsets.fromLTRB(Gap.lg, Gap.md, Gap.lg, Gap.xl)),
                  children: _body(context),
                ),
    );
  }

  List<Widget> _body(BuildContext context) {
    final t = AppLocalizations.of(context);
    final s = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final live = const ['active', 'pending', 'hidden'].contains(_state);
    final name = '${_a['name'] ?? ''}';
    final photo = _a['photo_url'] as String?;
    final gd = (_a['gd'] is Map) ? Map<String, dynamic>.from(_a['gd'] as Map) : null;
    final desc = '${_a['description'] ?? ''}';
    return [
      Container(
        padding: const EdgeInsets.symmetric(horizontal: Gap.md, vertical: Gap.sm),
        decoration: BoxDecoration(
          color: s.surfaceContainerHigh,
          borderRadius: BorderRadius.circular(Radii.md),
        ),
        child: Text(maStateLabel(t, _state, safeSaid: _a['safe_said'] == true),
            style: TextStyle(color: maStateColor(s, _state), fontWeight: FontWeight.w700)),
      ),
      const SizedBox(height: Gap.md),
      if (photo != null && photo.isNotEmpty) ...[
        Center(child: MaPhoto(url: photo, size: 220, label: name)),
        const SizedBox(height: Gap.sm),
        Text(_a['is_child'] == true ? t.maNoScreenshotChild : t.maNoScreenshot,
            style: text.bodySmall, textAlign: TextAlign.center),
        const SizedBox(height: Gap.md),
      ],
      Text(t.maNameAge(name, maD(context, '${_a['age'] ?? ''}')), style: text.headlineSmall),
      if (_a['is_child'] == true)
        Padding(
          padding: const EdgeInsets.only(top: Gap.xs),
          child: Text(t.maChildBadge, style: TextStyle(color: s.error, fontWeight: FontWeight.w600)),
        ),
      const SizedBox(height: Gap.sm),
      _row(context, Icons.schedule_rounded, t.maLastSeen(maWhen(context, _a['last_seen_at'] as String?))),
      _row(context, Icons.place_rounded,
          t.maArea('${_a['area_text'] ?? ''}', '${_a['district_name'] ?? ''}')),
      _row(context, Icons.radar_rounded, maD(context, t.maRadius(_a['radius_km'] as int? ?? 10))),
      if (desc.isNotEmpty) ...[
        const SizedBox(height: Gap.sm),
        Text(desc),
      ],
      if (gd != null) ...[
        const SizedBox(height: Gap.md),
        Card(
          margin: EdgeInsets.zero,
          child: Padding(
            padding: const EdgeInsets.all(Gap.md),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(maD(context, t.maGdLineV2('${gd['thana'] ?? ''}', '${gd['number'] ?? ''}',
                  maWhen(context, gd['date'] as String?).split(',').first))),
              const SizedBox(height: Gap.xs),
              Text(t.maGdUnverifiedV2, key: const ValueKey('ma-gd-unverified'),
                  style: TextStyle(color: s.error, fontWeight: FontWeight.w600)),
            ]),
          ),
        ),
      ] else if (live && _a['is_child'] != true) ...[
        const SizedBox(height: Gap.md),
        Text(t.maGdUnverifiedV2, style: TextStyle(color: s.error)),
      ],
      const SizedBox(height: Gap.lg),
      ..._actions(context, live),
    ];
  }

  Widget _row(BuildContext context, IconData icon, String text) => Padding(
        padding: const EdgeInsets.only(bottom: Gap.xs),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Icon(icon, size: 20, color: Theme.of(context).colorScheme.onSurfaceVariant),
          const SizedBox(width: Gap.sm),
          Expanded(child: Text(text)),
        ]),
      );

  List<Widget> _actions(BuildContext context, bool live) {
    final t = AppLocalizations.of(context);
    final text = Theme.of(context).textTheme;
    final out = <Widget>[];
    Widget big(Widget b) => Padding(
        padding: const EdgeInsets.only(bottom: Gap.sm), child: ConstrainedBox(constraints: const BoxConstraints(minHeight: 52), child: b));
    switch (_role) {
      case 'family':
        if (_state == 'pending') {
          final asked = (_a['cosign_asked'] is Map) ? '${(_a['cosign_asked'] as Map)['name'] ?? ''}' : '';
          out.add(Text(asked.isEmpty ? t.maPendingNoCosignerV2 : t.maPendingCosignerV2(asked)));
          out.add(const SizedBox(height: Gap.sm));
          out.add(big(FilledButton.icon(
              key: const ValueKey('ma-add-gd'),
              onPressed: _busy ? null : _addGd,
              icon: const Icon(Icons.local_police_rounded),
              label: Text(t.maAddGdV2))));
        }
        if (_state == 'active' || _state == 'hidden') {
          out.add(Text(maD(context, t.maReach(_a['pushed'] as int? ?? 0, _a['listed'] as int? ?? 0,
              _a['recipients_family'] as int? ?? 0)), style: text.bodySmall));
          if (_state == 'hidden') out.add(Text(t.maHiddenFamily));
          if (_a['safe_said'] == true) out.add(Text(t.maChildSaidSafeFamily));
          out.add(const SizedBox(height: Gap.sm));
          out.add(big(FilledButton.tonalIcon(
              key: const ValueKey('ma-tips'),
              onPressed: _tips,
              icon: const Icon(Icons.forum_rounded),
              label: Text(maD(context, t.maTipsButton(_a['tips'] as int? ?? 0,
                  _a['tips_unread'] as int? ?? 0))))));
        }
        if (live) {
          out.add(big(FilledButton.icon(
              key: const ValueKey('ma-found'),
              style: FilledButton.styleFrom(backgroundColor: Brand.successFill, foregroundColor: Colors.white),
              onPressed: _busy ? null : _found,
              icon: const Icon(Icons.check_circle_rounded),
              label: Text(t.maFound))));
          if (_a['can_renew'] == true) {
            out.add(big(OutlinedButton.icon(
                key: const ValueKey('ma-renew'),
                onPressed: _busy ? null : _renew,
                icon: const Icon(Icons.update_rounded),
                label: Text(t.maRenew))));
          } else if (_state == 'active') {
            out.add(Text(maD(context, t.maExpires(maWhen(context, _a['expires_at'] as String?))),
                style: text.bodySmall));
            out.add(const SizedBox(height: Gap.sm));
          }
          out.add(big(OutlinedButton.icon(
              key: const ValueKey('ma-close'),
              onPressed: _busy ? null : _close,
              icon: const Icon(Icons.close_rounded),
              label: Text(t.maClose))));
        }
        if (_state == 'found' && _a['share_agreed'] == true) {
          out.add(big(FilledButton.tonalIcon(
              key: const ValueKey('ma-share-thanks'),
              onPressed: _openShare,
              icon: const Icon(Icons.favorite_rounded),
              label: Text(t.maShareThanks))));
        }
        if (_state == 'safe') out.add(Text(t.maSafeFamilyLine));
        out.add(const Ma999Button());
        break;
      case 'subject':
        if (live) {
          out.add(Text(_a['is_child'] == true ? t.maAboutMeBodyChild : t.maAboutMeBody));
          out.add(const SizedBox(height: Gap.sm));
          out.add(big(FilledButton.icon(
              key: const ValueKey('ma-safe'),
              style: FilledButton.styleFrom(backgroundColor: Brand.successFill, foregroundColor: Colors.white),
              onPressed: _busy ? null : () => _act('safe', const {},
                  _a['is_child'] == true ? t.maSafeSentChild : t.maSafeSent),
              icon: const Icon(Icons.verified_user_rounded),
              label: Text(t.maIamSafe))));
        }
        break;
      case 'cosigner':
        if (_state == 'pending') {
          out.add(big(FilledButton(
              key: const ValueKey('ma-cosign-yes'),
              onPressed: _busy ? null : () => _act('cosign', {'confirm': true}, t.maCosignDone),
              child: Text(t.maCosignYes))));
          out.add(big(OutlinedButton(
              onPressed: _busy ? null : () => _act('cosign', {'confirm': false}, t.maCosignDeclined),
              child: Text(t.maCosignNo))));
        }
        break;
      default: // recipient
        if (_state == 'active') {
          out.add(big(FilledButton.icon(
              key: const ValueKey('ma-tip'),
              onPressed: _busy ? null : _tip,
              icon: const Icon(Icons.lock_rounded),
              label: Text(t.maTipCta))));
          if (_a['my_tip_thread'] is int) {
            out.add(big(OutlinedButton.icon(
                onPressed: () => _openThread(_a['my_tip_thread'] as int),
                icon: const Icon(Icons.forum_rounded),
                label: Text(t.maMyTips))));
          }
          out.add(const Ma999Button());
          out.add(const SizedBox(height: Gap.sm));
          out.add(Align(
            alignment: Alignment.centerLeft,
            child: _a['reported'] == true
                ? Text(t.maReported, style: text.bodySmall)
                : TextButton.icon(
                    key: const ValueKey('ma-report'),
                    onPressed: _busy ? null : _report,
                    icon: const Icon(Icons.flag_rounded),
                    label: Text(t.maReport)),
          ));
        } else {
          out.add(Text(t.maEndedRecipient));
        }
    }
    return out;
  }
}

class _GdSheet extends StatefulWidget {
  @override
  State<_GdSheet> createState() => _GdSheetState();
}

class _GdSheetState extends State<_GdSheet> {
  final _num = TextEditingController();
  final _thana = TextEditingController();
  DateTime _date = DateTime.now();
  String? _err;

  @override
  void dispose() {
    _num.dispose();
    _thana.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final loc = MaterialLocalizations.of(context);
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(Gap.lg, Gap.lg, Gap.lg, Gap.md),
      child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text(t.maGdTitleV2, style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: Gap.xs),
        Text(t.maGdHelpV2, style: Theme.of(context).textTheme.bodySmall),
        const SizedBox(height: Gap.md),
        TextField(
          controller: _num,
          decoration: InputDecoration(labelText: t.maGdNumberV2, errorText: _err, border: const OutlineInputBorder()),
        ),
        const SizedBox(height: Gap.sm),
        TextField(
          controller: _thana,
          decoration: InputDecoration(labelText: t.maGdThana, border: const OutlineInputBorder()),
        ),
        const SizedBox(height: Gap.sm),
        OutlinedButton.icon(
          onPressed: () async {
            final d = await showDatePicker(
                context: context,
                initialDate: _date,
                firstDate: DateTime.now().subtract(const Duration(days: 60)),
                lastDate: DateTime.now());
            if (d != null) setState(() => _date = d);
          },
          icon: const Icon(Icons.event_rounded),
          label: Text(maD(context, t.maGdDateV2(loc.formatMediumDate(_date)))),
        ),
        const SizedBox(height: Gap.md),
        ConstrainedBox(constraints: const BoxConstraints(minHeight: 52),
          child: FilledButton(
            onPressed: () {
              final n = maCleanGd(_num.text);
              if (n == null || _thana.text.trim().length < 2) {
                setState(() => _err = t.maErrGdV2);
                return;
              }
              Navigator.pop(context, {
                'gd_number': n,
                'gd_thana': _thana.text.trim(),
                'gd_date': _date.toIso8601String().substring(0, 10),
              });
            },
            child: Text(t.maGdSaveV2),
          ),
        ),
      ]),
    );
  }
}
