import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../state.dart';
import '../theme.dart';
import '../name_about_api.dart';
import '../widgets/skeleton.dart';
import '../l10n/app_localizations.dart';

/// Assisto P15 — "About the Assisto name" (name / trademark research note).
///
/// Shows the structured name/trademark check summary the backend returns for
/// 'Assisto' (meaning, relevant Nice classes, owner research checklist,
/// current status) and PROMINENTLY shows the disclaimer that this is
/// informational only — NOT a legal trademark clearance and NOT legal advice.
/// The disclaimer renders from local bilingual strings so it is shown even if
/// the payload omits one, and is reinforced by the server-supplied note.
class NameAboutScreen extends StatefulWidget {
  const NameAboutScreen({super.key});
  @override
  State<NameAboutScreen> createState() => _NameAboutScreenState();
}

class _NameAboutScreenState extends State<NameAboutScreen> {
  Map<String, dynamic>? _data;
  bool _loading = true;
  bool _error = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = false;
    });
    try {
      _data = await context.read<AppState>().api.nameAbout();
    } catch (_) {
      _error = true;
    }
    if (mounted) setState(() => _loading = false);
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(t.nameAboutTitle)),
      body: _loading
          ? const SkeletonList(count: 5)
          : _error
              ? StateMessage(
                  icon: Icons.cloud_off,
                  title: t.nameAboutErrorTitle,
                  message: t.nameAboutErrorBody,
                  tint: Brand.danger,
                  action: FilledButton.tonal(
                      onPressed: _load, child: Text(t.retry)),
                )
              : _data == null || _data!.isEmpty
                  ? StateMessage(
                      icon: Icons.badge_outlined,
                      title: t.nameAboutEmptyTitle,
                      message: t.nameAboutEmptyBody,
                      action: FilledButton.tonal(
                          onPressed: _load, child: Text(t.retry)),
                    )
                  : _body(context, t),
    );
  }

  Widget _body(BuildContext context, AppLocalizations t) {
    final scheme = Theme.of(context).colorScheme;
    final data = _data!;
    final name = (data['name'] ?? 'Assisto').toString();
    final meaning = (data['meaning'] ?? '').toString();
    final status = (data['status'] ?? '').toString();
    final serverDisclaimer = (data['disclaimer'] ?? '').toString();
    final classes = (data['classes'] as List?) ?? const [];
    final checklist = (data['checklist'] as List?) ?? const [];

    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        padding: const EdgeInsets.all(Gap.lg),
        children: [
          // ---- Hero: the name ----
          Container(
            padding: const EdgeInsets.all(Gap.lg),
            decoration: BoxDecoration(
              gradient: Brand.gradient,
              borderRadius: BorderRadius.circular(Radii.lg),
            ),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(t.nameAboutNameLabel,
                  style: const TextStyle(
                      color: Colors.white70, fontWeight: FontWeight.w600)),
              const SizedBox(height: Gap.xs),
              Text(name,
                  style: const TextStyle(
                      color: Colors.white,
                      fontSize: 28,
                      fontWeight: FontWeight.w800)),
              if (meaning.isNotEmpty) ...[
                const SizedBox(height: Gap.sm),
                Text(meaning,
                    style: const TextStyle(
                        color: Colors.white, height: 1.4, fontSize: 14)),
              ],
            ]),
          ),
          const SizedBox(height: Gap.lg),

          // ---- Disclaimer (prominent, bilingual, always shown) ----
          _DisclaimerCard(
            title: t.nameAboutDisclaimerTitle,
            text: t.nameAboutDisclaimer,
          ),
          const SizedBox(height: Gap.lg),

          // ---- Status ----
          if (status.isNotEmpty) ...[
            Text(t.nameAboutStatusLabel,
                style: Theme.of(context)
                    .textTheme
                    .titleMedium
                    ?.copyWith(fontWeight: FontWeight.w700)),
            const SizedBox(height: Gap.sm),
            Container(
              padding: const EdgeInsets.all(Gap.md),
              decoration: BoxDecoration(
                color: Brand.warning.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(Radii.sm),
              ),
              child: Row(children: [
                const Icon(Icons.hourglass_bottom, color: Brand.warning),
                const SizedBox(width: Gap.sm),
                Expanded(
                    child: Text(status, style: const TextStyle(height: 1.4))),
              ]),
            ),
            const SizedBox(height: Gap.lg),
          ],

          // ---- Relevant trademark classes ----
          if (classes.isNotEmpty) ...[
            Text(t.nameAboutClassesLabel,
                style: Theme.of(context)
                    .textTheme
                    .titleMedium
                    ?.copyWith(fontWeight: FontWeight.w700)),
            const SizedBox(height: Gap.sm),
            for (final c in classes)
              if (c is Map)
                Card(
                  margin: const EdgeInsets.only(bottom: Gap.sm),
                  child: ListTile(
                    leading: CircleAvatar(
                      backgroundColor: scheme.primary.withValues(alpha: 0.12),
                      child: Text('${c['class'] ?? '?'}',
                          style: TextStyle(
                              color: scheme.primary,
                              fontWeight: FontWeight.w700)),
                    ),
                    title: Text(t.nameAboutClassLabel('${c['class'] ?? '?'}')),
                    subtitle: Text((c['note'] ?? '').toString()),
                  ),
                ),
            const SizedBox(height: Gap.lg),
          ],

          // ---- Owner research checklist ----
          if (checklist.isNotEmpty) ...[
            Text(t.nameAboutChecklistLabel,
                style: Theme.of(context)
                    .textTheme
                    .titleMedium
                    ?.copyWith(fontWeight: FontWeight.w700)),
            const SizedBox(height: Gap.xs),
            Text(t.nameAboutChecklistHint,
                style: TextStyle(
                    color: scheme.onSurfaceVariant, fontSize: 12, height: 1.4)),
            const SizedBox(height: Gap.sm),
            Card(
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: Gap.xs),
                child: Column(
                  children: [
                    for (final item in checklist)
                      ListTile(
                        leading: Icon(Icons.check_circle_outline,
                            color: scheme.primary),
                        title: Text(item.toString(),
                            style: const TextStyle(height: 1.4)),
                        dense: true,
                      ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: Gap.lg),
          ],

          // ---- Server-supplied disclaimer note (reinforcement) ----
          if (serverDisclaimer.isNotEmpty)
            Text(serverDisclaimer,
                style: TextStyle(
                    color: scheme.onSurfaceVariant,
                    fontSize: 12,
                    height: 1.5,
                    fontStyle: FontStyle.italic)),
        ],
      ),
    );
  }
}

/// Prominent, high-contrast legal-clearance disclaimer. Uses the error
/// container colours for a WCAG-safe foreground/background pairing.
class _DisclaimerCard extends StatelessWidget {
  final String title;
  final String text;
  const _DisclaimerCard({required this.title, required this.text});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(Gap.md),
      decoration: BoxDecoration(
        color: scheme.errorContainer,
        borderRadius: BorderRadius.circular(Radii.md),
        border: Border.all(color: scheme.error.withValues(alpha: 0.4)),
      ),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Icon(Icons.gavel_rounded, color: scheme.onErrorContainer),
        const SizedBox(width: Gap.sm),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(title,
                style: TextStyle(
                    color: scheme.onErrorContainer,
                    fontWeight: FontWeight.w800)),
            const SizedBox(height: Gap.xs),
            Text(text,
                style: TextStyle(
                    color: scheme.onErrorContainer, height: 1.5, fontSize: 13)),
          ]),
        ),
      ]),
    );
  }
}
