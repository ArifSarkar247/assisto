import 'package:flutter/material.dart';
import '../../theme.dart';
import '../../l10n/app_localizations.dart';
import 'crm_common.dart';
import 'package:assisto/widgets/app_sheet.dart';

/// WhatsApp-from-CRM sheet (official WhatsApp Business Cloud API ONLY — NEVER
/// personal WhatsApp). Opened from the lead-detail screen. It:
///   * shows the key-gated "connect WhatsApp Business" state when the owner
///     hasn't connected the Meta Cloud API (no faked delivery — honest state),
///   * lets the rep send a free-form message (inside the 24h window) or pick an
///     OWNER-DEFINED template (required outside the window),
///   * records opt-in consent, and
///   * every send is AUTO-LOGGED on the lead timeline (the caller refreshes it).
class CrmWhatsAppSheet extends StatefulWidget {
  final int leadId;
  final String leadName;
  const CrmWhatsAppSheet(
      {super.key, required this.leadId, required this.leadName});

  /// Convenience: open as a modal bottom sheet. Returns true if a send happened
  /// (so the lead detail can refresh its timeline to show the auto-logged item).
  static Future<bool?> show(BuildContext context,
      {required int leadId, required String leadName}) {
    return showAppSheet<bool>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (sheetCtx) => Padding(
        padding: EdgeInsets.only(
            bottom: MediaQuery.of(sheetCtx).viewInsets.bottom),
        child: CrmWhatsAppSheet(leadId: leadId, leadName: leadName),
      ),
    );
  }

  @override
  State<CrmWhatsAppSheet> createState() => _CrmWhatsAppSheetState();
}

class _CrmWhatsAppSheetState extends State<CrmWhatsAppSheet> {
  Map<String, dynamic>? _status;
  List<Map<String, dynamic>> _templates = [];
  final _text = TextEditingController();
  int? _templateId;
  bool _loading = true;
  bool _sending = false;
  CrmError? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final api = CrmApi.of(context);
      _status = await api.whatsappStatus(widget.leadId);
      final org = (_status?['org'] as num?)?.toInt();
      // Templates are org-scoped; derive org from the lead status payload if
      // present, else skip (free-form only).
      if (org != null) {
        _templates = await api.waTemplates(org);
      }
    } catch (e) {
      _error = CrmError.from(e);
    }
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _setOptIn(bool v) async {
    try {
      await CrmApi.of(context).whatsappOptIn(widget.leadId, v);
      await _load();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
      }
    }
  }

  Future<void> _send(AppLocalizations t) async {
    setState(() => _sending = true);
    try {
      final r = await CrmApi.of(context).whatsappSend(
        widget.leadId,
        text: _templateId == null ? _text.text.trim() : null,
        templateId: _templateId,
      );
      final state = (r['state'] ?? '').toString();
      final msg = state == 'queued'
          ? t.crmWaQueued
          : state == 'needs_key'
              ? t.crmWaDraftedNeedsKey
              : t.crmWaDrafted;
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(msg)));
        Navigator.pop(context, true);
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
      }
    }
    if (mounted) setState(() => _sending = false);
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;

    if (_loading) {
      return const Padding(
        padding: EdgeInsets.all(Gap.lg),
        child: Center(child: CircularProgressIndicator()),
      );
    }
    if (_error != null) {
      return Padding(
        padding: const EdgeInsets.all(Gap.lg),
        child: CrmStateView.error(
            error: _error!, title: t.loadFailed, onRetry: _load),
      );
    }

    final s = _status ?? {};
    final hasKey = s['has_key'] == true;
    final optedIn = s['opted_in'] == true;
    final inWindow = s['in_window'] == true;

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(Gap.md, 0, Gap.md, Gap.md),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Row(children: [
            Icon(Icons.chat_rounded, color: scheme.primary),
            const SizedBox(width: Gap.sm),
            Expanded(
                child: Text('WhatsApp · ${widget.leadName}',
                    style: AType.titleMedium.copyWith(fontWeight: FontWeight.w800))),
          ]),
          const SizedBox(height: Gap.sm),

          // Key-gated state: official Business Cloud API not connected.
          if (!hasKey) NeedsKeyBanner(t.crmWaConnectPrompt),

          // Opt-in consent gate (required before any send).
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            value: optedIn,
            onChanged: _setOptIn,
            title: Text(t.crmWaOptIn),
            subtitle: Text(t.crmWaOptInHint,
                style: AType.bodySmall.copyWith(color: scheme.onSurfaceVariant)),
          ),

          // 24h service-window note (free-form vs template).
          Align(
            alignment: Alignment.centerLeft,
            child: Text(inWindow ? t.crmWaInWindow : t.crmWaOutWindow,
                style: AType.bodySmall.copyWith(color: scheme.onSurfaceVariant)),
          ),
          const SizedBox(height: Gap.sm),

          // Template picker (owner-defined copy only). Required outside window.
          if (_templates.isNotEmpty)
            DropdownButtonFormField<int?>(
              initialValue: _templateId,
              isExpanded: true,
              decoration: InputDecoration(
                labelText: t.crmWaTemplate,
                border: const OutlineInputBorder(),
              ),
              items: [
                DropdownMenuItem<int?>(value: null, child: Text(t.crmWaFreeForm)),
                for (final tpl in _templates)
                  DropdownMenuItem<int?>(
                      value: (tpl['id'] as num).toInt(),
                      child: Text(tpl['name']?.toString() ?? '',
                          overflow: TextOverflow.ellipsis)),
              ],
              onChanged: (v) => setState(() => _templateId = v),
            ),
          const SizedBox(height: Gap.sm),

          // Free-form text box (used when no template is selected).
          if (_templateId == null)
            TextField(
              controller: _text,
              minLines: 2,
              maxLines: 5,
              decoration: InputDecoration(
                labelText: t.crmWaMessage,
                hintText: inWindow ? null : t.crmWaOutWindowHint,
                border: const OutlineInputBorder(),
              ),
              enabled: inWindow,
            ),
          if (_templateId != null)
            Align(
              alignment: Alignment.centerLeft,
              child: Text(
                (_templates.firstWhere(
                        (e) => (e['id'] as num).toInt() == _templateId,
                        orElse: () => const {})['body'] ??
                    '')
                    .toString(),
                style: TextStyle(color: scheme.onSurfaceVariant, height: 1.4),
              ),
            ),
          const SizedBox(height: Gap.md),

          // Send — honest label depends on whether a key is connected.
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              onPressed: (_sending ||
                      !optedIn ||
                      (_templateId == null && (!inWindow || _text.text.trim().isEmpty)))
                  ? null
                  : () => _send(t),
              icon: _sending
                  ? const SizedBox(
                      width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.send_rounded),
              label: Text(hasKey ? t.crmWaSend : t.crmWaSendDraft),
            ),
          ),
          const SizedBox(height: Gap.xs),
          Text(t.crmWaAutoLogNote,
              textAlign: TextAlign.center,
              style: AType.labelSmall.copyWith(color: scheme.onSurfaceVariant)),
        ]),
      ),
    );
  }
}
