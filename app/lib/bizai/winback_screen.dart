import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../api.dart';
import '../l10n/app_localizations.dart';
import '../screens/business/bizagent/seller_agent_screen.dart' show baErrorText, bd;
import '../state.dart';
import '../theme.dart';
import '../widgets/app_sheet.dart' show withNavBarInset;
import '../widgets/business_ui.dart';
import '../widgets/skeleton.dart';
import '../widgets/subs_common.dart' show fmtInt, taka;

/// bizai pillar 2 — server seam (backend/core/views_bizai.py Crm*View).
abstract class WinbackSource {
  Future<Map<String, dynamic>> segments();
  Future<Map<String, dynamic>> ladder();
  Future<Map<String, dynamic>> approve(Map<String, dynamic> body);
  Future<Map<String, dynamic>> aiDraft(String stage, String text, String lang);
}

class ApiWinbackSource implements WinbackSource {
  final ApiClient api;
  ApiWinbackSource(this.api);
  @override
  Future<Map<String, dynamic>> segments() => api.getJson('/bizai/crm/segments');
  @override
  Future<Map<String, dynamic>> ladder() => api.getJson('/bizai/crm/ladder');
  @override
  Future<Map<String, dynamic>> approve(Map<String, dynamic> body) =>
      api.postJson('/bizai/crm/ladder', body);
  @override
  Future<Map<String, dynamic>> aiDraft(String stage, String text, String lang) =>
      api.postJson('/bizai/crm/draft', {'stage': stage, 'text': text, 'lang': lang});
}

List<Map<String, dynamic>> _list(Object? v) =>
    [for (final x in (v as List? ?? const [])) (x as Map).cast<String, dynamic>()];

/// bizai — "Bring customers back": who your customers are (by last purchase,
/// value and favourite product) and the 30 / 60 / 90-day win-back ladder,
/// drafted for you; one tap switches it on. Sends go through the guarded
/// retention pipeline (STOP, quiet hours, daily caps, credits shown first).
class WinbackScreen extends StatefulWidget {
  final WinbackSource? source;
  const WinbackScreen({super.key, this.source});
  @override
  State<WinbackScreen> createState() => _WinbackScreenState();
}

