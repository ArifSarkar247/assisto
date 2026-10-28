import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../theme.dart';
import 'package:assisto/widgets/app_sheet.dart';

/// Small picker sheets/dialogs used by the 1:1 chat ⋮ menu behaviours:
/// mute durations, disappearing timer, chat theme colour, and the report
/// reason chooser. Original Assisto identity; all copy via AppLocalizations
/// (zero Bangla here).

// --------------------------------------------------------------------------
// Mute ▸ 8 hours / 1 week / Always  (returns Duration; Duration.zero == Always)
// --------------------------------------------------------------------------
Future<Duration?> showMutePicker(BuildContext context) {
  final t = AppLocalizations.of(context);
  return showAppSheet<Duration>(
    context: context,
    showDragHandle: true,
    builder: (ctx) => SafeArea(
      top: false,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ListTile(
            title: Text(t.msgrChatMute8h),
            onTap: () => Navigator.pop(ctx, const Duration(hours: 8)),
          ),
          ListTile(
            title: Text(t.msgrChatMute1w),
            onTap: () => Navigator.pop(ctx, const Duration(days: 7)),
          ),
          ListTile(
            title: Text(t.msgrChatMuteAlways),
            onTap: () => Navigator.pop(ctx, Duration.zero),
          ),
        ],
      ),
    ),
  );
}

// --------------------------------------------------------------------------
// Disappearing ▸ Off / 24h / 7d / 90d  (returns seconds: 0/86400/604800/7776000)
// --------------------------------------------------------------------------
Future<int?> showDisappearingPicker(BuildContext context, int currentSec) {
  final t = AppLocalizations.of(context);
  final options = <int, String>{
    0: t.msgrChatDisapOff,
    86400: t.msgrChatDisap24h,
    604800: t.msgrChatDisap7d,
    7776000: t.msgrChatDisap90d,
  };
  return showAppSheet<int>(
    context: context,
    showDragHandle: true,
    builder: (ctx) => SafeArea(
      top: false,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(Gap.lg, 0, Gap.lg, Gap.sm),
            child: Text(t.msgrChatDisapHint,
                style: Theme.of(ctx).textTheme.bodySmall),
          ),
          for (final e in options.entries)
            RadioListTile<int>(
              value: e.key,
              groupValue: currentSec,
              title: Text(e.value),
              onChanged: (v) => Navigator.pop(ctx, v),
            ),
        ],
      ),
    ),
  );
}

// --------------------------------------------------------------------------
// Chat theme colour picker (per-chat accent). Returns a theme token string.
// --------------------------------------------------------------------------
class ChatThemeChoice {
  final String token;
  final Color swatch;
  const ChatThemeChoice(this.token, this.swatch);
}

const _kThemeChoices = <ChatThemeChoice>[
  ChatThemeChoice('default', Color(0xFF00BCD4)),
  ChatThemeChoice('cyanBlue', Color(0xFF2196F3)),
  ChatThemeChoice('bluePurple', Color(0xFF7C4DFF)),
  ChatThemeChoice('nightInk', Color(0xFF263238)),
  ChatThemeChoice('warmPaper', Color(0xFFD7A86E)),
  ChatThemeChoice('forestCalm', Color(0xFF2E7D32)),
];

Future<String?> showChatThemePicker(BuildContext context, String current) {
  final t = AppLocalizations.of(context);
  return showAppSheet<String>(
    context: context,
    showDragHandle: true,
    builder: (ctx) => SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.all(Gap.lg),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(t.msgrChatThemePick,
                style: Theme.of(ctx).textTheme.titleMedium),
            const SizedBox(height: Gap.md),
            Wrap(
              spacing: Gap.md,
              runSpacing: Gap.md,
              children: [
                for (final c in _kThemeChoices)
                  InkWell(
                    onTap: () => Navigator.pop(ctx, c.token),
                    borderRadius: BorderRadius.circular(999),
                    child: Container(
                      width: 44,
                      height: 44,
                      decoration: BoxDecoration(
                        color: c.swatch,
                        shape: BoxShape.circle,
                        border: Border.all(
                          color: c.token == current
                              ? Theme.of(ctx).colorScheme.onSurface
                              : Colors.transparent,
                          width: 3,
                        ),
                      ),
                      child: c.token == current
                          ? const Icon(Icons.check_rounded, color: Colors.white, size: 20)
                          : null,
                    ),
                  ),
              ],
            ),
          ],
        ),
      ),
    ),
  );
}

// --------------------------------------------------------------------------
// Report reason chooser (1:1). On confirm the chat uploads the LAST 5
// decrypted messages of this chat to moderation (report-last-5).
// --------------------------------------------------------------------------
class ChatReportResult {
  final String reason;
  final bool alsoBlock;
  const ChatReportResult(this.reason, this.alsoBlock);
}

/// Reason codes mirror the moderation taxonomy keys already in the app.
const _kReportReasons = <String>[
  'spam',
  'harassment',
  'scamFraud',
  'hateSpeech',
  'nudity',
  'violentThreat',
  'impersonation',
  'other',
];

String _reasonLabel(AppLocalizations t, String code) {
  switch (code) {
    case 'spam':
      return t.msgrChatReasonSpam;
    case 'harassment':
      return t.msgrChatReasonHarassment;
    case 'scamFraud':
      return t.msgrChatReasonScam;
    case 'hateSpeech':
      return t.msgrChatReasonHate;
    case 'nudity':
      return t.msgrChatReasonNudity;
    case 'violentThreat':
      return t.msgrChatReasonThreat;
    case 'impersonation':
      return t.msgrChatReasonImpersonation;
    default:
      return t.msgrChatReasonOther;
  }
}

Future<ChatReportResult?> showChatReportPicker(BuildContext context) {
  final t = AppLocalizations.of(context);
  return showAppSheet<ChatReportResult>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (ctx) {
      String? chosen;
      bool alsoBlock = false;
      return StatefulBuilder(
        builder: (ctx, setSheet) => SafeArea(
          top: false,
          child: SingleChildScrollView(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(Gap.lg, 0, Gap.lg, Gap.lg),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(t.circleReport,
                      style: Theme.of(ctx).textTheme.titleMedium),
                  const SizedBox(height: Gap.xs),
                  Text(t.msgrChatReportNote,
                      style: Theme.of(ctx).textTheme.bodySmall),
                  const SizedBox(height: Gap.sm),
                  for (final code in _kReportReasons)
                    RadioListTile<String>(
                      value: code,
                      groupValue: chosen,
                      contentPadding: EdgeInsets.zero,
                      title: Text(_reasonLabel(t, code)),
                      onChanged: (v) => setSheet(() => chosen = v),
                    ),
                  CheckboxListTile(
                    value: alsoBlock,
                    contentPadding: EdgeInsets.zero,
                    title: Text(t.msgrChatReportAlsoBlock),
                    onChanged: (v) => setSheet(() => alsoBlock = v ?? false),
                  ),
                  const SizedBox(height: Gap.sm),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton(
                      onPressed: chosen == null
                          ? null
                          : () => Navigator.pop(
                              ctx, ChatReportResult(chosen!, alsoBlock)),
                      child: Text(t.msgrChatReportSubmit),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    },
  );
}
