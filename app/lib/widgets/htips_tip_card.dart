import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';
import '../theme.dart';
import '../l10n/app_localizations.dart';

/// ADVANCED health-tip card. Over the GOOD card it adds:
///   - a SOURCE-NAMED line WITH a content-review date (DGHS / WHO / IEDCR),
///   - an optional symptom-AWARENESS block ("when to see a doctor") — this is
///     guidance, NEVER a diagnosis,
///   - SAVE (bookmark) and SHARE actions,
///   - a per-tip "not medical advice" footnote so the safety notice travels
///     with the content even when shared.
/// The card never diagnoses: awareness notes only say when to seek care, and
/// emergency wording always points to 999 / a doctor.
class HtipsTipCard extends StatelessWidget {
  final Map<String, dynamic> tip;
  final bool saved;
  final VoidCallback? onToggleSave;

  const HtipsTipCard({
    super.key,
    required this.tip,
    this.saved = false,
    this.onToggleSave,
  });

  Future<void> _share(BuildContext context) async {
    final t = AppLocalizations.of(context);
    final title = (tip['title'] ?? '').toString();
    final body = (tip['body'] ?? '').toString();
    final sourceName = (tip['source_name'] ?? '').toString();
    final reviewed = (tip['reviewed'] ?? '').toString();
    // Shared text ALWAYS carries the named source + the "not medical advice"
    // notice so the safety context never gets stripped off in forwarding.
    final srcLine = reviewed.isEmpty
        ? t.healthTipSourceLine(sourceName)
        : t.htipsSourceDateLine(sourceName, reviewed);
    final text = '$title\n\n$body\n\n$srcLine\n${t.htipsNotMedicalAdvice}';
    try {
      await Share.share(text, subject: title);
    } catch (_) {
      await Clipboard.setData(ClipboardData(text: text));
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(t.htipsCopied)),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final title = (tip['title'] ?? '').toString();
    final body = (tip['body'] ?? '').toString();
    final sourceName = (tip['source_name'] ?? '').toString();
    final reviewed = (tip['reviewed'] ?? '').toString();
    final awareness = (tip['awareness'] ?? '').toString();

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(Gap.lg),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(title, style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: Gap.xs),
          Text(body, style: TextStyle(color: scheme.onSurfaceVariant, height: 1.45)),

          // symptom-awareness: WHEN to see a doctor (NOT a diagnosis)
          if (awareness.isNotEmpty) ...[
            const SizedBox(height: Gap.md),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(Gap.sm),
              decoration: BoxDecoration(
                color: scheme.errorContainer,
                borderRadius: BorderRadius.circular(Radii.sm),
              ),
              child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Icon(Icons.medical_services_outlined,
                    size: 16, color: scheme.onErrorContainer),
                const SizedBox(width: Gap.xs),
                Expanded(
                  child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(t.htipsWhenToSeeDoctor,
                            style: TextStyle(
                                fontSize: 11.5,
                                fontWeight: FontWeight.w700,
                                color: scheme.onErrorContainer)),
                        const SizedBox(height: 2),
                        Text(awareness,
                            style: TextStyle(
                                fontSize: 12,
                                height: 1.35,
                                color: scheme.onErrorContainer)),
                      ]),
                ),
              ]),
            ),
          ],

          // source (NAMED) + review date
          if (sourceName.isNotEmpty) ...[
            const SizedBox(height: Gap.md),
            Row(children: [
              Icon(Icons.verified_outlined, size: 14, color: scheme.secondary),
              const SizedBox(width: Gap.xs),
              Expanded(
                child: Text(
                  reviewed.isEmpty
                      ? t.healthTipSourceLine(sourceName)
                      : t.htipsSourceDateLine(sourceName, reviewed),
                  // qa1: 11px light-theme teal on the card was 2.8:1
                  style: TextStyle(fontSize: 11, color: Brand.onTint(context, scheme.secondary)),
                ),
              ),
            ]),
          ],

          // per-tip "not medical advice" footnote (travels with the content)
          const SizedBox(height: Gap.xs),
          Text(t.htipsNotMedicalAdvice,
              style: TextStyle(fontSize: 10.5, color: scheme.onSurfaceVariant)),

          // actions: save + share
          const SizedBox(height: Gap.xs),
          Row(mainAxisAlignment: MainAxisAlignment.end, children: [
            TextButton.icon(
              onPressed: onToggleSave,
              icon: Icon(saved ? Icons.bookmark : Icons.bookmark_border, size: 18),
              label: Text(saved ? t.htipsSaved : t.htipsSave),
            ),
            const SizedBox(width: Gap.xs),
            TextButton.icon(
              onPressed: () => _share(context),
              icon: const Icon(Icons.share_outlined, size: 18),
              label: Text(t.htipsShare),
            ),
          ]),
        ]),
      ),
    );
  }
}
