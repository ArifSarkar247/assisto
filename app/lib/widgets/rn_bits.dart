import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../famcare_api.dart';
import '../l10n/app_localizations.dart';
import '../state.dart';
import '../theme.dart';
import 'app_sheet.dart';

/// remnotes (owner Reminders & Notes review 28 Oct) — small shared pieces.

/// Bangla digits under bn for any value (ARB `Object` placeholders and
/// `'$n'` print Latin digits otherwise).
String rnDigits(AppLocalizations t, Object? v) {
  final s = '${v ?? ''}';
  if (!t.localeName.startsWith('bn')) return s;
  final b = StringBuffer();
  for (final r in s.runes) {
    b.writeCharCode(r >= 0x30 && r <= 0x39 ? 0x09E6 + (r - 0x30) : r);
  }
  return b.toString();
}

// ------------------------------------------------------------ note colours
/// Palette keys stored on the server (core/remnotes.NOTE_COLORS).
const List<String> kNoteColors = [
  'red', 'orange', 'yellow', 'green', 'teal', 'blue', 'purple', 'gray',
];

Color _base(String key) => switch (key) {
      // Material's named swatches (no new hex literals outside theme.dart)
      'red' => Colors.red.shade600,
      'orange' => Colors.orange.shade600,
      'yellow' => Colors.amber.shade500,
      'green' => Colors.green.shade600,
      'teal' => Colors.teal.shade600,
      'blue' => Colors.blue.shade600,
      'purple' => Colors.purple.shade600,
      _ => Colors.blueGrey.shade500,
    };

/// The card fill for a colour key: a soft tint over the surface, so the
/// normal on-surface text keeps its contrast in light AND dark themes.
Color? noteFill(BuildContext context, String? key) {
  if (key == null || !kNoteColors.contains(key)) return null;
  final scheme = Theme.of(context).colorScheme;
  final dark = Theme.of(context).brightness == Brightness.dark;
  return Color.alphaBlend(
      _base(key).withValues(alpha: dark ? 0.24 : 0.16), scheme.surface);
}

/// The swatch dot colour (the strong colour itself).
Color noteSwatch(String key) => _base(key);

String noteColorName(AppLocalizations t, String key) => switch (key) {
      'red' => t.rnColorRed,
      'orange' => t.rnColorOrange,
      'yellow' => t.rnColorYellow,
      'green' => t.rnColorGreen,
      'teal' => t.rnColorTeal,
      'blue' => t.rnColorBlue,
      'purple' => t.rnColorPurple,
      'gray' => t.rnColorGray,
      _ => t.rnColorNone,
    };

/// A row of colour swatches (none + 8). 48dp targets, each with a label for
/// TalkBack; the chosen one shows a tick (never colour alone).
class NoteColorPicker extends StatelessWidget {
  const NoteColorPicker({super.key, required this.value, required this.onChanged});
  final String value;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    Widget dot(String key) {
      final on = value == key;
      final fill = key.isEmpty ? scheme.surface : noteSwatch(key);
      return Semantics(
        button: true,
        selected: on,
        label: key.isEmpty ? t.rnColorNone : noteColorName(t, key),
        child: InkResponse(
          key: ValueKey('rn-color-${key.isEmpty ? 'none' : key}'),
          onTap: () => onChanged(key),
          radius: 26,
          child: SizedBox(
            width: 48,
            height: 48,
            child: Center(
              child: Container(
                width: 32,
                height: 32,
                decoration: BoxDecoration(
                  color: fill,
                  shape: BoxShape.circle,
                  border: Border.all(
                      color: on ? scheme.primary : scheme.outlineVariant,
                      width: on ? 3 : 1),
                ),
                child: on
                    ? Icon(Icons.check_rounded,
                        size: 18,
                        color: key.isEmpty || key == 'yellow'
                            ? Colors.black87
                            : Colors.white)
                    : (key.isEmpty
                        ? Icon(Icons.format_color_reset_rounded,
                            size: 16, color: scheme.onSurfaceVariant)
                        : null),
              ),
            ),
          ),
        ),
      );
    }

    return Wrap(children: [dot(''), for (final k in kNoteColors) dot(k)]);
  }
}

