import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:local_auth/local_auth.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../l10n/app_localizations.dart';
import '../services/error_report.dart';
import '../theme.dart';
import '../widgets/password_field.dart';

/// e-gaps — CHAT LOCK (WhatsApp "Lock this chat").
///
/// * A locked chat leaves the main chat list and lives in a "Locked chats"
///   folder that opens only after the phone's fingerprint / face (Android 9+
///   with a biometric enrolled) or this phone's chat-lock CODE (always works,
///   Android 8–16, every brand — no system dialog the ROM can break).
/// * Its notifications never show the name or the text ("Assisto — New
///   message"), even in the background isolate.
/// * Opening it from anywhere else (notification, search, a link) shows the
///   lock first ([ChatLockGate]).
/// * The lock lives on THIS phone (like WhatsApp); the code is stored only as
///   a salted, stretched SHA-256 hash. Forgot the code → "Unlock all": every
///   locked chat is unlocked AND cleared from this view, so nobody who
///   doesn't know the code can read them.
class ChatLockStore {
  ChatLockStore._();
  static final ChatLockStore instance = ChatLockStore._();
  static const _k = 'e_chat_lock_v1';
  static const _rounds = 20000;

  Set<String>? _chats;
  String _salt = '';
  String _hash = '';

  /// Bumped on every change (the chat list listens).
  final ValueNotifier<int> revision = ValueNotifier(0);

  Future<void> _load() async {
    if (_chats != null) return;
    final c = <String>{};
    try {
      final p = await SharedPreferences.getInstance();
      final raw = p.getString(_k);
      if (raw != null) {
        final j = jsonDecode(raw) as Map;
        c.addAll(((j['c'] as List?) ?? const []).map((e) => '$e'));
        _salt = '${j['s'] ?? ''}';
        _hash = '${j['h'] ?? ''}';
      }
    } catch (_) {}
    _chats = c;
  }

  Future<void> _save() async {
    try {
      final p = await SharedPreferences.getInstance();
      await p.setString(
          _k, jsonEncode({'c': (_chats ?? {}).toList(), 's': _salt, 'h': _hash}));
    } catch (e) {
      reportNonFatal('e_lock_save', e);
    }
    revision.value++;
  }

  Future<void> warm() => _load();

  bool isLockedSync(String chatKey) => _chats?.contains(chatKey) ?? false;

  /// Straight from storage (reloads the plugin cache): the FCM background
  /// isolate keeps its own SharedPreferences copy, so a chat locked in the
  /// app a minute ago must still hide its notification. Never throws.
  static Future<bool> isLockedFresh(String chatKey) async {
    try {
      final p = await SharedPreferences.getInstance();
      await p.reload();
      final raw = p.getString(_k);
      if (raw == null) return false;
      final j = jsonDecode(raw) as Map;
      return ((j['c'] as List?) ?? const []).map((e) => '$e').contains(chatKey);
    } catch (_) {
      return false;
    }
  }

  Future<bool> isLocked(String chatKey) async {
    await _load();
    return _chats!.contains(chatKey);
  }

  Future<Set<String>> locked() async {
    await _load();
    return {..._chats!};
  }

  Future<bool> hasCode() async {
    await _load();
    return _hash.isNotEmpty;
  }

  static String hashCode_(String salt, String code) {
    List<int> d = utf8.encode('$salt|$code');
    for (var i = 0; i < _rounds; i++) {
      d = sha256.convert(d).bytes;
    }
    return base64Encode(d);
  }

  /// A valid code: 4–8 digits.
  static bool validCode(String code) => RegExp(r'^\d{4,8}$').hasMatch(code);

  Future<void> setCode(String code) async {
    await _load();
    final r = Random.secure();
    _salt = base64Encode(List<int>.generate(16, (_) => r.nextInt(256)));
    _hash = hashCode_(_salt, code);
    await _save();
  }

  Future<bool> verify(String code) async {
    await _load();
    if (_hash.isEmpty) return false;
    return hashCode_(_salt, code) == _hash;
  }

  Future<void> lock(String chatKey) async {
    await _load();
    if (_chats!.add(chatKey)) await _save();
  }

