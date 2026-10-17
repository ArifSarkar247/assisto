import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:share_plus/share_plus.dart';
import '../l10n/app_localizations.dart';
import '../state.dart';
import '../theme.dart';
import '../widgets/ladder_common.dart' show fmtInt;
import 'circle_screen.dart';

/// Phone Safety Check-up — premium, HONEST anti-theft phone-hardening guidance.
///
/// Assisto CANNOT read or enforce any of these OS settings. It only *guides*
/// the user through the menus (menu paths vary per OEM / Android version) and
/// lets them self-confirm each step; the "protection score" is simply how many
/// steps the user has personally confirmed — never a verified state. Several
/// steps (Theft Protection, power-off PIN, offline device lock) depend on the
/// Android version and the brand, so availability is clearly noted.
class PhoneSafetyScreen extends StatefulWidget {
  const PhoneSafetyScreen({super.key});
  @override
  State<PhoneSafetyScreen> createState() => _PhoneSafetyScreenState();
}

/// A brand is a (id, group-label) pair. The group label is localized via ARB;
/// the OEM proper nouns themselves stay as literals inside the label strings.
class _Brand {
  final String id;
  final String Function(AppLocalizations) label;
  const _Brand(this.id, this.label);
}

/// One hardening step. [how] and [why] are localized at build time. [link] is
/// an optional genuinely-openable deep link (never a fake settings panel).
class _Step {
  final String id;
  final String Function(AppLocalizations) title;
  final String Function(AppLocalizations) why;
  final List<String> Function(AppLocalizations) how;
  final String? link; // real, launchable URL only (else null -> steps only)
  final String Function(AppLocalizations)? linkLabel;
  final String Function(AppLocalizations)? availability; // version/brand note
  const _Step(this.id, this.title, this.why, this.how,
      {this.link, this.linkLabel, this.availability});
}

class _PhoneSafetyScreenState extends State<PhoneSafetyScreen> {
  static const _brandKey = 'phonesafe_brand';

  final List<_Brand> _brands = [
    _Brand('stock', (t) => t.phoneSafeBrandStock),
    _Brand('realme', (t) => t.phoneSafeBrandRealme),
    _Brand('samsung', (t) => t.phoneSafeBrandSamsung),
    _Brand('xiaomi', (t) => t.phoneSafeBrandXiaomi),
    _Brand('vivo', (t) => t.phoneSafeBrandVivo),
  ];

  String _brand = 'stock';
  final Map<String, bool> _confirmed = {}; // '<brand>_<stepId>' -> confirmed
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final saved = await Settings.getString(_brandKey);
    if (saved != null && _brands.any((b) => b.id == saved)) _brand = saved;
    await _loadConfirmations();
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _loadConfirmations() async {
    for (final s in _steps) {
      final k = 'phonesafe_${_brand}_${s.id}';
      _confirmed[k] = await Settings.getBool(k, false);
    }
  }

  Future<void> _pickBrand(String id) async {
    _brand = id;
    await Settings.setString(_brandKey, id);
    await _loadConfirmations();
    if (mounted) setState(() {});
  }

  Future<void> _toggle(String stepId, bool v) async {
    final k = 'phonesafe_${_brand}_$stepId';
    setState(() => _confirmed[k] = v);
    await Settings.setBool(k, v);
  }

  bool _isConfirmed(String stepId) =>
      _confirmed['phonesafe_${_brand}_$stepId'] ?? false;

  int get _confirmedCount =>
      _steps.where((s) => _isConfirmed(s.id)).length;

  int get _score {
    if (_steps.isEmpty) return 0;
    return ((_confirmedCount / _steps.length) * 100).round();
  }

