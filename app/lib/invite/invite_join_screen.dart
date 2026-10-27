import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:provider/provider.dart';

import '../crypto/identity_vault.dart';
import '../growth/install_ping.dart';
import '../l10n/app_localizations.dart';
import '../models.dart';
import '../otp_api.dart';
import '../push/push_service.dart' show appNavigatorKey;
import '../screens/circle_chat_screen.dart';
import '../screens/login_screen.dart';
import '../screens/otp/otp_verify_screen.dart';
import '../state.dart';
import '../theme.dart';
import 'invite_api.dart';
import 'invite_link.dart';
import 'invite_router.dart';

/// invite-join — "Join <name>'s circle" (owner order 27 Oct, gap #7).
///
/// Signed OUT (new person, opened from the link / Play install referrer):
///   name + mobile -> [Join]  (SMS on: one OTP screen; no password, ever)
///   -> account made + joined server-side in ONE call -> straight into the
///   chat with the inviter. "SMS didn't come" -> continue with email.
/// Signed IN: one card, [Join] -> the chat.
///
/// Every state has its own honest screen: loading, offline (Retry), invalid /
/// expired / used / own invite / rate limited (server's bilingual text),
/// already connected (Open chat), circle full. 48dp targets, theme colours
/// only (dark mode), large-font safe (scrolls, no fixed heights), TalkBack
/// labels on the avatar + buttons.
class InviteJoinScreen extends StatefulWidget {
  final String code;
  final String via;
  final InviteBackend? backend;
  final OtpBackend? otpBackend;

  /// Tests inject a fake picker (no platform channel).
  final Future<Uint8List?> Function()? pickPhoto;

  /// Tests: skip opening the chat (needs crypto + network).
  final void Function(Map<String, dynamic> member, String name)? onJoined;

  /// Shown as the router's root (signed out) vs pushed over home (signed in).
  final bool asRoot;

  /// Tests: record the new session instead of touching secure storage.
  final Future<void> Function(String token, AppUser user)? adopt;

  const InviteJoinScreen({
    super.key,
    required this.code,
    this.via = 'link',
    this.backend,
    this.otpBackend,
    this.pickPhoto,
    this.onJoined,
    this.asRoot = false,
    this.adopt,
  });

  @override
  State<InviteJoinScreen> createState() => _InviteJoinScreenState();
}

enum _St { loading, offline, ready, problem, already }

class _InviteJoinScreenState extends State<InviteJoinScreen> {
  _St _st = _St.loading;
  Map<String, dynamic> _p = const {};
  String _problem = '';
  bool _busy = false;
  bool _useEmail = false;
  String? _error;
  Uint8List? _photo;
  final _name = TextEditingController();
  final _phone = TextEditingController();
  final _email = TextEditingController();

  InviteBackend get _b =>
      widget.backend ?? ApiInviteBackend(context.read<AppState>().api);
  OtpBackend get _otp =>
      widget.otpBackend ?? ApiOtpBackend(context.read<AppState>().api);
  bool get _signedIn => context.read<AppState>().loggedIn;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  @override
  void dispose() {
    _name.dispose();
    _phone.dispose();
    _email.dispose();
    super.dispose();
  }

  String get _inviter {
    final n = '${_p['inviter_name'] ?? ''}'.trim();
    return n.isEmpty ? AppLocalizations.of(context).circleSomeone : n;
  }

  Future<void> _load() async {
    if (!mounted) return;
    setState(() {
      _st = _St.loading;
      _error = null;
    });
    try {
      final r = await _b.preview(widget.code).timeout(const Duration(seconds: 15));
      if (!mounted) return;
      final state = '${r['state'] ?? ''}';
      setState(() {
        _p = r;
        if (inviteOk(r) && state == 'already') {
          _st = _St.already;
        } else if (inviteOk(r)) {
          _st = _St.ready;
        } else {
          _st = _St.problem;
          _problem = '${r['detail'] ?? ''}';
        }
      });
    } catch (_) {
      if (mounted) setState(() => _st = _St.offline);
    }
  }

  // ------------------------------------------------------------------ actions
  Future<void> _pick() async {
    try {
      Uint8List? b;
      if (widget.pickPhoto != null) {
        b = await widget.pickPhoto!();
      } else {
        final x = await ImagePicker().pickImage(
            source: ImageSource.gallery, maxWidth: 512, maxHeight: 512, imageQuality: 80);
        b = await x?.readAsBytes();
      }
      if (b != null && mounted) setState(() => _photo = b);
    } catch (_) { // best-effort: picker unavailable; the photo is optional
    }
  }

