import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../l10n/app_localizations.dart';
import '../../theme.dart';
import 'remit_sheets.dart';
import 'remit_source.dart';
import 'remit_widgets.dart';

/// budget-remittance: the monthly report for the person who sends the money
/// — how much came and where it went, in clear Bangla (or English). It is
/// sent ONLY when the user taps "Share in My Circle" and picks the member;
/// it goes as a normal end-to-end encrypted My Circle message. Nothing is
/// ever shared automatically.
class RemitReportScreen extends StatefulWidget {
  final RemitSource source;
  final String month;
  final String? initialLang;
  const RemitReportScreen({super.key, required this.source, required this.month, this.initialLang});

  @override
  State<RemitReportScreen> createState() => _RemitReportScreenState();
}

class _RemitReportScreenState extends State<RemitReportScreen> {
  late String _lang = widget.initialLang ?? 'bn';
  bool _loading = true;
  bool _sending = false;
  Object? _err;
  String _text = '';
  String? _sentTo;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _err = null;
    });
    try {
      final d = await widget.source.report(widget.month, _lang);
      _text = '${d['text'] ?? ''}';
    } catch (e) {
      _err = e;
    }
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _share() async {
    final t = AppLocalizations.of(context);
    final messenger = ScaffoldMessenger.of(context);
    List<Map<String, dynamic>> members;
    try {
      members = await widget.source.members();
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(rmOffline(e) ? t.rmtNeedsInternet : t.rmtErrorBody)));
      return;
    }
    if (!mounted) return;
    final m = await showMemberPicker(context, members);
    if (m == null || !mounted) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        scrollable: true, // insets: 200% text / keyboard
        title: Text(t.rmtShareConfirmTitle),
        content: Text(t.rmtShareConfirmBody('${m['name'] ?? ''}')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: Text(t.cancel)),
          FilledButton(
            key: const ValueKey('rmt_share_send'),
            onPressed: () => Navigator.pop(c, true),
            child: Text(t.rmtShareSend),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    setState(() => _sending = true);
    try {
      await widget.source.shareToMember(m, _text);
      HapticFeedback.selectionClick();
      setState(() => _sentTo = '${m['name'] ?? ''}');
      messenger.showSnackBar(SnackBar(content: Text(t.rmtShareSent('${m['name'] ?? ''}'))));
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(rmOffline(e) ? t.rmtNeedsInternet : t.rmtShareFailed)));
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: Text(t.rmtReportTitle)),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _err != null
          ? rmErrorView(context, _err!, _load)
          : ListView(
              padding: const EdgeInsets.fromLTRB(Gap.lg, Gap.md, Gap.lg, Gap.xxxl),
              children: [
                Text(rmMonthLabel(context, widget.month), style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: Gap.sm),
                Text(t.rmtReportLang, style: Theme.of(context).textTheme.titleSmall),
                const SizedBox(height: Gap.xs),
                Wrap(
                  spacing: Gap.sm,
                  children: [
                    ChoiceChip(
                      key: const ValueKey('rmt_report_bn'),
                      materialTapTargetSize: MaterialTapTargetSize.padded,
                      label: Text(t.rmtReportBangla),
                      selected: _lang == 'bn',
                      onSelected: (_) {
                        _lang = 'bn';
                        _load();
                      },
                    ),
                    ChoiceChip(
                      key: const ValueKey('rmt_report_en'),
                      materialTapTargetSize: MaterialTapTargetSize.padded,
                      label: Text(t.rmtReportEnglish),
                      selected: _lang == 'en',
                      onSelected: (_) {
                        _lang = 'en';
                        _load();
                      },
                    ),
                  ],
                ),
                const SizedBox(height: Gap.md),
                Card(
                  margin: EdgeInsets.zero,
                  child: Padding(
                    padding: const EdgeInsets.all(Gap.lg),
                    child: SelectableText(_text, key: const ValueKey('rmt_report_text')),
                  ),
                ),
                const SizedBox(height: Gap.md),
                Text(t.rmtReportPrivacy, style: Theme.of(context).textTheme.bodySmall),
                const SizedBox(height: Gap.lg),
                FilledButton.icon(
                  key: const ValueKey('rmt_share'),
                  style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
                  onPressed: _sending || _text.isEmpty ? null : _share,
                  icon: _sending
                      ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                      : const Icon(Icons.ios_share_rounded),
                  label: Text(t.rmtShareInCircle),
                ),
                if (_sentTo != null)
                  Padding(
                    padding: const EdgeInsets.only(top: Gap.sm),
                    child: Text(t.rmtShareSent(_sentTo!), style: TextStyle(color: scheme.primary)),
                  ),
              ],
            ),
    );
  }
}
