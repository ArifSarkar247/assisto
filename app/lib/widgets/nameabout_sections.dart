import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';
import '../theme.dart';
import '../l10n/app_localizations.dart';

/// Assisto — "About the Assisto name" ADVANCED surface (SPEC v2.1 §21).
///
/// Reusable, stateless presentation pieces for the name/trademark info note.
/// HARD RULE: ZERO Bangla glyphs in this (or any) .dart file — every visible
/// string is read through `AppLocalizations` (ARB), including the FAQ copy,
/// the brand-story copy and the source note. The matching bilingual strings
/// are emitted to `.phaseB/up_nameabout_arb.json` for the integrator to fold
/// into `app_en.arb` / `app_bn.arb`.
///
/// CRITICAL (repeated, by design): nothing here EVER claims the name is
/// cleared, available, or registered. Every surface is marked "informational
/// only — not legal trademark clearance / not legal advice", and the status is
/// always rendered as "research pending — no clearance claimed".

/// The official source for a Bangladesh trademark search — shown verbatim and
/// opened externally, never summarised as if it were an answer.
const String kDpdtPortalUrl = 'http://www.dpdt.gov.bd/';
const String kWipoBrandDbUrl = 'https://branddb.wipo.int/';

/// A prominent, high-contrast "NOT legal clearance" banner. Rendered more than
/// once on the screen so the disclaimer is unmissable regardless of scroll
/// position. Uses the error-container colour pair (WCAG-safe foreground).
class NameAboutDisclaimerBanner extends StatelessWidget {
  /// When true, renders the shorter "reminder" variant used lower on the page.
  final bool compact;
  const NameAboutDisclaimerBanner({super.key, this.compact = false});

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final title = compact ? t.nameAboutDisclaimerShort : t.nameAboutDisclaimerTitle;
    return Semantics(
      container: true,
      label: '${t.nameAboutDisclaimerTitle}. ${t.nameAboutDisclaimer}',
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.all(Gap.md),
        decoration: BoxDecoration(
          color: scheme.errorContainer,
          borderRadius: BorderRadius.circular(Radii.md),
          border: Border.all(color: scheme.error.withValues(alpha: 0.45), width: 1.5),
        ),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Icon(Icons.gavel_rounded, color: scheme.onErrorContainer),
          const SizedBox(width: Gap.sm),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(title,
                  style: TextStyle(
                      color: scheme.onErrorContainer,
                      fontWeight: FontWeight.w800,
                      height: 1.35)),
              if (!compact) ...[
                const SizedBox(height: Gap.xs),
                Text(t.nameAboutDisclaimer,
                    style: TextStyle(
                        color: scheme.onErrorContainer, height: 1.5, fontSize: 13)),
              ],
            ]),
          ),
        ]),
      ),
    );
  }
}

/// Simple titled section header used throughout the screen.
class NameAboutSectionTitle extends StatelessWidget {
  final String text;
  final IconData icon;
  const NameAboutSectionTitle({super.key, required this.text, required this.icon});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: Gap.sm),
      child: Row(children: [
        Icon(icon, size: 20, color: scheme.primary),
        const SizedBox(width: Gap.sm),
        Expanded(
          child: Text(text,
              style: Theme.of(context)
                  .textTheme
                  .titleMedium
                  ?.copyWith(fontWeight: FontWeight.w800)),
        ),
      ]),
    );
  }
}

/// The brand-story block: why the name, what it means. Pure info, no claims.
class NameAboutBrandStory extends StatelessWidget {
  /// Server-supplied meaning (may be empty); the fuller story comes from ARB.
  final String meaning;
  const NameAboutBrandStory({super.key, required this.meaning});

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      NameAboutSectionTitle(text: t.nameAboutStoryTitle, icon: Icons.auto_stories_outlined),
      Card(
        child: Padding(
          padding: const EdgeInsets.all(Gap.md),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            if (meaning.isNotEmpty) ...[
              Text(meaning, style: const TextStyle(height: 1.5, fontWeight: FontWeight.w600)),
              const SizedBox(height: Gap.sm),
            ],
            Text(t.nameAboutStoryBody,
                style: TextStyle(height: 1.55, color: scheme.onSurfaceVariant)),
          ]),
        ),
      ),
    ]);
  }
}

/// Status chip — ALWAYS "research pending / no clearance claimed". The colour
/// is warning (never success) so it can never read as "cleared / safe".
class NameAboutStatusCard extends StatelessWidget {
  final String status; // server-supplied; falls back to ARB
  const NameAboutStatusCard({super.key, required this.status});

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final text = status.isNotEmpty ? status : t.nameAboutStatusPending;
    return Container(
      padding: const EdgeInsets.all(Gap.md),
      decoration: BoxDecoration(
        color: Brand.warning.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(Radii.sm),
        border: Border.all(color: Brand.warning.withValues(alpha: 0.35)),
      ),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Icon(Icons.hourglass_bottom, color: Brand.warning),
        const SizedBox(width: Gap.sm),
        Expanded(child: Text(text, style: const TextStyle(height: 1.45))),
      ]),
    );
  }
}

/// Trademark-class card. Classes 9 & 42 are visually emphasised (the two
/// primary classes for a software assistant), the rest shown as secondary.
class NameAboutClassCard extends StatelessWidget {
  final int number;
  final String note;
  const NameAboutClassCard({super.key, required this.number, required this.note});

