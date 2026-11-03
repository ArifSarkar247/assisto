// p3docs — "End-to-end lock" for the Documents vault (flag vault_e2e).
//
// Switch on (PIN + plain-words warning + recovery code), fingerprint wrap,
// recovery code saved sealed on the server, trusted people from My Circle,
// unlock on a new phone (recovery code / trusted person + 24 h wait), and the
// helper's side (approve after matching the code on a call). The crypto lives
// in vault_e2e.dart; nothing secret leaves the phone.
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../crypto/e2e.dart' show IdentityKeyPair;
import '../crypto/key_service.dart' show KeyService;
import '../l10n/app_localizations.dart';
import '../messaging/chat_lock.dart' show ChatLockAuth;
import '../theme.dart' show AType, Gap, Radii;
import '../widgets/app_sheet.dart' show withNavBarInset;
import '../widgets/ladder_common.dart' show fmtInt;
import '../widgets/rn_bits.dart' show pickCircleMember;
import 'vault_e2e.dart';
import 'vault_e2e_api.dart';
import 'vault_lock.dart';
import 'vault_security_screen.dart' show showVaultRecoveryCode;

class VaultE2EScreen extends StatefulWidget {
  final VaultLock lock;
  final VaultE2EBackend backend;
  final VaultE2E? keyring;
  const VaultE2EScreen({super.key, required this.lock, required this.backend, this.keyring});

  @override
  State<VaultE2EScreen> createState() => _VaultE2EScreenState();
}

