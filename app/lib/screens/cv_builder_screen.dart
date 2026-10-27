import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';

import '../ads/ad_banner_slot.dart' show AdBannerSlot;
import '../l10n/app_localizations.dart';
import '../state.dart';
import '../theme.dart';
import '../widgets/skeleton.dart';
import '../services/error_kind.dart' show honestFailText; // qa2

/// CV / RESUME BUILDER — standalone, KEY-FREE (student & job-seeker front door).
///
/// The student/job-seeker finally gets a dedicated place to BUILD a CV. The
/// user fills a structured form — contact header (name, headline, phone, email,
/// location), then repeatable EDUCATION, EXPERIENCE and SKILLS sections — and
/// Assisto assembles it into a clean, deterministic PLAIN-TEXT resume they can
/// PREVIEW, COPY to the clipboard or SHARE. It WORKS WITH NO AI KEY: formatting
/// is pure string assembly, identical every time.
///
/// HONEST AI SEAM: an optional "polish with AI" affordance is shown as a clearly
/// labelled, documented key-gated state ("connect an AI key" — Integrations →
/// anthropic). It NEVER fabricates output and the whole tool is fully usable
/// without it.
///
/// Persistence (generic api helpers, no api.dart edit — PaCollectionItem
/// precedent; collection `cv` appended to GENERIC_COLLECTIONS server-side):
///   listItems('cv') → [{id, name, headline, phone, email, location,
///                        education:[{degree,institution,year}],
///                        experience:[{title,org,dates,bullets}],
///                        skills:[String], updated_at}]
/// ONE CV per user: the first save creates the single row, later saves
/// updateItem(id). Each field round-trips as JSON through one flexible per-user
/// collection. ZERO Bangla literals — every string is an AppLocalizations
/// getter.
class CvBuilderScreen extends StatefulWidget {
  const CvBuilderScreen({super.key});
  @override
  State<CvBuilderScreen> createState() => _CvBuilderScreenState();
}

const String _cvPath = 'cv';

String _today() {
  final n = DateTime.now();
  return '${n.year.toString().padLeft(4, '0')}-${n.month.toString().padLeft(2, '0')}-${n.day.toString().padLeft(2, '0')}';
}

/// One education entry.
class _Education {
  String degree;
  String institution;
  String year;
  _Education({this.degree = '', this.institution = '', this.year = ''});
  factory _Education.fromJson(Map<String, dynamic> j) => _Education(
        degree: (j['degree'] ?? '').toString(),
        institution: (j['institution'] ?? '').toString(),
        year: (j['year'] ?? '').toString(),
      );
  Map<String, dynamic> toJson() =>
      {'degree': degree, 'institution': institution, 'year': year};
  bool get isEmpty =>
      degree.trim().isEmpty &&
      institution.trim().isEmpty &&
      year.trim().isEmpty;
}

/// One experience entry. [bullets] is one achievement per line (free text).
class _Experience {
  String title;
  String org;
  String dates;
  String bullets;
  _Experience(
      {this.title = '', this.org = '', this.dates = '', this.bullets = ''});
  factory _Experience.fromJson(Map<String, dynamic> j) {
    final b = j['bullets'];
    final bulletsText = b is List
        ? b.map((e) => e.toString()).join('\n')
        : (b ?? '').toString();
    return _Experience(
      title: (j['title'] ?? '').toString(),
      org: (j['org'] ?? '').toString(),
      dates: (j['dates'] ?? '').toString(),
      bullets: bulletsText,
    );
  }
  Map<String, dynamic> toJson() => {
        'title': title,
        'org': org,
        'dates': dates,
        'bullets': bullets
            .split('\n')
            .map((l) => l.trim())
            .where((l) => l.isNotEmpty)
            .toList(),
      };
  bool get isEmpty =>
      title.trim().isEmpty &&
      org.trim().isEmpty &&
      dates.trim().isEmpty &&
      bullets.trim().isEmpty;
}

class _CvBuilderScreenState extends State<CvBuilderScreen> {
  // header fields
  final _name = TextEditingController();
  final _headline = TextEditingController();
  final _phone = TextEditingController();
  final _email = TextEditingController();
  final _location = TextEditingController();

  // repeatable sections
  final List<_Education> _education = [];
  final List<_Experience> _experience = [];
  final List<String> _skills = [];

