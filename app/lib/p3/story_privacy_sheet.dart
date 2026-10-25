// P3 — WhatsApp-style privacy for Stories and Notes:
// My contacts / My contacts except… / Only share with…
import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../theme.dart';
import '../widgets/notif_models.dart' show notifLocalizeDigits;
import 'story_crypto.dart';

String privacyLabel(AppLocalizations t, StoryPrivacy p, BuildContext context) =>
    switch (p.mode) {
      StoryPrivacy.except => p.exclude.isEmpty
          ? t.p3PrivExcept
          : t.p3PrivExceptN(notifLocalizeDigits(context, '${p.exclude.length}')),
      StoryPrivacy.chosen =>
        t.p3PrivOnlyN(notifLocalizeDigits(context, '${p.allow.length}')),
      _ => t.p3PrivContacts,
    };

Future<StoryPrivacy?> showStoryPrivacySheet(BuildContext context,
    {required List<Map<String, dynamic>> members,
    required StoryPrivacy initial,
    required String title,
    String? note}) {
  return showModalBottomSheet<StoryPrivacy>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (_) => StoryPrivacySheet(
        members: members, initial: initial, title: title, note: note),
  );
}

class StoryPrivacySheet extends StatefulWidget {
  final List<Map<String, dynamic>> members;
  final StoryPrivacy initial;
  final String title;
  final String? note;
  const StoryPrivacySheet(
      {super.key,
      required this.members,
      required this.initial,
      required this.title,
      this.note});
  @override
  State<StoryPrivacySheet> createState() => _StoryPrivacySheetState();
}

class _StoryPrivacySheetState extends State<StoryPrivacySheet> {
  late String _mode = widget.initial.mode;
  late final Set<int> _allow = {...widget.initial.allow};
  late final Set<int> _except = {...widget.initial.exclude};

  List<Map<String, dynamic>> get _people =>
      [for (final m in widget.members) if (peerUserId(m) != null) m];

  Future<void> _pick(bool chosen) async {
    final t = AppLocalizations.of(context);
    final target = chosen ? _allow : _except;
    final picked = {...target};
    final ok = await showModalBottomSheet<bool>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (ctx) => StatefulBuilder(builder: (ctx, setS) {
        return SafeArea(
          child: ConstrainedBox(
            constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(ctx).height * 0.75),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: Gap.lg),
                child: Text(chosen ? t.p3PrivPickOnly : t.p3PrivPickExcept,
                    style: Theme.of(ctx).textTheme.titleMedium),
              ),
              Flexible(
                child: _people.isEmpty
                    ? Padding(
                        padding: const EdgeInsets.all(Gap.xl),
                        child: Text(t.p3PrivNoContacts, textAlign: TextAlign.center))
                    : ListView(shrinkWrap: true, children: [
                        for (final m in _people)
                          CheckboxListTile(
                            value: picked.contains(peerUserId(m)),
                            onChanged: (v) => setS(() => v == true
                                ? picked.add(peerUserId(m)!)
                                : picked.remove(peerUserId(m))),
                            title: Text('${m['name'] ?? ''}', overflow: TextOverflow.ellipsis),
                          ),
                      ]),
              ),
              Padding(
                padding: const EdgeInsets.all(Gap.lg),
                child: SizedBox(
                  width: double.infinity,
                  child: FilledButton(
                      onPressed: () => Navigator.pop(ctx, true), child: Text(t.p3Done)),
                ),
              ),
            ]),
          ),
        );
      }),
    );
    if (ok == true) {
      setState(() {
        target
          ..clear()
          ..addAll(picked);
        _mode = chosen ? StoryPrivacy.chosen : StoryPrivacy.except;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    String n(int x) => notifLocalizeDigits(context, '$x');
    Widget option(String mode, String title, String sub, {VoidCallback? onPick}) =>
        RadioListTile<String>(
          key: ValueKey('p3-priv-$mode'),
          value: mode,
          title: Text(title),
          subtitle: Text(sub),
          secondary: onPick == null
              ? null
              : IconButton(
                  tooltip: t.p3PrivChoose,
                  icon: const Icon(Icons.edit_rounded),
                  onPressed: onPick),
        );
    return SafeArea(
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: Gap.lg),
              child: Text(widget.title, style: Theme.of(context).textTheme.titleMedium),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(Gap.lg, Gap.xs, Gap.lg, Gap.sm),
              child: Text(widget.note ?? t.p3PrivWho,
                  style: TextStyle(fontSize: 13, color: scheme.onSurfaceVariant)),
            ),
            RadioGroup<String>(
              groupValue: _mode,
              onChanged: (v) {
                if (v == StoryPrivacy.everyone) {
                  setState(() => _mode = v!);
                } else if (v != null) {
                  _pick(v == StoryPrivacy.chosen);
                }
              },
              child: Column(children: [
                option(StoryPrivacy.everyone, t.p3PrivContacts, t.p3PrivContactsSub),
                option(StoryPrivacy.except, t.p3PrivExcept,
                    _except.isEmpty ? t.p3PrivExceptSub : t.p3PrivExcludedN(n(_except.length)),
                    onPick: () => _pick(false)),
                option(StoryPrivacy.chosen, t.p3PrivOnly,
                    _allow.isEmpty ? t.p3PrivOnlySub : t.p3PrivIncludedN(n(_allow.length)),
                    onPick: () => _pick(true)),
              ]),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(Gap.lg, Gap.sm, Gap.lg, Gap.xs),
              child: Row(children: [
                Icon(Icons.lock_outline_rounded, size: 16, color: scheme.primary),
                const SizedBox(width: Gap.sm),
                Expanded(
                    child: Text(t.p3PrivE2e,
                        style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant))),
              ]),
            ),
            Padding(
              padding: const EdgeInsets.all(Gap.lg),
              child: FilledButton(
                key: const ValueKey('p3-priv-save'),
                onPressed: (_mode == StoryPrivacy.chosen && _allow.isEmpty)
                    ? null
                    : () => Navigator.pop(
                        context,
                        StoryPrivacy(_mode,
                            allow: _allow.toList(), exclude: _except.toList())),
                child: Text(t.p3Done),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
