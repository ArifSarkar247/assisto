import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:geolocator/geolocator.dart';
import 'package:provider/provider.dart';

import '../family_alerts_api.dart' show newSosClientId;
import '../l10n/app_localizations.dart';
import '../nearby/emergency_numbers.dart';
import '../nearby/phone_country.dart';
import '../services/action_feedback.dart';
import '../state.dart';
import '../ds/ds.dart';
import '../theme.dart';
import '../widgets/app_sheet.dart' show withNavBarInset;
import '../widgets/notif_models.dart' show notifLocalizeDigits;
import '../widgets/permission_reason.dart';
import '../widgets/sos_ladder_card.dart';
import '../widgets/sos_a11y.dart';
import 'sos_api.dart';
import 'sos_recorder.dart';
import 'sos_retry.dart'; // gap-sos
import 'sos_sms.dart';
import 'sos_widgets.dart';
import 'package:assisto/safety/ad_block_context.dart' show AdBlockedState;

/// fcsos — Family Care v3 SCREEN 2: the SOS SENDER.
///
///   5-second countdown  -> big "Cancel (pressed by mistake)" + "Send now"
///   sending             -> server push to EVERY family phone (all families)
///   sent                -> who got it / saw it (ladder), who is going,
///                          live location every 15 s while this screen is
///                          open, 30 s sound clip (clearly shown, Stop),
///                          "Sent by mistake — tell everyone", "I am safe"
///   no internet         -> SMS from MY SIM to the 2 chosen people (the SMS
///                          app opens ready; the user taps Send) + keeps
///                          retrying the server with the SAME press id
///
/// Always free, never an ad. Opened from the Family screen's red button
/// (FcSlots.openSosSender), the elder Danger button and anywhere else.
class SosSenderScreen extends StatefulWidget {
  const SosSenderScreen({
    super.key,
    this.source = 'family_v3',
    this.familyId,
    this.api,
    this.locate,
    this.recorder,
    this.countdownSeconds = 5,
    this.smsContacts,
    this.openUri,
    this.retryEvery = const Duration(seconds: 15),
    this.pollEvery = const Duration(seconds: 5),
    this.country,
    this.debugPhase,
    this.debugRecipients = 0,
    this.debugRecState,
    this.startSent = false,
    this.startRecipients = 0,
  });

  /// gap-sos: the SOS already went out from another surface (the Emergency
  /// hub's hold button) — open straight on the SENT page (who is going, live
  /// location, 30 s sound, "Sent by mistake"); nothing is sent again.
  final bool startSent;
  final int startRecipients;

  final String source;
  final int? familyId;
  final FcSosApi? api;
  final Future<(double, double)?> Function()? locate;
  final SosRecorder? recorder;
  final int countdownSeconds;

  /// Test seam: the 2 SMS people (default: SosSmsStore on this phone).
  final List<SosSmsContact>? smsContacts;

  /// Test seam: open sms:/tel: (default openForUser).
  final Future<void> Function(Uri uri)? openUri;
  final Duration retryEvery;
  final Duration pollEvery;

  /// Test seam: ISO country for the emergency number (default: SIM/network).
  final String? country;

  /// Gallery / tests: start in this phase (no countdown, no send, no timers).
  final SosPhase? debugPhase;
  final int debugRecipients;
  final String? debugRecState;

  static const route = '/sos_send';

  static Future<void> open(BuildContext context, {String source = 'family_v3', int? familyId}) =>
      Navigator.of(context).push(MaterialPageRoute<void>(
          settings: const RouteSettings(name: route),
          fullscreenDialog: true,
          builder: (_) => SosSenderScreen(source: source, familyId: familyId)));

  @override
  State<SosSenderScreen> createState() => _SosSenderScreenState();
}

enum SosPhase { countdown, sending, sent, offline }

