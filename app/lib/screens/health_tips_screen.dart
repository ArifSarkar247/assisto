import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../state.dart';
import '../theme.dart';
import '../ds/ds.dart';
import '../l10n/app_localizations.dart';
import '../widgets/health_api.dart';
import '../widgets/htips_tip_card.dart';
import '../widgets/htips_seasonal.dart';
import '../widgets/htips_store.dart';
import '../services/action_feedback.dart'; // db1
import '../services/error_kind.dart' show honestFailText; // qa2

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
  Object? _failCause; // qa2: why it failed (5xx = our server, not the internet)

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
    } catch (e) {
      if (mounted) setState(() {
        _error = true;
        _failCause = e;
      });
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

    // "saved-only" is a client-side filter over whatever the backend returned.
    final visibleTips = _savedOnly
        ? _tips.where((tip) => _savedIds.contains((tip['id'] ?? '').toString())).toList()
        : _tips;

    return Scaffold(
      appBar: AppBar(title: Text(t.healthTipsTitle)),
      // admob: Free users only, allowlisted page, takes no space without a fill
      body: RefreshIndicator(
        onRefresh: _load,
        child: ListView(padding: const EdgeInsets.all(Gap.lg), children: [
          // non-diagnostic disclaimer — always visible
          if (_disclaimer.isNotEmpty)
            DsCard(
              tone: DsTone.success,
              padding: const EdgeInsets.all(Gap.md),
              child: Row(children: [
                  Icon(Icons.info_outline_rounded, size: 18, color: DsTokens.of(context).successInk),
                  const SizedBox(width: Gap.sm),
                  Expanded(
                    child: Text(_disclaimer,
                        style: AType.bodySmall.copyWith(color: DsTokens.of(context).successInk)),
                  ),
                ]),
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
              prefixIcon: const Icon(Icons.search_rounded),
            ),
            onSubmitted: (_) => _load(),
            textInputAction: TextInputAction.search,
          ),
          const SizedBox(height: Gap.md),

          // topic chips + "saved" filter
          // designv2: one scrolling row (chips never break into odd rows)
          DsChipRow(padding: EdgeInsets.zero, children: [
            DsChip(
              label: t.healthTipsAllTopics,
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
                DsChip(
                  label: _topicLabel(top),
                  selected: _activeTopic == top['id'],
                  onSelected: (_) {
                    setState(() => _activeTopic = top['id'].toString());
                    _load();
                  },
                ),
            DsChip(
              icon: _savedOnly ? Icons.bookmark_rounded : Icons.bookmark_border_rounded,
              label: t.htipsSavedFilter,
              selected: _savedOnly,
              onSelected: (v) => setState(() => _savedOnly = v),
            ),
          ]),
          const SizedBox(height: Gap.lg),

          if (_loading)
            Column(children: [
              for (var i = 0; i < 3; i++)
                Padding(padding: const EdgeInsets.only(bottom: Gap.md), child: DsSkeleton.card(lines: 3)),
            ])
          else if (_error)
            _ErrorRetry(message: honestFailText(t, _failCause, otherwise: t.healthTipsLoadError), onRetry: _load)
          else if (visibleTips.isEmpty)
            Padding(
              padding: const EdgeInsets.all(Gap.xl),
              child: Center(child: Text(
                  _savedOnly ? t.htipsNoSaved : t.healthTipsNoResults,
                  textAlign: TextAlign.center,
                  style: AType.bodyMedium.copyWith(color: DsTokens.of(context).muted))),
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
                style: AType.labelSmall.copyWith(color: DsTokens.of(context).muted)),
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
    final ds = DsTokens.of(context);
    return DsCard(
        padding: const EdgeInsets.all(Gap.md),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Icon(Icons.emergency_rounded, color: ds.dangerInk, size: 20),
            const SizedBox(width: Gap.sm),
            Expanded(child: Text(label,
                style: AType.titleSmall.copyWith(fontWeight: FontWeight.w700, color: ds.text))),
          ]),
          const SizedBox(height: Gap.sm),
          TextField(
            controller: controller,
            minLines: 1,
            maxLines: 3,
            decoration: InputDecoration(hintText: hint),
          ),
          const SizedBox(height: Gap.sm),
          DsButton.secondary(
            expand: true,
            busy: checking,
            onPressed: onCheck,
            icon: Icons.health_and_safety_rounded,
            label: button,
          ),
          if (action != null && action!.isNotEmpty) ...[
            const SizedBox(height: Gap.sm),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(Gap.md),
              decoration: BoxDecoration(
                color: ds.dangerFill,
                borderRadius: BorderRadius.circular(DsRadius.card),
              ),
              child: Row(children: [
                Icon(Icons.warning_amber_rounded, color: ds.onDangerFill),
                const SizedBox(width: Gap.sm),
                Expanded(child: Text(action!,
                    style: AType.bodyMedium.copyWith(color: ds.onDangerFill, fontWeight: FontWeight.w700))),
              ]),
            ),
          ] else if (action != null && action!.isEmpty) ...[
            const SizedBox(height: Gap.sm),
            Row(children: [
              Icon(Icons.check_circle_outline_rounded, size: 16, color: ds.successInk),
              const SizedBox(width: Gap.xs),
              Expanded(child: Text(safeText,
                  style: AType.bodySmall.copyWith(color: DsTokens.of(context).muted))),
            ]),
          ],
        ]),
    );
  }
}

class _ErrorRetry extends StatelessWidget {
  final String message;
  final VoidCallback onRetry;
  const _ErrorRetry({required this.message, required this.onRetry});
  @override
  Widget build(BuildContext context) {
    return DsEmptyState(
      icon: Icons.cloud_off_rounded,
      title: message,
      actionLabel: AppLocalizations.of(context).retry,
      onAction: onRetry,
    );
  }
}
