import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';

import '../../l10n/app_localizations.dart';
import '../../services/action_feedback.dart' show openForUser;
import '../../theme.dart';
import '../../widgets/app_sheet.dart' show withNavBarInset;
import '../../widgets/local_counter.dart';
import '../../widgets/local_digits.dart';
import '../../widgets/wrapped_share.dart';
import '../travel_planner_screen.dart' show tvNiceDate;
import 'life_common.dart';
import 'life_logic.dart';

/// p3life — Wedding & events additions (owner PART 3, 3 Nov):
///   * [WeddingScheduleTab] programme (gaye holud, biye, bou-bhat …)
///   * [WeddingVendorsTab]  vendor list: quote, paid, due; one-tap call
///   * [WeddingGiftsTab]    gift register: who gave what, cash total,
///                          thank-you status + a thank-you SMS
///   * [InvitationCardScreen] Bangla invitation card designs → image share

Widget _totalsCard(BuildContext context, List<(String, String)> cells) {
  final s = Theme.of(context).colorScheme;
  return Card(
    color: s.primaryContainer.withValues(alpha: 0.35),
    child: Padding(
      padding: const EdgeInsets.all(Gap.md),
      child: Wrap(spacing: Gap.xl, runSpacing: Gap.sm, children: [
        for (final c in cells)
          Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(c.$1, style: TextStyle(color: s.onSurfaceVariant)),
            Text(ld(context, c.$2), style: Theme.of(context).textTheme.titleMedium),
          ]),
      ]),
    ),
  );
}

Future<void> _sms(BuildContext context, String phone, String body) {
  final to = phone.replaceAll(RegExp(r'[^0-9+]'), '');
  return openForUser(context, Uri.parse('sms:$to?body=${Uri.encodeComponent(body)}'),
      where: 'p3life.sms');
}

class WeddingScheduleTab extends StatelessWidget {
  const WeddingScheduleTab({super.key});

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    return LifeCollectionView(
      path: 'wedding/schedule',
      sort: (rows) => [...rows]..sort((a, b) =>
          '${a['date'] ?? '9999'} ${a['time'] ?? ''}'.compareTo('${b['date'] ?? '9999'} ${b['time'] ?? ''}')),
      emptyIcon: Icons.event_note_rounded,
      emptyTitle: t.p3lSchedEmptyTitle,
      emptyBody: t.p3lSchedEmptyBody,
      emptyHowTo: t.p3lSchedHowTo,
      addLabel: t.p3lSchedAdd,
      formTitle: t.p3lSchedEdit,
      deleteBody: t.p3lSchedDelete,
      fields: [
        LifeField('title', t.p3lSchedName, maxLength: 60, required: true),
        LifeField('date', t.p3lLegDate, kind: LifeFieldKind.date),
        LifeField('time', t.p3lLegTime, kind: LifeFieldKind.time),
        LifeField('place', t.p3lSchedPlace, maxLength: 100),
        LifeField('note', t.p3lNote, kind: LifeFieldKind.multiline, maxLength: 200),
      ],
      item: (context, r, onEdit, onDelete) {
        final date = '${r['date'] ?? ''}', time = '${r['time'] ?? ''}';
        final place = '${r['place'] ?? ''}', note = '${r['note'] ?? ''}';
        return Card(
          margin: const EdgeInsets.only(bottom: Gap.sm),
          child: ListTile(
            contentPadding: const EdgeInsets.fromLTRB(Gap.md, Gap.xs, Gap.xs, Gap.xs),
            leading: const Icon(Icons.celebration_rounded),
            title: Text('${r['title'] ?? ''}'),
            subtitle: Text([
              [if (date.isNotEmpty) tvNiceDate(context, date), if (time.isNotEmpty) ld(context, time)].join(' · '),
              if (place.isNotEmpty) place,
              if (note.isNotEmpty) note,
            ].where((x) => x.isNotEmpty).join('\n')),
            trailing: LifeRowMenu(onEdit: onEdit, onDelete: onDelete),
            onTap: onEdit,
          ),
        );
      },
    );
  }
}

