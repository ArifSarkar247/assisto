// P3 — "@Assisto" actions inside a My Circle chat (1:1 + groups).
//
// E2E RULE (.phaseB/P3_DESIGN.md §1): AI actions that need message content
// run only when the user taps them, show exactly what will be sent and its
// credit cost first, and send ONLY that text (decrypted on this phone). The
// first time, a clear notice explains it ("This sends these messages to
// Assisto AI"). Non-AI actions (reminder, split, list, safety) post E2E cards.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:geolocator/geolocator.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../l10n/app_localizations.dart';
import '../notifications.dart';
import '../screens/credits_screen.dart';
import '../state.dart';
import '../theme.dart';
import '../feature_gates.dart' show kMedicalFeaturesAllowed;
import '../widgets/journey_api.dart';
import '../widgets/notif_models.dart' show notifLocalizeDigits;
import '../widgets/reminders_nlp.dart' as nlp;
import 'assisto_card.dart';
import 'assisto_card_view.dart' show p3When, p3Taka;
import 'assisto_intent.dart';
import 'p3_api.dart';

/// What the chat screen hands the Assisto sheet. Everything here is LOCAL:
/// the decrypted text never leaves the phone unless the user runs an AI
/// action on it.
class AssistoChatPort {
  final bool isGroup;
  final String chatName;
  final String myName;
  final List<String> memberNames; // the OTHER people in this chat
  final List<Map<String, String>> Function() unread; // [{from, text}] oldest first
  final List<Map<String, String>> Function() recent; // last messages, oldest first
  final String Function() draft;
  final void Function(String text) setDraft;
  final String Function() lastIncoming;
  final Future<bool> Function(String plaintext) send;

  const AssistoChatPort({
    required this.isGroup,
    required this.chatName,
    required this.myName,
    required this.memberNames,
    required this.unread,
    required this.recent,
    required this.draft,
    required this.setDraft,
    required this.lastIncoming,
    required this.send,
  });
}

const String kP3ConsentKey = 'p3_ai_consent_v1';

/// Open the @Assisto menu, or jump straight to [intent]'s action.
Future<void> showAssistoMenu(BuildContext context, AssistoChatPort port,
    {AssistoIntent? intent}) async {
  final a = intent?.action ?? AssistoAction.menu;
  if (a != AssistoAction.menu) return _openAction(context, port, a, intent);
  final picked = await showModalBottomSheet<_Pick>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (_) => AssistoMenuSheet(port: port),
  );
  if (picked == null || !context.mounted) return;
  if (picked.safety != null) {
    return runSafetyAction(context, port, picked.safety!);
  }
  return _openAction(context, port, picked.action!, null);
}

Future<void> _openAction(BuildContext context, AssistoChatPort port,
    AssistoAction a, AssistoIntent? intent) async {
  switch (a) {
    case AssistoAction.summarize:
    case AssistoAction.translate:
    case AssistoAction.ask:
      await showModalBottomSheet<void>(
        context: context,
        showDragHandle: true,
        isScrollControlled: true,
        builder: (_) => AssistoAiSheet(port: port, action: a, intent: intent),
      );
    case AssistoAction.remind:
      await showModalBottomSheet<void>(
        context: context,
        showDragHandle: true,
        isScrollControlled: true,
        builder: (_) => ReminderComposer(port: port, intent: intent),
      );
    case AssistoAction.split:
      await showModalBottomSheet<void>(
        context: context,
        showDragHandle: true,
        isScrollControlled: true,
        builder: (_) => SplitComposer(port: port, intent: intent),
      );
    case AssistoAction.list:
      await showModalBottomSheet<void>(
        context: context,
        showDragHandle: true,
        isScrollControlled: true,
        builder: (_) => ListComposer(port: port, intent: intent),
      );
    case AssistoAction.menu:
      break;
  }
}

enum SafetyAction { arrived, sos, med, lost }

class _Pick {
  final AssistoAction? action;
  final SafetyAction? safety;
  const _Pick({this.action, this.safety});
}

class AssistoMenuSheet extends StatefulWidget {
  final AssistoChatPort port;
  const AssistoMenuSheet({super.key, required this.port});
  @override
  State<AssistoMenuSheet> createState() => AssistoMenuSheetState();
}

class AssistoMenuSheetState extends State<AssistoMenuSheet> {
  AssistoQuote? _quote;