class _WinbackScreenState extends State<WinbackScreen> {
  late final WinbackSource _src =
      widget.source ?? ApiWinbackSource(context.read<AppState>().api);
  Map<String, dynamic>? _seg;
  Map<String, dynamic>? _lad;
  final Map<String, String> _drafts = {};
  Object? _error;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _error = null);
    try {
      final r = await Future.wait([_src.segments(), _src.ladder()]);
      if (!mounted) return;
      setState(() {
        _seg = r[0];
        _lad = r[1];
        for (final s in _list(r[1]['stages'])) {
          _drafts['${s['stage']}'] = '${s['draft'] ?? ''}';
        }
      });
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  String _segLabel(AppLocalizations t, String k) => switch (k) {
        'champion' => t.bizaiSegChampion,
        'loyal' => t.bizaiSegLoyal,
        'new' => t.bizaiSegNew,
        'at_risk_30' => t.bizaiSegAtRisk30,
        'at_risk_60' => t.bizaiSegAtRisk60,
        'lost_90' => t.bizaiSegLost90,
        _ => t.bizaiSegOneTime,
      };

  String _stageLabel(AppLocalizations t, String st) => switch (st) {
        'wb30' => t.bizaiStage30,
        'wb60' => t.bizaiStage60,
        _ => t.bizaiStage90,
      };

  Future<void> _approve(bool on) async {
    final t = AppLocalizations.of(context);
    final bn = Localizations.localeOf(context).languageCode == 'bn';
    setState(() => _busy = true);
    try {
      final r = await _src.approve(on
          ? {
              'channel': 'in_app',
              'drafts': {
                for (final e in _drafts.entries) e.key: {bn ? 'bn' : 'en': e.value}
              },
            }
          : {'on': false});
      if (mounted) setState(() => _lad = r);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(on ? t.bizaiLadderOnDone : t.bizaiLadderOffDone)));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(baErrorText(t, e))));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _ai(String stage) async {
    final t = AppLocalizations.of(context);
    final lang = Localizations.localeOf(context).languageCode;
    setState(() => _busy = true);
    try {
      final r = await _src.aiDraft(stage, _drafts[stage] ?? '', lang);
      if (mounted && r['text'] is String) setState(() => _drafts[stage] = r['text'] as String);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(baErrorText(t, e))));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    return Scaffold(appBar: AppBar(title: Text(t.bizaiWinbackTitle)), body: _body(t));
  }

  Widget _body(AppLocalizations t) {
    if (_error != null) {
      return StateMessage(
        icon: Icons.cloud_off_rounded,
        title: t.bizLoadFailed,
        message: baErrorText(t, _error!),
        action: FilledButton(onPressed: _load, child: Text(t.bizRetry)),
      );
    }
    final seg = _seg, lad = _lad;
    if (seg == null || lad == null) return const SkeletonList();
    final stages = _list(lad['stages']);
    final allOn = stages.isNotEmpty && stages.every((s) => s['enabled'] == true);
    final total = (seg['total'] as num?)?.toInt() ?? 0;
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(padding: withNavBarInset(context, const EdgeInsets.all(Gap.lg)), children: [
        BizCard(
          title: t.bizaiSegmentsTitle,
          icon: Icons.groups_rounded,
          child: total == 0
              ? Text(t.bizaiSegmentsEmpty)
              : Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(t.bizaiSegmentsSub(fmtInt(context, total))),
                  const SizedBox(height: Gap.sm),
                  for (final s in _list(seg['segments']))
                    if (((s['count'] as num?) ?? 0) > 0)
                      ExpansionTile(
                        tilePadding: EdgeInsets.zero,
                        title: Text(_segLabel(t, '${s['key']}')),
                        trailing: Text(fmtInt(context, (s['count'] as num).toInt()),
                            style: const TextStyle(fontWeight: FontWeight.w700)),
                        children: [
                          for (final m in _list(s['members']))
                            ListTile(
                              contentPadding: EdgeInsets.zero,
                              title: Text('${m['name'] ?? ''}'),
                              subtitle: Text(t.bizaiMemberLine(
                                  fmtInt(context, (m['days'] as num?)?.toInt() ?? 0),
                                  taka(context, (m['spend_poisha'] as num?)?.toInt() ?? 0),
                                  bd(context, m['interest']))),
                              trailing: m['high_value'] == true
                                  ? Icon(Icons.star_rounded,
                                      semanticLabel: t.bizaiHighValue,
                                      color: AssistoTokens.of(context).warning)
                                  : null,
                            ),
                        ],
                      ),
                ]),
        ),
        const SizedBox(height: Gap.md),
        BizCard(
          title: t.bizaiLadderTitle,
          icon: Icons.replay_rounded,
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Text(t.bizaiLadderSub),
            const SizedBox(height: Gap.sm),
            for (final s in stages) ...[
              Text('${_stageLabel(t, '${s['stage']}')} · '
                  '${t.bizaiLadderAudience(fmtInt(context, (s['audience'] as num?)?.toInt() ?? 0))}',
                  style: const TextStyle(fontWeight: FontWeight.w700)),
              const SizedBox(height: Gap.xs),
              Text(bd(context, (_drafts['${s['stage']}'] ?? '')
                  .replaceAll('{name}', t.bizaiPhName)
                  .replaceAll('{shop}', t.bizaiPhShop)
                  .replaceAll('{days}', t.bizaiPhDays))),
              Align(
                alignment: AlignmentDirectional.centerStart,
                child: TextButton.icon(
                  onPressed: _busy || allOn ? null : () => _ai('${s['stage']}'),
                  icon: const Icon(Icons.auto_awesome_rounded),
                  label: Text(t.bizaiAiRewrite),
                ),
              ),
              const Divider(),
            ],
            BizNote(text: t.bizaiLadderSafety, icon: Icons.verified_user_rounded),
            const SizedBox(height: Gap.sm),
            FilledButton.icon(
              key: const ValueKey('bizai-ladder-approve'),
              style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
              onPressed: _busy ? null : () => _approve(!allOn),
              icon: Icon(allOn ? Icons.pause_circle_rounded : Icons.check_circle_rounded),
              label: Text(allOn ? t.bizaiLadderStop : t.bizaiLadderApprove),
            ),
          ]),
        ),
      ]),
    );
  }
}
