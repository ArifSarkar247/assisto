import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../../widgets/app_sheet.dart';
import 'retention_source.dart';
import 'retention_widgets.dart';

/// bizauto — who stopped this shop's automatic messages (masked numbers,
/// how and when), plus "add a stop by phone" for a customer who asked in
/// person. Read-only on purpose: only the customer can start messages again.
class RetentionOptOutsScreen extends StatefulWidget {
  final RetentionSource source;
  const RetentionOptOutsScreen({super.key, required this.source});

  @override
  State<RetentionOptOutsScreen> createState() => _RetentionOptOutsScreenState();
}

class _RetentionOptOutsScreenState extends State<RetentionOptOutsScreen> {
  bool _loading = true;
  bool _busy = false;
  String? _error;
  List<Map<String, dynamic>> _rows = const [];
  final _phone = TextEditingController();

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _phone.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final d = await widget.source.optOuts();
      _rows = rtList(d['opt_outs']);
    } catch (e) {
      _error = rtError(e) ?? '';
    }
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _add() async {
    final t = AppLocalizations.of(context);
    final p = _phone.text.trim();
    setState(() => _busy = true);
    try {
      await widget.source.addOptOut(p);
      _phone.clear();
      if (mounted) rtSnack(context, t.rtOptOutDone);
      await _load();
    } catch (e) {
      if (mounted) rtSnack(context, rtError(e) ?? t.rtGenericError);
    }
    if (mounted) setState(() => _busy = false);
  }

  String _source(AppLocalizations t, Object? s) {
    switch ('$s') {
      case 'sms_link':
        return t.bzSrcSmsLink;
      case 'in_app':
        return t.bzSrcInApp;
      case 'owner':
        return t.bzSrcOwner;
      default:
        return t.bzSrcChat;
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(t.bzStoppedTitle)),
      body: _body(t),
    );
  }

  Widget _body(AppLocalizations t) {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error != null) {
      return RtMessage(
        icon: Icons.cloud_off_rounded,
        title: t.rtLoadErrorTitle,
        body: _error!.isNotEmpty ? _error! : t.rtLoadErrorBody,
        action: FilledButton(
            style: FilledButton.styleFrom(minimumSize: const Size(120, 48)),
            onPressed: _load,
            child: Text(t.rtRetry)),
      );
    }
    final scheme = Theme.of(context).colorScheme;
    final digits = _phone.text.replaceAll(RegExp(r'\D'), '').length;
    return ListView(
      padding: withNavBarInset(context, const EdgeInsets.fromLTRB(16, 12, 16, 32)),
      children: [
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Icon(Icons.verified_user_outlined, color: scheme.primary),
          const SizedBox(width: 12),
          Expanded(child: Text(t.bzStoppedBenefit)),
        ]),
        const SizedBox(height: 12),
        if (_rows.isEmpty) ...[
          Text(t.bzStoppedEmpty,
              textAlign: TextAlign.center, style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
        ],
        Text(t.bzStoppedHowTo),
        const SizedBox(height: 12),
        TextField(
          controller: _phone,
          onChanged: (_) => setState(() {}),
          keyboardType: TextInputType.phone,
          decoration: InputDecoration(labelText: t.rtOptOutHint, border: const OutlineInputBorder()),
        ),
        const SizedBox(height: 8),
        FilledButton.icon(
          style: FilledButton.styleFrom(minimumSize: const Size(48, 48)),
          icon: const Icon(Icons.block_rounded),
          label: Text(t.rtOptOutAdd),
          // enabled only once a full phone number is typed
          onPressed: (_busy || digits < 10) ? null : _add,
        ),
        const Divider(height: 32),
        for (final r in _rows)
          ListTile(
            contentPadding: EdgeInsets.zero,
            minVerticalPadding: 12,
            leading: const Icon(Icons.do_not_disturb_on_outlined),
            title: Text(rtDigits(rtLang(context), '${r['who'] ?? ''}')),
            subtitle: Text('${_source(t, r['source'])} · ${rtWhen(context, r['at'])}'),
          ),
        if (_rows.isNotEmpty) ...[
          const SizedBox(height: 8),
          Text(t.bzStoppedOnlyThey, style: Theme.of(context).textTheme.bodySmall),
        ],
      ],
    );
  }
}
