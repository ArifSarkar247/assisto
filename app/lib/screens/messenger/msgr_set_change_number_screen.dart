import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../api.dart';
import '../../l10n/app_localizations.dart';
import '../../messenger_setapi.dart';
import '../../state.dart';
import '../../theme.dart';
import '../../widgets/msgr_set_tiles.dart';
import 'package:assisto/widgets/app_sheet.dart';

/// Change number — a two-step flow: enter the NEW number, receive a code on it,
/// confirm. The server migrates the circle + chats; the old number keeps the
/// account until the code is confirmed (see
/// [MessengerSettingsApi.changeNumberRequest] / changeNumberConfirm).
class MsgrSetChangeNumberScreen extends StatefulWidget {
  const MsgrSetChangeNumberScreen({super.key, this.verifyOwn = false});

  /// tagada2: VERIFY the account's CURRENT number through the same flow
  /// (server: request with new_phone == own number is allowed until it is
  /// verified). The number is prefilled from the account and locked; the
  /// wording says "verify". Absent -> the normal change-number flow.
  final bool verifyOwn;

  @override
  State<MsgrSetChangeNumberScreen> createState() =>
      _MsgrSetChangeNumberScreenState();
}

class _MsgrSetChangeNumberScreenState
    extends State<MsgrSetChangeNumberScreen> {
  final _phone = TextEditingController();
  final _code = TextEditingController();
  final _pin = TextEditingController();
  int _step = 0; // 0 = enter number, 1 = enter code
  bool _busy = false;
  String? _error;
  // Server status: is an SMS service connected? does confirm need the PIN?
  bool _statusLoading = true;
  bool _statusFailed = false;
  bool _smsEnabled = false;
  bool _pinRequired = false;

  @override
  void initState() {
    super.initState();
    if (widget.verifyOwn) {
      _phone.text = context.read<AppState>().user?.phone ?? '';
    }
    _loadStatus();
  }

  Future<void> _loadStatus() async {
    setState(() {
      _statusLoading = true;
      _statusFailed = false;
    });
    try {
      final r = await _api.changeNumberStatus();
      _smsEnabled = r['sms_enabled'] == true;
      _pinRequired = r['two_step_required'] == true;
    } catch (_) {
      _statusFailed = true;
    }
    if (mounted) setState(() => _statusLoading = false);
  }

  String _errText(Object e, String fallback) {
    if (e is ApiException) {
      if (e.status == 503) return _t.msgChangeNumberSmsOff;
      if (e.message.isNotEmpty) return e.message;
    }
    return fallback;
  }

  ApiClient get _api => context.read<AppState>().api;
  AppLocalizations get _t => AppLocalizations.of(context);

  @override
  void dispose() {
    _phone.dispose();
    _code.dispose();
    _pin.dispose();
    super.dispose();
  }

  Future<void> _request() async {
    final phone = _phone.text.trim();
    if (phone.length < 6) {
      setState(() => _error = _t.msgrSetChangeNumberInvalid);
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await _api.changeNumberRequest(phone);
      if (mounted) setState(() => _step = 1);
    } catch (e) {
      if (mounted) {
        setState(() => _error = _errText(e, _t.msgrSetChangeNumberSendFailed));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _confirm() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await _api.changeNumberConfirm(
          newPhone: _phone.text.trim(),
          code: _code.text.trim(),
          pin: _pinRequired ? _pin.text.trim() : null);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(widget.verifyOwn
              ? _t.tg2VerifyDone
              : _t.msgrSetChangeNumberDone)));
      Navigator.of(context).maybePop(widget.verifyOwn ? true : null);
    } catch (e) {
      if (mounted) {
        setState(() => _error = _errText(e, _t.msgrSetChangeNumberCodeFailed));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = _t;
    return Scaffold(
      appBar: AppBar(
          title: Text(widget.verifyOwn
              ? t.tg2VerifyTitle
              : t.msgrSetChangeNumberTitle)),
      body: ListView(
        padding: withNavBarInset(context, const EdgeInsets.all(Gap.lg)),
        children: [
          MsgrSetNote(
              widget.verifyOwn
                  ? t.tg2VerifyIntro
                  : t.msgrSetChangeNumberIntro,
              icon: widget.verifyOwn
                  ? Icons.verified_user_rounded
                  : Icons.swap_horiz_rounded),
          const SizedBox(height: Gap.sm),
          if (_statusLoading)
            const Center(child: CircularProgressIndicator())
          else if (_statusFailed) ...[
            Text(t.msgLoadFailed),
            const SizedBox(height: Gap.sm),
            FilledButton(onPressed: _loadStatus, child: Text(t.retry)),
          ] else if (!_smsEnabled)
            // Honest disabled state: no SMS service on the server, so no code
            // can be sent. The form is not shown at all.
            MsgrSetNote(t.msgChangeNumberSmsOff, icon: Icons.sms_failed_rounded)
          else if (_step == 0) ...[
            TextField(
              key: const ValueKey('chg-phone'),
              controller: _phone,
              readOnly: widget.verifyOwn, // tagada2: own number, locked
              keyboardType: TextInputType.phone,
              inputFormatters: [
                FilteringTextInputFormatter.allow(RegExp(r'[0-9+]')),
              ],
              decoration: InputDecoration(
                labelText: widget.verifyOwn
                    ? t.tg2VerifyNumber
                    : t.msgrSetChangeNumberNew,
                border: const OutlineInputBorder(),
                errorText: _error,
                prefixIcon: const Icon(Icons.phone_rounded),
              ),
            ),
            const SizedBox(height: Gap.lg),
            FilledButton(
              onPressed: _busy ? null : _request,
              child: _busy
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2))
                  : Text(t.msgrSetChangeNumberSendCode),
            ),
          ] else ...[
            Text(t.msgrSetChangeNumberCodeSent(_phone.text.trim())),
            const SizedBox(height: Gap.md),
            TextField(
              controller: _code,
              autofocus: true,
              keyboardType: TextInputType.number,
              maxLength: 6,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              decoration: InputDecoration(
                labelText: t.msgrSetChangeNumberCode,
                border: const OutlineInputBorder(),
                errorText: _error,
              ),
            ),
            if (_pinRequired) ...[
              const SizedBox(height: Gap.sm),
              TextField(
                controller: _pin,
                obscureText: true,
                keyboardType: TextInputType.number,
                maxLength: 6,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                decoration: InputDecoration(
                  labelText: t.msgTwoStepCurrentPin,
                  border: const OutlineInputBorder(),
                ),
              ),
            ],
            const SizedBox(height: Gap.sm),
            FilledButton(
              onPressed: _busy ? null : _confirm,
              child: _busy
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2))
                  : Text(t.msgrSetChangeNumberConfirm),
            ),
            if (!widget.verifyOwn)
              TextButton(
                onPressed: _busy ? null : () => setState(() => _step = 0),
                child: Text(t.msgrSetChangeNumberEditNumber),
              )
            else
              TextButton(
                onPressed: _busy ? null : _request,
                child: Text(t.tg2VerifyResend),
              ),
          ],
        ],
      ),
    );
  }
}