  @override
  void initState() {
    super.initState();
    final api = context.read<AppState>().api;
    api.assistoQuote().timeout(const Duration(seconds: 8)).then((q) {
      if (mounted) setState(() => _quote = q);
    }, onError: (_) {});
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    String cost(String a) {
      final q = _quote;
      if (q == null) return t.p3UsesCredits;
      return t.p3CreditsN(notifLocalizeDigits(context, '${q.cost(a)}'));
    }

    Widget tile(IconData i, String title, String sub, String trailing, _Pick p,
            {Color? tone}) =>
        ListTile(
          key: ValueKey('p3-menu-${p.action?.name ?? p.safety?.name}'),
          leading: Icon(i, color: tone ?? scheme.primary),
          title: Text(title),
          subtitle: Text(sub),
          trailing: Text(trailing,
              style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant)),
          onTap: () => Navigator.of(context).pop(p),
        );
    final unreadN = widget.port.unread().length;
    return SafeArea(
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(Gap.lg, 0, Gap.lg, Gap.xs),
              child: Row(children: [
                Container(
                  width: 32,
                  height: 32,
                  decoration: const BoxDecoration(gradient: Brand.gradient, shape: BoxShape.circle),
                  child: const Icon(Icons.auto_awesome, color: Colors.white, size: 18),
                ),
                const SizedBox(width: Gap.sm),
                Expanded(
                  child: Text(t.p3MenuTitle, style: Theme.of(context).textTheme.titleMedium),
                ),
              ]),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(Gap.lg, 0, Gap.lg, Gap.sm),
              child: Text(t.p3MenuPrivacy,
                  style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant)),
            ),
            tile(Icons.summarize_outlined, t.p3ActSummarize,
                unreadN > 0
                    ? t.p3ActSummarizeSubN(notifLocalizeDigits(context, '$unreadN'))
                    : t.p3ActSummarizeSub,
                cost('summarize'), const _Pick(action: AssistoAction.summarize)),
            tile(Icons.alarm_add_outlined, t.p3ActRemind, t.p3ActRemindSub, t.p3Free,
                const _Pick(action: AssistoAction.remind)),
            tile(Icons.call_split, t.p3ActSplit, t.p3ActSplitSub, t.p3Free,
                const _Pick(action: AssistoAction.split)),
            tile(Icons.checklist, t.p3ActList, t.p3ActListSub, t.p3Free,
                const _Pick(action: AssistoAction.list)),
            tile(Icons.translate, t.p3ActTranslate, t.p3ActTranslateSub,
                cost('translate'), const _Pick(action: AssistoAction.translate)),
            tile(Icons.help_outline, t.p3ActAsk, t.p3ActAskSub, cost('ask'),
                const _Pick(action: AssistoAction.ask)),
            const Divider(),
            Padding(
              padding: const EdgeInsets.fromLTRB(Gap.lg, Gap.xs, Gap.lg, 0),
              child: Text(t.p3SafetyTitle,
                  style: TextStyle(fontWeight: FontWeight.w700, color: scheme.onSurfaceVariant)),
            ),
            tile(Icons.where_to_vote_outlined, t.p3SafeArrived, t.p3SafeArrivedSub, t.p3Free,
                const _Pick(safety: SafetyAction.arrived), tone: Brand.onTint(context, Brand.successFill)),
            tile(Icons.sos, t.p3SafeSos, t.p3SafeSosSub, t.p3Free,
                const _Pick(safety: SafetyAction.sos), tone: Brand.dangerFill),
            // play-nomed: no "medicine update" (missed-dose) card in Play.
            if (kMedicalFeaturesAllowed)
              tile(Icons.medication_outlined, t.p3SafeMed, t.p3SafeMedSub, t.p3Free,
                  const _Pick(safety: SafetyAction.med)),
            tile(Icons.phonelink_erase, t.p3SafeLost, t.p3SafeLostSub, t.p3Free,
                const _Pick(safety: SafetyAction.lost), tone: Brand.warnInk(context)),
            const SizedBox(height: Gap.sm),
          ],
        ),
      ),
    );
  }
}

// ===========================================================================
// AI actions — summarize / translate / ask
// ===========================================================================
class AssistoAiSheet extends StatefulWidget {
  final AssistoChatPort port;
  final AssistoAction action;
  final AssistoIntent? intent;
  const AssistoAiSheet({super.key, required this.port, required this.action, this.intent});
  @override
  State<AssistoAiSheet> createState() => _AssistoAiSheetState();
}

enum _AiStage { input, running, result, error }

class _AssistoAiSheetState extends State<AssistoAiSheet> {
  AssistoQuote? _quote;
  bool _quoteFailed = false;
  _AiStage _stage = _AiStage.input;
  final _q = TextEditingController();
  String _target = 'en';
  String _source = 'draft'; // translate: draft | last | typed
  String _result = '';
  String _error = '';
  int _charged = 0;
  List<Map<String, String>> _msgs = const [];
  bool _usedUnread = true;

  String get _action => switch (widget.action) {
        AssistoAction.summarize => 'summarize',
        AssistoAction.translate => 'translate',
        _ => 'ask',
      };

  @override
  void initState() {
    super.initState();
    final p = widget.port;
    final i = widget.intent;
    if (widget.action == AssistoAction.summarize) {
      _msgs = p.unread();
      if (_msgs.isEmpty) {
        _usedUnread = false;
        _msgs = p.recent();
      }
    } else if (widget.action == AssistoAction.translate) {
      final typed = (i?.rest ?? '').trim();
      if (typed.isNotEmpty) {
        _source = 'typed';
        _q.text = typed;
      } else if (p.draft().trim().isNotEmpty) {
        _source = 'draft';
      } else {
        _source = 'last';
      }
      final txt = _translateText();
      _target = (i?.target.isNotEmpty ?? false)
          ? i!.target
          : (RegExp('[\u0980-\u09ff]').hasMatch(txt) ? 'en' : 'bn');
    } else {
      _q.text = (i?.rest ?? '').trim();
    }
    _loadQuote();
  }

  Future<void> _loadQuote() async {
    setState(() => _quoteFailed = false);
    try {
      final q = await context
          .read<AppState>()
          .api
          .assistoQuote()
          .timeout(const Duration(seconds: 10));
      if (mounted) setState(() => _quote = q);
    } catch (_) {
      if (mounted) setState(() => _quoteFailed = true);
    }
  }

  @override
  void dispose() {
    _q.dispose();
    super.dispose();
  }

  String _translateText() => switch (_source) {
        'typed' => _q.text.trim(),
        'draft' => widget.port.draft().trim(),
        _ => widget.port.lastIncoming().trim(),
      };

  bool get _needsConsent => widget.action != AssistoAction.ask;

  bool get _canRun {
    if (_quote == null) return false;
    switch (widget.action) {
      case AssistoAction.summarize:
        return _msgs.isNotEmpty;
      case AssistoAction.translate:
        return _translateText().isNotEmpty;
      default:
        return _q.text.trim().isNotEmpty;
    }
  }

