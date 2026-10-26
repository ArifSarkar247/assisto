import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../l10n/app_localizations.dart';
import '../../theme.dart';
import '../../widgets/bn_day_periods.dart' show appDateLocale;
import 'booking_source.dart';

/// booking-bot shared pieces: the 30-second guide, honest state views, the
/// status chip, a booking row and the day + free-time picker. Every time the
/// picker shows comes from the server's free-slot engine (never invented).

String bkLang(BuildContext context) => Localizations.localeOf(context).languageCode;

String bkStatusText(AppLocalizations t, String s) => switch (s) {
      'requested' => t.bkgStRequested,
      'confirmed' => t.bkgStConfirmed,
      'done' => t.bkgStDone,
      'no_show' => t.bkgStNoShow,
      'cancelled' => t.bkgStCancelled,
      _ => s,
    };

String bkChannelText(AppLocalizations t, String c) => switch (c) {
      'web' => t.bkgChWeb,
      'app' => t.bkgChApp,
      'manual' => t.bkgChManual,
      'whatsapp_cloud' => 'WhatsApp',
      'messenger' => 'Messenger',
      'instagram' => 'Instagram',
      'website' => t.bkgChWebsite,
      _ => c,
    };

/// "10:30" style time of an ISO start in the UI language (Bangla digits).
String bkTime(BuildContext context, String iso) {
  final dt = DateTime.tryParse(iso);
  if (dt == null) return '';
  final local = dt.toUtc().add(const Duration(hours: 6)); // Asia/Dhaka
  return DateFormat('h:mm a', appDateLocale(context)).format(
      DateTime(local.year, local.month, local.day, local.hour, local.minute));
}

/// The Dhaka calendar day of an ISO start.
DateTime bkDhakaDay(String iso) {
  final dt = DateTime.tryParse(iso);
  if (dt == null) return DateTime.now();
  final l = dt.toUtc().add(const Duration(hours: 6));
  return DateTime(l.year, l.month, l.day);
}

DateTime bkToday() {
  final l = DateTime.now().toUtc().add(const Duration(hours: 6));
  return DateTime(l.year, l.month, l.day);
}

String bkDayLabel(BuildContext context, DateTime d) =>
    DateFormat('EEE, d MMM', appDateLocale(context)).format(d);

class BookingGuideCard extends StatelessWidget {
  final bool business;
  final VoidCallback? onClose;
  const BookingGuideCard({super.key, this.business = true, this.onClose});

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    Widget step(IconData icon, String title, String body) => Padding(
          padding: const EdgeInsets.symmetric(vertical: Gap.xs + 2),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            CircleAvatar(
                radius: 18,
                backgroundColor: scheme.primaryContainer,
                child: Icon(icon, size: 20, color: scheme.onPrimaryContainer)),
            const SizedBox(width: Gap.md),
            Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(title, style: const TextStyle(fontWeight: FontWeight.w700)),
              const SizedBox(height: Gap.xxs),
              Text(body),
            ])),
          ]),
        );
    return Card(
      margin: const EdgeInsets.fromLTRB(Gap.lg, Gap.md, Gap.lg, Gap.xs),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(Gap.lg, 14, Gap.lg, Gap.sm),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(business ? t.bkgGuideTitle : t.bkgMyGuideTitle,
              style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: Gap.xs + 2),
          if (business) ...[
            step(Icons.design_services_outlined, t.bkgGuide1Title, t.bkgGuide1Body),
            step(Icons.link_rounded, t.bkgGuide2Title, t.bkgGuide2Body),
            step(Icons.event_available_outlined, t.bkgGuide3Title, t.bkgGuide3Body),
          ] else ...[
            step(Icons.link_rounded, t.bkgMyGuide1Title, t.bkgMyGuide1Body),
            step(Icons.schedule_rounded, t.bkgMyGuide2Title, t.bkgMyGuide2Body),
            step(Icons.notifications_active_outlined, t.bkgMyGuide3Title, t.bkgMyGuide3Body),
          ],
          const SizedBox(height: Gap.xs),
          Text(t.bkgGuideRules, style: Theme.of(context).textTheme.bodySmall),
          if (onClose != null)
            Align(
              alignment: Alignment.centerRight,
              child: TextButton(
                  style: TextButton.styleFrom(minimumSize: const Size(64, 48)),
                  onPressed: onClose,
                  child: Text(t.bkgGotIt)),
            ),
        ]),
      ),
    );
  }
}

