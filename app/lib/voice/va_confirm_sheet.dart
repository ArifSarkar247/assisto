import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../l10n/app_localizations.dart';
import '../theme.dart';
import 'package:assisto/widgets/app_sheet.dart';

/// Lets the confirm sheet ask its question out loud and hear "yes" / "no".
/// Implemented by the Assisto Voice screen (TTS + the shared VoiceDictation).
abstract class VaConfirmVoice {
  /// Speak [text]; completes when it has been spoken (or after a timeout).
  Future<void> say(String text);

  /// Listen briefly for a yes/no. true = yes, false = no, null = unclear.
  Future<bool?> listenYesNo(BuildContext sheetContext);

  /// Stop listening/speaking (sheet closed by tap).
  void stop();
}

/// The mandatory confirmation before ANY outgoing action (call, SMS,
/// WhatsApp, SOS). Nothing leaves the phone unless the user taps the confirm
/// button or clearly says "yes". Returns the chosen contact map (or `{}` when
/// there is nothing to choose), or null when cancelled.
class VaConfirmSheet extends StatefulWidget {
  final IconData icon;
  final String title;
  final String? detail;
  final List<Map<String, String>> choices;
  final String confirmLabel;
  final bool danger;
  final VaConfirmVoice? voice;
  final String? spokenQuestion;
  final bool debugListening;

  const VaConfirmSheet({
    super.key,
    required this.icon,
    required this.title,
    this.detail,
    this.choices = const [],
    required this.confirmLabel,
    this.danger = false,
    this.voice,
    this.spokenQuestion,
    this.debugListening = false,
  });

  static Future<Map<String, String>?> show(
    BuildContext context, {
    required IconData icon,
    required String title,
    String? detail,
    List<Map<String, String>> choices = const [],
    required String confirmLabel,
    bool danger = false,
    VaConfirmVoice? voice,
    String? spokenQuestion,
  }) async {
    final r = await showAppSheet<Map<String, String>>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      useSafeArea: true,
      builder: (_) => VaConfirmSheet(
        icon: icon,
        title: title,
        detail: detail,
        choices: choices,
        confirmLabel: confirmLabel,
        danger: danger,
        voice: voice,
        spokenQuestion: spokenQuestion,
      ),
    );
    voice?.stop();
    return r;
  }

  /// A plain "why we need this" step before a runtime permission.
  static Future<bool> reason(BuildContext context,
      {required IconData icon, required String body}) async {
    final t = AppLocalizations.of(context);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        scrollable: true, // insets: 200% text / keyboard
        icon: Icon(icon),
        content: Text(body),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(t.cancel)),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(t.vaContinue)),
        ],
      ),
    );
    return ok == true;
  }

  @override
  State<VaConfirmSheet> createState() => _VaConfirmSheetState();
}

class _VaConfirmSheetState extends State<VaConfirmSheet> {
  int _sel = 0;
  bool _listening = false;
  bool _closed = false;

  @override
  void initState() {
    super.initState();
    _listening = widget.debugListening;
    if (widget.voice != null && widget.spokenQuestion != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _askByVoice());
    }
  }

  Future<void> _askByVoice() async {
    final v = widget.voice!;
    try {
      await v.say(widget.spokenQuestion!);
      if (!mounted || _closed) return;
      setState(() => _listening = true);
      final yes = await v.listenYesNo(context);
      if (!mounted || _closed) return;
      setState(() => _listening = false);
      if (yes == true) {
        _confirm();
      } else if (yes == false) {
        _cancel();
      }
    } catch (_) {
      if (mounted) setState(() => _listening = false);
    }
  }

  void _confirm() {
    if (_closed) return;
    _closed = true;
    HapticFeedback.mediumImpact();
    Navigator.pop(
        context, widget.choices.isEmpty ? <String, String>{} : widget.choices[_sel]);
  }

  void _cancel() {
    if (_closed) return;
    _closed = true;
    Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final accent = widget.danger ? Brand.danger : scheme.primary;
    return Padding(
      padding: EdgeInsets.fromLTRB(Gap.lg, 0, Gap.lg,
          Gap.lg + MediaQuery.of(context).viewInsets.bottom),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(children: [
              Container(
                width: 48,
                height: 48,
                decoration: BoxDecoration(
                  color: accent.withValues(alpha: 0.14),
                  shape: BoxShape.circle,
                ),
                child: Icon(widget.icon, color: accent, size: 26),
              ),
              const SizedBox(width: Gap.md),
              Expanded(
                child: Text(widget.title,
                    style: Theme.of(context)
                        .textTheme
                        .titleLarge
                        ?.copyWith(fontWeight: FontWeight.w700)),
              ),
            ]),
            if (widget.detail != null) ...[
              const SizedBox(height: Gap.md),
              Text(widget.detail!,
                  style: Theme.of(context)
                      .textTheme
                      .bodyLarge
                      ?.copyWith(color: scheme.onSurfaceVariant)),
            ],
            if (widget.choices.isNotEmpty) ...[
              const SizedBox(height: Gap.md),
              for (var i = 0; i < widget.choices.length; i++)
                Card(
                  margin: const EdgeInsets.only(bottom: Gap.sm),
                  color: i == _sel
                      ? scheme.primaryContainer
                      : scheme.surfaceContainerHighest,
                  child: InkWell(
                    borderRadius: BorderRadius.circular(Radii.md),
                    onTap: () => setState(() => _sel = i),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                          horizontal: Gap.md, vertical: Gap.sm + 2),
                      child: Row(children: [
                        Icon(
                            i == _sel
                                ? Icons.radio_button_checked_rounded
                                : Icons.radio_button_off_rounded,
                            color: i == _sel
                                ? scheme.onPrimaryContainer
                                : scheme.onSurfaceVariant),
                        const SizedBox(width: Gap.md),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(widget.choices[i]['name'] ?? '',
                                  style: TextStyle(
                                      fontWeight: FontWeight.w600,
                                      color: i == _sel
                                          ? scheme.onPrimaryContainer
                                          : scheme.onSurface)),
                              Text(widget.choices[i]['phone'] ?? '',
                                  style: TextStyle(
                                      color: i == _sel
                                          ? scheme.onPrimaryContainer
                                          : scheme.onSurfaceVariant)),
                            ],
                          ),
                        ),
                      ]),
                    ),
                  ),
                ),
            ],
            if (_listening) ...[
              const SizedBox(height: Gap.md),
              Row(children: [
                Icon(Icons.mic_rounded, color: scheme.primary, size: 20),
                const SizedBox(width: Gap.sm),
                Expanded(
                  child: Text(t.vaSayYesNo,
                      style: TextStyle(color: scheme.primary)),
                ),
              ]),
            ],
            const SizedBox(height: Gap.lg),
            Row(children: [
              Expanded(
                child: OutlinedButton(
                  style: OutlinedButton.styleFrom(
                      minimumSize: const Size.fromHeight(52)),
                  onPressed: _cancel,
                  child: Text(t.cancel),
                ),
              ),
              const SizedBox(width: Gap.md),
              Expanded(
                child: FilledButton(
                  style: FilledButton.styleFrom(
                    minimumSize: const Size.fromHeight(52),
                    backgroundColor: widget.danger ? const Color(0xFFC62828) : null,
                    foregroundColor: widget.danger ? Colors.white : null,
                  ),
                  onPressed: _confirm,
                  child: Text(widget.confirmLabel,
                      textAlign: TextAlign.center),
                ),
              ),
            ]),
          ],
        ),
      ),
    );
  }
}