  bool get _primary => number == 9 || number == 42;

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    return Card(
      margin: const EdgeInsets.only(bottom: Gap.sm),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(Radii.md),
        side: _primary
            ? BorderSide(color: scheme.primary.withValues(alpha: 0.5), width: 1.5)
            : BorderSide.none,
      ),
      child: ListTile(
        leading: CircleAvatar(
          backgroundColor: _primary
              ? scheme.primary
              : scheme.primary.withValues(alpha: 0.12),
          child: Text('$number',
              style: TextStyle(
                  color: _primary ? scheme.onPrimary : scheme.primary,
                  fontWeight: FontWeight.w800)),
        ),
        title: Row(children: [
          Flexible(child: Text(t.nameAboutClassLabel('$number'))),
          if (_primary) ...[
            const SizedBox(width: Gap.sm),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
              decoration: BoxDecoration(
                color: scheme.primary.withValues(alpha: 0.14),
                borderRadius: BorderRadius.circular(Radii.pill),
              ),
              child: Text(t.nameAboutClassPrimary,
                  style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                      color: scheme.primary)),
            ),
          ],
        ]),
        subtitle: Text(note, style: const TextStyle(height: 1.4)),
      ),
    );
  }
}

/// Source note — shows WHERE a real search must happen, with the official
/// portal link opened externally. Framed as "where to look", never "result".
class NameAboutSourceNote extends StatelessWidget {
  const NameAboutSourceNote({super.key});

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      NameAboutSectionTitle(text: t.nameAboutSourcesTitle, icon: Icons.verified_outlined),
      Text(t.nameAboutSourcesBody,
          style: TextStyle(color: scheme.onSurfaceVariant, height: 1.5, fontSize: 13)),
      const SizedBox(height: Gap.sm),
      _SourceTile(
        label: t.nameAboutSourceDpdt,
        url: kDpdtPortalUrl,
        scheme: scheme,
      ),
      const SizedBox(height: Gap.xs),
      _SourceTile(
        label: t.nameAboutSourceWipo,
        url: kWipoBrandDbUrl,
        scheme: scheme,
      ),
    ]);
  }
}

class _SourceTile extends StatelessWidget {
  final String label;
  final String url;
  final ColorScheme scheme;
  const _SourceTile({required this.label, required this.url, required this.scheme});

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    return Material(
      color: scheme.surfaceContainerHighest,
      borderRadius: BorderRadius.circular(Radii.sm),
      child: InkWell(
        borderRadius: BorderRadius.circular(Radii.sm),
        onTap: () => _open(context, url),
        child: Semantics(
          button: true,
          link: true,
          label: '$label, $url',
          child: Padding(
            padding: const EdgeInsets.all(Gap.md),
            child: Row(children: [
              Icon(Icons.open_in_new, size: 18, color: scheme.primary),
              const SizedBox(width: Gap.sm),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(label, style: const TextStyle(fontWeight: FontWeight.w600)),
                  const SizedBox(height: 2),
                  Text(url,
                      style: TextStyle(
                          fontSize: 12, color: scheme.onSurfaceVariant)),
                ]),
              ),
              IconButton(
                tooltip: t.copy,
                icon: const Icon(Icons.copy, size: 18),
                onPressed: () async {
                  await Clipboard.setData(ClipboardData(text: url));
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(content: Text(t.copied)));
                  }
                },
              ),
            ]),
          ),
        ),
      ),
    );
  }

  Future<void> _open(BuildContext context, String url) async {
    final t = AppLocalizations.of(context);
    bool ok = false;
    try {
      ok = await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
    } catch (_) {
      ok = false;
    }
    if (!ok && context.mounted) {
      await Clipboard.setData(ClipboardData(text: url));
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(t.nameAboutOpenFailed)));
      }
    }
  }
}

/// Expandable bilingual FAQ. Each entry is a (question, answer) ARB pair.
class NameAboutFaq extends StatelessWidget {
  const NameAboutFaq({super.key});

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final items = <List<String>>[
      [t.nameAboutFaqClearedQ, t.nameAboutFaqClearedA],
      [t.nameAboutFaqWhyClassesQ, t.nameAboutFaqWhyClassesA],
      [t.nameAboutFaqSearchQ, t.nameAboutFaqSearchA],
      [t.nameAboutFaqAttorneyQ, t.nameAboutFaqAttorneyA],
      [t.nameAboutFaqGlobalQ, t.nameAboutFaqGlobalA],
      [t.nameAboutFaqChangeQ, t.nameAboutFaqChangeA],
    ];
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      NameAboutSectionTitle(text: t.nameAboutFaqTitle, icon: Icons.help_outline),
      Card(
        clipBehavior: Clip.antiAlias,
        child: Column(
          children: [
            for (var i = 0; i < items.length; i++) ...[
              if (i > 0) const Divider(height: 1),
              ExpansionTile(
                shape: const Border(),
                collapsedShape: const Border(),
                leading: const Icon(Icons.question_answer_outlined),
                title: Text(items[i][0],
                    style: const TextStyle(fontWeight: FontWeight.w600)),
                childrenPadding: const EdgeInsets.fromLTRB(Gap.lg, 0, Gap.lg, Gap.md),
                expandedCrossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(items[i][1], style: const TextStyle(height: 1.5)),
                ],
              ),
            ],
          ],
        ),
      ),
    ]);
  }
}
