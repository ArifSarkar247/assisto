import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../api.dart';
import '../l10n/app_localizations.dart';
import '../screens/business/business_plans_screen.dart' show BusinessPlansScreen; // bizai2
import '../plans_v2/buy_inside.dart';
import '../screens/business/bizagent/seller_agent_screen.dart' show baErrorText, bd;
import '../state.dart';
import '../theme.dart';
import '../ds/ds.dart';
import '../widgets/app_sheet.dart' show showAppSheet, withNavBarInset;
import '../widgets/local_counter.dart'; // gap-bizai
import '../screens/crm/customer_list_screen.dart' show CustomerListScreen; // gap-bizai
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

  Future<bool> _approve(bool on) async {
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
      return true;
    } catch (e) {
      // buyinside: out of AI credits -> the credits sheet right here (the
      // drafts stay as typed)
      if (mounted && await BuyInside.handle(context, e, 'bizai_winback')) return false;
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(baErrorText(t, e))));
      }
      return false;
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// gap-bizai: the owner can write the message in their own words. The
  /// placeholders show as "(customer's name)" / "(your shop)" / "(days)" in
  /// the box and go back to {name} / {shop} / {days} on save.
  Future<void> _editDraft(String stage) async {
    final t = AppLocalizations.of(context);
    String toUi(String x) => x
        .replaceAll('{name}', t.bizaiPhName)
        .replaceAll('{shop}', t.bizaiPhShop)
        .replaceAll('{days}', t.bizaiPhDays);
    String fromUi(String x) => x
        .replaceAll(t.bizaiPhName, '{name}')
        .replaceAll(t.bizaiPhShop, '{shop}')
        .replaceAll(t.bizaiPhDays, '{days}');
    final c = TextEditingController(text: toUi(_drafts[stage] ?? ''));
    final saved = await showAppSheet<String>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (ctx) => Padding(
        padding: EdgeInsets.fromLTRB(
            Gap.lg, 0, Gap.lg, Gap.lg + MediaQuery.of(ctx).viewInsets.bottom),
        child: SingleChildScrollView(
          child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(t.gbzWbEditTitle, style: AType.titleMedium),
                const SizedBox(height: Gap.xs),
                Text(t.gbzWbEditHint(t.bizaiPhName, t.bizaiPhShop), style: AType.bodySmall),
                const SizedBox(height: Gap.md),
                TextField(
                  key: const ValueKey('gbz-wb-edit-field'),
                  controller: c,
                  minLines: 3,
                  maxLines: 8,
                  maxLength: 400,
                  buildCounter: localCounter,
                  decoration: const InputDecoration(border: OutlineInputBorder()),
                ),
                const SizedBox(height: Gap.sm),
                FilledButton(
                  key: const ValueKey('gbz-wb-edit-save'),
                  style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(48)),
                  onPressed: () => Navigator.of(ctx).pop(c.text),
                  child: Text(t.gbzWbSave),
                ),
              ]),
        ),
      ),
    );
    // (the controller is left to the GC: disposing it here races the
    // sheet's closing animation)
    if (saved == null || !mounted) return;
    final txt = fromUi(saved.trim());
    if (txt.isEmpty || txt == _drafts[stage]) return;
    final before = _drafts[stage];
    setState(() => _drafts[stage] = txt);
    // A ladder that is already running saves the new words at once (the
    // server checks them); otherwise they are kept for "Approve".
    final stages = _list(_lad?['stages']);
    final allOn = stages.isNotEmpty && stages.every((s) => s['enabled'] == true);
    if (allOn) {
      final ok = await _approve(true);
      if (!ok && mounted) setState(() => _drafts[stage] = before ?? '');
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
        // Who can be won back = the soft DS hero (the big number first).
        DsHeroCard(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              DsAvatar(
                  child: Icon(Icons.groups_rounded,
                      size: 22, color: DsTokens.of(context).primaryInk)),
              const SizedBox(width: Gap.md),
              Expanded(
                child: Semantics(
                  header: true,
                  child: Text(t.bizaiSegmentsTitle,
                      style: AType.titleMedium.copyWith(
                          color: DsTokens.of(context).text, fontWeight: FontWeight.w700)),
                ),
              ),
            ]),
            const SizedBox(height: Gap.md),
            if (total == 0)
              Text(t.bizaiSegmentsEmpty,
                  style: AType.bodyMedium.copyWith(color: DsTokens.of(context).muted))
            else
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  DsNumber(fmtInt(context, total)),
                  Text(t.bizaiSegmentsSub(fmtInt(context, total)),
                      style: AType.bodyMedium.copyWith(color: DsTokens.of(context).muted)),
                  const SizedBox(height: Gap.sm),
                  for (final s in _list(seg['segments']))
                    if (((s['count'] as num?) ?? 0) > 0)
                      ExpansionTile(
                        tilePadding: EdgeInsets.zero,
                        title: Text(_segLabel(t, '${s['key']}')),
                        trailing: Text(fmtInt(context, (s['count'] as num).toInt()),
                            style: AType.bodyMedium.copyWith(fontWeight: FontWeight.w700)),
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
                  style: AType.bodyMedium.copyWith(fontWeight: FontWeight.w700)),
              const SizedBox(height: Gap.xs),
              // the message itself, as a soft quote
              DsSurface(
                flat: true,
                color: DsTokens.of(context).cardAlt,
                borderColor: DsTokens.of(context).border,
                padding: const EdgeInsets.all(Gap.md),
                child: Text(bd(context, (_drafts['${s['stage']}'] ?? '')
                    .replaceAll('{name}', t.bizaiPhName)
                    .replaceAll('{shop}', t.bizaiPhShop)
                    .replaceAll('{days}', t.bizaiPhDays)),
                    style: AType.bodyMedium.copyWith(color: DsTokens.of(context).text)),
              ),
              // gap-bizai: the in-app path reaches only Assisto users — say
              // how many, and where to message the rest yourself.
              if (s['on_assisto'] is num &&
                  ((s['audience'] as num?) ?? 0) > ((s['on_assisto'] as num?) ?? 0)) ...[
                const SizedBox(height: Gap.xs),
                Text(
                    t.gbzWbReach(fmtInt(context, (s['on_assisto'] as num).toInt()),
                        fmtInt(context, (s['audience'] as num).toInt())),
                    key: ValueKey('gbz-wb-reach-${s['stage']}'),
                    style: AType.bodySmall.copyWith(color: DsTokens.of(context).muted)),
              ],
              Wrap(spacing: Gap.xs, children: [
                TextButton.icon(
                  key: ValueKey('gbz-wb-edit-${s['stage']}'),
                  style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
                  onPressed: _busy || lad['plan_ok'] == false
                      ? null
                      : () => _editDraft('${s['stage']}'),
                  icon: const Icon(Icons.edit_outlined),
                  label: Text(t.gbzWbEdit),
                ),
                TextButton.icon(
                  style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
                  onPressed: _busy || allOn || lad['plan_ok'] == false
                      ? null
                      : () => _ai('${s['stage']}'),
                  icon: const Icon(Icons.auto_awesome_rounded),
                  label: Text(t.bizaiAiRewrite),
                ),
              ]),
              const Divider(),
            ],
            BizNote(text: t.bizaiLadderSafety, icon: Icons.verified_user_rounded),
            const SizedBox(height: Gap.sm),
            // gap-bizai: customers not on Assisto — message them yourself
            // (own WhatsApp / SMS, one card each; STOP is respected there too)
            if (stages.any((s) =>
                s['on_assisto'] is num &&
                ((s['audience'] as num?) ?? 0) > ((s['on_assisto'] as num?) ?? 0))) ...[
              OutlinedButton.icon(
                key: const ValueKey('gbz-wb-others'),
                style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(48)),
                onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => const CustomerListScreen())),
                icon: const Icon(Icons.chat_rounded),
                label: Text(t.gbzWbMessageOthers),
              ),
              const SizedBox(height: Gap.sm),
            ],
            // bizai2: reading is free; switching on needs Business — say so
            // and open the plans instead of a button that only fails (402).
            if (lad['plan_ok'] == false) ...[
              BizNote(text: '${lad['plan_note'] ?? ''}', icon: Icons.workspace_premium_rounded),
              const SizedBox(height: Gap.sm),
              DsButton(
                buttonKey: const ValueKey('bizai2-ladder-plans'),
                expand: true,
                onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => const BusinessPlansScreen())),
                icon: Icons.workspace_premium_rounded,
                label: t.bizai2SeeBusinessPlan,
              ),
            ] else
              DsButton(
                buttonKey: const ValueKey('bizai-ladder-approve'),
                expand: true,
                busy: _busy,
                onPressed: _busy ? null : () => _approve(!allOn),
                icon: allOn ? Icons.pause_circle_rounded : Icons.check_circle_rounded,
                label: allOn ? t.bizaiLadderStop : t.bizaiLadderApprove,
              ),
          ]),
        ),
      ]),
    );
  }
}
