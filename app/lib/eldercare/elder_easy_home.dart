import 'dart:async';

import 'package:clock/clock.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../l10n/app_localizations.dart';
import '../state.dart';
import '../theme.dart';
import '../widgets/app_sheet.dart';
import '../widgets/chatnav.dart';
import '../widgets/elderly_mode.dart';
import '../widgets/voice_command_sheet.dart';
import 'elder_common.dart';
import 'silent_watch_client.dart';
import 'silent_watch_settings_sheet.dart';

/// fcelder — SCREEN 4 ELDER EASY HOME (Family Care V3, opt-in elderly mode).
///
/// A greeting with the elder's name and the time, then five very large,
/// high-contrast buttons: I AM OK (green), call son, call daughter, Talk to
/// Assisto, DANGER (red -> the SOS sender). Every button SAYS its name out
/// loud when pressed (the phone's own Bangla voice), so an elder who cannot
/// read well still knows what they pressed. Text wraps (never clipped) at
/// 200 % font, light + dark, TalkBack labels, 96 dp targets.
///
/// Calls go over the SIM (no internet needed); the family list is cached for
/// offline. Always free, never ads. Every tap is also a sign of life for an
/// opted-in Silent Watch (kept on the phone only).
class ElderEasyHome extends StatefulWidget {
  final VoidCallback? onExit;

  /// Tests / gallery: a fixed family list and name (no server).
  final List<ElderContact>? debugFamily;
  final String? debugName;

  /// Gallery (gap-familycare): open the answer sheet for (question, answer).
  final (String, String)? debugReply;

  const ElderEasyHome({super.key, this.onExit, this.debugFamily, this.debugName, this.debugReply});

  @override
  State<ElderEasyHome> createState() => _ElderEasyHomeState();
}