  Future<void> _openLink(String url) async {
    final uri = Uri.parse(url);
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    }
  }

  Future<void> _shareChecklist() async {
    final t = AppLocalizations.of(context);
    final buf = StringBuffer(t.phoneSafeShareHeader);
    buf.writeln();
    for (final s in _steps) {
      buf.writeln('\n- ${s.title(t)}');
      for (final step in s.how(t)) {
        buf.writeln('  * $step');
      }
    }
    buf.writeln('\n${t.phoneSafeHonestNote}');
    await Share.share(buf.toString());
  }

  /// The step catalogue. Wording adapts per OEM where the menu path differs
  /// (handled inside the localized `how` builders via brand-specific keys).
  List<_Step> get _steps => [
        _Step(
          'lockshade',
          (t) => t.phoneSafeShadeTitle,
          (t) => t.phoneSafeShadeWhy,
          (t) => switch (_brand) {
                'realme' => t.phoneSafeShadeHowRealme.split('\n'),
                'samsung' => t.phoneSafeShadeHowSamsung.split('\n'),
                'xiaomi' => t.phoneSafeShadeHowXiaomi.split('\n'),
                'vivo' => t.phoneSafeShadeHowVivo.split('\n'),
                _ => t.phoneSafeShadeHowStock.split('\n'),
              },
          availability: (t) => t.phoneSafeAvailBrand,
        ),
        _Step(
          'poweroffpin',
          (t) => t.phoneSafePowerOffTitle,
          (t) => t.phoneSafePowerOffWhy,
          (t) => switch (_brand) {
                'realme' => t.phoneSafePowerOffHowRealme.split('\n'),
                'xiaomi' => t.phoneSafePowerOffHowXiaomi.split('\n'),
                _ => t.phoneSafePowerOffHowGeneric.split('\n'),
              },
          availability: (t) => t.phoneSafeAvailBrand,
        ),
        _Step(
          'locknetsec',
          (t) => t.phoneSafeLockNetTitle,
          (t) => t.phoneSafeLockNetWhy,
          (t) => switch (_brand) {
                'samsung' => t.phoneSafeLockNetHowSamsung.split('\n'),
                _ => t.phoneSafeLockNetHowOther.split('\n'),
              },
          availability: (t) => t.phoneSafeAvailBrand,
        ),
        _Step(
          'theftprotect',
          (t) => t.phoneSafeTheftTitle,
          (t) => t.phoneSafeTheftWhy,
          (t) => t.phoneSafeTheftHow.split('\n'),
          availability: (t) => t.phoneSafeAvailAndroid15,
        ),
        _Step(
          'findhub',
          (t) => t.phoneSafeFindTitle,
          (t) => t.phoneSafeFindWhy,
          (t) => t.phoneSafeFindHow.split('\n'),
          link: 'https://www.google.com/android/find',
          linkLabel: (t) => t.phoneSafeFindOpenWeb,
        ),
        _Step(
          'simpin',
          (t) => t.phoneSafeSimTitle,
          (t) => t.phoneSafeSimWhy,
          (t) => t.phoneSafeSimHow.split('\n'),
        ),
        _Step(
          'screenlock',
          (t) => t.phoneSafeLockTitle,
          (t) => t.phoneSafeLockWhy,
          (t) => t.phoneSafeLockHow.split('\n'),
        ),
        _Step(
          'frp',
          (t) => t.phoneSafeFrpTitle,
          (t) => t.phoneSafeFrpWhy,
          (t) => t.phoneSafeFrpHow.split('\n'),
        ),
        _Step(
          'brandaccount',
          (t) => t.phoneSafeBrandAccountTitle,
          (t) => t.phoneSafeBrandAccountWhy,
          (t) => switch (_brand) {
                'samsung' => t.phoneSafeBrandAccountHowSamsung.split('\n'),
                'xiaomi' => t.phoneSafeBrandAccountHowXiaomi.split('\n'),
                _ => t.phoneSafeBrandAccountHowOther.split('\n'),
              },
          availability: (t) => t.phoneSafeAvailBrand,
        ),
        _Step(
          'twostep',
          (t) => t.phoneSafeTwoStepTitle,
          (t) => t.phoneSafeTwoStepWhy,
          (t) => t.phoneSafeTwoStepHow.split('\n'),
          link: 'https://myaccount.google.com/signinoptions/twosv',
          linkLabel: (t) => t.phoneSafeTwoStepOpenWeb,
        ),
      ];

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    if (_loading) {
      return Scaffold(
        appBar: AppBar(title: Text(t.phoneSafetyTitle)),
        body: const Center(child: CircularProgressIndicator()),
      );
    }
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: Text(t.phoneSafetyTitle), actions: [
        IconButton(
          tooltip: t.phoneSafeShareTooltip,
          icon: const Icon(Icons.ios_share_outlined),
          onPressed: _shareChecklist,
        ),
      ]),
      body: ListView(padding: const EdgeInsets.all(Gap.lg), children: [
        _ScoreCard(score: _score, confirmed: _confirmedCount, total: _steps.length),
        const SizedBox(height: Gap.md),
        // Honesty banner — Assisto never reads or enforces these settings.
        Card(
          color: scheme.tertiaryContainer,
          child: Padding(
            padding: const EdgeInsets.all(Gap.md),
            child: Row(children: [
              Icon(Icons.info_outline, color: scheme.onTertiaryContainer, size: 20),
              const SizedBox(width: Gap.sm),
              Expanded(
                child: Text(t.phoneSafeHonestNote,
                    style: TextStyle(
                        color: scheme.onTertiaryContainer, fontSize: 13)),
              ),
            ]),
          ),
        ),
        const SizedBox(height: Gap.md),
        // Honest reality explainer — what software can and cannot do.
        Card(
          color: scheme.secondaryContainer,
          child: Padding(
            padding: const EdgeInsets.all(Gap.md),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(children: [
                  Icon(Icons.shield_outlined,
                      color: scheme.onSecondaryContainer, size: 20),
                  const SizedBox(width: Gap.sm),
                  Expanded(
                    child: Text(t.phoneSafeRealityTitle,
                        style: TextStyle(
                            color: scheme.onSecondaryContainer,
                            fontWeight: FontWeight.w700,
                            fontSize: 14)),
                  ),
                ]),
                const SizedBox(height: Gap.sm),
                Text(t.phoneSafeRealityBody,
                    style: TextStyle(
                        color: scheme.onSecondaryContainer,
                        fontSize: 13,
                        height: 1.35)),
              ],
            ),
          ),
        ),
        const SizedBox(height: Gap.lg),
        Text(t.phoneSafeBrandPrompt,
            style: const TextStyle(fontWeight: FontWeight.w700)),
        const SizedBox(height: Gap.sm),
        Wrap(spacing: Gap.sm, runSpacing: Gap.xs, children: [
          for (final b in _brands)
            ChoiceChip(
              label: Text(b.label(t)),
              selected: _brand == b.id,
              onSelected: (_) => _pickBrand(b.id),
            ),
        ]),
        const SizedBox(height: Gap.lg),
        for (final s in _steps)
          _StepCard(
            step: s,
            confirmed: _isConfirmed(s.id),
            onToggle: (v) => _toggle(s.id, v),
            onLink: s.link == null ? null : () => _openLink(s.link!),
          ),
        const SizedBox(height: Gap.md),
        // Family hand-off: open My Circle (trusted family).
        SizedBox(
          width: double.infinity,
          child: FilledButton.icon(
            icon: const Icon(Icons.diversity_1_outlined),
            label: Text(t.phoneSafeCheckFamily),
            onPressed: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const CircleScreen())),
          ),
        ),
        const SizedBox(height: Gap.sm),
        SizedBox(
          width: double.infinity,
          child: OutlinedButton.icon(
            icon: const Icon(Icons.ios_share_outlined),
            label: Text(t.phoneSafeShareChecklist),
            onPressed: _shareChecklist,
          ),
        ),
        const SizedBox(height: Gap.lg),
        Text(t.phoneSafeFooterNote,
            style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant)),
      ]),
    );
  }
}

