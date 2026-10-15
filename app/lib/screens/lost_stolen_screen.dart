import 'dart:convert';
import 'dart:io' show Platform;
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:geolocator/geolocator.dart';
import 'package:provider/provider.dart';
import '../crypto/e2e.dart' show Pbkdf2;
import '../l10n/app_localizations.dart';
import '../state.dart';
import '../theme.dart';
import '../widgets/journey_api.dart';

/// #80 — Lost / stolen phone protection (device-admin).
///
/// HONESTY CONTRACT: the only source of truth for "is protection on?" is the
/// native DevicePolicyManager.isAdminActive() check, polled through the
/// MethodChannel on every build/resume. If device-admin is NOT granted the UI
/// shows every protection as INACTIVE with an Enable button. We never store or
/// trust a client-side "enabled" flag as if it were the real grant.
///
/// NATIVE CHANNEL: "com.assisto/device_admin" (see
/// android_overlay/.../MainActivity.kt + AssistoDeviceAdminReceiver.kt).
///   isAdminActive() -> bool
///   requestAdmin({explanation}) -> bool   // opens the system consent screen
///   lockNow() -> bool                      // requires active admin
///   startAlarm() -> bool / stopAlarm() -> bool
///   openAdminSettings() -> bool            // so the user can deactivate + uninstall
///
/// REUSE: last-location reporting reuses the SAME GPS + /journey/sos path the
/// SOS flow uses — Geolocator.getCurrentPosition() exactly as in
/// journey_sos_screen.dart (_position) + ApiClient.journeySos (journey_api.dart).
/// No new GPS code and no duplicate endpoint.
///
/// RECOVERY PIN: hashed locally with PBKDF2-HMAC-SHA256 (crypto/e2e.dart) +
/// a random salt; only salt+hash are persisted (flutter_secure_storage). The
/// raw PIN never leaves the device and is never stored in clear.
class LostStolenScreen extends StatefulWidget {
  const LostStolenScreen({super.key});

  @override
  State<LostStolenScreen> createState() => _LostStolenScreenState();
}

