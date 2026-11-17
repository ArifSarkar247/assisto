import 'dart:async';

import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../ds/ds.dart';
import '../theme.dart';
import '../widgets/app_sheet.dart';
import 'elder_common.dart';
import 'silent_watch_client.dart';

/// fcelder — "Are you OK?" full screen on the ELDER's phone (opened by the
/// Silent Watch ring / the server's ask after a missed Care Call). One huge
/// green I AM OK; "I need help" goes to the SOS sender. The question is
/// spoken out loud when the screen opens and on "Listen again".
class AreYouOkScreen extends StatefulWidget {
  const AreYouOkScreen({super.key});

  static bool _open = false;

  /// Opens once (never stacked twice).
  static Future<void> open(BuildContext context) async {
    if (_open) return;
    _open = true;
    try {
      await Navigator.of(context).push(MaterialPageRoute<void>(
          fullscreenDialog: true, builder: (_) => const AreYouOkScreen()));
    } catch (_) {
    } finally {
      _open = false;
    }
  }

  @override
  State<AreYouOkScreen> createState() => _AreYouOkScreenState();
}

class _AreYouOkScreenState extends State<AreYouOkScreen> {
  bool _done = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _speak());
  }

  Future<void> _speak() async {
    if (!mounted) return;
    final t = AppLocalizations.of(context);
    await ElderHooks.say(context, '${t.fceAskTitle} ${t.fceAskBody}');
  }

  Future<void> _ok() async {
    final t = AppLocalizations.of(context);
    unawaited(ElderHooks.say(context, t.fceImOk));
    await SilentWatchClient.iAmOk(ElderHooks.api(context));
    if (!mounted) return;
    setState(() => _done = true);
    await Future<void>.delayed(const Duration(seconds: 2));
    if (mounted) Navigator.of(context).maybePop();
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final ds = DsTokens.of(context);
    return Scaffold(
      backgroundColor: ds.bg,
      body: SafeArea(
        child: ListView(
          padding: withNavBarInset(context, const EdgeInsets.fromLTRB(Gap.lg, Gap.lg, Gap.lg, Gap.xxl)),
          children: [
            const SizedBox(height: Gap.xl),
            Center(child: DsIllustration(
                icon: _done ? Icons.favorite_rounded : Icons.help_outline_rounded,
                size: 120,
                color: _done ? ElderColors.ok : ds.primary)),
            const SizedBox(height: Gap.md),
            Semantics(
              header: true,
              child: Text(_done ? t.fceImOkDone : t.fceAskTitle,
                  key: const Key('fce-ask-title'),
                  textAlign: TextAlign.center,
                  style: AType.displaySmall.copyWith(fontWeight: FontWeight.w800, color: ds.text)),
            ),
            if (!_done) ...[
              const SizedBox(height: Gap.sm),
              Text(t.fceAskWhy,
                  textAlign: TextAlign.center, style: AType.titleLarge.copyWith(color: ds.muted)),
              const SizedBox(height: Gap.xl),
              ElderBigButton(
                key: const Key('fce-ask-ok'),
                icon: Icons.check_circle_rounded,
                label: t.fceImOk,
                sublabel: t.fceAskBody,
                color: ElderColors.ok,
                minHeight: 140,
                onTap: _ok,
              ),
              const SizedBox(height: Gap.lg),
              ElderBigButton(
                key: const Key('fce-ask-help'),
                icon: Icons.sos_rounded,
                label: t.fceAskNeedHelp,
                color: ElderColors.danger,
                onTap: () {
                  unawaited(ElderHooks.say(context, t.fceAskNeedHelp));
                  ElderHooks.sos(context);
                },
              ),
              const SizedBox(height: Gap.lg),
              // the key sits on the button itself (dead-button sweep allowlist)
              SizedBox(
                height: 56,
                child: TextButton.icon(
                  key: const Key('fce-ask-listen'),
                  onPressed: _speak,
                  icon: const Icon(Icons.volume_up_rounded, size: 28),
                  label: Text(t.fceListenAgain, style: AType.titleLarge.copyWith(color: ds.primaryInk)),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
