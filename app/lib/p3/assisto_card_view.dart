// P3 — the rich "Assisto" card drawn in a My Circle chat (1:1 + groups).
// The card's content arrived end-to-end encrypted like any message; this
// widget only renders what the phone already decrypted.
import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../services/action_feedback.dart';
import '../theme.dart';
import '../feature_gates.dart' show kMedicalFeaturesAllowed;
import '../widgets/notif_models.dart' show notifLocalizeDigits;
import 'assisto_card.dart';

String p3When(BuildContext context, DateTime at) {
  final l = MaterialLocalizations.of(context);
  final local = at.toLocal();
  final now = DateTime.now();
  final time = l.formatTimeOfDay(TimeOfDay.fromDateTime(local));
  final sameDay = local.year == now.year && local.month == now.month && local.day == now.day;
  return sameDay ? time : '${l.formatMediumDate(local)}, $time';
}

String p3Taka(BuildContext context, int poisha) =>
    notifLocalizeDigits(context, '৳${takaOf(poisha)}');

class AssistoCardView extends StatelessWidget {
  final AssistoCard card;
  final bool mine;
  final String senderName; // display name of the sender ('' when unknown)
  final CardLedger ledger;
  final Future<void> Function(AssistoCard card)? onAddReminder;
  final void Function(AssistoCard card, int index, bool on)? onTick;
  final VoidCallback? onLongPress;

