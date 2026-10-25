import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../theme.dart';

/// Resolve a visibility mode code (everyone/family/chosen/except) to its
/// localized label. Replaces the old StatusL10n.audienceLabel helper.
String _audienceLabel(AppLocalizations s, String mode) {
  switch (mode) {
    case StatusAudience.family:
      return s.statusAudienceFamily;
    case StatusAudience.chosen:
      return s.statusAudienceChosen;
    case StatusAudience.except:
      return s.statusAudienceExcept;
    default:
      return s.statusAudienceEveryone;
  }
}

/// Visibility codes — MIRROR core/logic/circle_status.py (AUD_*). Kept here so
/// the composer and the backend speak the same vocabulary.
class StatusAudience {
  StatusAudience._();
  static const everyone = 'everyone';
  static const family = 'family';
  static const chosen = 'chosen'; // allowlist of member ids
  static const except = 'except'; // everyone minus an excludelist
  static const all = [everyone, family, chosen, except];

  /// A fresh default visibility object (whole circle).
  static Map<String, dynamic> defaultVisibility() =>
      {'mode': everyone, 'allow_ids': <int>[], 'except_ids': <int>[]};
}

/// Bottom-sheet audience picker for a new status. Returns the visibility map
/// {mode, allow_ids, except_ids} the composer POSTs; the server re-resolves it
/// per viewer (circle_status.can_view_status) so this is a REQUEST, not trust.
class CircleStatusAudienceSheet extends StatefulWidget {
  /// The caller's circle members: [{id, name, relation}].
  final List<Map<String, dynamic>> members;
  final Map<String, dynamic> initial;

  const CircleStatusAudienceSheet({
    super.key,
    required this.members,
    required this.initial,
  });

  @override
  State<CircleStatusAudienceSheet> createState() =>
      _CircleStatusAudienceSheetState();
}

class _CircleStatusAudienceSheetState extends State<CircleStatusAudienceSheet> {
  late String _mode;
  late Set<int> _allow;
  late Set<int> _except;

  @override
  void initState() {
    super.initState();
    _mode = '${widget.initial['mode'] ?? StatusAudience.everyone}';
    _allow = _ids(widget.initial['allow_ids']);
    _except = _ids(widget.initial['except_ids']);
  }

  Set<int> _ids(dynamic v) =>
      ((v as List?) ?? const []).map((e) => e as int).toSet();

  Map<String, dynamic> _result() => {
        'mode': _mode,
        'allow_ids': _allow.toList()..sort(),
        'except_ids': _except.toList()..sort(),
      };

  @override
  Widget build(BuildContext context) {
    final s = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final needsList =
        _mode == StatusAudience.chosen || _mode == StatusAudience.except;
    final isExcept = _mode == StatusAudience.except;
    final selected = isExcept ? _except : _allow;

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(Gap.lg),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(s.statusWhoCanSee,
                style: Theme.of(context)
                    .textTheme
                    .titleMedium
                    ?.copyWith(color: scheme.primary)),
            const SizedBox(height: Gap.sm),
            for (final mode in StatusAudience.all)
              RadioListTile<String>(
                value: mode,
                groupValue: _mode,
                contentPadding: EdgeInsets.zero,
                title: Text(_audienceLabel(s, mode)),
                onChanged: (v) => setState(() => _mode = v!),
              ),
            if (needsList) ...[
              const Divider(),
              Text(isExcept ? s.statusExcludePeople : s.statusChoosePeople,
                  style: TextStyle(
                      fontSize: 12, color: scheme.onSurfaceVariant)),
              const SizedBox(height: Gap.xs),
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 260),
                child: ListView(
                  shrinkWrap: true,
                  children: [
                    for (final m in widget.members)
                      CheckboxListTile(
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        value: selected.contains(m['id'] as int),
                        title: Text('${m['name'] ?? ''}'),
                        onChanged: (on) => setState(() {
                          final id = m['id'] as int;
                          final set = isExcept ? _except : _allow;
                          if (on == true) {
                            set.add(id);
                          } else {
                            set.remove(id);
                          }
                        }),
                      ),
                  ],
                ),
              ),
            ],
            const SizedBox(height: Gap.sm),
            Align(
              alignment: Alignment.centerRight,
              child: FilledButton(
                onPressed: () => Navigator.of(context).pop(_result()),
                child: Text(s.statusDone),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// A compact tappable chip showing the current audience (used in the composer).
class CircleStatusAudienceChip extends StatelessWidget {
  final Map<String, dynamic> visibility;
  final VoidCallback onTap;
  const CircleStatusAudienceChip({
    super.key,
    required this.visibility,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final s = AppLocalizations.of(context);
    final mode = '${visibility['mode'] ?? StatusAudience.everyone}';
    return ActionChip(
      avatar: const Icon(Icons.visibility_rounded, size: 18),
      label: Text(_audienceLabel(s, mode)),
      onPressed: onTap,
    );
  }
}