class _LostStolenScreenState extends State<LostStolenScreen>
    with WidgetsBindingObserver {
  static const _channel = MethodChannel('com.assisto/device_admin');
  static const _secure = FlutterSecureStorage();

  // Settings keys (SharedPreferences via Settings helper).
  static const _kLock = 'ls_action_lock';
  static const _kAlarm = 'ls_action_alarm';
  static const _kMessage = 'ls_action_message';
  static const _kLocate = 'ls_action_locate';
  static const _kSmsSeam = 'ls_sms_trigger'; // gated seam, off by default
  static const _kOwnerName = 'ls_owner_name';
  static const _kOwnerPhone = 'ls_owner_phone';
  static const _kLostMsg = 'ls_lost_message';
  // Secure-storage keys for the recovery PIN.
  static const _kPinSalt = 'ls_pin_salt';
  static const _kPinHash = 'ls_pin_hash';

  bool _loading = true;
  bool _adminActive = false; // THE source of truth (native)
  bool _hasPin = false;

  bool _lock = true;
  bool _alarm = true;
  bool _message = true;
  bool _locate = true;
  bool _smsSeam = false;

  String _ownerName = '';
  String _ownerPhone = '';
  String _lostMsg = '';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _load();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Re-poll native grant whenever we come back (e.g. from the consent screen
    // or from Settings after a deactivation) so the UI stays honest.
    if (state == AppLifecycleState.resumed) _refreshAdmin();
  }

  Future<void> _load() async {
    _lock = await Settings.getBool(_kLock, true);
    _alarm = await Settings.getBool(_kAlarm, true);
    _message = await Settings.getBool(_kMessage, true);
    _locate = await Settings.getBool(_kLocate, true);
    _smsSeam = await Settings.getBool(_kSmsSeam, false);
    _ownerName = await Settings.getString(_kOwnerName) ?? '';
    _ownerPhone = await Settings.getString(_kOwnerPhone) ?? '';
    _lostMsg = await Settings.getString(_kLostMsg) ?? '';
    _hasPin = await _readPinHash() != null;
    await _refreshAdmin();
    if (mounted) setState(() => _loading = false);
  }

  // ---- native bridge (honest, every call guarded) -----------------------

  Future<void> _refreshAdmin() async {
    // iOS: device-admin does not exist. Never touch the MethodChannel — just
    // report INACTIVE so the honest iOS state renders. (build() also returns an
    // Android-only screen on iOS, but this keeps the native call from firing.)
    if (Platform.isIOS) {
      if (mounted) setState(() => _adminActive = false);
      return;
    }
    bool active = false;
    try {
      active = await _channel.invokeMethod<bool>('isAdminActive') ?? false;
    } on PlatformException {
      active = false; // channel/plugin not present -> treat as INACTIVE
    } on MissingPluginException {
      active = false;
    }
    if (mounted) setState(() => _adminActive = active);
  }

  Future<void> _enable() async {
    if (Platform.isIOS) return; // no device-admin on iOS
    final tr = AppLocalizations.of(context);
    try {
      await _channel.invokeMethod<bool>(
        'requestAdmin',
        {'explanation': tr.lostStolenConsentExplain},
      );
    } on PlatformException {
      // fall through — _refreshAdmin will report the real state
    } on MissingPluginException {
      if (mounted) _snack(tr.lostStolenNativeMissing);
    }
    await _refreshAdmin();
  }

  Future<void> _openAdminSettings() async {
    if (Platform.isIOS) return; // no device-admin on iOS
    final tr = AppLocalizations.of(context);
    // If a recovery PIN is set, require it before exposing the deactivation
    // path (a thief shouldn't be able to turn protection off casually). This is
    // a deterrent, NOT a hard lock: the OS always lets the true owner reach
    // Settings → Device admin directly — so we never claim it's unbreakable.
    if (_hasPin) {
      final entered = await _askPin(tr);
      if (entered == null) return;
      if (!await _verifyPin(entered)) {
        if (mounted) _snack(tr.lostStolenPinWrong);
        return;
      }
    }
    try {
      await _channel.invokeMethod('openAdminSettings');
    } on PlatformException {
      /* ignore */
    } on MissingPluginException {
      /* ignore */
    }
  }

  Future<void> _testLock() async {
    if (Platform.isIOS) return; // no device-admin on iOS
    final tr = AppLocalizations.of(context);
    if (!_adminActive) return;
    bool ok = false;
    try {
      ok = await _channel.invokeMethod<bool>('lockNow') ?? false;
    } catch (_) {
      ok = false;
    }
    if (mounted) _snack(ok ? tr.lostStolenLockSent : tr.lostStolenActionFailed);
  }

  Future<void> _testAlarm() async {
    if (Platform.isIOS) return; // native alarm receiver is Android-only
    final tr = AppLocalizations.of(context);
    bool ok = false;
    try {
      ok = await _channel.invokeMethod<bool>('startAlarm') ?? false;
    } catch (_) {
      ok = false;
    }
    if (!mounted) return;
    if (!ok) {
      _snack(tr.lostStolenActionFailed);
      return;
    }
    // Let the user stop the test alarm.
    final stop = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        title: Text(tr.lostStolenAlarmPlaying),
        content: Text(tr.lostStolenAlarmPlayingBody),
        actions: [
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(tr.lostStolenStopAlarm),
          ),
        ],
      ),
    );
    if (stop == true) {
      try {
        await _channel.invokeMethod('stopAlarm');
      } catch (_) {/* ignore */}
    }
  }

  /// REUSE of the SOS GPS path: identical Geolocator flow as
  /// journey_sos_screen.dart `_position`, then the SAME ApiClient.journeySos
  /// endpoint to report last location. No duplication of GPS or transport.
  Future<void> _reportLocation() async {
    final tr = AppLocalizations.of(context);
    final pos = await _position();
    if (pos == null) {
      if (mounted) _snack(tr.lostStolenNoLocation);
      return;
    }
    final api = context.read<AppState>().api;
    bool ok = true;
    try {
      await api.journeySos(
        lat: pos.latitude,
        lng: pos.longitude,
        silent: true, // reporting a lost device, not firing a panic UI
        siren: false,
      );
    } catch (_) {
      ok = false; // server queues/retries; still show an honest message
    }
    if (mounted) {
      _snack(ok ? tr.lostStolenLocationSent : tr.lostStolenLocationQueued);
    }
  }

  /// Identical to journey_sos_screen.dart `_position` — shared GPS behaviour.
  Future<Position?> _position() async {
    try {
      if (!await Geolocator.isLocationServiceEnabled()) return null;
      var perm = await Geolocator.checkPermission();
      if (perm == LocationPermission.denied) {
        perm = await Geolocator.requestPermission();
      }
      if (perm == LocationPermission.denied ||
          perm == LocationPermission.deniedForever) {
        return null;
      }
      return await Geolocator.getCurrentPosition();
    } catch (_) {
      return null;
    }
  }

  // ---- recovery PIN (PBKDF2-hashed, raw never stored) --------------------

  Future<String?> _readPinHash() async {
    return _secure.read(key: _kPinHash);
  }

  Future<void> _setPin() async {
    final tr = AppLocalizations.of(context);
    final pin = await _askPin(tr, confirm: true);
    if (pin == null || pin.isEmpty) return;
    final rng = Random.secure();
    final salt =
        Uint8List.fromList(List<int>.generate(16, (_) => rng.nextInt(256)));
    final hash = Pbkdf2.derive(utf8.encode(pin), salt, 20000, 32);
    await _secure.write(key: _kPinSalt, value: base64Encode(salt));
    await _secure.write(key: _kPinHash, value: base64Encode(hash));
    if (mounted) {
      setState(() => _hasPin = true);
      _snack(tr.lostStolenPinSaved);
    }
  }

  Future<bool> _verifyPin(String entered) async {
    final saltB = await _secure.read(key: _kPinSalt);
    final hashB = await _secure.read(key: _kPinHash);
    if (saltB == null || hashB == null) return false;
    final salt = base64Decode(saltB);
    final got = Pbkdf2.derive(utf8.encode(entered), salt, 20000, 32);
    final want = base64Decode(hashB);
    if (got.length != want.length) return false;
    var diff = 0;
    for (var i = 0; i < got.length; i++) {
      diff |= got[i] ^ want[i];
    }
    return diff == 0;
  }

  Future<String?> _askPin(AppLocalizations tr, {bool confirm = false}) async {
    final c1 = TextEditingController();
    final c2 = TextEditingController();
    String? error;
    return showDialog<String>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setD) => AlertDialog(
          title: Text(tr.lostStolenRecoveryPin),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(tr.lostStolenPinHint,
                  style: Theme.of(ctx).textTheme.bodySmall),
              const SizedBox(height: Gap.sm),
              TextField(
                controller: c1,
                keyboardType: TextInputType.number,
                obscureText: true,
                maxLength: 8,
                decoration: InputDecoration(labelText: tr.lostStolenPinLabel),
              ),
              if (confirm)
                TextField(
                  controller: c2,
                  keyboardType: TextInputType.number,
                  obscureText: true,
                  maxLength: 8,
                  decoration:
                      InputDecoration(labelText: tr.lostStolenPinConfirmLabel),
                ),
              if (error != null)
                Padding(
                  padding: const EdgeInsets.only(top: Gap.xs),
                  child: Text(error!,
                      style: TextStyle(color: Theme.of(ctx).colorScheme.error)),
                ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: Text(tr.cancel),
            ),
            FilledButton(
              onPressed: () {
                final v = c1.text.trim();
                if (v.length < 4) {
                  setD(() => error = tr.lostStolenPinTooShort);
                  return;
                }
                if (confirm && v != c2.text.trim()) {
                  setD(() => error = tr.lostStolenPinMismatch);
                  return;
                }
                Navigator.pop(ctx, v);
              },
              child: Text(tr.save),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _editOwnerContact() async {
    final tr = AppLocalizations.of(context);
    final nameC = TextEditingController(text: _ownerName);
    final phoneC = TextEditingController(text: _ownerPhone);
    final msgC = TextEditingController(text: _lostMsg);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(tr.lostStolenLostMessage),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: nameC,
                decoration: InputDecoration(labelText: tr.lostStolenOwnerName),
              ),
              TextField(
                controller: phoneC,
                keyboardType: TextInputType.phone,
                decoration: InputDecoration(labelText: tr.lostStolenOwnerPhone),
              ),
              TextField(
                controller: msgC,
                maxLines: 3,
                decoration:
                    InputDecoration(labelText: tr.lostStolenMessageLabel),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(tr.cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(tr.save),
          ),
        ],
      ),
    );
    if (ok == true) {
      _ownerName = nameC.text.trim();
      _ownerPhone = phoneC.text.trim();
      _lostMsg = msgC.text.trim();
      await Settings.setString(_kOwnerName, _ownerName);
      await Settings.setString(_kOwnerPhone, _ownerPhone);
      await Settings.setString(_kLostMsg, _lostMsg);
      if (mounted) setState(() {});
    }
  }

  void _snack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(SnackBar(content: Text(msg)));
  }

  @override
  Widget build(BuildContext context) {
    final tr = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    // iOS: device-admin (remote lock / alarm / uninstall-resistance) is an
    // Android-only capability. Show an honest "Android-only" state instead of a
    // dead toggle UI. The native MethodChannel is never touched on iOS.
    if (Platform.isIOS) {
      return Scaffold(
        appBar: AppBar(title: Text(tr.lostStolenTitle)),
        body: _iosOnly(tr, scheme),
      );
    }
    return Scaffold(
      appBar: AppBar(title: Text(tr.lostStolenTitle)),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(Gap.md),
              children: [
                _statusBanner(tr, scheme),
                const SizedBox(height: Gap.md),
                _intro(tr, scheme),
                const SizedBox(height: Gap.md),
                _recoveryPinCard(tr, scheme),
                const SizedBox(height: Gap.md),
                _actionsCard(tr, scheme),
                const SizedBox(height: Gap.md),
                _lostMessageCard(tr, scheme),
                const SizedBox(height: Gap.md),
                _triggersCard(tr, scheme),
                const SizedBox(height: Gap.md),
                _uninstallCard(tr, scheme),
                const SizedBox(height: Gap.xl),
              ],
            ),
    );
  }

  /// Honest iOS state: this protection is Android-only for now.
  Widget _iosOnly(AppLocalizations tr, ColorScheme scheme) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(Gap.lg),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.phonelink_lock_outlined,
                size: 56, color: scheme.onSurfaceVariant),
            const SizedBox(height: Gap.md),
            Text(
              tr.iosAndroidOnlyTitle,
              textAlign: TextAlign.center,
              style: Theme.of(context)
                  .textTheme
                  .titleLarge
                  ?.copyWith(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: Gap.sm),
            Text(
              tr.lostStolenIosOnlyBody,
              textAlign: TextAlign.center,
              style: Theme.of(context)
                  .textTheme
                  .bodyMedium
                  ?.copyWith(color: scheme.onSurfaceVariant, height: 1.4),
            ),
          ],
        ),
      ),
    );
  }

  Widget _statusBanner(AppLocalizations tr, ColorScheme scheme) {
    final active = _adminActive;
    final bg = active
        ? Brand.success.withValues(alpha: 0.12)
        : Brand.warning.withValues(alpha: 0.14);
    final fg = active ? Brand.success : Brand.warning;
    return Card(
      color: bg,
      child: Padding(
        padding: const EdgeInsets.all(Gap.md),
        child: Row(
          children: [
            Icon(active ? Icons.verified_user : Icons.gpp_maybe,
                color: fg, size: 32),
            const SizedBox(width: Gap.sm),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    active
                        ? tr.lostStolenStateActive
                        : tr.lostStolenStateInactive,
                    style: Theme.of(context)
                        .textTheme
                        .titleMedium
                        ?.copyWith(color: fg, fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    active
                        ? tr.lostStolenStateActiveBody
                        : tr.lostStolenStateInactiveBody,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
              ),
            ),
            if (!active)
              FilledButton(
                onPressed: _enable,
                child: Text(tr.lostStolenEnable),
              )
            else
              TextButton(
                onPressed: _openAdminSettings,
                child: Text(tr.lostStolenManage),
              ),
          ],
        ),
      ),
    );
  }

  Widget _intro(AppLocalizations tr, ColorScheme scheme) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(Gap.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(tr.lostStolenIntroTitle,
                style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: Gap.xs),
            Text(tr.lostStolenIntroBody,
                style: Theme.of(context).textTheme.bodyMedium),
            const SizedBox(height: Gap.sm),
            _bullet(tr.lostStolenBulletLock),
            _bullet(tr.lostStolenBulletAlarm),
            _bullet(tr.lostStolenBulletLocate),
            _bullet(tr.lostStolenBulletMessage),
            const SizedBox(height: Gap.xs),
            Text(tr.lostStolenPrivacyNote,
                style: Theme.of(context).textTheme.bodySmall),
          ],
        ),
      ),
    );
  }

  Widget _bullet(String text) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('•  '),
            Expanded(child: Text(text)),
          ],
        ),
      );

  Widget _recoveryPinCard(AppLocalizations tr, ColorScheme scheme) {
    return Card(
      child: ListTile(
        leading: const Icon(Icons.pin),
        title: Text(tr.lostStolenRecoveryPin),
        subtitle: Text(
            _hasPin ? tr.lostStolenPinSet : tr.lostStolenPinNotSet),
        trailing: TextButton(
          onPressed: _setPin,
          child: Text(_hasPin ? tr.lostStolenPinChange : tr.safetyCheckinSet),
        ),
      ),
    );
  }

  Widget _actionsCard(AppLocalizations tr, ColorScheme scheme) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(Gap.sm),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(Gap.sm, Gap.sm, Gap.sm, 0),
              child: Text(tr.lostStolenActionsTitle,
                  style: Theme.of(context).textTheme.titleMedium),
            ),
            SwitchListTile(
              value: _lock,
              title: Text(tr.lostStolenActionLock),
              subtitle: Text(_adminActive
                  ? tr.lostStolenActionLockOk
                  : tr.lostStolenNeedsAdmin),
              onChanged: (v) async {
                setState(() => _lock = v);
                await Settings.setBool(_kLock, v);
              },
            ),
            if (_lock && _adminActive)
              Padding(
                padding: const EdgeInsets.fromLTRB(Gap.md, 0, Gap.md, Gap.sm),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: OutlinedButton.icon(
                    icon: const Icon(Icons.lock_outline),
                    label: Text(tr.lostStolenTestLock),
                    onPressed: _testLock,
                  ),
                ),
              ),
            SwitchListTile(
              value: _alarm,
              title: Text(tr.lostStolenActionAlarm),
              subtitle: Text(tr.lostStolenActionAlarmBody),
              onChanged: (v) async {
                setState(() => _alarm = v);
                await Settings.setBool(_kAlarm, v);
              },
            ),
            if (_alarm)
              Padding(
                padding: const EdgeInsets.fromLTRB(Gap.md, 0, Gap.md, Gap.sm),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: OutlinedButton.icon(
                    icon: const Icon(Icons.volume_up),
                    label: Text(tr.lostStolenTestAlarm),
                    onPressed: _testAlarm,
                  ),
                ),
              ),
            SwitchListTile(
              value: _locate,
              title: Text(tr.lostStolenActionLocate),
              subtitle: Text(tr.lostStolenActionLocateBody),
              onChanged: (v) async {
                setState(() => _locate = v);
                await Settings.setBool(_kLocate, v);
              },
            ),
            if (_locate)
              Padding(
                padding: const EdgeInsets.fromLTRB(Gap.md, 0, Gap.md, Gap.sm),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: OutlinedButton.icon(
                    icon: const Icon(Icons.my_location),
                    label: Text(tr.lostStolenReportNow),
                    onPressed: _reportLocation,
                  ),
                ),
              ),
            SwitchListTile(
              value: _message,
              title: Text(tr.lostStolenActionMessage),
              subtitle: Text(tr.lostStolenActionMessageBody),
              onChanged: (v) async {
                setState(() => _message = v);
                await Settings.setBool(_kMessage, v);
              },
            ),
          ],
        ),
      ),
    );
  }

  Widget _lostMessageCard(AppLocalizations tr, ColorScheme scheme) {
    final hasContact = _ownerPhone.isNotEmpty || _lostMsg.isNotEmpty;
    return Card(
      child: ListTile(
        leading: const Icon(Icons.contact_phone_outlined),
        title: Text(tr.lostStolenLostMessage),
        subtitle: Text(hasContact
            ? [
                if (_ownerName.isNotEmpty) _ownerName,
                if (_ownerPhone.isNotEmpty) _ownerPhone,
              ].join(' · ')
            : tr.lostStolenLostMessageEmpty),
        trailing: TextButton(
          onPressed: _editOwnerContact,
          child: Text(tr.edit),
        ),
      ),
    );
  }

  Widget _triggersCard(AppLocalizations tr, ColorScheme scheme) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(Gap.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(tr.lostStolenTriggersTitle,
                style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: Gap.xs),
            Text(tr.lostStolenTriggersBody,
                style: Theme.of(context).textTheme.bodySmall),
            const SizedBox(height: Gap.sm),
            // SMS-command trigger is a SEAM: it needs a separate native SMS
            // BroadcastReceiver (RECEIVE_SMS). That receiver is NOT shipped in
            // this build, so the toggle is honestly marked "coming soon" and
            // disabled — never pretend remote SMS control is live.
            SwitchListTile(
              value: _smsSeam,
              title: Text(tr.lostStolenSmsTrigger),
              subtitle: Text(tr.lostStolenSmsTriggerSoon),
              onChanged: null, // gated: native SMS receiver not shipped yet
            ),
          ],
        ),
      ),
    );
  }

  Widget _uninstallCard(AppLocalizations tr, ColorScheme scheme) {
    return Card(
      color: scheme.surfaceContainerHighest,
      child: Padding(
        padding: const EdgeInsets.all(Gap.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.shield_outlined, size: 20),
                const SizedBox(width: Gap.xs),
                Text(tr.lostStolenUninstallTitle,
                    style: Theme.of(context).textTheme.titleSmall),
              ],
            ),
            const SizedBox(height: Gap.xs),
            Text(tr.lostStolenUninstallBody,
                style: Theme.of(context).textTheme.bodySmall),
          ],
        ),
      ),
    );
  }
}