  Future<void> unlock(String chatKey) async {
    await _load();
    if (_chats!.remove(chatKey)) await _save();
  }

  /// Forgot the code: unlock everything + forget the code. Returns the chats
  /// that were locked (the caller clears them).
  Future<Set<String>> resetAll() async {
    await _load();
    final was = {..._chats!};
    _chats!.clear();
    _salt = '';
    _hash = '';
    await _save();
    return was;
  }

  /// Tests only.
  void resetForTest() {
    _chats = null;
    _salt = '';
    _hash = '';
  }
}

/// After a successful unlock the locked folder (and the chat opened from it)
/// stays open for a short while, so moving between the folder and a chat
/// doesn't ask again. Leaving the app ends it ([end]).
class ChatLockSession {
  ChatLockSession._();
  static DateTime? _until;
  static DateTime Function() clock = DateTime.now;
  static const window = Duration(minutes: 3);

  static bool get isOpen {
    final u = _until;
    return u != null && clock().isBefore(u);
  }

  static void open() => _until = clock().add(window);
  static void end() {
    _until = null;
    _chats.clear();
  }

  /// Locked chats unlocked on a screen that is still open (they stay
  /// readable there however long the person reads).
  static final Set<String> _chats = {};
  static void markChat(String chatKey) => _chats.add(chatKey);
  static void closeChat(String chatKey) => _chats.remove(chatKey);
  static bool isChatOpen(String chatKey) => isOpen || _chats.contains(chatKey);
}

/// Plugin seam: biometric. null = not available here (use the code).
typedef BiometricCheck = Future<bool?> Function(String reason);

class ChatLockAuth {
  ChatLockAuth._();

  static const MethodChannel _device = MethodChannel('com.assisto/device_admin');

  /// Tests swap this.
  static BiometricCheck biometric = _realBiometric;

  static Future<bool?> _realBiometric(String reason) async {
    try {
      // Android 8.x: androidx.biometric's own dialog needs an AppCompat
      // theme (see SecurityGuard) — use the code there.
      try {
        final m = await _device.invokeMethod<dynamic>('deviceInfo');
        if (m is Map && m['sdkInt'] is int && (m['sdkInt'] as int) < 28) return null;
      } catch (_) {}
      final auth = LocalAuthentication();
      if (!await auth.isDeviceSupported() || !await auth.canCheckBiometrics) return null;
      if ((await auth.getAvailableBiometrics()).isEmpty) return null;
      return await auth.authenticate(
        localizedReason: reason,
        options: const AuthenticationOptions(
            biometricOnly: true, stickyAuth: true, useErrorDialogs: true),
      );
    } catch (e) {
      reportNonFatal('e_lock_bio', e);
      return null; // plugin / ROM trouble: the code still works
    }
  }

  /// Unlock: biometric first (when the phone has one), else / on cancel the
  /// chat-lock code. True = the person proved it is them.
  static Future<bool> authenticate(BuildContext context) async {
    final t = AppLocalizations.of(context);
    final bio = await biometric(t.eLockBioReason);
    if (bio == true) {
      ChatLockSession.open();
      return true;
    }
    if (!context.mounted) return false;
    final ok = await _askCode(context);
    if (ok) ChatLockSession.open();
    return ok;
  }

  static Future<bool> _askCode(BuildContext context) async {
    if (!await ChatLockStore.instance.hasCode()) return false;
    if (!context.mounted) return false;
    final r = await showDialog<String>(
      context: context,
      builder: (ctx) => const _CodeDialog(),
    );
    if (r == _CodeDialog.forgot && context.mounted) {
      await _forgot(context);
      return false;
    }
    return r == _CodeDialog.ok;
  }

  /// Clears one chat's history for me on the server ("member:12" /
  /// "group:3"); set by the app (an ApiClient lives there).
  static Future<void> Function(String chatKey)? clearChat;

