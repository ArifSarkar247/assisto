import 'package:flutter/material.dart';

import '../../api.dart';
import '../../l10n/app_localizations.dart';
import '../../theme.dart';
import '../../voice/reply_speaker.dart';
import 'fc_brain_api.dart';
import 'fc_brain_settings_screen.dart';

/// fcbrain — the NIGHT NEWS card on the Family screen (FcSlots.nightNewsCard).
///
/// One short card: tonight's family news (written by the Normal model from
/// structured facts only, or the plain template when AI is down; free), an
/// optional "Listen" (the phone's own TTS via ReplySpeaker), and "Change"
/// (time / off / what about me goes in). Before tonight's card is made the
/// server answers a template preview, so the card is never empty or fake.
class FcNightNewsCard extends StatefulWidget {
  const FcNightNewsCard({super.key, required this.api, this.familyId, this.debugData});
  final ApiClient api;
  final int? familyId;

  /// Gallery / tests: a fixed server answer (no network).
  final Map<String, dynamic>? debugData;

  @override
  State<FcNightNewsCard> createState() => _FcNightNewsCardState();
}

class _FcNightNewsCardState extends State<FcNightNewsCard> {
  Map<String, dynamic>? _d;
  bool _failed = false;
  final ReplySpeaker _speaker = ReplySpeaker();

  @override
  void initState() {
    super.initState();
    if (widget.debugData != null) {
      _d = widget.debugData;
    } else {
      _load();
    }
  }

  @override
  void dispose() {
    _speaker.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final r = await widget.api.fcbNightNews();
      if (mounted) setState(() => _d = r);
    } catch (_) {
      if (mounted) setState(() => _failed = true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final cs = Theme.of(context).colorScheme;
    final night = (_d?['night'] as Map?) ?? const {};
    if (_failed || (_d != null && night['on'] == false)) {
      // off (or offline): one quiet row to turn it on — never a dead card
      return ListTile(
        leading: const Icon(Icons.nightlight_round),
        title: Text(t.fcbNightTitle),
        subtitle: Text(_failed ? t.fcbNightOffline : t.fcbNightOff),
        trailing: TextButton(onPressed: _openSettings, child: Text(t.fcbChange)),
        onTap: _openSettings,
      );
    }
    final card = (_d?['card'] as Map?) ?? const {};
    final text = (card['text'] ?? '').toString();
    final preview = card['source'] == 'preview';
    final time = (night['time'] ?? '21:30').toString();
    final lang = Localizations.localeOf(context).languageCode;
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: Gap.lg, vertical: Gap.sm),
      child: Padding(
        padding: const EdgeInsets.all(Gap.lg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              Icon(Icons.nightlight_round, color: cs.primary),
              const SizedBox(width: Gap.sm),
              Expanded(
                child: Text(t.fcbNightTitle, style: Theme.of(context).textTheme.titleMedium),
              ),
            ]),
            const SizedBox(height: Gap.sm),
            if (_d == null)
              const LinearProgressIndicator()
            else ...[
              if (preview)
                Padding(
                  padding: const EdgeInsets.only(bottom: Gap.xs),
                  child: Text(t.fcbNightPreview(_clock(time, lang)),
                      style: Theme.of(context).textTheme.bodySmall),
                ),
              Text(text, style: Theme.of(context).textTheme.bodyLarge),
            ],
            const SizedBox(height: Gap.sm),
            Wrap(spacing: Gap.sm, runSpacing: Gap.xs, children: [
              if (text.isNotEmpty)
                OutlinedButton.icon(
                  style: OutlinedButton.styleFrom(minimumSize: const Size(48, 48)),
                  onPressed: () => _speaker.speak('night', text, lang: lang),
                  icon: const Icon(Icons.volume_up),
                  label: Text(t.fcbListen),
                ),
              TextButton(
                style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
                onPressed: _openSettings,
                child: Text(t.fcbChange),
              ),
            ]),
          ],
        ),
      ),
    );
  }

  void _openSettings() {
    Navigator.of(context)
        .push(MaterialPageRoute(
            builder: (_) => FcBrainSettingsScreen(api: widget.api, familyId: widget.familyId)))
        .then((_) => widget.debugData == null ? _load() : null);
  }
}

/// "21:30" -> "রাত ৯:৩০" / "9:30 PM".
String fcClockLabel(String hhmm, String lang) => _clock(hhmm, lang);

String _clock(String hhmm, String lang) {
  final p = hhmm.split(':');
  final h = int.tryParse(p.first) ?? 21;
  final m = p.length > 1 ? (int.tryParse(p[1]) ?? 0) : 0;
  final h12 = h % 12 == 0 ? 12 : h % 12;
  final mm = m.toString().padLeft(2, '0');
  if (lang != 'bn') return '$h12:$mm ${h < 12 ? 'AM' : 'PM'}';
  const d = '০১২৩৪৫৬৭৮৯';
  String bn(String s) => s.replaceAllMapped(RegExp(r'[0-9]'), (x) => d[int.parse(x[0]!)]);
  final part = h < 4
      ? 'রাত'
      : h < 6
          ? 'ভোর'
          : h < 12
              ? 'সকাল'
              : h < 15
                  ? 'দুপুর'
                  : h < 18
                      ? 'বিকাল'
                      : h < 20
                          ? 'সন্ধ্যা'
                          : 'রাত';
  return '$part ${bn('$h12:$mm')}';
}