/// Live protection score /100 with a colored ring. The score is the proportion
/// of self-confirmed steps — NOT a verified device state.
class _ScoreCard extends StatelessWidget {
  final int score;
  final int confirmed;
  final int total;
  const _ScoreCard(
      {required this.score, required this.confirmed, required this.total});

  Color _ringColor() {
    if (score >= 80) return Brand.success;
    if (score >= 40) return Brand.warning;
    return Brand.danger;
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final ring = _ringColor();
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(Gap.lg),
        child: Row(children: [
          SizedBox(
            width: 76,
            height: 76,
            child: Stack(alignment: Alignment.center, children: [
              SizedBox(
                width: 76,
                height: 76,
                child: CircularProgressIndicator(
                  value: score / 100,
                  strokeWidth: 7,
                  backgroundColor: scheme.surfaceContainerHighest,
                  valueColor: AlwaysStoppedAnimation<Color>(ring),
                ),
              ),
              Text(fmtInt(context, score),
                  style: TextStyle(
                      fontWeight: FontWeight.w800,
                      fontSize: 22,
                      color: scheme.onSurface)),
            ]),
          ),
          const SizedBox(width: Gap.lg),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(t.phoneSafeScoreTitle,
                    style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 16)),
                const SizedBox(height: Gap.xs),
                Text(
                  t.phoneSafeScoreSubtitle(
                      fmtInt(context, confirmed), fmtInt(context, total)),
                  style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 13),
                ),
              ],
            ),
          ),
        ]),
      ),
    );
  }
}

