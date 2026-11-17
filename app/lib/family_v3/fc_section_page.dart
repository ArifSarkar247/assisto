import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../l10n/app_localizations.dart';
import '../state.dart';
import '../theme.dart';
import '../widgets/fam_card_section.dart';
import '../widgets/fam_members_section.dart';
import '../widgets/fam_probashi_section.dart';
import '../widgets/fam_school_section.dart';
import '../widgets/fam_sharing_hub.dart';
import '../widgets/famacct_section.dart';
import '../widgets/skeleton.dart';

/// fcscreen — one old Family Care section on its own page, opened from a
/// More row of the v3 Family screen. Every feature of the 6 old tabs stays
/// reachable (owner order i): Kids and school, Family ledger, Important
/// papers (+ bazar list + privacy), Probashi, Family card, Members.
enum FcSection { school, ledger, papers, probashi, card, members, bazar } // bazar: gap-familycare

class FcSectionPage extends StatefulWidget {
  final FcSection section;
  final String title;

  /// gap-familycare: members abroad [{name, tz}] for the Probashi page.
  final List<Map<String, String>> abroad;

  /// gap-familycare: the v3 family for the SHARED ledger, and its other
  /// members as picker rows [{id: 'u<user id>', name}].
  final int? familyId;
  final List<Map<String, dynamic>> familyMembers;

  /// Gallery: the ledger's first sub-tab.
  final int debugLedgerTab;
  const FcSectionPage(
      {super.key,
      required this.section,
      required this.title,
      this.abroad = const [],
      this.familyId,
      this.familyMembers = const [],
      this.debugLedgerTab = 0});
  @override
  State<FcSectionPage> createState() => _FcSectionPageState();
}

class _FcSectionPageState extends State<FcSectionPage> {
  List<Map<String, dynamic>> _members = [];
  List<Map<String, dynamic>> _school = [];
  bool _loading = true;
  bool _failed = false;
  bool _sharedLedger = true; // gap-familycare: the family's ledger first

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final api = context.read<AppState>().api;
    try {
      _members = await api.listItems('family');
      if (widget.section == FcSection.school) _school = await api.listItems('school');
      FamCardStore.cacheMembers(_members);
      _failed = false;
    } catch (_) {
      _failed = _members.isEmpty;
    }
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _pick() async {
    final changed = await showFamCirclePicker(context, onAddByHand: () async {
      final ok = await showFamMemberForm(context);
      if (ok == true) await _load();
    });
    if (changed == true) await _load();
  }

  Widget _body() {
    switch (widget.section) {
      case FcSection.school:
        return FamSchoolSection(items: _school, members: _members, onChanged: _load);
      case FcSection.ledger:
        final fid = widget.familyId;
        if (fid == null) return FamAcctSection(members: _members, onAddMember: _pick);
        final t = AppLocalizations.of(context);
        return Column(children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(Gap.md, Gap.sm, Gap.md, 0),
            child: SizedBox(
              width: double.infinity,
              child: SegmentedButton<bool>(
                key: const ValueKey('fcg-ledger-scope'),
                showSelectedIcon: false,
                segments: [
                  ButtonSegment(value: true, label: Text(t.fcgLedgerFamily, maxLines: 2, textAlign: TextAlign.center)),
                  ButtonSegment(value: false, label: Text(t.fcgLedgerMine, maxLines: 2, textAlign: TextAlign.center)),
                ],
                selected: {_sharedLedger},
                onSelectionChanged: (v) => setState(() => _sharedLedger = v.first),
              ),
            ),
          ),
          Expanded(
            child: _sharedLedger
                ? FamAcctSection(
                    key: ValueKey('fcg-ledger-family-$fid'),
                    members: widget.familyMembers,
                    familyId: fid,
                    initialTab: widget.debugLedgerTab)
                : FamAcctSection(
                    key: const ValueKey('fcg-ledger-mine'), members: _members, onAddMember: _pick),
          ),
        ]);
      case FcSection.papers: // gap-familycare: papers open on the papers pane
        return FamSharingHub(members: _members, onAddMember: _pick, initialPane: 'docs');
      case FcSection.bazar:
        return FamSharingHub(members: _members, onAddMember: _pick);
      case FcSection.probashi:
        return FamProbashiSection(abroad: widget.abroad);
      case FcSection.card:
        return FamCardSection(members: _members, onAddMember: _pick);
      case FcSection.members:
        return FamMembersSection(members: _members, onChanged: _load);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(widget.title)),
      body: _loading
          ? const SkeletonList()
          : (_failed && widget.section != FcSection.probashi)
              ? StateMessage(
                  icon: Icons.cloud_off_rounded,
                  title: t.loadFailed,
                  tint: Brand.danger,
                  action: FilledButton.icon(
                    onPressed: () {
                      setState(() => _loading = true);
                      _load();
                    },
                    icon: const Icon(Icons.refresh_rounded),
                    label: Text(t.retry),
                  ),
                )
              : _body(),
    );
  }
}
