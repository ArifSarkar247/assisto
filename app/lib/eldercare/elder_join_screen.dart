import 'dart:async';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../api.dart' show ApiException;
import '../l10n/app_localizations.dart';
import '../screens/battery_guidance_screen.dart';
import '../theme.dart';
import '../widgets/app_sheet.dart';
import '../widgets/elderly_mode.dart';
import '../widgets/local_counter.dart';
import 'elder_common.dart';
import 'silent_watch_client.dart';

/// fcelder — ELDER SETUP BY A CHILD, the ELDER's phone.
///
/// Opened by the QR (App Link https://lifeassisto.com/e/<CODE>, scanned with
/// the phone's own camera) or by typing the code. Shows what the child wants
/// to turn on, READS IT ALOUD in Bangla, and asks ONE big YES. Nothing is
/// configured before that YES. Then: Easy home on, Care Call accepted, Silent
/// Watch armed with this phone's own token, and the battery guide (Xiaomi,
/// Realme, Oppo, Vivo, Samsung, Tecno, Infinix …) so alarms survive the
/// phone's battery saver.
class ElderJoinScreen extends StatefulWidget {
  const ElderJoinScreen({super.key, this.initialCode, this.debugPreview});

  final String? initialCode;

  /// Tests / gallery: the consent step without a server.
  final Map<String, dynamic>? debugPreview;

  static const pendingKey = 'fce_pending_code';

  /// "/e/<CODE>" or a full https://lifeassisto.com/e/<CODE> -> CODE, else null.
  static String? codeFrom(String? raw) {
    if (raw == null) return null;
    final s = raw.trim();
    final i = s.indexOf('/e/');
    if (i == -1) return null;
    if (s.contains('://')) {
      final u = Uri.tryParse(s);
      if (u == null || !u.host.endsWith('lifeassisto.com')) return null;
    }
    final c = s.substring(i + 3).split('?').first.split('#').first.replaceAll('/', '').toUpperCase();
    return RegExp(r'^[A-HJKMNP-Z2-9]{8}$').hasMatch(c) ? c : null;
  }

  /// MaterialApp.onGenerateRoute hook (warm App Link "/e/<CODE>").
  static Route<dynamic>? route(RouteSettings s) {
    final c = (s.name ?? '').startsWith('/e/') ? codeFrom(s.name) : null;
    if (c == null) return null;
    return MaterialPageRoute<void>(settings: s, builder: (_) => ElderJoinScreen(initialCode: c));
  }

  static bool _coldDone = false;

  /// Cold start: the link arrives as the full URL in defaultRouteName.
  /// Signed out: the code waits (prefs) until the elder has signed in.
  static Future<void> maybeOpenColdStart(BuildContext context, String defaultRouteName,
      {required bool loggedIn}) async {
    if (_coldDone) return;
    _coldDone = true;
    final c = codeFrom(defaultRouteName);
    if (c == null) return;
    if (!loggedIn) {
      try {
        (await SharedPreferences.getInstance()).setString(pendingKey, c);
      } catch (_) {
      // best-effort: guarded so a failure never blocks the elder's tap
    }
      return;
    }
    try {
      if (context.mounted) {
        await Navigator.of(context)
            .push(MaterialPageRoute<void>(builder: (_) => ElderJoinScreen(initialCode: c)));
      }
    } catch (_) {
      // best-effort: guarded so a failure never blocks the elder's tap
    }
  }

  /// After sign-in / on resume: a code that arrived while signed out.
  static Future<void> maybeOpenPending(BuildContext context) async {
    try {
      final p = await SharedPreferences.getInstance();
      final c = p.getString(pendingKey);
      if (c == null) return;
      await p.remove(pendingKey);
      if (context.mounted) {
        await Navigator.of(context)
            .push(MaterialPageRoute<void>(builder: (_) => ElderJoinScreen(initialCode: c)));
      }
    } catch (_) {
      // best-effort: guarded so a failure never blocks the elder's tap
    }
  }

  @override
  State<ElderJoinScreen> createState() => _ElderJoinScreenState();
}

