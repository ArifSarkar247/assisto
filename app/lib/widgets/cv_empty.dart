import 'package:flutter/material.dart';
import 'circle_people_filter.dart'; // circlea

import '../l10n/app_localizations.dart';
import '../screens/messenger/messenger_home_screen.dart';
import '../theme.dart';
import 'app_sheet.dart';
import 'fam_empty.dart' show famDigits;
import 'rn_bits.dart' show loadCircleRows;

/// cctvveh (owner checklist, 2 Nov): the CCTV + vehicle empty states share
/// the Family Care shape — one line saying what you gain, ONE big primary
/// button that does the first real step, an optional second action and a
/// short numbered how-to. Unlike [FamEmptyState] this is a plain Column so it
/// can sit inside a card or a ListView (scrolls with its parent at 200%).
class CvEmptyBlock extends StatelessWidget {
  const CvEmptyBlock({
    super.key,
    required this.icon,
    required this.title,
    required this.benefit,
    this.primaryLabel,
    this.onPrimary,
    this.primaryIcon = Icons.add_rounded,
    this.steps = const [],
    this.secondaryLabel,
    this.onSecondary,
    this.compact = false,
  });

  final IconData icon;
  final String title;
  final String benefit;
  final String? primaryLabel;
  final VoidCallback? onPrimary;
  final IconData primaryIcon;
  final List<String> steps;
  final String? secondaryLabel;
  final VoidCallback? onSecondary;

  /// Inside a card: smaller icon, no top gap.
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    return Column(
      key: const ValueKey('cv-empty'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(height: compact ? Gap.xs : Gap.xl),
        Center(
          child: Container(
            height: compact ? 52 : 72,
            width: compact ? 52 : 72,
            decoration: BoxDecoration(
              color: scheme.primary.withValues(alpha: 0.12),
              shape: BoxShape.circle,
            ),
            child: Icon(icon, size: compact ? 26 : 34, color: scheme.primary),
          ),
        ),
        const SizedBox(height: Gap.md),
        Text(title,
            textAlign: TextAlign.center,
            style: (compact ? tt.titleMedium : tt.titleLarge)?.copyWith(fontWeight: FontWeight.w700)),
        const SizedBox(height: Gap.xs),
        Text(benefit,
            key: const ValueKey('cv-empty-benefit'),
            textAlign: TextAlign.center,
            style: tt.bodyLarge?.copyWith(color: scheme.onSurfaceVariant)),
        if (primaryLabel != null && onPrimary != null) ...[
          const SizedBox(height: Gap.lg),
          ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 56),
            child: FilledButton.icon(
              key: const ValueKey('cv-empty-primary'),
              onPressed: onPrimary,
              icon: Icon(primaryIcon),
              label: Text(primaryLabel!,
                  textAlign: TextAlign.center,
                  style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
            ),
          ),
        ],
        if (secondaryLabel != null && onSecondary != null) ...[
          const SizedBox(height: Gap.sm),
          ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 48),
            child: OutlinedButton(
              key: const ValueKey('cv-empty-secondary'),
              onPressed: onSecondary,
              child: Text(secondaryLabel!, textAlign: TextAlign.center),
            ),
          ),
        ],
        if (steps.isNotEmpty) ...[
          const SizedBox(height: Gap.lg),
          Container(
            key: const ValueKey('cv-empty-steps'),
            padding: const EdgeInsets.all(Gap.md),
            decoration: BoxDecoration(
              color: scheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              for (var i = 0; i < steps.length; i++)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: Gap.xs),
                  child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    CircleAvatar(
                      radius: 12,
                      backgroundColor: scheme.primary,
                      child: Text(famDigits(context, '${i + 1}'),
                          style: TextStyle(
                              fontSize: 12, fontWeight: FontWeight.w700, color: scheme.onPrimary)),
                    ),
                    const SizedBox(width: Gap.sm),
                    Expanded(child: Text(steps[i])),
                  ]),
                ),
            ]),
          ),
        ],
        SizedBox(height: compact ? Gap.xs : Gap.lg),
      ],
    );
  }
}

/// Loader for the Circle picker (tests inject a fake list).
typedef CvCircleLoader = Future<List<Map<String, dynamic>>?> Function(BuildContext context);

/// Tests / gallery override for [pickCirclePerson]'s list.
CvCircleLoader? cvCircleLoaderOverride;