// ------------------------------------------------------------ My Circle pick
/// Pick ONE accepted My Circle member (the same list Family Care uses) —
/// nobody's name is typed twice. Returns {circle_id, name, relation} or null.
Future<Map<String, dynamic>?> pickCircleMember(BuildContext context,
    {required String title, String? subtitle}) {
  return showAppSheet<Map<String, dynamic>>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (_) => _CirclePick(title: title, subtitle: subtitle),
  );
}

/// Accepted Circle rows from /family/circle-pick (null = could not load).
Future<List<Map<String, dynamic>>?> loadCircleRows(BuildContext context) async {
  try {
    final r = await context.read<AppState>().api.famCirclePick();
    return [
      for (final e in famPickRows(r))
        if (e['circle_id'] != null) e
    ];
  } catch (_) {
    return null;
  }
}

class _CirclePick extends StatefulWidget {
  const _CirclePick({required this.title, this.subtitle});
  final String title;
  final String? subtitle;
  @override
  State<_CirclePick> createState() => _CirclePickState();
}

class _CirclePickState extends State<_CirclePick> {
  List<Map<String, dynamic>>? _rows;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _failed = false);
    final r = await loadCircleRows(context);
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
    Widget body;
    if (_failed) {
      body = Column(mainAxisSize: MainAxisSize.min, children: [
        Text(t.rnLoadFailed, textAlign: TextAlign.center),
        const SizedBox(height: Gap.md),
        FilledButton.icon(
            onPressed: _load,
            icon: const Icon(Icons.refresh_rounded),
            label: Text(t.retry)),
      ]);
    } else if (_rows == null) {
      body = const Padding(
          padding: EdgeInsets.all(Gap.xl),
          child: Center(child: CircularProgressIndicator()));
    } else if (_rows!.isEmpty) {
      body = Text(t.rnCircleNone,
          key: const ValueKey('rn-circle-none'), textAlign: TextAlign.center);
    } else {
      body = Column(mainAxisSize: MainAxisSize.min, children: [
        for (final r in _rows!)
          ListTile(
            key: ValueKey('rn-circle-${r['circle_id']}'),
            leading: CircleAvatar(
                child: Text(('${r['name'] ?? ''}'.trim().isEmpty
                        ? '?'
                        : '${r['name']}'.trim().characters.first)
                    .toUpperCase())),
            title: Text('${r['name'] ?? ''}'),
            onTap: () => Navigator.pop(context, r),
          ),
      ]);
    }
    return Padding(
      padding: EdgeInsets.fromLTRB(
          Gap.lg, 0, Gap.lg, Gap.lg + MediaQuery.of(context).viewInsets.bottom),
      child: SingleChildScrollView(
        child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(widget.title,
                  style: Theme.of(context)
                      .textTheme
                      .titleLarge
                      ?.copyWith(fontWeight: FontWeight.w700)),
              if (widget.subtitle != null) ...[
                const SizedBox(height: Gap.xs),
                Text(widget.subtitle!,
                    style: TextStyle(color: scheme.onSurfaceVariant)),
              ],
              const SizedBox(height: Gap.md),
              body,
            ]),
      ),
    );
  }
}

/// remnotes: one honest strip when the server refused a queued write.
class SyncRefusalStrip extends StatelessWidget {
  const SyncRefusalStrip({super.key, required this.message});
  final String? message;
  @override
  Widget build(BuildContext context) {
    final m = message;
    if (m == null || m.isEmpty) return const SizedBox.shrink();
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    return Semantics(
      liveRegion: true,
      child: Container(
        key: const ValueKey('rn-sync-refused'),
        width: double.infinity,
        margin: const EdgeInsets.fromLTRB(Gap.md, Gap.sm, Gap.md, 0),
        padding: const EdgeInsets.all(Gap.sm),
        decoration: BoxDecoration(
            color: scheme.errorContainer,
            borderRadius: BorderRadius.circular(Radii.md)),
        child: Row(children: [
          Icon(Icons.cloud_off_rounded, size: 18, color: scheme.onErrorContainer),
          const SizedBox(width: Gap.sm),
          Expanded(
              child: Text(t.rnSyncRefused(m),
                  style: TextStyle(color: scheme.onErrorContainer))),
        ]),
      ),
    );
  }
}