const List<String> kVendorServices = [
  'venue', 'cook', 'decor', 'photo', 'makeup', 'card', 'transport', 'other'
];

String vendorServiceLabel(AppLocalizations t, String k) => switch (k) {
      'venue' => t.p3lVenVenue,
      'cook' => t.p3lVenCook,
      'decor' => t.p3lVenDecor,
      'photo' => t.p3lVenPhoto,
      'makeup' => t.p3lVenMakeup,
      'card' => t.p3lVenCard,
      'transport' => t.p3lVenTransport,
      _ => t.p3lVenOther,
    };

class WeddingVendorsTab extends StatelessWidget {
  const WeddingVendorsTab({super.key});

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    return LifeCollectionView(
      path: 'wedding/vendors',
      emptyIcon: Icons.storefront_rounded,
      emptyTitle: t.p3lVenEmptyTitle,
      emptyBody: t.p3lVenEmptyBody,
      emptyHowTo: t.p3lVenHowTo,
      addLabel: t.p3lVenAdd,
      formTitle: t.p3lVenEdit,
      deleteBody: t.p3lVenDelete,
      header: (context, rows) {
        final v = vendorTotals(rows);
        return Padding(
          padding: const EdgeInsets.only(bottom: Gap.sm),
          child: _totalsCard(context, [
            (t.p3lVenQuoted, fmtTaka(v.quoted)),
            (t.p3lVenPaid, fmtTaka(v.paid)),
            (t.p3lVenDue, fmtTaka(v.due)),
          ]),
        );
      },
      fields: [
        LifeField('name', t.p3lVenName, maxLength: 60, required: true),
        LifeField('service', t.p3lVenService, kind: LifeFieldKind.choice, options: [
          for (final k in kVendorServices) (k, vendorServiceLabel(t, k)),
        ]),
        LifeField('phone', t.p3lPhone, kind: LifeFieldKind.phone, maxLength: 20),
        LifeField('quote', t.p3lVenQuoted, kind: LifeFieldKind.money, maxLength: 12),
        LifeField('paid', t.p3lVenPaid, kind: LifeFieldKind.money, maxLength: 12),
        LifeField('note', t.p3lNote, kind: LifeFieldKind.multiline, maxLength: 200),
      ],
      item: (context, r, onEdit, onDelete) {
        final s = Theme.of(context).colorScheme;
        final q = poishaOf(r['quote']), p = poishaOf(r['paid']);
        final due = q > p ? q - p : 0;
        final phone = '${r['phone'] ?? ''}'.trim();
        return Card(
          margin: const EdgeInsets.only(bottom: Gap.sm),
          child: ListTile(
            contentPadding: const EdgeInsets.fromLTRB(Gap.md, Gap.xs, Gap.xs, Gap.xs),
            title: Text('${r['name'] ?? ''} · ${vendorServiceLabel(t, '${r['service'] ?? 'other'}')}'),
            subtitle: Text(ld(context,
                '${t.p3lVenQuoted} ${fmtTaka(q)} · ${t.p3lVenPaid} ${fmtTaka(p)}${due > 0 ? ' · ${t.p3lVenDue} ${fmtTaka(due)}' : ''}'),
                style: TextStyle(color: due > 0 ? s.onSurface : s.onSurfaceVariant)),
            trailing: Row(mainAxisSize: MainAxisSize.min, children: [
              if (phone.isNotEmpty)
                IconButton(
                  tooltip: t.p3lCall,
                  icon: const Icon(Icons.call_rounded),
                  onPressed: () => openForUser(context, Uri.parse('tel:$phone'),
                      where: 'p3life.vendor.call'),
                ),
              LifeRowMenu(onEdit: onEdit, onDelete: onDelete),
            ]),
            onTap: onEdit,
          ),
        );
      },
    );
  }
}