  int? _recordId; // the single CV row id (null until first save)
  bool _loading = true, _error = false, _saving = false, _dirty = false;
  Object? _failCause; // qa2: why it failed (5xx = our server, not the internet)
  bool _started = false; // user tapped "start" on the first-run empty state

  AppLocalizations get t => AppLocalizations.of(context);

  @override
  void initState() {
    super.initState();
    for (final c in [_name, _headline, _phone, _email, _location]) {
      c.addListener(_markDirty);
    }
    _load();
  }

  @override
  void dispose() {
    for (final c in [_name, _headline, _phone, _email, _location]) {
      c.dispose();
    }
    super.dispose();
  }

  void _markDirty() {
    if (!_dirty && mounted) setState(() => _dirty = true);
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = false;
    });
    try {
      final rows = await context.read<AppState>().api.listItems(_cvPath);
      if (rows.isNotEmpty) {
        _applyRecord(rows.first);
      }
    } catch (e) {
      _error = true;
      _failCause = e;
    }
    if (mounted) setState(() => _loading = false);
  }

  void _applyRecord(Map<String, dynamic> r) {
    _recordId = (r['id'] as num?)?.toInt();
    _name.text = (r['name'] ?? '').toString();
    _headline.text = (r['headline'] ?? '').toString();
    _phone.text = (r['phone'] ?? '').toString();
    _email.text = (r['email'] ?? '').toString();
    _location.text = (r['location'] ?? '').toString();
    _education
      ..clear()
      ..addAll(((r['education'] as List?) ?? [])
          .whereType<Map>()
          .map((e) => _Education.fromJson(e.cast<String, dynamic>())));
    _experience
      ..clear()
      ..addAll(((r['experience'] as List?) ?? [])
          .whereType<Map>()
          .map((e) => _Experience.fromJson(e.cast<String, dynamic>())));
    _skills
      ..clear()
      ..addAll(((r['skills'] as List?) ?? [])
          .map((e) => e.toString())
          .where((s) => s.trim().isNotEmpty));
    _dirty = false;
  }

  Map<String, dynamic> _toBody() => {
        'name': _name.text.trim(),
        'headline': _headline.text.trim(),
        'phone': _phone.text.trim(),
        'email': _email.text.trim(),
        'location': _location.text.trim(),
        'education':
            _education.where((e) => !e.isEmpty).map((e) => e.toJson()).toList(),
        'experience':
            _experience.where((e) => !e.isEmpty).map((e) => e.toJson()).toList(),
        'skills': _skills.where((s) => s.trim().isNotEmpty).toList(),
        'updated_at': _today(),
      };

  void _toast(String msg) => ScaffoldMessenger.of(context)
    ..clearSnackBars()
    ..showSnackBar(SnackBar(content: Text(msg)));

  bool get _hasAnyData =>
      _name.text.trim().isNotEmpty ||
      _headline.text.trim().isNotEmpty ||
      _phone.text.trim().isNotEmpty ||
      _email.text.trim().isNotEmpty ||
      _location.text.trim().isNotEmpty ||
      _education.any((e) => !e.isEmpty) ||
      _experience.any((e) => !e.isEmpty) ||
      _skills.any((s) => s.trim().isNotEmpty);

  Future<void> _save() async {
    FocusScope.of(context).unfocus();
    setState(() => _saving = true);
    final body = _toBody();
    try {
      final api = context.read<AppState>().api;
      if (_recordId != null) {
        await api.updateItem(_cvPath, _recordId!, body);
      } else {
        final row = await api.createItem(_cvPath, body);
        _recordId = (row['id'] as num?)?.toInt();
      }
      _dirty = false;
      if (mounted) _toast(t.cvSaved);
    } catch (_) {
      if (mounted) _toast(t.saveFailed);
    }
    if (mounted) setState(() => _saving = false);
  }

  // ---- education -----------------------------------------------------------
  Future<void> _editEducation({int? index}) async {
    final existing = index == null ? null : _education[index];
    final result = await showModalBottomSheet<_Education>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => _EducationSheet(initial: existing),
    );
    if (result == null) return;
    setState(() {
      if (index == null) {
        _education.add(result);
      } else {
        _education[index] = result;
      }
      _dirty = true;
    });
  }

  // ---- experience ----------------------------------------------------------
  Future<void> _editExperience({int? index}) async {
    final existing = index == null ? null : _experience[index];
    final result = await showModalBottomSheet<_Experience>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => _ExperienceSheet(initial: existing),
    );
    if (result == null) return;
    setState(() {
      if (index == null) {
        _experience.add(result);
      } else {
        _experience[index] = result;
      }
      _dirty = true;
    });
  }

  // ---- skills --------------------------------------------------------------
  Future<void> _addSkill() async {
    final result = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => const _SkillSheet(),
    );
    if (result == null) return;
    final v = result.trim();
    if (v.isEmpty) return;
    final dup =
        _skills.any((s) => s.toLowerCase() == v.toLowerCase());
    if (dup) {
      _toast(t.cvSkillDuplicate);
      return;
    }
    setState(() {
      _skills.add(v);
      _dirty = true;
    });
  }

  // ---- preview / copy / share ---------------------------------------------
  Future<void> _preview() async {
    FocusScope.of(context).unfocus();
    final text = buildCvText(_toBody(), t);
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => _PreviewSheet(text: text),
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    if (_loading) {
      return Scaffold(
        appBar: AppBar(title: Text(t.cvTitle)),
        body: const SkeletonList(),
      );
    }
    if (_error) {
      return Scaffold(
        appBar: AppBar(title: Text(t.cvTitle)),
        body: StateMessage(
          icon: Icons.cloud_off_rounded,
          tint: scheme.error,
          title: t.loadFailed,
          message: honestFailText(t, _failCause, otherwise: t.cvLoadError),
          action: FilledButton.tonalIcon(
            onPressed: _load,
            icon: const Icon(Icons.refresh_rounded),
            label: Text(t.retry),
          ),
        ),
      );
    }

    return Scaffold(
      // banners-everywhere (owner 26 Oct): one bottom banner, Free only
      bottomNavigationBar: const AdBannerSlot(screen: 'cv_builder'),
      appBar: AppBar(
        title: Text(t.cvTitle),
        actions: [
          IconButton(
            tooltip: t.cvPreview,
            onPressed: _hasAnyData ? _preview : null,
            icon: const Icon(Icons.visibility_rounded),
          ),
        ],
      ),
      floatingActionButton: _dirty
          ? FloatingActionButton.extended(
              onPressed: _saving ? null : _save,
              icon: _saving
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.save_rounded),
              label: Text(t.save),
            )
          : null,
      body: (_hasAnyData || _started) ? _form() : _emptyState(),
    );
  }

  Widget _emptyState() {
    return SingleChildScrollView(
      physics: const AlwaysScrollableScrollPhysics(),
      child: ConstrainedBox(
        constraints: BoxConstraints(
            minHeight: MediaQuery.of(context).size.height * 0.7),
        child: StateMessage(
          icon: Icons.description_rounded,
          title: t.cvWelcomeTitle,
          message: t.cvWelcomeBody,
          action: FilledButton.icon(
            onPressed: () => setState(() => _started = true),
            icon: const Icon(Icons.edit_rounded),
            label: Text(t.cvStart),
          ),
        ),
      ),
    );
  }

  Widget _form() {
    final scheme = Theme.of(context).colorScheme;
    return ListView(
      padding: const EdgeInsets.fromLTRB(Gap.lg, Gap.lg, Gap.lg, 96),
      children: [
        // --- contact header card ---
        _SectionCard(
          icon: Icons.person_outline_rounded,
          title: t.cvContactSection,
          child: Column(children: [
            _field(_name, t.cvFullName,
                cap: TextCapitalization.words, icon: Icons.badge_rounded),
            const SizedBox(height: Gap.md),
            _field(_headline, t.cvHeadline,
                cap: TextCapitalization.sentences,
                icon: Icons.work_outline_rounded,
                hint: t.cvHeadlineHint),
            const SizedBox(height: Gap.md),
            _field(_phone, t.cvPhone,
                keyboard: TextInputType.phone, icon: Icons.phone_rounded),
            const SizedBox(height: Gap.md),
            _field(_email, t.cvEmail,
                keyboard: TextInputType.emailAddress,
                icon: Icons.email_rounded),
            const SizedBox(height: Gap.md),
            _field(_location, t.cvLocation,
                cap: TextCapitalization.words,
                icon: Icons.place_rounded,
                hint: t.cvLocationHint),
          ]),
        ),
        const SizedBox(height: Gap.lg),

        // --- education ---
        _SectionCard(
          icon: Icons.school_rounded,
          title: t.cvEducationSection,
          onAdd: () => _editEducation(),
          addLabel: t.cvAddEducation,
          child: _education.isEmpty
              ? _emptyHint(t.cvNoEducation)
              : Column(
                  children: [
                    for (var i = 0; i < _education.length; i++)
                      _entryTile(
                        title: _education[i].degree.isEmpty
                            ? t.cvEducationSection
                            : _education[i].degree,
                        subtitle: [
                          _education[i].institution,
                          _education[i].year
                        ].where((s) => s.trim().isNotEmpty).join(' · '),
                        onEdit: () => _editEducation(index: i),
                        onDelete: () => setState(() {
                          _education.removeAt(i);
                          _dirty = true;
                        }),
                      ),
                  ],
                ),
        ),
        const SizedBox(height: Gap.lg),

        // --- experience ---
        _SectionCard(
          icon: Icons.business_center_rounded,
          title: t.cvExperienceSection,
          onAdd: () => _editExperience(),
          addLabel: t.cvAddExperience,
          child: _experience.isEmpty
              ? _emptyHint(t.cvNoExperience)
              : Column(
                  children: [
                    for (var i = 0; i < _experience.length; i++)
                      _entryTile(
                        title: _experience[i].title.isEmpty
                            ? t.cvExperienceSection
                            : _experience[i].title,
                        subtitle: [
                          _experience[i].org,
                          _experience[i].dates
                        ].where((s) => s.trim().isNotEmpty).join(' · '),
                        onEdit: () => _editExperience(index: i),
                        onDelete: () => setState(() {
                          _experience.removeAt(i);
                          _dirty = true;
                        }),
                      ),
                  ],
                ),
        ),
        const SizedBox(height: Gap.lg),

        // --- skills ---
        _SectionCard(
          icon: Icons.bolt_rounded,
          title: t.cvSkillsSection,
          onAdd: _addSkill,
          addLabel: t.cvAddSkill,
          child: _skills.isEmpty
              ? _emptyHint(t.cvNoSkills)
              : Wrap(
                  spacing: Gap.sm,
                  runSpacing: Gap.sm,
                  children: [
                    for (var i = 0; i < _skills.length; i++)
                      InputChip(
                        label: Text(_skills[i],
                            maxLines: 1, overflow: TextOverflow.ellipsis),
                        onDeleted: () => setState(() {
                          _skills.removeAt(i);
                          _dirty = true;
                        }),
                      ),
                  ],
                ),
        ),
        const SizedBox(height: Gap.lg),

        // --- preview / copy / share actions ---
        FilledButton.icon(
          onPressed: _hasAnyData ? _preview : null,
          icon: const Icon(Icons.visibility_rounded, size: 18),
          label: Text(t.cvPreview),
        ),
        const SizedBox(height: Gap.xl),

        // --- honest AI-enhance seam ---
        const _AiPolishCard(),
        const SizedBox(height: Gap.lg),
        Text(t.cvPrivacyNote,
            style: AType.bodySmall.copyWith(color: scheme.onSurfaceVariant, height: 1.4)),
      ],
    );
  }

  Widget _field(TextEditingController c, String label,
      {TextInputType? keyboard,
      TextCapitalization cap = TextCapitalization.none,
      IconData? icon,
      String? hint}) {
    return TextField(
      controller: c,
      keyboardType: keyboard,
      textCapitalization: cap,
      decoration: InputDecoration(
        labelText: label,
        hintText: hint,
        prefixIcon: icon == null ? null : Icon(icon, size: 20),
      ),
    );
  }

  Widget _emptyHint(String msg) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: Gap.xs),
      child: Text(msg,
          style: AType.bodyMedium.copyWith(color: scheme.onSurfaceVariant, height: 1.4)),
    );
  }

  Widget _entryTile({
    required String title,
    required String subtitle,
    required VoidCallback onEdit,
    required VoidCallback onDelete,
  }) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: Gap.sm),
      child: Material(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(Radii.sm),
        child: InkWell(
          onTap: onEdit,
          borderRadius: BorderRadius.circular(Radii.sm),
          child: Padding(
            padding:
                const EdgeInsets.fromLTRB(Gap.md, Gap.sm, Gap.xs, Gap.sm),
            child: Row(children: [
              Expanded(
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style:
                              const TextStyle(fontWeight: FontWeight.w700)),
                      if (subtitle.trim().isNotEmpty) ...[
                        const SizedBox(height: Gap.xxs),
                        Text(subtitle,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: AType.bodySmall.copyWith(color: scheme.onSurfaceVariant)),
                      ],
                    ]),
              ),
              IconButton(
                icon: const Icon(Icons.delete_outline_rounded, size: 20),
                tooltip: t.delete,
                onPressed: onDelete,
              ),
            ]),
          ),
        ),
      ),
    );
  }
}

