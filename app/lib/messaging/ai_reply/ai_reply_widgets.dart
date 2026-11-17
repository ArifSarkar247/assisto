/// ai-reply-core: the My Circle AI reply UI (Design System V2, bn/en,
/// light/dark, 200% font, 48 dp targets). All copy via AppLocalizations.
///
///  * showAiReplySheet  — chat ⋮ → AI reply: 4 modes (group: off/suggest),
///    the Busy timer, the tag switch, style consent, credits + ad unlock.
///  * AiSuggestionStrip — 2–3 reply chips above the composer (one tap sends)
///    or the "needs you" note for a held topic.
///  * AiReplyTag        — the small "Assisto AI reply" tag under a bubble.
///  * AiModeStrip       — "AI is replying for you" line while Busy/Full auto.
library;

import 'package:flutter/material.dart';

import '../../ds/ds.dart';
import '../../l10n/app_localizations.dart';
import '../../widgets/rewarded_ad_sheet.dart';
import 'ai_reply.dart';

bool _bn(BuildContext c) => Localizations.localeOf(c).languageCode == 'bn';

/// ASCII digits -> Bangla digits on a Bangla screen (code points only).
String aiDigits(Object? v, bool bn) {
  final s = '${v ?? ''}';
  if (!bn) return s;
  return String.fromCharCodes(
      s.codeUnits.map((c) => (c >= 0x30 && c <= 0x39) ? 0x09E6 + (c - 0x30) : c));
}

/// The Busy end time: the platform's own clock format, Bangla digits in bn.
String aiClock(BuildContext context, DateTime t) {
  final s = MaterialLocalizations.of(context).formatTimeOfDay(TimeOfDay.fromDateTime(t));
  return aiDigits(s, _bn(context));
}

/// Opens the AI reply sheet; returns the new state (null = unchanged).
Future<AiReplyState?> showAiReplySheet(
  BuildContext context, {
  required AiReplyApi api,
  required int chatId,
  required bool group,
  required String name,
  AiReplyState? initial,
}) =>
    showAppSheet<AiReplyState>(
      context: context,
      isScrollControlled: true,
      builder: (_) => AiReplySheet(
          api: api, chatId: chatId, group: group, name: name, initial: initial),
    );

class AiReplySheet extends StatefulWidget {
  const AiReplySheet({
    super.key,
    required this.api,
    required this.chatId,
    required this.group,
    required this.name,
    this.initial,
  });
  final AiReplyApi api;
  final int chatId;
  final bool group;
  final String name;
  final AiReplyState? initial;

  @override
  State<AiReplySheet> createState() => _AiReplySheetState();
}

class _AiReplySheetState extends State<AiReplySheet> {
  AiReplyState? _s;
  bool _busy = false;
  bool _failed = false;
  int _busyMinutes = 60;

  @override
  void initState() {
    super.initState();
    _s = widget.initial;
    _reload();
  }

  Future<void> _reload() async {
    try {
      final s = await widget.api.load(group: widget.group, id: widget.chatId);
      if (mounted) setState(() {
        _s = s;
        _failed = false;
      });
    } catch (_) {
      if (mounted) setState(() => _failed = _s == null);
    }
  }

  Future<void> _save({String? mode, int? busyMinutes, bool? labelOn}) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final s = await widget.api.save(
          group: widget.group,
          id: widget.chatId,
          mode: mode,
          busyMinutes: busyMinutes,
          labelOn: labelOn);
      if (mounted) setState(() => _s = s);
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.maybeOf(context)?.showSnackBar(
            SnackBar(content: Text(AppLocalizations.of(context).aiReplyError)));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _setConsent(bool on) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await widget.api.setStyleConsent(on);
      await _reload();
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.maybeOf(context)?.showSnackBar(
            SnackBar(content: Text(AppLocalizations.of(context).aiReplyError)));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  String _modeTitle(AppLocalizations t, String m) => switch (m) {
        'suggest' => t.aiReplyModeSuggest,
        'busy' => t.aiReplyModeBusy,
        'auto' => t.aiReplyModeAuto,
        _ => t.aiReplyModeOff,
      };