class WeddingGiftsTab extends StatelessWidget {
  const WeddingGiftsTab({super.key});

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    return LifeCollectionView(
      path: 'wedding/gifts',
      emptyIcon: Icons.card_giftcard_rounded,
      emptyTitle: t.p3lGiftEmptyTitle,
      emptyBody: t.p3lGiftEmptyBody,
      emptyHowTo: t.p3lGiftHowTo,
      addLabel: t.p3lGiftAdd,
      formTitle: t.p3lGiftEdit,
      deleteBody: t.p3lGiftDelete,
      header: (context, rows) {
        final g = giftTotals(rows);
        return Padding(
          padding: const EdgeInsets.only(bottom: Gap.sm),
          child: _totalsCard(context, [
            (t.p3lGiftCount, '${g.count}'),
            (t.p3lGiftCash, fmtTaka(g.cash)),
            (t.p3lGiftToThank, '${g.toThank}'),
          ]),
        );
      },
      fields: [
        LifeField('giver', t.p3lGiftGiver, maxLength: 60, required: true, circlePick: true),
        LifeField('gift', t.p3lGiftWhat, maxLength: 80),
        LifeField('amount', t.p3lGiftAmount, kind: LifeFieldKind.money, maxLength: 12),
        LifeField('occasion', t.p3lGiftOccasion, maxLength: 40),
        LifeField('thanked', t.p3lGiftThanked, kind: LifeFieldKind.toggle),
      ],
      item: (context, r, onEdit, onDelete) {
        final s = Theme.of(context).colorScheme;
        final giver = '${r['giver'] ?? ''}';
        final amt = poishaOf(r['amount']);
        final what = '${r['gift'] ?? ''}', occ = '${r['occasion'] ?? ''}';
        final thanked = r['thanked'] == true;
        final phone = '${r['phone'] ?? ''}'.trim();
        return Card(
          margin: const EdgeInsets.only(bottom: Gap.sm),
          child: ListTile(
            contentPadding: const EdgeInsets.fromLTRB(Gap.md, Gap.xs, Gap.xs, Gap.xs),
            leading: Icon(thanked ? Icons.favorite_rounded : Icons.card_giftcard_rounded,
                color: thanked ? s.primary : s.tertiary),
            title: Text(giver),
            subtitle: Text(ld(context, [
              [if (what.isNotEmpty) what, if (amt > 0) fmtTaka(amt)].join(' · '),
              if (occ.isNotEmpty) occ,
              thanked ? t.p3lGiftThankedYes : t.p3lGiftThankedNo,
            ].where((x) => x.isNotEmpty).join('\n'))),
            trailing: Row(mainAxisSize: MainAxisSize.min, children: [
              if (phone.isNotEmpty && !thanked)
                IconButton(
                  tooltip: t.p3lGiftThankSms,
                  icon: const Icon(Icons.sms_rounded),
                  onPressed: () => _sms(context, phone, t.p3lGiftThankMsg(giver)),
                ),
              LifeRowMenu(onEdit: onEdit, onDelete: onDelete),
            ]),
            onTap: onEdit,
          ),
        );
      },
    );
  }
}

// ------------------------------------------------------- invitation card
const List<String> kCardDesigns = ['rose', 'holud', 'classic'];
const List<String> kCardOccasions = ['wedding', 'holud', 'reception', 'akika', 'birthday', 'other'];

String cardOccasionLabel(AppLocalizations t, String k) => switch (k) {
      'wedding' => t.p3lCardOccWedding,
      'holud' => t.p3lCardOccHolud,
      'reception' => t.p3lCardOccReception,
      'akika' => t.p3lCardOccAkika,
      'birthday' => t.p3lCardOccBirthday,
      _ => t.p3lCardOccOther,
    };

String cardDesignLabel(AppLocalizations t, String k) => switch (k) {
      'rose' => t.p3lCardDesignRose,
      'holud' => t.p3lCardDesignHolud,
      _ => t.p3lCardDesignClassic,
    };

