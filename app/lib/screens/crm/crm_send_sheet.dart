import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../api.dart';
import '../../l10n/app_localizations.dart';
import '../../messaging/date_separators.dart' show localDigits;
import '../../services/error_kind.dart';
import '../../services/error_report.dart';
import '../../theme.dart';
import 'crm100_api.dart';

/// crm100 — "send from CRM" to ONE customer. The seller writes (or keeps)
/// the text, then picks HOW, each with an honest state:
///   * WhatsApp — opens WhatsApp with the text filled in (their phone sends);
///   * Phone SMS — opens the phone's own SMS app (their SIM sends);
///   * Assisto SMS — our gateway: the credit cost and their balance are
///     shown FIRST, then a confirm; STOP / quiet hours / caps / no gateway
///     are explained, never hidden.
/// Nothing is ever sent without this tap. Returns true when something was
/// opened or sent (the caller refreshes the history).
class CrmSendSheet extends StatefulWidget {
  final CustomerTarget target;
  final String name;
  final int? business;
  final int? lead;
  final String initialText;
  final String purpose;
  const CrmSendSheet(
      {super.key,
      required this.target,
      required this.name,
      this.business,
      this.lead,
      this.initialText = '',
      this.purpose = 'message'});

  static Future<bool?> show(BuildContext context,
          {required CustomerTarget target,
          required String name,
          int? business,
          int? lead,
          String initialText = '',
          String purpose = 'message'}) =>
      showModalBottomSheet<bool>(
        context: context,
        isScrollControlled: true,
        showDragHandle: true,
        useSafeArea: true,
        builder: (_) => CrmSendSheet(
            target: target,
            name: name,
            business: business,
            lead: lead,
            initialText: initialText,
            purpose: purpose),
      );

  @override
  State<CrmSendSheet> createState() => _CrmSendSheetState();
}

class _CrmSendSheetState extends State<CrmSendSheet> {
  late final TextEditingController _text =
      TextEditingController(text: widget.initialText);
  Map<String, dynamic>? _pv;
  bool _busy = false;
  String _status = '';
  bool _statusBad = false;
  bool _did = false;
  Object? _fail;

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  String _d(Object v) =>
      localDigits('$v', Localizations.localeOf(context).languageCode);

  String get _lang => Localizations.localeOf(context).languageCode;

  Future<void> _preview() async {
    final txt = _text.text.trim();
    if (txt.isEmpty) return;
    setState(() {
      _busy = true;
      _fail = null;
    });
    try {
      _pv = await Crm100Api.of(context)
          .sendPreview(widget.target, txt, business: widget.business, lang: _lang)
          .timeout(const Duration(seconds: 15));
    } catch (e) {
      _fail = e;
      _pv = null;
      reportNonFatal('crm100.sendPreview', e);
    }
    if (mounted) setState(() => _busy = false);
  }