  const AssistoCardView({
    super.key,
    required this.card,
    required this.mine,
    required this.senderName,
    required this.ledger,
    this.onAddReminder,
    this.onTick,
    this.onLongPress,
  });

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final who = mine ? t.p3You : (senderName.isEmpty ? t.p3Someone : senderName);
    final (IconData icon, String label, Color tone) = switch (card.type) {
      CardType.summary => (Icons.summarize_outlined, t.p3CardSummary, scheme.primary),
      CardType.answer => (Icons.help_outline, t.p3CardAnswer, scheme.primary),
      CardType.translate => (Icons.translate, t.p3CardTranslate, scheme.primary),
      CardType.reminder => (Icons.alarm, t.p3CardReminder, scheme.primary),
      CardType.split => (Icons.call_split, t.p3CardSplit, scheme.primary),
      CardType.list => (Icons.checklist, t.p3CardList, scheme.primary),
      CardType.arrived => (Icons.where_to_vote_outlined, t.p3CardArrived, Brand.successFill),
      CardType.sos => (Icons.sos, t.p3CardSos, Brand.dangerFill),
      CardType.med => (Icons.medication_outlined, t.p3CardMed, scheme.primary),
      CardType.lost => (Icons.phonelink_erase, t.p3CardLost, Brand.warnInk(context)),
      _ => (Icons.auto_awesome, t.p3Assisto, scheme.primary),
    };
    final urgent = card.type == CardType.sos;
    final width = MediaQuery.sizeOf(context).width;
    return Align(
      alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
      child: GestureDetector(
        onLongPress: onLongPress,
        child: Container(
          key: ValueKey('p3-card-${card.type}-${card.id}'),
          constraints: BoxConstraints(maxWidth: width * 0.86),
          margin: const EdgeInsets.symmetric(horizontal: Gap.sm, vertical: Gap.xs),
          decoration: BoxDecoration(
            color: urgent
                ? Brand.dangerFill.withValues(alpha: 0.10)
                : scheme.surfaceContainerHigh,
            borderRadius: BorderRadius.circular(Radii.md),
            border: Border.all(
                color: urgent ? Brand.dangerFill : scheme.outlineVariant,
                width: urgent ? 1.5 : 1),
          ),
          clipBehavior: Clip.antiAlias,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                height: 3,
                decoration: BoxDecoration(
                  gradient: urgent ? null : Brand.gradient,
                  color: urgent ? Brand.dangerFill : null,
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(Gap.md, Gap.sm, Gap.md, Gap.md),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(children: [
                      Icon(icon, size: 18, color: tone),
                      const SizedBox(width: Gap.xs),
                      Expanded(
                        child: Text(label,
                            style: TextStyle(
                                fontWeight: FontWeight.w700, color: tone, fontSize: 13)),
                      ),
                      _AssistoChip(scheme: scheme, label: t.p3Assisto),
                    ]),
                    const SizedBox(height: Gap.sm),
                    ..._body(context, t, scheme, who),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  List<Widget> _body(BuildContext context, AppLocalizations t, ColorScheme scheme, String who) {
    final muted = TextStyle(fontSize: 12, color: scheme.onSurfaceVariant, height: 1.3);
    final body = TextStyle(fontSize: 15, color: scheme.onSurface, height: 1.35);
    switch (card.type) {
      case CardType.summary:
        return [
          Text(t.p3SummaryOf(notifLocalizeDigits(context, '${card.integer('n')}')), style: muted),
          const SizedBox(height: Gap.xs),
          SelectableText(card.str('text'), style: body),
          const SizedBox(height: Gap.sm),
          Text(t.p3AiMarker, style: muted),
        ];
      case CardType.answer:
        return [
          Text(card.str('q'), style: body.copyWith(fontWeight: FontWeight.w600)),
          const SizedBox(height: Gap.xs),
          SelectableText(card.str('a'), style: body),
          const SizedBox(height: Gap.sm),
          Text(t.p3AiMarker, style: muted),
        ];
      case CardType.translate:
        return [
          Text(card.str('src'), style: muted),
          const SizedBox(height: Gap.xs),
          SelectableText(card.str('out'), style: body),
          const SizedBox(height: Gap.sm),
          Text(t.p3AiMarker, style: muted),
        ];
      case CardType.reminder:
        return _reminder(context, t, scheme, who, body, muted);
      case CardType.split:
        return _split(context, t, scheme, body, muted);
      case CardType.list:
        return _list(context, t, scheme, body, muted);
      case CardType.arrived:
        final place = card.str('place');
        return [
          Text(t.p3ArrivedLine(who), style: body.copyWith(fontWeight: FontWeight.w600)),
          if (place.isNotEmpty) Text(place, style: body),
          Text(p3When(context, DateTime.tryParse(card.str('at')) ?? DateTime.now()), style: muted),
        ];
      case CardType.sos:
        final link = card.str('link');
        return [
          Text(t.p3SosLine(who),
              style: body.copyWith(fontWeight: FontWeight.w700, color: Brand.onTint(context, Brand.dangerFill))),
          Text(p3When(context, DateTime.tryParse(card.str('at')) ?? DateTime.now()), style: muted),
          const SizedBox(height: Gap.sm),
          if (link.isNotEmpty)
            FilledButton.icon(
              style: Brand.dangerButton(),
              onPressed: () => openForUser(context, Uri.parse(link), where: 'p3.sos.map'),
              icon: const Icon(Icons.location_on_outlined),
              label: Text(t.p3OpenLocation),
            )
          else
            Text(t.p3NoLocation, style: muted),
        ];
      case CardType.med:
        final missed = card.list('missed');
        final taken = card.list('taken');
        // play-nomed: a medicine card received from a website-APK user shows
        // no dose list in the Play flavour (missed-dose alert UI hidden).
        if (!kMedicalFeaturesAllowed) {
          return [
            Text(t.p3MedLine(who), style: body.copyWith(fontWeight: FontWeight.w600)),
          ];
        }
        return [
          Text(t.p3MedLine(who), style: body.copyWith(fontWeight: FontWeight.w600)),
          const SizedBox(height: Gap.xs),
          if (missed.isNotEmpty) ...[
            Text(t.p3MedMissed, style: muted.copyWith(color: Brand.onTint(context, Brand.dangerFill), fontWeight: FontWeight.w600)),
            for (final m in missed) Text('• ${(m as Map)['name']} · ${m['slot']}', style: body),
          ],
          if (taken.isNotEmpty) ...[
            const SizedBox(height: Gap.xs),
            Text(t.p3MedTaken, style: muted.copyWith(color: Brand.onTint(context, Brand.successFill), fontWeight: FontWeight.w600)),
            for (final m in taken) Text('• ${(m as Map)['name']} · ${m['slot']}', style: body),
          ],
        ];
      case CardType.lost:
        final link = card.str('link');
        return [
          Text(t.p3LostLine(who), style: body.copyWith(fontWeight: FontWeight.w600)),
          const SizedBox(height: Gap.xs),
          Text(t.p3LostAdvice, style: body),
          if (link.isNotEmpty) ...[
            const SizedBox(height: Gap.sm),
            OutlinedButton.icon(
              onPressed: () => openForUser(context, Uri.parse(link), where: 'p3.lost.map'),
              icon: const Icon(Icons.location_on_outlined),
              label: Text(t.p3LastSeenPlace),
            ),
          ],
        ];
    }
    return [Text(t.p3Assisto, style: body)];
  }

  List<Widget> _reminder(BuildContext context, AppLocalizations t, ColorScheme scheme,
      String who, TextStyle body, TextStyle muted) {
    final at = DateTime.tryParse(card.str('at'));
    final all = card.str('scope') == 'all';
    final acks = ledger.acks[card.id] ?? const [];
    final added = mine || ledger.ackedByMe.contains(card.id);
    return [
      Text(card.str('title'), style: body.copyWith(fontWeight: FontWeight.w600)),
      if (at != null) Text(p3When(context, at), style: body),
      const SizedBox(height: Gap.xs),
      Text(all ? t.p3ReminderForAllBy(who) : t.p3ReminderBy(who), style: muted),
      if (acks.isNotEmpty) Text(t.p3AddedBy(acks.join(', ')), style: muted),
      const SizedBox(height: Gap.sm),
      if (added)
        Row(children: [
          Icon(Icons.check_circle, size: 18, color: Brand.onTint(context, Brand.successFill)),
          const SizedBox(width: Gap.xs),
          Expanded(child: Text(t.p3InYourReminders, style: muted)),
        ])
      else
        FilledButton.icon(
          key: ValueKey('p3-rem-add-${card.id}'),
          onPressed: onAddReminder == null ? null : () => onAddReminder!(card),
          icon: const Icon(Icons.add_alarm),
          label: Text(t.p3AddToMyReminders),
        ),
    ];
  }

  List<Widget> _split(BuildContext context, AppLocalizations t, ColorScheme scheme,
      TextStyle body, TextStyle muted) {
    final shares = card.list('shares');
    return [
      Text(card.str('title'), style: body.copyWith(fontWeight: FontWeight.w600)),
      Text(t.p3SplitTotal(p3Taka(context, card.integer('total'))), style: body),
      Text(t.p3PaidBy(card.str('payer')), style: muted),
      const SizedBox(height: Gap.sm),
      for (final s in shares)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 2),
          child: Row(children: [
            Expanded(child: Text('${(s as Map)['name']}', style: body, overflow: TextOverflow.ellipsis)),
            Text(p3Taka(context, (s['amount'] as num?)?.toInt() ?? 0),
                style: body.copyWith(fontWeight: FontWeight.w600)),
          ]),
        ),
      const SizedBox(height: Gap.sm),
      Text(t.p3SplitNote, style: muted),
    ];
  }

  List<Widget> _list(BuildContext context, AppLocalizations t, ColorScheme scheme,
      TextStyle body, TextStyle muted) {
    final items = card.list('items').map((e) => '$e').toList();
    final done = ledger.doneCount(card.id, items.length);
    return [
      Text(card.str('title'), style: body.copyWith(fontWeight: FontWeight.w600)),
      Text(t.p3ListProgress(notifLocalizeDigits(context, '$done'),
              notifLocalizeDigits(context, '${items.length}')),
          style: muted),
      const SizedBox(height: Gap.xs),
      for (var i = 0; i < items.length; i++)
        Builder(builder: (context) {
          final st = ledger.itemState(card.id, i);
          return InkWell(
            key: ValueKey('p3-list-${card.id}-$i'),
            onTap: onTick == null ? null : () => onTick!(card, i, !st.done),
            borderRadius: BorderRadius.circular(Radii.sm),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Icon(st.done ? Icons.check_box : Icons.check_box_outline_blank,
                    size: 22, color: st.done ? scheme.primary : scheme.onSurfaceVariant),
                const SizedBox(width: Gap.sm),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(items[i],
                        style: body.copyWith(
                            decoration: st.done ? TextDecoration.lineThrough : null,
                            color: st.done ? scheme.onSurfaceVariant : scheme.onSurface)),
                    if (st.done && st.by.isNotEmpty) Text(t.p3TickedBy(st.by), style: muted),
                  ]),
                ),
              ]),
            ),
          );
        }),
    ];
  }
}

class _AssistoChip extends StatelessWidget {
  final ColorScheme scheme;
  final String label;
  const _AssistoChip({required this.scheme, required this.label});

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: Gap.sm, vertical: 2),
        decoration: BoxDecoration(
          color: scheme.primaryContainer,
          borderRadius: BorderRadius.circular(Radii.pill),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(Icons.auto_awesome, size: 12, color: scheme.onPrimaryContainer),
          const SizedBox(width: 3),
          Text(label, style: TextStyle(fontSize: 11, color: scheme.onPrimaryContainer, fontWeight: FontWeight.w600)),
        ]),
      );
}
