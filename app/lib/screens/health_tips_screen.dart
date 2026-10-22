import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../state.dart';
import '../theme.dart';
import '../l10n/app_localizations.dart';
import '../widgets/health_api.dart';
import '../widgets/htips_tip_card.dart';
import '../widgets/htips_seasonal.dart';
import '../widgets/htips_store.dart';
import '../services/action_feedback.dart'; // db1

/// ADVANCED Health-tips library — trusted public-health guidance
/// (DGHS / WHO / IEDCR), grouped by topic, every tip SOURCE-NAMED and dated.
/// Over the GOOD version it adds: BD-specific SEASONAL highlights (dengue /
/// heat / winter / flood), per-tip SAVE (bookmark) + a "saved-only" filter,
/// SHARE (safety notice travels with the text), and a symptom-AWARENESS block
/// per tip ("when to see a doctor"). We NEVER diagnose: an optional red-flag
/// box scans free text and, on an emergency term, surfaces the fixed
/// "call 999 / see a doctor" action — never a diagnosis. The non-diagnostic
/// "not medical advice" notice + 999 call-to-action are always present.
class HealthTipsScreen extends StatefulWidget {
  const HealthTipsScreen({super.key});
  @override
  State<HealthTipsScreen> createState() => _HealthTipsScreenState();
}

class _HealthTipsScreenState extends State<HealthTipsScreen> {
  final _search = TextEditingController();
  final _emergencyText = TextEditingController();

  List<Map<String, dynamic>> _topics = [];
  List<Map<String, dynamic>> _tips = [];
  List<Map<String, dynamic>> _seasonal = [];
  String _disclaimer = '';
  List<String> _sources = [];
  String? _activeTopic;

  Set<String> _savedIds = {};
  bool _savedOnly = false;

  bool _loading = true;
  bool _error = false;

  String? _emergencyAction;
  bool _emergencyChecking = false;

  @override
  void initState() {
    super.initState();
    _loadSaved();
    _load();
  }

  @override
  void dispose() {
    _search.dispose();
    _emergencyText.dispose();
    super.dispose();
  }

