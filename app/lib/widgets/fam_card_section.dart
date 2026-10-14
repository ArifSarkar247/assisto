import 'package:flutter/material.dart';
import '../theme.dart';
import '../l10n/app_localizations.dart';
import 'fam_sharing_strings.dart';
import 'wrapped_share.dart';

/// #73 FAMILY CARD (SPEC v2.1 §21) — ADVANCED upgrade of the FAMILY good-bit.
/// A shareable family card (members + relations + emergency info), bilingual,
/// light/dark, captured to PNG via the proven RepaintBoundary->PNG flow already
/// used by emergency_card_view / money_wrapped (reused via WrappedShare), plus
/// a print/export action.
///
/// Self-contained, clearly bounded, embedded as ONE tab in FamilyScreen. It
/// only renders data the screen already holds (`members`) — it invents nothing
/// and reaches no network. Does not touch the famacct section (D5).
class FamCardSection extends StatefulWidget {
  final List<Map<String, dynamic>> members;
  const FamCardSection({super.key, required this.members});

  @override
  State<FamCardSection> createState() => _FamCardSectionState();
}

class _FamCardSectionState extends State<FamCardSection> {
  final GlobalKey _boundaryKey = GlobalKey();
  bool _dark = false;

  // Emergency info the owner can fill in for the card (blood group, address,
  // one emergency contact). Local to the card; shared only inside the image.
  final _blood = TextEditingController();
  final _address = TextEditingController();
  final _emName = TextEditingController();
  final _emPhone = TextEditingController();

