import 'package:flutter/material.dart';
import '../../theme.dart';
import '../../l10n/app_localizations.dart';
import 'crm_common.dart';

/// FIRST-RUN flow for the in-app Sales CRM.
///
/// Shown by [CrmHomeScreen] when the signed-in user has NO CRM org/membership
/// (GET /crm/orgs/ returns []). This is a friendly welcome — never an error.
/// Two paths:
///   (a) "Start your company's CRM" — company name + industry + team size →
///       POST /crm/orgs/ which creates the org, makes the user OWNER and seeds a
///       sample pipeline with default stages.
///   (b) "Join a team" — enter an invite code → POST /crm/join to join an
///       existing org as a member.
///
/// On success it calls [onReady] so the host can reload and drop into the
/// workspace. The whole screen is driven by AppLocalizations (bn/en).
class CrmFirstRunScreen extends StatefulWidget {
  /// Called after an org is created or joined so the host can reload orgs.
  final Future<void> Function() onReady;

  /// Gallery/preview seam: start on a specific tab + skip live network.
  final bool previewJoin;

  const CrmFirstRunScreen({super.key, required this.onReady, this.previewJoin = false});

  @override
  State<CrmFirstRunScreen> createState() => _CrmFirstRunScreenState();
}

class _CrmFirstRunScreenState extends State<CrmFirstRunScreen> {
  bool _joinMode = false;
  bool _busy = false;
  CrmError? _error;

  // ---- start-your-CRM form ----
  final _nameCtl = TextEditingController();
  String _industry = 'rmg';
  String _teamSize = 'small';

  // ---- join form ----
  final _codeCtl = TextEditingController();

  @override
  void initState() {
    super.initState();
    _joinMode = widget.previewJoin;
  }

  @override
  void dispose() {
    _nameCtl.dispose();
    _codeCtl.dispose();
    super.dispose();
  }

  // Industry option codes are stable; labels come from ARB.
  List<({String code, String label})> _industries(AppLocalizations t) => [
        (code: 'rmg', label: t.crmIndRmg),
        (code: 'pharma', label: t.crmIndPharma),
        (code: 'retail', label: t.crmIndRetail),
        (code: 'it', label: t.crmIndIt),
        (code: 'manufacturing', label: t.crmIndManufacturing),
        (code: 'services', label: t.crmIndServices),
        (code: 'other', label: t.crmIndOther),
      ];

  List<({String code, String label})> _teamSizes(AppLocalizations t) => [
        (code: 'solo', label: t.crmTeamSizeSolo),
        (code: 'small', label: t.crmTeamSizeSmall),
        (code: 'medium', label: t.crmTeamSizeMedium),
        (code: 'large', label: t.crmTeamSizeLarge),
      ];