class _VaultE2EScreenState extends State<VaultE2EScreen> {
  VaultE2E get _k => widget.keyring ?? VaultE2E.instance;
  bool _loading = true;
  bool _failed = false;
  bool _busy = false;
  bool _setUp = false;
  bool _bio = false;
  Map<String, dynamic> _state = const {};
  Map<String, dynamic>? _request;
  List<Map<String, dynamic>> _inbox = const [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _failed = false;
    });
    final setUp = await _k.isSetUp();
    final bio = await _k.hasBioWrap();
    try {
      final s = await widget.backend.state();
      final inbox = await widget.backend.helpInbox();
      final req = await widget.backend.helpRequest();
      _state = s;
      _inbox = inbox;
      _request = req;
      if (req != null && req['ready'] == true && !_k.unlocked) await _finishHelp(req);
    } catch (_) {
      _failed = true;
    }
    if (!mounted) return;
    setState(() {
      _setUp = setUp;
      _bio = bio;
      _loading = false;
    });
  }

  void _snack(String s) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(s)));
  }

  int get _sealedDocs => (_state['sealed_docs'] as num?)?.toInt() ?? 0;
  bool get _hasServerRecovery => _state['recovery_wrap'] == true;
  List<Map<String, dynamic>> get _helpers =>
      ((_state['helpers'] as List?) ?? const []).whereType<Map>()
          .map((m) => m.cast<String, dynamic>()).toList();

  // ------------------------------------------------------------ PIN prompt
  Future<String?> _askPin() async {
    final t = AppLocalizations.of(context);
    final ctrl = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        scrollable: true,
        title: Text(t.vaultE2eEnterPin),
        content: TextField(
          key: const Key('e2e_pin'),
          controller: ctrl,
          autofocus: true,
          obscureText: true,
          keyboardType: TextInputType.number,
          onSubmitted: (_) => Navigator.pop(ctx, true),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(t.cancel)),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(t.ok)),
        ],
      ),
    );
    final pin = ctrl.text.trim();
    if (ok != true || pin.isEmpty) return null;
    final r = await widget.lock.check(pin);
    if (r != PinCheck.ok) {
      _snack(t.vaultE2eWrongPin);
      return null;
    }
    return pin;
  }

  // ------------------------------------------------------------ switch on
  Future<void> _turnOn() async {
    final t = AppLocalizations.of(context);
    var understood = false;
    final go = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setD) => AlertDialog(
          scrollable: true,
          title: Text(t.vaultE2eTurnOn),
          content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(t.vaultE2eServerSees),
            const SizedBox(height: Gap.md),
            Text(t.vaultE2eLossWarning, style: AType.bodyMedium.copyWith(fontWeight: FontWeight.w700)),
            const SizedBox(height: Gap.sm),
            CheckboxListTile(
              key: const Key('e2e_understand'),
              contentPadding: EdgeInsets.zero,
              value: understood,
              onChanged: (v) => setD(() => understood = v == true),
              title: Text(t.vaultE2eUnderstand),
            ),
          ]),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(t.cancel)),
            FilledButton(
                onPressed: understood ? () => Navigator.pop(ctx, true) : null,
                child: Text(t.vaultE2eTurnOn)),
          ],
        ),
      ),
    );
    if (go != true || !mounted) return;
    final pin = await _askPin();
    if (pin == null || !mounted) return;
    setState(() => _busy = true);
    try {
      final r = await _k.setUp(pin);
      await widget.lock.setRecoveryCode(r.code); // ONE code for PIN reset + documents
      await widget.backend.putRecovery(r.recoveryWrap);
      if (!mounted) return;
      await showVaultRecoveryCode(context, r.code);
    } catch (_) {
      _snack(t.vaultE2eFailed);
    }
    if (mounted) setState(() => _busy = false);
    _load();
  }

  Future<void> _newCode() async {
    final t = AppLocalizations.of(context);
    if (!_k.unlocked) {
      _snack(t.vaultE2eLockedOpen);
      return;
    }
    setState(() => _busy = true);
    try {
      final r = await _k.newRecovery();
      await widget.lock.setRecoveryCode(r.code);
      await widget.backend.putRecovery(r.recoveryWrap);
      if (mounted) await showVaultRecoveryCode(context, r.code);
    } catch (_) {
      _snack(t.vaultE2eFailed);
    }
    if (mounted) setState(() => _busy = false);
    _load();
  }

  Future<void> _toggleBio(bool on) async {
    final t = AppLocalizations.of(context);
    if (on) {
      if (!_k.unlocked) {
        _snack(t.vaultE2eLockedOpen);
        return;
      }
      final ok = await ChatLockAuth.biometric(t.vaultBioReason);
      if (ok != true) {
        _snack(ok == null ? t.vaultBioUnavailable : t.vaultBioNotConfirmed);
        return;
      }
      await widget.lock.setBiometric(true);
    }
    try {
      await _k.enableBio(on);
    } catch (_) {
      _snack(t.vaultE2eFailed);
    }
    final has = await _k.hasBioWrap();
    if (mounted) setState(() => _bio = has);
  }

  // ------------------------------------------------------------ unlock
  Future<void> _unlockWithCode() async {
    final t = AppLocalizations.of(context);
    final ctrl = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        scrollable: true,
        title: Text(t.vaultE2eUnlockCode),
        content: TextField(
          key: const Key('e2e_code'),
          controller: ctrl,
          autofocus: true,
          textCapitalization: TextCapitalization.characters,
          decoration: InputDecoration(labelText: t.vaultE2eCodeHint),
          onSubmitted: (_) => Navigator.pop(ctx, true),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(t.cancel)),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(t.vaultE2eUnlockCode)),
        ],
      ),
    );
    final code = ctrl.text;
    if (ok != true || code.trim().isEmpty || !mounted) return;
    setState(() => _busy = true);
    try {
      final wrap = await widget.backend.getRecovery();
      final dmk = wrap == null ? null : await _k.openRecovery(wrap, code);
      if (dmk == null) {
        _snack(t.vaultE2eCodeWrong);
      } else {
        await _adopt(dmk);
        await _k.wrapForCode(code);
        await widget.lock.setRecoveryCode(code);
      }
    } catch (_) {
      _snack(t.vaultE2eFailed);
    }
    if (mounted) setState(() => _busy = false);
    _load();
  }

  /// A recovered key becomes this phone's key under the vault PIN.
  Future<void> _adopt(Uint8List dmk) async {
    final t = AppLocalizations.of(context);
    final pin = await _askPin();
    if (pin == null) return;
    await _k.adopt(dmk, pin);
    _snack(t.vaultE2eUnlocked);
  }

  Future<void> _askHelper(Map<String, dynamic> helper) async {
    final t = AppLocalizations.of(context);
    setState(() => _busy = true);
    try {
      final me = await KeyService.instance.identity();
      final r = await widget.backend.requestHelp(
          (helper['id'] as num).toInt(), me.publicKeyB64, me.keyId);
      if ((r['_status'] as num? ?? 200) >= 300) {
        _snack('${r['detail'] ?? t.vaultE2eFailed}');
      }
    } catch (_) {
      _snack(t.vaultE2eFailed);
    }
    if (mounted) setState(() => _busy = false);
    _load();
  }

  Future<void> _finishHelp(Map<String, dynamic> req) async {
    final hb = req['handback'];
    if (hb is! String) return;
    final me = await KeyService.instance.identity();
    final dmk = VaultE2E.openFromPublicKey(hb, me);
    if (dmk == null || !mounted) return;
    await _adopt(dmk);
  }

  Future<void> _cancelHelp() async {
    try {
      await widget.backend.cancelHelp();
    } catch (_) {}
    _load();
  }

  // ------------------------------------------------------------ helpers
  Future<void> _addHelper() async {
    final t = AppLocalizations.of(context);
    final row = await pickCircleMember(context, title: t.vaultE2eAddHelper, subtitle: t.vaultE2eHelpersSub);
    if (row == null || !mounted) return;
    final mid = (row['circle_id'] as num?)?.toInt();
    if (mid == null) return;
    setState(() => _busy = true);
    try {
      final k = await widget.backend.peerKey(mid);
      final pubB64 = '${k['public_key'] ?? ''}';
      if (pubB64.isEmpty) {
        _snack(t.vaultE2eNoKeyYet);
      } else {
        final wrap = _k.sealForHelper(Uint8List.fromList(base64Decode(pubB64)),
            kid: '${k['key_id'] ?? ''}');
        final r = await widget.backend.addHelper(mid, wrap, '${k['key_id'] ?? ''}');
        final st = (r['_status'] as num?)?.toInt() ?? 200;
        if (st == 409) {
          _snack(t.vaultE2eNoKeyYet);
        } else if (st >= 300) {
          _snack('${r['detail'] ?? t.vaultE2eFailed}');
        }
      }
    } catch (_) {
      _snack(t.vaultE2eFailed);
    }
    if (mounted) setState(() => _busy = false);
    _load();
  }

  Future<void> _removeHelper(Map<String, dynamic> h) async {
    try {
      await widget.backend.deleteHelper((h['id'] as num).toInt());
    } catch (_) {
      _snack(AppLocalizations.of(context).vaultE2eFailed);
    }
    _load();
  }

  Future<void> _decide(Map<String, dynamic> req, bool approve) async {
    final t = AppLocalizations.of(context);
    setState(() => _busy = true);
    try {
      String? wrap;
      if (approve) {
        final me = await KeyService.instance.identity();
        final dmk = VaultE2E.openFromPublicKey('${req['wrap']}', me);
        if (dmk == null) throw StateError('wrap');
        final pub = base64Decode('${req['requester_pub']}');
        wrap = VaultE2E.sealToPublicKey(dmk, Uint8List.fromList(pub));
        dmk.fillRange(0, dmk.length, 0); // never kept on the helper's phone
      }
      final r = await widget.backend.decideHelp((req['id'] as num).toInt(), approve: approve, wrap: wrap);
      if ((r['_status'] as num? ?? 200) < 300 && approve) _snack(t.vaultE2eApproved);
    } catch (_) {
      _snack(t.vaultE2eFailed);
    }
    if (mounted) setState(() => _busy = false);
    _load();
  }

  // ------------------------------------------------------------ UI
  String _when(String? iso) {
    final d = iso == null ? null : DateTime.tryParse(iso)?.toLocal();
    if (d == null) return '';
    return DateFormat('d MMM, h:mm a', Localizations.localeOf(context).languageCode).format(d);
  }

  Widget _section(String s) => Padding(
        padding: const EdgeInsets.fromLTRB(0, Gap.lg, 0, Gap.xs),
        child: Text(s, style: AType.titleSmall.copyWith(fontWeight: FontWeight.w700)),
      );

  Widget _infoCard(BuildContext context, String text, {IconData icon = Icons.info_outline_rounded, bool strong = false}) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(Gap.md),
      decoration: BoxDecoration(
        color: strong ? cs.errorContainer : cs.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(Radii.sm),
      ),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Icon(icon, color: strong ? cs.onErrorContainer : cs.onSurfaceVariant),
        const SizedBox(width: Gap.sm),
        Expanded(
            child: Text(text,
                style: AType.bodyMedium.copyWith(color: strong ? cs.onErrorContainer : cs.onSurfaceVariant))),
      ]),
    );
  }

  Widget _bigButton(Key key, IconData icon, String label, VoidCallback? onTap, {bool tonal = false}) {
    final child = tonal
        ? FilledButton.tonalIcon(key: key, onPressed: onTap, icon: Icon(icon), label: Text(label))
        : FilledButton.icon(key: key, onPressed: onTap, icon: Icon(icon), label: Text(label));
    return Padding(
      padding: const EdgeInsets.only(top: Gap.sm),
      child: SizedBox(width: double.infinity, child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 48), child: child)),
    );
  }

  List<Widget> _inboxCards(AppLocalizations t) => [
        for (final r in _inbox)
          Card(
            key: Key('e2e_inbox_${r['id']}'),
            child: Padding(
              padding: const EdgeInsets.all(Gap.md),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(t.vaultE2eInboxTitle('${r['owner_name'] ?? ''}'),
                    style: AType.titleSmall.copyWith(fontWeight: FontWeight.w700)),
                const SizedBox(height: Gap.xs),
                Text(t.vaultE2eInboxBody(_matchFor('${r['requester_pub'] ?? ''}'))),
                Wrap(spacing: Gap.sm, children: [
                  FilledButton(
                      key: Key('e2e_approve_${r['id']}'),
                      onPressed: _busy ? null : () => _decide(r, true),
                      child: Text(t.vaultE2eApprove)),
                  OutlinedButton(
                      onPressed: _busy ? null : () => _decide(r, false),
                      child: Text(t.vaultE2eDecline)),
                ]),
              ]),
            ),
          ),
      ];

  String _matchFor(String pubB64) {
    try {
      return _localDigits(VaultE2E.matchCode(Uint8List.fromList(base64Decode(pubB64))));
    } catch (_) {
      return '—';
    }
  }

  String _localDigits(String s) {
    if (Localizations.localeOf(context).languageCode != 'bn') return s;
    const bn = '০১২৩৪৫৬৭৮৯';
    return s.split('').map((c) {
      final d = int.tryParse(c);
      return d == null ? c : bn[d];
    }).join();
  }

  Widget? _requestCard(AppLocalizations t) {
    final r = _request;
    if (r == null) return null;
    final st = '${r['state']}';
    final name = '${r['helper_name'] ?? ''}';
    String text;
    switch (st) {
      case 'pending':
        text = t.vaultE2eRequestPending(name);
      case 'approved':
        text = t.vaultE2eRequestWait(_when(r['ready_at'] as String?));
      case 'declined':
        text = t.vaultE2eRequestDeclined(name);
      default:
        return null;
    }
    return Card(
      key: const Key('e2e_request'),
      child: Padding(
        padding: const EdgeInsets.all(Gap.md),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(text, style: AType.bodyMedium.copyWith(fontWeight: FontWeight.w600)),
          if (st == 'pending' || st == 'approved') ...[
            const SizedBox(height: Gap.xs),
            FutureBuilder<IdentityKeyPair>(
              future: KeyService.instance.identity(),
              builder: (ctx, snap) => snap.hasData
                  ? Text(t.vaultE2eMatchCode(_localDigits(VaultE2E.matchCode(snap.data!.publicKey))))
                  : const SizedBox.shrink(),
            ),
            TextButton(onPressed: _busy ? null : _cancelHelp, child: Text(t.vaultE2eRequestCancel)),
          ],
        ]),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final children = <Widget>[];
    if (_loading) {
      children.add(const Padding(
          padding: EdgeInsets.all(Gap.xl), child: Center(child: CircularProgressIndicator())));
    } else {
      if (_failed) {
        children.add(_infoCard(context, t.vaultE2eFailed, icon: Icons.cloud_off_rounded));
        children.add(_bigButton(const Key('e2e_retry'), Icons.refresh_rounded, t.retry, _load, tonal: true));
      }
      children.add(_infoCard(context, t.vaultE2eServerSees, icon: Icons.lock_outline_rounded));
      final req = _requestCard(t);
      if (req != null) children.add(req);
      if (!_setUp && !_k.unlocked) {
        if (_sealedDocs > 0 || _hasServerRecovery) {
          children.add(_section(t.vaultE2eLockedCount(fmtInt(context, _sealedDocs))));
          children.add(_bigButton(const Key('e2e_unlock_code'), Icons.key_rounded, t.vaultE2eUnlockCode,
              _busy || !_hasServerRecovery ? null : _unlockWithCode));
          for (final h in _helpers)
            children.add(_bigButton(Key('e2e_ask_${h['id']}'), Icons.handshake_rounded,
                '${t.vaultE2eAskHelper}: ${h['helper_name'] ?? ''}', _busy ? null : () => _askHelper(h),
                tonal: true));
        } else if (!_failed) {
          children.add(_section(t.vaultE2eTitle));
          children.add(Text(t.vaultE2eWhat));
          children.add(_bigButton(const Key('e2e_turn_on'), Icons.enhanced_encryption_rounded,
              t.vaultE2eTurnOn, _busy ? null : _turnOn));
        }
      } else {
        children.add(ListTile(
          contentPadding: EdgeInsets.zero,
          leading: Icon(Icons.verified_user_rounded, color: Theme.of(context).colorScheme.primary),
          title: Text(t.vaultE2eOnTitle),
          subtitle: Text(t.vaultE2eOldDocsNote),
        ));
        if (!_k.unlocked)
          children.add(_infoCard(context, t.vaultE2eLockedOpen, icon: Icons.lock_rounded));
        children.add(SwitchListTile(
          key: const Key('e2e_bio'),
          contentPadding: EdgeInsets.zero,
          secondary: const Icon(Icons.fingerprint_rounded),
          title: Text(t.vaultE2eFingerprint),
          subtitle: Text(t.vaultE2eFingerprintSub),
          value: _bio,
          onChanged: _busy ? null : _toggleBio,
        ));
        children.add(ListTile(
          contentPadding: EdgeInsets.zero,
          leading: Icon(_hasServerRecovery ? Icons.check_circle_rounded : Icons.error_outline_rounded,
              color: _hasServerRecovery ? Colors.green.shade700 : Theme.of(context).colorScheme.error),
          title: Text(_hasServerRecovery ? t.vaultE2eRecoveryOnServer : t.vaultE2eRecoveryMissing),
        ));
        children.add(_bigButton(const Key('e2e_new_code'), Icons.key_rounded, t.vaultE2eNewCode,
            _busy ? null : _newCode, tonal: true));
        children.add(_section(t.vaultE2eHelpers));
        children.add(Text(t.vaultE2eHelpersSub, style: AType.bodySmall));
        for (final h in _helpers)
          children.add(ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.person_rounded),
            title: Text('${h['helper_name'] ?? ''}'),
            trailing: TextButton(onPressed: _busy ? null : () => _removeHelper(h), child: Text(t.vaultE2eRemove)),
          ));
        if (_helpers.length < 3)
          children.add(_bigButton(const Key('e2e_add_helper'), Icons.diversity_1_rounded, t.vaultE2eAddHelper,
              _busy || !_k.unlocked ? null : _addHelper, tonal: true));
      }
      if (_inbox.isNotEmpty) {
        children.add(_section(t.vaultE2eInboxSection));
        children.addAll(_inboxCards(t));
      }
      children.add(const SizedBox(height: Gap.lg));
      children.add(_infoCard(context, t.vaultE2eLossWarning, icon: Icons.warning_amber_rounded, strong: true));
    }
    return Scaffold(
      appBar: AppBar(title: Text(t.vaultE2eTitle)),
      body: RefreshIndicator(
        onRefresh: _load,
        child: ListView(
          padding: withNavBarInset(context, const EdgeInsets.fromLTRB(Gap.md, Gap.md, Gap.md, Gap.xl)),
          children: children,
        ),
      ),
    );
  }
}