  Future<void> _joinSignedIn() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final r = await _b.join(widget.code, via: widget.via)
          .timeout(const Duration(seconds: 20));
      if (!mounted) return;
      if (!inviteOk(r)) {
        setState(() => _error = '${r['detail'] ?? ''}');
        return;
      }
      await _done(r);
    } catch (_) {
      if (mounted) setState(() => _error = AppLocalizations.of(context).ijOffline);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _signup() async {
    final t = AppLocalizations.of(context);
    final name = _name.text.trim();
    final phone = _phone.text.trim();
    final email = _email.text.trim();
    if (name.isEmpty) return setState(() => _error = t.ijNeedName);
    if (!_useEmail && phone.isEmpty) return setState(() => _error = t.ijNeedPhone);
    if (!_useEmail && !looksLikeBdMobile(phone)) {
      return setState(() => _error = t.otpPhoneInvalid);
    }
    if (_useEmail && !email.contains('@')) return setState(() => _error = t.ijNeedEmail);
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      String? proof;
      if (!_useEmail && _p['sms_enabled'] == true) {
        proof = await OtpVerifyScreen.run(context,
            backend: _otp, purpose: 'signup', phone: phone, title: t.ijVerifyTitle);
        if (!mounted) return;
        if (proof == null) {
          // backed out or the SMS never came: offer the email way, honestly
          setState(() => _error = t.ijSmsFailed);
          return;
        }
      }
      var device = '';
      try {
        device = await InstallPing.installId();
      } catch (_) {} // best-effort: no device id only skips referral credit
      final r = await _b
          .signup(
              code: widget.code,
              name: name,
              phone: _useEmail ? '' : phone,
              email: _useEmail ? email : '',
              otpProof: proof,
              via: widget.via,
              deviceId: device)
          .timeout(const Duration(seconds: 25));
      if (!mounted) return;
      if (!inviteOk(r) || r['token'] == null) {
        setState(() => _error = '${r['detail'] ?? t.ijOffline}');
        return;
      }
      final app = context.read<AppState>();
      // The signed-in root must not offer this same code again on top.
      InviteRouter.markHandled(widget.code);
      final cx = _ctx();
      final user = AppUser.fromJson((r['user'] as Map).cast<String, dynamic>());
      if (widget.adopt != null) {
        await widget.adopt!('${r['token']}', user);
      } else {
        // The language shown here is the choice (the screen has the switch).
        if (app.locale == null && mounted) {
          await app.setLocale(Localizations.localeOf(context));
        }
        // The invite IS the first win: no 7-step onboarding before the chat.
        await Settings.setBool('onboarded', true);
        app.markOnboarded();
        await app.adoptSession('${r['token']}', user);
      }
      final photo = _photo;
      if (photo != null) unawaited(app.saveProfile({'photo': base64Encode(photo)}));
      await _done(r, cx);
    } catch (_) {
      if (mounted) setState(() => _error = t.ijOffline);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Everything [_done] needs from this screen's context, captured BEFORE
  /// sign-in (the root swaps this screen for home as soon as the session
  /// exists, so the context may be gone afterwards).
  ({AppLocalizations t, NavigatorState? nav, ScaffoldMessengerState? messenger})
      _ctx() => (
            t: AppLocalizations.of(context),
            nav: appNavigatorKey.currentState ?? Navigator.maybeOf(context),
            messenger: ScaffoldMessenger.maybeOf(context),
          );

  Future<void> _done(Map<String, dynamic> r,
      [({AppLocalizations t, NavigatorState? nav, ScaffoldMessengerState? messenger})?
          c]) async {
    final member = ((r['member'] as Map?) ?? const {}).cast<String, dynamic>();
    final name = '${(r['inviter'] as Map?)?['name'] ?? _p['inviter_name'] ?? ''}';
    final cx = c ?? _ctx();
    await PendingInvite.clear();
    if (widget.onJoined != null) {
      widget.onJoined!(member, name);
      return;
    }
    final t = cx.t;
    final nav = cx.nav;
    final messenger = cx.messenger;
    if (!widget.asRoot && mounted) Navigator.of(context).maybePop();
    messenger?.showSnackBar(SnackBar(
        content: Text(t.ijJoinedSnack(name.isEmpty ? t.circleSomeone : name))));
    try {
      final id = await IdentityVault.instance.get();
      // root case: the router swaps this screen for home on sign-in; open
      // the chat on top of it on the next frame
      WidgetsBinding.instance.addPostFrameCallback((_) {
        nav?.push(MaterialPageRoute<void>(
            builder: (_) => CircleChatScreen(member: member, identity: id)));
      });
    } catch (_) {} // best-effort: already joined + snack shown; the chat is in My Circle
  }

  Future<void> _notNow() async {
    // As the root, the router swaps this screen for sign-in as soon as the
    // code is cleared; show progress until it does (never a dead tap).
    if (widget.asRoot) setState(() => _st = _St.loading);
    await PendingInvite.clear();
    if (!mounted) return;
    if (!widget.asRoot) Navigator.of(context).maybePop();
  }

  // ----------------------------------------------------------------------- UI
  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    return Scaffold(
      appBar: AppBar(
        title: Text(t.ijAppBar),
        automaticallyImplyLeading: !widget.asRoot,
        actions: [
          if (widget.asRoot)
            TextButton(
              key: const Key('ij-lang'),
              onPressed: () {
                final app = context.read<AppState>();
                final bn = Localizations.localeOf(context).languageCode == 'bn';
                app.setLocale(Locale(bn ? 'en' : 'bn'));
              },
              child: Text(t.ijSwitchLang),
            ),
        ],
      ),
      body: SafeArea(child: _body(t)),
    );
  }

  Widget _body(AppLocalizations t) {
    switch (_st) {
      case _St.loading:
        return Center(
            child: Semantics(
                label: t.ijLoading, child: const CircularProgressIndicator()));
      case _St.offline:
        return _message(Icons.wifi_off_rounded, t.ijOffline,
            primary: (t.ijRetry, _load), key: const Key('ij-offline'));
      case _St.problem:
        return _message(Icons.link_off_rounded, _problem.isEmpty ? t.ijBadTitle : _problem,
            title: t.ijBadTitle,
            primary: (t.ijContinueApp, _notNow),
            key: const Key('ij-problem'));
      case _St.already:
        return _message(Icons.check_circle_rounded, t.ijAlready(_inviter),
            primary: (t.ijOpenChat, _joinSignedIn), key: const Key('ij-already'));
      case _St.ready:
        return _signedIn ? _confirmCard(t) : _form(t);
    }
  }

  Widget _header(AppLocalizations t) {
    final scheme = Theme.of(context).colorScheme;
    final initial = '${_p['inviter_initial'] ?? ''}'.trim();
    return Column(children: [
      Semantics(
        label: t.ijJoinTitle(_inviter),
        excludeSemantics: true,
        child: CircleAvatar(
          radius: 40,
          backgroundColor: scheme.primaryContainer,
          child: Text(initial.isEmpty ? '?' : initial,
              style: TextStyle(
                  fontSize: 34,
                  fontWeight: FontWeight.w800,
                  color: scheme.onPrimaryContainer)),
        ),
      ),
      const SizedBox(height: Gap.md),
      Text(t.ijJoinTitle(_inviter),
          key: const Key('ij-title'),
          textAlign: TextAlign.center,
          style: Theme.of(context)
              .textTheme
              .headlineSmall
              ?.copyWith(fontWeight: FontWeight.w700)),
      const SizedBox(height: Gap.xs),
      Text(t.ijJoinSub,
          textAlign: TextAlign.center,
          style: TextStyle(color: scheme.onSurfaceVariant, height: 1.4)),
    ]);
  }

  Widget _confirmCard(AppLocalizations t) {
    return _scroll([
      _header(t),
      const SizedBox(height: Gap.xl),
      _primary(t.ijJoinButton, _joinSignedIn, key: const Key('ij-join')),
      const SizedBox(height: Gap.sm),
      _errorText(),
      TextButton(
          key: const Key('ij-not-now'),
          style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
          onPressed: _busy ? null : _notNow,
          child: Text(t.ijNotNow)),
    ]);
  }

  Widget _form(AppLocalizations t) {
    final scheme = Theme.of(context).colorScheme;
    return _scroll([
      _header(t),
      const SizedBox(height: Gap.lg),
      TextField(
        key: const Key('ij-name'),
        controller: _name,
        autofocus: true,
        textInputAction: TextInputAction.next,
        textCapitalization: TextCapitalization.words,
        maxLength: 60,
        decoration: InputDecoration(
            labelText: t.ijNameLabel, prefixIcon: const Icon(Icons.person_rounded)),
      ),
      const SizedBox(height: Gap.sm),
      if (!_useEmail)
        TextField(
          key: const Key('ij-phone'),
          controller: _phone,
          keyboardType: TextInputType.phone,
          textInputAction: TextInputAction.done,
          onSubmitted: (_) => _busy ? null : _signup(),
          inputFormatters: [
            FilteringTextInputFormatter.allow(RegExp(r'[0-9+ \-\u09E6-\u09EF]')),
          ],
          decoration: InputDecoration(
              labelText: t.ijPhoneLabel,
              hintText: t.ijPhoneHint,
              prefixIcon: const Icon(Icons.phone_rounded)),
        )
      else
        TextField(
          key: const Key('ij-email'),
          controller: _email,
          keyboardType: TextInputType.emailAddress,
          textInputAction: TextInputAction.done,
          onSubmitted: (_) => _busy ? null : _signup(),
          decoration: InputDecoration(
              labelText: t.ijEmailLabel, prefixIcon: const Icon(Icons.email_rounded)),
        ),
      const SizedBox(height: Gap.sm),
      Align(
        alignment: AlignmentDirectional.centerStart,
        child: TextButton.icon(
          key: const Key('ij-photo'),
          style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
          onPressed: _busy ? null : _pick,
          icon: _photo == null
              ? const Icon(Icons.add_a_photo_rounded)
              : CircleAvatar(radius: 14, backgroundImage: MemoryImage(_photo!)),
          label: Text(_photo == null ? t.ijAddPhoto : t.ijPhotoAdded),
        ),
      ),
      const SizedBox(height: Gap.md),
      _primary(t.ijJoinButton, _signup, key: const Key('ij-join')),
      const SizedBox(height: Gap.xs),
      Text(t.ijNoPassword,
          textAlign: TextAlign.center,
          style: TextStyle(color: scheme.onSurfaceVariant)),
      _errorText(),
      TextButton(
        key: const Key('ij-switch-email'),
        style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
        onPressed: _busy
            ? null
            : () => setState(() {
                  _useEmail = !_useEmail;
                  _error = null;
                }),
        child: Text(_useEmail ? t.ijUsePhone : t.ijUseEmail, textAlign: TextAlign.center),
      ),
      TextButton(
        key: const Key('ij-have-account'),
        style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
        onPressed: _busy
            ? null
            : () => Navigator.of(context).push(
                MaterialPageRoute<void>(builder: (_) => const _SignInRoute())),
        child: Text(t.ijHaveAccount, textAlign: TextAlign.center),
      ),
    ]);
  }

  Widget _errorText() {
    final e = _error;
    if (e == null || e.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: Gap.sm),
      child: Semantics(
        liveRegion: true,
        child: Text(e,
            key: const Key('ij-error'),
            textAlign: TextAlign.center,
            style: TextStyle(color: Theme.of(context).colorScheme.error)),
      ),
    );
  }

  Widget _primary(String label, VoidCallback onTap, {Key? key}) => FilledButton(
        key: key,
        style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
        onPressed: _busy ? null : onTap,
        child: _busy
            ? const SizedBox(
                width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2))
            : Text(label, style: const TextStyle(fontSize: 17)),
      );

  Widget _scroll(List<Widget> children) => Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(Gap.lg),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 440),
            child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch, children: children),
          ),
        ),
      );

  Widget _message(IconData icon, String text,
      {String? title, required (String, VoidCallback) primary, Key? key}) {
    final scheme = Theme.of(context).colorScheme;
    return KeyedSubtree(
      key: key,
      child: _scroll([
        Icon(icon, size: 56, color: scheme.primary),
        const SizedBox(height: Gap.md),
        if (title != null) ...[
          Text(title,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: Gap.sm),
        ],
        Text(text, textAlign: TextAlign.center, style: const TextStyle(height: 1.4)),
        const SizedBox(height: Gap.lg),
        _primary(primary.$1, primary.$2),
      ]),
    );
  }
}

/// "Already have an account? Sign in" — the normal login screen; once signed
/// in, the router (still holding the pending code) offers the one-tap join.
class _SignInRoute extends StatelessWidget {
  const _SignInRoute();
  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    if (app.loggedIn) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (context.mounted) Navigator.of(context).maybePop();
      });
    }
    return const LoginScreen();
  }
}
