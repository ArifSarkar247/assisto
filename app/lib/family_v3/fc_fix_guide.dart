import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';

import '../l10n/app_localizations.dart';
import '../screens/battery_guidance_screen.dart' show BatteryGuidanceScreen, oemStepTitle, oemStepBody;
import '../services/oem_guide.dart';
import '../theme.dart';
import '../widgets/app_sheet.dart';
import 'fc_text.dart';

/// fcscreen — "Why no news from NAME?" (owner order e): the plain reason, then
/// the per-brand fix (Xiaomi, Realme, Oppo, Vivo, Samsung, Tecno, Infinix:
/// autostart + battery unrestricted), reusing the tl1 OEM step texts. On the
/// member's own phone it opens the real settings guide; for someone else the
/// steps can be sent to them.
class FcBrand {
  final String label;
  final OemFamily family;
  const FcBrand(this.label, this.family);
}

const fcBrands = <FcBrand>[
  FcBrand('Xiaomi', OemFamily.xiaomi),
  FcBrand('Realme', OemFamily.realme),
  FcBrand('Oppo', OemFamily.oppo),
  FcBrand('Vivo', OemFamily.vivo),
  FcBrand('Samsung', OemFamily.samsung),
  FcBrand('Tecno', OemFamily.transsion),
  FcBrand('Infinix', OemFamily.transsion),
];

/// Which chip to preselect from the brand the member's phone reported.
int? fcBrandIndex(String reported) {
  final s = reported.toLowerCase();
  if (s.isEmpty) return null;
  for (var i = 0; i < fcBrands.length; i++) {
    if (s.contains(fcBrands[i].label.toLowerCase())) return i;
  }
  if (s.contains('redmi') || s.contains('poco')) return 0;
  final f = detectOemFamily(s, s);
  final i = fcBrands.indexWhere((b) => b.family == f);
  return i < 0 ? null : i;
}

Future<void> showFcFixGuide(BuildContext context,
    {required String name, required String reason, Map? brain, bool isMe = false}) {
  return showAppSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (_) => FcFixGuide(name: name, reason: reason, brain: brain, isMe: isMe),
  );
}

class FcFixGuide extends StatefulWidget {
  final String name;
  final String reason;
  final Map? brain;
  final bool isMe;
  const FcFixGuide(
      {super.key, required this.name, required this.reason, this.brain, this.isMe = false});
  @override
  State<FcFixGuide> createState() => _FcFixGuideState();
}

class _FcFixGuideState extends State<FcFixGuide> {
  int? _brand; // index in fcBrands; -1 = other
  @override
  void initState() {
    super.initState();
    _brand = fcBrandIndex('${widget.brain?['brand'] ?? ''}');
  }

  OemFamily get _family =>
      (_brand == null || _brand! < 0) ? OemFamily.nearStock : fcBrands[_brand!].family;

  String _shareText(AppLocalizations t) {
    final steps = oemSteps(_family);
    final b = StringBuffer(t.fc3FixShareHead)..writeln();
    var i = 1;
    for (final s in steps) {
      b.writeln('$i. ${oemStepTitle(t, s, _family)}: ${oemStepBody(t, s, _family)}');
      i++;
    }
    return b.toString();
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final steps = oemSteps(_family);
    final extra = switch (widget.reason) {
      'battery_off' => t.fc3FixCharge,
      'no_internet' => t.fc3FixInternet,
      _ => '',
    };
    return ListView(
      key: const ValueKey('fc3-fix-guide'),
      shrinkWrap: true,
      padding: const EdgeInsets.fromLTRB(Gap.lg, 0, Gap.lg, Gap.lg),
      children: [
        Text(t.fc3FixTitle(widget.name),
            style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700)),
        const SizedBox(height: Gap.sm),
        Text(fcReason(context, widget.reason, widget.brain),
            style: TextStyle(color: fcInk(context, 'stale'), fontWeight: FontWeight.w600)),
        if (extra.isNotEmpty) ...[
          const SizedBox(height: Gap.xs),
          Text(extra),
        ],
        if (widget.isMe) ...[
          const SizedBox(height: Gap.md),
          FilledButton.icon(
            key: const ValueKey('fc3-fix-mine'),
            style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(48)),
            onPressed: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const BatteryGuidanceScreen())),
            icon: const Icon(Icons.settings_rounded),
            label: Text(t.fc3FixMine),
          ),
        ],
        const SizedBox(height: Gap.md),
        Text(t.fc3FixPickBrand(widget.name), style: const TextStyle(fontWeight: FontWeight.w700)),
        const SizedBox(height: Gap.xs),
        Wrap(
          spacing: Gap.sm,
          runSpacing: Gap.xs,
          children: [
            for (var i = 0; i < fcBrands.length; i++)
              ChoiceChip(
                key: ValueKey('fc3-brand-${fcBrands[i].label}'),
                label: Text(fcBrands[i].label),
                selected: _brand == i,
                onSelected: (_) => setState(() => _brand = i),
              ),
            ChoiceChip(
              label: Text(t.fc3FixOtherBrand),
              selected: _brand == -1,
              onSelected: (_) => setState(() => _brand = -1),
            ),
          ],
        ),
        const SizedBox(height: Gap.md),
        Text(t.fc3FixSteps, style: const TextStyle(fontWeight: FontWeight.w700)),
        for (var i = 0; i < steps.length; i++)
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: CircleAvatar(
                radius: 14,
                backgroundColor: scheme.primaryContainer,
                child: Text(fcDigits(context, i + 1),
                    style: TextStyle(color: scheme.onPrimaryContainer, fontSize: 13))),
            title: Text(oemStepTitle(t, steps[i], _family),
                style: const TextStyle(fontWeight: FontWeight.w600)),
            subtitle: Text(oemStepBody(t, steps[i], _family)),
          ),
        if (!widget.isMe) ...[
          const SizedBox(height: Gap.sm),
          FilledButton.tonalIcon(
            key: const ValueKey('fc3-fix-send'),
            style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(48)),
            onPressed: () => Share.share(_shareText(t)),
            icon: const Icon(Icons.send_rounded),
            label: Text(t.fc3FixSend),
          ),
        ],
      ],
    );
  }
}
