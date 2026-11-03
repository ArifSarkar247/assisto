import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../l10n/app_localizations.dart';
import 'ladder_common.dart' show fmtInt;

// aifinal (owner AI order 3 Nov 23:15, PART 3): the answer level the user
// picks above the AI chat input — Normal / Better / Best — with the credits
// one answer costs shown BEFORE sending. Never upgrades by itself; a level
// whose daily budget is used up shows "temporarily unavailable". Hidden when
// the owner switch is off (the server sends enabled: false). The last level
// is remembered on this phone.

class AiLevel {
  final String id;
  final String name;
  final int credits;
  final int maxChars;
  final bool available;
  const AiLevel(this.id, this.name, this.credits, this.maxChars, this.available);

  static AiLevel? from(Object? j) {
    if (j is! Map) return null;
    final id = j['id'];
    if (id is! String || id.isEmpty) return null;
    return AiLevel(id, (j['name'] ?? id).toString(), (j['credits'] as num?)?.toInt() ?? 0,
        (j['max_chars'] as num?)?.toInt() ?? 0, j['available'] != false);
  }
}

class AiLevelState {
  final bool enabled;
  final String defaultId;
  final List<AiLevel> levels;
  const AiLevelState(this.enabled, this.defaultId, this.levels);
  static const off = AiLevelState(false, 'normal', []);

  static AiLevelState parse(Map<String, dynamic> j) {
    if (j['enabled'] != true) return off;
    final ls = <AiLevel>[
      for (final x in (j['levels'] as List? ?? const []))
        if (AiLevel.from(x) != null) AiLevel.from(x)!
    ];
    if (ls.isEmpty) return off;
    return AiLevelState(true, (j['default'] ?? 'normal').toString(), ls);
  }

  AiLevel? byId(String? id) {
    for (final l in levels) {
      if (l.id == id) return l;
    }
    return null;
  }
}

const aiLevelPrefKey = 'ai_answer_level';

/// The level to use: the remembered one when it exists and is available,
/// else the server default, else the first available. Never a dearer level
/// than the user chose — an unavailable choice falls back to the default.
String pickAiLevel(AiLevelState s, String? remembered) {
  final r = s.byId(remembered);
  if (r != null && r.available) return r.id;
  final d = s.byId(s.defaultId);
  if (d != null && d.available) return d.id;
  for (final l in s.levels) {
    if (l.available) return l.id;
  }
  return s.defaultId;
}

class AiLevelPicker extends StatefulWidget {
  final Future<Map<String, dynamic>> Function() load;
  final ValueChanged<String?> onChanged;

  /// PART 4: claim the one-time welcome credits (server: once per verified
  /// phone + device); returns the server's message ('' = nothing granted).
  final Future<Map<String, dynamic>> Function()? welcome;
  const AiLevelPicker(
      {super.key, required this.load, required this.onChanged, this.welcome});

  @override
  State<AiLevelPicker> createState() => _AiLevelPickerState();
}

class _AiLevelPickerState extends State<AiLevelPicker> {
  AiLevelState _s = AiLevelState.off;
  String? _sel;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    AiLevelState s;
    try {
      s = AiLevelState.parse(await widget.load());
    } catch (_) {
      s = AiLevelState.off;
    }
    String? remembered;
    try {
      remembered = (await SharedPreferences.getInstance()).getString(aiLevelPrefKey);
    } catch (_) {}
    if (!mounted) return;
    final sel = s.enabled ? pickAiLevel(s, remembered) : null;
    setState(() {
      _s = s;
      _sel = sel;
    });
    widget.onChanged(sel);
    if (s.enabled && widget.welcome != null) {
      try {
        final r = await widget.welcome!();
        final msg = (r['message'] ?? '').toString();
        if (msg.isNotEmpty && mounted) {
          ScaffoldMessenger.maybeOf(context)
              ?.showSnackBar(SnackBar(content: Text(msg)));
        }
      } catch (_) {}
    }
  }

  Future<void> _choose(AiLevel l) async {
    if (!l.available) return;
    setState(() => _sel = l.id);
    widget.onChanged(l.id);
    try {
      (await SharedPreferences.getInstance()).setString(aiLevelPrefKey, l.id);
    } catch (_) {
      // best-effort: remembering the level is a convenience; the pick still applies
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!_s.enabled) return const SizedBox.shrink();
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final cur = _s.byId(_sel);
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 0),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Wrap(spacing: 8, runSpacing: 4, children: [
          for (final l in _s.levels)
            Semantics(
              selected: l.id == _sel,
              label: l.available
                  ? t.ailvChipA11y(l.name, fmtInt(context, l.credits))
                  : '${l.name}. ${t.ailvUnavailable}',
              excludeSemantics: true,
              child: ChoiceChip(
                materialTapTargetSize: MaterialTapTargetSize.padded,
                label: Text(l.available
                    ? t.ailvChip(l.name, fmtInt(context, l.credits))
                    : '${l.name} · ${t.ailvUnavailable}'),
                selected: l.id == _sel,
                onSelected: l.available ? (_) => _choose(l) : null,
              ),
            ),
        ]),
        if (cur != null)
          Padding(
            padding: const EdgeInsets.only(top: 2, left: 4),
            child: Text(t.ailvEstimate(fmtInt(context, cur.credits)),
                style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant)),
          ),
      ]),
    );
  }
}

/// The small hint under a Normal answer to a hard question. A hint only:
/// nothing is re-sent or charged unless the user picks Better themselves.
class AiBetterHint extends StatelessWidget {
  final Map<String, dynamic> meta;
  const AiBetterHint(this.meta, {super.key});
  static bool shows(Map<String, dynamic> m) => m['hint_better'] == true;

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: 4, left: 4),
      child: Text(t.ailvHintBetter,
          style: TextStyle(
              fontSize: 12, color: Theme.of(context).colorScheme.onSurfaceVariant)),
    );
  }
}
