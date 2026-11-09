import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../famcare_api.dart';
import '../l10n/app_localizations.dart';
import '../state.dart';
import '../theme.dart';
import '../widgets/app_sheet.dart';
import '../widgets/notif_models.dart' show notifLocalizeDigits;
import 'sos_sms.dart';

/// fcsos: the SOS surfaces' red. Darker than Brand.danger so white body text
/// on it passes WCAG AA (7.0:1); Brand.danger stays for icons / accents.
const kSosRed = Brand.sosRed;

/// One honest status block (icon + title + optional body / action).
class SosBanner extends StatelessWidget {
  const SosBanner(
      {super.key, required this.icon, required this.color, required this.title, this.body, this.action});
  final IconData icon;
  final Color color;
  final String title;
  final String? body;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final s = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(Gap.md),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(Radii.md),
        border: Border.all(color: color.withValues(alpha: 0.45)),
      ),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Icon(icon, color: color, size: 28),
        const SizedBox(width: Gap.md),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(title,
                style: TextStyle(fontSize: 17, fontWeight: FontWeight.w800, color: s.onSurface)),
            if (body != null && body!.isNotEmpty) ...[
              const SizedBox(height: Gap.xs),
              Text(body!, style: TextStyle(fontSize: 14, height: 1.35, color: s.onSurface)),
            ],
            if (action != null) action!,
          ]),
        ),
      ]),
    );
  }
}

/// A full-width, ≥ 56 dp action (emergency screens).
class SosBigButton extends StatelessWidget {
  const SosBigButton(
      {super.key,
      required this.icon,
      required this.label,
      required this.color,
      required this.fg,
      required this.onTap,
      this.height = 60});
  final IconData icon;
  final String label;
  final Color color;
  final Color fg;
  final VoidCallback? onTap;
  final double height;

  @override
  Widget build(BuildContext context) {
    return ConstrainedBox(
      constraints: BoxConstraints(minHeight: height),
      child: FilledButton.icon(
        style: FilledButton.styleFrom(
          backgroundColor: color,
          foregroundColor: fg,
          padding: const EdgeInsets.symmetric(horizontal: Gap.lg, vertical: Gap.md),
          textStyle: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
          alignment: AlignmentDirectional.centerStart,
        ),
        onPressed: onTap,
        icon: Icon(icon, size: 26),
        label: Align(
          alignment: AlignmentDirectional.centerStart,
          child: Text(label, softWrap: true),
        ),
      ),
    );
  }
}

/// "Who is going" — guardian2 "I am going" taps, oldest first.
class SosGoingList extends StatelessWidget {
  const SosGoingList({super.key, required this.going, required this.title, required this.empty});
  final List<Map<String, dynamic>> going;
  final String title;
  final String empty;

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final s = Theme.of(context).colorScheme;
    return Card(
      key: const ValueKey('fcs-going'),
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(Gap.md),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Icon(Icons.directions_run_rounded, color: s.primary),
            const SizedBox(width: Gap.sm),
            Expanded(
                child: Text(title,
                    style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w800))),
          ]),
          const SizedBox(height: Gap.sm),
          if (going.isEmpty)
            Text(empty, style: TextStyle(color: s.onSurfaceVariant))
          else
            for (final g in going)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: Gap.xs),
                child: Row(children: [
                  const Icon(Icons.check_circle_rounded, color: Brand.success, size: 22),
                  const SizedBox(width: Gap.sm),
                  Expanded(
                    child: Text(
                      g['me'] == true
                          ? t.fcsGoingYou
                          : t.fcsGoingName('${g['name'] ?? ''}',
                              sosClock(context, '${g['at'] ?? ''}')),
                      style: const TextStyle(fontSize: 16),
                    ),
                  ),
                ]),
              ),
        ]),
      ),
    );
  }
}

/// "10:42" from an ISO time, in the phone's local time, Bangla digits in bn.
String sosClock(BuildContext context, String iso) {
  final d = DateTime.tryParse(iso);
  if (d == null) return '';
  final l = d.toLocal();
  final h = l.hour % 12 == 0 ? 12 : l.hour % 12;
  final m = l.minute.toString().padLeft(2, '0');
  final t = AppLocalizations.of(context);
  final v = '$h:$m';
  final hr = l.hour;
  // Bangla names the part of the day (night, dawn, morning, noon,
  // afternoon, evening); English says am or pm
  final out = hr < 4
      ? t.fcsTimeNight(v)
      : hr < 6
          ? t.fcsTimeDawn(v)
          : hr < 12
              ? t.fcsTimeMorning(v)
              : hr < 15
                  ? t.fcsTimeNoon(v)
                  : hr < 18
                      ? t.fcsTimeAfternoon(v)
                      : hr < 20
                          ? t.fcsTimeEvening(v)
                          : t.fcsTimeLateNight(v);
  return notifLocalizeDigits(context, out);
}