enum _Step { code, consent, battery, done }

class _ElderJoinScreenState extends State<ElderJoinScreen> {
  final _codeCtl = TextEditingController();
  _Step _step = _Step.code;
  Map<String, dynamic>? _preview;
  String? _error;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    if (widget.debugPreview != null) {
      _preview = widget.debugPreview;
      _step = _Step.consent;
    } else if (widget.initialCode != null) {
      _codeCtl.text = widget.initialCode!;
      WidgetsBinding.instance.addPostFrameCallback((_) => _check());
    }
  }

  @override
  void dispose() {
    _codeCtl.dispose();
    super.dispose();
  }

  String get _code => String.fromCharCodes(_codeCtl.text.toUpperCase().codeUnits.map(
          (c) => (c >= 0x09E6 && c <= 0x09EF) ? 0x30 + (c - 0x09E6) : c))
      .replaceAll(RegExp(r'[^A-Z0-9]'), '');

  Future<void> _check() async {
    final api = ElderHooks.api(context);
    final t = AppLocalizations.of(context);
    if (api == null) return;
    if (_code.length != 8) {
      setState(() => _error = t.fceJoinCodeInvalid);
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final r = await api.previewSetup(_code);
      if (!mounted) return;
      setState(() {
        _preview = r;
        _step = _Step.consent;
      });
      WidgetsBinding.instance.addPostFrameCallback((_) => _readAloud());
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } catch (_) {
      if (mounted) setState(() => _error = t.fceOffline);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  String _consentText(AppLocalizations t) {
    final p = _preview ?? const {};
    final plan = (p['plan'] as Map?) ?? const {};
    final child = '${p['child_name'] ?? ''}';
    final bn = ElderHooks.lang(context) == 'bn';
    final parts = <String>[t.fceJoinConsentIntro(child)];
    if (plan['easy_home'] == true) parts.add(t.fceJoinConsentEasy);
    if (plan['carecall'] == true) parts.add(t.fceJoinConsentCare(child));
    if (plan['silent_watch'] == true) {
      parts.add(t.fceJoinConsentWatch2(elderDigits(p['hours'] ?? 4, bn)));
      parts.add(t.fceWatchPrivacy);
    }
    parts.add(t.fceJoinConsentStop);
    return parts.join('\n\n');
  }

  Future<void> _readAloud() async {
    if (!mounted) return;
    final t = AppLocalizations.of(context);
    await ElderHooks.say(context, '${_consentText(t)}\n\n${t.fceJoinConsentAsk}');
  }

  Future<void> _yes() async {
    final api = ElderHooks.api(context);
    final t = AppLocalizations.of(context);
    if (api == null) return;
    final lang = ElderHooks.lang(context);
    unawaited(ElderHooks.say(context, t.fceJoinYes));
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final r = await api.acceptSetup(_code);
      final plan = (r['plan'] as Map?) ?? const {};
      final cfg = Map<String, dynamic>.from((r['config'] as Map?) ?? const {});
      await SilentWatchClient.configure(api, cfg, token: r['token'] as String?, lang: lang);
      if (plan['easy_home'] == true && mounted) {
        await EldersModeController.set(context, true);
      }
      if (mounted) setState(() => _step = _Step.battery);
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } catch (_) {
      if (mounted) setState(() => _error = t.fceOffline);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(t.fceJoinTitle)),
      body: ListView(
        padding: withNavBarInset(context, const EdgeInsets.fromLTRB(Gap.lg, Gap.md, Gap.lg, Gap.xxl)),
        children: switch (_step) {
          _Step.code => _codeStep(t),
          _Step.consent => _consentStep(t),
          _Step.battery => _batteryStep(t),
          _Step.done => _batteryStep(t),
        },
      ),
      // The big YES is always on screen (owner screenshot review: under a
      // long consent text it sat below the fold — an elder may never scroll).
      bottomNavigationBar: _step == _Step.consent
          ? SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(Gap.lg, Gap.sm, Gap.lg, Gap.md),
                child: ElderBigButton(
                  key: const Key('fce-consent-yes'),
                  icon: Icons.check_circle_rounded,
                  label: t.fceJoinYes,
                  sublabel: t.fceJoinConsentAsk,
                  color: ElderColors.ok,
                  minHeight: 112,
                  onTap: _busy ? () {} : _yes,
                ),
              ),
            )
          : null,
    );
  }

  List<Widget> _codeStep(AppLocalizations t) {
    final scheme = Theme.of(context).colorScheme;
    return [
      Text(t.fceJoinCodeHelp, style: AType.titleLarge),
      const SizedBox(height: Gap.lg),
      TextField(
        key: const Key('fce-join-code'),
        controller: _codeCtl,
        maxLength: 8,
        buildCounter: localCounter,
        textCapitalization: TextCapitalization.characters,
        style: AType.headlineMedium.copyWith(letterSpacing: 4, fontWeight: FontWeight.w700),
        decoration: InputDecoration(labelText: t.fceJoinCodeHint, border: const OutlineInputBorder()),
        onSubmitted: (_) => _check(),
      ),
      const SizedBox(height: Gap.md),
      SizedBox(
        height: 64,
        child: FilledButton(
          key: const Key('fce-join-next'),
          onPressed: _busy ? null : _check,
          child: Text(t.fceJoinCodeCta, style: AType.titleLarge),
        ),
      ),
      if (_error != null)
        Padding(
            padding: const EdgeInsets.only(top: Gap.md),
            child: Text(_error!, style: AType.titleMedium.copyWith(color: scheme.error))),
    ];
  }

  List<Widget> _consentStep(AppLocalizations t) {
    final scheme = Theme.of(context).colorScheme;
    final child = '${_preview?['child_name'] ?? ''}';
    return [
      Text(t.fceJoinConsentTitle(child),
          key: const Key('fce-consent-title'),
          style: AType.headlineMedium.copyWith(fontWeight: FontWeight.w800)),
      const SizedBox(height: Gap.md),
      Text(_consentText(t), style: AType.titleLarge.copyWith(height: 1.5)),
      const SizedBox(height: Gap.md),
      SizedBox(
        height: 56,
        child: OutlinedButton.icon(
          key: const Key('fce-consent-listen'),
          onPressed: _readAloud,
          icon: const Icon(Icons.volume_up_rounded, size: 28),
          label: Text(t.fceListenAgain, style: AType.titleLarge),
        ),
      ),
      const SizedBox(height: Gap.md),
      SizedBox(
        height: 56,
        child: TextButton(
          onPressed: () => Navigator.of(context).maybePop(),
          child: Text(t.fceJoinNotNow, style: AType.titleLarge),
        ),
      ),
      if (_error != null)
        Text(_error!, style: AType.titleMedium.copyWith(color: scheme.error)),
    ];
  }

  List<Widget> _batteryStep(AppLocalizations t) => [
        const Icon(Icons.verified_rounded, size: 72, color: ElderColors.ok),
        const SizedBox(height: Gap.md),
        Text(t.fceJoinDone,
            key: const Key('fce-join-done'),
            textAlign: TextAlign.center,
            style: AType.headlineMedium.copyWith(fontWeight: FontWeight.w800)),
        const SizedBox(height: Gap.lg),
        Text(t.fceJoinBatteryBody, style: AType.titleLarge),
        const SizedBox(height: Gap.lg),
        SizedBox(
          height: 64,
          child: FilledButton.icon(
            key: const Key('fce-join-battery'),
            onPressed: () => Navigator.of(context).push(MaterialPageRoute<void>(
                builder: (_) => const BatteryGuidanceScreen(firstRun: true))),
            icon: const Icon(Icons.battery_charging_full_rounded),
            label: Text(t.fceJoinBatteryCta, style: AType.titleLarge),
          ),
        ),
        const SizedBox(height: Gap.md),
        SizedBox(
          height: 56,
          child: OutlinedButton(
            key: const Key('fce-join-finish'),
            onPressed: () => Navigator.of(context).popUntil((r) => r.isFirst),
            child: Text(t.fceJoinFinish, style: AType.titleLarge),
          ),
        ),
      ];
}