  Future<void> _open(String url, String channel) async {
    final t = AppLocalizations.of(context);
    var ok = false;
    try {
      // a launcher that never answers must not freeze the sheet
      ok = await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication)
          .timeout(const Duration(seconds: 8), onTimeout: () => false);
    } catch (e) {
      reportNonFatal('crm100.open', e);
    }
    if (!mounted) return;
    if (ok) {
      _did = true;
      try {
        await Crm100Api.of(context).sendLog(widget.target, channel, _text.text.trim(),
            business: widget.business, purpose: widget.purpose, lead: widget.lead);
      } catch (e) {
        reportNonFatal('crm100.sendLog', e); // the message itself still went
      }
    }
    if (!mounted) return;
    setState(() {
      _statusBad = !ok;
      _status = ok
          ? (channel == 'whatsapp_link' ? t.c100OpenedWa : t.c100OpenedSms)
          : t.c100CantOpen;
    });
  }

  Future<void> _assisto(Map<String, dynamic> sms) async {
    final t = AppLocalizations.of(context);
    final credits = (sms['credits'] as num?)?.toInt() ?? 1;
    final bal = (sms['balance'] as num?)?.toInt() ?? 0;
    final go = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(t.c100SmsConfirmTitle),
        content: Text(t.c100SmsConfirmBody(widget.name.isEmpty ? t.c100ThisCustomer : widget.name,
            _d(credits), _d(bal))),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(t.cancel)),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(t.c100SmsSend)),
        ],
      ),
    );
    if (go != true || !mounted) return;
    setState(() => _busy = true);
    try {
      final r = await Crm100Api.of(context).sendSms(widget.target, _text.text.trim(), credits,
          business: widget.business, lang: _lang, lead: widget.lead);
      if (!mounted) return;
      _did = true;
      setState(() {
        _busy = false;
        _statusBad = false;
        _status = t.c100SmsSent(_d((r['credits'] as num?)?.toInt() ?? credits),
            _d((r['balance'] as num?)?.toInt() ?? bal));
      });
    } catch (e) {
      if (!mounted) return;
      final body = e is ApiException ? e.body : null;
      setState(() {
        _busy = false;
        _statusBad = true;
        _status = (body?['detail'] ?? '').toString().isNotEmpty
            ? '${body!['detail']}'
            : honestFailText(t, e, otherwise: t.c100SmsFailed);
      });
      if (body?['reason'] == 'price_changed') _preview(); // show the new cost
    }
  }

  String _blockedText(AppLocalizations t, String why, Map<String, dynamic> sms) {
    switch (why) {
      case 'sms_not_configured':
        return t.c100SmsNoGateway;
      case 'owner_only':
        return t.c100SmsOwnerOnly;
      case 'opted_out':
        return t.c100SmsOptedOut;
      case 'quiet_hours':
        return t.c100SmsQuiet;
      case 'insufficient_credits':
        return t.c100SmsNoCredits(_d((sms['credits'] as num?)?.toInt() ?? 1),
            _d((sms['balance'] as num?)?.toInt() ?? 0));
      case 'bad_phone':
        return t.c100NoPhone;
      case 'too_long':
        return t.c100SmsTooLong;
      case 'no_business':
        return t.c100SmsNoBusiness;
      case 'not_your_customer':
        return t.c100SmsNotYours;
      default:
        return t.c100SmsUnavailable;
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final pv = _pv;
    final sms = (pv?['sms'] as Map?)?.cast<String, dynamic>();
    final phoneOk = pv?['phone_ok'] == true;
    return Padding(
      padding: EdgeInsets.only(
          left: Gap.lg,
          right: Gap.lg,
          bottom: MediaQuery.of(context).viewInsets.bottom + Gap.lg),
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(t.c100SendTitle(widget.name.isEmpty ? t.c100ThisCustomer : widget.name),
                style: AType.titleLarge, maxLines: 2, overflow: TextOverflow.ellipsis),
            const SizedBox(height: Gap.xs),
            Text(t.c100NeverAuto,
                style: AType.bodySmall.copyWith(color: scheme.onSurfaceVariant)),
            const SizedBox(height: Gap.md),
            TextField(
              controller: _text,
              minLines: 3,
              maxLines: 6,
              maxLength: 600,
              textInputAction: TextInputAction.newline,
              decoration: InputDecoration(
                  labelText: t.c100MessageLabel, border: const OutlineInputBorder()),
              onChanged: (_) {
                if (_pv != null) setState(() => _pv = null); // re-check the cost
              },
            ),
            const SizedBox(height: Gap.sm),
            if (pv == null)
              FilledButton.icon(
                onPressed: _busy || _text.text.trim().isEmpty ? null : _preview,
                icon: _busy
                    ? const SizedBox(
                        width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.arrow_forward_rounded),
                label: Text(t.c100ChooseHow),
              ),
            if (_fail != null) ...[
              const SizedBox(height: Gap.sm),
              _Note(
                  icon: Icons.cloud_off_rounded,
                  text: failKindOf(_fail!) == FailKind.network
                      ? t.c100Offline
                      : honestFailText(t, _fail, otherwise: t.c100PreviewFailed),
                  bad: true),
            ],
            if (pv != null) ...[
              if (!phoneOk) _Note(icon: Icons.phone_disabled_rounded, text: t.c100NoPhone, bad: true),
              const SizedBox(height: Gap.sm),
              _Way(
                icon: Icons.chat_rounded,
                title: t.c100WayWa,
                sub: t.c100WayWaSub,
                onTap: phoneOk && '${pv['wa_url'] ?? ''}'.isNotEmpty
                    ? () => _open('${pv['wa_url']}', 'whatsapp_link')
                    : null,
              ),
              _Way(
                icon: Icons.sms_rounded,
                title: t.c100WaySms,
                sub: t.c100WaySmsSub,
                onTap: phoneOk && '${pv['sms_uri'] ?? ''}'.isNotEmpty
                    ? () => _open('${pv['sms_uri']}', 'sms_app')
                    : null,
              ),
              if (sms != null)
                _Way(
                  icon: Icons.outgoing_mail,
                  title: t.c100WayAssisto,
                  sub: sms['available'] == true
                      ? t.c100WayAssistoCost(_d((sms['credits'] as num?)?.toInt() ?? 1),
                          _d((sms['segments'] as num?)?.toInt() ?? 1),
                          _d((sms['balance'] as num?)?.toInt() ?? 0))
                      : _blockedText(t, '${sms['blocked'] ?? ''}', sms),
                  onTap: sms['available'] == true && !_busy ? () => _assisto(sms) : null,
                ),
            ],
            if (_status.isNotEmpty) ...[
              const SizedBox(height: Gap.sm),
              Semantics(
                liveRegion: true,
                child: _Note(
                    icon: _statusBad ? Icons.error_outline_rounded : Icons.check_circle_rounded,
                    text: _status,
                    bad: _statusBad),
              ),
            ],
            const SizedBox(height: Gap.md),
            OutlinedButton(
              onPressed: () => Navigator.pop(context, _did),
              child: Text(_did ? t.c100Done : t.cancel),
            ),
          ],
        ),
      ),
    );
  }
}

class _Way extends StatelessWidget {
  final IconData icon;
  final String title;
  final String sub;
  final VoidCallback? onTap;
  const _Way({required this.icon, required this.title, required this.sub, this.onTap});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final on = onTap != null;
    return Card(
      margin: const EdgeInsets.only(bottom: Gap.sm),
      child: ListTile(
        minVerticalPadding: Gap.md,
        enabled: on,
        leading: Icon(icon, color: on ? scheme.primary : scheme.onSurfaceVariant),
        title: Text(title),
        subtitle: Text(sub),
        trailing: on ? const Icon(Icons.chevron_right_rounded) : null,
        onTap: onTap,
      ),
    );
  }
}

class _Note extends StatelessWidget {
  final IconData icon;
  final String text;
  final bool bad;
  const _Note({required this.icon, required this.text, this.bad = false});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(Gap.md),
      decoration: BoxDecoration(
          color: bad ? scheme.errorContainer : scheme.secondaryContainer,
          borderRadius: BorderRadius.circular(Radii.md)),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Icon(icon, size: 20, color: bad ? scheme.onErrorContainer : scheme.onSecondaryContainer),
        const SizedBox(width: Gap.sm),
        Expanded(
            child: Text(text,
                style: TextStyle(
                    color: bad ? scheme.onErrorContainer : scheme.onSecondaryContainer))),
      ]),
    );
  }
}