  String _modeSub(AppLocalizations t, String m) => switch (m) {
        'suggest' => t.aiReplyModeSuggestSub,
        'busy' => t.aiReplyModeBusySub,
        'auto' => t.aiReplyModeAutoSub,
        _ => t.aiReplyModeOffSub,
      };

  IconData _modeIcon(String m) => switch (m) {
        'suggest' => Icons.lightbulb_outline_rounded,
        'busy' => Icons.do_not_disturb_on_outlined,
        'auto' => Icons.auto_awesome_rounded,
        _ => Icons.block_rounded,
      };

  String _busyLabel(AppLocalizations t, int m) => switch (m) {
        30 => t.aiReply30m,
        60 => t.aiReply1h,
        120 => t.aiReply2h,
        _ => t.aiReplyUntilOff,
      };

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final tok = DsTokens.of(context);
    final tx = Theme.of(context).textTheme;
    final bn = _bn(context);
    final s = _s;
    return SafeArea(
      top: false,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.9),
        child: SingleChildScrollView(
          padding: const EdgeInsets.only(bottom: Gap.lg),
          child: Column(
            key: const Key('aireply-sheet'),
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              DsSheetHeader(
                widget.group ? t.aiReplyGroupTitle : t.aiReplyTitle(widget.name),
                subtitle: t.aiReplyIntro,
              ),
              if (s == null && !_failed)
                const Padding(
                  padding: EdgeInsets.all(Gap.xl),
                  child: Center(child: CircularProgressIndicator()),
                )
              else if (s == null)
                Padding(
                  padding: Gap.screen,
                  child: Column(children: [
                    Text(t.aiReplyError, style: tx.bodyLarge?.copyWith(color: tok.text)),
                    const SizedBox(height: Gap.md),
                    DsButton.secondary(label: t.aiReplyRetry, onPressed: _reload),
                  ]),
                )
              else if (s.child)
                Padding(
                  padding: Gap.screen,
                  child: Text(t.aiReplyChild, style: tx.bodyLarge?.copyWith(color: tok.text)),
                )
              else ...[
                for (final m in kAiReplyModes)
                  if (s.allowedModes.contains(m))
                    _ModeRow(
                      key: Key('aireply-mode-$m'),
                      icon: _modeIcon(m),
                      title: _modeTitle(t, m),
                      subtitle: _modeSub(t, m),
                      selected: s.mode == m,
                      onTap: _busy
                          ? null
                          : () => _save(mode: m, busyMinutes: m == 'busy' ? _busyMinutes : null),
                    ),
                if (widget.group)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(Gap.lg, Gap.xs, Gap.lg, Gap.sm),
                    child: Text(t.aiReplyGroupOnly,
                        style: tx.bodyMedium?.copyWith(color: tok.muted)),
                  ),
                if (!widget.group && s.allowedModes.contains('busy')) ...[
                  DsSectionHeader(t.aiReplyBusyFor),
                  if (s.mode == 'busy')
                    Padding(
                      padding: const EdgeInsets.fromLTRB(Gap.lg, 0, Gap.lg, Gap.xs),
                      child: Text(
                          s.busyUntil == null
                              ? t.aiReplyBusyOn
                              : t.aiReplyBusyUntil(aiClock(context, s.busyUntil!)),
                          key: const Key('aireply-busy-until'),
                          style: tx.bodyMedium?.copyWith(color: tok.text)),
                    ),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: Gap.lg),
                    child: Wrap(spacing: Gap.sm, runSpacing: Gap.sm, children: [
                      for (final mins in kAiBusyMinutes)
                        DsChip(
                          key: Key('aireply-busy-$mins'),
                          label: _busyLabel(t, mins),
                          selected: _busyMinutes == mins,
                          onSelected: _busy
                              ? null
                              : (_) {
                                  setState(() => _busyMinutes = mins);
                                  _save(mode: 'busy', busyMinutes: mins);
                                },
                        ),
                    ]),
                  ),
                  const SizedBox(height: Gap.sm),
                ],
                if (!widget.group)
                  SwitchListTile(
                    key: const Key('aireply-label'),
                    value: s.labelOn,
                    onChanged: _busy ? null : (v) => _save(labelOn: v),
                    title: Text(t.aiReplyLabel),
                    subtitle: Text(t.aiReplyLabelSub),
                  ),
                SwitchListTile(
                  key: const Key('aireply-style'),
                  value: s.styleConsent,
                  onChanged: _busy ? null : _setConsent,
                  title: Text(t.aiReplyStyle),
                  subtitle: Text(t.aiReplyStyleSub),
                ),
                const Divider(height: Gap.xl),
                Padding(
                  padding: Gap.screen,
                  child: Text(
                    '${t.aiReplyCost(aiDigits(s.creditsPerReply, bn))} '
                    '${t.aiReplyFreeLeft(aiDigits(s.freeLeft, bn))}',
                    key: const Key('aireply-cost'),
                    style: tx.bodyMedium?.copyWith(color: tok.muted),
                  ),
                ),
                if (s.unlock == 'ad' && s.mode != 'off')
                  Padding(
                    padding: const EdgeInsets.fromLTRB(Gap.lg, Gap.md, Gap.lg, 0),
                    child: DsButton.secondary(
                      key: const Key('aireply-watch-ad'),
                      label: t.aiReplyWatchAd,
                      icon: Icons.ondemand_video_rounded,
                      expand: true,
                      onPressed: () async {
                        final ok = await RewardedAdSheet.show(context,
                            placement: kAiUnlockPlacement);
                        if (ok == true) await _reload();
                      },
                    ),
                  ),
              ],
              const SizedBox(height: Gap.md),
              Padding(
                padding: Gap.screen,
                child: DsButton(
                  key: const Key('aireply-done'),
                  label: t.aiReplyDone,
                  expand: true,
                  onPressed: () => Navigator.of(context).pop(_s),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ModeRow extends StatelessWidget {
  const _ModeRow({
    super.key,
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.selected,
    required this.onTap,
  });
  final IconData icon;
  final String title;
  final String subtitle;
  final bool selected;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final tok = DsTokens.of(context);
    return Semantics(
      selected: selected,
      button: true,
      child: DsListRow(
        leading: Icon(icon, color: selected ? tok.primaryInk : tok.muted),
        title: title,
        subtitle: subtitle,
        trailing: Icon(
          selected ? Icons.radio_button_checked_rounded : Icons.radio_button_off_rounded,
          color: selected ? tok.primaryInk : tok.muted,
        ),
        onTap: onTap,
      ),
    );
  }
}

/// 2–3 reply chips above the composer (Suggest mode); one tap sends.
class AiSuggestionStrip extends StatelessWidget {
  const AiSuggestionStrip({
    super.key,
    required this.suggestions,
    required this.onTap,
    this.loading = false,
    this.needsYou = false,
    this.noCredits = false,
    this.onUnlock,
    this.onClose,
  });
  final List<String> suggestions;
  final ValueChanged<String> onTap;
  final bool loading;
  final bool needsYou;
  final bool noCredits;
  final VoidCallback? onUnlock;
  final VoidCallback? onClose;

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final tok = DsTokens.of(context);
    final tx = Theme.of(context).textTheme;
    Widget body;
    if (loading) {
      body = Row(children: [
        const SizedBox(
            width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)),
        const SizedBox(width: Gap.sm),
        Flexible(
            child: Text(t.aiReplySuggesting,
                style: tx.bodyMedium?.copyWith(color: tok.muted))),
      ]);
    } else if (needsYou || noCredits) {
      body = Row(children: [
        Icon(needsYou ? Icons.front_hand_rounded : Icons.toll_rounded,
            size: 18, color: tok.muted),
        const SizedBox(width: Gap.sm),
        Expanded(
          child: Text(needsYou ? t.aiReplyNeedsYou : t.aiReplyNoCredits,
              key: const Key('aireply-needs-you'),
              style: tx.bodyMedium?.copyWith(color: tok.text)),
        ),
        if (noCredits && onUnlock != null)
          TextButton(onPressed: onUnlock, child: Text(t.aiReplyWatchAd)),
      ]);
    } else {
      body = Wrap(spacing: Gap.sm, runSpacing: Gap.xs, children: [
        for (var i = 0; i < suggestions.length; i++)
          ActionChip(
            key: Key('aireply-chip-$i'),
            avatar: Icon(Icons.auto_awesome_rounded, size: 16, color: tok.primaryInk),
            label: Text(suggestions[i], maxLines: 3, softWrap: true),
            tooltip: t.aiReplyTapToSend,
            materialTapTargetSize: MaterialTapTargetSize.padded,
            onPressed: () => onTap(suggestions[i]),
          ),
      ]);
    }
    return Padding(
      key: const Key('aireply-strip'),
      padding: const EdgeInsets.fromLTRB(Gap.sm, Gap.xs, Gap.xs, 0),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Expanded(child: body),
        if (onClose != null)
          IconButton(
            tooltip: t.aiReplyHide,
            icon: const Icon(Icons.close_rounded, size: 20),
            onPressed: onClose,
          ),
      ]),
    );
  }
}