// =========================================================================
// DETERMINISTIC CV TEXT ASSEMBLER — pure, no AI, no key. Identical input gives
// an identical, cleanly formatted plain-text resume every time.
// =========================================================================
String buildCvText(Map<String, dynamic> cv, AppLocalizations t) {
  final lines = <String>[];
  final name = (cv['name'] ?? '').toString().trim();
  final headline = (cv['headline'] ?? '').toString().trim();

  if (name.isNotEmpty) {
    lines.add(name.toUpperCase());
  }
  if (headline.isNotEmpty) {
    lines.add(headline);
  }

  // contact line: phone · email · location
  final contact = [
    (cv['phone'] ?? '').toString().trim(),
    (cv['email'] ?? '').toString().trim(),
    (cv['location'] ?? '').toString().trim(),
  ].where((s) => s.isNotEmpty).join('  |  ');
  if (contact.isNotEmpty) lines.add(contact);

  void heading(String h) {
    lines.add('');
    lines.add(h.toUpperCase());
    lines.add('-' * (h.length < 4 ? 4 : h.length));
  }

  // education
  final edu = (cv['education'] as List?) ?? [];
  if (edu.isNotEmpty) {
    heading(t.cvEducationSection);
    for (final raw in edu) {
      final e = (raw as Map).cast<String, dynamic>();
      final degree = (e['degree'] ?? '').toString().trim();
      final inst = (e['institution'] ?? '').toString().trim();
      final year = (e['year'] ?? '').toString().trim();
      final head =
          [degree, if (year.isNotEmpty) '($year)'].where((s) => s.isNotEmpty).join(' ');
      if (head.isNotEmpty) lines.add(head);
      if (inst.isNotEmpty) lines.add('  $inst');
    }
  }

  // experience
  final exp = (cv['experience'] as List?) ?? [];
  if (exp.isNotEmpty) {
    heading(t.cvExperienceSection);
    for (final raw in exp) {
      final e = (raw as Map).cast<String, dynamic>();
      final title = (e['title'] ?? '').toString().trim();
      final org = (e['org'] ?? '').toString().trim();
      final dates = (e['dates'] ?? '').toString().trim();
      final head = [
        [title, if (org.isNotEmpty) org].where((s) => s.isNotEmpty).join(' — '),
        if (dates.isNotEmpty) '($dates)',
      ].where((s) => s.isNotEmpty).join('  ');
      if (head.isNotEmpty) lines.add(head);
      final b = e['bullets'];
      final bullets = b is List
          ? b.map((x) => x.toString().trim()).where((x) => x.isNotEmpty)
          : (b ?? '')
              .toString()
              .split('\n')
              .map((x) => x.trim())
              .where((x) => x.isNotEmpty);
      for (final line in bullets) {
        lines.add('  • $line');
      }
    }
  }

  // skills
  final skills = ((cv['skills'] as List?) ?? [])
      .map((s) => s.toString().trim())
      .where((s) => s.isNotEmpty)
      .toList();
  if (skills.isNotEmpty) {
    heading(t.cvSkillsSection);
    lines.add(skills.join(', '));
  }

  final text = lines.join('\n').trim();
  return text.isEmpty ? t.cvEmptyPreview : text;
}