  /// The one-time notice. Returns true when the user agreed.
  Future<bool> _consent() async {
    if (!_needsConsent) return true;
    SharedPreferences? prefs;
    try {
      prefs = await SharedPreferences.getInstance();
      if (prefs.getBool(kP3ConsentKey) == true) return true;
    } catch (_) {}
    if (!mounted) return false;
    var remember = true;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) {
        final t = AppLocalizations.of(ctx);
        return StatefulBuilder(builder: (ctx, setD) {
          return AlertDialog(
            key: const ValueKey('p3-consent'),
            icon: const Icon(Icons.lock_open_outlined),
            title: Text(t.p3ConsentTitle),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(t.p3ConsentBody),
                const SizedBox(height: Gap.sm),
                CheckboxListTile(
                  contentPadding: EdgeInsets.zero,
                  value: remember,
                  onChanged: (v) => setD(() => remember = v ?? false),
                  title: Text(t.p3ConsentRemember),
                  controlAffinity: ListTileControlAffinity.leading,
                ),
              ],
            ),
            actions: [
              TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(t.cancel)),
              FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(t.p3ConsentOk)),
            ],
          );
        });
      },
    );
    if (ok == true && remember) {
      try {
        await prefs?.setBool(kP3ConsentKey, true);
      } catch (_) {}
    }
    return ok == true;
  }

  Future<void> _run() async {
    if (!_canRun) return;
    if (!await _consent() || !mounted) return;
    setState(() => _stage = _AiStage.running);
    final api = context.read<AppState>().api;
    final AssistoRun r;
    switch (widget.action) {
      case AssistoAction.summarize:
        r = await api.assistoRun('summarize', messages: _msgs, consent: true);
      case AssistoAction.translate:
        r = await api.assistoRun('translate',
            text: _translateText(), target: _target, consent: true);
      default:
        r = await api.assistoRun('ask', question: _q.text.trim());
    }
    if (!mounted) return;
    setState(() {
      if (r.ok) {
        _stage = _AiStage.result;
        _result = r.result;
        _charged = r.charged;
      } else {
        _stage = _AiStage.error;
        _error = r.error;
      }
    });
  }

  Future<void> _share() async {
    final t = AppLocalizations.of(context);
    final AssistoCard card;
    final String fb;
    switch (widget.action) {
      case AssistoAction.summarize:
        card = AssistoCard(CardType.summary, newCardId(), {'text': _result, 'n': _msgs.length});
        fb = '${t.p3FbSummary}: ${_firstLine(_result)}';
      case AssistoAction.translate:
        card = AssistoCard(CardType.translate, newCardId(),
            {'src': _translateText(), 'out': _result, 'to': _target});
        fb = '${t.p3FbTranslate}: $_result';
      default:
        card = AssistoCard(CardType.answer, newCardId(), {'q': _q.text.trim(), 'a': _result});
        fb = '${t.p3FbAnswer}: ${_firstLine(_result)}';
    }
    final ok = await widget.port.send(encodeCard(card, fb));
    if (!mounted) return;
    if (ok) {
      Navigator.of(context).pop();
    } else {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(t.p3SendFailed)));
    }
  }

  String _firstLine(String s) {
    final l = s.trim().split('\n').first;
    return l.length > 80 ? '${l.substring(0, 80)}…' : l;
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final title = switch (widget.action) {
      AssistoAction.summarize => t.p3ActSummarize,
      AssistoAction.translate => t.p3ActTranslate,
      _ => t.p3ActAsk,
    };
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(Gap.lg, 0, Gap.lg, Gap.lg),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(title, style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: Gap.sm),
              ...switch (_stage) {
                _AiStage.input => _input(t, scheme),
                _AiStage.running => [
                    const SizedBox(height: Gap.xl),
                    const Center(child: CircularProgressIndicator()),
                    const SizedBox(height: Gap.md),
                    Center(child: Text(t.p3Working)),
                    const SizedBox(height: Gap.xl),
                  ],
                _AiStage.result => _resultView(t, scheme),
                _AiStage.error => _errorView(t, scheme),
              },
            ],
          ),
        ),
      ),
    );
  }

  List<Widget> _input(AppLocalizations t, ColorScheme scheme) {
    final muted = TextStyle(fontSize: 13, color: scheme.onSurfaceVariant, height: 1.3);
    final q = _quote;
    final cost = q == null ? '' : notifLocalizeDigits(context, '${q.cost(_action)}');
    final out = <Widget>[];
    if (widget.action == AssistoAction.summarize) {
      final n = notifLocalizeDigits(context, '${_msgs.length}');
      out.add(Text(
          _msgs.isEmpty
              ? t.p3NothingToSummarize
              : (_usedUnread ? t.p3SendsUnread(n) : t.p3SendsRecent(n)),
          style: muted));
      if (_msgs.isNotEmpty) {
        out.add(const SizedBox(height: Gap.sm));
        out.add(Container(
          constraints: const BoxConstraints(maxHeight: 160),
          padding: const EdgeInsets.all(Gap.sm),
          decoration: BoxDecoration(
              color: scheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(Radii.sm)),
          child: ListView(
            shrinkWrap: true,
            children: [
              for (final m in _msgs)
                Text('${m['from']}: ${m['text']}',
                    maxLines: 2, overflow: TextOverflow.ellipsis, style: muted),
            ],
          ),
        ));
      }
    } else if (widget.action == AssistoAction.translate) {
      final hasDraft = widget.port.draft().trim().isNotEmpty;
      final hasLast = widget.port.lastIncoming().trim().isNotEmpty;
      out.add(Wrap(spacing: Gap.sm, runSpacing: Gap.xs, children: [
        if (hasDraft)
          ChoiceChip(
              label: Text(t.p3SrcDraft),
              selected: _source == 'draft',
              onSelected: (_) => setState(() => _source = 'draft')),
        if (hasLast)
          ChoiceChip(
              label: Text(t.p3SrcLast),
              selected: _source == 'last',
              onSelected: (_) => setState(() => _source = 'last')),
        ChoiceChip(
            label: Text(t.p3SrcType),
            selected: _source == 'typed',
            onSelected: (_) => setState(() => _source = 'typed')),
      ]));
      out.add(const SizedBox(height: Gap.sm));
      if (_source == 'typed') {
        out.add(TextField(
          controller: _q,
          maxLines: 4,
          minLines: 2,
          onChanged: (_) => setState(() {}),
          decoration: InputDecoration(
              hintText: t.p3TranslateHint, border: const OutlineInputBorder()),
        ));
      } else {
        out.add(Container(
          padding: const EdgeInsets.all(Gap.sm),
          decoration: BoxDecoration(
              color: scheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(Radii.sm)),
          child: Text(_translateText().isEmpty ? t.p3NothingToTranslate : _translateText(),
              maxLines: 5, overflow: TextOverflow.ellipsis),
        ));
      }
      out.add(const SizedBox(height: Gap.sm));
      out.add(SegmentedButton<String>(
        segments: [
          ButtonSegment(value: 'bn', label: Text(t.p3ToBangla)),
          ButtonSegment(value: 'en', label: Text(t.p3ToEnglish)),
        ],
        selected: {_target},
        onSelectionChanged: (s) => setState(() => _target = s.first),
      ));
      out.add(const SizedBox(height: Gap.sm));
      out.add(Text(t.p3SendsThisText, style: muted));
    } else {
      out.add(TextField(
        controller: _q,
        autofocus: _q.text.isEmpty,
        maxLines: 4,
        minLines: 2,
        maxLength: 500,
        onChanged: (_) => setState(() {}),
        decoration: InputDecoration(hintText: t.p3AskHint, border: const OutlineInputBorder()),
      ));
      out.add(Text(t.p3AskPrivacy, style: muted));
    }
    out.add(const SizedBox(height: Gap.md));
    if (_quoteFailed) {
      out.add(Text(t.p3QuoteFailed, style: muted));
      out.add(const SizedBox(height: Gap.xs));
      out.add(OutlinedButton.icon(
          onPressed: _loadQuote, icon: const Icon(Icons.refresh), label: Text(t.retry)));
    } else if (q != null && !q.aiAvailable) {
      out.add(Text(t.p3AiOff, style: muted));
    } else {
      out.add(FilledButton.icon(
        key: const ValueKey('p3-ai-run'),
        onPressed: _canRun && (q?.aiAvailable ?? false) ? _run : null,
        icon: const Icon(Icons.auto_awesome),
        label: Text(q == null ? t.p3CheckingCredits : t.p3RunFor(cost)),
      ));
      if (q != null) {
        out.add(const SizedBox(height: Gap.xs));
        out.add(Text(t.p3Balance(notifLocalizeDigits(context, '${q.balance}')),
            textAlign: TextAlign.center, style: muted));
      }
    }
    return out;
  }

  List<Widget> _resultView(AppLocalizations t, ColorScheme scheme) => [
        Container(
          padding: const EdgeInsets.all(Gap.md),
          decoration: BoxDecoration(
              color: scheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(Radii.md)),
          child: SelectableText(_result, style: const TextStyle(fontSize: 15, height: 1.4)),
        ),
        const SizedBox(height: Gap.xs),
        Text(
            '${t.p3AiMarker} · ${t.p3CreditsUsed(notifLocalizeDigits(context, '$_charged'))}',
            style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant)),
        const SizedBox(height: Gap.md),
        if (widget.action == AssistoAction.translate && _source == 'draft')
          FilledButton.icon(
            onPressed: () {
              widget.port.setDraft(_result);
              Navigator.of(context).pop();
            },
            icon: const Icon(Icons.edit_outlined),
            label: Text(t.p3UseInMessage),
          ),
        const SizedBox(height: Gap.xs),
        OutlinedButton.icon(
          key: const ValueKey('p3-ai-share'),
          onPressed: _share,
          icon: const Icon(Icons.send_outlined),
          label: Text(t.p3ShareInChat),
        ),
        const SizedBox(height: Gap.xs),
        Text(t.p3ShareNote, style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant)),
        TextButton.icon(
          onPressed: () {
            Clipboard.setData(ClipboardData(text: _result));
            ScaffoldMessenger.of(context)
                .showSnackBar(SnackBar(content: Text(t.p3Copied)));
          },
          icon: const Icon(Icons.copy),
          label: Text(t.p3Copy),
        ),
      ];

  List<Widget> _errorView(AppLocalizations t, ColorScheme scheme) {
    final msg = switch (_error) {
      'credits' => t.p3ErrCredits,
      'paused' => t.p3ErrPaused,
      'limit' => t.p3ErrLimit,
      'ai_off' => t.p3AiOff,
      'net' => t.p3ErrNet,
      _ => t.p3ErrBusy,
    };
    return [
      Row(children: [
        Icon(Icons.info_outline, color: scheme.error),
        const SizedBox(width: Gap.sm),
        Expanded(child: Text(msg)),
      ]),
      const SizedBox(height: Gap.sm),
      Text(t.p3NotCharged, style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant)),
      const SizedBox(height: Gap.md),
      if (_error == 'credits')
        FilledButton.icon(
          key: const ValueKey('p3-get-credits'),
          onPressed: () => Navigator.of(context)
              .push(MaterialPageRoute(builder: (_) => const CreditsScreen())),
          icon: const Icon(Icons.bolt),
          label: Text(t.p3GetCredits),
        )
      else
        OutlinedButton.icon(
          onPressed: () => setState(() => _stage = _AiStage.input),
          icon: const Icon(Icons.refresh),
          label: Text(t.retry),
        ),
    ];
  }
}