/// Honest full-screen state: hidden / offline / error / empty.
class BkMessage extends StatelessWidget {
  final IconData icon;
  final String title, body;
  final Widget? action;
  const BkMessage({super.key, required this.icon, required this.title, required this.body, this.action});

  @override
  Widget build(BuildContext context) {
    return ListView(padding: const EdgeInsets.all(Gap.xxl), children: [
      const SizedBox(height: Gap.xxl),
      Icon(icon, size: 56, color: Theme.of(context).colorScheme.primary),
      const SizedBox(height: Gap.lg),
      Text(title, textAlign: TextAlign.center, style: Theme.of(context).textTheme.titleLarge),
      const SizedBox(height: Gap.sm),
      Text(body, textAlign: TextAlign.center),
      if (action != null) ...[const SizedBox(height: 20), Center(child: action!)],
    ]);
  }
}

/// The right state view for a failed load (feature off / offline / error).
Widget bkErrorView(BuildContext context, Object e, VoidCallback retry) {
  final t = AppLocalizations.of(context);
  final btn = FilledButton(
      style: FilledButton.styleFrom(minimumSize: const Size(120, 48)),
      onPressed: retry,
      child: Text(t.bkgRetry));
  if (bkStatus(e) == 403) {
    return BkMessage(icon: Icons.lock_clock_outlined, title: t.bkgOffTitle, body: t.bkgOffBody);
  }
  if (bkOffline(e)) {
    return BkMessage(icon: Icons.wifi_off_rounded, title: t.bkgOfflineTitle, body: t.bkgOfflineBody, action: btn);
  }
  return BkMessage(
      icon: Icons.cloud_off_rounded,
      title: t.bkgErrorTitle,
      body: bkError(e) ?? t.bkgErrorBody,
      action: btn);
}

class BkStatusChip extends StatelessWidget {
  final String status;
  const BkStatusChip(this.status, {super.key});

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final (Color bg, Color fg) = switch (status) {
      'confirmed' => (scheme.primaryContainer, scheme.onPrimaryContainer),
      'requested' => (scheme.tertiaryContainer, scheme.onTertiaryContainer),
      'done' => (scheme.secondaryContainer, scheme.onSecondaryContainer),
      _ => (scheme.surfaceContainerHighest, scheme.onSurfaceVariant),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: Gap.sm + 2, vertical: Gap.xs),
      decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(Radii.pill)),
      child: Text(bkStatusText(t, status),
          style: TextStyle(color: fg, fontWeight: FontWeight.w600, fontSize: 13)),
    );
  }
}

/// One booking row (business list / calendar / customer list).
class BkBookingTile extends StatelessWidget {
  final Map<String, dynamic> b;
  final bool business;
  final VoidCallback onTap;
  const BkBookingTile({super.key, required this.b, required this.onTap, this.business = true});

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final who = business
        ? ((b['customer_name'] ?? '').toString().isNotEmpty ? b['customer_name'].toString() : t.bkgNoName)
        : bkMap(b['business'])['name']?.toString() ?? '';
    final staff = (b['staff'] ?? '').toString();
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: Gap.lg, vertical: Gap.xs),
      child: InkWell(
        borderRadius: BorderRadius.circular(Radii.md),
        onTap: onTap,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 64),
          child: Padding(
            padding: const EdgeInsets.all(Gap.md),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              SizedBox(
                width: 76,
                child: Text(bkTime(context, (b['start'] ?? '').toString()),
                    style: Theme.of(context).textTheme.titleMedium),
              ),
              const SizedBox(width: Gap.sm),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(who, style: const TextStyle(fontWeight: FontWeight.w700)),
                  Text([b['service'] ?? '', if (staff.isNotEmpty) staff].join(' · ')),
                  if (!business) Text((b['when'] ?? '').toString(), style: Theme.of(context).textTheme.bodySmall),
                  const SizedBox(height: Gap.xs),
                  Wrap(spacing: Gap.sm, runSpacing: Gap.xs, children: [
                    BkStatusChip((b['status'] ?? '').toString()),
                    if (business)
                      Text(bkChannelText(t, (b['channel'] ?? '').toString()),
                          style: Theme.of(context).textTheme.bodySmall),
                  ]),
                ]),
              ),
              const Icon(Icons.chevron_right_rounded),
            ]),
          ),
        ),
      ),
    );
  }
}

