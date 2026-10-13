import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../state.dart';
import '../theme.dart';
import '../l10n/app_localizations.dart';
import '../widgets/health_api.dart';
import '../widgets/health_medicine_card.dart';

/// Medicine DATABASE (drug lookup) — distinct from the medicine-reminder screen.
/// Search a brand or generic to see generic / strength / form / manufacturer /
/// indicative price / uses / how-to-take, plus same-generic alternatives.
/// Benchmarked vs the SAFE lookup subset of 1mg / Medisafe.
///
/// LICENSING: ships a SMALL curated DGDA-style SAMPLE set (clearly badged).
/// Full data shows a needs-data state until DGDA data is wired. Every record
/// and alternative carries the "don't switch without a doctor/pharmacist"
/// warning. We never copy DIMS / MedEx or any proprietary DB.
class MedicineDbScreen extends StatefulWidget {
  const MedicineDbScreen({super.key});
  @override
  State<MedicineDbScreen> createState() => _MedicineDbScreenState();
}

class _MedicineDbScreenState extends State<MedicineDbScreen> {
  final _search = TextEditingController();

  List<Map<String, dynamic>> _results = [];
  Map<String, dynamic> _meta = {};
  bool _searched = false;
  bool _loading = false;
  bool _error = false;

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  Future<void> _run() async {
    final q = _search.text.trim();
    if (q.isEmpty) return;
    FocusScope.of(context).unfocus();
    setState(() {
      _loading = true;
      _error = false;
      _searched = true;
    });
    try {
      final r = await context.read<AppState>().api.medicineDbSearch(q);
      if (!mounted) return;
      setState(() {
        _results = ((r['results'] ?? []) as List).cast<Map<String, dynamic>>();
        _meta = (r['meta'] ?? {}) as Map<String, dynamic>;
      });
    } catch (_) {
      if (mounted) setState(() => _error = true);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final isSample = _meta['is_sample'] == true;
    final sampleNotice = (_meta['sample_notice'] ?? '').toString();
    final switchWarning = (_meta['switch_warning'] ?? '').toString();

    return Scaffold(
      appBar: AppBar(title: Text(t.medicineDbTitle)),
      body: ListView(padding: const EdgeInsets.all(Gap.lg), children: [
        // search
        TextField(
          controller: _search,
          decoration: InputDecoration(
            hintText: t.medicineDbSearchHint,
            prefixIcon: const Icon(Icons.search),
            suffixIcon: IconButton(
              icon: const Icon(Icons.arrow_forward),
              onPressed: _run,
            ),
          ),
          onSubmitted: (_) => _run(),
          textInputAction: TextInputAction.search,
        ),
        const SizedBox(height: Gap.md),

        // sample-data badge
        if (_searched && isSample && sampleNotice.isNotEmpty)
          Container(
            padding: const EdgeInsets.all(Gap.md),
            margin: const EdgeInsets.only(bottom: Gap.md),
            decoration: BoxDecoration(
              color: Brand.warning.withOpacity(0.15),
              borderRadius: BorderRadius.circular(Radii.md),
            ),
            child: Row(children: [
              const Icon(Icons.science_outlined, size: 18, color: Color(0xFF8A6D00)),
              const SizedBox(width: Gap.sm),
              Expanded(child: Text(sampleNotice,
                  style: const TextStyle(fontSize: 12, color: Color(0xFF8A6D00)))),
            ]),
          ),

        // switch-warning (always, once results exist)
        if (_searched && switchWarning.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(bottom: Gap.md),
            child: Row(children: [
              Icon(Icons.warning_amber_rounded, size: 16, color: scheme.error),
              const SizedBox(width: Gap.xs),
              Expanded(child: Text(switchWarning,
                  style: TextStyle(fontSize: 12, color: scheme.error, fontWeight: FontWeight.w600))),
            ]),
          ),

        if (_loading)
          const Center(child: Padding(
              padding: EdgeInsets.all(Gap.xl), child: CircularProgressIndicator()))
        else if (_error)
          Padding(
            padding: const EdgeInsets.all(Gap.xl),
            child: Column(children: [
              Text(t.medicineDbLoadError, textAlign: TextAlign.center),
              const SizedBox(height: Gap.md),
              OutlinedButton.icon(
                onPressed: _run,
                icon: const Icon(Icons.refresh),
                label: Text(t.retry),
              ),
            ]),
          )
        else if (!_searched)
          _IntroState(
            title: t.medicineDbIntroTitle,
            body: t.medicineDbIntroBody,
          )
        else if (_results.isEmpty)
          // clean needs-data / no-result state
          _NeedsDataState(
            title: t.medicineDbNeedsDataTitle,
            message: t.medicineDbNeedsDataBody,
          )
        else
          for (final rec in _results) ...[
            HealthMedicineCard(record: rec),
            const SizedBox(height: Gap.md),
          ],
      ]),
    );
  }
}

class _IntroState extends StatelessWidget {
  final String title, body;
  const _IntroState({required this.title, required this.body});
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(top: Gap.xl),
      child: Column(children: [
        Icon(Icons.medication_outlined, size: 48, color: scheme.primary),
        const SizedBox(height: Gap.md),
        Text(title, style: Theme.of(context).textTheme.titleMedium,
            textAlign: TextAlign.center),
        const SizedBox(height: Gap.sm),
        Text(body, textAlign: TextAlign.center,
            style: TextStyle(color: scheme.onSurfaceVariant)),
      ]),
    );
  }
}

class _NeedsDataState extends StatelessWidget {
  final String title, message;
  const _NeedsDataState({required this.title, required this.message});
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(top: Gap.xl),
      child: Column(children: [
        Icon(Icons.inventory_2_outlined, size: 48, color: scheme.onSurfaceVariant),
        const SizedBox(height: Gap.md),
        Text(title, style: Theme.of(context).textTheme.titleMedium,
            textAlign: TextAlign.center),
        const SizedBox(height: Gap.sm),
        Text(message, textAlign: TextAlign.center,
            style: TextStyle(color: scheme.onSurfaceVariant)),
      ]),
    );
  }
}