// ===========================================================================
// Reminder — for me / for everyone (others accept with one tap)
// ===========================================================================
/// Add a reminder to MY reminders on this phone (synced like any reminder).
Future<bool> addReminderForMe(BuildContext context, String title, DateTime at) async {
  try {
    final app = context.read<AppState>();
    final row = await app.reminders.add({
      'title': title,
      'notes': '',
      'due_at': at.toUtc().toIso8601String(),
      'recurrence': 'none',
      'recurrence_rule': <String, dynamic>{},
      'date_only': false,
      'done': false,
      'link': <String, dynamic>{},
    });
    final lid = row['localId'];
    if (lid is String) {
      unawaited(Notifications.schedule(lid, title, '', at.toLocal()));
    }
    return true;
  } catch (_) {
    return false;
  }
}

class ReminderComposer extends StatefulWidget {
  final AssistoChatPort port;
  final AssistoIntent? intent;
  const ReminderComposer({super.key, required this.port, this.intent});
  @override
  State<ReminderComposer> createState() => _ReminderComposerState();
}

class _ReminderComposerState extends State<ReminderComposer> {
  final _title = TextEditingController();
  DateTime _at = DateTime.now().add(const Duration(hours: 1));
  bool _everyone = false;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    final rest = widget.intent?.rest ?? '';
    _everyone = widget.intent?.everyone ?? false;
    if (rest.isNotEmpty) {
      final p = nlp.parseReminder(rest);
      _title.text = p.cleanTitle.isNotEmpty ? p.cleanTitle : rest;
      final dt = p.dateTime;
      if (dt != null && dt.isAfter(DateTime.now())) {
        _at = p.dateOnly ? DateTime(dt.year, dt.month, dt.day, 9) : dt;
      }
    } else {
      final n = DateTime.now().add(const Duration(hours: 1));
      _at = DateTime(n.year, n.month, n.day, n.hour);
    }
  }

  @override
  void dispose() {
    _title.dispose();
    super.dispose();
  }

  Future<void> _pickDate() async {
    final d = await showDatePicker(
        context: context,
        initialDate: _at,
        firstDate: DateTime.now().subtract(const Duration(days: 1)),
        lastDate: DateTime.now().add(const Duration(days: 730)));
    if (d != null) setState(() => _at = DateTime(d.year, d.month, d.day, _at.hour, _at.minute));
  }

  Future<void> _pickTime() async {
    final tm = await showTimePicker(context: context, initialTime: TimeOfDay.fromDateTime(_at));
    if (tm != null) setState(() => _at = DateTime(_at.year, _at.month, _at.day, tm.hour, tm.minute));
  }

  Future<void> _save() async {
    final t = AppLocalizations.of(context);
    final title = _title.text.trim();
    if (title.isEmpty || _busy) return;
    setState(() => _busy = true);
    final mineOk = await addReminderForMe(context, title, _at);
    var sent = true;
    if (_everyone && mounted) {
      final card = reminderCard(title: title, at: _at, forEveryone: true, by: widget.port.myName);
      sent = await widget.port.send(
          encodeCard(card, '⏰ ${t.p3FbReminder}: $title · ${p3When(context, _at)}'));
    }
    if (!mounted) return;
    setState(() => _busy = false);
    final msg = !mineOk || !sent
        ? t.p3SendFailed
        : (_everyone ? t.p3ReminderSentAll : t.p3ReminderSavedMe);
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
    if (mineOk && sent) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final l = MaterialLocalizations.of(context);
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(Gap.lg, 0, Gap.lg, Gap.lg),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(t.p3ActRemind, style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: Gap.md),
              TextField(
                controller: _title,
                maxLength: 120,
                onChanged: (_) => setState(() {}),
                decoration: InputDecoration(
                    labelText: t.p3ReminderWhat, border: const OutlineInputBorder()),
              ),
              Row(children: [
                Expanded(
                  child: OutlinedButton.icon(
                      onPressed: _pickDate,
                      icon: const Icon(Icons.event),
                      label: Text(l.formatMediumDate(_at), overflow: TextOverflow.ellipsis)),
                ),
                const SizedBox(width: Gap.sm),
                Expanded(
                  child: OutlinedButton.icon(
                      onPressed: _pickTime,
                      icon: const Icon(Icons.schedule),
                      label: Text(l.formatTimeOfDay(TimeOfDay.fromDateTime(_at)))),
                ),
              ]),
              const SizedBox(height: Gap.md),
              SegmentedButton<bool>(
                segments: [
                  ButtonSegment(value: false, label: Text(t.p3ForMe), icon: const Icon(Icons.person_outline)),
                  ButtonSegment(
                      value: true,
                      label: Text(widget.port.isGroup ? t.p3ForEveryone : t.p3ForBoth),
                      icon: const Icon(Icons.groups_outlined)),
                ],
                selected: {_everyone},
                onSelectionChanged: (s) => setState(() => _everyone = s.first),
              ),
              const SizedBox(height: Gap.sm),
              Text(_everyone ? t.p3ForEveryoneNote : t.p3ForMeNote,
                  style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant)),
              const SizedBox(height: Gap.md),
              FilledButton.icon(
                key: const ValueKey('p3-rem-save'),
                onPressed: _title.text.trim().isEmpty || _busy ? null : _save,
                icon: Icon(_everyone ? Icons.send : Icons.alarm_add),
                label: Text(_everyone ? t.p3SendReminder : t.p3SaveReminder),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ===========================================================================
// Split a bill
// ===========================================================================
class SplitComposer extends StatefulWidget {
  final AssistoChatPort port;
  final AssistoIntent? intent;
  const SplitComposer({super.key, required this.port, this.intent});
  @override
  State<SplitComposer> createState() => _SplitComposerState();
}

class _SplitComposerState extends State<SplitComposer> {
  final _title = TextEditingController();
  final _amount = TextEditingController();
  late final List<String> _people;
  final Set<String> _in = {};
  bool _save = true;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _people = [widget.port.myName, ...widget.port.memberNames];
    _in.addAll(_people);
    final p = widget.intent?.poisha ?? 0;
    if (p > 0) _amount.text = takaOf(p).replaceAll(',', '');
  }

  @override
  void dispose() {
    _title.dispose();
    _amount.dispose();
    super.dispose();
  }

  int get _poisha => poishaOf(_amount.text);

  Future<void> _send() async {
    final t = AppLocalizations.of(context);
    if (_poisha <= 0 || _in.isEmpty || _busy) return;
    setState(() => _busy = true);
    final names = _people.where(_in.contains).toList();
    final title = _title.text.trim().isEmpty ? t.p3SplitDefaultTitle : _title.text.trim();
    final card = splitCard(
        title: title, totalPoisha: _poisha, payer: widget.port.myName, names: names);
    final ok = await widget.port.send(encodeCard(card,
        '➗ ${t.p3FbSplit}: $title · ${p3Taka(context, _poisha)}'));
    var saved = true;
    if (ok && _save && mounted) saved = await _saveToSplitBook(title, names);
    if (!mounted) return;
    setState(() => _busy = false);
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(!ok ? t.p3SendFailed : (saved ? t.p3SplitSent : t.p3SplitSentNotSaved))));
    if (ok) Navigator.of(context).pop();
  }

  /// Reuse the existing Expense-split book (split/people + split/expenses).
  Future<bool> _saveToSplitBook(String title, List<String> names) async {
    try {
      final api = context.read<AppState>().api;
      final people = await api.listItems('split/people');
      final ids = <dynamic>[];
      dynamic payer;
      for (final n in names) {
        Map<String, dynamic>? row;
        for (final p in people) {
          if ('${p['name']}'.toLowerCase() == n.toLowerCase()) row = p;
        }
        row ??= await api.createItem('split/people', {'name': n});
        ids.add(row['id']);
        if (n == widget.port.myName) payer = row['id'];
      }
      await api.createItem('split/expenses', {
        'title': title,
        'payer': payer ?? ids.first,
        'mode': 'equal',
        'amount': (_poisha / 100).toStringAsFixed(2),
        'participants': ids,
      });
      return true;
    } catch (_) {
      return false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final names = _people.where(_in.contains).toList();
    final shares = equalShares(_poisha, names.length);
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(Gap.lg, 0, Gap.lg, Gap.lg),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(t.p3ActSplit, style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: Gap.md),
              TextField(
                controller: _title,
                maxLength: 80,
                decoration: InputDecoration(
                    labelText: t.p3SplitWhat,
                    hintText: t.p3SplitDefaultTitle,
                    border: const OutlineInputBorder()),
              ),
              TextField(
                controller: _amount,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                onChanged: (_) => setState(() {}),
                decoration: InputDecoration(
                    labelText: t.p3SplitAmount,
                    prefixText: '\u09f3 ',
                    border: const OutlineInputBorder()),
              ),
              const SizedBox(height: Gap.md),
              Text(t.p3SplitWho, style: const TextStyle(fontWeight: FontWeight.w600)),
              for (var i = 0; i < _people.length; i++)
                CheckboxListTile(
                  contentPadding: EdgeInsets.zero,
                  value: _in.contains(_people[i]),
                  onChanged: (v) => setState(() =>
                      v == true ? _in.add(_people[i]) : _in.remove(_people[i])),
                  title: Text(i == 0 ? t.p3YouName(_people[i]) : _people[i],
                      overflow: TextOverflow.ellipsis),
                  secondary: _in.contains(_people[i]) && shares.isNotEmpty
                      ? Text(p3Taka(context, shares[names.indexOf(_people[i])]))
                      : null,
                ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                value: _save,
                onChanged: (v) => setState(() => _save = v),
                title: Text(t.p3SplitSaveBook),
              ),
              Text(t.p3SplitNote, style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant)),
              const SizedBox(height: Gap.md),
              FilledButton.icon(
                key: const ValueKey('p3-split-send'),
                onPressed: _poisha > 0 && names.isNotEmpty && !_busy ? _send : null,
                icon: const Icon(Icons.send),
                label: Text(t.p3SplitSend),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ===========================================================================
// Shopping list
// ===========================================================================
class ListComposer extends StatefulWidget {
  final AssistoChatPort port;
  final AssistoIntent? intent;
  const ListComposer({super.key, required this.port, this.intent});
  @override
  State<ListComposer> createState() => _ListComposerState();
}

class _ListComposerState extends State<ListComposer> {
  final _title = TextEditingController();
  final _items = TextEditingController();
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    final items = widget.intent?.items ?? const [];
    if (items.isNotEmpty) _items.text = items.join('\n');
  }

  @override
  void dispose() {
    _title.dispose();
    _items.dispose();
    super.dispose();
  }

  List<String> get _list => splitItems(_items.text);

  Future<void> _send() async {
    final t = AppLocalizations.of(context);
    final items = _list;
    if (items.isEmpty || _busy) return;
    setState(() => _busy = true);
    final title = _title.text.trim().isEmpty ? t.p3ListDefaultTitle : _title.text.trim();
    final ok = await widget.port.send(encodeCard(listCard(title, items),
        '🛒 $title: ${items.take(4).join(', ')}${items.length > 4 ? '…' : ''}'));
    if (!mounted) return;
    setState(() => _busy = false);
    if (ok) {
      Navigator.of(context).pop();
    } else {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(t.p3SendFailed)));
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(Gap.lg, 0, Gap.lg, Gap.lg),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(t.p3ActList, style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: Gap.md),
              TextField(
                controller: _title,
                maxLength: 60,
                decoration: InputDecoration(
                    labelText: t.p3ListTitle,
                    hintText: t.p3ListDefaultTitle,
                    border: const OutlineInputBorder()),
              ),
              TextField(
                controller: _items,
                minLines: 4,
                maxLines: 8,
                onChanged: (_) => setState(() {}),
                decoration: InputDecoration(
                    labelText: t.p3ListItems,
                    hintText: t.p3ListItemsHint,
                    border: const OutlineInputBorder()),
              ),
              const SizedBox(height: Gap.xs),
              Text(t.p3ListNote, style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant)),
              const SizedBox(height: Gap.md),
              FilledButton.icon(
                key: const ValueKey('p3-list-send'),
                onPressed: _list.isEmpty || _busy ? null : _send,
                icon: const Icon(Icons.send),
                label: Text(t.p3ListSend(notifLocalizeDigits(context, '${_list.length}'))),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ===========================================================================
// Family safety cards (reuse Safe Journey, SOS, medicines, lost phone)
// ===========================================================================
Future<String> _mapLink({Map? fallback}) async {
  try {
    if (await Geolocator.isLocationServiceEnabled()) {
      var perm = await Geolocator.checkPermission();
      if (perm == LocationPermission.denied) perm = await Geolocator.requestPermission();
      if (perm != LocationPermission.denied && perm != LocationPermission.deniedForever) {
        final pos = await Geolocator.getCurrentPosition()
            .timeout(const Duration(seconds: 8));
        return 'https://maps.google.com/?q=${pos.latitude},${pos.longitude}';
      }
    }
  } catch (_) {}
  final lat = fallback?['lat'];
  final lng = fallback?['lng'];
  if (lat != null && lng != null) return 'https://maps.google.com/?q=$lat,$lng';
  return '';
}

void _snack(BuildContext context, String m) {
  if (!context.mounted) return;
  ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));
}