/// Day chips + the free times the server returns for that day. [load] gets
/// the ISO day and returns the server payload ({slots:[{start,label}]}).
class BkSlotPicker extends StatefulWidget {
  final Future<Map<String, dynamic>> Function(String day) load;
  final void Function(Map<String, dynamic> slot) onPick;
  final int days;
  final DateTime? firstDay;
  const BkSlotPicker({super.key, required this.load, required this.onPick, this.days = 14, this.firstDay});

  @override
  State<BkSlotPicker> createState() => _BkSlotPickerState();
}

class _BkSlotPickerState extends State<BkSlotPicker> {
  late DateTime _day = widget.firstDay ?? bkToday();
  bool _loading = true;
  Object? _err;
  List<Map<String, dynamic>> _slots = const [];
  String? _picked;

  @override
  void initState() {
    super.initState();
    _fetch();
  }

  Future<void> _fetch() async {
    setState(() {
      _loading = true;
      _err = null;
      _picked = null;
    });
    try {
      final d = await widget.load(bkIsoDay(_day));
      _slots = bkList(d['slots']);
    } catch (e) {
      _err = e;
    }
    if (mounted) setState(() => _loading = false);
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final start = widget.firstDay ?? bkToday();
    final days = [for (var i = 0; i < widget.days; i++) start.add(Duration(days: i))];
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Text(t.bkgPickDay, style: Theme.of(context).textTheme.titleSmall),
      const SizedBox(height: Gap.sm),
      SizedBox(
        height: 56,
        child: ListView(scrollDirection: Axis.horizontal, children: [
          for (final d in days)
            Padding(
              padding: const EdgeInsets.only(right: Gap.sm),
              child: ChoiceChip(
                materialTapTargetSize: MaterialTapTargetSize.padded,
                label: Text(bkDayLabel(context, d)),
                selected: d == _day,
                onSelected: (_) {
                  _day = d;
                  _fetch();
                },
              ),
            ),
        ]),
      ),
      const SizedBox(height: Gap.md),
      Text(t.bkgPickTime, style: Theme.of(context).textTheme.titleSmall),
      const SizedBox(height: Gap.sm),
      if (_loading)
        const Padding(padding: EdgeInsets.all(Gap.lg), child: Center(child: CircularProgressIndicator()))
      else if (_err != null)
        Column(children: [
          Text(bkOffline(_err!) ? t.bkgOfflineBody : (bkError(_err!) ?? t.bkgErrorBody)),
          TextButton(
              style: TextButton.styleFrom(minimumSize: const Size(64, 48)),
              onPressed: _fetch,
              child: Text(t.bkgRetry)),
        ])
      else if (_slots.isEmpty)
        Text(t.bkgNoFreeTimes)
      else
        Wrap(spacing: Gap.sm, runSpacing: Gap.sm, children: [
          for (final s in _slots)
            ChoiceChip(
              materialTapTargetSize: MaterialTapTargetSize.padded,
              label: Text(bkTime(context, s['start'].toString())),
              selected: _picked == s['start'],
              onSelected: (_) {
                setState(() => _picked = s['start'].toString());
                widget.onPick(s);
              },
            ),
        ]),
    ]);
  }
}