// =========================================================================
// section wrapper card
// =========================================================================
class _SectionCard extends StatelessWidget {
  final IconData icon;
  final String title;
  final Widget child;
  final VoidCallback? onAdd;
  final String? addLabel;
  const _SectionCard({
    required this.icon,
    required this.title,
    required this.child,
    this.onAdd,
    this.addLabel,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(Gap.md),
        child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(children: [
                Icon(icon, size: 20, color: scheme.primary),
                const SizedBox(width: Gap.sm),
                Expanded(
                  child: Text(title,
                      style: Theme.of(context).textTheme.titleMedium,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis),
                ),
              ]),
              const SizedBox(height: Gap.sm),
              child,
              if (onAdd != null) ...[
                const SizedBox(height: Gap.xs),
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton.icon(
                    onPressed: onAdd,
                    icon: const Icon(Icons.add_rounded, size: 18),
                    label: Text(addLabel ?? ''),
                  ),
                ),
              ],
            ]),
      ),
    );
  }
}

// =========================================================================
// bottom-sheet forms
// =========================================================================
class _EducationSheet extends StatefulWidget {
  final _Education? initial;
  const _EducationSheet({this.initial});
  @override
  State<_EducationSheet> createState() => _EducationSheetState();
}

class _EducationSheetState extends State<_EducationSheet> {
  late final _degree = TextEditingController(text: widget.initial?.degree ?? '');
  late final _inst =
      TextEditingController(text: widget.initial?.institution ?? '');
  late final _year = TextEditingController(text: widget.initial?.year ?? '');

