import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../state.dart';
import '../theme.dart';

/// Agent Studio (feature 32): AI-generated original documents — letter, CV,
/// caption, Excel formula, email. Clean needs-key state when no AI key.
class AgentStudioScreen extends StatefulWidget {
  const AgentStudioScreen({super.key});
  @override
  State<AgentStudioScreen> createState() => _AgentStudioScreenState();
}

class _AgentStudioScreenState extends State<AgentStudioScreen> {
  final _prompt = TextEditingController();
  String _kind = 'letter';
  String? _result;
  bool _needsKey = false, _busy = false;

  @override
  void dispose() {
    _prompt.dispose();
    super.dispose();
  }

  Future<void> _go(String Function(String, String) t) async {
    if (_prompt.text.trim().isEmpty) return;
    setState(() {
      _busy = true;
      _result = null;
      _needsKey = false;
    });
    try {
      final r = await context.read<AppState>().api.studio(_kind, _prompt.text.trim());
      if (r['needs_key'] == true) {
        _needsKey = true;
      } else {
        _result = r['text']?.toString();
      }
    } catch (_) {}
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    final en = context.watch<AppState>().locale?.languageCode == 'en';
    String t(String bn, String e) => en ? e : bn;
    final kinds = {
      'letter': t('চিঠি', 'Letter'), 'cv': 'CV', 'caption': t('ক্যাপশন', 'Caption'),
      'excel': 'Excel', 'email': 'Email',
    };
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: Text(t('এজেন্ট স্টুডিও', 'Agent Studio'))),
      body: ListView(padding: const EdgeInsets.all(Gap.lg), children: [
        Wrap(spacing: Gap.sm, children: [
          for (final e in kinds.entries)
            ChoiceChip(
              label: Text(e.value),
              selected: _kind == e.key,
              onSelected: (_) => setState(() => _kind = e.key),
            ),
        ]),
        const SizedBox(height: Gap.md),
        TextField(
          controller: _prompt,
          maxLines: 4,
          decoration: InputDecoration(
            labelText: t('কী লিখব? বিস্তারিত বলুন', 'What should I write? Describe it'),
            alignLabelWithHint: true,
          ),
        ),
        const SizedBox(height: Gap.md),
        FilledButton.icon(
          onPressed: _busy ? null : () => _go(t),
          icon: _busy
              ? const SizedBox(height: 18, width: 18, child: CircularProgressIndicator(strokeWidth: 2))
              : const Icon(Icons.auto_awesome),
          label: Text(t('তৈরি করুন', 'Generate')),
        ),
        if (_needsKey) ...[
          const SizedBox(height: Gap.lg),
          Card(
            color: scheme.tertiaryContainer,
            child: Padding(
              padding: const EdgeInsets.all(Gap.lg),
              child: Text(
                t('চালু হবে যখন AI key যোগ হবে (Integrations)।',
                    'Available when an AI key is added (Integrations).'),
                style: TextStyle(color: scheme.onTertiaryContainer),
              ),
            ),
          ),
        ],
        if (_result != null) ...[
          const SizedBox(height: Gap.lg),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(Gap.lg),
              child: Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
                SelectableText(_result!),
                const SizedBox(height: Gap.sm),
                TextButton.icon(
                  onPressed: () {
                    Clipboard.setData(ClipboardData(text: _result!));
                    ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(content: Text(t('কপি হয়েছে', 'Copied'))));
                  },
                  icon: const Icon(Icons.copy, size: 16),
                  label: Text(t('কপি', 'Copy')),
                ),
              ]),
            ),
          ),
        ],
      ]),
    );
  }
}