Future<void> runSafetyAction(BuildContext context, AssistoChatPort port, SafetyAction a) async {
  final t = AppLocalizations.of(context);
  final api = context.read<AppState>().api;
  final now = DateTime.now();
  switch (a) {
    case SafetyAction.arrived:
      var place = '';
      try {
        final j = await api.journeyActive().timeout(const Duration(seconds: 8));
        final id = (j['id'] as num?)?.toInt();
        if (id != null) {
          place = '${(j['destination'] as Map?)?['name'] ?? ''}';
          await api.journeyArrived(id);
        }
      } catch (_) {}
      final card = AssistoCard(CardType.arrived, newCardId(),
          {'place': place, 'at': now.toUtc().toIso8601String()});
      final ok = await port.send(encodeCard(card,
          '✅ ${t.p3FbArrived}${place.isEmpty ? '' : ' · $place'}'));
      if (context.mounted) _snack(context, ok ? t.p3Sent : t.p3SendFailed);
    case SafetyAction.sos:
      final go = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          key: const ValueKey('p3-sos-confirm'),
          icon: const Icon(Icons.sos, color: Brand.dangerFill),
          title: Text(t.p3SosConfirmTitle),
          content: Text(t.p3SosConfirmBody(port.chatName)),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(t.cancel)),
            FilledButton(
                style: Brand.dangerButton(),
                onPressed: () => Navigator.pop(ctx, true),
                child: Text(t.p3SosSend)),
          ],
        ),
      );
      if (go != true || !context.mounted) return;
      Map? last;
      int? jid;
      try {
        final j = await api.journeyActive().timeout(const Duration(seconds: 6));
        jid = (j['id'] as num?)?.toInt();
        last = j['last_location'] as Map?;
      } catch (_) {}
      final link = await _mapLink(fallback: last);
      double? lat, lng;
      final m = RegExp(r'q=(-?[\d.]+),(-?[\d.]+)').firstMatch(link);
      if (m != null) {
        lat = double.tryParse(m.group(1)!);
        lng = double.tryParse(m.group(2)!);
      }
      // the existing SOS (safety-exempt: never charged) alerts safety contacts
      unawaited(api.journeySos(journeyId: jid, lat: lat, lng: lng).then((_) {}, onError: (_) {}));
      final card = AssistoCard(CardType.sos, newCardId(),
          {'at': now.toUtc().toIso8601String(), 'link': link});
      final ok = await port.send(encodeCard(card,
          '🆘 ${t.p3FbSos}${link.isEmpty ? '' : ' $link'}'));
      if (context.mounted) _snack(context, ok ? t.p3SosSent : t.p3SendFailed);
    case SafetyAction.med:
      await showModalBottomSheet<void>(
          context: context,
          showDragHandle: true,
          isScrollControlled: true,
          builder: (_) => _MedSheet(port: port));
    case SafetyAction.lost:
      Map? loc;
      try {
        final r = await api.securityLostPhone().timeout(const Duration(seconds: 8));
        loc = r['last_location'] as Map?;
      } catch (_) {}
      if (!context.mounted) return;
      final go = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          icon: Icon(Icons.phonelink_erase, color: Brand.warnInk(ctx)),
          title: Text(t.p3LostConfirmTitle),
          content: Text(t.p3LostAdvice),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(t.cancel)),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(t.p3SendAlert)),
          ],
        ),
      );
      if (go != true) return;
      final lat = loc?['lat'];
      final lng = loc?['lng'];
      final link = (lat != null && lng != null) ? 'https://maps.google.com/?q=$lat,$lng' : '';
      final card = AssistoCard(CardType.lost, newCardId(),
          {'at': now.toUtc().toIso8601String(), 'link': link});
      final ok = await port.send(encodeCard(card, '⚠ ${t.p3FbLost}'));
      if (context.mounted) _snack(context, ok ? t.p3Sent : t.p3SendFailed);
  }
}