  @override
  void dispose() {
    _degree.dispose();
    _inst.dispose();
    _year.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final insets = MediaQuery.of(context).viewInsets.bottom;
    return Padding(
      padding: EdgeInsets.fromLTRB(Gap.lg, 0, Gap.lg, Gap.lg + insets),
      child: SingleChildScrollView(
        child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(t.cvAddEducation,
                  style: Theme.of(context).textTheme.titleLarge),
              const SizedBox(height: Gap.lg),
              TextField(
                controller: _degree,
                autofocus: true,
                textCapitalization: TextCapitalization.words,
                decoration: InputDecoration(
                    labelText: t.cvDegree, hintText: t.cvDegreeHint),
              ),
              const SizedBox(height: Gap.md),
              TextField(
                controller: _inst,
                textCapitalization: TextCapitalization.words,
                decoration: InputDecoration(labelText: t.cvInstitution),
              ),
              const SizedBox(height: Gap.md),
              TextField(
                controller: _year,
                decoration: InputDecoration(
                    labelText: t.cvYear, hintText: t.cvYearHint),
              ),
              const SizedBox(height: Gap.lg),
              _sheetActions(context, onSave: () {
                Navigator.pop(
                    context,
                    _Education(
                      degree: _degree.text.trim(),
                      institution: _inst.text.trim(),
                      year: _year.text.trim(),
                    ));
              }),
            ]),
      ),
    );
  }
}

