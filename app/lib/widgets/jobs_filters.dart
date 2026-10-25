import 'package:flutter/material.dart';
import '../l10n/app_localizations.dart';
import '../theme.dart';
import 'jobs_store.dart';

/// Advanced discovery filters (category, location, salary, type, experience)
/// for the Job Hunter — SPEC v2.1 §21. A bottom sheet returning a [JobFilter].
/// All labels come from the ARB bundle (zero Bangla literals here).
class JobsFilterSheet extends StatefulWidget {
  final JobFilter initial;
  const JobsFilterSheet({super.key, required this.initial});

  static Future<JobFilter?> show(BuildContext context, JobFilter initial) =>
      showModalBottomSheet<JobFilter>(
        context: context,
        isScrollControlled: true,
        showDragHandle: true,
        builder: (_) => JobsFilterSheet(initial: initial),
      );

  @override
  State<JobsFilterSheet> createState() => _JobsFilterSheetState();
}

class _JobsFilterSheetState extends State<JobsFilterSheet> {
  late String _category, _jobType, _experience;
  late TextEditingController _location, _minSal, _maxSal;

  @override
  void initState() {
    super.initState();
    _category = widget.initial.category;
    _jobType = widget.initial.jobType;
    _experience = widget.initial.experience;
    _location = TextEditingController(text: widget.initial.location);
    _minSal = TextEditingController(
        text: widget.initial.minSalary?.toString() ?? '');
    _maxSal = TextEditingController(
        text: widget.initial.maxSalary?.toString() ?? '');
  }

  @override
  void dispose() {
    _location.dispose();
    _minSal.dispose();
    _maxSal.dispose();
    super.dispose();
  }

  String _catLabel(AppLocalizations tr, String k) => {
        'it': tr.jobsCatIt, 'accounts': tr.jobsCatAccounts, 'sales': tr.jobsCatSales,
        'ngo': tr.jobsCatNgo, 'garments': tr.jobsCatGarments,
        'education': tr.jobsCatEducation, 'engineering': tr.jobsCatEngineering,
        'health': tr.jobsCatHealth, 'gov': tr.jobsCatGov, 'other': tr.jobsCatOther,
      }[k]!;

  String _typeLabel(AppLocalizations tr, String k) => {
        'full_time': tr.jobsTypeFullTime, 'part_time': tr.jobsTypePartTime,
        'contract': tr.jobsTypeContract, 'remote': tr.jobsTypeRemote,
        'internship': tr.jobsTypeInternship,
      }[k]!;

  String _expLabel(AppLocalizations tr, String k) => {
        'entry': tr.jobsExpEntry, 'mid': tr.jobsExpMid, 'senior': tr.jobsExpSenior,
      }[k]!;

  @override
  Widget build(BuildContext context) {
    final tr = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final pad = MediaQuery.of(context).viewInsets.bottom;
    return Padding(
      padding: EdgeInsets.fromLTRB(Gap.lg, 0, Gap.lg, Gap.lg + pad),
      child: SingleChildScrollView(
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(tr.jobsFiltersTitle,
              style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700)),
          const SizedBox(height: Gap.lg),
          _sectionLabel(tr.jobsFilterCategory, scheme),
          Wrap(spacing: Gap.sm, runSpacing: Gap.sm, children: [
            for (final c in kCategories)
              ChoiceChip(
                label: Text(_catLabel(tr, c)),
                selected: _category == c,
                onSelected: (_) => setState(() => _category = _category == c ? '' : c),
              ),
          ]),
          const SizedBox(height: Gap.lg),
          _sectionLabel(tr.jobsFilterType, scheme),
          Wrap(spacing: Gap.sm, runSpacing: Gap.sm, children: [
            for (final t in kJobTypes)
              ChoiceChip(
                label: Text(_typeLabel(tr, t)),
                selected: _jobType == t,
                onSelected: (_) => setState(() => _jobType = _jobType == t ? '' : t),
              ),
          ]),
          const SizedBox(height: Gap.lg),
          _sectionLabel(tr.jobsFilterExperience, scheme),
          Wrap(spacing: Gap.sm, runSpacing: Gap.sm, children: [
            for (final e in kExperience)
              ChoiceChip(
                label: Text(_expLabel(tr, e)),
                selected: _experience == e,
                onSelected: (_) => setState(() => _experience = _experience == e ? '' : e),
              ),
          ]),
          const SizedBox(height: Gap.lg),
          TextField(
            controller: _location,
            decoration: InputDecoration(
              labelText: tr.jobsFilterLocation,
              prefixIcon: const Icon(Icons.location_on_rounded),
              border: const OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: Gap.md),
          _sectionLabel(tr.jobsFilterSalary, scheme),
          Row(children: [
            Expanded(child: TextField(
              controller: _minSal,
              keyboardType: TextInputType.number,
              decoration: InputDecoration(labelText: tr.jobsSalaryMin, border: const OutlineInputBorder()),
            )),
            const SizedBox(width: Gap.md),
            Expanded(child: TextField(
              controller: _maxSal,
              keyboardType: TextInputType.number,
              decoration: InputDecoration(labelText: tr.jobsSalaryMax, border: const OutlineInputBorder()),
            )),
          ]),
          const SizedBox(height: Gap.xl),
          Row(children: [
            Expanded(child: OutlinedButton(
              onPressed: () => Navigator.pop(context, JobFilter(query: widget.initial.query)),
              child: Text(tr.jobsClearFilters),
            )),
            const SizedBox(width: Gap.md),
            Expanded(child: FilledButton(
              onPressed: () => Navigator.pop(context, JobFilter(
                query: widget.initial.query,
                category: _category,
                location: _location.text.trim(),
                jobType: _jobType,
                experience: _experience,
                minSalary: int.tryParse(_minSal.text.trim()),
                maxSalary: int.tryParse(_maxSal.text.trim()),
              )),
              child: Text(tr.jobsApplyFilters),
            )),
          ]),
        ]),
      ),
    );
  }

  Widget _sectionLabel(String text, ColorScheme scheme) => Padding(
        padding: const EdgeInsets.only(bottom: Gap.sm),
        child: Text(text,
            style: TextStyle(fontWeight: FontWeight.w700, color: scheme.onSurface)),
      );
}
