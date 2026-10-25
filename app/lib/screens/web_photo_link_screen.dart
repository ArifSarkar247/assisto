import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../l10n/app_localizations.dart';
import '../photo_studio/ps_backend.dart';
import '../photo_studio/ps_controller.dart';
import '../photo_studio/ps_web_import.dart';
import '../state.dart';
import '../theme.dart';
import '../widgets/skeleton.dart';
import 'photo_studio_screen.dart';

/// w1-webphoto — target of https://lifeassisto.com/photo/app?t=<token>.
///
/// Signed out: remembers the token and asks to sign in (the photo opens right
/// after). Signed in: claims the website photo ONCE and opens Photo Studio
/// with it; saving goes through the normal Photo Studio export gate. An
/// expired / used link gets an honest message, never a fake photo.
class WebPhotoLinkScreen extends StatefulWidget {
  const WebPhotoLinkScreen(
      {super.key, required this.token, this.api, this.deps});
  final String token;

  /// Injected in tests; default talks to the server.
  final WebPhotoApi? api;
  final PsDeps? deps;

  @override
  State<WebPhotoLinkScreen> createState() => _WebPhotoLinkScreenState();
}

enum _Phase { waiting, loading, signIn, expired, failed }

class _WebPhotoLinkScreenState extends State<WebPhotoLinkScreen> {
  _Phase _phase = _Phase.waiting;
  bool _started = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _maybeStart();
  }

  void _maybeStart() {
    if (_started) return;
    final app = context.read<AppState>();
    if (app.loading) return; // rebuilt via watch() below
    if (!app.loggedIn) {
      WebPhotoLink.pending = widget.token;
      if (_phase != _Phase.signIn) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) setState(() => _phase = _Phase.signIn);
        });
      }
      return;
    }
    _started = true;
    WebPhotoLink.pending = null;
    WidgetsBinding.instance.addPostFrameCallback((_) => _claim());
  }

  PsDeps _deps() =>
      widget.deps ??
      PsDeps(backend: ApiPsBackend(context.read<AppState>().api));

  Future<void> _claim() async {
    if (!mounted) return;
    setState(() => _phase = _Phase.loading);
    final deps = _deps();
    WebClaimResult r;
    try {
      final api = widget.api ??
          ApiWebPhotoApi(context.read<AppState>().api, deps.backend);
      r = await api.claim(widget.token);
    } catch (_) {
      r = const WebClaimResult(WebClaimStatus.failed);
    }
    if (!mounted) return;
    switch (r.status) {
      case WebClaimStatus.ok:
        await Navigator.of(context).pushReplacement(MaterialPageRoute(
            builder: (_) =>
                PhotoStudioScreen(deps: widget.deps, webImport: r.import)));
      case WebClaimStatus.expired:
        setState(() => _phase = _Phase.expired);
      case WebClaimStatus.failed:
        setState(() => _phase = _Phase.failed);
    }
  }

  void _openStudio() => Navigator.of(context).pushReplacement(
      MaterialPageRoute(builder: (_) => PhotoStudioScreen(deps: widget.deps)));

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final app = context.watch<AppState>();
    if (!_started && !app.loading) _maybeStart();
    return Scaffold(
      appBar: AppBar(title: Text(t.psTitle)),
      body: SafeArea(
        child: switch (_phase) {
          _Phase.waiting || _Phase.loading => Column(children: [
              Padding(
                padding: const EdgeInsets.all(Gap.lg),
                child: Text(t.psWebOpening,
                    key: const Key('psWebOpening'),
                    style: Theme.of(context).textTheme.titleMedium),
              ),
              const Expanded(child: SkeletonList()),
            ]),
          _Phase.signIn => StateMessage(
              icon: Icons.login_rounded,
              title: t.psWebLoginTitle,
              message: t.psWebLoginBody,
              action: FilledButton.icon(
                key: const Key('psWebSignIn'),
                onPressed: () => Navigator.of(context).maybePop(),
                icon: const Icon(Icons.login_rounded),
                label: Text(t.psWebLoginBtn),
              ),
            ),
          _Phase.expired => StateMessage(
              key: const Key('psWebExpired'),
              icon: Icons.timer_off_rounded,
              title: t.psWebExpiredTitle,
              message: t.psWebExpiredBody,
              tint: Brand.warnInk(context),
              action: FilledButton.icon(
                onPressed: _openStudio,
                icon: const Icon(Icons.auto_awesome_rounded),
                label: Text(t.psWebOpenStudio),
              ),
            ),
          _Phase.failed => StateMessage(
              key: const Key('psWebFailed'),
              icon: Icons.cloud_off_rounded,
              title: t.loadFailed,
              message: t.psWebFailed,
              tint: Brand.danger,
              action: FilledButton.icon(
                onPressed: _claim,
                icon: const Icon(Icons.refresh_rounded),
                label: Text(t.retry),
              ),
            ),
        },
      ),
    );
  }
}