class _ExperienceSheet extends StatefulWidget {
  final _Experience? initial;
  const _ExperienceSheet({this.initial});
  @override
  State<_ExperienceSheet> createState() => _ExperienceSheetState();
}

class _ExperienceSheetState extends State<_ExperienceSheet> {
  late final _title = TextEditingController(text: widget.initial?.title ?? '');
  late final _org = TextEditingController(text: widget.initial?.org ?? '');
  late final _dates = TextEditingController(text: widget.initial?.dates ?? '');
  late final _bullets =
      TextEditingController(text: widget.initial?.bullets ?? '');

  @override
  void dispose() {
    _title.dispose();
    _org.dispose();
    _dates.dispose();
    _bullets.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final insets = MediaQuery.of(context).viewInsets.bottom;
    return Padding(
      padding: EdgeInsets.fromLTRB(Gap.lg, 0, Gap.lg, Gap.lg + insets),
      child: SingleChildScrollView(
        child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(t.cvAddExperience,
                  style: Theme.of(context).textTheme.titleLarge),
              const SizedBox(height: Gap.lg),
              TextField(
                controller: _title,
                autofocus: true,
                textCapitalization: TextCapitalization.words,
                decoration: InputDecoration(
                    labelText: t.cvJobTitle, hintText: t.cvJobTitleHint),
              ),
              const SizedBox(height: Gap.md),
              TextField(
                controller: _org,
                textCapitalization: TextCapitalization.words,
                decoration: InputDecoration(labelText: t.cvOrganisation),
              ),
              const SizedBox(height: Gap.md),
              TextField(
                controller: _dates,
                decoration: InputDecoration(
                    labelText: t.cvDates, hintText: t.cvDatesHint),
              ),
              const SizedBox(height: Gap.md),
              TextField(
                controller: _bullets,
                minLines: 3,
                maxLines: 6,
                textCapitalization: TextCapitalization.sentences,
                decoration: InputDecoration(
                    labelText: t.cvBullets,
                    hintText: t.cvBulletsHint,
                    alignLabelWithHint: true),
              ),
              const SizedBox(height: Gap.lg),
              _sheetActions(context, onSave: () {
                Navigator.pop(
                    context,
                    _Experience(
                      title: _title.text.trim(),
                      org: _org.text.trim(),
                      dates: _dates.text.trim(),
                      bullets: _bullets.text.trim(),
                    ));
              }),
            ]),
      ),
    );
  }
}