/// Today's doses that were due before now and not taken (PRN excluded).
({List<Map<String, String>> missed, List<Map<String, String>> taken}) medicineStatus(
    List<Map<String, dynamic>> rows, DateTime now) {
  final missed = <Map<String, String>>[];
  final taken = <Map<String, String>>[];
  for (final r in rows) {
    if (r['prn'] == true) continue;
    final slot = '${r['slot'] ?? ''}';
    final name = '${r['name'] ?? ''}';
    if (r['taken'] == true) {
      taken.add({'name': name, 'slot': slot});
      continue;
    }
    if (r['skipped'] == true) {
      missed.add({'name': name, 'slot': slot});
      continue;
    }
    final m = RegExp(r'^(\d{1,2}):(\d{2})').firstMatch(slot);
    if (m == null) continue;
    final due = DateTime(now.year, now.month, now.day, int.parse(m.group(1)!), int.parse(m.group(2)!));
    if (due.isBefore(now.subtract(const Duration(minutes: 30)))) {
      missed.add({'name': name, 'slot': slot});
    }
  }
  return (missed: missed, taken: taken);
}

class _MedSheet extends StatefulWidget {
  final AssistoChatPort port;
  const _MedSheet({required this.port});
  @override
  State<_MedSheet> createState() => _MedSheetState();
}

