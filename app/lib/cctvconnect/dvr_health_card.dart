import 'package:flutter/material.dart';
import '../ds/ds.dart';
import 'package:provider/provider.dart';

import '../l10n/app_localizations.dart';
import '../screens/watchman/watchman_source.dart' show wmDigits, wmError, wmList;
import '../screens/watchman/watchman_widgets.dart' show wmLang, wmOk, wmWarn, wmBad, WmPill;
import '../state.dart';
import '../theme.dart';
import '../widgets/app_sheet.dart';
import 'cctv_connect_source.dart';

/// cctvconnect (CCTV Guard V3 part B) — the daily green check of a place's
/// DVR / cameras: recording on, disk healthy, every camera online, not
/// covered or moved, how many days are kept. Words + icon, never colour
/// alone. Hidden while nothing has reported yet (the Guard Box or a brand
/// cloud fills it); "not checked" is never shown as green.
class DvrHealthCard extends StatefulWidget {
  final int siteId;
  final bool owner;
  final CctvConnectSource? source;

  /// Gallery / tests: start with the problem lines open.
  final bool initiallyOpen;
  const DvrHealthCard(
      {super.key, required this.siteId, this.owner = true, this.source, this.initiallyOpen = false});

  @override
  State<DvrHealthCard> createState() => _DvrHealthCardState();
}

class _DvrHealthCardState extends State<DvrHealthCard> {
  CctvConnectSource? _src;
  Map<String, dynamic>? _d;
  late bool _open = widget.initiallyOpen;

  @override
  void initState() {
    super.initState();
    _src = widget.source;
    if (_src == null) {
      try {
        _src = ApiCctvConnectSource(context.read<AppState>().api);
      } catch (_) {
        return; // no app state (a test without one): stay hidden
      }
    }
    _load();
  }

  Future<void> _load() async {
    try {
      final d = await _src!.health(widget.siteId);
      if (mounted) setState(() => _d = d);
    } catch (_) {
      // hidden: the rest of the CCTV screen never depends on this card
    }
  }

  Future<void> _target() async {
    final t = AppLocalizations.of(context);
    final lang = wmLang(context);
    final cur = (_d?['target_days'] as num?)?.toInt() ?? 7;
    final pick = await showAppSheet<int>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          padding: withNavBarInset(ctx, const EdgeInsets.only(bottom: Gap.md)),
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(Gap.lg, 0, Gap.lg, Gap.sm),
              child: Text(t.ccnHealthTarget, style: Theme.of(ctx).textTheme.titleMedium),
            ),
            for (final d in const [7, 15, 30, 60])
              ListTile(
                key: ValueKey('ccnDays-$d'),
                minVerticalPadding: Gap.md,
                leading: Icon(d == cur ? Icons.radio_button_checked : Icons.radio_button_off),
                title: Text(t.ccnHealthDaysOpt(wmDigits(lang, d))),
                onTap: () => Navigator.of(ctx).pop(d),
              ),
          ],
        ),
      ),
    );
    if (pick == null || pick == cur || !mounted) return;
    final msg = ScaffoldMessenger.of(context);
    try {
      final d = await _src!.setTargetDays(widget.siteId, pick);
      if (mounted) setState(() => _d = d);
      msg.showSnackBar(SnackBar(content: Text(t.ccnHealthTargetSaved)));
    } catch (e) {
      msg.showSnackBar(SnackBar(content: Text(wmError(e) ?? t.ccnLoadError)));
    }
  }

  @override
  Widget build(BuildContext context) {
    final d = _d;
    if (d == null || wmList(d['devices']).isEmpty) return const SizedBox.shrink();
    final t = AppLocalizations.of(context);
    final lang = wmLang(context);
    final th = Theme.of(context).textTheme;
    final status = (d['status'] ?? 'unknown').toString();
    final lines = wmList(d['lines']);
    final (Color color, IconData icon, String word) = switch (status) {
      'green' => (wmOk(), Icons.verified_rounded, t.ccnHealthGreen),
      'red' => (wmBad(), Icons.report_rounded, t.ccnHealthRed),
      'amber' => (wmWarn(), Icons.warning_amber_rounded, t.ccnHealthAmber),
      _ => (wmWarn(), Icons.help_outline_rounded, t.ccnHealthUnknown),
    };
    final days = (d['recorded_days'] as num?)?.toInt();
    final target = (d['target_days'] as num?)?.toInt() ?? 7;
    return Padding(key: const Key('dvrHealthCard'), padding: const EdgeInsets.fromLTRB(0, Gap.sm, 0, Gap.xs), child: DsCard(
        padding: const EdgeInsets.all(Gap.md),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          InkWell(
            onTap: lines.isEmpty ? null : () => setState(() => _open = !_open),
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 48),
              child: Row(children: [
                Icon(icon, color: color, semanticLabel: word),
                const SizedBox(width: Gap.sm),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(t.ccnHealthTitle, style: AType.bodyMedium.copyWith(fontWeight: FontWeight.w700)),
                    const SizedBox(height: 2),
                    Text((d['title'] ?? '').toString(), key: const Key('dvrHealthTitle')),
                  ]),
                ),
                if (lines.isNotEmpty)
                  Icon(_open ? Icons.expand_less_rounded : Icons.expand_more_rounded),
              ]),
            ),
          ),
          const SizedBox(height: Gap.xs),
          Wrap(spacing: Gap.sm, runSpacing: Gap.xs, children: [
            WmPill(label: word, icon: icon, color: color),
            WmPill(
              label: days == null
                  ? t.ccnHealthUnknownDays
                  : t.ccnHealthDays(wmDigits(lang, days), wmDigits(lang, target)),
              icon: Icons.history_rounded,
              color: days != null && days < target ? wmWarn() : wmOk(),
            ),
          ]),
          if (_open)
            for (final l in lines)
              Padding(
                padding: const EdgeInsets.only(top: Gap.sm),
                child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Icon(l['sev'] == 'red' ? Icons.error_rounded : Icons.info_rounded,
                      size: 20, color: l['sev'] == 'red' ? wmBad() : wmWarn()),
                  const SizedBox(width: Gap.sm),
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text((l['what'] ?? '').toString(), style: th.bodyMedium),
                      Text('${t.ccnHealthFix}: ${l['fix'] ?? ''}', style: th.bodySmall),
                    ]),
                  ),
                ]),
              ),
          if (widget.owner)
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                key: const Key('dvrHealthTarget'),
                style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
                onPressed: _target,
                icon: const Icon(Icons.tune_rounded),
                label: Text(t.ccnHealthTarget),
              ),
            ),
        ]),
      ));
  }
}