class _SosSenderScreenState extends State<SosSenderScreen>
    with AdBlockedState<SosSenderScreen> {
  SosPhase _phase = SosPhase.countdown;
  // a11ysweep: TalkBack users get at least 10 s to reach Cancel
  late final bool _sr = sosScreenReaderOn();
  late int _left = sosCountdownSeconds(widget.countdownSeconds, screenReader: _sr);
  Timer? _tick, _poll, _live, _recTick;
  final String _clientId = newSosClientId();
  (double, double)? _pos;
  Future<(double, double)?>? _posF;
  int _recipients = 0;
  List<Map<String, dynamic>> _going = const [];
  String _state = 'active';
  List<SosSmsContact> _sms = const [];
  String? _cc;
  bool _ending = false;

  // 30 s sound
  late final SosRecorder _rec = widget.recorder ?? sosRecorderFactory();
  String _recState = 'idle'; // idle | asking | recording | uploading | sent | failed | denied
  int _recSec = 0;

  FcSosApi get _api => widget.api ?? HttpFcSosApi(context.read<AppState>().api);

  @override
  void initState() {
    super.initState();
    final dp = widget.debugPhase;
    if (dp != null) {
      _phase = dp;
      _recipients = widget.debugRecipients;
      _recState = widget.debugRecState ?? 'idle';
      _recSec = 12;
      unawaited(_loadSms());
      unawaited(_loadCountry());
      if (dp == SosPhase.sent) {
        WidgetsBinding.instance.addPostFrameCallback((_) => _refreshStatus());
      }
      return;
    }
    _posF = _locate();
    unawaited(_posF!.then((p) {
      if (p != null) _pos = p;
    }));
    unawaited(_loadSms());
    unawaited(_loadCountry());
    if (widget.startSent) {
      _recipients = widget.startRecipients;
      WidgetsBinding.instance.addPostFrameCallback((_) => _afterSent());
    } else if (_left <= 0) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _send());
    } else {
      HapticFeedback.heavyImpact();
      if (_sr) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted || _phase != SosPhase.countdown) return;
          sosAnnounce(context, AppLocalizations.of(context).a11ySosTalkBackIntro(_d('$_left')));
        });
      }
      _tick = Timer.periodic(const Duration(seconds: 1), (_) {
        if (!mounted) return;
        setState(() => _left--);
        HapticFeedback.heavyImpact();
        if (_left <= 0) _send();
      });
    }
  }

  Future<void> _loadSms() async {
    final l = widget.smsContacts ?? await SosSmsStore.load();
    if (mounted) setState(() => _sms = l);
  }

  Future<void> _loadCountry() async {
    if (widget.country != null) {
      _cc = widget.country;
      return;
    }
    final p = await PhoneCountry.read();
    if (mounted) setState(() => _cc = pickEmergencyCountry(network: p.network, sim: p.sim));
  }

  /// [ask]: may show the Android location prompt (the first read only —
  /// gap-sos: the 15 s live updates never re-ask a person who said no).
  Future<(double, double)?> _locate({bool ask = true}) async {
    if (widget.locate != null) return widget.locate!();
    try {
      if (!await Geolocator.isLocationServiceEnabled()) return null;
      var perm = await Geolocator.checkPermission();
      if (perm == LocationPermission.denied && ask) {
        // bounded: an unanswered prompt never holds the SOS
        perm = await Geolocator.requestPermission()
            .timeout(const Duration(seconds: 10), onTimeout: () => LocationPermission.denied);
      }
      if (perm == LocationPermission.denied || perm == LocationPermission.deniedForever) {
        return null;
      }
      final last = await Geolocator.getLastKnownPosition();
      final p = await Geolocator.getCurrentPosition()
          .timeout(const Duration(seconds: 8), onTimeout: () async {
        if (last != null) return last;
        throw TimeoutException('gps');
      });
      return (p.latitude, p.longitude);
    } catch (_) {
      return null;
    }
  }

  void _cancelCountdown() {
    _tick?.cancel();
    final t = AppLocalizations.of(context);
    final m = ScaffoldMessenger.maybeOf(context);
    Navigator.of(context).maybePop();
    m?.showSnackBar(SnackBar(content: Text(t.fcsCancelledNothingSent)));
  }

  Future<void> _send() async {
    _tick?.cancel();
    if (_phase == SosPhase.sending || _phase == SosPhase.sent) return;
    setState(() => _phase = SosPhase.sending);
    // never hold the SOS for the GPS: what we have now (≤ 1.5 s more), the
    // live updates fill in the rest
    if (_pos == null && _posF != null) {
      try {
        _pos = await _posF!.timeout(const Duration(milliseconds: 1500));
      } catch (_) {
        // best-effort: no GPS yet — the SOS goes now, live updates add it
      }
    }
    final ok = await _trySend();
    if (!mounted) return;
    if (!ok) {
      setState(() => _phase = SosPhase.offline);
      // gap-sos (P1): the app-wide retry owns the unsent press, so Back or
      // leaving this screen never silently drops the SOS; only "Stop trying"
      // does. Same press id -> the family is rung once.
      final api = _api;
      final source = widget.source;
      final id = _clientId;
      SosRetry.start(
        clientId: id,
        every: widget.retryEvery,
        send: () => api.send(lat: _pos?.$1, lng: _pos?.$2, source: source, clientId: id),
        onSent: (r) {
          if (!mounted) return;
          _recipients = (r['recipients'] as num?)?.toInt() ?? 0;
          _afterSent();
        },
      );
      return;
    }
    _afterSent();
  }

  Future<bool> _trySend() async {
    try {
      final r = await _api
          .send(lat: _pos?.$1, lng: _pos?.$2, source: widget.source, clientId: _clientId)
          .timeout(const Duration(seconds: 10));
      _recipients = (r['recipients'] as num?)?.toInt() ?? 0;
      return true;
    } catch (_) {
      return false;
    }
  }

  void _afterSent() {
    if (!mounted) return;
    HapticFeedback.vibrate();
    setState(() => _phase = SosPhase.sent);
    unawaited(_refreshStatus());
    _poll = Timer.periodic(widget.pollEvery, (_) => _refreshStatus());
    // live location while this screen is open (no background tracking)
    unawaited(_pushLocation());
    _live = Timer.periodic(const Duration(seconds: 15), (_) => _pushLocation());
    unawaited(_autoRecord());
  }

  Future<void> _refreshStatus() async {
    try {
      final s = await _api.status();
      if (!mounted) return;
      setState(() {
        _state = '${s['state'] ?? 'active'}';
        _going = ((s['going'] as List?) ?? const [])
            .whereType<Map>()
            .map((e) => e.cast<String, dynamic>())
            .toList();
      });
      if (_state != 'active') {
        _poll?.cancel();
        _live?.cancel();
      }
    } catch (_) {
      // keep the last state; next tick tries again
    }
  }

  Future<void> _pushLocation() async {
    if (_state != 'active') return;
    final p = (_pos != null && _live == null) ? _pos : await _locate(ask: false);
    if (p == null) return;
    _pos = p;
    try {
      await _api.location(p.$1, p.$2);
    } catch (_) {
      // best-effort: the next 15 s tick sends the newest position
    }
  }

  // ---------------------------------------------------------------- sound
  Future<void> _autoRecord() async {
    // only when the microphone is ALREADY allowed: no prompt in the middle
    // of an emergency; otherwise a clear button asks first
    if (await _rec.granted()) {
      await _startRec();
    } else if (mounted) {
      setState(() => _recState = 'idle');
    }
  }

  Future<void> _askAndRecord() async {
    setState(() => _recState = 'asking');
    // the user tapped "Record 30 s for your family": say why, then ask
    final go = await showPermissionReason(context, PermKind.mic);
    if (!mounted) return;
    if (!go) {
      setState(() => _recState = 'idle');
      return;
    }
    if (await _rec.request()) {
      await _startRec();
    } else if (mounted) {
      setState(() => _recState = 'denied');
    }
  }

  Future<void> _startRec() async {
    if (!await _rec.start()) {
      if (mounted) setState(() => _recState = 'failed');
      return;
    }
    if (!mounted) return;
    setState(() {
      _recState = 'recording';
      _recSec = 0;
    });
    _recTick = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      setState(() => _recSec++);
      if (_recSec >= 30) _stopRec();
    });
  }

  Future<void> _stopRec() async {
    _recTick?.cancel();
    if (_recState != 'recording') return;
    final sec = _recSec.clamp(1, 30);
    setState(() => _recState = 'uploading');
    final bytes = await _rec.stop();
    var ok = false;
    if (bytes != null) {
      try {
        ok = await _api.uploadAudio(bytes, sec);
      } catch (_) {
        ok = false;
      }
    }
    if (mounted) setState(() => _recState = ok ? 'sent' : 'failed');
  }

  // ------------------------------------------------------------ endings
  Future<void> _mistake() async {
    final t = AppLocalizations.of(context);
    final yes = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(t.fcsMistakeConfirmTitle),
        content: Text(t.fcsMistakeConfirmBody),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(t.fcsKeepSos)),
          FilledButton(
              key: const ValueKey('fcs-mistake-yes'),
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(t.fcsTellEveryone)),
        ],
      ),
    );
    if (yes != true || !mounted) return;
    await _end(mistake: true);
  }

  Future<void> _end({required bool mistake}) async {
    final t = AppLocalizations.of(context);
    final m = ScaffoldMessenger.maybeOf(context);
    setState(() => _ending = true);
    if (_recState == 'recording') await _stopRec();
    try {
      await _api.resolve(mistake: mistake).timeout(const Duration(seconds: 12));
      _poll?.cancel();
      _live?.cancel();
      if (!mounted) return;
      m?.showSnackBar(SnackBar(content: Text(mistake ? t.fcsMistakeSent : t.fa100SafeSent)));
      Navigator.of(context).maybePop();
    } catch (_) {
      m?.showSnackBar(SnackBar(content: Text(t.fa100SafeFailed)));
    } finally {
      if (mounted) setState(() => _ending = false);
    }
  }

  Future<void> _open(Uri u, String where) async {
    if (widget.openUri != null) return widget.openUri!(u);
    await openForUser(context, u, where: where);
  }

  Future<void> _sendSms({SosSmsContact? only}) async {
    final t = AppLocalizations.of(context);
    final body = sosSmsBody(t.sosShareText, t.emergencySosAlertText, _pos);
    final to = only == null ? [for (final c in _sms) c.phone] : [only.phone];
    await _open(sosSmsUri(to, body), 'fcsos.sms');
  }

  Future<void> _pickSms() async {
    final l = await showSosSmsPicker(context, current: _sms);
    if (l != null && mounted) setState(() => _sms = l);
  }

  @override
  void dispose() {
    _tick?.cancel();
    // gap-sos: an unsent SOS keeps trying after this screen closes (SosRetry)
    _poll?.cancel();
    _live?.cancel();
    _recTick?.cancel();
    if (_recState == 'recording') unawaited(_rec.stop());
    super.dispose();
  }

  String _d(String s) => notifLocalizeDigits(context, s);

  @override
  Widget build(BuildContext context) {
    return PopScope(
      // the countdown's back = Cancel (nothing sent)
      canPop: _phase != SosPhase.sending,
      onPopInvokedWithResult: (did, _) {
        if (did) _tick?.cancel();
      },
      child: switch (_phase) {
        SosPhase.countdown || SosPhase.sending => _countdown(context),
        SosPhase.sent => _sent(context),
        SosPhase.offline => _offline(context),
      },
    );
  }

  Widget _countdown(BuildContext context) {
    final t = AppLocalizations.of(context);
    final sending = _phase == SosPhase.sending;
    return Scaffold(
      key: const ValueKey('fcs-countdown'),
      backgroundColor: kSosRed,
      body: SafeArea(
        child: LayoutBuilder(
          builder: (ctx, c) => SingleChildScrollView(
            padding: withNavBarInset(context, const EdgeInsets.all(Gap.lg)),
            child: ConstrainedBox(
              constraints: BoxConstraints(minHeight: c.maxHeight - Gap.lg * 2),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Icon(Icons.sos_rounded, color: Colors.white, size: 56),
                  const SizedBox(height: Gap.md),
                  Semantics(
                    liveRegion: true,
                    child: Text(
                      sending ? t.fcsSendingNow : t.fcsCountdownTitle,
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                          color: Colors.white, fontSize: 24, fontWeight: FontWeight.w800),
                    ),
                  ),
                  const SizedBox(height: Gap.md),
                  if (sending)
                    const Center(
                        child: SizedBox(
                            width: 72,
                            height: 72,
                            child: CircularProgressIndicator(color: Colors.white, strokeWidth: 6)))
                  else
                    SosCountdownSemantics(
                      label: t.a11ySosSecondsLeft(_d('$_left')),
                      child: Text(_d('$_left'),
                          key: const ValueKey('fcs-countdown-number'),
                          textAlign: TextAlign.center,
                          style: Theme.of(context).textTheme.displayLarge?.copyWith(
                              color: Colors.white, fontSize: 96, fontWeight: FontWeight.w900, letterSpacing: -2)),
                    ),
                  const SizedBox(height: Gap.sm),
                  Text(t.fcsCountdownBody,
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                          color: Colors.white, fontSize: 16, height: 1.35)),
                  const SizedBox(height: Gap.xl),
                  // a11ysweep: with TalkBack, Cancel comes FIRST (reading
                  // order and on screen) so a mis-tap is undone in one swipe
                  ..._sosButtons(_sr, [
                    ConstrainedBox(
                      constraints: const BoxConstraints(minHeight: 64),
                      child: FilledButton.icon(
                        key: const ValueKey('fcs-send-now'),
                        style: FilledButton.styleFrom(
                            backgroundColor: Colors.white,
                            foregroundColor: kSosRed,
                            shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(DsRadius.button))),
                        onPressed: sending ? null : _send,
                        icon: const Icon(Icons.send_rounded),
                        // style on the Text (merges with the theme font);
                        // ButtonStyle.textStyle would drop the app font
                        label: Text(t.fcsSendNow,
                            style: Theme.of(context).textTheme.titleLarge?.copyWith(
                                fontSize: 20, fontWeight: FontWeight.w800, color: kSosRed)),
                      ),
                    ),
                    ConstrainedBox(
                      constraints: const BoxConstraints(minHeight: 64),
                      child: OutlinedButton.icon(
                        key: const ValueKey('fcs-cancel'),
                        style: OutlinedButton.styleFrom(
                            foregroundColor: Colors.white,
                            side: const BorderSide(color: Colors.white, width: 2),
                            shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(DsRadius.button))),
                        onPressed: sending ? null : _cancelCountdown,
                        icon: const Icon(Icons.close_rounded),
                        label: Text(t.fcsCancelMistake,
                            textAlign: TextAlign.center,
                            style: Theme.of(context).textTheme.titleMedium?.copyWith(
                                fontSize: 18, fontWeight: FontWeight.w700, color: Colors.white)),
                      ),
                    ),
                  ]),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// [send, cancel] in the order the user should meet them.
  static List<Widget> _sosButtons(bool screenReader, List<Widget> sendCancel) {
    final first = screenReader ? sendCancel[1] : sendCancel[0];
    final second = screenReader ? sendCancel[0] : sendCancel[1];
    return [first, const SizedBox(height: Gap.md), second];
  }

  Widget _sent(BuildContext context) {
    final t = AppLocalizations.of(context);
    final ds = DsTokens.of(context);
    final em = emergencyFor(_cc);
    return Scaffold(
      key: const ValueKey('fcs-sent'),
      appBar: AppBar(
        title: Text(t.fcsSentTitle),
        backgroundColor: kSosRed,
        foregroundColor: Colors.white,
        titleTextStyle: Theme.of(context).appBarTheme.titleTextStyle?.copyWith(color: Colors.white), // theme title colour would override foregroundColor (a11y contrast)
      ),
      body: ListView(
        padding: withNavBarInset(context, const EdgeInsets.all(Gap.md)),
        children: [
          SosBanner(
            icon: Icons.notifications_active_rounded,
            color: Brand.danger,
            title: _recipients > 0
                ? t.fcsSentToN(_d('$_recipients'))
                : t.fcsSentToNobody,
            body: _recipients > 0 ? t.fcsSentBody : t.fcsSentNobodyBody,
          ),
          if (_recipients == 0) ...[
            const SizedBox(height: Gap.sm),
            _smsButton(t),
          ],
          const SizedBox(height: Gap.md),
          _soundCard(t),
          const SizedBox(height: Gap.md),
          SosGoingList(going: _going, empty: t.fcsGoingWaiting, title: t.fcsGoingTitle),
          const SizedBox(height: Gap.md),
          SosLadderCard(
            contacts: [for (final c in _sms) {'name': c.name, 'phone': c.phone}],
            smsBody: sosSmsBody(t.sosShareText, t.emergencySosAlertText, _pos),
            load: _api.ladder,
            resolve: () => _api.resolve(mistake: false),
          ),
          const SizedBox(height: Gap.md),
          SosBigButton(
            key: const ValueKey('fcs-call-emergency'),
            icon: Icons.local_police_rounded,
            label: _d(t.fcsCallEmergency(em.primary.number)),
            color: ds.card,
            fg: ds.text,
            onTap: () => _open(Uri.parse('tel:${em.primary.dial}'), 'fcsos.emergency'),
          ),
          const SizedBox(height: Gap.sm),
          SosBigButton(
            key: const ValueKey('fcs-mistake'),
            icon: Icons.undo_rounded,
            label: t.fcsSentByMistake,
            color: ds.card,
            fg: ds.text,
            onTap: _ending || _state != 'active' ? null : _mistake,
          ),
          const SizedBox(height: Gap.sm),
          Text(t.fcsLiveNote,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(fontSize: 13, color: ds.muted)),
        ],
      ),
    );
  }

  Widget _soundCard(AppLocalizations t) {
    final ds = DsTokens.of(context);
    switch (_recState) {
      case 'recording':
        return SosBanner(
          key: const ValueKey('fcs-recording'),
          icon: Icons.mic_rounded,
          color: Brand.danger,
          title: t.fcsRecording(_d('${30 - _recSec}')),
          body: t.fcsRecordingBody,
          action: TextButton(
              key: const ValueKey('fcs-rec-stop'),
              onPressed: _stopRec,
              child: Text(t.fcsStop)),
        );
      case 'uploading':
        return SosBanner(
            icon: Icons.cloud_upload_rounded, color: ds.primaryInk, title: t.fcsSoundSending);
      case 'sent':
        return SosBanner(
            key: const ValueKey('fcs-sound-sent'),
            icon: Icons.check_circle_rounded,
            color: Brand.success,
            title: t.fcsSoundSent);
      case 'failed':
        return SosBanner(
            icon: Icons.mic_off_rounded, color: ds.muted, title: t.fcsSoundFailed);
      case 'denied':
        return SosBanner(
            icon: Icons.mic_off_rounded, color: ds.muted, title: t.fcsSoundDenied);
      default:
        return SosBigButton(
          key: const ValueKey('fcs-rec-start'),
          icon: Icons.mic_rounded,
          label: t.fcsRecordButton,
          color: ds.card,
          fg: ds.text,
          onTap: _recState == 'asking' ? null : _askAndRecord,
        );
    }
  }

  Widget _smsButton(AppLocalizations t) {
    if (_sms.isEmpty) {
      return SosBigButton(
        key: const ValueKey('fcs-sms-pick'),
        icon: Icons.person_add_alt_1_rounded,
        label: t.fcsSmsPickTwo,
        color: kSosRed,
        fg: Colors.white,
        onTap: _pickSms,
      );
    }
    String nameOf(SosSmsContact c) => c.name.isEmpty ? _d(c.phone) : c.name;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      SosBigButton(
        key: const ValueKey('fcs-sms-send'),
        icon: Icons.sms_rounded,
        label: t.fcsSmsSendTo(_sms.map(nameOf).join(', ')),
        color: kSosRed,
        fg: Colors.white,
        onTap: _sendSms,
      ),
      // some SMS apps take only one number: one message per person
      if (_sms.length > 1)
        Wrap(spacing: Gap.sm, children: [
          for (final c in _sms)
            TextButton.icon(
              key: ValueKey('fcs-sms-one-${c.phone}'),
              style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
              onPressed: () => _sendSms(only: c),
              icon: const Icon(Icons.sms_outlined),
              label: Text(t.fcsSmsOne(nameOf(c))),
            ),
        ]),
    ]);
  }

  Widget _offline(BuildContext context) {
    final t = AppLocalizations.of(context);
    final ds = DsTokens.of(context);
    final em = emergencyFor(_cc);
    return Scaffold(
      key: const ValueKey('fcs-offline'),
      appBar: AppBar(
          title: Text(t.fcsOfflineTitle),
          backgroundColor: kSosRed,
          foregroundColor: Colors.white,
          titleTextStyle: Theme.of(context).appBarTheme.titleTextStyle?.copyWith(color: Colors.white)), // theme title colour would override foregroundColor (a11y contrast)
      body: ListView(
        padding: withNavBarInset(context, const EdgeInsets.all(Gap.md)),
        children: [
          SosBanner(
            icon: Icons.wifi_off_rounded,
            color: Brand.danger,
            title: t.fcsOfflineHead,
            body: t.fcsOfflineBody,
          ),
          const SizedBox(height: Gap.md),
          _smsButton(t),
          if (_sms.isNotEmpty)
            Align(
              alignment: AlignmentDirectional.centerStart,
              child: TextButton(onPressed: _pickSms, child: Text(t.fcsSmsChange)),
            ),
          Padding(
            padding: const EdgeInsets.symmetric(vertical: Gap.sm),
            child: Text(t.fcsSmsHow,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(fontSize: 13, color: ds.muted)),
          ),
          SosBigButton(
            key: const ValueKey('fcs-call-emergency'),
            icon: Icons.local_police_rounded,
            label: _d(t.fcsCallEmergency(em.primary.number)),
            color: ds.card,
            fg: ds.text,
            onTap: () => _open(Uri.parse('tel:${em.primary.dial}'), 'fcsos.emergency'),
          ),
          const SizedBox(height: Gap.md),
          Row(children: [
            const SizedBox(
                width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)),
            const SizedBox(width: Gap.sm),
            Expanded(child: Text(t.fcsStillTrying)),
          ]),
          const SizedBox(height: Gap.md),
          TextButton(
            key: const ValueKey('fcs-offline-cancel'),
            onPressed: () {
              SosRetry.stop();
              Navigator.of(context).maybePop();
            },
            child: Text(t.fcsStopTrying),
          ),
        ],
      ),
    );
  }
}
