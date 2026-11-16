// cityapp B8 + B9: Long distance and water (which district buses leave from
// Gabtoli, Mohakhali, Sayedabad...; launches / waterbus from Sadarghat and
// other ghats) and the City offices guide (passport, BRTA, DC, land office,
// city corporation: where, open hours, papers to bring, date checked).
import 'package:flutter/material.dart';
import '../../ds/ds.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart' show LaunchMode;

import '../../api.dart';
import '../../city/city_api.dart';
import '../../city/city_models.dart';
import '../../city/city_widgets.dart';
import '../../l10n/app_localizations.dart';
import '../../services/action_feedback.dart' show openForUser;
import '../../state.dart';
import '../../theme.dart';
import '../../widgets/app_sheet.dart' show withNavBarInset;
import '../../widgets/local_counter.dart';
import 'city_service_screen.dart' show showCityCorrection;

class CityDirectoryScreen extends StatefulWidget {
  final String city;

  /// 'terminals', 'ghats', 'offices' (contract §5 paths).
  final List<String> kinds;
  const CityDirectoryScreen({super.key, this.city = 'dhaka', required this.kinds});
  @override
  State<CityDirectoryScreen> createState() => _CityDirectoryScreenState();
}

class _CityDirectoryScreenState extends State<CityDirectoryScreen> {
  final Map<String, List<CityDirItem>> _items = {};
  bool _loading = true, _failed = false;
  final _q = TextEditingController();

  bool get _offices => widget.kinds.contains('offices');

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _q.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final ApiClient api = context.read<AppState>().api;
    var failed = false;
    for (final k in widget.kinds) {
      try {
        final r = await api.cityDirectory(widget.city, k);
        _items[k] = [for (final e in (r['items'] as List? ?? const [])) CityDirItem.from(e)];
      } catch (_) {
        failed = true;
      }
    }
    if (mounted) {
      setState(() {
        _failed = failed && _items.values.every((l) => l.isEmpty);
        _loading = false;
      });
    }
  }

  bool _match(CityDirItem i, String q) {
    if (q.isEmpty) return true;
    final hay = [i.name, i.nameBn, i.address, ...i.routes, ...i.routesBn, ...i.papersEn, ...i.papersBn].join(' ').toLowerCase();
    return hay.contains(q.toLowerCase());
  }

  String _kindTitle(AppLocalizations t, String k) => switch (k) {
        'terminals' => t.cityTerminals,
        'ghats' => t.cityGhats,
        _ => t.cityOffices,
      };

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final q = _q.text.trim();
    return Scaffold(
      appBar: AppBar(title: Text(_offices ? t.cityOffices : t.cityLongDistance)),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              key: ValueKey('city_dir_${widget.kinds.join('_')}'),
              padding: withNavBarInset(context, const EdgeInsets.all(Gap.lg)),
              children: [
                TextField(
                  key: const ValueKey('city_dir_search'),
                  controller: _q,
                  maxLength: 60,
                  buildCounter: localCounter,
                  onChanged: (_) => setState(() {}),
                  decoration: InputDecoration(
                      prefixIcon: const Icon(Icons.search_rounded),
                      labelText: _offices ? t.cityOfficesSearch : t.cityLongSearch),
                ),
                if (_failed) Text(t.cityLiveFailed),
                for (final k in widget.kinds) ...[
                  if (widget.kinds.length > 1) CitySection(_kindTitle(t, k)),
                  if ((_items[k] ?? const []).isEmpty && !_failed)
                    DsCard(
                      padding: const EdgeInsets.all(Gap.lg),
                      child: Text(t.cityNotCollectedYet),
                    ),
                  for (final i in (_items[k] ?? const <CityDirItem>[]).where((i) => _match(i, q))) _card(t, i),
                ],
              ],
            ),
    );
  }

  Widget _card(AppLocalizations t, CityDirItem i) {
    final bn = cityBn(context);
    final s = Theme.of(context).colorScheme;
    String d(String x) => cityD(context, x);
    final papers = i.papers(bn);
    return DsCard(key: ValueKey('city_dir_item_${i.id}'),
      padding: const EdgeInsets.all(Gap.md),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Expanded(child: Text(d(i.label(bn)), style: AType.titleMedium.copyWith(fontWeight: FontWeight.w800))),
            if (i.status.isNotEmpty) CityStatusBadge(i.status),
          ]),
          if (i.address.isNotEmpty) Text(d(i.address)),
          const SizedBox(height: Gap.xs),
          Text(i.hours.isNotEmpty ? d(t.cityHours(i.hours)) : t.cityHoursUnknown,
              style: AType.bodyMedium.copyWith(fontWeight: FontWeight.w700)),
          if (i.routesFor(bn).isNotEmpty) ...[
            const SizedBox(height: Gap.xs),
            Text(i.kind == 'ghat' ? t.cityLaunchesTo : (i.kind == 'office' ? t.cityServices : t.cityBusesTo),
                style: AType.labelLarge),
            Wrap(spacing: Gap.xs, runSpacing: Gap.xs, children: [
              for (final r in i.routesFor(bn)) Chip(label: Text(d(r)), visualDensity: VisualDensity.compact),
            ]),
          ],
          if (papers.isNotEmpty) ...[
            const SizedBox(height: Gap.xs),
            Text(t.cityPapers, style: AType.labelLarge),
            for (final p in papers)
              Padding(
                padding: const EdgeInsets.only(top: Gap.xxs),
                child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Icon(Icons.check_box_outline_blank_rounded, size: 18, color: s.ds.muted),
                  const SizedBox(width: Gap.xs),
                  Expanded(child: Text(d(p))),
                ]),
              ),
          ],
          if (i.checked.isNotEmpty) ...[
            const SizedBox(height: Gap.xs),
            Text(t.cityCheckedOn(cityDate(context, i.checked)), style: AType.bodySmall),
          ],
          Wrap(spacing: Gap.sm, runSpacing: Gap.xs, children: [
            if (i.lat != null && i.lon != null)
              FilledButton.tonalIcon(
                style: FilledButton.styleFrom(minimumSize: const Size(48, 48)),
                onPressed: () => openForUser(
                    context, Uri.parse('https://www.google.com/maps/dir/?api=1&destination=${i.lat},${i.lon}'),
                    where: 'city.dir_maps', mode: LaunchMode.externalApplication),
                icon: const Icon(Icons.directions_rounded, size: 18),
                label: Text(t.cityOpenInGoogleMaps),
              ),
            if (i.sources.isNotEmpty && i.sources.first.url.isNotEmpty)
              TextButton(
                style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
                onPressed: () => openForUser(context, Uri.parse(i.sources.first.url),
                    where: 'city.dir_source', mode: LaunchMode.externalApplication),
                child: Text(t.cityOpenSource),
              ),
            TextButton(
              style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
              onPressed: () => showCityCorrection(context,
                  api: context.read<AppState>().api,
                  target: i.kind == 'office' ? 'office' : 'terminal',
                  targetId: i.id),
              child: Text(t.cityWrongInfo),
            ),
          ]),
        ]),
    );
  }
}