/// One expandable step card: title, why-line, how-to steps, optional real
/// deep-link, availability note, and a self-confirm switch.
class _StepCard extends StatelessWidget {
  final _Step step;
  final bool confirmed;
  final ValueChanged<bool> onToggle;
  final VoidCallback? onLink;
  const _StepCard({
    required this.step,
    required this.confirmed,
    required this.onToggle,
    this.onLink,
  });

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    return Card(
      margin: const EdgeInsets.only(bottom: Gap.md),
      child: Theme(
        data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          shape: const Border(),
          collapsedShape: const Border(),
          leading: Icon(
            confirmed ? Icons.check_circle : Icons.radio_button_unchecked,
            color: confirmed ? Brand.success : scheme.onSurfaceVariant,
          ),
          title: Text(step.title(t),
              style: const TextStyle(fontWeight: FontWeight.w700)),
          subtitle: Text(step.why(t),
              style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant)),
          childrenPadding:
              const EdgeInsets.fromLTRB(Gap.lg, 0, Gap.lg, Gap.md),
          children: [
            for (int i = 0; i < step.how(t).length; i++)
              Padding(
                padding: const EdgeInsets.only(bottom: Gap.sm),
                child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text('${fmtInt(context, i + 1)}.  ',
                      style: TextStyle(color: scheme.primary, fontWeight: FontWeight.w700)),
                  Expanded(child: Text(step.how(t)[i])),
                ]),
              ),
            if (step.availability != null)
              Padding(
                padding: const EdgeInsets.only(top: Gap.xs, bottom: Gap.sm),
                child: Row(children: [
                  Icon(Icons.schedule, size: 15, color: scheme.onSurfaceVariant),
                  const SizedBox(width: Gap.xs),
                  Expanded(
                    child: Text(step.availability!(t),
                        style: TextStyle(
                            fontSize: 11,
                            fontStyle: FontStyle.italic,
                            color: scheme.onSurfaceVariant)),
                  ),
                ]),
              ),
            if (onLink != null)
              Align(
                alignment: Alignment.centerLeft,
                child: OutlinedButton.icon(
                  icon: const Icon(Icons.open_in_new, size: 18),
                  label: Text(step.linkLabel?.call(t) ?? t.phoneSafeOpen),
                  onPressed: onLink,
                ),
              ),
            const SizedBox(height: Gap.sm),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(t.phoneSafeConfirmLabel,
                  style: const TextStyle(fontSize: 14)),
              value: confirmed,
              onChanged: onToggle,
            ),
          ],
        ),
      ),
    );
  }
}