class _MedSheetState extends State<_MedSheet> {
  bool _loading = true;
  bool _failed = false;
  List<Map<String, String>> _missed = const [];
  List<Map<String, String>> _taken = const [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _failed = false;
    });
    try {
      final rows = await context.read<AppState>().api.medicinesToday().timeout(const Duration(seconds: 10));
      final s = medicineStatus(rows, DateTime.now());
      _missed = s.missed;
      _taken = s.taken;
    } catch (_) {
      _failed = true;
    }
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _send() async {
    final t = AppLocalizations.of(context);
    final card = AssistoCard(CardType.med, newCardId(), {
      'missed': _missed,
      'taken': _taken,
      'at': DateTime.now().toUtc().toIso8601String(),
    });
    final fb = _missed.isNotEmpty
        ? '💊 ${t.p3FbMedMissed}: ${_missed.map((m) => m['name']).join(', ')}'
        : '💊 ${t.p3FbMedTaken}';
    final ok = await widget.port.send(encodeCard(card, fb));
    if (!mounted) return;
    Navigator.of(context).pop();
    _snack(context, ok ? t.p3Sent : t.p3SendFailed);
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(Gap.lg, 0, Gap.lg, Gap.lg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(t.p3SafeMed, style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: Gap.md),
            if (_loading)
              const Center(child: CircularProgressIndicator())
            else if (_failed) ...[
              Text(t.p3MedLoadFailed),
              const SizedBox(height: Gap.sm),
              OutlinedButton.icon(onPressed: _load, icon: const Icon(Icons.refresh), label: Text(t.retry)),
            ] else if (_missed.isEmpty && _taken.isEmpty)
              Text(t.p3MedNone)
            else ...[
              if (_missed.isNotEmpty) ...[
                Text(t.p3MedMissed, style: TextStyle(fontWeight: FontWeight.w700, color: Brand.onTint(context, Brand.dangerFill))),
                for (final m in _missed) Text('• ${m['name']} · ${m['slot']}'),
                const SizedBox(height: Gap.sm),
              ],
              if (_taken.isNotEmpty) ...[
                Text(t.p3MedTaken, style: TextStyle(fontWeight: FontWeight.w700, color: Brand.onTint(context, Brand.successFill))),
                for (final m in _taken) Text('• ${m['name']} · ${m['slot']}'),
              ],
              const SizedBox(height: Gap.sm),
              Text(t.p3MedNote(widget.port.chatName),
                  style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant)),
              const SizedBox(height: Gap.md),
              FilledButton.icon(onPressed: _send, icon: const Icon(Icons.send), label: Text(t.p3SendToChat)),
            ],
          ],
        ),
      ),
    );
  }
}