  Future<void> _loadSaved() async {
    final ids = await HtipsStore.savedIds();
    if (mounted) setState(() => _savedIds = ids);
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = false;
    });
    try {
      final r = await context.read<AppState>().api.healthTips(
          topic: _activeTopic, query: _search.text);
      if (!mounted) return;
      setState(() {
        _topics = ((r['topics'] ?? []) as List).cast<Map<String, dynamic>>();
        _tips = ((r['tips'] ?? []) as List).cast<Map<String, dynamic>>();
        _seasonal = ((r['seasonal'] ?? []) as List).cast<Map<String, dynamic>>();
        _disclaimer = (r['disclaimer'] ?? '').toString();
        _sources = ((r['sources'] ?? []) as List).map((e) => e.toString()).toList();
      });
    } catch (_) {
      if (mounted) setState(() => _error = true);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _toggleSave(String id) async {
    final nowSaved = await HtipsStore.toggle(id);
    if (!mounted) return;
    setState(() {
      if (nowSaved) {
        _savedIds.add(id);
      } else {
        _savedIds.remove(id);
      }
    });
  }

  /// Human-readable label for a topic chip. The backend sends `name`; some
  /// payloads use `label`. Returns '' for null/blank so the caller can skip the
  /// chip entirely (never render a literal "null").
  String _topicLabel(Map<String, dynamic> top) {
    final raw = top['name'] ?? top['label'];
    if (raw == null) return '';
    final s = raw.toString().trim();
    return s == 'null' ? '' : s;
  }

  void _openTopic(String topicId) {
    setState(() {
      _activeTopic = topicId;
      _savedOnly = false;
    });
    _load();
  }

  Future<void> _checkEmergency() async {
    final text = _emergencyText.text.trim();
    if (text.isEmpty) {
      showNeedInput(context); // db1: was a dead tap
      return;
    }
    FocusScope.of(context).unfocus();
    setState(() {
      _emergencyChecking = true;
      _emergencyAction = null;
    });
    try {
      final r = await context.read<AppState>().api.healthEmergencyCheck(text);
      if (!mounted) return;
      final isEmergency = r['emergency'] == true;
      setState(() => _emergencyAction =
          isEmergency ? (r['action'] ?? '').toString() : '');
    } catch (_) {
      if (mounted) setState(() => _emergencyAction = null);
    } finally {
      if (mounted) setState(() => _emergencyChecking = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;

    // "saved-only" is a client-side filter over whatever the backend returned.
    final visibleTips = _savedOnly
        ? _tips.where((tip) => _savedIds.contains((tip['id'] ?? '').toString())).toList()
        : _tips;

    return Scaffold(
      appBar: AppBar(title: Text(t.healthTipsTitle)),
      body: RefreshIndicator(
        onRefresh: _load,
        child: ListView(padding: const EdgeInsets.all(Gap.lg), children: [
          // non-diagnostic disclaimer — always visible
          if (_disclaimer.isNotEmpty)
            Card(
              color: scheme.tertiaryContainer,
              child: Padding(
                padding: const EdgeInsets.all(Gap.md),
                child: Row(children: [
                  Icon(Icons.info_outline, size: 18, color: scheme.onTertiaryContainer),
                  const SizedBox(width: Gap.sm),
                  Expanded(
                    child: Text(_disclaimer,
                        style: TextStyle(fontSize: 12, color: scheme.onTertiaryContainer)),
                  ),
                ]),
              ),
            ),
          const SizedBox(height: Gap.md),

          // red-flag / emergency check (NOT a diagnosis)
          _EmergencyCheckBox(
            controller: _emergencyText,
            checking: _emergencyChecking,
            action: _emergencyAction,
            onCheck: _checkEmergency,
            label: t.healthEmergencyCheckLabel,
            hint: t.healthEmergencyCheckHint,
            button: t.healthEmergencyCheckButton,
            safeText: t.healthEmergencyNoRedFlags,
          ),
          const SizedBox(height: Gap.lg),

          // seasonal highlights (dengue / heat / winter / flood) — current month
          if (_seasonal.isNotEmpty) ...[
            HtipsSeasonal(highlights: _seasonal, onOpenTopic: _openTopic),
            const SizedBox(height: Gap.lg),
          ],

          // search
          TextField(
            controller: _search,
            decoration: InputDecoration(
              hintText: t.healthTipsSearchHint,
              prefixIcon: const Icon(Icons.search),
            ),
            onSubmitted: (_) => _load(),
            textInputAction: TextInputAction.search,
          ),
          const SizedBox(height: Gap.md),

          // topic chips + "saved" filter
          Wrap(spacing: Gap.sm, runSpacing: Gap.xs, children: [
            ChoiceChip(
              label: Text(t.healthTipsAllTopics),
              selected: _activeTopic == null,
              onSelected: (_) {
                setState(() => _activeTopic = null);
                _load();
              },
            ),
            for (final top in _topics)
              // The backend sends each topic as {id, name}. Read `name` (fall
              // back to `label`), and only build a chip when the label is a
              // real non-empty string — otherwise a null/blank field would
              // render the literal text "null" on a health screen.
              if (_topicLabel(top).isNotEmpty)
                ChoiceChip(
                  label: Text(_topicLabel(top)),
                  selected: _activeTopic == top['id'],
                  onSelected: (_) {
                    setState(() => _activeTopic = top['id'].toString());
                    _load();
                  },
                ),
            FilterChip(
              avatar: Icon(
                _savedOnly ? Icons.bookmark : Icons.bookmark_border,
                size: 16,
              ),
              label: Text(t.htipsSavedFilter),
              selected: _savedOnly,
              onSelected: (v) => setState(() => _savedOnly = v),
            ),
          ]),
          const SizedBox(height: Gap.lg),

          if (_loading)
            const Center(child: Padding(
                padding: EdgeInsets.all(Gap.xl), child: CircularProgressIndicator()))
          else if (_error)
            _ErrorRetry(message: t.healthTipsLoadError, onRetry: _load)
          else if (visibleTips.isEmpty)
            Padding(
              padding: const EdgeInsets.all(Gap.xl),
              child: Center(child: Text(
                  _savedOnly ? t.htipsNoSaved : t.healthTipsNoResults,
                  textAlign: TextAlign.center,
                  style: TextStyle(color: scheme.onSurfaceVariant))),
            )
          else
            for (final tip in visibleTips) ...[
              HtipsTipCard(
                tip: tip,
                saved: _savedIds.contains((tip['id'] ?? '').toString()),
                onToggleSave: () => _toggleSave((tip['id'] ?? '').toString()),
              ),
              const SizedBox(height: Gap.md),
            ],

          if (_sources.isNotEmpty) ...[
            const SizedBox(height: Gap.sm),
            Text(t.healthTipsSourcesLine(_sources.join(', ')),
                style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant)),
          ],
        ]),
      ),
    );
  }
}

/// A free-text box that flags emergency red-flags. Shows a loud red banner with
/// the fixed "call 999 / see a doctor" action — never a diagnosis.
class _EmergencyCheckBox extends StatelessWidget {
  final TextEditingController controller;
  final bool checking;
  final String? action; // null=not run, ''=safe, non-empty=emergency
  final VoidCallback onCheck;
  final String label, hint, button, safeText;
  const _EmergencyCheckBox({
    required this.controller,
    required this.checking,
    required this.action,
    required this.onCheck,
    required this.label,
    required this.hint,
    required this.button,
    required this.safeText,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(Gap.md),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            const Icon(Icons.emergency_outlined, color: Brand.danger, size: 20),
            const SizedBox(width: Gap.sm),
            Expanded(child: Text(label,
                style: const TextStyle(fontWeight: FontWeight.w700))),
          ]),
          const SizedBox(height: Gap.sm),
          TextField(
            controller: controller,
            minLines: 1,
            maxLines: 3,
            decoration: InputDecoration(hintText: hint),
          ),
          const SizedBox(height: Gap.sm),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: checking ? null : onCheck,
              icon: checking
                  ? const SizedBox(
                      width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.health_and_safety_outlined, size: 18),
              label: Text(button),
            ),
          ),
          if (action != null && action!.isNotEmpty) ...[
            const SizedBox(height: Gap.sm),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(Gap.md),
              decoration: BoxDecoration(
                color: Brand.danger,
                borderRadius: BorderRadius.circular(Radii.md),
              ),
              child: Row(children: [
                const Icon(Icons.warning_amber_rounded, color: Colors.white),
                const SizedBox(width: Gap.sm),
                Expanded(child: Text(action!,
                    style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700))),
              ]),
            ),
          ] else if (action != null && action!.isEmpty) ...[
            const SizedBox(height: Gap.sm),
            Row(children: [
              Icon(Icons.check_circle_outline, size: 16, color: scheme.secondary),
              const SizedBox(width: Gap.xs),
              Expanded(child: Text(safeText,
                  style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant))),
            ]),
          ],
        ]),
      ),
    );
  }
}

class _ErrorRetry extends StatelessWidget {
  final String message;
  final VoidCallback onRetry;
  const _ErrorRetry({required this.message, required this.onRetry});
  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(Gap.xl),
      child: Column(children: [
        Text(message, textAlign: TextAlign.center),
        const SizedBox(height: Gap.md),
        OutlinedButton.icon(
          onPressed: onRetry,
          icon: const Icon(Icons.refresh),
          label: Text(AppLocalizations.of(context).retry),
        ),
      ]),
    );
  }
}
