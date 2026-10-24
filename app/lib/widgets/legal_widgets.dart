import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';
import '../theme.dart';
import '../l10n/app_localizations.dart';
import '../services/action_feedback.dart'; // db1
import '../services/error_kind.dart' show honestFailText; // qa2

/// Legal / policy centre — ADVANCED shared widgets (SPEC v2.1 §21/§22).
///
/// All copy (titles, section headings, bodies, stamp, contact) is backend DATA
/// rendered at runtime; this file holds only chrome. Zero Bangla literals in
/// .dart — every visible chrome string comes from the ARB (`legal*` keys).

/// A legal page as returned by `/legal/<key>` (superset-tolerant).
class LegalPageData {
  final String key;
  final String title;
  final String stamp;
  /// false = owner-reviewed page (no red DRAFT banner; the stamp is a plain
  /// 'updated …' line).
  final bool draft;
  final String? lastUpdated;
  final String? contact;
  final String body; // flat back-compat body
  final List<LegalSection> sections;

  /// l1-launch: the full public page on lifeassisto.com (privacy / terms /
  /// delete-account); null when the page is in-app only.
  final String? webUrl;

  const LegalPageData({
    required this.key,
    required this.title,
    required this.stamp,
    this.draft = true,
    required this.body,
    required this.sections,
    this.lastUpdated,
    this.contact,
    this.webUrl,
  });

  factory LegalPageData.fromJson(Map<String, dynamic> j) {
    final raw = (j['sections'] as List?) ?? const [];
    final secs = raw
        .whereType<Map>()
        .map((m) => LegalSection.fromJson(m.cast<String, dynamic>()))
        .toList();
    final body = (j['body'] as String?) ?? '';
    // Back-compat: if the backend is old (no sections) synthesise one so the
    // viewer still renders rather than showing an empty page.
    final sections = secs.isNotEmpty
        ? secs
        : (body.isEmpty
            ? const <LegalSection>[]
            : [LegalSection(heading: (j['title'] as String?) ?? '', body: body)]);
    return LegalPageData(
      key: (j['key'] as String?) ?? '',
      title: (j['title'] as String?) ?? '',
      stamp: (j['stamp'] as String?) ?? '',
      draft: j['draft'] != false,
      lastUpdated: j['last_updated'] as String?,
      contact: j['contact'] as String?,
      webUrl: _httpsOrNull(j['web_url']),
      body: body,
      sections: sections,
    );
  }

  /// Only an https URL is ever opened (the value comes from our backend).
  static String? _httpsOrNull(Object? v) {
    if (v is! String || v.isEmpty) return null;
    final u = Uri.tryParse(v);
    return (u != null && u.scheme == 'https' && u.host.isNotEmpty) ? v : null;
  }

  /// Does this page (title or any section) match [q] (case-insensitive)?
  bool matches(String q) {
    if (q.isEmpty) return true;
    final needle = q.toLowerCase();
    if (title.toLowerCase().contains(needle)) return true;
    return sections.any((s) => s.matches(needle));
  }
}

class LegalSection {
  final String heading;
  final String body;
  const LegalSection({required this.heading, required this.body});

  factory LegalSection.fromJson(Map<String, dynamic> j) => LegalSection(
        heading: (j['heading'] as String?) ?? '',
        body: (j['body'] as String?) ?? '',
      );

  bool matches(String lowerNeedle) =>
      heading.toLowerCase().contains(lowerNeedle) ||
      body.toLowerCase().contains(lowerNeedle);
}

/// The §22 DRAFT banner. Always shown on every page — never present unreviewed
/// legal text as final. High-contrast (errorContainer) in light and dark.
class LegalDraftBanner extends StatelessWidget {
  final String stamp;
  const LegalDraftBanner({super.key, required this.stamp});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(Gap.md),
      decoration: BoxDecoration(
        color: scheme.errorContainer,
        borderRadius: BorderRadius.circular(Radii.sm),
      ),
      child: Row(children: [
        Icon(Icons.gavel_rounded, color: scheme.onErrorContainer, size: 20),
        const SizedBox(width: Gap.sm),
        Expanded(
          child: Text(
            stamp,
            style: TextStyle(
                color: scheme.onErrorContainer, fontWeight: FontWeight.w600),
          ),
        ),
      ]),
    );
  }
}

/// A searchable text field for the policy index.
class LegalSearchField extends StatelessWidget {
  final TextEditingController controller;
  final ValueChanged<String> onChanged;
  const LegalSearchField(
      {super.key, required this.controller, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    return TextField(
      controller: controller,
      onChanged: onChanged,
      textInputAction: TextInputAction.search,
      decoration: InputDecoration(
        hintText: t.legalSearchHint,
        prefixIcon: const Icon(Icons.search),
        suffixIcon: controller.text.isEmpty
            ? null
            : IconButton(
                tooltip: t.legalClearSearch,
                icon: const Icon(Icons.close),
                onPressed: () {
                  controller.clear();
                  onChanged('');
                },
              ),
        isDense: true,
        border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(Radii.sm)),
      ),
    );
  }
}