  @override
  void dispose() {
    _blood.dispose();
    _address.dispose();
    _emName.dispose();
    _emPhone.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    if (widget.members.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(Gap.xl),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Icon(Icons.badge_outlined,
                size: 48, color: scheme.onSurfaceVariant),
            const SizedBox(height: Gap.md),
            Text(famLabel(context, 'famCardEmpty'),
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.titleMedium),
          ]),
        ),
      );
    }
    return ListView(
      padding: const EdgeInsets.fromLTRB(Gap.md, Gap.md, Gap.md, Gap.xl),
      children: [
        Row(children: [
          Expanded(
            child: Text(famLabel(context, 'famCardTitle'),
                style: Theme.of(context).textTheme.titleLarge),
          ),
          SegmentedButton<bool>(
            segments: [
              ButtonSegment(value: false, label: Text(famLabel(context, 'famCardLight'))),
              ButtonSegment(value: true, label: Text(famLabel(context, 'famCardDark'))),
            ],
            selected: {_dark},
            onSelectionChanged: (s) => setState(() => _dark = s.first),
          ),
        ]),
        const SizedBox(height: Gap.md),
        // The capturable card.
        RepaintBoundary(
          key: _boundaryKey,
          child: _card(),
        ),
        const SizedBox(height: Gap.md),
        Wrap(spacing: Gap.sm, runSpacing: Gap.sm, children: [
          FilledButton.icon(
            onPressed: _shareImage,
            icon: const Icon(Icons.image_outlined),
            label: Text(famLabel(context, 'famCardShareImage')),
          ),
          OutlinedButton.icon(
            onPressed: _shareImage, // print/export = same PNG the user can save/print
            icon: const Icon(Icons.print_outlined),
            label: Text(famLabel(context, 'famCardPrint')),
          ),
          OutlinedButton.icon(
            onPressed: _editEmergency,
            icon: const Icon(Icons.edit_outlined),
            label: Text(famLabel(context, 'famCardEditEmergency')),
          ),
        ]),
      ],
    );
  }

  Widget _card() {
    // Fixed card colours (not theme) so the captured PNG is deterministic.
    final bg = _dark ? const Color(0xFF13161C) : Colors.white;
    final fg = _dark ? Colors.white : const Color(0xFF13161C);
    final sub = _dark ? Colors.white70 : Colors.black54;
    final hasEmergency = _blood.text.trim().isNotEmpty ||
        _address.text.trim().isNotEmpty ||
        _emName.text.trim().isNotEmpty;
    return Container(
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(Radii.lg),
        border: Border.all(color: _dark ? Colors.white24 : Colors.black12),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(Gap.lg),
          decoration: BoxDecoration(
            gradient: Brand.gradient,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(Radii.lg)),
          ),
          child: Row(children: [
            const Icon(Icons.family_restroom, color: Colors.white),
            const SizedBox(width: Gap.md),
            Text(famLabel(context, 'famCardMyFamily'),
                style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w700,
                    fontSize: 18)),
            const Spacer(),
            Text(AppLocalizations.of(context).famCardMembers(famNum(context, widget.members.length)),
                style: const TextStyle(color: Colors.white70, fontSize: 13)),
          ]),
        ),
        Padding(
          padding: const EdgeInsets.all(Gap.lg),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            for (final m in widget.members) _memberRow(m, fg, sub),
            if (hasEmergency) ...[
              Divider(height: Gap.xl, color: _dark ? Colors.white24 : Colors.black12),
              Text(famLabel(context, 'famCardEmergency'),
                  style: TextStyle(fontWeight: FontWeight.w700, color: fg)),
              const SizedBox(height: Gap.xs),
              if (_blood.text.trim().isNotEmpty)
                _emRow(famLabel(context, 'famCardBlood'), _blood.text.trim(), fg, sub),
              if (_address.text.trim().isNotEmpty)
                _emRow(famLabel(context, 'famCardAddress'), _address.text.trim(), fg, sub),
              if (_emName.text.trim().isNotEmpty)
                _emRow(
                    famLabel(context, 'famCardEmContact'),
                    [_emName.text.trim(), _emPhone.text.trim()]
                        .where((s) => s.isNotEmpty)
                        .join(' · '),
                    fg,
                    sub),
            ],
          ]),
        ),
      ]),
    );
  }

  Widget _memberRow(Map<String, dynamic> m, Color fg, Color sub) {
    final name = (m['name'] ?? '').toString();
    final rel = (m['relation'] ?? '').toString();
    final phone = (m['phone'] ?? '').toString();
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(children: [
        Icon(Icons.person_outline, size: 18, color: sub),
        const SizedBox(width: Gap.sm),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(name,
                style: TextStyle(color: fg, fontWeight: FontWeight.w600)),
            if (rel.isNotEmpty || phone.isNotEmpty)
              Text([rel, phone].where((s) => s.isNotEmpty).join(' · '),
                  style: TextStyle(color: sub, fontSize: 13)),
          ]),
        ),
      ]),
    );
  }

  Widget _emRow(String label, String value, Color fg, Color sub) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: RichText(
          text: TextSpan(children: [
            TextSpan(
                text: '$label: ',
                style: TextStyle(color: sub, fontSize: 13)),
            TextSpan(
                text: value,
                style: TextStyle(
                    color: fg, fontSize: 13, fontWeight: FontWeight.w600)),
          ]),
        ),
      );

  Future<void> _shareImage() async {
    final ok = await WrappedShare.shareAsImage(
        _boundaryKey, famLabel(context, 'famCardMyFamily'));
    if (!ok && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(famLabel(context, 'famCardShareFailed'))));
    }
  }

  Future<void> _editEmergency() async {
    final t = AppLocalizations.of(context);
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(famLabel(context, 'famCardEditEmergency')),
        content: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            TextField(
                controller: _blood,
                decoration:
                    InputDecoration(labelText: famLabel(context, 'famCardBlood'))),
            TextField(
                controller: _address,
                decoration:
                    InputDecoration(labelText: famLabel(context, 'famCardAddress'))),
            TextField(
                controller: _emName,
                decoration:
                    InputDecoration(labelText: famLabel(context, 'famCardEmContact'))),
            TextField(
                controller: _emPhone,
                keyboardType: TextInputType.phone,
                decoration: InputDecoration(labelText: t.phoneOptional)),
          ]),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: Text(t.cancel)),
          FilledButton(
              onPressed: () {
                setState(() {});
                Navigator.pop(ctx);
              },
              child: Text(t.save)),
        ],
      ),
    );
  }
}