  Future<void> _start(AppLocalizations t) async {
    final name = _nameCtl.text.trim();
    if (name.isEmpty) {
      setState(() => _error = CrmError(t.crmOrgNameRequired, '', status: 0));
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await CrmApi.of(context).createOrg(name, industry: _industry, teamSize: _teamSize);
      await widget.onReady();
    } catch (e) {
      if (mounted) setState(() => _error = CrmError.from(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _join(AppLocalizations t) async {
    final code = _codeCtl.text.trim();
    if (code.isEmpty) {
      setState(() => _error = CrmError(t.crmInviteCodeRequired, '', status: 0));
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await CrmApi.of(context).joinOrg(code);
      await widget.onReady();
    } catch (e) {
      if (mounted) setState(() => _error = CrmError.from(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    return ListView(
      padding: const EdgeInsets.all(Gap.lg),
      children: [
        const SizedBox(height: Gap.lg),
        // ---- welcome header ----
        Center(
          child: Container(
            height: 80,
            width: 80,
            decoration: BoxDecoration(
              gradient: const LinearGradient(colors: [Brand.cyan, Brand.blue, Brand.purple]),
              shape: BoxShape.circle,
            ),
            child: const Icon(Icons.hub_rounded, size: 38, color: Colors.white),
          ),
        ),
        const SizedBox(height: Gap.lg),
        Text(t.crmWelcomeTitle,
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w800)),
        const SizedBox(height: Gap.sm),
        Text(t.crmWelcomeBody,
            textAlign: TextAlign.center,
            style: TextStyle(color: scheme.onSurfaceVariant, height: 1.4)),
        const SizedBox(height: Gap.lg),

        // ---- path switch ----
        SegmentedButton<bool>(
          segments: [
            // qa1: the full bn label wrapped to two lines inside the segment
            ButtonSegment(value: false, label: Text(t.qa1CrmStartShort), icon: const Icon(Icons.rocket_launch_rounded)),
            ButtonSegment(value: true, label: Text(t.crmJoinTeam), icon: const Icon(Icons.group_add_rounded)),
          ],
          selected: {_joinMode},
          onSelectionChanged: (s) => setState(() {
            _joinMode = s.first;
            _error = null;
          }),
        ),
        const SizedBox(height: Gap.lg),

        if (_error != null) ...[
          _errorBanner(t),
          const SizedBox(height: Gap.md),
        ],

        if (!_joinMode) _startForm(t) else _joinForm(t),
      ],
    );
  }

  Widget _errorBanner(AppLocalizations t) {
    final scheme = Theme.of(context).colorScheme;
    final e = _error!;
    return Container(
      padding: const EdgeInsets.all(Gap.md),
      decoration: BoxDecoration(
        color: scheme.errorContainer.withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(Radii.md),
      ),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Icon(Icons.error_outline_rounded, color: scheme.error, size: 20),
        const SizedBox(width: Gap.sm),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(e.message, style: TextStyle(color: scheme.onErrorContainer)),
            if (e.ref.isNotEmpty) ...[
              const SizedBox(height: Gap.xs),
              RefCodeChip(e.ref),
            ],
          ]),
        ),
      ]),
    );
  }

  // ---- (a) Start your company's CRM ----
  Widget _startForm(AppLocalizations t) {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(t.crmStartOrgHint, style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant)),
      const SizedBox(height: Gap.md),
      TextField(
        controller: _nameCtl,
        textCapitalization: TextCapitalization.words,
        decoration: InputDecoration(
          labelText: t.crmCompanyName,
          prefixIcon: const Icon(Icons.business_rounded),
          border: const OutlineInputBorder(),
        ),
      ),
      const SizedBox(height: Gap.md),
      Text(t.crmIndustry, style: const TextStyle(fontWeight: FontWeight.w700)),
      const SizedBox(height: Gap.xs),
      Wrap(spacing: Gap.xs, runSpacing: Gap.xs, children: [
        for (final i in _industries(t))
          ChoiceChip(
            label: Text(i.label),
            selected: _industry == i.code,
            onSelected: (_) => setState(() => _industry = i.code),
          ),
      ]),
      const SizedBox(height: Gap.md),
      Text(t.crmTeamSize, style: const TextStyle(fontWeight: FontWeight.w700)),
      const SizedBox(height: Gap.xs),
      Wrap(spacing: Gap.xs, runSpacing: Gap.xs, children: [
        for (final s in _teamSizes(t))
          ChoiceChip(
            label: Text(s.label),
            selected: _teamSize == s.code,
            onSelected: (_) => setState(() => _teamSize = s.code),
          ),
      ]),
      const SizedBox(height: Gap.lg),
      FilledButton.icon(
        onPressed: _busy ? null : () => _start(t),
        icon: _busy
            ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
            : const Icon(Icons.rocket_launch_rounded),
        label: Text(t.crmCreateOrg),
      ),
    ]);
  }

  // ---- (b) Join a team ----
  Widget _joinForm(AppLocalizations t) {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(t.crmJoinTeamHint, style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant)),
      const SizedBox(height: Gap.md),
      TextField(
        controller: _codeCtl,
        textCapitalization: TextCapitalization.characters,
        decoration: InputDecoration(
          labelText: t.crmInviteCode,
          hintText: 'ABCD2345',
          prefixIcon: const Icon(Icons.vpn_key_rounded),
          border: const OutlineInputBorder(),
        ),
      ),
      const SizedBox(height: Gap.lg),
      FilledButton.icon(
        onPressed: _busy ? null : () => _join(t),
        icon: _busy
            ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
            : const Icon(Icons.group_add_rounded),
        label: Text(t.crmJoinTeam),
      ),
    ]);
  }
}