/// One policy page as an expandable, searchable section list. A query (if any)
/// is highlighted-by-expansion: matching sections auto-expand.
class LegalSectionList extends StatelessWidget {
  final List<LegalSection> sections;
  final String query;
  const LegalSectionList(
      {super.key, required this.sections, this.query = ''});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final needle = query.toLowerCase();
    return Column(
      children: [
        for (final s in sections)
          Card(
            margin: const EdgeInsets.only(bottom: Gap.sm),
            child: Theme(
              // Remove the default divider lines for a cleaner look.
              data: Theme.of(context)
                  .copyWith(dividerColor: Colors.transparent),
              child: ExpansionTile(
                initiallyExpanded:
                    needle.isNotEmpty && s.matches(needle),
                tilePadding:
                    const EdgeInsets.symmetric(horizontal: Gap.lg),
                childrenPadding: const EdgeInsets.fromLTRB(
                    Gap.lg, 0, Gap.lg, Gap.lg),
                title: Text(s.heading,
                    style: const TextStyle(
                        fontWeight: FontWeight.w700, fontSize: 15)),
                children: [
                  Align(
                    alignment: Alignment.centerLeft,
                    child: SelectableText(
                      s.body,
                      style: TextStyle(
                          fontSize: 14,
                          height: 1.55,
                          color: scheme.onSurface),
                    ),
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }
}

/// A "last updated · contact" footer row with a copy-page affordance.
class LegalPageFooter extends StatelessWidget {
  final LegalPageData page;
  const LegalPageFooter({super.key, required this.page});

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final meta = <String>[
      if (page.lastUpdated != null && page.lastUpdated!.isNotEmpty)
        '${t.legalLastUpdated}: ${page.lastUpdated}',
    ];
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      if (meta.isNotEmpty)
        Text(meta.join('   •   '),
            style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant)),
      if (page.contact != null && page.contact!.isNotEmpty) ...[
        const SizedBox(height: Gap.sm),
        Row(children: [
          Icon(Icons.help_outline, size: 16, color: scheme.onSurfaceVariant),
          const SizedBox(width: 6),
          Expanded(
            child: Text(page.contact!,
                style:
                    TextStyle(fontSize: 12, color: scheme.onSurfaceVariant)),
          ),
        ]),
      ],
      if (page.webUrl != null) ...[
        const SizedBox(height: Gap.md),
        // l1-launch: the full, public version (the one Google Play links to).
        SizedBox(
          width: double.infinity,
          child: OutlinedButton.icon(
            icon: const Icon(Icons.open_in_new, size: 18),
            label: Text(t.l1LegalOpenWeb, textAlign: TextAlign.center),
            onPressed: () async {
              try {
                await launchUrl(Uri.parse(page.webUrl!),
                    mode: LaunchMode.externalApplication);
              } catch (e) {
                showActionFailed(context, 'legal.openWeb', e, open: true); // db1
              }
            },
          ),
        ),
      ],
      const SizedBox(height: Gap.sm),
      Align(
        alignment: Alignment.centerLeft,
        child: TextButton.icon(
          icon: const Icon(Icons.copy, size: 16),
          label: Text(t.legalCopyPage),
          onPressed: () {
            final text = '${page.title}\n\n${page.stamp}\n\n${page.body}';
            Clipboard.setData(ClipboardData(text: text));
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text(t.copied)),
            );
          },
        ),
      ),
    ]);
  }
}

/// Shared states: loading, offline/error (with retry) and an empty-search view.
class LegalLoading extends StatelessWidget {
  const LegalLoading({super.key});
  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    return Center(
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        const CircularProgressIndicator(),
        const SizedBox(height: Gap.md),
        Text(t.legalLoading,
            style: Theme.of(context).textTheme.bodyMedium),
      ]),
    );
  }
}

class LegalErrorState extends StatelessWidget {
  final VoidCallback onRetry;
  final Object? error; // qa2: a 5xx is our server, not the user's internet
  const LegalErrorState({super.key, required this.onRetry, this.error});
  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(Gap.xl),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const Icon(Icons.cloud_off, size: 44),
          const SizedBox(height: Gap.sm),
          Text(honestFailText(t, error, otherwise: t.legalOffline),
              textAlign: TextAlign.center),
          const SizedBox(height: Gap.md),
          FilledButton.tonalIcon(
              onPressed: onRetry,
              icon: const Icon(Icons.refresh),
              label: Text(t.retry)),
        ]),
      ),
    );
  }
}

class LegalEmptySearch extends StatelessWidget {
  final String query;
  const LegalEmptySearch({super.key, required this.query});
  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.all(Gap.xl),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Icon(Icons.search_off, size: 40, color: scheme.onSurfaceVariant),
        const SizedBox(height: Gap.sm),
        Text(t.legalNoResults,
            textAlign: TextAlign.center,
            style: TextStyle(color: scheme.onSurfaceVariant)),
      ]),
    );
  }
}
