import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../state.dart';
import '../theme.dart';
import '../name_about_api.dart';
import '../widgets/skeleton.dart';
import '../widgets/nameabout_sections.dart';
import '../widgets/nameabout_checklist.dart';
import '../l10n/app_localizations.dart';
import '../services/error_kind.dart' show honestFailText; // qa2

/// Assisto — "About the Assisto name" (ADVANCED, SPEC v2.1 §21).
///
/// An honest, info-only surface explaining the meaning and brand story behind
/// the name, which trademark (Nice) classes matter — with 9 & 42 emphasised —
/// the current trademark-check STATUS (always "research pending, no clearance
/// claimed"), a DIY trademark checklist the owner works through (search the BD
/// DPDT portal, the relevant classes, app stores / domains, then consult an
/// attorney), the official source links (DPDT portal + WIPO), and an FAQ.
///
/// CRITICAL, by design and repeated: this surface is marked prominently and
/// repeatedly "informational only — NOT a legal trademark clearance and NOT
/// legal advice". A high-contrast disclaimer banner renders at the top, a
/// compact reminder renders again lower down, and the status can never read as
/// "cleared". The disclaimer uses local bilingual ARB strings so it is shown
/// even if the backend omits its own note.
///
/// HARD RULE: ZERO Bangla glyphs anywhere in this file; all copy is ARB-backed
/// and read through `AppLocalizations`. New keys are emitted to
/// `.phaseB/up_nameabout_arb.json` for the integrator.
class NameAboutScreen extends StatefulWidget {
  const NameAboutScreen({super.key});
  @override
  State<NameAboutScreen> createState() => _NameAboutScreenState();
}