class _ElderEasyHomeState extends State<ElderEasyHome> with WidgetsBindingObserver {
  List<ElderContact> _family = const [];
  bool _watchOn = false;
  int _daysLearned = 0;
  DateTime? _awayUntil;
  Timer? _tick;
  DateTime _now = clock.now();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _tick = Timer.periodic(const Duration(seconds: 30), (_) {
      if (mounted) setState(() => _now = clock.now());
    });
    _load();
    final dr = widget.debugReply;
    if (dr != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) unawaited(_showReply(dr.$1, elderPlainReply(dr.$2)));
      });
    }
  }

  @override
  void dispose() {
    _tick?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _load();
  }

  Future<void> _load() async {
    if (widget.debugFamily != null) {
      setState(() => _family = widget.debugFamily!);
    } else {
      final cached = await ElderFamilyCache.load();
      if (mounted && cached.isNotEmpty) setState(() => _family = cached);
      final api = ElderHooks.api(context);
      if (api != null) {
        try {
          final r = await api.status();
          final fresh = ((r['family'] as List?) ?? const [])
              .map(ElderContact.fromJson)
              .whereType<ElderContact>()
              .toList();
          await ElderFamilyCache.save(fresh);
          if (mounted) setState(() => _family = fresh);
        } catch (_) {
          // offline: the cached family keeps working (calls use the SIM)
        }
      }
    }
    final on = await SilentWatchClient.isOn();
    final days = await SilentWatchClient.daysLearned();
    final away = on ? await SilentWatchClient.awayUntil() : null;
    if (mounted) {
      setState(() {
        _watchOn = on;
        _daysLearned = days;
        _awayUntil = away;
      });
    }
  }

  AppLocalizations get _t => AppLocalizations.of(context);
  bool get _bn => ElderHooks.lang(context) == 'bn';

  String _name() {
    if (widget.debugName != null) return widget.debugName!;
    try {
      final n = context.read<AppState>().user?.name.trim() ?? '';
      return n.split(' ').first;
    } catch (_) {
      return '';
    }
  }

  String _greeting() {
    final h = _now.hour, n = _name();
    if (h >= 4 && h < 12) return _t.fceGoodMorning(n);
    if (h >= 12 && h < 17) return _t.fceGoodAfternoon(n);
    return _t.fceGoodEvening(n);
  }

  Future<void> _pressed(String spoken) async {
    unawaited(SilentWatchClient.noteActivity());
    await ElderHooks.say(context, spoken);
  }

  Future<void> _ok() async {
    final t = _t;
    unawaited(_pressed(t.fceImOk));
    await SilentWatchClient.iAmOk(ElderHooks.api(context));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(t.fceImOkDone, style: AType.titleLarge.copyWith(color: Colors.white)),
        backgroundColor: ElderColors.ok));
  }

  Future<void> _call(ElderContact c, String label) async {
    final t = _t;
    unawaited(_pressed(label));
    final who = c.name.isEmpty ? label : c.name;
    final go = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        scrollable: true,
        icon: const Icon(Icons.call_rounded, color: ElderColors.ok, size: 36),
        title: Text(t.fceCallConfirm(who), style: AType.headlineSmall),
        content: Text(elderDigits(c.phone, _bn), style: AType.titleLarge),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(t.cancel, style: AType.titleLarge)),
          FilledButton.icon(
            style: Brand.successButton(),
            onPressed: () => Navigator.pop(ctx, true),
            icon: const Icon(Icons.call_rounded),
            label: Text(t.fceCallNow, style: AType.titleLarge),
          ),
        ],
      ),
    );
    if (go != true) return;
    final uri = Uri(scheme: 'tel', path: c.phone);
    try {
      await launchUrl(uri);
    } catch (_) {
      // best-effort: no dialer app; the number stays on screen to dial by hand
    }
  }

  Future<void> _talk() async {
    unawaited(_pressed(_t.fceTalk));
    final listen = ElderHooks.listenOverride;
    final text = listen != null ? await listen(context) : await showVoiceCommandSheet(context);
    if (text == null || text.trim().isEmpty || !mounted) return;
    final local = ChatNav.detectRoute(text);
    if (local != null && ChatNav.push(context, local)) return;
    Map<String, dynamic>? r;
    try {
      final ask = ElderHooks.agentOverride;
      r = ask != null ? await ask(context, text) : await context.read<AppState>().api.agent(text);
    } catch (_) {
      r = null; // offline / AI down -> the honest offline line below
    }
    if (!mounted) return;
    if (r != null && ChatNav.push(context, r['route'] as String?)) return;
    // gap-familycare: a real question gets a real answer — shown big and
    // read out loud (before: every answer was dropped as "could not").
    final reply = r == null ? '' : elderPlainReply('${r['reply'] ?? ''}');
    if (reply.isNotEmpty) {
      await _showReply(text.trim(), reply);
      return;
    }
    final msg = r == null ? _t.fceTalkOffline : _t.sendFailed;
    unawaited(ElderHooks.say(context, msg));
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(msg, style: AType.titleMedium.copyWith(color: Colors.white))));
  }

  Future<void> _showReply(String asked, String reply) async {
    final t = _t;
    final spoken = elderSpokenPart(reply);
    unawaited(ElderHooks.say(context, spoken));
    await showAppSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: MediaQuery.of(ctx).size.height * 0.85),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(Gap.lg, 0, Gap.lg, Gap.lg),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(t.fceYouAsked(asked),
                    style: AType.titleMedium.copyWith(
                        color: Theme.of(ctx).colorScheme.onSurfaceVariant)),
                const SizedBox(height: Gap.sm),
                Flexible(
                  child: SingleChildScrollView(
                    child: Text(reply,
                        key: const Key('fce-reply'),
                        style: AType.headlineSmall.copyWith(height: 1.45)),
                  ),
                ),
                const SizedBox(height: Gap.md),
                ElderBigButton(
                  key: const Key('fce-reply-again'),
                  icon: Icons.volume_up_rounded,
                  label: t.fceHearAgain,
                  color: ElderColors.talk,
                  minHeight: 72,
                  onTap: () => unawaited(ElderHooks.say(ctx, spoken)),
                ),
                const SizedBox(height: Gap.sm),
                ElderBigButton(
                  key: const Key('fce-reply-close'),
                  icon: Icons.close_rounded,
                  label: t.close,
                  color: ElderColors.callA,
                  minHeight: 72,
                  onTap: () => Navigator.pop(ctx),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _danger() async {
    unawaited(_pressed(_t.fceDanger));
    await ElderHooks.sos(context);
  }

  Future<void> _exit() async {
    final t = _t;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        scrollable: true,
        title: Text(t.elderlyExitConfirmTitle),
        content: Text(t.elderlyExitConfirmBody),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(t.cancel)),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(t.elderlyExitConfirmCta)),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    await EldersModeController.set(context, false);
    if (!mounted) return;
    widget.onExit?.call();
  }

  /// "I am going out" (phone left at home): Silent Watch does not ask
  /// "Are you OK?" until the chosen time + 30 min — so an outing to the
  /// market or the mosque never worries the family. Back home: any use of
  /// the phone ends the pause.
  Future<void> _goingOut() async {
    final t = _t;
    unawaited(_pressed(t.fceGoingOut));
    final hours = await showAppSheet<int>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(Gap.lg, 0, Gap.lg, Gap.lg),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Semantics(
                header: true,
                child: Text(t.fceGoingOutAsk, style: AType.headlineSmall.copyWith(fontWeight: FontWeight.w700)),
              ),
              const SizedBox(height: Gap.xs),
              Text(t.fceGoingOutWhy, style: AType.titleMedium),
              const SizedBox(height: Gap.md),
              for (final h in const [1, 2, 3, 4]) ...[
                ElderBigButton(
                  key: Key('fce-away-$h'),
                  icon: Icons.schedule_rounded,
                  label: t.fceGoingOutHours(elderDigits(h, _bn)),
                  color: ElderColors.callA,
                  minHeight: 72,
                  onTap: () => Navigator.pop(ctx, h),
                ),
                const SizedBox(height: Gap.sm),
              ],
            ],
          ),
        ),
      ),
    );
    if (hours == null || !mounted) return;
    final until = await SilentWatchClient.goingOut(hours);
    if (!mounted) return;
    setState(() => _awayUntil = until);
    final msg = until == null ? t.fceGoingOutFailed : t.fceGoingOutDone(elderClock(until, _bn));
    unawaited(ElderHooks.say(context, msg));
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(msg, style: AType.titleLarge.copyWith(color: Colors.white)),
        backgroundColor: until == null ? ElderColors.danger : ElderColors.callA));
  }

  void _watchSettings() {
    showAppSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => const SilentWatchSettingsSheet(),
    ).then((_) => _load());
  }

  @override
  Widget build(BuildContext context) {
    final t = _t;
    final pick = pickCallTargets(_family);
    String label(ElderContact c) {
      if (c.isSon) return t.fceCallSon;
      if (c.isDaughter) return t.fceCallDaughter;
      return t.fceCallName(c.name);
    }

    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      backgroundColor: scheme.surface,
      appBar: AppBar(
        toolbarHeight: 64,
        automaticallyImplyLeading: false,
        title: Text(t.elderlyHomeTitle, style: AType.titleLarge.copyWith(fontWeight: FontWeight.w700)),
      ),
      body: ListView(
        padding: withNavBarInset(context, const EdgeInsets.fromLTRB(Gap.lg, Gap.sm, Gap.lg, Gap.xxl)),
        children: [
          Semantics(
            header: true,
            child: Text(_greeting(),
                key: const Key('fce-greeting'),
                style: AType.headlineLarge.copyWith(fontWeight: FontWeight.w800, color: scheme.onSurface)),
          ),
          Text(t.fceTimeNow(elderClock(_now, _bn)),
              key: const Key('fce-time'),
              style: AType.displaySmall.copyWith(fontWeight: FontWeight.w700, color: scheme.onSurface)),
          const SizedBox(height: Gap.lg),
          ElderBigButton(
            key: const Key('fce-ok'),
            icon: Icons.check_circle_rounded,
            label: t.fceImOk,
            sublabel: _watchOn ? t.fceImOkSub : null,
            color: ElderColors.ok,
            minHeight: 112,
            onTap: _ok,
          ),
          const SizedBox(height: Gap.md),
          if (pick.first != null)
            ElderBigButton(
              key: const Key('fce-call-1'),
              icon: Icons.call_rounded,
              label: label(pick.first!),
              sublabel: pick.first!.isSon || pick.first!.isDaughter ? pick.first!.name : null,
              color: ElderColors.callA,
              onTap: () => _call(pick.first!, label(pick.first!)),
            )
          else
            ElderBigButton(
              key: const Key('fce-add-family'),
              icon: Icons.person_add_alt_1_rounded,
              label: t.fceAddFamily,
              sublabel: t.fceAddFamilySub,
              color: ElderColors.callA,
              onTap: () {
                unawaited(_pressed(t.fceAddFamily));
                ChatNav.push(context, 'family');
              },
            ),
          if (pick.second != null) ...[
            const SizedBox(height: Gap.md),
            ElderBigButton(
              key: const Key('fce-call-2'),
              icon: Icons.call_rounded,
              label: label(pick.second!),
              sublabel: pick.second!.isSon || pick.second!.isDaughter ? pick.second!.name : null,
              color: ElderColors.callB,
              onTap: () => _call(pick.second!, label(pick.second!)),
            ),
          ],
          const SizedBox(height: Gap.md),
          ElderBigButton(
            key: const Key('fce-talk'),
            icon: Icons.mic_rounded,
            label: t.fceTalk,
            color: ElderColors.talk,
            onTap: _talk,
          ),
          const SizedBox(height: Gap.md),
          ElderBigButton(
            key: const Key('fce-danger'),
            icon: Icons.sos_rounded,
            label: t.fceDanger,
            sublabel: t.fceDangerSub,
            color: ElderColors.danger,
            minHeight: 112,
            onTap: _danger,
          ),
          const SizedBox(height: Gap.xl),
          if (_watchOn) ...[
            Card(
              child: ListTile(
                key: const Key('fce-going-out'),
                minVerticalPadding: Gap.md,
                leading: Icon(Icons.directions_walk_rounded, color: scheme.primary, size: 32),
                title: Text(t.fceGoingOut, style: AType.titleLarge),
                subtitle: Text(
                    _awayUntil == null
                        ? t.fceGoingOutSub
                        : t.fceGoingOutActive(elderClock(_awayUntil!, _bn)),
                    style: AType.titleMedium),
                trailing: const Icon(Icons.chevron_right_rounded),
                onTap: _goingOut,
              ),
            ),
            const SizedBox(height: Gap.sm),
          ],
          if (_watchOn)
            Card(
              child: ListTile(
                key: const Key('fce-watch-row'),
                minVerticalPadding: Gap.md,
                leading: Icon(Icons.shield_moon_rounded, color: scheme.primary, size: 32),
                title: Text(t.fceWatchOn, style: AType.titleLarge),
                subtitle: Text(
                    _daysLearned >= 7
                        ? t.fceWatchLearned
                        : t.fceWatchLearning(elderDigits(_daysLearned + 1, _bn)),
                    style: AType.titleMedium),
                trailing: const Icon(Icons.chevron_right_rounded),
                onTap: _watchSettings,
              ),
            ),
          const SizedBox(height: Gap.md),
          // The always-present, clearly labelled way OUT of the easy home
          // (bottom of the page: never squeezed off a 200 % app bar).
          SizedBox(
            height: 56,
            child: TextButton.icon(
              key: const Key('fce-exit'),
              onPressed: _exit,
              icon: const Icon(Icons.close_rounded, size: 26),
              label: Text(t.elderlyExitCta, style: AType.titleMedium),
            ),
          ),
        ],
      ),
    );
  }
}