/// Fixed artwork palettes (the card is an image, the same in light/dark).
({Color bg, Color bg2, Color ink, Color accent}) _palette(String d) => switch (d) {
      'rose' => (bg: const Color(0xFF6D0F2A), bg2: const Color(0xFF9B1B3F), ink: Colors.white, accent: const Color(0xFFF3C969)),
      'holud' => (bg: const Color(0xFFFFE082), bg2: const Color(0xFFFFC107), ink: const Color(0xFF1B3A12), accent: const Color(0xFF2E7D32)),
      _ => (bg: const Color(0xFFFFFBF2), bg2: const Color(0xFFF1E6CF), ink: const Color(0xFF14213D), accent: const Color(0xFF9C6B12)),
    };

class InvitationCardScreen extends StatefulWidget {
  final Map<String, dynamic>? event; // {title, event_date, venue}
  const InvitationCardScreen({super.key, this.event});
  @override
  State<InvitationCardScreen> createState() => _InvitationCardScreenState();
}

class _InvitationCardScreenState extends State<InvitationCardScreen> {
  final _key = GlobalKey();
  String _design = 'rose', _occasion = 'wedding';
  late final TextEditingController _names, _venue, _hosts, _msg, _time;
  String _date = '';
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    final e = widget.event ?? const {};
    _names = TextEditingController(text: '${e['title'] ?? ''}');
    _venue = TextEditingController(text: '${e['venue'] ?? ''}');
    _hosts = TextEditingController();
    _msg = TextEditingController();
    _time = TextEditingController();
    _date = '${e['event_date'] ?? ''}';
    for (final c in [_names, _venue, _hosts, _msg, _time]) {
      c.addListener(() => setState(() {}));
    }
  }

  @override
  void dispose() {
    for (final c in [_names, _venue, _hosts, _msg, _time]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _share() async {
    final t = AppLocalizations.of(context);
    setState(() => _busy = true);
    final caption = t.p3lCardCaption(_names.text.trim());
    try {
      final f = await WrappedShare.captureToFile(_key, fileName: 'invitation.png');
      if (f == null) {
        await Share.share(caption);
      } else {
        await Share.shareXFiles([XFile(f.path)], text: caption);
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context)
          ..clearSnackBars()
          ..showSnackBar(SnackBar(content: Text(t.p3lCardShareFailed)));
      }
    }
    if (mounted) setState(() => _busy = false);
  }

  Widget _tf(TextEditingController c, String label, {int max = 80, int lines = 1}) => Padding(
        padding: const EdgeInsets.only(bottom: Gap.sm),
        child: TextField(
          controller: c,
          maxLength: max,
          buildCounter: localCounter,
          minLines: lines,
          maxLines: lines,
          decoration: InputDecoration(labelText: label, border: const OutlineInputBorder()),
        ),
      );

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(t.p3lCardTitle)),
      body: ListView(
        padding: withNavBarInset(context, const EdgeInsets.all(Gap.lg)),
        children: [
          RepaintBoundary(
            key: _key,
            child: InvitationCard(
              design: _design,
              heading: cardOccasionLabel(t, _occasion),
              names: _names.text.trim(),
              invite: _msg.text.trim().isEmpty ? t.p3lCardInviteDefault : _msg.text.trim(),
              date: _date.isEmpty ? '' : tvNiceDate(context, _date),
              time: ld(context, _time.text.trim()),
              venue: _venue.text.trim(),
              hosts: _hosts.text.trim().isEmpty ? '' : t.p3lCardHosts(_hosts.text.trim()),
            ),
          ),
          const SizedBox(height: Gap.md),
          FilledButton.icon(
            key: const ValueKey('life-card-share'),
            style: FilledButton.styleFrom(minimumSize: const Size(48, 52)),
            onPressed: _busy ? null : _share,
            icon: const Icon(Icons.share_rounded),
            label: Text(t.p3lCardShare),
          ),
          const SizedBox(height: Gap.lg),
          Text(t.p3lCardDesign, style: Theme.of(context).textTheme.labelLarge),
          Wrap(spacing: Gap.sm, children: [
            for (final d in kCardDesigns)
              ChoiceChip(
                key: ValueKey('life-card-design-$d'),
                label: Text(cardDesignLabel(t, d)),
                selected: _design == d,
                materialTapTargetSize: MaterialTapTargetSize.padded,
                onSelected: (_) => setState(() => _design = d),
              ),
          ]),
          const SizedBox(height: Gap.sm),
          Text(t.p3lCardOccasion, style: Theme.of(context).textTheme.labelLarge),
          Wrap(spacing: Gap.sm, children: [
            for (final o in kCardOccasions)
              ChoiceChip(
                label: Text(cardOccasionLabel(t, o)),
                selected: _occasion == o,
                materialTapTargetSize: MaterialTapTargetSize.padded,
                onSelected: (_) => setState(() => _occasion = o),
              ),
          ]),
          const SizedBox(height: Gap.md),
          _tf(_names, t.p3lCardNames),
          OutlinedButton.icon(
            style: OutlinedButton.styleFrom(minimumSize: const Size(48, 48)),
            icon: const Icon(Icons.calendar_today_rounded, size: 18),
            label: Text(_date.isEmpty ? t.p3lLegDate : '${t.p3lLegDate}: ${tvNiceDate(context, _date)}'),
            onPressed: () async {
              final now = DateTime.now();
              final d = await showDatePicker(
                  context: context,
                  initialDate: parseIsoDate(_date) ?? now,
                  firstDate: DateTime(now.year - 1),
                  lastDate: DateTime(now.year + 5));
              if (d != null && mounted) setState(() => _date = isoDate(d));
            },
          ),
          const SizedBox(height: Gap.sm),
          _tf(_time, t.p3lCardTime, max: 30),
          _tf(_venue, t.p3lSchedPlace, max: 100),
          _tf(_hosts, t.p3lCardHostsLabel, max: 100),
          _tf(_msg, t.p3lCardMessage, max: 160, lines: 3),
        ],
      ),
    );
  }
}