class _NameAboutScreenState extends State<NameAboutScreen> {
  Map<String, dynamic>? _data;
  bool _loading = true;
  bool _error = false;
  Object? _failCause; // qa2: why it failed (5xx = our server, not the internet)
  bool _offline = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = false;
      _offline = false;
    });
    try {
      _data = await context.read<AppState>().api.nameAbout();
    } catch (e) {
      _error = true;
      _failCause = e;
      // Best-effort offline hint (network-ish errors render the offline copy).
      final s = e.toString().toLowerCase();
      _offline = s.contains('socket') ||
          s.contains('network') ||
          s.contains('connection') ||
          s.contains('failed host');
    }
    if (mounted) setState(() => _loading = false);
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(t.nameAboutTitle)),
      body: _loading
          ? const SkeletonList(count: 6)
          : _error
              ? StateMessage(
                  icon: _offline ? Icons.wifi_off : Icons.cloud_off,
                  title: _offline ? t.nameAboutOfflineTitle : t.nameAboutErrorTitle,
                  message: _offline
                      ? t.nameAboutOfflineBody
                      : honestFailText(t, _failCause, otherwise: t.nameAboutErrorBody),
                  tint: Brand.danger,
                  action: FilledButton.tonal(
                      onPressed: _load, child: Text(t.retry)),
                )
              : _data == null || _data!.isEmpty
                  ? _EmptyWithDisclaimer(onRetry: _load)
                  : _body(context, t),
    );
  }

  Widget _body(BuildContext context, AppLocalizations t) {
    final data = _data!;
    final name = (data['name'] ?? 'Assisto').toString();
    final meaning = (data['meaning'] ?? '').toString();
    final status = (data['status'] ?? '').toString();
    final serverDisclaimer = (data['disclaimer'] ?? '').toString();
    final classes = (data['classes'] as List?) ?? const [];
    final checklist = ((data['checklist'] as List?) ?? const [])
        .map((e) => e.toString())
        .where((s) => s.isNotEmpty)
        .toList();
    final scheme = Theme.of(context).colorScheme;

    final classWidgets = <Widget>[];
    for (final c in classes) {
      if (c is Map) {
        final n = int.tryParse('${c['class']}') ?? 0;
        classWidgets.add(NameAboutClassCard(number: n, note: (c['note'] ?? '').toString()));
      }
    }

    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        padding: const EdgeInsets.all(Gap.lg),
        children: [
          // ---- Hero: the name ----
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(Gap.lg),
            decoration: BoxDecoration(
              gradient: Brand.gradient,
              borderRadius: BorderRadius.circular(Radii.lg),
            ),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(t.nameAboutNameLabel,
                  style: const TextStyle(
                      color: Colors.white, fontWeight: FontWeight.w600)),
              const SizedBox(height: Gap.xs),
              Text(name,
                  style: const TextStyle(
                      color: Colors.white,
                      fontSize: 28,
                      fontWeight: FontWeight.w800)),
              const SizedBox(height: Gap.sm),
              Text(t.nameAboutStatusPending,
                  style: const TextStyle(color: Colors.white, height: 1.4, fontSize: 13)),
            ]),
          ),
          const SizedBox(height: Gap.lg),

          // ---- Disclaimer (prominent, bilingual, always shown, TOP) ----
          const NameAboutDisclaimerBanner(),
          const SizedBox(height: Gap.lg),

          // ---- Brand story / meaning ----
          NameAboutBrandStory(meaning: meaning),
          const SizedBox(height: Gap.lg),

          // ---- Trademark-check status ----
          NameAboutSectionTitle(
              text: t.nameAboutStatusLabel, icon: Icons.fact_check_outlined),
          NameAboutStatusCard(status: status),
          const SizedBox(height: Gap.lg),

          // ---- Relevant trademark classes (9 & 42 emphasised) ----
          if (classWidgets.isNotEmpty) ...[
            NameAboutSectionTitle(
                text: t.nameAboutClassesLabel, icon: Icons.category_outlined),
            Text(t.nameAboutClassesHint,
                style: TextStyle(
                    color: scheme.onSurfaceVariant, fontSize: 13, height: 1.45)),
            const SizedBox(height: Gap.sm),
            ...classWidgets,
            const SizedBox(height: Gap.lg),
          ],

          // ---- DIY trademark checklist ----
          NameAboutChecklist(serverItems: checklist),
          const SizedBox(height: Gap.lg),

          // ---- Official sources ----
          const NameAboutSourceNote(),
          const SizedBox(height: Gap.lg),

          // ---- FAQ ----
          const NameAboutFaq(),
          const SizedBox(height: Gap.lg),

          // ---- Disclaimer reminder (compact, repeated LOWER on page) ----
          const NameAboutDisclaimerBanner(compact: true),

          // ---- Server-supplied note (reinforcement, if present) ----
          if (serverDisclaimer.isNotEmpty) ...[
            const SizedBox(height: Gap.md),
            Text(serverDisclaimer,
                style: TextStyle(
                    color: scheme.onSurfaceVariant,
                    fontSize: 12,
                    height: 1.5,
                    fontStyle: FontStyle.italic)),
          ],
        ],
      ),
    );
  }
}

/// Empty state that STILL shows the disclaimer — the info-only framing must
/// survive even when there is no payload to render.
class _EmptyWithDisclaimer extends StatelessWidget {
  final Future<void> Function() onRetry;
  const _EmptyWithDisclaimer({required this.onRetry});

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    return ListView(
      padding: const EdgeInsets.all(Gap.lg),
      children: [
        const NameAboutDisclaimerBanner(),
        const SizedBox(height: Gap.xl),
        Icon(Icons.badge_outlined,
            size: 48, color: Theme.of(context).colorScheme.onSurfaceVariant),
        const SizedBox(height: Gap.md),
        Text(t.nameAboutEmptyTitle,
            textAlign: TextAlign.center,
            style: Theme.of(context)
                .textTheme
                .titleMedium
                ?.copyWith(fontWeight: FontWeight.w700)),
        const SizedBox(height: Gap.xs),
        Text(t.nameAboutEmptyBody,
            textAlign: TextAlign.center,
            style: TextStyle(
                color: Theme.of(context).colorScheme.onSurfaceVariant, height: 1.45)),
        const SizedBox(height: Gap.lg),
        Center(
          child: FilledButton.tonal(onPressed: onRetry, child: Text(t.retry)),
        ),
      ],
    );
  }
}
