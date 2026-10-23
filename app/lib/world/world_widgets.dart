import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../l10n/app_localizations.dart';
import '../messaging/date_separators.dart' show fmtDate, localDigits;
import '../theme.dart';
import '../voice/va_native.dart';

/// p4-world shared bits: open an official link, read text aloud (bn/en TTS),
/// small notes and the "source · updated" line every data card carries.

String uwLang(BuildContext context) =>
    Localizations.localeOf(context).languageCode == 'en' ? 'en' : 'bn';

/// Digits in the UI language (Bangla digits in bn).
String uwDigits(BuildContext context, Object v) =>
    localDigits('$v', uwLang(context));

/// ISO date/time -> short local text ("23 Oct, 18:05"), Bangla digits in bn.
/// Unparseable input is shown as-is (never invented).
String uwWhen(BuildContext context, String iso, {bool time = true}) {
  final s = iso.trim();
  if (s.isEmpty) return '';
  final d = DateTime.tryParse(s);
  if (d == null) return localDigits(s, uwLang(context));
  return fmtDate(
      time ? 'd MMM, HH:mm' : 'd MMM yyyy', d.toLocal(), uwLang(context));
}

Future<void> uwOpen(BuildContext context, String url) async {
  final t = AppLocalizations.of(context);
  final uri = Uri.tryParse(url);
  var ok = false;
  if (uri != null && (uri.scheme == 'https' || uri.scheme == 'http')) {
    try {
      ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (_) {
      ok = false;
    }
  }
  if (!ok && context.mounted) {
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(t.uwCouldNotOpen)));
  }
}

/// Reads [text] aloud with the phone's TTS in the UI language. Honest when the
/// phone has no Bangla voice (offers the system TTS settings).
class UwSpeakButton extends StatelessWidget {
  const UwSpeakButton({super.key, required this.text, this.compact = false});
  final String text;
  final bool compact;

  Future<void> _speak(BuildContext context) async {
    final t = AppLocalizations.of(context);
    final lang = uwLang(context);
    final r = await VaNative.speak(text, lang);
    if (!context.mounted) return;
    if (r == 'no_voice') {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(t.uwTtsNoVoice),
        action: SnackBarAction(
            label: t.uwTtsSettings,
            onPressed: () => VaNative.openTtsSettings()),
      ));
    } else if (r == null || r == 'no_engine') {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(t.uwTtsUnavailable)));
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    return IconButton(
      tooltip: t.uwListen,
      visualDensity: compact ? VisualDensity.compact : null,
      onPressed: text.trim().isEmpty ? null : () => _speak(context),
      icon: const Icon(Icons.volume_up_outlined),
    );
  }
}

/// A tinted note (verify / consult / AI-generated).
class UwNote extends StatelessWidget {
  const UwNote(
      {super.key,
      required this.text,
      this.icon = Icons.info_outline,
      this.warn = false});
  final String text;
  final IconData icon;
  final bool warn;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final bg = warn ? scheme.tertiaryContainer : scheme.surfaceContainerHighest;
    final fg = warn ? scheme.onTertiaryContainer : scheme.onSurfaceVariant;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(Gap.md),
      decoration:
          BoxDecoration(color: bg, borderRadius: BorderRadius.circular(12)),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Icon(icon, size: 18, color: fg),
        const SizedBox(width: Gap.sm),
        Expanded(child: Text(text, style: TextStyle(color: fg, height: 1.4))),
      ]),
    );
  }
}

/// "Source: X · Updated: Y" with the source opening its official site.
class UwSourceLine extends StatelessWidget {
  const UwSourceLine(
      {super.key, required this.source, this.url = '', this.updated = ''});
  final String source;
  final String url;
  final String updated;

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final style = Theme.of(context)
        .textTheme
        .bodySmall
        ?.copyWith(color: scheme.onSurfaceVariant);
    final when = uwWhen(context, updated);
    return InkWell(
      onTap: url.isEmpty ? null : () => uwOpen(context, url),
      child: Padding(
        padding: const EdgeInsets.only(top: Gap.sm),
        child: Text(
          [t.uwSourceIs(source), if (when.isNotEmpty) t.uwUpdatedAt(when)]
              .join(' · '),
          style: style?.copyWith(
              decoration: url.isEmpty ? null : TextDecoration.underline,
              decorationColor: scheme.onSurfaceVariant),
        ),
      ),
    );
  }
}

/// A tappable official link row.
class UwLinkTile extends StatelessWidget {
  const UwLinkTile({super.key, required this.label, required this.url});
  final String label;
  final String url;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final host = Uri.tryParse(url)?.host.replaceFirst('www.', '') ?? '';
    return ListTile(
      contentPadding: EdgeInsets.zero,
      dense: true,
      leading: Icon(Icons.open_in_new, color: scheme.primary, size: 20),
      title: Text(label),
      subtitle: host.isEmpty ? null : Text(host),
      onTap: () => uwOpen(context, url),
    );
  }
}

/// Section header used across the hubs.
class UwHeader extends StatelessWidget {
  const UwHeader(this.text, {super.key, this.trailing});
  final String text;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(0, Gap.lg, 0, Gap.sm),
        child: Row(children: [
          Expanded(
              child: Text(text,
                  style: Theme.of(context)
                      .textTheme
                      .titleMedium
                      ?.copyWith(fontWeight: FontWeight.w700))),
          if (trailing != null) trailing!,
        ]),
      );
}