  /// Forgot the code: every locked chat is unlocked AND cleared (this
  /// person's view of it) — the only safe way without the code.
  static Future<void> _forgot(BuildContext context) async {
    final t = AppLocalizations.of(context);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        scrollable: true, // insets: 200% text / keyboard
        title: Text(t.eLockForgotTitle),
        content: Text(t.eLockForgotBody),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(t.cancel)),
          FilledButton(
              key: const Key('e-lock-forgot-ok'),
              style: FilledButton.styleFrom(
                  backgroundColor: Theme.of(ctx).colorScheme.error,
                  foregroundColor: Theme.of(ctx).colorScheme.onError),
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(t.eLockForgotConfirm)),
        ],
      ),
    );
    if (ok != true) return;
    final was = await ChatLockStore.instance.resetAll();
    final clear = clearChat;
    for (final k in was) {
      try {
        await clear?.call(k);
      } catch (e) {
        reportNonFatal('e_lock_forgot_clear', e);
      }
    }
    if (context.mounted) {
      ScaffoldMessenger.maybeOf(context)
          ?.showSnackBar(SnackBar(content: Text(t.eLockForgotDone)));
    }
  }

  /// First lock on this phone: choose + confirm the code. False = cancelled.
  static Future<bool> ensureCode(BuildContext context) async {
    if (await ChatLockStore.instance.hasCode()) return true;
    if (!context.mounted) return false;
    final code = await showDialog<String>(
      context: context,
      builder: (ctx) => const _SetCodeDialog(),
    );
    if (code == null) return false;
    await ChatLockStore.instance.setCode(code);
    return true;
  }
}

class _CodeDialog extends StatefulWidget {
  static const ok = 'ok';
  static const forgot = 'forgot';
  const _CodeDialog();
  @override
  State<_CodeDialog> createState() => _CodeDialogState();
}

class _CodeDialogState extends State<_CodeDialog> {
  final _c = TextEditingController();
  String _err = '';
  bool _busy = false;

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  Future<void> _check() async {
    if (_busy) return;
    setState(() => _busy = true);
    final ok = await ChatLockStore.instance.verify(_c.text.trim());
    if (!mounted) return;
    if (ok) {
      Navigator.pop(context, _CodeDialog.ok);
    } else {
      setState(() {
        _busy = false;
        _err = AppLocalizations.of(context).eLockWrongCode;
        _c.clear();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    return AlertDialog(
      title: Text(t.eLockEnterCode),
      content: Column(mainAxisSize: MainAxisSize.min, children: [
        ObscureTextField(
          key: const Key('e-lock-code'),
          controller: _c,
          keyboardType: TextInputType.number,
          autofocus: true,
          maxLength: 8,
          onSubmitted: (_) => _check(),
          decoration: InputDecoration(
              labelText: t.eLockCodeLabel, errorText: _err.isEmpty ? null : _err),
        ),
      ]),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(context, _CodeDialog.forgot),
            child: Text(t.eLockForgot)),
        TextButton(onPressed: () => Navigator.pop(context), child: Text(t.cancel)),
        FilledButton(
            key: const Key('e-lock-code-ok'),
            onPressed: _busy ? null : _check,
            child: Text(t.eLockUnlock)),
      ],
    );
  }
}

class _SetCodeDialog extends StatefulWidget {
  const _SetCodeDialog();
  @override
  State<_SetCodeDialog> createState() => _SetCodeDialogState();
}

class _SetCodeDialogState extends State<_SetCodeDialog> {
  final _a = TextEditingController();
  final _b = TextEditingController();
  String _err = '';

  @override
  void dispose() {
    _a.dispose();
    _b.dispose();
    super.dispose();
  }

