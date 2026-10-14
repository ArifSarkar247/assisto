import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../api.dart';
import '../../l10n/app_localizations.dart';
import '../../messenger_setapi.dart';
import '../../state.dart';
import '../../theme.dart';
import '../../widgets/msgr_set_tiles.dart';

/// Change number — a two-step flow: enter the NEW number, receive a code on it,
/// confirm. The server migrates the circle + chats; the old number keeps the
/// account until the code is confirmed (see
/// [MessengerSettingsApi.changeNumberRequest] / changeNumberConfirm).
class MsgrSetChangeNumberScreen extends StatefulWidget {
  const MsgrSetChangeNumberScreen({super.key});

  @override
  State<MsgrSetChangeNumberScreen> createState() =>
      _MsgrSetChangeNumberScreenState();
}

class _MsgrSetChangeNumberScreenState
    extends State<MsgrSetChangeNumberScreen> {
  final _phone = TextEditingController();
  final _code = TextEditingController();
  int _step = 0; // 0 = enter number, 1 = enter code
  bool _busy = false;
  String? _error;

  ApiClient get _api => context.read<AppState>().api;
  AppLocalizations get _t => AppLocalizations.of(context);

  @override
  void dispose() {
    _phone.dispose();
    _code.dispose();
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
    } catch (_) {
      if (mounted) setState(() => _error = _t.msgrSetChangeNumberSendFailed);
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
          newPhone: _phone.text.trim(), code: _code.text.trim());
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(_t.msgrSetChangeNumberDone)));
      Navigator.of(context).maybePop();
    } catch (_) {
      if (mounted) {
        setState(() => _error = _t.msgrSetChangeNumberCodeFailed);
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = _t;
    return Scaffold(
      appBar: AppBar(title: Text(t.msgrSetChangeNumberTitle)),
      body: ListView(
        padding: const EdgeInsets.all(Gap.lg),
        children: [
          MsgrSetNote(t.msgrSetChangeNumberIntro,
              icon: Icons.swap_horiz_outlined),
          const SizedBox(height: Gap.sm),
          if (_step == 0) ...[
            TextField(
              controller: _phone,
              keyboardType: TextInputType.phone,
              inputFormatters: [
                FilteringTextInputFormatter.allow(RegExp(r'[0-9+]')),
              ],
              decoration: InputDecoration(
                labelText: t.msgrSetChangeNumberNew,
                border: const OutlineInputBorder(),
                errorText: _error,
                prefixIcon: const Icon(Icons.phone_outlined),
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
            TextButton(
              onPressed: _busy ? null : () => setState(() => _step = 0),
              child: Text(t.msgrSetChangeNumberEditNumber),
            ),
          ],
        ],
      ),
    );
  }
}