/// The small "Assisto AI reply" tag under an AI-sent message.
class AiReplyTag extends StatelessWidget {
  const AiReplyTag({super.key, required this.color});
  final Color color;

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: 2),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(Icons.auto_awesome_rounded, size: 12, color: color),
        const SizedBox(width: Gap.xs),
        Flexible(
          child: Text(t.aiReplyTag,
              style: Theme.of(context)
                  .textTheme
                  .labelSmall
                  ?.copyWith(fontStyle: FontStyle.italic, color: color)),
        ),
      ]),
    );
  }
}

/// One line at the top of the chat while Busy / Full auto is on, plus the
/// "AI held a message — it needs you" notice.
class AiModeStrip extends StatelessWidget {
  const AiModeStrip({
    super.key,
    required this.state,
    required this.onChange,
    this.onHeldSeen,
  });
  final AiReplyState state;
  final VoidCallback onChange;
  final ValueChanged<int>? onHeldSeen;

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final tok = DsTokens.of(context);
    final tx = Theme.of(context).textTheme;
    final held = state.held.isNotEmpty ? state.held.first : null;
    final String line;
    if (held != null) {
      line = t.aiReplyHeldHere;
    } else if (state.mode == 'busy') {
      line = state.busyUntil == null
          ? t.aiReplyBusyOn
          : t.aiReplyBusyUntil(aiClock(context, state.busyUntil!));
    } else {
      line = t.aiReplyOnAuto;
    }
    return Material(
      color: tok.primarySoft,
      child: Padding(
        key: const Key('aireply-mode-strip'),
        padding: const EdgeInsets.fromLTRB(Gap.lg, Gap.xs, Gap.xs, Gap.xs),
        child: Row(children: [
          Icon(held != null ? Icons.front_hand_rounded : Icons.auto_awesome_rounded,
              size: 18, color: tok.primaryInk),
          const SizedBox(width: Gap.sm),
          Expanded(child: Text(line, style: tx.bodyMedium?.copyWith(color: tok.text))),
          if (held != null && onHeldSeen != null)
            TextButton(
              onPressed: () => onHeldSeen!((held['id'] as num).toInt()),
              child: Text(t.aiReplyHeldOk),
            )
          else
            TextButton(onPressed: onChange, child: Text(t.aiReplyChange)),
        ]),
      ),
    );
  }
}