  void _save() {
    final t = AppLocalizations.of(context);
    final a = _a.text.trim(), b = _b.text.trim();
    if (!ChatLockStore.validCode(a)) {
      setState(() => _err = t.eLockCodeRule);
      return;
    }
    if (a != b) {
      setState(() => _err = t.eLockCodeMismatch);
      return;
    }
    Navigator.pop(context, a);
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    return AlertDialog(
      title: Text(t.eLockSetCodeTitle),
      content: SingleChildScrollView(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Text(t.eLockSetCodeBody, style: Theme.of(context).textTheme.bodySmall),
          const SizedBox(height: Gap.sm),
          ObscureTextField(
            key: const Key('e-lock-new'),
            controller: _a,
            keyboardType: TextInputType.number,
            autofocus: true,
            maxLength: 8,
            decoration: InputDecoration(labelText: t.eLockCodeLabel),
          ),
          ObscureTextField(
            key: const Key('e-lock-confirm'),
            controller: _b,
            keyboardType: TextInputType.number,
            maxLength: 8,
            decoration: InputDecoration(
                labelText: t.eLockCodeConfirm, errorText: _err.isEmpty ? null : _err),
          ),
        ]),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: Text(t.cancel)),
        FilledButton(
            key: const Key('e-lock-new-ok'), onPressed: _save, child: Text(t.eLockSave)),
      ],
    );
  }
}

/// Lock / unlock one chat from its ⋮ menu. Returns the new locked state, or
/// null when nothing changed (cancelled / failed).
Future<bool?> toggleChatLock(BuildContext context, String chatKey) async {
  final t = AppLocalizations.of(context);
  final messenger = ScaffoldMessenger.maybeOf(context);
  final store = ChatLockStore.instance;
  if (await store.isLocked(chatKey)) {
    if (!context.mounted) return null;
    if (!await ChatLockAuth.authenticate(context)) return null;
    await store.unlock(chatKey);
    messenger?.showSnackBar(SnackBar(content: Text(t.eLockUnlocked)));
    return false;
  }
  if (!context.mounted) return null;
  if (!await ChatLockAuth.ensureCode(context)) return null;
  await store.lock(chatKey);
  ChatLockSession.open(); // the person just proved it: stay in the chat
  messenger?.showSnackBar(SnackBar(content: Text(t.eLockLocked)));
  return true;
}

/// Shows the lock in front of a locked chat opened from outside the folder.
class ChatLockGate extends StatefulWidget {
  final String chatKey;
  final Widget child;
  const ChatLockGate({super.key, required this.chatKey, required this.child});

  @override
  State<ChatLockGate> createState() => _ChatLockGateState();
}

class _ChatLockGateState extends State<ChatLockGate> {
  bool _open = false;
  bool _asked = false;
  AppLifecycleListener? _life;

  @override
  void initState() {
    super.initState();
    // leaving the app locks the chat again (asked once more on return)
    _life = AppLifecycleListener(
      onPause: () {
        ChatLockSession.end();
        if (mounted && ChatLockStore.instance.isLockedSync(widget.chatKey)) {
          setState(() => _open = false);
        }
      },
      onResume: () {
        if (mounted && !_open) _ask();
      },
    );
    _open = !ChatLockStore.instance.isLockedSync(widget.chatKey) || ChatLockSession.isOpen;
    if (ChatLockSession.isOpen) ChatLockSession.markChat(widget.chatKey);
    if (!_open) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _ask());
    } else {
      // the sync read may be early (first open after a cold start)
      unawaited(ChatLockStore.instance.isLocked(widget.chatKey).then((locked) {
        if (locked && !ChatLockSession.isOpen && mounted) {
          setState(() => _open = false);
          _ask();
        }
      }));
    }
  }

  @override
  void dispose() {
    _life?.dispose();
    ChatLockSession.closeChat(widget.chatKey);
    super.dispose();
  }

  Future<void> _ask() async {
    if (_asked || !mounted) return;
    _asked = true;
    final ok = await ChatLockAuth.authenticate(context);
    if (!mounted) return;
    if (ok) ChatLockSession.markChat(widget.chatKey);
    setState(() {
      _open = ok;
      _asked = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_open) return widget.child;
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(Gap.xl),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Icon(Icons.lock_outline_rounded, size: 56, color: scheme.primary),
            const SizedBox(height: Gap.md),
            Text(t.eLockGateTitle,
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: Gap.lg),
            FilledButton.icon(
              key: const Key('e-lock-gate-unlock'),
              onPressed: _ask,
              icon: const Icon(Icons.lock_open_rounded),
              label: Text(t.eLockUnlock),
            ),
          ]),
        ),
      ),
    );
  }
}