/// The card artwork itself (pure; the gallery renders each design).
class InvitationCard extends StatelessWidget {
  final String design, heading, names, invite, date, time, venue, hosts;
  const InvitationCard({
    super.key,
    required this.design,
    required this.heading,
    required this.names,
    required this.invite,
    required this.date,
    required this.time,
    required this.venue,
    required this.hosts,
  });

  @override
  Widget build(BuildContext context) {
    final p = _palette(design);
    TextStyle st(double size, {FontWeight w = FontWeight.w500, Color? c}) =>
        TextStyle(fontSize: size, fontWeight: w, color: c ?? p.ink, height: 1.35);
    return AspectRatio(
      aspectRatio: 4 / 5,
      child: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
              begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [p.bg, p.bg2]),
          borderRadius: BorderRadius.circular(16),
        ),
        padding: const EdgeInsets.all(14),
        child: Container(
          decoration: BoxDecoration(
            border: Border.all(color: p.accent, width: 2),
            borderRadius: BorderRadius.circular(10),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          child: FittedBox(
            fit: BoxFit.scaleDown,
            child: SizedBox(
              width: 300,
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                Icon(design == 'holud' ? Icons.local_florist_rounded : Icons.favorite_rounded,
                    color: p.accent, size: 30),
                const SizedBox(height: 6),
                Text(heading, textAlign: TextAlign.center,
                    style: st(30, w: FontWeight.w800, c: p.accent)),
                const SizedBox(height: 10),
                Text(invite, textAlign: TextAlign.center, style: st(15)),
                if (names.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  Text(names, textAlign: TextAlign.center, style: st(24, w: FontWeight.w700)),
                ],
                const SizedBox(height: 12),
                Container(height: 1.5, width: 120, color: p.accent),
                const SizedBox(height: 12),
                if (date.isNotEmpty) Text(date, textAlign: TextAlign.center, style: st(17, w: FontWeight.w700)),
                if (time.isNotEmpty) Text(time, textAlign: TextAlign.center, style: st(15)),
                if (venue.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  Text(venue, textAlign: TextAlign.center, style: st(15)),
                ],
                if (hosts.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  Text(hosts, textAlign: TextAlign.center, style: st(14, w: FontWeight.w600)),
                ],
              ]),
            ),
          ),
        ),
      ),
    );
  }
}