/// Used by the chat screens: one tap on "Add to my reminders" on a card
/// someone else sent — adds it for ME and tells the chat (E2E ack event).
Future<void> acceptReminderCard(BuildContext context, AssistoCard card,
    String myName, Future<bool> Function(String plaintext) send) async {
  final t = AppLocalizations.of(context);
  final at = DateTime.tryParse(card.str('at'));
  if (at == null) return;
  final ok = await addReminderForMe(context, card.str('title'), at.toLocal());
  if (!ok) {
    if (context.mounted) _snack(context, t.p3SendFailed);
    return;
  }
  await send(encodeCard(ackCard(card.id, myName), '✅ ${t.p3FbAck(card.str('title'))}'));
  if (context.mounted) _snack(context, t.p3ReminderAdded);
}

/// Exposed for the chat screens' list ticks.
Future<void> sendTick(AssistoCard list, int i, bool on, String myName,
    Future<bool> Function(String plaintext) send, AppLocalizations t) async {
  final items = list.list('items');
  final item = i < items.length ? '${items[i]}' : '';
  await send(encodeCard(tickCard(list.id, i, on, myName),
      '${on ? '☑' : '☐'} ${on ? t.p3FbTicked(item) : t.p3FbUnticked(item)}'));
}

/// The strip above the composer while the user types "@Assisto": one tap
/// opens the Assisto actions. What follows "@Assisto" is never sent to the
/// chat.
class AssistoMentionHint extends StatelessWidget {
  final VoidCallback onTap;
  const AssistoMentionHint({super.key, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.primaryContainer,
      child: InkWell(
        key: const ValueKey('p3-mention-hint'),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: Gap.lg, vertical: Gap.sm),
          child: Row(children: [
            Icon(Icons.auto_awesome, size: 18, color: scheme.onPrimaryContainer),
            const SizedBox(width: Gap.sm),
            Expanded(
              child: Text(t.p3MentionHint,
                  style: TextStyle(color: scheme.onPrimaryContainer, fontWeight: FontWeight.w600)),
            ),
            Icon(Icons.chevron_right, color: scheme.onPrimaryContainer),
          ]),
        ),
      ),
    );
  }
}

