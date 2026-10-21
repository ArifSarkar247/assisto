import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../theme.dart';
import 'voice_input.dart';

/// Settings -> Voice: the ONLY place to override the voice-input language.
/// Auto (default) listens with the Bangla recogniser, which also handles
/// English and mixed Banglish speech; Bangla / English force one language.
/// The chat screens read the saved choice each time they open.
class SettingsVoiceSection extends StatefulWidget {
  const SettingsVoiceSection({super.key});

  @override
  State<SettingsVoiceSection> createState() => _SettingsVoiceSectionState();
}

class _SettingsVoiceSectionState extends State<SettingsVoiceSection> {
  String _mode = 'auto';

  @override
  void initState() {
    super.initState();
    VoiceDictation.savedMode().then((m) {
      if (mounted) setState(() => _mode = m);
    });
  }

  void _set(String m) {
    setState(() => _mode = m);
    VoiceDictation.saveMode(m);
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final cs = Theme.of(context).colorScheme;
    final options = [
      ('auto', Icons.auto_awesome_outlined, t.p1VoiceAuto, t.p1VoiceAutoBody),
      (
        'bn',
        Icons.record_voice_over_outlined,
        t.languageBangla,
        t.p1VoiceBnBody
      ),
      (
        'en',
        Icons.record_voice_over_outlined,
        t.languageEnglish,
        t.p1VoiceEnBody
      ),
    ];
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(Gap.lg, Gap.md, Gap.lg, Gap.xs),
        child: Row(children: [
          Icon(Icons.mic_none, size: 20, color: cs.primary),
          const SizedBox(width: Gap.sm),
          Expanded(
            child: Text(t.p1VoiceTitle,
                style: Theme.of(context)
                    .textTheme
                    .titleMedium
                    ?.copyWith(fontWeight: FontWeight.w700)),
          ),
        ]),
      ),
      RadioGroup<String>(
        groupValue: _mode,
        onChanged: (v) {
          if (v != null) _set(v);
        },
        child: Column(children: [
          for (final o in options)
            RadioListTile<String>(
              key: ValueKey('voice_mode_${o.$1}'),
              value: o.$1,
              secondary: Icon(o.$2, color: cs.onSurfaceVariant),
              title: Text(o.$3,
                  style: const TextStyle(fontWeight: FontWeight.w600)),
              subtitle: Text(o.$4),
            ),
        ]),
      ),
      Padding(
        padding: const EdgeInsets.fromLTRB(Gap.lg, 0, Gap.lg, Gap.sm),
        child: Text(t.p1VoiceNote,
            style: TextStyle(fontSize: 12.5, color: cs.onSurfaceVariant)),
      ),
    ]);
  }
}