class _SkillSheet extends StatefulWidget {
  const _SkillSheet();
  @override
  State<_SkillSheet> createState() => _SkillSheetState();
}

class _SkillSheetState extends State<_SkillSheet> {
  final _c = TextEditingController();
  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final insets = MediaQuery.of(context).viewInsets.bottom;
    return Padding(
      padding: EdgeInsets.fromLTRB(Gap.lg, 0, Gap.lg, Gap.lg + insets),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Text(t.cvAddSkill, style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: Gap.lg),
        TextField(
          controller: _c,
          autofocus: true,
          textCapitalization: TextCapitalization.words,
          decoration: InputDecoration(
              labelText: t.cvSkillLabel, hintText: t.cvSkillHint),
          onSubmitted: (v) => Navigator.pop(context, v),
        ),
        const SizedBox(height: Gap.lg),
        _sheetActions(context, onSave: () => Navigator.pop(context, _c.text)),
      ]),
    );
  }
}

Widget _sheetActions(BuildContext context, {required VoidCallback onSave}) {
  final t = AppLocalizations.of(context);
  return Row(children: [
    Expanded(
      child: OutlinedButton(
          onPressed: () => Navigator.pop(context), child: Text(t.cancel)),
    ),
    const SizedBox(width: Gap.md),
    Expanded(
      child: FilledButton(onPressed: onSave, child: Text(t.cvDone)),
    ),
  ]);
}

// =========================================================================
// preview sheet: formatted plain text + copy + share
// =========================================================================
class _PreviewSheet extends StatelessWidget {
  final String text;
  const _PreviewSheet({required this.text});

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.7,
      minChildSize: 0.4,
      maxChildSize: 0.95,
      builder: (context, scroll) {
        return Padding(
          padding: const EdgeInsets.fromLTRB(Gap.lg, 0, Gap.lg, Gap.lg),
          child: Column(children: [
            Row(children: [
              Expanded(
                child: Text(t.cvPreview,
                    style: Theme.of(context).textTheme.titleLarge),
              ),
            ]),
            const SizedBox(height: Gap.sm),
            Expanded(
              child: Container(
                width: double.infinity,
                padding: const EdgeInsets.all(Gap.md),
                decoration: BoxDecoration(
                  color: scheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(Radii.md),
                ),
                child: SingleChildScrollView(
                  controller: scroll,
                  child: SelectableText(
                    text,
                    style: AType.bodyMedium.copyWith(fontFamily: 'monospace', height: 1.5),
                  ),
                ),
              ),
            ),
            const SizedBox(height: Gap.md),
            Row(children: [
              Expanded(
                child: FilledButton.icon(
                  onPressed: () async {
                    await Clipboard.setData(ClipboardData(text: text));
                    if (context.mounted) {
                      ScaffoldMessenger.of(context)
                        ..clearSnackBars()
                        ..showSnackBar(SnackBar(content: Text(t.copied)));
                    }
                  },
                  icon: const Icon(Icons.copy_rounded, size: 18),
                  label: Text(t.copy),
                ),
              ),
              const SizedBox(width: Gap.sm),
              OutlinedButton.icon(
                onPressed: () => Share.share(text, subject: t.cvTitle),
                icon: const Icon(Icons.ios_share_rounded, size: 18),
                label: Text(t.cvShare),
              ),
            ]),
          ]),
        );
      },
    );
  }
}

// =========================================================================
// honest AI-enhance seam — documented, key-gated, never fabricates output.
// =========================================================================
class _AiPolishCard extends StatelessWidget {
  const _AiPolishCard();
  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(Gap.md),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(Radii.sm),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Icon(Icons.lock_outline_rounded, size: 18, color: scheme.primary),
        const SizedBox(width: Gap.sm),
        Expanded(
          child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(t.cvAiPolishTitle,
                    style: const TextStyle(
                        fontWeight: FontWeight.w700, height: 1.4)),
                const SizedBox(height: Gap.xxs),
                Text(t.cvAiPolishBody,
                    style: AType.bodySmall.copyWith(color: scheme.onSurfaceVariant,
                        height: 1.4)),
              ]),
        ),
      ]),
    );
  }
}