/// "2 min ago" style age, Bangla digits in bn.
String sosAge(BuildContext context, int seconds) {
  final t = AppLocalizations.of(context);
  final s = seconds < 0 ? 0 : seconds;
  final out = s < 60
      ? t.fcsAgeSeconds('$s')
      : s < 3600
          ? t.fcsAgeMinutes('${s ~/ 60}')
          : t.fcsAgeHours('${s ~/ 3600}');
  return notifLocalizeDigits(context, out);
}

/// Pick the 2 SMS people: My Circle in one tap (when online) or type a
/// number. Saved on this phone (works offline). Returns the new list.
Future<List<SosSmsContact>?> showSosSmsPicker(BuildContext context,
    {required List<SosSmsContact> current,
    Future<List<Map<String, dynamic>>> Function()? loadCircle}) {
  return showAppSheet<List<SosSmsContact>>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (ctx) => _SmsPicker(current: current, loadCircle: loadCircle),
  );
}

class _SmsPicker extends StatefulWidget {
  const _SmsPicker({required this.current, this.loadCircle});
  final List<SosSmsContact> current;
  final Future<List<Map<String, dynamic>>> Function()? loadCircle;
  @override
  State<_SmsPicker> createState() => _SmsPickerState();
}

class _SmsPickerState extends State<_SmsPicker> {
  late List<SosSmsContact> _sel = [...widget.current];
  List<Map<String, dynamic>>? _rows;
  final _phone = TextEditingController();

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final f = widget.loadCircle ??
          () async => famPickRows(await context.read<AppState>().api.famCirclePick());
      final r = await f();
      if (mounted) {
        setState(() => _rows = [
              for (final x in r)
                if (cleanPhone('${x['phone'] ?? ''}').isNotEmpty) x
            ]);
      }
    } catch (_) {
      if (mounted) setState(() => _rows = const []); // offline: typing still works
    }
  }

  @override
  void dispose() {
    _phone.dispose();
    super.dispose();
  }

  bool _has(String p) => _sel.any((c) => c.phone == cleanPhone(p));

  void _toggle(String name, String phone) {
    final p = cleanPhone(phone);
    if (p.isEmpty) return;
    setState(() {
      if (_has(p)) {
        _sel.removeWhere((c) => c.phone == p);
      } else {
        if (_sel.length >= SosSmsStore.max) _sel.removeAt(0);
        _sel.add(SosSmsContact(name, p));
      }
    });
  }

  Future<void> _save() async {
    await SosSmsStore.save(_sel);
    if (mounted) Navigator.of(context).pop(_sel);
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final s = Theme.of(context).colorScheme;
    final rows = _rows;
    return Padding(
      padding: EdgeInsets.only(
          left: Gap.lg,
          right: Gap.lg,
          bottom: MediaQuery.viewInsetsOf(context).bottom + Gap.lg),
      child: SingleChildScrollView(
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text(t.fcsSmsPickTitle,
              style: const TextStyle(fontSize: 19, fontWeight: FontWeight.w800)),
          const SizedBox(height: Gap.xs),
          Text(t.fcsSmsPickBody, style: TextStyle(color: s.onSurfaceVariant)),
          const SizedBox(height: Gap.md),
          if (rows == null)
            const Center(child: Padding(padding: EdgeInsets.all(Gap.md), child: CircularProgressIndicator()))
          else
            for (final r in rows)
              CheckboxListTile(
                key: ValueKey('fcs-sms-row-${r['circle_id']}'),
                contentPadding: EdgeInsets.zero,
                value: _has('${r['phone']}'),
                onChanged: (_) => _toggle('${r['name'] ?? ''}', '${r['phone']}'),
                title: Text('${r['name'] ?? ''}'),
                subtitle: Text(notifLocalizeDigits(context, '${r['phone']}')),
              ),
          for (final c in _sel.where((c) => !(rows ?? const []).any((r) => cleanPhone('${r['phone']}') == c.phone)))
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              value: true,
              onChanged: (_) => _toggle(c.name, c.phone),
              title: Text(c.name.isEmpty ? notifLocalizeDigits(context, c.phone) : c.name),
            ),
          const SizedBox(height: Gap.sm),
          Row(children: [
            Expanded(
              child: TextField(
                key: const ValueKey('fcs-sms-phone'),
                controller: _phone,
                keyboardType: TextInputType.phone,
                inputFormatters: [
                  FilteringTextInputFormatter.allow(RegExp(r'[0-9+ \-]')),
                  LengthLimitingTextInputFormatter(18),
                ],
                decoration: InputDecoration(labelText: t.fcsSmsTypeNumber),
              ),
            ),
            const SizedBox(width: Gap.sm),
            ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 48),
              child: OutlinedButton(
                key: const ValueKey('fcs-sms-add'),
                onPressed: () {
                  _toggle('', _phone.text);
                  _phone.clear();
                },
                child: Text(t.fcsSmsAdd),
              ),
            ),
          ]),
          const SizedBox(height: Gap.lg),
          ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 52),
            child: FilledButton(
              key: const ValueKey('fcs-sms-save'),
              onPressed: _sel.isEmpty ? null : _save,
              child: Text(t.fcsSmsSave(notifLocalizeDigits(context, '${_sel.length}'))),
            ),
          ),
        ]),
      ),
    );
  }
}