/// Pick ONE accepted My Circle member in one tap — the same list Family Care
/// uses (`/family/circle-pick`: circle_id, name, relation, phone). Rows whose
/// phone is in [already] show a tick and cannot be picked twice. When Circle
/// is empty the sheet says so and offers "Add someone to My Circle" (never a
/// dead end). Returns the row or null.
Future<Map<String, dynamic>?> pickCirclePerson(BuildContext context,
    {required String title, String? subtitle, Set<String> already = const {}}) {
  return showAppSheet<Map<String, dynamic>>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (_) => _CvCirclePick(title: title, subtitle: subtitle, already: already),
  );
}

/// Last 10 digits — '01711-000000', '+8801711000000' and '8801711000000'
/// compare equal.
String cvPhoneKey(String p) {
  final d = p.replaceAll(RegExp(r'\D'), '');
  return d.length > 10 ? d.substring(d.length - 10) : d;
}

class _CvCirclePick extends StatefulWidget {
  const _CvCirclePick({required this.title, this.subtitle, required this.already});
  final String title;
  final String? subtitle;
  final Set<String> already;
  @override
  State<_CvCirclePick> createState() => _CvCirclePickState();
}

class _CvCirclePickState extends State<_CvCirclePick> {
  List<Map<String, dynamic>>? _rows;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _failed = false);
    final r = await (cvCircleLoaderOverride ?? loadCircleRows)(context);
    if (!mounted) return;
    setState(() {
      _rows = r;
      _failed = r == null;
    });
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final already = {for (final p in widget.already) cvPhoneKey(p)};
    Widget body;
    if (_failed) {
      body = Column(mainAxisSize: MainAxisSize.min, children: [
        Text(t.rnLoadFailed, textAlign: TextAlign.center),
        const SizedBox(height: Gap.md),
        FilledButton.icon(
            onPressed: _load, icon: const Icon(Icons.refresh_rounded), label: Text(t.retry)),
      ]);
    } else if (_rows == null) {
      body = const Padding(
          padding: EdgeInsets.all(Gap.xl), child: Center(child: CircularProgressIndicator()));
    } else if (_rows!.isEmpty) {
      body = CvEmptyBlock(
        compact: true,
        icon: Icons.group_add_rounded,
        title: t.cvvCircleEmptyTitle,
        benefit: t.cvvCircleEmptyBody,
        primaryIcon: Icons.person_add_alt_1_rounded,
        primaryLabel: t.cvvOpenMyCircle,
        onPrimary: () {
          Navigator.pop(context);
          Navigator.of(context).push(MaterialPageRoute(
              builder: (_) => const MessengerHomeScreen(startAdd: true)));
        },
      );
    } else {
      // circlea: chips (All / Family / Others) + search, Family first
      body = CirclePeopleList(
        rows: _rows!,
        listKey: 'pick-circle',
        rowBuilder: (_, r) => Builder(builder: (_) {
            final phone = '${r['phone'] ?? ''}';
            final taken = phone.isNotEmpty && already.contains(cvPhoneKey(phone));
            final name = '${r['name'] ?? ''}'.trim();
            return ListTile(
              key: ValueKey('cv-circle-${r['circle_id']}'),
              minTileHeight: 56,
              enabled: !taken,
              leading: CircleAvatar(
                  child: Text((name.isEmpty ? '?' : name.characters.first).toUpperCase())),
              title: Text(name),
              subtitle: phone.isEmpty ? null : Text(famDigits(context, phone)),
              trailing: taken
                  ? Tooltip(
                      message: t.cvvAlreadyAdded,
                      child: Icon(Icons.check_circle_rounded, color: scheme.primary))
                  : const Icon(Icons.chevron_right_rounded),
              onTap: taken ? null : () => Navigator.pop(context, r),
            );
          }),
      );
    }
    return Padding(
      padding: EdgeInsets.fromLTRB(
          Gap.lg, 0, Gap.lg, Gap.lg + MediaQuery.of(context).viewInsets.bottom),
      child: SingleChildScrollView(
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
          Text(widget.title,
              style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700)),
          if (widget.subtitle != null) ...[
            const SizedBox(height: Gap.xs),
            Text(widget.subtitle!, style: TextStyle(color: scheme.onSurfaceVariant)),
          ],
          const SizedBox(height: Gap.md),
          body,
        ]),
      ),
    );
  }
}
